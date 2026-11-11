using System.Diagnostics;
using RiotSwitcher.App.Interop;
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
    private readonly IRiotProcessController _processController;
    private readonly Control _dispatcher;
    private readonly WatchMessageWindow _messages;
    private readonly RiotWindowTracker _tracker;
    private readonly System.Windows.Forms.Timer _exitTimer;
    private readonly System.Windows.Forms.Timer _trimTimer;
    private readonly DateTime _graceUntil = DateTime.UtcNow.AddSeconds(30);

    private bool _trimLogged;

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
        _processController = new RiotProcessController(paths);

        _dispatcher = new Control();
        _ = _dispatcher.Handle; // handle de thread pour BeginInvoke / WinEventHook

        _messages = new WatchMessageWindow(OpenSettings, Quit);

        // Doit exister avant le premier Check() du tracker : le premier événement
        // Change peut être déclenché de façon synchrone par Start().
        _exitTimer = new System.Windows.Forms.Timer { Interval = 1000 };
        _exitTimer.Tick += (_, _) => CheckExitPending();

        // Le veilleur doit rester très léger : quand aucun overlay n'est affiché,
        // on rend périodiquement la mémoire de travail au système (page file),
        // sans toucher au CPU entre deux passages.
        _trimTimer = new System.Windows.Forms.Timer { Interval = 2_000 };
        _trimTimer.Tick += (_, _) => TrimWorkingSetIfIdle();

        _logger.Info("WatchContext : initialisation du veilleur.");
        _tracker = new RiotWindowTracker(_dispatcher, _logger);
        _tracker.Changed += OnRiotWindowChanged;
        _tracker.Start();

        _ = Task.Run(CheckUpdatesInBackgroundAsync);
        _trimTimer.Start();
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
            // On garde l'instance de l'overlay pour la réutiliser au prochain
            // affichage : la recréer à chaque fois coûtait la création du handle
            // WinForms et le rendu initial à chaque cycle (30-90 ms).
            HideOverlay();

            if (!_exitOnClientClose) return;

            if (!_seenWindow && DateTime.UtcNow < _graceUntil)
            {
                ScheduleExitCheck();
                return;
            }

            if (SwitchSignal.IsActive())
            {
                ScheduleExitCheck();
                return;
            }

            // Fermer la fenêtre Riot (croix / réduction dans la zone de notification)
            // ne quitte pas forcément Riot Client : l'UX ou le service peut rester
            // chargé en arrière-plan. On garde le veilleur en vie tant qu'un processus
            // Riot Client tourne, pour recréer l'overlay quand la fenêtre est rouverte.
            if (IsRiotClientAlive())
            {
                ScheduleExitCheck();
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

    private void ScheduleExitCheck()
    {
        _exitPending = true;
        _exitTimer.Start();
    }

    private bool IsRiotClientAlive()
    {
        try
        {
            // La fenêtre peut être fermée alors que l'UX ou le service Riot reste
            // en arrière-plan (zone de notification). On ne quitte que lorsque tout
            // a réellement disparu. Une seule énumération des processus par
            // vérification (l'ancienne version en faisait deux, une par nom).
            var processes = _processController.FindRiotProcesses();
            return processes.Any(p => p.IsClientUi || p.IsService);
        }
        catch
        {
            return false;
        }
    }

    private void CheckExitPending()
    {
        if (_quitting || !_exitPending) return;

        if (SwitchSignal.IsActive()) return;
        if (!_seenWindow && DateTime.UtcNow < _graceUntil) return;
        if (_overlay is { Visible: true }) return;

        // Le client Riot peut être réduit dans la zone de notification : sa fenêtre
        // est absente mais son UX ou son service tourne encore. On attend que tout
        // ait réellement quitté avant de terminer le veilleur.
        if (IsRiotClientAlive()) return;

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

    private void HideOverlay()
    {
        try
        {
            _overlay?.HideAttached();
        }
        catch
        {
            // L'overlay est peut-être déjà détruit avec la fenêtre Riot.
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

    private void TrimWorkingSetIfIdle()
    {
        if (_quitting) return;
        if (_overlay is { Visible: true }) return;

        try
        {
            using var process = Process.GetCurrentProcess();
            const long trimThreshold = 32L * 1024 * 1024;
            if (process.WorkingSet64 < trimThreshold) return;

            GC.Collect(GC.MaxGeneration, GCCollectionMode.Forced, blocking: true, compacting: true);
            GC.WaitForPendingFinalizers();
            GC.Collect(GC.MaxGeneration, GCCollectionMode.Forced, blocking: true, compacting: true);

            AppNativeMethods.EmptyWorkingSet(AppNativeMethods.GetCurrentProcess());

            // Compactage initial rapide (2 s), puis vérification plus espacée.
            _trimTimer.Interval = 10_000;

            if (!_trimLogged)
            {
                process.Refresh();
                _logger.Info(
                    "Veilleur : mémoire de travail compactée " +
                    $"(working set={process.WorkingSet64 / (1024 * 1024)} Mo, " +
                    $"privée={process.PrivateMemorySize64 / (1024 * 1024)} Mo).");
                _trimLogged = true;
            }
        }
        catch (Exception ex)
        {
            _logger.Warn("Compactage mémoire du veilleur impossible : " + ex.Message);
        }
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
            _trimTimer.Dispose();
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
