using RiotSwitcher.Core.Riot;

namespace RiotSwitcher.Core.Tests;

public sealed class RiotProcessControllerTests
{
    [Fact]
    public void BuildServiceStartInfo_RemovesElectronRunAsNode()
    {
        var root = TestData.CreateTempRoot();
        var previous = Environment.GetEnvironmentVariable("ELECTRON_RUN_AS_NODE");
        try
        {
            var paths = TestData.CreatePaths(root);
            Environment.SetEnvironmentVariable("ELECTRON_RUN_AS_NODE", "1");

            var psi = RiotProcessController.BuildServiceStartInfo(paths, launchProduct: null);

            Assert.False(psi.UseShellExecute);
            Assert.DoesNotContain(
                psi.Environment.Keys,
                key => string.Equals(key, "ELECTRON_RUN_AS_NODE", StringComparison.OrdinalIgnoreCase));
        }
        finally
        {
            Environment.SetEnvironmentVariable("ELECTRON_RUN_AS_NODE", previous);
            TestData.Cleanup(root);
        }
    }

    [Fact]
    public void BuildServiceStartInfo_AddsProductArguments()
    {
        var root = TestData.CreateTempRoot();
        try
        {
            var paths = TestData.CreatePaths(root);

            var psi = RiotProcessController.BuildServiceStartInfo(paths, "league_of_legends", "live");

            Assert.Contains("--launch-product=league_of_legends", psi.Arguments, StringComparison.Ordinal);
            Assert.Contains("--launch-patchline=live", psi.Arguments, StringComparison.Ordinal);
        }
        finally
        {
            TestData.Cleanup(root);
        }
    }
}
