using System.Windows.Forms;
using RiotSwitcher.Core;
using RiotSwitcher.Core.Infrastructure;
using RiotSwitcher.Core.Riot;
using RiotSwitcher.Core.Settings;
using RiotSwitcher.Core.Vault;

namespace RiotSwitcher.App;

internal static class Program
{
    private const string HelpText =
        "RiotSwitch — change de compte Riot sans mot de passe.\n\n" +
        "Utilisation :\n" +
        "  RiotSwitch.exe                       Mode par défaut : zéro fond (lance Riot Client\n" +
        "                                       et quitte avec lui)\n" +
        "  RiotSwitch.exe --watch               Veilleur en arrière-plan persistant\n" +
        "  RiotSwitch.exe --launch-riot --ephemeral\n" +
        "                                       Lance Riot Client et quitte avec lui (zéro fond)\n" +
        "  RiotSwitch.exe --settings            Ouvre les paramètres\n" +
        "  RiotSwitch.exe --attach              Attache l'overlay au Riot Client déjà ouvert\n" +
        "  RiotSwitch.exe --version             Affiche la version\n\n" +
        "L'overlay n'apparaît que lorsque la fenêtre du Riot Client est ouverte.";

    [STAThread]
    private static void Main(string[] args)
    {
        ApplicationConfiguration.Initialize();
        Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);

        var options = CommandLineOptions.Parse(args);

        if (options.Help)
        {
            ShowInfo(HelpText);
            return;
        }

        if (options.Version)
        {
            ShowInfo($"{AppInfo.DisplayName} {AppInfo.Version}");
            return;
        }

        RiotPaths paths;
        try
        {
            paths = RiotPaths.Discover();
        }
        catch (RiotNotInstalledException ex)
        {
            ShowError(ex.Message);
            return;
        }

        var logger = new FileLogger(paths.VaultLogsDir);
        logger.Info($"Démarrage : attach={options.Attach}, launch={options.LaunchRiot}, watch={options.Watch}, settings={options.Settings}");

        // Les callbacks d'un switch peuvent arriver après la destruction de l'overlay
        // (fermeture de la fenêtre Riot). On journalise au lieu d'afficher la boîte
        // « exception non gérée » de WinForms.
        Application.ThreadException += (_, e) =>
            logger.Error("Exception UI non gérée", e.Exception);
        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
        {
            if (e.ExceptionObject is Exception ex)
            {
                logger.Error("Exception non gérée", ex);
            }
        };
        var settingsStore = new SettingsStore(paths, logger);
        var settings = settingsStore.Load();

        try
        {
            if (options.Settings)
            {
                RunSettings(paths, settingsStore, settings, logger);
                return;
            }

            if (options.Attach)
            {
                RunAttach(paths, settingsStore, settings, logger);
                return;
            }

            RunWatchOrLaunch(paths, settingsStore, settings, logger, options);
        }
        catch (Exception ex)
        {
            logger.Error("Erreur fatale de RiotSwitch", ex);
            ShowError("RiotSwitch a rencontré une erreur :\n\n" + ex.Message);
        }
    }

    private static void RunWatchOrLaunch(
        RiotPaths paths,
        SettingsStore settingsStore,
        AppSettings settings,
        IAppLogger logger,
        CommandLineOptions options)
    {
        using var single = SingleInstance.Acquire();

        if (!single.IsOwner)
        {
            var launchRiotFromDefault = options.NoArguments && settings.BackgroundMode == BackgroundMode.Launcher;
            if (options.LaunchRiot || launchRiotFromDefault)
            {
                // Un veilleur tourne déjà : il affichera l'overlay quand la fenêtre Riot apparaîtra.
                if (!StartRiot(paths, logger))
                {
                    ShowError("Impossible de lancer Riot Client.");
                }

                return;
            }

            if (options.Attach)
            {
                ShowInfo("RiotSwitch est déjà lancé. Utilise le bouton de l'overlay.");
            }

            return;
        }

        if (!settings.FirstRunCompleted)
        {
            using var welcome = new WelcomeForm(settingsStore, settings);
            var welcomeResult = welcome.ShowDialog();
            settings.FirstRunCompleted = true;
            if (welcomeResult != DialogResult.OK)
            {
                // « Plus tard » : ne pas installer de démarrage automatique pour cette fois.
                settings.Autostart = false;
            }

            settingsStore.Save(settings);
        }

        var shortcutWarning = ShortcutService.Apply(settings);
        if (shortcutWarning is not null)
        {
            logger.Warn($"Raccourci de démarrage non créé : {shortcutWarning}");
        }

        // Le mode par défaut est le zéro fond : sans argument et avec la configuration
        // Launcher, on démarre Riot Client puis on s'arrête avec lui. Un --watch explicite
        // conserve le veilleur persistant, même si Launcher est configuré.
        var launcherByDefault = options.NoArguments && settings.BackgroundMode == BackgroundMode.Launcher;
        if (options.LaunchRiot || launcherByDefault)
        {
            if (!StartRiot(paths, logger))
            {
                ShowError("Impossible de lancer Riot Client. Vérifie l'installation de Riot Client.");
                return;
            }
        }

        var exitOnClientClose = launcherByDefault || (options.LaunchRiot && options.Ephemeral);
        var context = new WatchContext(paths, settings, settingsStore, logger, exitOnClientClose);
        Application.Run(context);
    }

    private static void RunSettings(
        RiotPaths paths,
        SettingsStore settingsStore,
        AppSettings settings,
        IAppLogger logger)
    {
        using var single = SingleInstance.Acquire();

        if (!single.IsOwner)
        {
            WatchMessageWindow.NotifyExisting(WatchMessageWindow.ShowSettingsMessage);
            return;
        }

        var vault = new SessionVault(paths, logger);
        using var form = new SettingsForm(paths, vault, settingsStore, settings, logger);
        form.ShowDialog();

        var shortcutWarning = ShortcutService.Apply(settings);
        if (shortcutWarning is not null)
        {
            logger.Warn($"Raccourci de démarrage non créé : {shortcutWarning}");
        }
    }

    private static void RunAttach(
        RiotPaths paths,
        SettingsStore settingsStore,
        AppSettings settings,
        IAppLogger logger)
    {
        using var single = SingleInstance.Acquire();

        if (!single.IsOwner)
        {
            ShowInfo("RiotSwitch est déjà lancé. Utilise le bouton de l'overlay.");
            return;
        }

        var window = RiotClientWindow.Find();
        logger.Info(window is null
            ? "Attach : fenêtre Riot Client introuvable."
            : $"Attach : fenêtre Riot Client hwnd={window.Handle} pid={window.ProcessId}.");
        if (window is null)
        {
            ShowInfo("Riot Client n'est pas ouvert.\n\nLance Riot Client, puis réessaie --attach.");
            return;
        }

        var context = new WatchContext(paths, settings, settingsStore, logger, exitOnClientClose: true);
        Application.Run(context);
    }

    private static bool StartRiot(RiotPaths paths, IAppLogger logger)
    {
        try
        {
            var controller = new RiotProcessController(paths);
            var started = controller.StartService(launchProduct: null);
            if (!started) logger.Warn("RiotClientServices.exe n'a pas pu être démarré.");

            // Si le service tournait déjà sans interface (cas fréquent quand le client League
            // est ouvert), le simple démarrage de RiotClientServices.exe ne rouvre pas l'UI.
            // L'API locale permet de demander explicitement l'affichage.
            var localApi = new RiotLocalApi(paths);
            var showThread = new Thread(() =>
            {
                for (var attempt = 0; attempt < 40; attempt++)
                {
                    if (localApi.TryShowClient(TimeSpan.FromSeconds(1))) return;
                    Thread.Sleep(250);
                }
            })
            {
                IsBackground = true,
                Name = "RiotSwitch.ShowClient"
            };
            showThread.Start();

            return started;
        }
        catch (Exception ex)
        {
            logger.Error("Lancement de Riot Client impossible", ex);
            return false;
        }
    }

    private static void ShowInfo(string message) =>
        MessageBox.Show(message, AppInfo.DisplayName, MessageBoxButtons.OK, MessageBoxIcon.Information);

    private static void ShowError(string message) =>
        MessageBox.Show(message, AppInfo.DisplayName, MessageBoxButtons.OK, MessageBoxIcon.Error);

    private sealed class CommandLineOptions
    {
        public bool Watch { get; private set; }
        public bool LaunchRiot { get; private set; }
        public bool Ephemeral { get; private set; }
        public bool Settings { get; private set; }
        public bool Attach { get; private set; }
        public bool Help { get; private set; }
        public bool Version { get; private set; }
        public bool NoArguments { get; private set; }

        public static CommandLineOptions Parse(string[] args)
        {
            var options = new CommandLineOptions
            {
                NoArguments = args.Length == 0
            };

            foreach (var raw in args)
            {
                switch (raw.Trim().ToLowerInvariant())
                {
                    case "--watch":
                        options.Watch = true;
                        break;
                    case "--launch-riot":
                    case "--launch":
                        options.LaunchRiot = true;
                        break;
                    case "--ephemeral":
                        options.Ephemeral = true;
                        break;
                    case "--settings":
                        options.Settings = true;
                        break;
                    case "--attach":
                        options.Attach = true;
                        break;
                    case "--version":
                    case "-v":
                        options.Version = true;
                        break;
                    case "--help":
                    case "-h":
                    case "/?":
                        options.Help = true;
                        break;
                }
            }

            if (!options.LaunchRiot && !options.Settings && !options.Attach)
            {
                options.Watch = true;
            }

            return options;
        }
    }
}
