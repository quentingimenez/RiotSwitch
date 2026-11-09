using RiotSwitcher.Core;
using RiotSwitcher.Core.Infrastructure;
using RiotSwitcher.Core.Riot;
using RiotSwitcher.Core.Settings;
using RiotSwitcher.Core.Updates;

namespace RiotSwitcher.App.Updates;

/// <summary>
/// Orchestration de la vérification et du téléchargement des mises à jour.
/// Le dernier résultat disponible est partagé entre le veilleur et la fenêtre Paramètres.
/// </summary>
internal static class UpdateState
{
    private static readonly SemaphoreSlim Gate = new(1, 1);
    private static UpdateInfo? _pending;

    public static UpdateInfo? Pending => _pending;

    public static async Task<UpdateCheckResult> CheckAsync(
        RiotPaths paths,
        AppSettings settings,
        SettingsStore settingsStore,
        IAppLogger logger,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(paths);
        ArgumentNullException.ThrowIfNull(settings);
        ArgumentNullException.ThrowIfNull(settingsStore);

        await Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var client = CreateClient();
            logger.Info($"Vérification des mises à jour (version {AppInfo.Version}).");
            var result = await client.CheckAsync(cancellationToken).ConfigureAwait(false);

            settings.LastUpdateCheckUtc = DateTimeOffset.UtcNow;
            settingsStore.Save(settings);

            if (result.UpdateAvailable && result.Update is not null)
            {
                _pending = result.Update;
                logger.Info($"Mise à jour disponible : v{result.Update.Version} (tag {result.Update.Tag}).");
            }
            else if (result.Success)
            {
                _pending = null;
                logger.Info($"RiotSwitch est à jour (version {AppInfo.Version}).");
            }
            else
            {
                logger.Warn("Vérification des mises à jour impossible : " + result.Error);
            }

            return result;
        }
        finally
        {
            Gate.Release();
        }
    }

    /// <summary>Télécharge, vérifie et extrait la mise à jour ; retourne le dossier de staging.</summary>
    public static async Task<string> DownloadAndPrepareAsync(
        RiotPaths paths,
        UpdateInfo update,
        IProgress<double>? progress,
        IAppLogger logger,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(paths);
        ArgumentNullException.ThrowIfNull(update);

        var updatesRoot = Path.Combine(paths.VaultRoot, "updates");
        var versionDirectory = Path.Combine(updatesRoot, update.Version.ToString());
        var stagingDirectory = Path.Combine(versionDirectory, "staging");
        var archivePath = Path.Combine(versionDirectory, AppInfo.UpdateAssetName);

        Directory.CreateDirectory(versionDirectory);
        if (Directory.Exists(stagingDirectory))
        {
            Directory.Delete(stagingDirectory, recursive: true);
        }

        var client = CreateClient();
        logger.Info($"Téléchargement de RiotSwitch v{update.Version}.");
        await client.DownloadAndVerifyAsync(update, archivePath, progress, cancellationToken).ConfigureAwait(false);

        ZipSafeExtractor.ExtractToDirectory(archivePath, stagingDirectory);
        if (!File.Exists(Path.Combine(stagingDirectory, "RiotSwitch.exe")))
        {
            throw new UpdateException("L'archive de mise à jour ne contient pas RiotSwitch.exe.");
        }

        logger.Info($"Mise à jour v{update.Version} téléchargée et vérifiée.");
        return stagingDirectory;
    }

    private static GitHubUpdateClient CreateClient() =>
        new(
            AppInfo.GitHubOwner,
            AppInfo.GitHubRepositoryName,
            UpdateVersion.Parse(AppInfo.Version));
}
