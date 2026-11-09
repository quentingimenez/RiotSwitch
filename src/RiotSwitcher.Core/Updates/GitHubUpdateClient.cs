using System.Globalization;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace RiotSwitcher.Core.Updates;

/// <summary>
/// Client minimal de l'API GitHub Releases et des assets de release.
/// Aucune donnée personnelle n'est envoyée : seuls le dépôt et la version courante sont lus.
/// </summary>
public sealed class GitHubUpdateClient
{
    private static readonly Regex Sha256Pattern = new(
        @"\b[0-9a-fA-F]{64}\b",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    private readonly HttpClient _http;
    private readonly string _owner;
    private readonly string _repository;
    private readonly UpdateVersion _currentVersion;

    public GitHubUpdateClient(
        string owner,
        string repository,
        UpdateVersion currentVersion,
        HttpMessageHandler? handler = null)
    {
        if (string.IsNullOrWhiteSpace(owner)) throw new ArgumentException("Owner GitHub manquant.", nameof(owner));
        if (string.IsNullOrWhiteSpace(repository)) throw new ArgumentException("Dépôt GitHub manquant.", nameof(repository));

        _owner = owner.Trim();
        _repository = repository.Trim();
        _currentVersion = currentVersion;

        _http = handler is null ? new HttpClient() : new HttpClient(handler, disposeHandler: false);
        _http.BaseAddress = new Uri("https://api.github.com/", UriKind.Absolute);
        _http.Timeout = TimeSpan.FromMinutes(5);
        _http.DefaultRequestHeaders.UserAgent.ParseAdd($"RiotSwitch/{AppInfo.Version}");
        _http.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
    }

    public async Task<UpdateCheckResult> CheckAsync(CancellationToken cancellationToken = default)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(15));

        try
        {
            var url = $"repos/{Uri.EscapeDataString(_owner)}/{Uri.EscapeDataString(_repository)}/releases/latest";
            using var response = await _http.GetAsync(url, timeout.Token).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
            {
                return UpdateCheckResult.Failure(
                    _currentVersion.ToString(),
                    $"GitHub a répondu {(int)response.StatusCode} ({response.ReasonPhrase}).");
            }

            await using var stream = await response.Content.ReadAsStreamAsync(timeout.Token).ConfigureAwait(false);
            using var document = await JsonDocument.ParseAsync(stream, cancellationToken: timeout.Token)
                .ConfigureAwait(false);

            return ParseRelease(document.RootElement);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return UpdateCheckResult.Failure(_currentVersion.ToString(), "Délai de vérification GitHub dépassé.");
        }
        catch (HttpRequestException ex)
        {
            return UpdateCheckResult.Failure(
                _currentVersion.ToString(),
                "Connexion à GitHub impossible : " + ex.Message);
        }
        catch (JsonException ex)
        {
            return UpdateCheckResult.Failure(
                _currentVersion.ToString(),
                "Réponse GitHub illisible : " + ex.Message);
        }
    }

    private UpdateCheckResult ParseRelease(JsonElement root)
    {
        var tag = GetString(root, "tag_name");
        if (string.IsNullOrWhiteSpace(tag))
        {
            return UpdateCheckResult.Failure(_currentVersion.ToString(), "La release GitHub n'a pas de tag.");
        }

        if (!UpdateVersion.TryParse(tag, out var latestVersion))
        {
            return UpdateCheckResult.Failure(
                _currentVersion.ToString(),
                $"Tag de release non reconnu : « {tag} ».");
        }

        if (latestVersion <= _currentVersion)
        {
            return UpdateCheckResult.NoUpdate(_currentVersion.ToString(), tag);
        }

        if (!root.TryGetProperty("assets", out var assetsElement) ||
            assetsElement.ValueKind != JsonValueKind.Array)
        {
            return UpdateCheckResult.Failure(
                _currentVersion.ToString(),
                "La release GitHub ne contient aucun asset.");
        }

        JsonElement? asset = null;
        JsonElement? checksumAsset = null;

        foreach (var candidate in assetsElement.EnumerateArray())
        {
            var name = GetString(candidate, "name");
            if (string.Equals(name, AppInfo.UpdateAssetName, StringComparison.OrdinalIgnoreCase))
            {
                asset = candidate;
            }
            else if (string.Equals(name, AppInfo.UpdateChecksumAssetName, StringComparison.OrdinalIgnoreCase))
            {
                checksumAsset = candidate;
            }
        }

        if (asset is null)
        {
            return UpdateCheckResult.Failure(
                _currentVersion.ToString(),
                $"L'asset « {AppInfo.UpdateAssetName} » est absent de la release {tag}.");
        }

        if (checksumAsset is null)
        {
            return UpdateCheckResult.Failure(
                _currentVersion.ToString(),
                $"L'asset de checksum « {AppInfo.UpdateChecksumAssetName} » est absent de la release {tag}.");
        }

        if (!TryGetHttpsUri(asset.Value, "browser_download_url", out var assetUrl) ||
            !TryGetHttpsUri(checksumAsset.Value, "browser_download_url", out var checksumUrl))
        {
            return UpdateCheckResult.Failure(
                _currentVersion.ToString(),
                "URL de téléchargement absente ou invalide dans la release GitHub.");
        }

        var releasePage = TryGetHttpsUri(root, "html_url", out var page)
            ? page!
            : new Uri(AppInfo.GitHubRepositoryUrl + "/releases", UriKind.Absolute);

        var info = new UpdateInfo(
            latestVersion,
            tag,
            GetString(root, "name") ?? tag,
            GetString(root, "body"),
            releasePage,
            assetUrl!,
            checksumUrl!);

        return UpdateCheckResult.Available(_currentVersion.ToString(), info);
    }

    /// <summary>
    /// Télécharge l'asset de release et vérifie son empreinte SHA-256 avant de le déplacer
    /// vers <paramref name="destinationZipPath"/>. Retourne le chemin du fichier vérifié.
    /// </summary>
    public async Task<string> DownloadAndVerifyAsync(
        UpdateInfo update,
        string destinationZipPath,
        IProgress<double>? progress = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(update);
        ArgumentException.ThrowIfNullOrWhiteSpace(destinationZipPath);

        var directory = Path.GetDirectoryName(Path.GetFullPath(destinationZipPath));
        if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);

        var expectedSha256 = await ReadChecksumAsync(update.ChecksumUrl, cancellationToken).ConfigureAwait(false);
        var temporaryPath = destinationZipPath + ".part";

        try
        {
            using var response = await _http
                .GetAsync(update.AssetUrl, HttpCompletionOption.ResponseHeadersRead, cancellationToken)
                .ConfigureAwait(false);
            response.EnsureSuccessStatusCode();

            var totalLength = response.Content.Headers.ContentLength ?? -1;
            using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);

            await using (var input = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false))
            await using (var output = new FileStream(
                             temporaryPath,
                             FileMode.Create,
                             FileAccess.Write,
                             FileShare.None,
                             bufferSize: 81920,
                             useAsync: true))
            {
                var buffer = new byte[81920];
                long totalRead = 0;
                int read;
                while ((read = await input.ReadAsync(buffer, cancellationToken).ConfigureAwait(false)) > 0)
                {
                    await output.WriteAsync(buffer.AsMemory(0, read), cancellationToken).ConfigureAwait(false);
                    hash.AppendData(buffer, 0, read);
                    totalRead += read;

                    if (totalLength > 0)
                    {
                        progress?.Report(Math.Min(1d, totalRead / (double)totalLength));
                    }
                }

                await output.FlushAsync(cancellationToken).ConfigureAwait(false);
            }

            var actualSha256 = Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant();
            if (!string.Equals(actualSha256, expectedSha256, StringComparison.OrdinalIgnoreCase))
            {
                throw new UpdateException(
                    "Checksum SHA-256 invalide : le fichier téléchargé est corrompu ou a été modifié.");
            }

            File.Move(temporaryPath, destinationZipPath, overwrite: true);
            progress?.Report(1d);
            return destinationZipPath;
        }
        catch
        {
            TryDelete(temporaryPath);
            throw;
        }
    }

    private async Task<string> ReadChecksumAsync(Uri checksumUrl, CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(15));

        using var response = await _http.GetAsync(checksumUrl, timeout.Token).ConfigureAwait(false);
        response.EnsureSuccessStatusCode();

        var text = await response.Content.ReadAsStringAsync(timeout.Token).ConfigureAwait(false);
        var match = Sha256Pattern.Match(text);
        if (!match.Success)
        {
            throw new UpdateException("Le fichier de checksum SHA-256 est illisible.");
        }

        return match.Value.ToLowerInvariant();
    }

    private static string? GetString(JsonElement element, string propertyName) =>
        element.TryGetProperty(propertyName, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;

    private static bool TryGetHttpsUri(JsonElement element, string propertyName, out Uri? uri)
    {
        uri = null;
        var value = GetString(element, propertyName);
        if (string.IsNullOrWhiteSpace(value)) return false;

        if (!Uri.TryCreate(value, UriKind.Absolute, out var parsed)) return false;
        if (!string.Equals(parsed.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase)) return false;

        uri = parsed;
        return true;
    }

    private static void TryDelete(string path)
    {
        try
        {
            if (File.Exists(path)) File.Delete(path);
        }
        catch
        {
            // Fichier temporaire : nettoyage best-effort.
        }
    }
}
