using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using RiotSwitcher.Core.Infrastructure;

namespace RiotSwitcher.Core.Vault;

public sealed class BundleContents
{
    public required BundleManifest Manifest { get; init; }
    public required byte[] YamlBytes { get; init; }
    public required IReadOnlyDictionary<string, byte[]> ProfileFiles { get; init; }
}

/// <summary>
/// Format de bundle RiotSwitch :
///   hors-chiffrement : "RSW1" + version(1) + SHA256 tronqué(8) + blob DPAPI(CurrentUser)
///   clair (ZIP)      : manifest.json + session/RiotGamesPrivateSettings.yaml + profile/**
/// </summary>
public static class DpapiBundle
{
    private static readonly byte[] Magic = { (byte)'R', (byte)'S', (byte)'W', (byte)'1' };
    private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("RiotSwitch:v1:session");
    private const byte FormatVersion = 1;
    private const int HeaderLength = 4 + 1 + 8;
    private const string ManifestEntry = "manifest.json";
    private const string SessionEntry = "session/RiotGamesPrivateSettings.yaml";
    private const string ProfilePrefix = "profile/";

    public static byte[] CreateEncryptedBundle(
        BundleManifest manifest,
        byte[] yamlBytes,
        IReadOnlyDictionary<string, byte[]>? profileFiles = null)
    {
        var payload = CreatePayload(manifest, yamlBytes, profileFiles);
        return Protect(payload);
    }

    public static BundleContents OpenBundle(byte[] encrypted)
    {
        var payload = Unprotect(encrypted);
        return ExtractPayload(payload);
    }

    public static byte[] Protect(byte[] plaintext)
    {
        if (plaintext is null) throw new ArgumentNullException(nameof(plaintext));

        var checksum = SHA256.HashData(plaintext);
        var encrypted = ProtectedData.Protect(plaintext, Entropy, DataProtectionScope.CurrentUser);

        var result = new byte[HeaderLength + encrypted.Length];
        Magic.CopyTo(result, 0);
        result[4] = FormatVersion;
        checksum.AsSpan(0, 8).CopyTo(result.AsSpan(5, 8));
        encrypted.CopyTo(result, HeaderLength);
        return result;
    }

    public static byte[] Unprotect(byte[] protectedBytes)
    {
        if (protectedBytes is null) throw new ArgumentNullException(nameof(protectedBytes));
        if (protectedBytes.Length < HeaderLength + 8)
            throw new InvalidDataException("Bundle RiotSwitch trop court.");

        if (!protectedBytes.AsSpan(0, 4).SequenceEqual(Magic))
            throw new InvalidDataException("Bundle RiotSwitch non reconnu (magie RSW1 absente).");

        if (protectedBytes[4] != FormatVersion)
            throw new InvalidDataException($"Version de bundle non supportée : {protectedBytes[4]}.");

        var expected = protectedBytes.AsSpan(5, 8).ToArray();
        var cipher = protectedBytes.AsSpan(HeaderLength).ToArray();

        byte[] plaintext;
        try
        {
            plaintext = ProtectedData.Unprotect(cipher, Entropy, DataProtectionScope.CurrentUser);
        }
        catch (CryptographicException ex)
        {
            throw new InvalidDataException(
                "Bundle illisible par DPAPI. Il a peut-être été créé par un autre compte Windows.", ex);
        }

        var actual = SHA256.HashData(plaintext);
        if (!CryptographicOperations.FixedTimeEquals(expected, actual.AsSpan(0, 8)))
            throw new InvalidDataException("Bundle corrompu (empreinte SHA256 invalide).");

        return plaintext;
    }

    private static byte[] CreatePayload(
        BundleManifest manifest,
        byte[] yamlBytes,
        IReadOnlyDictionary<string, byte[]>? profileFiles)
    {
        if (yamlBytes.Length == 0)
            throw new InvalidDataException("Session Riot vide : capture refusée.");

        var profiles = profileFiles ?? new Dictionary<string, byte[]>();
        manifest.ProfileFiles = profiles.Keys.OrderBy(k => k, StringComparer.Ordinal).ToList();
        manifest.IncludesProfile = manifest.ProfileFiles.Count > 0;

        using var memory = new MemoryStream();
        using (var archive = new ZipArchive(memory, ZipArchiveMode.Create, leaveOpen: true))
        {
            var manifestEntry = archive.CreateEntry(ManifestEntry, CompressionLevel.Optimal);
            using (var stream = manifestEntry.Open())
            {
                JsonSerializer.Serialize(stream, manifest, JsonDefaults.Options);
            }

            var sessionEntry = archive.CreateEntry(SessionEntry, CompressionLevel.Optimal);
            using (var stream = sessionEntry.Open())
            {
                stream.Write(yamlBytes);
            }

            foreach (var (relativePath, bytes) in profiles)
            {
                var safeRelative = NormalizeProfilePath(relativePath);
                var entry = archive.CreateEntry(ProfilePrefix + safeRelative, CompressionLevel.Optimal);
                using var stream = entry.Open();
                stream.Write(bytes);
            }
        }

        return memory.ToArray();
    }

    private static BundleContents ExtractPayload(byte[] payload)
    {
        using var memory = new MemoryStream(payload);
        using var archive = new ZipArchive(memory, ZipArchiveMode.Read);

        var manifestEntry = archive.GetEntry(ManifestEntry)
            ?? throw new InvalidDataException("Manifest absent du bundle.");

        BundleManifest manifest;
        using (var stream = manifestEntry.Open())
        {
            manifest = JsonSerializer.Deserialize<BundleManifest>(stream, JsonDefaults.Options)
                ?? throw new InvalidDataException("Manifest invalide.");
        }

        var sessionEntry = archive.GetEntry(SessionEntry)
            ?? throw new InvalidDataException("Session Riot absente du bundle.");

        byte[] yamlBytes;
        using (var stream = sessionEntry.Open())
        using (var buffer = new MemoryStream())
        {
            stream.CopyTo(buffer);
            yamlBytes = buffer.ToArray();
        }

        if (yamlBytes.Length == 0)
            throw new InvalidDataException("Session Riot vide dans le bundle.");

        var profiles = new Dictionary<string, byte[]>(StringComparer.OrdinalIgnoreCase);
        foreach (var entry in archive.Entries)
        {
            if (!entry.FullName.StartsWith(ProfilePrefix, StringComparison.OrdinalIgnoreCase)) continue;
            if (entry.FullName.EndsWith("/", StringComparison.Ordinal)) continue;

            var relative = entry.FullName[ProfilePrefix.Length..];
            relative = NormalizeProfilePath(relative);
            using var stream = entry.Open();
            using var buffer = new MemoryStream();
            stream.CopyTo(buffer);
            profiles[relative] = buffer.ToArray();
        }

        return new BundleContents
        {
            Manifest = manifest,
            YamlBytes = yamlBytes,
            ProfileFiles = profiles
        };
    }

    private static string NormalizeProfilePath(string path)
    {
        if (string.IsNullOrWhiteSpace(path))
            throw new InvalidDataException("Chemin de profil vide.");
        if (Path.IsPathRooted(path))
            throw new InvalidDataException($"Chemin de profil absolu interdit : {path}");

        var normalized = path.Replace('\\', '/').TrimStart('/');
        var parts = normalized.Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length == 0 || parts.Any(p => p is "." or ".."))
            throw new InvalidDataException($"Chemin de profil invalide : {path}");

        return string.Join('/', parts);
    }
}
