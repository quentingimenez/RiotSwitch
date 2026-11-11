using System.Diagnostics;
using System.Text;
using RiotSwitcher.App.Interop;
using RiotSwitcher.Core.Infrastructure;
using RiotSwitcher.Core.Riot;
using RiotSwitcher.Core.Switching;

namespace RiotSwitcher.App;

/// <summary>
/// Détecte l'apparition/disparition de la fenêtre principale du Riot Client.
/// WinEventHook pour la réactivité + timer de secours (2 s), très peu de CPU.
///
/// Une fenêtre déjà connue est re-vérifiée sur place (<see cref="RiotClientWindow.Inspect"/>)
/// au lieu d'énumérer toutes les fenêtres de haut niveau : le cas courant coûte quelques
/// dizaines d'appels Win32, et un EnumWindows complet n'est fait qu'à la découverte, à la
/// fermeture ou au redémarrage du client.
/// </summary>
internal sealed class RiotWindowTracker : IDisposable
{
    private readonly Control _dispatcher;
    private readonly IAppLogger? _logger;
    private readonly System.Windows.Forms.Timer _fallback;
    private readonly AppNativeMethods.WinEventDelegate _callback;
    private readonly HashSet<IntPtr> _knownHandles = new();
    private readonly HashSet<IntPtr> _raisedHandles = new();
    private IntPtr _hook;
    private IntPtr _foregroundHook;
    private IntPtr _minimizeHook;
    private IntPtr _currentHandle;
    private RiotClientWindowInfo? _lastWindow;
    private DateTime _startedAtUtc;
    private DateTime? _absentSinceUtc;
    private int _checkQueued;
    private bool _started;
    private IntPtr _pendingHwnd;
    private bool _pendingIsForeground;

    // Le client Electron change brièvement d'état pendant le chargement de la
    // page (splash, première navigation, fenêtre pas encore peinte). On garde
    // l'overlay quelques secondes avant de le détruire pour éviter les
    // apparitions/disparitions pendant que la page se rend.
    private const int AbsentGraceMs = 3500;

    public event Action<RiotClientWindowInfo?>? Changed;

    public RiotClientWindowInfo? Current { get; private set; }

    public RiotWindowTracker(Control dispatcher, IAppLogger? logger = null)
    {
        _dispatcher = dispatcher ?? throw new ArgumentNullException(nameof(dispatcher));
        _logger = logger;
        _callback = OnWinEvent;

        // Filet de sécurité uniquement : les changements réels (création, affichage,
        // masquage, premier plan) arrivent par le hook. Un balayage toutes les 2 s
        // suffit à couvrir les cas non couverts par les événements (redimensionnement
        // d'une fenêtre minimisée, etc.) en coûtant deux fois moins qu'à 1 Hz.
        _fallback = new System.Windows.Forms.Timer { Interval = 2000 };
        _fallback.Tick += (_, _) => Check();
    }

    public void Start()
    {
        if (_started) return;
        _started = true;
        _startedAtUtc = DateTime.UtcNow;

        // Seuls les événements qui changent l'état de la fenêtre (création,
        // destruction, affichage, masquage) sont demandés. L'ancienne plage
        // CREATE..LOCATIONCHANGE livrait aussi REORDER/FOCUS/SELECTION/
        // LOCATIONCHANGE que le callback jetait ensuite : c'était la principale
        // source de CPU du veilleur sur un bureau actif.
        _hook = AppNativeMethods.SetWinEventHook(
            AppNativeMethods.EVENT_OBJECT_CREATE,
            AppNativeMethods.EVENT_OBJECT_HIDE,
            IntPtr.Zero,
            _callback,
            0,
            0,
            AppNativeMethods.WINEVENT_OUTOFCONTEXT | AppNativeMethods.WINEVENT_SKIPOWNPROCESS);

        // Suit aussi les changements de fenêtre active : l'overlay doit disparaître
        // quand le Riot Client est recouvert ou caché, et revenir quand il est visible.
        _foregroundHook = AppNativeMethods.SetWinEventHook(
            AppNativeMethods.EVENT_SYSTEM_FOREGROUND,
            AppNativeMethods.EVENT_SYSTEM_FOREGROUND,
            IntPtr.Zero,
            _callback,
            0,
            0,
            AppNativeMethods.WINEVENT_OUTOFCONTEXT | AppNativeMethods.WINEVENT_SKIPOWNPROCESS);

        // Réduction/restauration : nécessaire pour cacher/montrer l'overlay sans
        // attendre le timer de secours (les événements OBJECT ne couvrent pas la
        // réduction d'une fenêtre).
        _minimizeHook = AppNativeMethods.SetWinEventHook(
            AppNativeMethods.EVENT_SYSTEM_MINIMIZESTART,
            AppNativeMethods.EVENT_SYSTEM_MINIMIZEEND,
            IntPtr.Zero,
            _callback,
            0,
            0,
            AppNativeMethods.WINEVENT_OUTOFCONTEXT | AppNativeMethods.WINEVENT_SKIPOWNPROCESS);

        _fallback.Start();
        _logger?.Info($"Tracker démarré (hook={_hook}, foreground={_foregroundHook}, minimize={_minimizeHook}).");
        Check();
    }

    private void OnWinEvent(
        IntPtr hWinEventHook,
        uint eventType,
        IntPtr hwnd,
        int idObject,
        int idChild,
        uint dwEventThread,
        uint dwmsEventTime)
    {
        if (idObject != 0) return;

        // Les changements de position sont très nombreux : l'overlay suit la
        // fenêtre avec son propre hook, et relancer ici un Scan() complet à
        // chaque déplacement serait coûteux sans rien apporter (Changed n'est
        // émis qu'au changement de handle). Le timer de secours couvre le reste.
        if (eventType == AppNativeMethods.EVENT_OBJECT_LOCATIONCHANGE) return;

        // Les événements de création/affichage/masquage de toutes les applications
        // passent par un hook global. Quand une fenêtre Riot est déjà connue, seuls
        // ses propres événements peuvent changer son état : ignorer tous les autres
        // évite des vérifications inutiles pendant l'activité normale du bureau.
        if (eventType != AppNativeMethods.EVENT_SYSTEM_FOREGROUND &&
            _lastWindow is { } known &&
            hwnd != known.Handle)
        {
            return;
        }

        // Aucune fenêtre Riot connue : les événements sont regroupés et le titre
        // de la dernière fenêtre reçue sera lu une seule fois par lot, sur le
        // thread UI (dans Check), au lieu d'une fois par événement ici.
        _pendingHwnd = hwnd;
        _pendingIsForeground = eventType == AppNativeMethods.EVENT_SYSTEM_FOREGROUND;
        QueueCheck();
    }

    private static bool HasRiotWindowTitle(IntPtr hwnd)
    {
        try
        {
            var length = AppNativeMethods.GetWindowTextLength(hwnd);
            if (length != RiotClientWindow.WindowTitle.Length) return false;

            var builder = new StringBuilder(length + 1);
            if (AppNativeMethods.GetWindowText(hwnd, builder, builder.Capacity) <= 0) return false;
            return string.Equals(builder.ToString(), RiotClientWindow.WindowTitle, StringComparison.Ordinal);
        }
        catch
        {
            return false;
        }
    }

    /// <summary>
    /// Regroupe les événements rapprochés en une seule vérification : un pic
    /// d'événements Windows ne doit pas déclencher une file de vérifications.
    /// </summary>
    private void QueueCheck()
    {
        if (Interlocked.Exchange(ref _checkQueued, 1) != 0) return;

        try
        {
            if (_dispatcher.IsHandleCreated)
            {
                _dispatcher.BeginInvoke(new Action(() =>
                {
                    Interlocked.Exchange(ref _checkQueued, 0);
                    Check();
                }));
            }
            else
            {
                Interlocked.Exchange(ref _checkQueued, 0);
                Check();
            }
        }
        catch
        {
            // Le message loop est peut-être arrêté.
            Interlocked.Exchange(ref _checkQueued, 0);
        }
    }

    private void Check()
    {
        if (!_started) return;

        // Aucune fenêtre Riot connue : la plupart des événements du bureau ne la
        // concernent pas. Le titre de la fenêtre du lot est lu une seule fois ici ;
        // s'il ne peut pas s'agir du client Riot, on évite une énumération complète.
        var pendingHwnd = _pendingHwnd;
        var pendingIsForeground = _pendingIsForeground;
        _pendingHwnd = IntPtr.Zero;
        _pendingIsForeground = false;

        if (_lastWindow is null &&
            !pendingIsForeground &&
            pendingHwnd != IntPtr.Zero &&
            !HasRiotWindowTitle(pendingHwnd))
        {
            return;
        }

        var window = ResolveCurrent();

        var handle = window?.Handle ?? IntPtr.Zero;

        if (handle == IntPtr.Zero)
        {
            // Fenêtre momentanément absente pendant le rendu de la page : on
            // conserve l'overlay quelques secondes avant de le détruire.
            var now = DateTime.UtcNow;
            _absentSinceUtc ??= now;

            if (_currentHandle != IntPtr.Zero &&
                (now - _absentSinceUtc.Value).TotalMilliseconds < AbsentGraceMs)
            {
                return;
            }
        }
        else
        {
            _absentSinceUtc = null;
        }

        Current = window;

        if (handle != _currentHandle)
        {
            _logger?.Info(window is null
                ? "Tracker : fenêtre Riot Client absente."
                : $"Tracker : fenêtre Riot Client détectée hwnd={window.Handle} pid={window.ProcessId} rect=({window.X},{window.Y},{window.Width}x{window.Height}).");
            _currentHandle = handle;
            try
            {
                Changed?.Invoke(window);
            }
            catch
            {
                // L'overlay ne doit pas tuer le veilleur.
            }
        }
    }

    /// <summary>
    /// Détermine l'état courant de la fenêtre Riot : re-vérification sur place si un
    /// handle est déjà connu, sinon une seule énumération complète.
    /// </summary>
    private RiotClientWindowInfo? ResolveCurrent()
    {
        if (_lastWindow is { } known)
        {
            var inspected = RiotClientWindow.Inspect(known.Handle, known.ProcessId, out var state);

            if (state != RiotWindowState.None)
            {
                if (inspected is not null) _lastWindow = inspected;

                switch (state)
                {
                    case RiotWindowState.Visible:
                        RaiseIfNotForeground(inspected!);
                        _knownHandles.Add(inspected!.Handle);
                        return inspected;

                    case RiotWindowState.Minimized:
                        // Le client peut démarrer réduit (ou son état a été restauré
                        // ainsi après une mise à jour) : on le restaure une seule fois,
                        // sans jamais rouvrir une fenêtre minimisée par l'utilisateur.
                        if (_knownHandles.Contains(inspected!.Handle)) return null;
                        RestoreMinimizedOnce(inspected);
                        return InspectAfterRestore(inspected);

                    case RiotWindowState.Present:
                        // Le client peut avoir démarré derrière une autre fenêtre : on
                        // le remonte une seule fois, pour un processus lancé après le
                        // veilleur, afin de rendre l'overlay visible.
                        if (!_knownHandles.Contains(inspected!.Handle) &&
                            !_raisedHandles.Contains(inspected.Handle))
                        {
                            RaiseCoveredOnce(inspected);
                            return InspectAfterRestore(inspected);
                        }

                        return null;

                    default:
                        // Fenêtre cachée, cloaked, hors écran ou trop petite : pas
                        // d'overlay, mais on garde le handle pour la re-vérifier.
                        return null;
                }
            }

            // Le handle n'est plus valide (fenêtre fermée) : nouvelle découverte.
            _lastWindow = null;
        }

        var scan = RiotClientWindow.Scan();

        if (scan.Visible is { } visible)
        {
            RaiseIfNotForeground(visible);
            _knownHandles.Add(visible.Handle);
            _lastWindow = visible;
            return visible;
        }

        var candidate = scan.Minimized ?? scan.Present;
        if (candidate is not null)
        {
            if (scan.Minimized is not null)
            {
                RestoreMinimizedOnce(scan.Minimized);
            }
            else
            {
                RaiseCoveredOnce(scan.Present!);
            }

            return InspectAfterRestore(candidate);
        }

        return null;
    }

    /// <summary>
    /// Après une restauration/remontée, la fenêtre peut mettre quelques millisecondes
    /// à devenir visible : une re-vérification immédiate suffit la plupart du temps.
    /// Sinon le hook (affichage/premier plan) ou le timer de secours reprend la main.
    /// </summary>
    private RiotClientWindowInfo? InspectAfterRestore(RiotClientWindowInfo candidate)
    {
        var after = RiotClientWindow.Inspect(candidate.Handle, candidate.ProcessId, out var state);
        if (state == RiotWindowState.Visible && after is not null)
        {
            RaiseIfNotForeground(after);
            _knownHandles.Add(after.Handle);
            _lastWindow = after;
            return after;
        }

        if (after is not null) _lastWindow = after;
        return null;
    }

    private void RestoreMinimizedOnce(RiotClientWindowInfo minimized)
    {
        if (!_started) return;
        if (!_knownHandles.Add(minimized.Handle)) return;

        _logger?.Info(
            $"Tracker : fenêtre Riot Client minimisée détectée hwnd={minimized.Handle} pid={minimized.ProcessId} ; restauration unique.");

        try
        {
            AppNativeMethods.ShowWindow(minimized.Handle, AppNativeMethods.SW_RESTORE);
        }
        catch
        {
            // Une fenêtre peut disparaître entre l'énumération et la restauration.
        }
    }

    private void RaiseIfNotForeground(RiotClientWindowInfo window)
    {
        if (!_started || SwitchSignal.IsActive()) return;
        if (_knownHandles.Contains(window.Handle) || _raisedHandles.Contains(window.Handle)) return;

        // Si le client est déjà au premier plan, rien à faire : l'overlay sera
        // au-dessus de lui car il lui appartient.
        if (AppNativeMethods.GetForegroundWindow() == window.Handle)
        {
            _raisedHandles.Add(window.Handle);
            return;
        }

        if (!IsProcessNewerThanWatcher(window.ProcessId)) return;

        _raisedHandles.Add(window.Handle);
        _logger?.Info(
            $"Tracker : fenêtre Riot Client sans focus hwnd={window.Handle} pid={window.ProcessId} ; remontée unique.");

        try
        {
            if (!AppNativeMethods.ForceForeground(window.Handle))
            {
                _logger?.Warn(
                    $"Tracker : impossible de remonter la fenêtre Riot Client hwnd={window.Handle} au premier plan.");
            }
        }
        catch
        {
            // Une fenêtre peut disparaître entre l'énumération et la remontée.
        }
    }

    private void RaiseCoveredOnce(RiotClientWindowInfo present)
    {
        if (!_started || SwitchSignal.IsActive()) return;

        // Uniquement une fenêtre jamais détectée (lancée pendant que le veilleur
        // tournait), et une seule fois par handle.
        if (_knownHandles.Contains(present.Handle) || _raisedHandles.Contains(present.Handle)) return;
        if (!IsProcessNewerThanWatcher(present.ProcessId)) return;

        _raisedHandles.Add(present.Handle);

        _logger?.Info(
            $"Tracker : fenêtre Riot Client lancée en arrière-plan hwnd={present.Handle} pid={present.ProcessId} ; remontée unique.");

        try
        {
            if (!AppNativeMethods.ForceForeground(present.Handle))
            {
                _logger?.Warn(
                    $"Tracker : impossible de remonter la fenêtre Riot Client hwnd={present.Handle} au premier plan.");
            }
        }
        catch
        {
            // Une fenêtre peut disparaître entre l'énumération et la remontée.
        }
    }

    private bool IsProcessNewerThanWatcher(int processId)
    {
        try
        {
            using var process = Process.GetProcessById(processId);
            return process.StartTime.ToUniversalTime() >= _startedAtUtc;
        }
        catch
        {
            return false;
        }
    }

    public void Dispose()
    {
        _started = false;
        _fallback.Stop();
        _fallback.Dispose();

        if (_hook != IntPtr.Zero)
        {
            AppNativeMethods.UnhookWinEvent(_hook);
            _hook = IntPtr.Zero;
        }

        if (_foregroundHook != IntPtr.Zero)
        {
            AppNativeMethods.UnhookWinEvent(_foregroundHook);
            _foregroundHook = IntPtr.Zero;
        }

        if (_minimizeHook != IntPtr.Zero)
        {
            AppNativeMethods.UnhookWinEvent(_minimizeHook);
            _minimizeHook = IntPtr.Zero;
        }
    }
}
