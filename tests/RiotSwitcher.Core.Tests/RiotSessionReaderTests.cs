using RiotSwitcher.Core.Riot;

namespace RiotSwitcher.Core.Tests;

public sealed class RiotSessionReaderTests
{
    [Fact]
    public void PslV1_session_is_parsed_and_switchable()
    {
        var snapshot = TestData.Snapshot(TestData.MakePslYaml("puuid-a", "PlayerOne", "EUW"));

        Assert.Equal(RiotSessionFormat.PslV1, snapshot.Info.Format);
        Assert.True(snapshot.Info.HasIdToken);
        Assert.True(snapshot.Info.HasRefreshToken);
        Assert.True(snapshot.Info.CanSwitch);
        Assert.Equal("puuid-a", snapshot.Info.Puuid);
        Assert.Equal("PlayerOne#EUW", snapshot.Info.RiotId);
        Assert.Equal("fr", snapshot.Info.Locale);
        Assert.Equal("fra", snapshot.Info.Country);
        Assert.Equal("euw1", snapshot.Info.Region);
        Assert.True(snapshot.Length > 0);
        Assert.Equal(64, snapshot.Sha256.Length);
    }

    [Fact]
    public void Dpop_bound_session_is_not_switchable()
    {
        var snapshot = TestData.Snapshot(TestData.MakePslYaml("puuid-a", "PlayerOne", "EUW", dpop: true));

        Assert.True(snapshot.Info.IsDpopBound);
        Assert.False(snapshot.Info.CanSwitch);
        Assert.Contains("DPoP", snapshot.Info.UnsupportedReason);
    }

    [Fact]
    public void Non_persistent_session_is_not_switchable()
    {
        var snapshot = TestData.Snapshot(TestData.MakePslYaml("puuid-a", "PlayerOne", "EUW", persist: false));

        Assert.False(snapshot.Info.IsPersistent);
        Assert.False(snapshot.Info.CanSwitch);
        Assert.Contains("Rester connecté", snapshot.Info.UnsupportedReason);
    }

    [Fact]
    public void Missing_refresh_token_is_not_switchable()
    {
        var snapshot = TestData.Snapshot(TestData.MakePslYaml("puuid-a", "PlayerOne", "EUW", includeRefresh: false));

        Assert.True(snapshot.Info.HasIdToken);
        Assert.False(snapshot.Info.HasRefreshToken);
        Assert.False(snapshot.Info.CanSwitch);
    }

    [Fact]
    public void Legacy_cookie_format_is_recognised()
    {
        var snapshot = TestData.Snapshot(TestData.MakeLegacyYaml());

        Assert.Equal(RiotSessionFormat.LegacyCookies, snapshot.Info.Format);
        Assert.True(snapshot.Info.HasLegacyCookies);
        Assert.True(snapshot.Info.CanSwitch);
        Assert.Null(snapshot.Info.Identity);
    }

    [Fact]
    public void Unknown_format_is_rejected()
    {
        var snapshot = TestData.Snapshot("foo: bar\r\n");

        Assert.Equal(RiotSessionFormat.Unknown, snapshot.Info.Format);
        Assert.False(snapshot.Info.CanSwitch);
        Assert.NotNull(snapshot.Info.UnsupportedReason);
    }

    [Fact]
    public void Empty_file_throws()
    {
        Assert.Throws<InvalidDataException>(() => RiotSessionReader.Snapshot(Array.Empty<byte>(), "x.yaml"));
    }
}
