using System.Security.Cryptography;
using System.Text;

namespace RiotSwitcher.Core.Infrastructure;

/// <summary>
/// Écritures atomiques (temp + rename) et lectures tolérantes aux verrous.
/// </summary>
public static class AtomicFile
{
    private static readonly UTF8Encoding Utf8NoBom = new(encoderShouldEmitUTF8Identifier: false);

    public static void WriteAllBytes(string path, ReadOnlySpan<byte> data, int attempts = 5)
    {
        if (string.IsNullOrWhiteSpace(path))
            throw new ArgumentException("Chemin requis.", nameof(path));

        var directory = Path.GetDirectoryName(Path.GetFullPath(path))
            ?? throw new ArgumentException("Le chemin doit avoir un dossier parent.", nameof(path));
        Directory.CreateDirectory(directory);

        Exception? lastError = null;
        for (var attempt = 1; attempt <= attempts; attempt++)
        {
            var temp = Path.Combine(
                directory,
                $".{Path.GetFileName(path)}.{Environment.ProcessId}.{Guid.NewGuid():N}.tmp");

            try
            {
                using (var stream = new FileStream(
                    temp,
                    FileMode.CreateNew,
                    FileAccess.Write,
                    FileShare.None,
                    bufferSize: 4096,
                    FileOptions.WriteThrough))
                {
                    stream.Write(data);
                    stream.Flush(flushToDisk: true);
                }

                if (File.Exists(path))
                {
                    try
                    {
                        File.Replace(temp, path, destinationBackupFileName: null, ignoreMetadataErrors: true);
                    }
                    catch (Exception ex) when (ex is IOException or PlatformNotSupportedException or UnauthorizedAccessException)
                    {
                        File.Move(temp, path, overwrite: true);
                    }
                }
                else
                {
                    File.Move(temp, path);
                }

                return;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or NotSupportedException)
            {
                lastError = ex;
                TryDelete(temp);
                if (attempt < attempts)
                    Thread.Sleep(120 * attempt);
            }
            finally
            {
                TryDelete(temp);
            }
        }

        throw new IOException($"Écriture atomique impossible : {path}", lastError);
    }

    public static void WriteAllText(string path, string text, int attempts = 5)
        => WriteAllBytes(path, Utf8NoBom.GetBytes(text), attempts);

    public static byte[] ReadAllBytes(string path, int attempts = 4)
    {
        Exception? lastError = null;
        for (var attempt = 1; attempt <= attempts; attempt++)
        {
            try
            {
                using var stream = new FileStream(
                    path,
                    FileMode.Open,
                    FileAccess.Read,
                    FileShare.ReadWrite | FileShare.Delete);
                using var buffer = new MemoryStream();
                stream.CopyTo(buffer);
                return buffer.ToArray();
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                lastError = ex;
                if (attempt < attempts)
                    Thread.Sleep(100 * attempt);
            }
        }

        throw new IOException($"Lecture impossible : {path}", lastError);
    }

    public static string ReadAllText(string path, int attempts = 4)
        => Encoding.UTF8.GetString(ReadAllBytes(path, attempts));

    public static string Sha256Hex(ReadOnlySpan<byte> data)
        => Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant();

    public static void TryDelete(string? path)
    {
        if (string.IsNullOrWhiteSpace(path)) return;
        try
        {
            if (File.Exists(path)) File.Delete(path);
        }
        catch
        {
            // Nettoyage best-effort.
        }
    }
}
