using System.Text.Json;

namespace RiotSwitcher.Core.Riot;

/// <summary>
/// Localise RiotClientServices.exe à partir de ProgramData\Riot Games\RiotClientInstalls.json,
/// puis des emplacements d'installation classiques.
/// </summary>
public static class RiotInstallLocator
{
    public static string? FindInstallRoot(string? programDataRoot = null)
    {
        var programData = programDataRoot ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
            "Riot Games");

        var candidates = new List<string?>();

        try
        {
            var installsFile = Path.Combine(programData, "RiotClientInstalls.json");
            if (File.Exists(installsFile))
            {
                using var doc = JsonDocument.Parse(File.ReadAllText(installsFile));
                foreach (var key in new[] { "rc_live", "rc_default" })
                {
                    if (doc.RootElement.TryGetProperty(key, out var value) &&
                        value.ValueKind == JsonValueKind.String)
                    {
                        candidates.Add(value.GetString());
                    }
                }
            }
        }
        catch
        {
            // Fichier absent, inaccessible ou corrompu : on passe aux emplacements connus.
        }

        candidates.Add(@"C:\Riot Games\Riot Client");
        candidates.Add(Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
            "Riot Games", "Riot Client"));
        candidates.Add(Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),
            "Riot Games", "Riot Client"));

        foreach (var candidate in candidates)
        {
            var root = NormalizeInstallRoot(candidate);
            if (root is not null &&
                File.Exists(Path.Combine(root, "RiotClientServices.exe")))
            {
                return root;
            }
        }

        return null;
    }

    private static string? NormalizeInstallRoot(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return null;

        var path = value.Trim().Replace('/', '\\');
        try
        {
            if (File.Exists(path))
                return Path.GetDirectoryName(Path.GetFullPath(path));
            if (Directory.Exists(path))
                return Path.GetFullPath(path);
        }
        catch
        {
            return null;
        }

        return null;
    }
}
