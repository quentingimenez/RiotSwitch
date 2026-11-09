using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;

namespace RiotSwitcher.Core.Riot;

/// <summary>
/// Résultat minimal de l'API locale du client Riot (endpoint /rso-auth/v1/authorization).
/// </summary>
public sealed record RiotAuthorizationInfo(string? Subject, string? PlatformId, long? AccountId)
{
    public string? Puuid => Subject;
}

/// <summary>
/// Accès en lecture seule à l'API locale du client Riot, authentifiée par le lockfile.
/// Sans cette API, on ne peut pas vérifier quel compte est réellement connecté après un switch.
/// </summary>
public interface IRiotLocalApi
{
    RiotAuthorizationInfo? TryGetAuthorization(TimeSpan? timeout = null);

    /// <summary>
    /// Demande au service Riot d'afficher l'interface du client (utile quand le service
    /// tourne déjà mais que l'interface Electron a été fermée).
    /// </summary>
    bool TryShowClient(TimeSpan? timeout = null);
}

public sealed class RiotLocalApi : IRiotLocalApi
{
    private readonly RiotPaths _paths;

    public RiotLocalApi(RiotPaths paths)
    {
        _paths = paths ?? throw new ArgumentNullException(nameof(paths));
    }

    public RiotAuthorizationInfo? TryGetAuthorization(TimeSpan? timeout = null)
    {
        try
        {
            var lockfile = ReadLockfile();
            if (lockfile is null) return null;

            using var client = CreateClient(timeout);
            using var request = CreateRequest(HttpMethod.Get, lockfile.Value, "/rso-auth/v1/authorization");
            using var response = client.Send(request);
            if (!response.IsSuccessStatusCode) return null;

            using var stream = response.Content.ReadAsStream();
            using var document = JsonDocument.Parse(stream);
            var root = document.RootElement;

            var subject = GetString(root, "subject");
            if (string.IsNullOrWhiteSpace(subject)) return null;

            return new RiotAuthorizationInfo(
                subject,
                GetString(root, "currentPlatformId"),
                GetLong(root, "currentAccountId"));
        }
        catch (Exception ex) when (IsExpectedApiException(ex))
        {
            return null;
        }
    }

    public bool TryShowClient(TimeSpan? timeout = null)
    {
        try
        {
            var lockfile = ReadLockfile();
            if (lockfile is null) return false;

            using var client = CreateClient(timeout);
            using var request = CreateRequest(HttpMethod.Post, lockfile.Value, "/riot-client-lifecycle/v1/show");
            request.Content = new ByteArrayContent(Array.Empty<byte>());
            using var response = client.Send(request);
            return response.IsSuccessStatusCode;
        }
        catch (Exception ex) when (IsExpectedApiException(ex))
        {
            return false;
        }
    }

    private static HttpClient CreateClient(TimeSpan? timeout)
    {
        var handler = new HttpClientHandler
        {
            UseProxy = false,
            ServerCertificateCustomValidationCallback = static (_, _, _, _) => true
        };

        return new HttpClient(handler)
        {
            Timeout = timeout ?? TimeSpan.FromSeconds(2)
        };
    }

    private static HttpRequestMessage CreateRequest(HttpMethod method, LockfileInfo lockfile, string path)
    {
        var request = new HttpRequestMessage(
            method,
            $"{lockfile.Protocol}://127.0.0.1:{lockfile.Port}{path}");
        var credentials = Convert.ToBase64String(
            Encoding.ASCII.GetBytes($"riot:{lockfile.Password}"));
        request.Headers.Authorization = new AuthenticationHeaderValue("Basic", credentials);
        return request;
    }

    private static bool IsExpectedApiException(Exception ex)
        => ex is IOException
            or UnauthorizedAccessException
            or HttpRequestException
            or TaskCanceledException
            or OperationCanceledException
            or JsonException
            or InvalidOperationException
            or FormatException
            or NotSupportedException;

    private LockfileInfo? ReadLockfile()
    {
        if (!File.Exists(_paths.LockfilePath)) return null;

        string text;
        using (var stream = new FileStream(
                   _paths.LockfilePath,
                   FileMode.Open,
                   FileAccess.Read,
                   FileShare.ReadWrite | FileShare.Delete))
        using (var reader = new StreamReader(stream, Encoding.UTF8))
        {
            text = reader.ReadToEnd();
        }

        var parts = text.Trim().Split(':');
        if (parts.Length < 5) return null;

        if (!int.TryParse(parts[2], out var port) || port <= 0 || port > 65535) return null;

        var protocol = parts[4].Trim().ToLowerInvariant();
        if (protocol is not ("https" or "http")) return null;

        // Le mot de passe peut théoriquement contenir des ':' : le protocole est toujours le dernier champ.
        var password = string.Join(":", parts, 3, parts.Length - 4);
        if (string.IsNullOrEmpty(password)) return null;

        return new LockfileInfo(protocol, port, password);
    }

    private static string? GetString(JsonElement element, string property)
        => element.TryGetProperty(property, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;

    private static long? GetLong(JsonElement element, string property)
        => element.TryGetProperty(property, out var value) && value.ValueKind == JsonValueKind.Number &&
           value.TryGetInt64(out var number)
            ? number
            : null;

    private readonly record struct LockfileInfo(string Protocol, int Port, string Password);
}
