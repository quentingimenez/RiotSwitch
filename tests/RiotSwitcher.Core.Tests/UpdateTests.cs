using System.IO.Compression;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using RiotSwitcher.Core.Updates;

namespace RiotSwitcher.Core.Tests;

public sealed class UpdateTests
{
    [Theory]
    [InlineData("1.2.3", 1, 2, 3)]
    [InlineData("v1.2.3", 1, 2, 3)]
    [InlineData("V10.0.7", 10, 0, 7)]
    public void Version_parses_semver_and_v_prefix(string text, int major, int minor, int patch)
    {
        Assert.True(UpdateVersion.TryParse(text, out var version));
        Assert.Equal(new UpdateVersion(major, minor, patch), version);
        Assert.Equal($"{major}.{minor}.{patch}", version.ToString());
    }

    [Theory]
    [InlineData("")]
    [InlineData("1.2")]
    [InlineData("1.2.3.4")]
    [InlineData("1.2.3-beta")]
    [InlineData("one.two.three")]
    [InlineData("v-1.2.3")]
    public void Version_rejects_invalid_values(string text)
    {
        Assert.False(UpdateVersion.TryParse(text, out _));
    }

    [Fact]
    public void Version_compares_numerically()
    {
        Assert.True(UpdateVersion.Parse("1.10.0") > UpdateVersion.Parse("1.9.9"));
        Assert.True(UpdateVersion.Parse("2.0.0") > UpdateVersion.Parse("1.99.99"));
        Assert.Equal(UpdateVersion.Parse("v1.2.3"), UpdateVersion.Parse("1.2.3"));
    }

    [Fact]
    public async Task Check_returns_available_when_release_is_newer()
    {
        var latestJson = LatestReleaseJson("v1.1.0");
        var client = CreateClient(latestJson, out _);

        var result = await client.CheckAsync();

        Assert.True(result.Success);
        Assert.True(result.UpdateAvailable);
        Assert.NotNull(result.Update);
        Assert.Equal(UpdateVersion.Parse("1.1.0"), result.Update!.Version);
        Assert.Equal("v1.1.0", result.Update.Tag);
        Assert.Equal(AppInfo.UpdateAssetName, result.Update.AssetUrl.Segments[^1]);
    }

    [Fact]
    public async Task Check_returns_no_update_for_same_version()
    {
        var client = CreateClient(LatestReleaseJson("v1.0.0"), out _);

        var result = await client.CheckAsync();

        Assert.True(result.Success);
        Assert.False(result.UpdateAvailable);
        Assert.Equal("v1.0.0", result.LatestTag);
    }

    [Fact]
    public async Task Check_fails_when_release_has_no_checksum_asset()
    {
        var client = CreateClient(LatestReleaseJson("v1.1.0", includeChecksum: false), out _);

        var result = await client.CheckAsync();

        Assert.False(result.Success);
        Assert.Contains("checksum", result.Error, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task Download_verifies_sha256_and_writes_archive()
    {
        var payload = Encoding.UTF8.GetBytes("fake zip payload");
        var hash = Convert.ToHexString(SHA256.HashData(payload)).ToLowerInvariant();

        var handler = new StubHandler(request =>
        {
            var path = request.RequestUri!.AbsolutePath;
            if (path.EndsWith(".sha256", StringComparison.OrdinalIgnoreCase))
            {
                return TextResponse($"{hash}  {AppInfo.UpdateAssetName}\n");
            }

            if (path.EndsWith(".zip", StringComparison.OrdinalIgnoreCase))
            {
                return BytesResponse(payload);
            }

            return TextResponse(LatestReleaseJson("v1.1.0"));
        });

        var client = new GitHubUpdateClient("owner", "repo", UpdateVersion.Parse("1.0.0"), handler);
        var updateResult = await client.CheckAsync();
        Assert.True(updateResult.UpdateAvailable);

        var root = TestData.CreateTempRoot();
        try
        {
            var destination = Path.Combine(root, AppInfo.UpdateAssetName);
            var returned = await client.DownloadAndVerifyAsync(updateResult.Update!, destination);

            Assert.Equal(destination, returned);
            Assert.True(File.Exists(destination));
            Assert.Equal(payload, await File.ReadAllBytesAsync(destination));
        }
        finally
        {
            TestData.Cleanup(root);
        }
    }

    [Fact]
    public async Task Download_rejects_bad_sha256()
    {
        var payload = Encoding.UTF8.GetBytes("fake zip payload");
        var wrongHash = new string('0', 64);

        var handler = new StubHandler(request =>
        {
            var path = request.RequestUri!.AbsolutePath;
            if (path.EndsWith(".sha256", StringComparison.OrdinalIgnoreCase))
            {
                return TextResponse(wrongHash + "\n");
            }

            if (path.EndsWith(".zip", StringComparison.OrdinalIgnoreCase))
            {
                return BytesResponse(payload);
            }

            return TextResponse(LatestReleaseJson("v1.1.0"));
        });

        var client = new GitHubUpdateClient("owner", "repo", UpdateVersion.Parse("1.0.0"), handler);
        var root = TestData.CreateTempRoot();
        try
        {
            var result = await client.CheckAsync();
            Assert.True(result.UpdateAvailable);

            var destination = Path.Combine(root, AppInfo.UpdateAssetName);
            await Assert.ThrowsAsync<UpdateException>(() =>
                client.DownloadAndVerifyAsync(result.Update!, destination));
            Assert.False(File.Exists(destination));
        }
        finally
        {
            TestData.Cleanup(root);
        }
    }

    [Fact]
    public void Zip_extractor_extracts_normal_entries()
    {
        var root = TestData.CreateTempRoot();
        try
        {
            var zipPath = Path.Combine(root, "ok.zip");
            using (var archive = ZipFile.Open(zipPath, ZipArchiveMode.Create))
            {
                var entry = archive.CreateEntry("docs/readme.txt");
                using var writer = new StreamWriter(entry.Open());
                writer.Write("bonjour");
            }

            var destination = Path.Combine(root, "out");
            ZipSafeExtractor.ExtractToDirectory(zipPath, destination);

            Assert.Equal("bonjour", File.ReadAllText(Path.Combine(destination, "docs", "readme.txt")));
        }
        finally
        {
            TestData.Cleanup(root);
        }
    }

    [Fact]
    public void Zip_extractor_rejects_zip_slip()
    {
        var root = TestData.CreateTempRoot();
        try
        {
            var zipPath = Path.Combine(root, "evil.zip");
            using (var archive = ZipFile.Open(zipPath, ZipArchiveMode.Create))
            {
                var entry = archive.CreateEntry("../evil.txt");
                using var writer = new StreamWriter(entry.Open());
                writer.Write("evil");
            }

            var destination = Path.Combine(root, "out");
            Assert.Throws<InvalidDataException>(() => ZipSafeExtractor.ExtractToDirectory(zipPath, destination));
            Assert.False(File.Exists(Path.Combine(root, "evil.txt")));
        }
        finally
        {
            TestData.Cleanup(root);
        }
    }

    private static GitHubUpdateClient CreateClient(string latestJson, out StubHandler handler)
    {
        handler = new StubHandler(_ => TextResponse(latestJson));
        return new GitHubUpdateClient("owner", "repo", UpdateVersion.Parse("1.0.0"), handler);
    }

    private static string LatestReleaseJson(string tag, bool includeChecksum = true)
    {
        var checksumAsset = includeChecksum
            ? """
              ,{"name":"RiotSwitch-win-x64.zip.sha256","browser_download_url":"https://github.com/owner/repo/releases/download/v1.1.0/RiotSwitch-win-x64.zip.sha256"}
              """
            : string.Empty;

        return $$"""
                 {
                   "tag_name": "{{tag}}",
                   "name": "RiotSwitch {{tag}}",
                   "body": "Notes de version.",
                   "html_url": "https://github.com/owner/repo/releases/tag/{{tag}}",
                   "assets": [
                     {"name":"RiotSwitch-win-x64.zip","browser_download_url":"https://github.com/owner/repo/releases/download/v1.1.0/RiotSwitch-win-x64.zip"}
                     {{checksumAsset}}
                   ]
                 }
                 """;
    }

    private static HttpResponseMessage TextResponse(string text) =>
        new(HttpStatusCode.OK)
        {
            Content = new StringContent(text, Encoding.UTF8, "text/plain")
        };

    private static HttpResponseMessage BytesResponse(byte[] bytes) =>
        new(HttpStatusCode.OK)
        {
            Content = new ByteArrayContent(bytes)
        };

    private sealed class StubHandler : HttpMessageHandler
    {
        private readonly Func<HttpRequestMessage, HttpResponseMessage> _responder;

        public StubHandler(Func<HttpRequestMessage, HttpResponseMessage> responder) =>
            _responder = responder;

        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken) =>
            Task.FromResult(_responder(request));
    }
}
