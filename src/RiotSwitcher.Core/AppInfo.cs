namespace RiotSwitcher.Core;

public static class AppInfo
{
    public const string ProductName = "RiotSwitch";
    public const string DisplayName = "RiotSwitch";
    public const string Version = "1.1.2";

    /// <summary>DÃ©pÃ´t GitHub public utilisÃ© pour les releases et l'auto-update.</summary>
    public const string GitHubOwner = "quentingimenez";
    public const string GitHubRepositoryName = "RiotSwitch";
    public const string GitHubRepositoryUrl = "https://github.com/quentingimenez/RiotSwitch";

    /// <summary>Nom exact de l'asset de release attendu par l'auto-update.</summary>
    public const string UpdateAssetName = "RiotSwitch-win-x64.zip";
    public const string UpdateChecksumAssetName = "RiotSwitch-win-x64.zip.sha256";

    public const string WatchMutexName = @"Local\RiotSwitch.Watch";
    public const string SwitchMutexName = @"Local\RiotSwitch.Switch";
    public const string VaultMutexName = @"Local\RiotSwitch.Vault";

    /// <summary>Ã‰vÃ©nement posÃ© pendant un switch (pour que le mode zÃ©ro fond ne quitte pas).</summary>
    public const string SwitchingEventName = @"Local\RiotSwitch.Switching";

    /// <summary>Titre de la fenÃªtre cachÃ©e du veilleur (FindWindow).</summary>
    public const string WatchWindowTitle = "RiotSwitch.Watch";

    public const string SettingsTitle = "RiotSwitch â€” ParamÃ¨tres";
    public const string AccountsPanelTitle = "Comptes Riot";
    public const string DataFolderName = "RiotSwitch";
}
