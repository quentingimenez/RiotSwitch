namespace RiotSwitcher.Core;

public static class AppInfo
{
    public const string ProductName = "RiotSwitch";
    public const string DisplayName = "RiotSwitch";
    public const string Version = "1.1.9";

    /// <summary>
    /// Vrai pour l'exÃ©cutable autonome (single-file) : les dÃ©pendances managÃ©es
    /// sont embarquÃ©es, donc aucun RiotSwitcher.Core.dll n'est posÃ© Ã  cÃ´tÃ© de l'exe.
    /// L'auto-update de type dossier n'est alors pas proposÃ©e.
    /// </summary>
    public static bool IsPortableSingleFile
    {
        get
        {
            try
            {
                return !File.Exists(Path.Combine(AppContext.BaseDirectory, "RiotSwitcher.Core.dll"));
            }
            catch
            {
                return false;
            }
        }
    }

    /// <summary>DÃƒÂ©pÃƒÂ´t GitHub public utilisÃƒÂ© pour les releases et l'auto-update.</summary>
    public const string GitHubOwner = "quentingimenez";
    public const string GitHubRepositoryName = "RiotSwitch";
    public const string GitHubRepositoryUrl = "https://github.com/quentingimenez/RiotSwitch";

    /// <summary>Nom exact de l'asset de release attendu par l'auto-update.</summary>
    public const string UpdateAssetName = "RiotSwitch-win-x64.zip";
    public const string UpdateChecksumAssetName = "RiotSwitch-win-x64.zip.sha256";

    public const string WatchMutexName = @"Local\RiotSwitch.Watch";
    public const string SwitchMutexName = @"Local\RiotSwitch.Switch";
    public const string VaultMutexName = @"Local\RiotSwitch.Vault";

    /// <summary>Ãƒâ€°vÃƒÂ©nement posÃƒÂ© pendant un switch (pour que le mode zÃƒÂ©ro fond ne quitte pas).</summary>
    public const string SwitchingEventName = @"Local\RiotSwitch.Switching";

    /// <summary>Titre de la fenÃƒÂªtre cachÃƒÂ©e du veilleur (FindWindow).</summary>
    public const string WatchWindowTitle = "RiotSwitch.Watch";

    public const string SettingsTitle = "RiotSwitch — Paramètres";
    public const string AccountsPanelTitle = "Comptes Riot";
    public const string DataFolderName = "RiotSwitch";
}
