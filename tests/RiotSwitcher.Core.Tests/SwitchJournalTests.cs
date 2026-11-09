using RiotSwitcher.Core.Switching;

namespace RiotSwitcher.Core.Tests;

public sealed class SwitchJournalTests
{
    [Fact]
    public void Begin_update_phase_and_clear()
    {
        var root = TestData.CreateTempRoot();
        try
        {
            var paths = TestData.CreatePaths(root);
            var journal = new SwitchJournal(paths);

            var entry = journal.Begin("puuid-b", "Beta", "puuid-a", "backup.rsw");
            Assert.Equal("puuid-b", entry.TargetAccountId);
            Assert.Equal("starting", entry.Phase);
            Assert.Equal("puuid-a", entry.CurrentAccountId);

            var loaded = journal.Load();
            Assert.NotNull(loaded);
            Assert.Equal("puuid-b", loaded.TargetAccountId);

            journal.Update(e => e.ClientClosed = true);
            journal.SetPhase("writing");

            loaded = journal.Load()!;
            Assert.True(loaded.ClientClosed);
            Assert.Equal("writing", loaded.Phase);
            Assert.NotEqual(default, loaded.UpdatedUtc);

            journal.Clear();
            Assert.Null(journal.Load());
        }
        finally
        {
            TestData.Cleanup(root);
        }
    }

    [Fact]
    public void Update_without_begin_is_noop()
    {
        var root = TestData.CreateTempRoot();
        try
        {
            var paths = TestData.CreatePaths(root);
            var journal = new SwitchJournal(paths);

            journal.Update(e => e.ClientClosed = true);
            journal.SetPhase("x");

            Assert.Null(journal.Load());
        }
        finally
        {
            TestData.Cleanup(root);
        }
    }
}
