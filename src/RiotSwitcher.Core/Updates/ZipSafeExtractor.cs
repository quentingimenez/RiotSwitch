using System.IO.Compression;

namespace RiotSwitcher.Core.Updates;

/// <summary>Extraction de ZIP avec protection contre les chemins hors dossier cible (zip-slip).</summary>
public static class ZipSafeExtractor
{
    public static void ExtractToDirectory(string zipPath, string destinationDirectory)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(zipPath);
        ArgumentException.ThrowIfNullOrWhiteSpace(destinationDirectory);

        if (!File.Exists(zipPath)) throw new FileNotFoundException("Archive de mise à jour introuvable.", zipPath);

        var destinationRoot = Path.GetFullPath(destinationDirectory)
            .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        Directory.CreateDirectory(destinationRoot);

        using var archive = ZipFile.OpenRead(zipPath);
        foreach (var entry in archive.Entries)
        {
            var fullName = entry.FullName.Replace('\\', '/');
            if (string.IsNullOrWhiteSpace(fullName)) continue;

            var targetPath = Path.GetFullPath(Path.Combine(destinationRoot, fullName));
            if (!IsUnderRoot(targetPath, destinationRoot))
            {
                throw new InvalidDataException($"Entrée d'archive dangereuse : « {entry.FullName} ».");
            }

            var isDirectory = fullName.EndsWith('/');
            if (isDirectory)
            {
                Directory.CreateDirectory(targetPath);
                continue;
            }

            var parent = Path.GetDirectoryName(targetPath);
            if (!string.IsNullOrEmpty(parent)) Directory.CreateDirectory(parent);

            entry.ExtractToFile(targetPath, overwrite: true);
        }
    }

    private static bool IsUnderRoot(string candidate, string root)
    {
        if (string.Equals(candidate, root, StringComparison.OrdinalIgnoreCase)) return true;

        return candidate.StartsWith(
            root + Path.DirectorySeparatorChar,
            StringComparison.OrdinalIgnoreCase);
    }
}
