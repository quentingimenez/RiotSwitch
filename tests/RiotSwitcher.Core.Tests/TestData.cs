using System.Text;
using System.Text.Json;
using RiotSwitcher.Core.Riot;

namespace RiotSwitcher.Core.Tests;

internal static class TestData
{
    public static string Base64Url(string text)
    {
        return Convert.ToBase64String(Encoding.UTF8.GetBytes(text))
            .TrimEnd('=')
            .Replace('+', '-')
            .Replace('/', '_');
    }

    public static string MakeJwt(
        string puuid,
        string gameName,
        string tagLine,
        string region = "euw1",
        string locale = "fr",
        DateTimeOffset? expires = null)
    {
        var header = Base64Url("{\"alg\":\"none\",\"typ\":\"JWT\"}");
        var exp = (expires ?? DateTimeOffset.UtcNow.AddHours(1)).ToUnixTimeSeconds();
        var payload = JsonSerializer.Serialize(new Dictionary<string, object?>
        {
            ["sub"] = puuid,
            ["acct"] = new Dictionary<string, object?>
            {
                ["game_name"] = gameName,
                ["tag_line"] = tagLine,
                ["state"] = "ENABLED"
            },
            ["player_locale"] = locale,
            ["country"] = "fra",
            ["login_country"] = "fra",
            ["lol_region"] = region,
            ["exp"] = exp,
            ["iat"] = exp - 3600
        });

        return $"{header}.{Base64Url(payload)}.signature";
    }

    public static string MakePslYaml(
        string puuid,
        string gameName,
        string tagLine,
        bool dpop = false,
        bool persist = true,
        bool includeRefresh = true,
        string refreshToken = "refresh-token-value")
    {
        var idToken = MakeJwt(puuid, gameName, tagLine);
        var refresh = includeRefresh ? $"      refresh_token: '{refreshToken}'\r\n" : string.Empty;

        return "psl:\r\n" +
               "  authorization:\r\n" +
               "    riot-client:\r\n" +
               $"      id_token: '{idToken}'\r\n" +
               $"      is_dpop_bound: {(dpop ? "true" : "false")}\r\n" +
               refresh +
               "      scopes:\r\n" +
               "        openid: true\r\n" +
               "riot-login:\r\n" +
               $"  persist: {(persist ? "true" : "false")}\r\n" +
               "rso-authenticator:\r\n" +
               "  tdid:\r\n" +
               "    domain: auth.riotgames.com\r\n" +
               "    name: tdid\r\n" +
               "    value: test-value\r\n";
    }

    public static string MakeLegacyYaml()
    {
        return "riot-login:\r\n" +
               "  persist: true\r\n" +
               "  session:\r\n" +
               "    cookies:\r\n" +
               "      - name: ssid\r\n" +
               "        value: legacy-cookie-value\r\n";
    }

    public static RiotSessionSnapshot Snapshot(string yaml, string sourcePath = "RiotGamesPrivateSettings.yaml")
    {
        return RiotSessionReader.Snapshot(Encoding.UTF8.GetBytes(yaml), sourcePath);
    }

    public static RiotPaths CreatePaths(string root)
    {
        var install = Path.Combine(root, "Riot Client");
        Directory.CreateDirectory(install);
        File.WriteAllBytes(Path.Combine(install, "RiotClientServices.exe"), Array.Empty<byte>());
        Directory.CreateDirectory(Path.Combine(install, "RiotClientElectron"));
        File.WriteAllBytes(Path.Combine(install, "RiotClientElectron", "Riot Client.exe"), Array.Empty<byte>());

        var userData = Path.Combine(root, "Local", "Riot Client");
        Directory.CreateDirectory(Path.Combine(userData, "Data"));

        var electronProfile = Path.Combine(root, "Roaming", "Riot Client");
        Directory.CreateDirectory(electronProfile);

        var vault = Path.Combine(root, "Vault");
        var programData = Path.Combine(root, "ProgramData");

        return new RiotPaths(
            installRoot: install,
            userDataRoot: userData,
            electronProfileRoot: electronProfile,
            vaultRoot: vault,
            programDataRoot: programData);
    }

    public static string CreateTempRoot()
    {
        var root = Path.Combine(Path.GetTempPath(), "RiotSwitchTests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        return root;
    }

    public static void Cleanup(string root)
    {
        for (var attempt = 0; attempt < 3; attempt++)
        {
            try
            {
                if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
                return;
            }
            catch (IOException)
            {
                Thread.Sleep(100);
            }
            catch (UnauthorizedAccessException)
            {
                Thread.Sleep(100);
            }
        }
    }
}
