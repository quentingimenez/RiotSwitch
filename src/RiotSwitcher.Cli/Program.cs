using System.Text;
using RiotSwitcher.Core;
using RiotSwitcher.Core.Infrastructure;
using RiotSwitcher.Core.Riot;
using RiotSwitcher.Core.Switching;
using RiotSwitcher.Core.Updates;
using RiotSwitcher.Core.Vault;

namespace RiotSwitcher.Cli;

internal static class Program
{
    private const int ExitOk = 0;
    private const int ExitError = 1;
    private const int ExitGame = 2;
    private const int ExitTarget = 3;
    private const int ExitAccess = 4;
    private const int ExitVerification = 5;

    private static int Main(string[] args)
    {
        try
        {
            Console.OutputEncoding = Encoding.UTF8;
        }
        catch
        {
            // Console atypique : continuer.
        }

        if (args.Length == 0 || IsHelp(args[0]))
        {
            PrintHelp();
            return ExitOk;
        }

        if (IsVersion(args[0]))
        {
            Console.WriteLine($"{AppInfo.DisplayName} {AppInfo.Version}");
            return ExitOk;
        }

        var command = args[0].Trim().ToLowerInvariant();
        var rest = args.Skip(1).ToArray();

        try
        {
            return command switch
            {
                "list" or "accounts" => ListAccounts(rest),
                "capture" => Capture(rest),
                "switch" => Switch(rest),
                "status" => Status(rest),
                "doctor" => Doctor(rest),
                "window" => Window(rest),
                "restore" => Restore(rest),
                "update" or "check-update" => CheckUpdate(rest),
                _ => Unknown(command)
            };
        }
        catch (RiotNotInstalledException ex)
        {
            Console.Error.WriteLine($"Riot Client introuvable : {ex.Message}");
            return ExitTarget;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidDataException)
        {
            Console.Error.WriteLine($"Erreur : {ex.Message}");
            return ExitError;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Erreur inattendue : {ex.Message}");
            return ExitError;
        }
    }

    private static int ListAccounts(string[] args)
    {
        var paths = RiotPaths.Discover();
        var vault = new SessionVault(paths);
        var accounts = vault.ListAccounts();

        if (accounts.Count == 0)
        {
            Console.WriteLine("Aucun compte enregistré.");
            Console.WriteLine("Connecte-toi dans le client Riot, puis lance : RiotSwitch.Cli capture --label \"Mon compte\"");
            return ExitOk;
        }

        Console.WriteLine($"{"Libellé",-22} {"Riot ID",-24} {"ID",-14} {"Dernier usage",-20} Produit");
        Console.WriteLine(new string('-', 100));

        foreach (var account in accounts)
        {
            var used = account.LastUsedUtc?.ToLocalTime().ToString("yyyy-MM-dd HH:mm") ?? "—";
            var product = string.IsNullOrWhiteSpace(account.AutoLaunchProduct) ? "—" : account.AutoLaunchProduct;
            Console.WriteLine($"{Truncate(account.DisplayName, 22),-22} {Truncate(account.RiotId ?? "—", 24),-24} {account.ShortId,-14} {used,-20} {product}");

            if (!string.IsNullOrWhiteSpace(account.LastError))
                Console.WriteLine($"  ⚠ {account.LastError}");
        }

        return ExitOk;
    }

    private static int Capture(string[] args)
    {
        var label = ReadOption(args, "--label");
        var includeProfile = args.Any(a => string.Equals(a, "--profile", StringComparison.OrdinalIgnoreCase));

        var paths = RiotPaths.Discover();
        if (!paths.LiveSessionExists)
        {
            Console.Error.WriteLine("Fichier de session Riot introuvable : connecte-toi d'abord dans le client Riot.");
            return ExitTarget;
        }

        var snapshot = RiotSessionReader.ReadFile(paths.LiveSessionFile);
        if (!snapshot.Info.HasSession || !snapshot.Info.CanSwitch)
        {
            Console.Error.WriteLine($"Session non exploitable : {snapshot.Info.UnsupportedReason ?? "format inconnu"}");
            return ExitTarget;
        }

        var vault = new SessionVault(paths);
        var account = vault.Capture(snapshot, label, includeProfile);

        Console.WriteLine($"Compte enregistré : {account.DisplayName} ({account.RiotId ?? account.Id})");
        if (account.Puuid is not null) Console.WriteLine($"PUUID : {account.Puuid}");
        Console.WriteLine($"Format : {snapshot.Info.Format}");
        Console.WriteLine($"Profil Electron inclus : {(account.HasProfile ? "oui" : "non")}");
        return ExitOk;
    }

    private static int Switch(string[] args)
    {
        var target = args.FirstOrDefault(a => !a.StartsWith("--", StringComparison.Ordinal));
        if (string.IsNullOrWhiteSpace(target))
        {
            Console.Error.WriteLine("Usage : RiotSwitch.Cli switch <id|libellé|RiotID> [--product league|valorant|none] [--no-launch] [--yes]");
            return ExitTarget;
        }

        var product = ReadOption(args, "--product");
        var noLaunch = args.Any(a => string.Equals(a, "--no-launch", StringComparison.OrdinalIgnoreCase));
        var yes = args.Any(a => string.Equals(a, "--yes", StringComparison.OrdinalIgnoreCase));

        var paths = RiotPaths.Discover();
        var vault = new SessionVault(paths);
        var account = vault.ResolveAccount(target);

        if (account is null)
        {
            Console.Error.WriteLine($"Compte cible introuvable : {target}");
            Console.Error.WriteLine("Comptes disponibles :");
            foreach (var known in vault.ListAccounts())
                Console.Error.WriteLine($"  - {known.DisplayName} ({known.RiotId ?? known.Id})");
            return ExitTarget;
        }

        var guard = new GameGuard().Check();
        if (guard.IsHardBlock)
        {
            Console.Error.WriteLine(guard.Message);
            return ExitGame;
        }

        if (guard.NeedsConfirmation && !yes)
        {
            Console.Error.WriteLine(guard.Message);
            Console.Error.WriteLine("Relance avec --yes pour confirmer la fermeture du client League of Legends.");
            return ExitError;
        }

        Console.WriteLine($"Changement vers {account.DisplayName}...");
        var service = new SwitchService(paths, vault);
        var result = service.Switch(new SwitchRequest
        {
            AccountId = account.Id,
            LaunchProduct = product,
            LaunchAfterSwitch = !noLaunch,
            ConfirmClientClose = _ => yes,
            ReportProgress = progress => Console.WriteLine($"  [{progress.Percent?.ToString() ?? ".."}%] {progress.Message}")
        });

        Console.WriteLine(result.Message);
        if (!string.IsNullOrWhiteSpace(result.Error)) Console.Error.WriteLine($"Détail : {result.Error}");

        return result.Outcome switch
        {
            SwitchOutcome.Success or SwitchOutcome.AlreadyCurrent => ExitOk,
            SwitchOutcome.GameRunning => ExitGame,
            SwitchOutcome.SessionUnusable or SwitchOutcome.ClientNotInstalled or SwitchOutcome.ConfirmationDeclined => ExitTarget,
            SwitchOutcome.AccessDenied => ExitAccess,
            SwitchOutcome.VerificationFailed or SwitchOutcome.RolledBack or SwitchOutcome.ReconnectRequired => ExitVerification,
            _ => ExitError
        };
    }

    private static int Status(string[] args)
    {
        var paths = RiotPaths.Discover();
        var vault = new SessionVault(paths);

        Console.WriteLine($"Riot Client : {paths.InstallRoot}");
        Console.WriteLine($"Session     : {paths.LiveSessionFile}");

        if (paths.LiveSessionExists)
        {
            try
            {
                var live = RiotSessionReader.ReadFile(paths.LiveSessionFile);
                Console.WriteLine($"Format      : {live.Info.Format}");
                Console.WriteLine($"Compte      : {live.Info.RiotId ?? "(inconnu)"}");
                Console.WriteLine($"PUUID       : {live.Info.Puuid ?? "(inconnu)"}");
                Console.WriteLine($"Switchable  : {(live.Info.CanSwitch ? "oui" : "non")}");

                if (!live.Info.CanSwitch && live.Info.UnsupportedReason is not null)
                    Console.WriteLine($"Raison      : {live.Info.UnsupportedReason}");

                var account = vault.FindByPuuid(live.Info.Puuid);
                Console.WriteLine($"Coffre      : {(account is null ? "compte non enregistré" : $"enregistré sous « {account.DisplayName} »")}");
            }
            catch (InvalidDataException ex)
            {
                Console.WriteLine($"Session illisible : {ex.Message}");
            }
        }
        else
        {
            Console.WriteLine("Session     : absente");
        }

        var processes = new RiotProcessController(paths);
        var ui = processes.FindClientUi();
        var service = processes.FindService();
        Console.WriteLine($"UI Riot     : {(ui is null ? "fermée" : $"ouverte (PID {ui.Id})")}");
        Console.WriteLine($"Service     : {(service is null ? "arrêté" : $"actif (PID {service.Id})")}");

        var authorization = new RiotLocalApi(paths).TryGetAuthorization();
        Console.WriteLine(authorization?.Subject is { Length: > 0 } subject
            ? $"API locale  : connectée (PUUID {subject})"
            : "API locale  : indisponible (client Riot non démarré ?)");

        var guard = new GameGuard().Check();
        Console.WriteLine($"Garde-fou   : {guard.Message}");
        Console.WriteLine($"Comptes     : {vault.ListAccounts().Count}");
        return ExitOk;
    }

    private static int Window(string[] args)
    {
        var window = RiotClientWindow.Find();
        if (window is null)
        {
            Console.WriteLine("Fenêtre Riot Client : aucune (client fermé, minimisé ou splash).");
            return ExitOk;
        }

        Console.WriteLine($"Fenêtre Riot Client : hwnd={window.Handle} pid={window.ProcessId}");
        Console.WriteLine($"Titre               : « {window.Title} »");
        Console.WriteLine($"Position            : {window.X},{window.Y} — {window.Width}x{window.Height}");
        Console.WriteLine($"Topmost             : {(window.IsTopMost ? "oui" : "non")}");
        return ExitOk;
    }

    private static int Doctor(string[] args)
    {
        var paths = RiotPaths.Discover();
        Console.WriteLine($"{AppInfo.DisplayName} {AppInfo.Version}");
        Console.WriteLine($"OS          : {Environment.OSVersion}");
        Console.WriteLine($"Install     : {paths.InstallRoot} (existe: {paths.InstallExists})");
        Console.WriteLine($"Client      : {paths.ClientExe} (existe: {paths.ClientExists})");
        Console.WriteLine($"Session     : {paths.LiveSessionFile} (existe: {paths.LiveSessionExists})");
        Console.WriteLine($"Profil      : {paths.ElectronProfileRoot} (existe: {paths.ElectronProfileExists})");
        Console.WriteLine($"Coffre      : {paths.VaultRoot}");

        var ok = paths.InstallExists;

        if (paths.LiveSessionExists)
        {
            try
            {
                var live = RiotSessionReader.ReadFile(paths.LiveSessionFile);
                Console.WriteLine($"Session     : format={live.Info.Format}, switchable={live.Info.CanSwitch}, compte={live.Info.RiotId ?? "?"}");
                if (!live.Info.CanSwitch)
                {
                    Console.WriteLine($"Attention   : {live.Info.UnsupportedReason}");
                    ok = false;
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine($"Session     : illisible ({ex.Message})");
                ok = false;
            }
        }
        else
        {
            Console.WriteLine("Session     : absente (connecte-toi dans le client Riot)");
        }

        var authorization = new RiotLocalApi(paths).TryGetAuthorization();
        Console.WriteLine(authorization?.Subject is { Length: > 0 } apiSubject
            ? $"API locale  : connectée (PUUID {apiSubject})"
            : "API locale  : indisponible");

        try
        {
            var test = Encoding.UTF8.GetBytes("riotswitch-dpapi-test");
            var protectedBytes = DpapiBundle.Protect(test);
            var roundtrip = DpapiBundle.Unprotect(protectedBytes);
            var dpapiOk = test.SequenceEqual(roundtrip);
            Console.WriteLine($"DPAPI       : {(dpapiOk ? "OK" : "incohérent")}");
            if (!dpapiOk) ok = false;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"DPAPI       : erreur ({ex.Message})");
            ok = false;
        }

        try
        {
            var vault = new SessionVault(paths);
            Console.WriteLine($"Comptes     : {vault.ListAccounts().Count}");
            Console.WriteLine($"Sauvegardes : {vault.ListBackups().Count}");
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Coffre      : erreur ({ex.Message})");
            ok = false;
        }

        try
        {
            var guard = new GameGuard().Check();
            Console.WriteLine($"Garde-fou   : {guard.Result} — {guard.Message}");
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Garde-fou   : erreur ({ex.Message})");
        }

        return ok ? ExitOk : ExitError;
    }

    private static int Restore(string[] args)
    {
        var fileName = args.FirstOrDefault(a => !a.StartsWith("--", StringComparison.Ordinal));
        if (string.IsNullOrWhiteSpace(fileName))
        {
            Console.Error.WriteLine("Usage : RiotSwitch.Cli restore <fichier.rsw>");
            return ExitTarget;
        }

        var paths = RiotPaths.Discover();
        var vault = new SessionVault(paths);
        var backup = vault.OpenBackup(fileName);

        if (!backup.Session.Info.HasSession)
        {
            Console.Error.WriteLine("La sauvegarde ne contient pas de session exploitable.");
            return ExitTarget;
        }

        var processes = new RiotProcessController(paths);
        if (processes.FindClientUi() is not null || processes.FindService() is not null)
        {
            Console.Error.WriteLine("Ferme complètement le client Riot avant de restaurer une sauvegarde.");
            return ExitAccess;
        }

        AtomicFile.WriteAllBytes(paths.LiveSessionFile, backup.Contents.YamlBytes);
        Console.WriteLine($"Sauvegarde restaurée : {backup.FileName}");
        Console.WriteLine($"Compte : {backup.Session.Info.RiotId ?? backup.Session.Info.Puuid ?? "?"}");
        return ExitOk;
    }

    private static int CheckUpdate(string[] args)
    {
        var client = new GitHubUpdateClient(
            AppInfo.GitHubOwner,
            AppInfo.GitHubRepositoryName,
            UpdateVersion.Parse(AppInfo.Version));

        var result = client.CheckAsync().GetAwaiter().GetResult();
        Console.WriteLine($"{AppInfo.DisplayName} {AppInfo.Version}");

        if (!result.Success)
        {
            Console.Error.WriteLine("Vérification impossible : " + result.Error);
            return ExitError;
        }

        if (result.UpdateAvailable && result.Update is { } update)
        {
            Console.WriteLine($"Mise à jour disponible : v{update.Version} (tag {update.Tag}).");
            Console.WriteLine($"Téléchargement : {update.AssetUrl}");
            return ExitOk;
        }

        Console.WriteLine("Aucune mise à jour disponible.");
        return ExitOk;
    }

    private static int Unknown(string command)
    {
        Console.Error.WriteLine($"Commande inconnue : {command}");
        PrintHelp();
        return ExitError;
    }

    private static void PrintHelp()
    {
        Console.WriteLine($"{AppInfo.DisplayName} — changement de compte Riot (ligne de commande)");
        Console.WriteLine();
        Console.WriteLine("Usage : RiotSwitch.Cli <commande> [options]");
        Console.WriteLine();
        Console.WriteLine("Commandes :");
        Console.WriteLine("  list | accounts                      Liste les comptes enregistrés.");
        Console.WriteLine("  capture [--label <nom>] [--profile]  Enregistre la session Riot active.");
        Console.WriteLine("  switch <id|libellé|RiotID>            Change de compte puis relance Riot.");
        Console.WriteLine("          [--product league|valorant|none] [--no-launch] [--yes]");
        Console.WriteLine("  status                                État du client et de la session.");
        Console.WriteLine("  doctor                                Diagnostic de l'installation et du coffre.");
        Console.WriteLine("  window                                Fenêtre Riot Client détectée (diagnostic).");
        Console.WriteLine("  restore <fichier.rsw>                 Restaure une sauvegarde (client fermé).");
        Console.WriteLine("  update                                Vérifie les mises à jour GitHub.");
        Console.WriteLine("  --help, --version");
        Console.WriteLine();
        Console.WriteLine("Codes de sortie : 0 OK, 1 erreur, 2 jeu en cours, 3 cible invalide, 4 accès refusé, 5 vérification.");
        Console.WriteLine("Conseil : connecte-toi une fois par compte dans le client Riot, puis capture chaque compte.");
    }

    private static string? ReadOption(string[] args, string name)
    {
        for (var i = 0; i < args.Length; i++)
        {
            if (string.Equals(args[i], name, StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length)
                return args[i + 1];
        }

        return null;
    }

    private static bool IsHelp(string arg) =>
        arg is "-h" or "--help" or "/?" or "help";

    private static bool IsVersion(string arg) =>
        arg is "-v" or "--version" or "version";

    private static string Truncate(string value, int length) =>
        value.Length <= length ? value : value[..Math.Max(0, length - 1)] + "…";
}
