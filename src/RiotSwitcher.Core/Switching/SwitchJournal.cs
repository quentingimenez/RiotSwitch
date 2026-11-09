using System.Text.Json;
using RiotSwitcher.Core.Infrastructure;
using RiotSwitcher.Core.Riot;

namespace RiotSwitcher.Core.Switching;

public sealed class SwitchJournalEntry
{
    public int SchemaVersion { get; set; } = 1;
    public Guid SwitchId { get; set; }
    public DateTimeOffset StartedUtc { get; set; }
    public DateTimeOffset UpdatedUtc { get; set; }
    public string Phase { get; set; } = "starting";
    public string TargetAccountId { get; set; } = string.Empty;
    public string TargetLabel { get; set; } = string.Empty;
    public string? CurrentAccountId { get; set; }
    public string? CurrentBackupFile { get; set; }
    public bool ClientClosed { get; set; }
    public bool ServiceStopped { get; set; }
    public bool TargetWritten { get; set; }
}

/// <summary>
/// Journal de switch : permet de diagnostiquer/reprendre après un crash. Ne contient aucun token.
/// </summary>
public sealed class SwitchJournal
{
    private readonly string _path;
    private readonly IAppLogger _logger;
    private readonly object _gate = new();
    private SwitchJournalEntry? _current;

    public SwitchJournal(RiotPaths paths, IAppLogger? logger = null)
    {
        ArgumentNullException.ThrowIfNull(paths);
        _path = paths.JournalFile;
        _logger = logger ?? NullLogger.Instance;

        try
        {
            var directory = System.IO.Path.GetDirectoryName(_path);
            if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);
        }
        catch
        {
            // Le vault créera le dossier ; les écritures échoueront proprement.
        }
    }

    public string Path => _path;

    public SwitchJournalEntry? Load()
    {
        lock (_gate)
        {
            if (!File.Exists(_path)) return null;

            try
            {
                var text = AtomicFile.ReadAllText(_path);
                var entry = JsonSerializer.Deserialize<SwitchJournalEntry>(text, JsonDefaults.Options);
                return entry;
            }
            catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException)
            {
                _logger.Warn($"Journal de switch illisible : {ex.Message}");
                return null;
            }
        }
    }

    public SwitchJournalEntry Begin(
        string targetAccountId,
        string targetLabel,
        string? currentAccountId,
        string? currentBackupFile)
    {
        var now = DateTimeOffset.UtcNow;
        var entry = new SwitchJournalEntry
        {
            SwitchId = Guid.NewGuid(),
            StartedUtc = now,
            UpdatedUtc = now,
            Phase = "starting",
            TargetAccountId = targetAccountId,
            TargetLabel = targetLabel,
            CurrentAccountId = currentAccountId,
            CurrentBackupFile = currentBackupFile
        };

        lock (_gate)
        {
            _current = entry;
            WriteUnlocked(entry);
        }

        return entry;
    }

    public void Update(Action<SwitchJournalEntry> update)
    {
        ArgumentNullException.ThrowIfNull(update);

        lock (_gate)
        {
            var entry = _current ?? TryLoadUnlocked();
            if (entry is null) return;

            update(entry);
            entry.UpdatedUtc = DateTimeOffset.UtcNow;
            _current = entry;
            WriteUnlocked(entry);
        }
    }

    public void SetPhase(string phase)
    {
        Update(entry => entry.Phase = phase);
    }

    public void Clear()
    {
        lock (_gate)
        {
            _current = null;
            try
            {
                if (File.Exists(_path)) File.Delete(_path);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                _logger.Warn($"Suppression du journal de switch impossible : {ex.Message}");
            }
        }
    }

    private SwitchJournalEntry? TryLoadUnlocked()
    {
        if (!File.Exists(_path)) return null;

        try
        {
            var text = AtomicFile.ReadAllText(_path);
            return JsonSerializer.Deserialize<SwitchJournalEntry>(text, JsonDefaults.Options);
        }
        catch
        {
            return null;
        }
    }

    private void WriteUnlocked(SwitchJournalEntry entry)
    {
        try
        {
            var json = JsonSerializer.Serialize(entry, JsonDefaults.Options);
            AtomicFile.WriteAllText(_path, json);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            _logger.Warn($"Écriture du journal de switch impossible : {ex.Message}");
        }
    }
}
