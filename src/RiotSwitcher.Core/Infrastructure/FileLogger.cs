using System.Text;
using System.Text.RegularExpressions;

namespace RiotSwitcher.Core.Infrastructure;

public interface IAppLogger
{
    void Info(string message);
    void Warn(string message);
    void Error(string message, Exception? exception = null);
}

public sealed class NullLogger : IAppLogger
{
    public static readonly NullLogger Instance = new();
    public void Info(string message) { }
    public void Warn(string message) { }
    public void Error(string message, Exception? exception = null) { }
}

/// <summary>
/// Journal texte local, sans jeton ni secret. Rotation 1 Mo x 3.
/// </summary>
public sealed class FileLogger : IAppLogger, IDisposable
{
    private const long MaxBytes = 1_048_576;
    private const int MaxFiles = 3;
    private static readonly UTF8Encoding Utf8NoBom = new(encoderShouldEmitUTF8Identifier: false);
    private static readonly Regex LongTokenRegex = new(
        @"[A-Za-z0-9_\-\.]{120,}",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);
    private static readonly Regex SecretKeyRegex = new(
        @"(?i)\b(id_token|refresh_token|access_token|ssid|password|authorization)\b\s*[:=]\s*\S+",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    private readonly object _gate = new();
    private readonly string _path;

    public FileLogger(string logDirectory)
    {
        Directory.CreateDirectory(logDirectory);
        _path = Path.Combine(logDirectory, "app.log");
    }

    public void Info(string message) => Write("INFO", message, null);
    public void Warn(string message) => Write("WARN", message, null);
    public void Error(string message, Exception? exception = null) => Write("ERROR", message, exception);

    private void Write(string level, string message, Exception? exception)
    {
        lock (_gate)
        {
            try
            {
                RotateIfNeeded();
                var line = $"{DateTimeOffset.UtcNow:O} [{level}] {Redact(message)}";
                if (exception is not null)
                    line += Environment.NewLine + Redact(exception.ToString());
                line += Environment.NewLine;
                File.AppendAllText(_path, line, Utf8NoBom);
            }
            catch
            {
                // Le journal ne doit jamais faire échouer une opération.
            }
        }
    }

    private void RotateIfNeeded()
    {
        try
        {
            var info = new FileInfo(_path);
            if (!info.Exists || info.Length < MaxBytes) return;

            for (var i = MaxFiles - 1; i >= 1; i--)
            {
                var source = $"{_path}.{i}";
                var destination = $"{_path}.{i + 1}";
                if (File.Exists(source))
                {
                    if (i + 1 > MaxFiles) File.Delete(source);
                    else File.Move(source, destination, overwrite: true);
                }
            }

            File.Move(_path, $"{_path}.1", overwrite: true);
        }
        catch
        {
            // Rotation best-effort.
        }
    }

    private static string Redact(string text)
    {
        if (string.IsNullOrEmpty(text)) return text;
        var result = SecretKeyRegex.Replace(text, "$1=<masqué>");
        result = LongTokenRegex.Replace(result, "<jeton-masqué>");
        return result;
    }

    public void Dispose() { }
}
