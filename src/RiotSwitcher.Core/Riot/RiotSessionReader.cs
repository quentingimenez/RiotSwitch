using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using RiotSwitcher.Core.Infrastructure;

namespace RiotSwitcher.Core.Riot;

/// <summary>
/// Lecteur ciblé de RiotGamesPrivateSettings.yaml. On n'écrit jamais ce fichier :
/// on le copie/restaure en bytes et on n'en extrait que des métadonnées.
/// </summary>
public static class RiotSessionReader
{
    private static readonly Regex IdTokenRegex = new(
        @"(?m)^[ \t]*id_token[ \t]*:[ \t]*['""]?([A-Za-z0-9_\-.]+)['""]?[ \t]*\r?$",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    private static readonly Regex RefreshTokenRegex = new(
        @"(?m)^[ \t]*refresh_token[ \t]*:[ \t]*['""]?([A-Za-z0-9_\-.]+)['""]?[ \t]*\r?$",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    private static readonly Regex DpopRegex = new(
        @"(?m)^[ \t]*is_dpop_bound[ \t]*:[ \t]*(true|false)\b",
        RegexOptions.Compiled | RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    private static readonly Regex PersistRegex = new(
        @"(?m)^[ \t]*persist[ \t]*:[ \t]*(true|false)\b",
        RegexOptions.Compiled | RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    private static readonly Regex PslRegex = new(
        @"(?m)^[ \t]*psl[ \t]*:[ \t]*\r?$",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    private static readonly Regex RiotClientRegex = new(
        @"(?m)^[ \t]*riot-client[ \t]*:[ \t]*\r?$",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    private static readonly Regex RiotLoginRegex = new(
        @"(?m)^[ \t]*riot-login[ \t]*:[ \t]*\r?$",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    private static readonly Regex CookiesRegex = new(
        @"(?m)^[ \t]*cookies[ \t]*:",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    private static readonly Regex SsidRegex = new(
        @"(?im)^[ \t]*-?[ \t]*name[ \t]*:[ \t]*['""]?ssid['""]?[ \t]*$|(?im)^[ \t]*ssid[ \t]*:",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    /// <summary>Lit le fichier, vérifie qu'il est stable (pas de write concurrent) et le parse.</summary>
    public static RiotSessionSnapshot ReadFile(
        string path,
        bool waitForStable = true,
        int attempts = 3,
        int delayMs = 120)
    {
        var bytes = AtomicFile.ReadAllBytes(path);
        var hash = Sha256Hex(bytes);

        if (waitForStable)
        {
            for (var i = 0; i < attempts; i++)
            {
                Thread.Sleep(delayMs);
                try
                {
                    var again = AtomicFile.ReadAllBytes(path);
                    var againHash = Sha256Hex(again);
                    if (againHash == hash) break;
                    bytes = again;
                    hash = againHash;
                }
                catch (IOException)
                {
                    // Le client est peut-être en train d'écrire ; on garde la dernière lecture.
                    break;
                }
            }
        }

        return Snapshot(bytes, path);
    }

    public static RiotSessionSnapshot Snapshot(byte[] bytes, string sourcePath)
    {
        if (bytes.Length == 0)
            throw new InvalidDataException("Le fichier de session est vide.");

        var text = Encoding.UTF8.GetString(bytes).TrimStart('\uFEFF');
        var info = Parse(text);
        return new RiotSessionSnapshot
        {
            YamlBytes = bytes,
            Text = text,
            Info = info,
            Sha256 = Sha256Hex(bytes),
            Length = bytes.LongLength,
            SourcePath = sourcePath,
            CapturedAtUtc = DateTimeOffset.UtcNow
        };
    }

    public static RiotSessionInfo Parse(string text)
    {
        var idToken = MatchValue(IdTokenRegex, text);
        var refreshToken = MatchValue(RefreshTokenRegex, text);
        var dpop = ParseBool(DpopRegex, text);
        var persist = ParseBool(PersistRegex, text);

        var hasPsl = PslRegex.IsMatch(text);
        var hasRiotClient = RiotClientRegex.IsMatch(text);
        var hasRiotLogin = RiotLoginRegex.IsMatch(text);
        var hasCookies = CookiesRegex.IsMatch(text);
        var hasSsid = SsidRegex.IsMatch(text);
        var hasLegacyCookies = hasSsid || (hasRiotLogin && hasCookies);

        var format = hasPsl && hasRiotClient
            ? RiotSessionFormat.PslV1
            : hasLegacyCookies
                ? RiotSessionFormat.LegacyCookies
                : RiotSessionFormat.Unknown;

        return new RiotSessionInfo
        {
            Format = format,
            HasIdToken = !string.IsNullOrWhiteSpace(idToken),
            HasRefreshToken = !string.IsNullOrWhiteSpace(refreshToken),
            HasLegacyCookies = hasLegacyCookies,
            IsDpopBound = dpop == true,
            Persist = persist,
            IdToken = idToken,
            RefreshToken = refreshToken,
            Identity = RiotTokenInspector.DecodeIdToken(idToken)
        };
    }

    public static string Sha256Hex(ReadOnlySpan<byte> data)
    {
        var hash = SHA256.HashData(data);
        return Convert.ToHexString(hash).ToLowerInvariant();
    }

    private static string? MatchValue(Regex regex, string text)
    {
        var match = regex.Match(text);
        return match.Success ? match.Groups[1].Value : null;
    }

    private static bool? ParseBool(Regex regex, string text)
    {
        var match = regex.Match(text);
        if (!match.Success) return null;
        return string.Equals(match.Groups[1].Value, "true", StringComparison.OrdinalIgnoreCase);
    }
}
