namespace RiotSwitcher.Core.Updates;

/// <summary>Release GitHub correspondant à une mise à jour disponible.</summary>
public sealed record UpdateInfo(
    UpdateVersion Version,
    string Tag,
    string Name,
    string? Notes,
    Uri ReleasePage,
    Uri AssetUrl,
    Uri ChecksumUrl);

/// <summary>Résultat d'une vérification de mise à jour (réseau GitHub).</summary>
public sealed record UpdateCheckResult(
    bool Success,
    string CurrentVersion,
    UpdateInfo? Update,
    string? LatestTag,
    string? Error)
{
    public bool UpdateAvailable => Success && Update is not null;

    public static UpdateCheckResult NoUpdate(string currentVersion, string? latestTag) =>
        new(true, currentVersion, null, latestTag, null);

    public static UpdateCheckResult Available(string currentVersion, UpdateInfo update) =>
        new(true, currentVersion, update, update.Tag, null);

    public static UpdateCheckResult Failure(string currentVersion, string error) =>
        new(false, currentVersion, null, null, error);
}

/// <summary>Erreur contrôlée du pipeline de mise à jour.</summary>
public sealed class UpdateException : Exception
{
    public UpdateException(string message) : base(message)
    {
    }

    public UpdateException(string message, Exception innerException) : base(message, innerException)
    {
    }
}
