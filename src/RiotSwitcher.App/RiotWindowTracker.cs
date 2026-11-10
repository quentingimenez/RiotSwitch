using RiotSwitcher.App.Interop;
using RiotSwitcher.Core.Infrastructure;
using RiotSwitcher.Core.Riot;

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
    private IntPtr _hook;
    private IntPtr _foregroundHook;
    private IntPtr _currentHandle;
    private bool _started;

    public event Action<RiotClientWindowInfo?>? Changed;

    public RiotClientWindowInfo? Current { get; private set; }

    public RiotWindowTracker(Control dispatcher, IAppLogger? logger = null)
    {
        _dispatcher = dispatcher ?? throw new ArgumentNullException(nameof(dispatcher));
        _logger = logger;
        _callback = OnWinEvent;
        _fallback = new System.Windows.Forms.Timer { Interval = 2000 };
        _fallback.Tick += (_, _) => Check();
    }

    public void Start()
    {
        if (_started) return;
        _started = true;

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
            if (window is not null)
                _knownHandles.Add(window.Handle);
        }

        Current = window;
        var handle = window?.Handle ?? IntPtr.Zero;

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
