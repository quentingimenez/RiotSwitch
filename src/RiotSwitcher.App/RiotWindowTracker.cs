using RiotSwitcher.App.Interop;
using RiotSwitcher.Core.Infrastructure;
using RiotSwitcher.Core.Riot;

namespace RiotSwitcher.App;

/// <summary>
/// Détecte l'apparition/disparition de la fenêtre principale du Riot Client.
/// WinEventHook pour la réactivité + timer de secours (5 s), très peu de CPU.
/// </summary>
internal sealed class RiotWindowTracker : IDisposable
{
    private readonly Control _dispatcher;
    private readonly IAppLogger? _logger;
    private readonly System.Windows.Forms.Timer _fallback;
    private readonly AppNativeMethods.WinEventDelegate _callback;
    private IntPtr _hook;
    private IntPtr _currentHandle;
    private bool _started;

    public event Action<RiotClientWindowInfo?>? Changed;

    public RiotClientWindowInfo? Current { get; private set; }

    public RiotWindowTracker(Control dispatcher, IAppLogger? logger = null)
    {
        _dispatcher = dispatcher ?? throw new ArgumentNullException(nameof(dispatcher));
        _logger = logger;
        _callback = OnWinEvent;
        _fallback = new System.Windows.Forms.Timer { Interval = 5000 };
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

        _fallback.Start();
        _logger?.Info($"Tracker démarré (hook={_hook}).");
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
        Current = window;

        if (window?.Handle != _currentHandle)
        {
            _logger?.Info(window is null
                ? "Tracker : fenêtre Riot Client absente."
                : $"Tracker : fenêtre Riot Client détectée hwnd={window.Handle}.");
            _currentHandle = window?.Handle ?? IntPtr.Zero;
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
    }
}
