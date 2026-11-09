namespace RiotSwitcher.Core.Riot;

/// <summary>
/// Tous les chemins utilisés par RiotSwitch. Les chemins d'installation, de données
/// utilisateur et de coffre sont injectables pour les tests.
/// </summary>
public sealed class RiotPaths
{
    public string InstallRoot { get; }
    public string UserDataRoot { get; }
    public string ElectronProfileRoot { get; }
    public string VaultRoot { get; }
    public string ProgramDataRoot { get; }

    public RiotPaths(
        string installRoot,
        string userDataRoot,
        string electronProfileRoot,
        string vaultRoot,
        string? programDataRoot = null)
    {
        if (string.IsNullOrWhiteSpace(installRoot))
            throw new ArgumentException("Le dossier d'installation Riot est requis.", nameof(installRoot));
        if (string.IsNullOrWhiteSpace(userDataRoot))
            throw new ArgumentException("Le dossier de données Riot est requis.", nameof(userDataRoot));
        if (string.IsNullOrWhiteSpace(electronProfileRoot))
            throw new ArgumentException("Le profil Electron Riot est requis.", nameof(electronProfileRoot));
        if (string.IsNullOrWhiteSpace(vaultRoot))
            throw new ArgumentException("Le dossier du coffre est requis.", nameof(vaultRoot));

        InstallRoot = Path.GetFullPath(installRoot);
        UserDataRoot = Path.GetFullPath(userDataRoot);
        ElectronProfileRoot = Path.GetFullPath(electronProfileRoot);
        VaultRoot = Path.GetFullPath(vaultRoot);
        ProgramDataRoot = Path.GetFullPath(programDataRoot ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
            "Riot Games"));
    }

    // Installation Riot Client -------------------------------------------------
    public string ServiceExe => Path.Combine(InstallRoot, "RiotClientServices.exe");
    public string ClientExe => Path.Combine(InstallRoot, "RiotClientElectron", "Riot Client.exe");
    public string CrashHandlerExe => Path.Combine(InstallRoot, "RiotClientCrashHandler.exe");
    public string UninstallExe => Path.Combine(InstallRoot, "RiotClientUninstaller.exe");

    // Données utilisateur Riot -------------------------------------------------
    public string DataDir => Path.Combine(UserDataRoot, "Data");
    public string LiveSessionFile => Path.Combine(DataDir, "RiotGamesPrivateSettings.yaml");
    public string SessionsDir => Path.Combine(DataDir, "Sessions");
    public string ConfigDir => Path.Combine(UserDataRoot, "Config");
    public string LockfilePath => Path.Combine(ConfigDir, "lockfile");
    public string SettingsYamlPath => Path.Combine(ConfigDir, "RiotClientSettings.yaml");
    public string LogsDir => Path.Combine(UserDataRoot, "Logs");
    public string ElectronLogsDir => Path.Combine(LogsDir, "Riot Client Electron Logs");

    // Profil Electron (contingence uniquement) ---------------------------------
    public string ElectronCookiesFile => Path.Combine(ElectronProfileRoot, "Network", "Cookies");
    public string ElectronCookiesJournalFile => Path.Combine(ElectronProfileRoot, "Network", "Cookies-journal");
    public string ElectronLocalStorageDir => Path.Combine(ElectronProfileRoot, "Local Storage", "leveldb");

    // Coffre RiotSwitch --------------------------------------------------------
    public string AccountsFile => Path.Combine(VaultRoot, "accounts.json");
    public string SessionsVaultDir => Path.Combine(VaultRoot, "sessions");
    public string BackupsDir => Path.Combine(VaultRoot, "backups");
    public string SettingsFile => Path.Combine(VaultRoot, "settings.json");
    public string JournalFile => Path.Combine(VaultRoot, "switch-journal.json");
    public string VaultLogsDir => Path.Combine(VaultRoot, "logs");
    public string AppLogFile => Path.Combine(VaultLogsDir, "app.log");

    public bool InstallExists => File.Exists(ServiceExe);
    public bool ClientExists => File.Exists(ClientExe);
    public bool LiveSessionExists => File.Exists(LiveSessionFile);
    public bool ElectronProfileExists => Directory.Exists(ElectronProfileRoot);

    public void EnsureVaultDirectories()
    {
        Directory.CreateDirectory(VaultRoot);
        Directory.CreateDirectory(SessionsVaultDir);
        Directory.CreateDirectory(BackupsDir);
        Directory.CreateDirectory(VaultLogsDir);
    }

    /// <summary>Découvre l'installation Riot et les dossiers de données.</summary>
    public static RiotPaths Discover(
        string? installRoot = null,
        string? userDataRoot = null,
        string? electronProfileRoot = null,
        string? vaultRoot = null,
        string? programDataRoot = null)
    {
        var install = installRoot ?? RiotInstallLocator.FindInstallRoot(programDataRoot);
        if (string.IsNullOrWhiteSpace(install))
            throw new RiotNotInstalledException(
                "Riot Client est introuvable. Vérifie que Riot Client est installé, puis relance RiotSwitch.");

        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var roaming = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);

        var profile = electronProfileRoot ?? PickElectronProfileRoot(roaming);
        var userData = userDataRoot ?? Path.Combine(local, "Riot Games", "Riot Client");
        var vault = vaultRoot ?? Path.Combine(local, "RiotSwitch");

        return new RiotPaths(install, userData, profile, vault, programDataRoot);
    }

    private static string PickElectronProfileRoot(string roaming)
    {
        var current = Path.Combine(roaming, "Riot Client");
        if (Directory.Exists(current)) return current;
        var legacy = Path.Combine(roaming, "riot-client-ux");
        if (Directory.Exists(legacy)) return legacy;
        return current;
    }
}

public sealed class RiotNotInstalledException : Exception
{
    public RiotNotInstalledException(string message) : base(message) { }
    public RiotNotInstalledException(string message, Exception inner) : base(message, inner) { }
}
