using System.Text.Json;
using RiotSwitcher.Core.Riot;

namespace RiotSwitcher.Core.Tests;

public sealed class RiotInstallLocatorTests
{
    [Fact]
    public void Finds_install_from_program_data_file()
    {
        var root = TestData.CreateTempRoot();
        try
        {
            var paths = TestData.CreatePaths(root);
            var programData = Path.Combine(paths.ProgramDataRoot, "Riot Games");
            Directory.CreateDirectory(programData);

            var json = JsonSerializer.Serialize(new Dictionary<string, string>
            {
                ["rc_live"] = paths.InstallRoot
            });
            File.WriteAllText(Path.Combine(programData, "RiotClientInstalls.json"), json);

            var found = RiotInstallLocator.FindInstallRoot(programData);

            Assert.NotNull(found);
            Assert.Equal(Path.GetFullPath(paths.InstallRoot), Path.GetFullPath(found!));
        }
        finally
        {
            TestData.Cleanup(root);
        }
    }

    [Fact]
    public void Accepts_executable_path_in_program_data_file()
    {
        var root = TestData.CreateTempRoot();
        try
        {
            var paths = TestData.CreatePaths(root);
            var programData = Path.Combine(paths.ProgramDataRoot, "Riot Games");
            Directory.CreateDirectory(programData);

            var json = JsonSerializer.Serialize(new Dictionary<string, string>
            {
                ["rc_live"] = paths.ServiceExe
            });
            File.WriteAllText(Path.Combine(programData, "RiotClientInstalls.json"), json);

            var found = RiotInstallLocator.FindInstallRoot(programData);

            Assert.NotNull(found);
            Assert.Equal(Path.GetFullPath(paths.InstallRoot), Path.GetFullPath(found!));
        }
        finally
        {
            TestData.Cleanup(root);
        }
    }
}
