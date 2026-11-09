using System.Text;
using RiotSwitcher.Core.Vault;

namespace RiotSwitcher.Core.Tests;

public sealed class DpapiBundleTests
{
    [Fact]
    public void Bundle_roundtrips_session_and_profile()
    {
        var yaml = Encoding.UTF8.GetBytes(TestData.MakePslYaml("puuid-a", "Alpha", "EUW"));
        var manifest = new BundleManifest
        {
            AccountId = "puuid-a",
            RiotId = "Alpha#EUW",
            Puuid = "puuid-a",
            Format = "psl-v1",
            CapturedAtUtc = DateTimeOffset.UtcNow,
            SourcePath = "test.yaml",
            YamlSha256 = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(yaml)),
            YamlLength = yaml.Length
        };

        var profile = new Dictionary<string, byte[]>(StringComparer.OrdinalIgnoreCase)
        {
            ["Network/Cookies"] = new byte[] { 1, 2, 3 },
            ["Local Storage/leveldb/000001.ldb"] = new byte[] { 4, 5, 6 }
        };

        var encrypted = DpapiBundle.CreateEncryptedBundle(manifest, yaml, profile);

        Assert.Equal((byte)'R', encrypted[0]);
        Assert.Equal((byte)'S', encrypted[1]);
        Assert.Equal((byte)'W', encrypted[2]);
        Assert.Equal((byte)'1', encrypted[3]);

        var opened = DpapiBundle.OpenBundle(encrypted);

        Assert.Equal("puuid-a", opened.Manifest.AccountId);
        Assert.Equal(yaml, opened.YamlBytes);
        Assert.True(opened.Manifest.IncludesProfile);
        Assert.Equal(profile["Network/Cookies"], opened.ProfileFiles["Network/Cookies"]);
        Assert.Equal(profile["Local Storage/leveldb/000001.ldb"], opened.ProfileFiles["Local Storage/leveldb/000001.ldb"]);
    }

    [Fact]
    public void Tampered_ciphertext_is_rejected()
    {
        var yaml = Encoding.UTF8.GetBytes(TestData.MakePslYaml("puuid-a", "Alpha", "EUW"));
        var manifest = new BundleManifest { AccountId = "puuid-a", Format = "psl-v1", YamlLength = yaml.Length };
        var encrypted = DpapiBundle.CreateEncryptedBundle(manifest, yaml);

        encrypted[^1] ^= 0xFF;

        Assert.Throws<InvalidDataException>(() => DpapiBundle.OpenBundle(encrypted));
    }

    [Fact]
    public void Bad_magic_is_rejected()
    {
        var yaml = Encoding.UTF8.GetBytes(TestData.MakePslYaml("puuid-a", "Alpha", "EUW"));
        var encrypted = DpapiBundle.CreateEncryptedBundle(new BundleManifest { AccountId = "puuid-a" }, yaml);

        encrypted[0] = (byte)'X';

        Assert.Throws<InvalidDataException>(() => DpapiBundle.OpenBundle(encrypted));
    }

    [Fact]
    public void Empty_yaml_is_refused()
    {
        Assert.Throws<InvalidDataException>(() =>
            DpapiBundle.CreateEncryptedBundle(new BundleManifest { AccountId = "puuid-a" }, Array.Empty<byte>()));
    }
}
