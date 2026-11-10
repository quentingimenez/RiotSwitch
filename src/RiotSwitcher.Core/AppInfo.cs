namespace RiotSwitcher.Core;

public static class AppInfo
{
    public const string ProductName = "RiotSwitch";
    public const string DisplayName = "RiotSwitch";
    public const string Version = "1.1.17";

    /// <summary>
    /// Vrai pour l'exécutable autonome (single-file) : les dépendances managées
    /// sont embarquées, donc aucun RiotSwitcher.Core.dll n'est posé à côté de l'exe.
    /// L'auto-update de type dossier n'est alors pas proposée.
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

    /// <summary>Dépôt GitHub public utilisé pour les releases et l'auto-update.</summary>
    public const string GitHubOwner = "quentingimenez";
    public const string GitHubRepositoryName = "RiotSwitch";
    public const string GitHubRepositoryUrl = "https://github.com/quentingimenez/RiotSwitch";

    /// <summary>Nom exact de l'asset de release attendu par l'auto-update.</summary>
    public const string UpdateAssetName = "RiotSwitch-win-x64.zip";
    public const string UpdateChecksumAssetName = "RiotSwitch-win-x64.zip.sha256";

    public const string WatchMutexName = @"Local\RiotSwitch.Watch";
    public const string SwitchMutexName = @"Local\RiotSwitch.Switch";
    public const string VaultMutexName = @"Local\RiotSwitch.Vault";

    /// <summary>Événement posé pendant un switch (pour que le mode zéro fond ne quitte pas).</summary>
    public const string SwitchingEventName = @"Local\RiotSwitch.Switching";

    /// <summary>Titre de la fenêtre cachée du veilleur (FindWindow).</summary>
    public const string WatchWindowTitle = "RiotSwitch.Watch";

    public const string SettingsTitle = "RiotSwitch — Paramètres";
    public const string AccountsPanelTitle = "Comptes Riot";
    public const string DataFolderName = "RiotSwitch";
}
