using RiotSwitcher.Core.Riot;
using RiotSwitcher.Core.Switching;
using RiotSwitcher.Core.Vault;

namespace RiotSwitcher.Core.Tests;

public sealed class SwitchServiceTests
{
    private sealed class FakeProcessController : IRiotProcessController
    {
        public RiotClientWindowInfo? Window { get; set; } =
            new(IntPtr.Zero, 123, "Riot Client", 0, 0, 1536, 864, false);

        public bool UiRunning { get; set; } = true;
        public bool CloseResult { get; set; } = true;
        public int StackRemaining { get; set; }
        public bool StartResult { get; set; } = true;
        public bool KillLeagueResult { get; set; } = true;

        public List<string> Calls { get; } = new();

        public IReadOnlyList<RiotProcessInfo> FindRiotProcesses() => Array.Empty<RiotProcessInfo>();

        public RiotProcessInfo? FindClientUi() =>
            UiRunning ? new RiotProcessInfo(5, RiotProcessNames.ClientUi, DateTime.Now) : null;

        public RiotProcessInfo? FindService() => null;

        public bool TryCloseClientUi(TimeSpan timeout, out bool graceful)
        {
            Calls.Add("close");
            if (!CloseResult)
            {
                graceful = false;
                return false;
            }

            UiRunning = false;
            graceful = true;
            return true;
        }

        public bool TryKill(RiotProcessInfo process, TimeSpan timeout)
        {
            Calls.Add("kill");
            return true;
        }

        public int TryKillRiotStack(TimeSpan timeout)
        {
            Calls.Add("kill-stack");
            return StackRemaining;
        }

        public bool TryKillLeagueClient(TimeSpan timeout)
        {
            Calls.Add("kill-league");
            return KillLeagueResult;
        }

        public bool StartService(string? launchProduct, string? launchPatchline = "live")
        {
            Calls.Add("start:" + (string.IsNullOrWhiteSpace(launchProduct) ? "none" : launchProduct));
            return StartResult;
        }

        public RiotClientWindowInfo? WaitForClientWindow(TimeSpan timeout)
        {
            Calls.Add("wait-window");
            return Window;
        }
    }

    private sealed class FakeLocalApi : IRiotLocalApi
    {
        public RiotAuthorizationInfo? Authorization { get; set; }

        public List<string> Calls { get; } = new();

        public RiotAuthorizationInfo? TryGetAuthorization(TimeSpan? timeout = null)
        {
            Calls.Add("authorization");
            return Authorization;
        }

        public bool TryShowClient(TimeSpan? timeout = null)
        {
            Calls.Add("show");
            return true;
        }
    }

    private sealed class FakeGameGuard : IGameGuard
    {
        public GameGuardStatus Status { get; set; } = GameGuardStatus.Allow();

        public GameGuardStatus Check() => Status;
    }

    private sealed class Harness : IDisposable
    {
        public string Root { get; }
        public RiotPaths Paths { get; }
        public SessionVault Vault { get; }
        public FakeProcessController Processes { get; } = new();
        public FakeGameGuard Guard { get; } = new();
        public FakeLocalApi LocalApi { get; } = new();
        public SwitchService Service { get; }

        public Harness()
        {
            Root = TestData.CreateTempRoot();
            Paths = TestData.CreatePaths(Root);
            File.WriteAllText(Paths.LiveSessionFile, TestData.MakePslYaml("puuid-a", "Alpha", "EUW"));

            Vault = new SessionVault(Paths);
            Vault.Capture(TestData.Snapshot(File.ReadAllText(Paths.LiveSessionFile)), label: "Alpha");
            Vault.Capture(TestData.Snapshot(TestData.MakePslYaml("puuid-b", "Beta", "EUW")), label: "Beta");

            Service = new SwitchService(
                Paths,
                Vault,
                Processes,
                Guard,
                localApi: LocalApi,
                verificationTimeout: TimeSpan.FromMilliseconds(400));
        }

        public static RiotClientWindowInfo RealClientWindow() =>
            new(new IntPtr(42), 123, "Riot Client", 0, 0, 1536, 864, false);

        public RiotSessionInfo LiveSession() =>
            RiotSessionReader.Parse(File.ReadAllText(Paths.LiveSessionFile));

        public void Dispose() => TestData.Cleanup(Root);
    }

    [Fact]
    public void Switch_writes_target_session_and_relaunches()
    {
        using var harness = new Harness();

        var result = harness.Service.Switch(new SwitchRequest { AccountId = "puuid-b" });

        Assert.True(result.IsSuccess, result.Message);
        Assert.Equal(SwitchOutcome.Success, result.Outcome);
        Assert.Equal("puuid-b", harness.LiveSession().Puuid);
        Assert.Contains("close", harness.Processes.Calls);
        Assert.Contains("kill-stack", harness.Processes.Calls);
        Assert.Contains("start:none", harness.Processes.Calls);
        Assert.Contains("wait-window", harness.Processes.Calls);
        Assert.Null(harness.Service.Journal.Load());
        Assert.NotNull(harness.Vault.GetAccount("puuid-b")!.LastSwitchUtc);
    }

    [Fact]
    public void Already_current_is_a_noop()
    {
        using var harness = new Harness();

        var result = harness.Service.Switch(new SwitchRequest { AccountId = "puuid-a" });

        Assert.Equal(SwitchOutcome.AlreadyCurrent, result.Outcome);
        Assert.DoesNotContain("close", harness.Processes.Calls);
    }

    [Fact]
    public void Game_running_blocks_without_touching_processes()
    {
        using var harness = new Harness();
        harness.Guard.Status = new GameGuardStatus(
            GameGuardResult.GameRunning,
            new[] { RiotProcessNames.LeagueGame },
            "partie en cours");

        var result = harness.Service.Switch(new SwitchRequest { AccountId = "puuid-b" });

        Assert.Equal(SwitchOutcome.GameRunning, result.Outcome);
        Assert.DoesNotContain("close", harness.Processes.Calls);
        Assert.Equal("puuid-a", harness.LiveSession().Puuid);
    }

    [Fact]
    public void League_client_requires_confirmation()
    {
        using var harness = new Harness();
        harness.Guard.Status = new GameGuardStatus(
            GameGuardResult.LeagueClientRunning,
            new[] { RiotProcessNames.LeagueClient },
            "client League ouvert");

        var result = harness.Service.Switch(new SwitchRequest
        {
            AccountId = "puuid-b",
            ConfirmClientClose = _ => false
        });

        Assert.Equal(SwitchOutcome.ConfirmationDeclined, result.Outcome);
        Assert.DoesNotContain("close", harness.Processes.Calls);
    }

    [Fact]
    public void Window_timeout_keeps_target_installed()
    {
        using var harness = new Harness();
        harness.Processes.Window = null;

        var result = harness.Service.Switch(new SwitchRequest { AccountId = "puuid-b" });

        Assert.Equal(SwitchOutcome.Timeout, result.Outcome);
        Assert.Equal("puuid-b", harness.LiveSession().Puuid);
        Assert.NotNull(harness.Vault.GetAccount("puuid-b")!.LastSwitchUtc);
        Assert.Null(harness.Service.Journal.Load());
    }

    [Fact]
    public void Access_denied_leaves_current_session()
    {
        using var harness = new Harness();
        harness.Processes.CloseResult = false;

        var result = harness.Service.Switch(new SwitchRequest { AccountId = "puuid-b" });

        Assert.Equal(SwitchOutcome.AccessDenied, result.Outcome);
        Assert.Equal("puuid-a", harness.LiveSession().Puuid);
        Assert.DoesNotContain("kill-stack", harness.Processes.Calls);
    }

    [Fact]
    public void Missing_install_is_reported()
    {
        using var harness = new Harness();
        File.Delete(harness.Paths.ServiceExe);

        var result = harness.Service.Switch(new SwitchRequest { AccountId = "puuid-b" });

        Assert.Equal(SwitchOutcome.ClientNotInstalled, result.Outcome);
        Assert.DoesNotContain("close", harness.Processes.Calls);
    }

    [Fact]
    public void Launch_after_switch_false_only_installs_session()
    {
        using var harness = new Harness();

        var result = harness.Service.Switch(new SwitchRequest
        {
            AccountId = "puuid-b",
            LaunchAfterSwitch = false
        });

        Assert.True(result.IsSuccess, result.Message);
        Assert.Equal("puuid-b", harness.LiveSession().Puuid);
        Assert.DoesNotContain("start:none", harness.Processes.Calls);
        Assert.Null(harness.Service.Journal.Load());
    }

    [Fact]
    public void Expired_target_session_leaves_client_on_login_page()
    {
        using var harness = new Harness();
        harness.Processes.Window = Harness.RealClientWindow();

        var result = harness.Service.Switch(new SwitchRequest { AccountId = "puuid-b" });

        Assert.Equal(SwitchOutcome.ReconnectRequired, result.Outcome);
        Assert.False(result.RolledBack);
        Assert.Contains("écran de connexion", result.Message);
        Assert.NotEmpty(harness.LocalApi.Calls);

        // La session cible reste installée et le client n'est ni tué ni relancé une seconde fois.
        Assert.Equal("puuid-b", harness.LiveSession().Puuid);
        Assert.Single(harness.Processes.Calls, call => call == "kill-stack");
        Assert.Single(harness.Processes.Calls, call => call == "start:none");
        Assert.Null(harness.Service.Journal.Load());

        var account = harness.Vault.GetAccount("puuid-b")!;
        Assert.NotNull(account.LastSwitchUtc);
        Assert.Equal(
            "Session expirée : reconnecte-toi dans le client Riot, puis ajoute à nouveau le compte.",
            account.LastError);
    }

    [Fact]
    public void Other_account_after_relaunch_rolls_back()
    {
        using var harness = new Harness();
        harness.Processes.Window = Harness.RealClientWindow();
        harness.LocalApi.Authorization = new RiotAuthorizationInfo("puuid-a", "EUW1", null);

        var result = harness.Service.Switch(new SwitchRequest { AccountId = "puuid-b" });

        Assert.Equal(SwitchOutcome.VerificationFailed, result.Outcome);
        Assert.True(result.RolledBack);

        // Le compte précédent est restauré, puis le client est relancé (deuxième cycle arrêt/démarrage).
        Assert.Equal("puuid-a", harness.LiveSession().Puuid);
        Assert.Equal(2, harness.Processes.Calls.Count(call => call == "kill-stack"));
        Assert.Equal(2, harness.Processes.Calls.Count(call => call == "start:none"));
        Assert.Equal(
            "Switch annulé : retour au compte précédent.",
            harness.Vault.GetAccount("puuid-b")!.LastError);
    }

    [Fact]
    public void Confirmed_target_account_succeeds_after_relaunch()
    {
        using var harness = new Harness();
        harness.Processes.Window = Harness.RealClientWindow();
        harness.LocalApi.Authorization = new RiotAuthorizationInfo("puuid-b", "EUW1", null);

        var result = harness.Service.Switch(new SwitchRequest { AccountId = "puuid-b" });

        Assert.Equal(SwitchOutcome.Success, result.Outcome);
        Assert.Equal("puuid-b", harness.LiveSession().Puuid);
        Assert.Single(harness.Processes.Calls, call => call == "kill-stack");
        Assert.Null(harness.Vault.GetAccount("puuid-b")!.LastError);
    }
}
