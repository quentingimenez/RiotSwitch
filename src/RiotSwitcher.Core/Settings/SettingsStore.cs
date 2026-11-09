using System.Text.Json;
using RiotSwitcher.Core.Infrastructure;
using RiotSwitcher.Core.Riot;

namespace RiotSwitcher.Core.Settings;

public enum BackgroundMode
{
    Watch = 0,
    Launcher = 1
}

public sealed class AppSettings
{
    public int SchemaVersion { get; set; } = 1;
    public BackgroundMode BackgroundMode { get; set; } = BackgroundMode.Launcher;
    public bool Autostart { get; set; }
    public double OverlayOffsetRightDip { get; set; } = 12;
    public double OverlayOffsetTopDip { get; set; } = 12;
    public bool OverlayPositionSet { get; set; }
    public bool OverlayPinned { get; set; }
    public int OverlayPinnedRightPx { get; set; }
    public int OverlayPinnedTopPx { get; set; }
    public string DefaultLaunchProduct { get; set; } = "none";
    public bool KeepBackups { get; set; } = true;
    public bool CaptureElectronProfile { get; set; }
    public bool AutoCheckUpdates { get; set; } = true;
    public DateTimeOffset? LastUpdateCheckUtc { get; set; }
    public string Language { get; set; } = "fr";
    public bool FirstRunCompleted { get; set; }
}

public sealed class SettingsStore
{
    private readonly RiotPaths _paths;
    private readonly IAppLogger _logger;
    private readonly object _gate = new();

    public SettingsStore(RiotPaths paths, IAppLogger? logger = null)
    {
        _paths = paths ?? throw new ArgumentNullException(nameof(paths));
        _logger = logger ?? NullLogger.Instance;
        try
        {
            var directory = Path.GetDirectoryName(_paths.SettingsFile);
            if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);
        }
        catch
        {
            // Le constructeur du vault crée le dossier ; les écritures échoueront proprement.
        }
    }

    public AppSettings Load()
    {
        lock (_gate)
        {
            if (!File.Exists(_paths.SettingsFile)) return new AppSettings();

            try
            {
                var text = AtomicFile.ReadAllText(_paths.SettingsFile);
                var settings = JsonSerializer.Deserialize<AppSettings>(text, JsonDefaults.Options)
                    ?? new AppSettings();
                Normalize(settings);
                return settings;
            }
            catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException)
            {
                _logger.Warn($"settings.json illisible, réinitialisation des préférences : {ex.Message}");
                return new AppSettings();
            }
        }
    }

    public void Save(AppSettings settings)
    {
        ArgumentNullException.ThrowIfNull(settings);

        lock (_gate)
        {
            Normalize(settings);
            try
            {
                var json = JsonSerializer.Serialize(settings, JsonDefaults.Options);
                AtomicFile.WriteAllText(_paths.SettingsFile, json);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                _logger.Warn($"Écriture de settings.json impossible : {ex.Message}");
            }
        }
    }

    public static void Normalize(AppSettings settings)
    {
        if (!Enum.IsDefined(typeof(BackgroundMode), settings.BackgroundMode))
            settings.BackgroundMode = BackgroundMode.Launcher;

        if (settings.OverlayOffsetRightDip < -2000 || settings.OverlayOffsetRightDip > 2000)
            settings.OverlayOffsetRightDip = 12;
        if (settings.OverlayOffsetTopDip < -2000 || settings.OverlayOffsetTopDip > 2000)
            settings.OverlayOffsetTopDip = 12;

        // Coordonnées absolues de l'overlay épinglé (pixels écran, multi-écrans).
        if (settings.OverlayPinnedRightPx < -32768 || settings.OverlayPinnedRightPx > 32767)
            settings.OverlayPinnedRightPx = 0;
        if (settings.OverlayPinnedTopPx < -32768 || settings.OverlayPinnedTopPx > 32767)
            settings.OverlayPinnedTopPx = 0;

        settings.DefaultLaunchProduct = NormalizeProduct(settings.DefaultLaunchProduct);
        if (string.IsNullOrWhiteSpace(settings.Language)) settings.Language = "fr";
        settings.SchemaVersion = 1;
    }

    public static string NormalizeProduct(string? product)
    {
        return (product ?? string.Empty).Trim().ToLowerInvariant() switch
        {
            "league" or "lol" or "league_of_legends" => "league_of_legends",
            "valorant" or "val" => "valorant",
            "none" or "aucun" or "client" or "" => "none",
            _ => "none"
        };
    }
}
