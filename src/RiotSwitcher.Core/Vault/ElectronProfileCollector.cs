using RiotSwitcher.Core.Infrastructure;
using RiotSwitcher.Core.Riot;

namespace RiotSwitcher.Core.Vault;

public sealed class ProfileFile
{
    public required string RelativePath { get; init; }
    public required byte[] Bytes { get; init; }
}

/// <summary>
/// Contingence avancée : snapshot du profil Electron (cookies + leveldb).
/// Utilisé uniquement si l'option est activée ; jamais touché par défaut.
/// </summary>
public static class ElectronProfileCollector
{
    public static IReadOnlyList<ProfileFile> Capture(RiotPaths paths)
    {
        var result = new List<ProfileFile>();
        var root = paths.ElectronProfileRoot;
        if (!Directory.Exists(root)) return result;

        AddFile(root, paths.ElectronCookiesFile, result);
        AddFile(root, paths.ElectronCookiesJournalFile, result);

        if (Directory.Exists(paths.ElectronLocalStorageDir))
        {
            try
            {
                foreach (var file in Directory.EnumerateFiles(
                             paths.ElectronLocalStorageDir, "*", SearchOption.AllDirectories))
                {
                    var relative = Path.GetRelativePath(root, file);
                    if (!IsSafeRelative(relative)) continue;
                    try
                    {
                        var bytes = AtomicFile.ReadAllBytes(file, attempts: 2);
                        result.Add(new ProfileFile { RelativePath = Normalize(relative), Bytes = bytes });
                    }
                    catch
                    {
                        // Fichier verrouillé (leveldb en écriture) : on l'ignore, best-effort.
                    }
                }
            }
            catch
            {
                // Dossier inaccessible : best-effort.
            }
        }

        return result;
    }

    public static void Restore(RiotPaths paths, IReadOnlyDictionary<string, byte[]> files)
    {
        if (files.Count == 0) return;

        foreach (var (relative, bytes) in files)
        {
            var safe = Normalize(relative);
            if (!IsSafeRelative(safe)) continue;

            var destination = Path.Combine(
                paths.ElectronProfileRoot,
                safe.Replace('/', Path.DirectorySeparatorChar));
            var directory = Path.GetDirectoryName(destination);
            if (directory is not null) Directory.CreateDirectory(directory);
            AtomicFile.WriteAllBytes(destination, bytes);
        }
    }

    private static void AddFile(string root, string path, List<ProfileFile> result)
    {
        try
        {
            if (!File.Exists(path)) return;
            var relative = Path.GetRelativePath(root, path);
            if (!IsSafeRelative(relative)) return;
            result.Add(new ProfileFile
            {
                RelativePath = Normalize(relative),
                Bytes = AtomicFile.ReadAllBytes(path, attempts: 2)
            });
        }
        catch
        {
            // Best-effort.
        }
    }

    private static string Normalize(string path) => path.Replace('\\', '/');

    private static bool IsSafeRelative(string path)
    {
        if (string.IsNullOrWhiteSpace(path) || Path.IsPathRooted(path)) return false;
        var parts = path.Replace('\\', '/').Split('/', StringSplitOptions.RemoveEmptyEntries);
        return parts.Length > 0 && parts.All(p => p is not "." and not "..");
    }
}
