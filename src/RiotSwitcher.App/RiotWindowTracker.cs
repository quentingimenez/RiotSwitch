using System.Diagnostics;
using RiotSwitcher.App.Interop;
using RiotSwitcher.Core.Infrastructure;
using RiotSwitcher.Core.Riot;
using RiotSwitcher.Core.Switching;

namespace RiotSwitcher.App;

/// <summary>
/// Détecte l'apparition/disparition de la fenêtre principale du Riot Client.
/// WinEventHook pour la réactivité + timer de secours (2 s), très peu de CPU.
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
    private IntPtr _currentHandle;
    private DateTime _startedAtUtc;
    private DateTime? _absentSinceUtc;
    private bool _started;

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
        _fallback = new System.Windows.Forms.Timer { Interval = 1000 };
        _fallback.Tick += (_, _) => Check();
    }

    public void Start()
    {
        if (_started) return;
        _started = true;
        _startedAtUtc = DateTime.UtcNow;

        _hook = AppNativeMethods.SetWinEventHook(
            AppNativeMethods.EVENT_OBJECT_CREATE,
            AppNativeMethods.EVENT_OBJECT_LOCATIONCHANGE,
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

        _fallback.Start();
        _logger?.Info($"Tracker démarré (hook={_hook}, foreground={_foregroundHook}).");
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
        // fenêtre avec son propre hook, et relancer ici un Find() complet à
        // chaque déplacement serait coûteux sans rien apporter (Changed n'est
        // émis qu'au changement de handle). Le timer de secours couvre le reste.
        if (eventType == AppNativeMethods.EVENT_OBJECT_LOCATIONCHANGE) return;

        try
        {
            if (_dispatcher.IsHandleCreated)
                _dispatcher.BeginInvoke(Check);
            else
                Check();
        }
        catch
        {
            // Le message loop est peut-être arrêté.
        }
    }

    private void Check()
    {
        if (!_started) return;

        var window = RiotClientWindow.Find();
        if (window is not null)
        {
            // Le client peut démarrer derrière une autre fenêtre ou sans focus
            // malgré une fenêtre visible. On le remonte une seule fois par handle
            // pour que l'overlay attaché soit réellement visible.
            RaiseIfNotForeground(window);

            // Une fenêtre qui a déjà été vue ne sera jamais restaurée si
            // l'utilisateur la minimise lui-même : l'overlay doit disparaître.
            _knownHandles.Add(window.Handle);
        }
        else
        {
            // Le client vient parfois de démarrer réduit (ou son état de fenêtre
            // a été restauré ainsi après une mise à jour). On le restaure une
            // seule fois pour laisser l'overlay s'afficher, sans jamais rouvrir
            // une fenêtre que l'utilisateur a volontairement minimisée.
            RestoreMinimizedOnce();
            window = RiotClientWindow.Find();

            // Le client peut avoir démarré derrière une autre fenêtre (DSH, jeu,
            // navigateur plein écran...). On le remonte une seule fois, pour un
            // processus lancé après le veilleur, afin de rendre l'overlay visible.
            if (window is null)
            {
                RaiseCoveredOnce();
                window = RiotClientWindow.Find();
            }

            if (window is not null)
            {
                RaiseIfNotForeground(window);
                _knownHandles.Add(window.Handle);
            }
        }

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
        else if (window is not null)
        {
            // Même fenêtre : rafraîchir ses coordonnées.
            Current = window;
        }
    }

    private void RestoreMinimizedOnce()
    {
        if (!_started) return;

        var minimized = RiotClientWindow.FindMinimized();
        if (minimized is null) return;

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

    private void RaiseCoveredOnce()
    {
        if (!_started || SwitchSignal.IsActive()) return;

        var present = RiotClientWindow.FindPresent();
        if (present is null) return;

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
    }
}
