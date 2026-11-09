using RiotSwitcher.App.Interop;
using RiotSwitcher.Core;

namespace RiotSwitcher.App;

/// <summary>Une seule instance du veilleur par session Windows.</summary>
internal sealed class SingleInstance : IDisposable
{
    private readonly Mutex? _mutex;

    private SingleInstance(Mutex? mutex, bool isOwner)
    {
        _mutex = mutex;
        IsOwner = isOwner;
    }

    public bool IsOwner { get; }

    public static SingleInstance Acquire()
    {
        try
        {
            var mutex = new Mutex(initiallyOwned: true, AppInfo.WatchMutexName, out var createdNew);
            return new SingleInstance(mutex, createdNew);
        }
        catch
        {
            // Environnement sans mutex nommé : laisser démarrer.
            return new SingleInstance(null, true);
        }
    }

    public void Dispose()
    {
        if (_mutex is null) return;

        if (IsOwner)
        {
            try
            {
                _mutex.ReleaseMutex();
            }
            catch
            {
                // Pas propriétaire ou déjà libéré.
            }
        }

        _mutex.Dispose();
    }
}

/// <summary>Petite fenêtre top-level cachée pour recevoir les messages inter-instances.</summary>
internal sealed class WatchMessageWindow : NativeWindow, IDisposable
{
    public static readonly uint ShowSettingsMessage = AppNativeMethods.RegisterWindowMessage("RiotSwitch.ShowSettings");
    public static readonly uint QuitMessage = AppNativeMethods.RegisterWindowMessage("RiotSwitch.Quit");

    private readonly Action _showSettings;
    private readonly Action _quit;

    public WatchMessageWindow(Action showSettings, Action quit)
    {
        _showSettings = showSettings;
        _quit = quit;

        CreateHandle(new CreateParams
        {
            Caption = "RiotSwitch.Watch",
            Style = unchecked((int)0x80000000), // WS_POPUP
            ExStyle = AppNativeMethods.WS_EX_TOOLWINDOW,
            X = -32000,
            Y = -32000,
            Width = 1,
            Height = 1,
            Parent = IntPtr.Zero
        });
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == (int)ShowSettingsMessage)
        {
            try
            {
                _showSettings();
            }
            catch
            {
                // Ne pas casser la boucle de messages.
            }

            return;
        }

        if (m.Msg == (int)QuitMessage)
        {
            try
            {
                _quit();
            }
            catch
            {
                // Ignorer.
            }

            return;
        }

        base.WndProc(ref m);
    }

    public void Dispose()
    {
        try
        {
            DestroyHandle();
        }
        catch
        {
            // Déjà détruit.
        }
    }

    public static void NotifyExisting(uint message)
    {
        try
        {
            AppNativeMethods.PostMessage(
                (IntPtr)AppNativeMethods.HWND_BROADCAST,
                message,
                IntPtr.Zero,
                IntPtr.Zero);
        }
        catch
        {
            // Pas d'instance existante.
        }
    }
}
