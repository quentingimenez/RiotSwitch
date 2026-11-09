namespace RiotSwitcher.Core.Vault;

/// <summary>Métadonnées du bundle chiffré (manifest.json dans l'archive ZIP).</summary>
public sealed class BundleManifest
{
    public int SchemaVersion { get; set; } = 1;
    public string AccountId { get; set; } = string.Empty;
    public string? RiotId { get; set; }
    public string? Puuid { get; set; }
    public string Format { get; set; } = "unknown";
    public DateTimeOffset CapturedAtUtc { get; set; }
    public string SourcePath { get; set; } = string.Empty;
    public string YamlSha256 { get; set; } = string.Empty;
    public long YamlLength { get; set; }
    public bool IncludesProfile { get; set; }
    public List<string> ProfileFiles { get; set; } = new();
}
