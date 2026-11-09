using System.Text;
using System.Text.Json;

namespace RiotSwitcher.Core.Riot;

/// <summary>
/// Décode la partie payload d'un JWT (sans vérifier la signature : on ne fait
/// qu'afficher des métadonnées locales, jamais de validation d'authentification).
/// </summary>
public static class RiotTokenInspector
{
    public static RiotIdTokenInfo? DecodeIdToken(string? jwt)
    {
        if (string.IsNullOrWhiteSpace(jwt)) return null;

        try
        {
            var parts = jwt.Split('.');
            if (parts.Length < 2) return null;

            var payload = Base64UrlDecode(parts[1]);
            using var doc = JsonDocument.Parse(payload);
            var root = doc.RootElement;

            var puuid = GetString(root, "sub");
            var locale = GetString(root, "player_locale") ?? GetString(root, "locale");
            var country = GetString(root, "country") ?? GetString(root, "login_country");
            var region = GetString(root, "lol_region") ?? GetString(root, "region");

            string? gameName = null;
            string? tagLine = null;
            if (root.TryGetProperty("acct", out var acct) && acct.ValueKind == JsonValueKind.Object)
            {
                gameName = GetString(acct, "game_name");
                tagLine = GetString(acct, "tag_line");
            }

            var exp = GetUnixTime(root, "exp");
            var iat = GetUnixTime(root, "iat");

            return new RiotIdTokenInfo(puuid, gameName, tagLine, locale, country, region, exp, iat);
        }
        catch
        {
            return null;
        }
    }

    private static string? GetString(JsonElement element, string propertyName)
    {
        if (!element.TryGetProperty(propertyName, out var value)) return null;
        return value.ValueKind switch
        {
            JsonValueKind.String => value.GetString(),
            JsonValueKind.Number => value.ToString(),
            _ => null
        };
    }

    private static DateTimeOffset? GetUnixTime(JsonElement element, string propertyName)
    {
        if (!element.TryGetProperty(propertyName, out var value)) return null;
        if (value.ValueKind != JsonValueKind.Number) return null;
        if (!value.TryGetInt64(out var seconds)) return null;
        if (seconds <= 0 || seconds > 253402300799) return null;
        return DateTimeOffset.FromUnixTimeSeconds(seconds);
    }

    private static byte[] Base64UrlDecode(string text)
    {
        var normalized = text.Replace('-', '+').Replace('_', '/');
        var padding = normalized.Length % 4;
        if (padding == 2) normalized += "==";
        else if (padding == 3) normalized += "=";
        else if (padding == 1) throw new FormatException("Base64url invalide.");

        return Convert.FromBase64String(normalized);
    }
}
