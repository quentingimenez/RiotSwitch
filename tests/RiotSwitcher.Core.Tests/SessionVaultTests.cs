using RiotSwitcher.Core.Riot;
using RiotSwitcher.Core.Vault;

namespace RiotSwitcher.Core.Tests;

public sealed class SessionVaultTests
{
    [Fact]
    public void Capture_get_and_metadata_roundtrip()
    {
        var root = TestData.CreateTempRoot();
        try
        {
            var paths = TestData.CreatePaths(root);
            var vault = new SessionVault(paths);

            var snapshot = TestData.Snapshot(TestData.MakePslYaml("puuid-a", "Alpha", "EUW"));
            var account = vault.Capture(snapshot, label: "Alpha");

            Assert.Equal("puuid-a", account.Id);
            Assert.Equal("Alpha", account.Label);
            Assert.Equal("Alpha#EUW", account.RiotId);
            Assert.False(account.Legacy);

            var accounts = vault.ListAccounts();
            Assert.Single(accounts);
            Assert.NotNull(vault.ResolveAccount("Alpha"));
            Assert.NotNull(vault.ResolveAccount("Alpha#EUW"));
            Assert.NotNull(vault.GetAccount("puuid-a"));

            var bundle = vault.GetBundle("puuid-a");
            Assert.Equal(snapshot.Sha256, bundle.Session.Sha256);
            Assert.Equal(snapshot.Text, bundle.Session.Text);

            vault.MarkUsed("puuid-a", DateTimeOffset.UtcNow);
            vault.MarkSwitched("puuid-a", DateTimeOffset.UtcNow);
            vault.SetLastError("puuid-a", "test");

            var updated = vault.GetAccount("puuid-a")!;
            Assert.NotNull(updated.LastUsedUtc);
            Assert.NotNull(updated.LastSwitchUtc);
            Assert.Equal("test", updated.LastError);

            Assert.True(vault.Rename("puuid-a", "Alpha 2"));
            Assert.Equal("Alpha 2", vault.GetAccount("puuid-a")!.Label);
        }
        finally
        {
            TestData.Cleanup(root);
        }
    }

    [Fact]
    public void Capture_two_accounts_and_delete_one()
    {
        var root = TestData.CreateTempRoot();
        try
        {
            var paths = TestData.CreatePaths(root);
            var vault = new SessionVault(paths);

            vault.Capture(TestData.Snapshot(TestData.MakePslYaml("puuid-a", "Alpha", "EUW")), label: "Alpha");
            vault.Capture(TestData.Snapshot(TestData.MakePslYaml("puuid-b", "Beta", "EUW")), label: "Beta");

            Assert.Equal(2, vault.ListAccounts().Count);

            Assert.True(vault.DeleteAccount("puuid-a"));
            Assert.Null(vault.GetAccount("puuid-a"));
            Assert.Single(vault.ListAccounts());
        }
        finally
        {
            TestData.Cleanup(root);
        }
    }

    [Fact]
    public void Accounts_can_be_reordered_and_sorted()
    {
        var root = TestData.CreateTempRoot();
        try
        {
            var paths = TestData.CreatePaths(root);
            var vault = new SessionVault(paths);

            vault.Capture(TestData.Snapshot(TestData.MakePslYaml("puuid-a", "Alpha", "EUW")), label: "Alpha");
            vault.Capture(TestData.Snapshot(TestData.MakePslYaml("puuid-b", "Beta", "EUW")), label: "Beta");
            vault.Capture(TestData.Snapshot(TestData.MakePslYaml("puuid-c", "Gamma", "EUW")), label: "Gamma");

            Assert.Equal(new[] { "Alpha", "Beta", "Gamma" }, vault.ListAccounts().Select(a => a.Label));

            Assert.True(vault.MoveAccount("puuid-b", -1));
            Assert.Equal(new[] { "Beta", "Alpha", "Gamma" }, vault.ListAccounts().Select(a => a.Label));
            Assert.False(vault.MoveAccount("puuid-b", -1));
            Assert.True(vault.MoveAccount("puuid-c", -1));
            Assert.Equal(new[] { "Beta", "Gamma", "Alpha" }, vault.ListAccounts().Select(a => a.Label));
            Assert.False(vault.MoveAccount("unknown", 1));

            vault.Rename("puuid-a", "Mike");
            vault.Rename("puuid-b", "Zeta");
            vault.Rename("puuid-c", "Alpha");
            Assert.True(vault.SortAccountsAlphabetically());
            Assert.Equal(new[] { "Alpha", "Mike", "Zeta" }, vault.ListAccounts().Select(a => a.Label));
            Assert.False(vault.SortAccountsAlphabetically());

            var reloaded = new SessionVault(paths);
            Assert.Equal(new[] { "Alpha", "Mike", "Zeta" }, reloaded.ListAccounts().Select(a => a.Label));
        }
        finally
        {
            TestData.Cleanup(root);
        }
    }

    [Fact]
    public void Unusable_session_is_refused()
    {
        var root = TestData.CreateTempRoot();
        try
        {
            var paths = TestData.CreatePaths(root);
            var vault = new SessionVault(paths);
            var dpop = TestData.Snapshot(TestData.MakePslYaml("puuid-a", "Alpha", "EUW", dpop: true));

            Assert.Throws<VaultException>(() => vault.Capture(dpop, label: "Alpha"));
            Assert.Empty(vault.ListAccounts());
        }
        finally
        {
            TestData.Cleanup(root);
        }
    }

    [Fact]
    public void Backups_roundtrip_and_are_pruned()
    {
        var root = TestData.CreateTempRoot();
        try
        {
            var paths = TestData.CreatePaths(root);
            var vault = new SessionVault(paths);
            var snapshot = TestData.Snapshot(TestData.MakePslYaml("puuid-a", "Alpha", "EUW"));

            var backup = vault.CreateBackup(snapshot, "test");
            Assert.True(File.Exists(backup.FullPath));

            var backups = vault.ListBackups();
            Assert.Single(backups);

            var opened = vault.OpenBackup(backup.FileName);
            Assert.Equal(snapshot.Sha256, opened.Session.Sha256);

            for (var i = 0; i < SessionVault.MaxBackups + 2; i++)
            {
                vault.CreateBackup(snapshot, $"test-{i}");
            }

            Assert.Equal(SessionVault.MaxBackups, vault.ListBackups().Count);
        }
        finally
        {
            TestData.Cleanup(root);
        }
    }

    [Fact]
    public void Legacy_account_uses_generated_id()
    {
        var root = TestData.CreateTempRoot();
        try
        {
            var paths = TestData.CreatePaths(root);
            var vault = new SessionVault(paths);
            var legacy = TestData.Snapshot(TestData.MakeLegacyYaml());

            var account = vault.Capture(legacy, label: "Legacy");

            Assert.True(account.Legacy);
            Assert.StartsWith("legacy-", account.Id);
            Assert.NotNull(vault.GetBundle(account.Id));
        }
        finally
        {
            TestData.Cleanup(root);
        }
    }
}
