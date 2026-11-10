using RiotSwitcher.Core.Settings;

namespace RiotSwitcher.Core.Tests;

public sealed class SettingsStoreTests
{
    [Fact]
    public void Defaults_when_file_is_absent()
    {
        var root = TestData.CreateTempRoot();
        try
        {
            var paths = TestData.CreatePaths(root);
            var store = new SettingsStore(paths);
            var settings = store.Load();

            Assert.Equal(BackgroundMode.Watch, settings.BackgroundMode);
            Assert.True(settings.Autostart);
            Assert.Equal(12, settings.OverlayOffsetRightDip);
            Assert.False(settings.OverlayPinned);
            Assert.Equal("none", settings.DefaultLaunchProduct);
            Assert.True(settings.AutoCheckUpdates);
            Assert.Null(settings.LastUpdateCheckUtc);
            Assert.Equal("fr", settings.Language);
            Assert.False(settings.FirstRunCompleted);
        }
        finally
        {
            TestData.Cleanup(root);
        }
    }

    [Fact]
    public void Save_then_load_roundtrip()
    {
        var root = TestData.CreateTempRoot();
        try
        {
            var paths = TestData.CreatePaths(root);
            var store = new SettingsStore(paths);

            store.Save(new AppSettings
            {
                BackgroundMode = BackgroundMode.Launcher,
                Autostart = false,
                OverlayOffsetRightDip = 40,
                OverlayOffsetTopDip = 24,
                OverlayPinned = true,
                OverlayPinnedRightPx = 1500,
                OverlayPinnedTopPx = 200,
                DefaultLaunchProduct = "league_of_legends",
                AutoCheckUpdates = false,
                LastUpdateCheckUtc = new DateTimeOffset(2026, 11, 9, 18, 0, 0, TimeSpan.Zero),
                FirstRunCompleted = true
            });

            var loaded = store.Load();
            Assert.Equal(BackgroundMode.Launcher, loaded.BackgroundMode);
            Assert.False(loaded.Autostart);
            Assert.Equal(40, loaded.OverlayOffsetRightDip);
            Assert.True(loaded.OverlayPinned);
            Assert.Equal(1500, loaded.OverlayPinnedRightPx);
            Assert.Equal(200, loaded.OverlayPinnedTopPx);
            Assert.Equal("league_of_legends", loaded.DefaultLaunchProduct);
            Assert.False(loaded.AutoCheckUpdates);
            Assert.Equal(
                new DateTimeOffset(2026, 11, 9, 18, 0, 0, TimeSpan.Zero),
                loaded.LastUpdateCheckUtc);
            Assert.True(loaded.FirstRunCompleted);
        }
        finally
        {
            TestData.Cleanup(root);
        }
    }

    [Fact]
    public void Normalize_repairs_invalid_values()
    {
        var settings = new AppSettings
        {
            BackgroundMode = (BackgroundMode)99,
            OverlayOffsetRightDip = 9999,
            OverlayOffsetTopDip = -9999,
            OverlayPinnedRightPx = 999999,
            OverlayPinnedTopPx = -999999,
            DefaultLaunchProduct = "lol",
            Language = ""
        };

        SettingsStore.Normalize(settings);

        Assert.Equal(BackgroundMode.Watch, settings.BackgroundMode);
        Assert.Equal(12, settings.OverlayOffsetRightDip);
        Assert.Equal(12, settings.OverlayOffsetTopDip);
        Assert.Equal(0, settings.OverlayPinnedRightPx);
        Assert.Equal(0, settings.OverlayPinnedTopPx);
        Assert.Equal("league_of_legends", settings.DefaultLaunchProduct);
        Assert.Equal("fr", settings.Language);
    }

    [Theory]
    [InlineData("lol", "league_of_legends")]
    [InlineData("league", "league_of_legends")]
    [InlineData("valorant", "valorant")]
    [InlineData("VAL", "valorant")]
    [InlineData("client", "none")]
    [InlineData("", "none")]
    [InlineData("inconnu", "none")]
    public void NormalizeProduct_maps_aliases(string input, string expected)
    {
        Assert.Equal(expected, SettingsStore.NormalizeProduct(input));
    }
}
