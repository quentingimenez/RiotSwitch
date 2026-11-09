using RiotSwitcher.Core.Riot;

namespace RiotSwitcher.Core.Tests;

public sealed class RiotLocalApiTests
{
    [Fact]
    public void MissingLockfile_ReturnsNull()
    {
        var root = TestData.CreateTempRoot();
        try
        {
            var paths = TestData.CreatePaths(root);
            var api = new RiotLocalApi(paths);

            Assert.Null(api.TryGetAuthorization(TimeSpan.FromMilliseconds(100)));
            Assert.False(api.TryShowClient(TimeSpan.FromMilliseconds(100)));
        }
        finally
        {
            TestData.Cleanup(root);
        }
    }

    [Fact]
    public void MalformedLockfile_ReturnsNull()
    {
        var root = TestData.CreateTempRoot();
        try
        {
            var paths = TestData.CreatePaths(root);
            Directory.CreateDirectory(Path.GetDirectoryName(paths.LockfilePath)!);
            File.WriteAllText(paths.LockfilePath, "pas-un-lockfile");

            var api = new RiotLocalApi(paths);

            Assert.Null(api.TryGetAuthorization(TimeSpan.FromMilliseconds(100)));
            Assert.False(api.TryShowClient(TimeSpan.FromMilliseconds(100)));
        }
        finally
        {
            TestData.Cleanup(root);
        }
    }
}
