using System.Text;
using RiotSwitcher.Core.Infrastructure;

namespace RiotSwitcher.Core.Tests;

public sealed class AtomicFileTests
{
    [Fact]
    public void Write_read_overwrite_and_delete()
    {
        var root = TestData.CreateTempRoot();
        try
        {
            var path = Path.Combine(root, "file.bin");

            AtomicFile.WriteAllBytes(path, Encoding.UTF8.GetBytes("hello"));
            Assert.Equal("hello", AtomicFile.ReadAllText(path));

            AtomicFile.WriteAllText(path, "bonjour");
            Assert.Equal("bonjour", AtomicFile.ReadAllText(path));

            Assert.Equal(
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
                AtomicFile.Sha256Hex(Encoding.UTF8.GetBytes("abc")));

            AtomicFile.TryDelete(path);
            Assert.False(File.Exists(path));
            AtomicFile.TryDelete(path);
            AtomicFile.TryDelete(null);
        }
        finally
        {
            TestData.Cleanup(root);
        }
    }

    [Fact]
    public void Write_creates_missing_directory()
    {
        var root = TestData.CreateTempRoot();
        try
        {
            var path = Path.Combine(root, "nested", "dir", "file.json");
            AtomicFile.WriteAllText(path, "{}");
            Assert.True(File.Exists(path));
        }
        finally
        {
            TestData.Cleanup(root);
        }
    }
}
