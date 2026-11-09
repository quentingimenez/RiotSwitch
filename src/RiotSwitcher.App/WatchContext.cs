using RiotSwitcher.App.Updates;
using RiotSwitcher.Core.Infrastructure;
using RiotSwitcher.Core.Riot;
using RiotSwitcher.Core.Settings;
using RiotSwitcher.Core.Switching;
using RiotSwitcher.Core.Vault;

namespace RiotSwitcher.App;

/// <summary>
/// Boucle de veille : aucune fenêtre visible hors Riot Client.
/// L'overlay est créé uniquement quand la fenêtre principale du Riot Client apparaît.
/// </summary>
internal sealed class WatchContext : ApplicationContext
{
    private readonly RiotPaths _paths;
    private readonly AppSettings _settings;
    private readonly SettingsStore _settingsStore;
    private readonly IAppLogger _logger;
    private readonly bool _exitOnClientClose;
    private readonly SessionVault _vault;
    private readonly SwitchService _switchService;
    private readonly Control _dispatcher;
    private readonly WatchMessageWindow _messages;
    private readonly RiotWindowTracker _tracker;
    private readonly System.Windows.Forms.Timer _exitTimer;
    private readonly DateTime _graceUntil = DateTime.UtcNow.AddSeconds(30);

    private OverlayForm? _overlay;
    private bool _seenWindow;
    private bool _settingsOpen;
    private bool _exitPending;
    private bool _quitPending;
    private bool _quitting;
    private bool _resourcesDisposed;

    public WatchContext(
        RiotPaths paths,
        AppSettings settings,
        SettingsStore settingsStore,
        IAppLogger logger,
        bool exitOnClientClose)
    {
        _paths = paths;
        _settings = settings;
        _settingsStore = settingsStore;
        _logger = logger;
        _exitOnClientClose = exitOnClientClose;

        _vault = new SessionVault(paths, logger);
        _switchService = new SwitchService(paths, _vault, logger: logger);

        _dispatcher = new Control();
        _ = _dispatcher.Handle; // handle de thread pour BeginInvoke / WinEventHook

        _messages = new WatchMessageWindow(OpenSettings, Quit);

        // Doit exister avant le premier Check() du tracker : le premier événement
        // Change peut être déclenché de façon synchrone par Start().
        _exitTimer = new System.Windows.Forms.Timer { Interval = 1000 };
        _exitTimer.Tick += (_, _) => CheckExitPending();

        _logger.Info("WatchContext : initialisation du veilleur.");
        _tracker = new RiotWindowTracker(_dispatcher, _logger);
        _tracker.Changed += OnRiotWindowChanged;
        _tracker.Start();

        _ = Task.Run(CheckUpdatesInBackgroundAsync);
    }

    private async Task CheckUpdatesInBackgroundAsync()
    {
        try
        {
            if (!_settings.AutoCheckUpdates) return;

            if (_settings.LastUpdateCheckUtc is { } last &&
                DateTimeOffset.UtcNow - last < TimeSpan.FromHours(24))
            {
                return;
            }

            // Laisse le veilleur démarrer sans concurrencer l'ouverture de l'overlay.
            await Task.Delay(TimeSpan.FromSeconds(20)).ConfigureAwait(false);

            var result = await UpdateState
                .CheckAsync(_paths, _settings, _settingsStore, _logger)
                .ConfigureAwait(false);

            if (result.UpdateAvailable && result.Update is not null)
            {
                _logger.Info($"Mise à jour disponible : v{result.Update.Version} (Paramètres → Mises à jour).");
            }
        }
        catch (Exception ex)
        {
            _logger.Warn("Vérification automatique des mises à jour impossible : " + ex.Message);
        }
    }

    private void OnRiotWindowChanged(RiotClientWindowInfo? window)
    {
        _logger.Info($"WatchContext : changement de fenêtre Riot (hwnd={window?.Handle.ToString() ?? "null"}).");
        if (_quitting) return;

        if (window is null)
        {
            DisposeOverlay();

            if (!_exitOnClientClose) return;

            if (!_seenWindow && DateTime.UtcNow < _graceUntil)
            {
                _exitPending = true;
                _exitTimer.Start();
                return;
            }

            if (SwitchSignal.IsActive())
            {
                _exitPending = true;
                _exitTimer.Start();
                return;
            }

            Quit();
            return;
        }

        _seenWindow = true;
        _exitPending = false;
        _exitTimer.Stop();

        try
        {
            if (_overlay is null || _overlay.IsDisposed)
            {
                _logger.Info("WatchContext : création de l'overlay.");
                _overlay = new OverlayForm(
                    _paths,
                    _vault,
                    _switchService,
                    _settingsStore,
                    _settings,
                    OpenSettings,
                    window);
                _logger.Info("WatchContext : overlay construit, affichage.");
                _overlay.ShowAttached(window);
                _logger.Info($"WatchContext : overlay affiché (handle={_overlay.Handle}, visible={_overlay.Visible}, created={_overlay.IsHandleCreated}).");
            }
            else
            {
                _overlay.UpdateTarget(window);
            }
        }
        catch (Exception ex)
        {
            _logger.Error("Création ou mise à jour de l'overlay impossible", ex);
        }
    }

    private void CheckExitPending()
    {
        if (_quitting || !_exitPending) return;

        if (SwitchSignal.IsActive()) return;
        if (!_seenWindow && DateTime.UtcNow < _graceUntil) return;
        if (_overlay is not null && !_overlay.IsDisposed) return;

        _exitTimer.Stop();
        Quit();
    }

    private void OpenSettings()
    {
        if (_quitting || _settingsOpen) return;

        _settingsOpen = true;
        try
        {
            using var form = new SettingsForm(_paths, _vault, _settingsStore, _settings, _logger);
            form.ShowDialog();
            _overlay?.RefreshAccounts();
        }
        catch (Exception ex)
        {
            _logger.Error("Ouverture des paramètres impossible", ex);
        }
        finally
        {
            _settingsOpen = false;
            if (_quitPending) Quit();
        }
    }

    private void DisposeOverlay()
    {
        try
        {
            _overlay?.Dispose();
        }
        catch
        {
            // L'overlay est peut-être déjà détruit avec la fenêtre Riot.
        }

        _overlay = null;
    }

    public void Quit()
    {
        if (_quitting) return;
        if (_settingsOpen)
        {
            _quitPending = true;
            return;
        }

        _quitting = true;
        _exitTimer.Stop();
        DisposeResources();
        ExitThread();
    }

    private void DisposeResources()
    {
        if (_resourcesDisposed) return;
        _resourcesDisposed = true;

        try
        {
            _tracker.Dispose();
        }
        catch
        {
            // Ignorer.
        }

        try
        {
            _messages.Dispose();
        }
        catch
        {
            // Ignorer.
        }

        DisposeOverlay();

        try
        {
            _exitTimer.Dispose();
        }
        catch
        {
            // Ignorer.
        }

        try
        {
            _dispatcher.Dispose();
        }
        catch
        {
            // Ignorer.
        }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) DisposeResources();
        base.Dispose(disposing);
    }
}
