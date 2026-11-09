namespace RiotSwitcher.Core.Vault;

public sealed class AccountRecord
{
    public string Id { get; set; } = string.Empty;
    public string Label { get; set; } = string.Empty;
    public string? RiotId { get; set; }
    public string? Puuid { get; set; }
    public string? Locale { get; set; }
    public string? Country { get; set; }
    public DateTimeOffset CreatedUtc { get; set; }
    public DateTimeOffset? LastUsedUtc { get; set; }
    public DateTimeOffset? LastSwitchUtc { get; set; }
    public string? AutoLaunchProduct { get; set; }
    public bool HasProfile { get; set; }
    public string? LastError { get; set; }
    public bool Legacy { get; set; }

    public string DisplayName
    {
        get
        {
            if (!string.IsNullOrWhiteSpace(Label)) return Label;
            if (!string.IsNullOrWhiteSpace(RiotId)) return RiotId!;
            return $"Compte {ShortId}";
        }
    }

    public string ShortId => Id.Length <= 6 ? Id : Id[..6];
}

public sealed class AccountsDocument
{
    public int SchemaVersion { get; set; } = 1;
    public List<AccountRecord> Accounts { get; set; } = new();
}

public sealed class VaultException : Exception
{
    public VaultException(string message) : base(message) { }
    public VaultException(string message, Exception inner) : base(message, inner) { }
}

public sealed class VaultBusyException : Exception
{
    public VaultBusyException(string message) : base(message) { }
}
