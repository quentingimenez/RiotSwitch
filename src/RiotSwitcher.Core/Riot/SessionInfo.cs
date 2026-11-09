namespace RiotSwitcher.Core.Riot;

public enum RiotSessionFormat
{
    Unknown = 0,
    PslV1 = 1,
    LegacyCookies = 2
}

public sealed record RiotIdTokenInfo(
    string? Puuid,
    string? GameName,
    string? TagLine,
    string? Locale,
    string? Country,
    string? Region,
    DateTimeOffset? ExpiresUtc,
    DateTimeOffset? IssuedUtc)
{
    public string? RiotId
    {
        get
        {
            if (string.IsNullOrWhiteSpace(GameName)) return null;
            return string.IsNullOrWhiteSpace(TagLine) ? GameName : $"{GameName}#{TagLine}";
        }
    }
}

public sealed class RiotSessionInfo
{
    public RiotSessionFormat Format { get; init; } = RiotSessionFormat.Unknown;
    public bool IsDpopBound { get; init; }
    public bool HasIdToken { get; init; }
    public bool HasRefreshToken { get; init; }
    public bool HasLegacyCookies { get; init; }
    public bool? Persist { get; init; }
    public string? IdToken { get; init; }
    public string? RefreshToken { get; init; }
    public RiotIdTokenInfo? Identity { get; init; }

    public string? Puuid => Identity?.Puuid;
    public string? RiotId => Identity?.RiotId;
    public string? Locale => Identity?.Locale;
    public string? Country => Identity?.Country;
    public string? Region => Identity?.Region;

    public bool HasSession => HasIdToken || HasRefreshToken || HasLegacyCookies;

    public bool IsPersistent => Persist != false;

    /// <summary>La session peut être copiée puis restaurée par RiotSwitch.</summary>
    public bool CanSwitch
    {
        get
        {
            if (IsDpopBound || !IsPersistent) return false;
            return Format switch
            {
                RiotSessionFormat.PslV1 => HasIdToken && HasRefreshToken,
                // L'ancien format cookies est accepté en best-effort : aucun sub à vérifier,
                // mais le fichier entier reste restaurable.
                RiotSessionFormat.LegacyCookies => HasLegacyCookies,
                _ => false
            };
        }
    }

    public string? UnsupportedReason
    {
        get
        {
            if (Format == RiotSessionFormat.Unknown)
                return "Format de session non reconnu.";
            if (IsDpopBound)
                return "Session liée par DPoP (non portable entre clients).";
            if (!IsPersistent)
                return "Session non persistante : active « Rester connecté » dans Riot Client.";
            if (Format == RiotSessionFormat.PslV1 && !HasIdToken)
                return "Jeton d'identité (id_token) absent.";
            if (Format == RiotSessionFormat.PslV1 && !HasRefreshToken)
                return "Refresh token absent : reconnexion manuelle nécessaire.";
            if (Format == RiotSessionFormat.LegacyCookies && !HasLegacyCookies)
                return "Cookie de session absent.";
            return null;
        }
    }
}

public sealed class RiotSessionSnapshot
{
    public required byte[] YamlBytes { get; init; }
    public required string Text { get; init; }
    public required RiotSessionInfo Info { get; init; }
    public required string Sha256 { get; init; }
    public required long Length { get; init; }
    public required string SourcePath { get; init; }
    public DateTimeOffset CapturedAtUtc { get; init; } = DateTimeOffset.UtcNow;
}
