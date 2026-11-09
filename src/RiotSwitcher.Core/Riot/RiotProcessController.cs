using System.Diagnostics;
using System.Text;

namespace RiotSwitcher.Core.Riot;

public static class RiotProcessNames
{
    public const string ClientUi = "Riot Client";
    public const string Service = "RiotClientServices";
    public const string CrashHandler = "RiotClientCrashHandler";
    public const string Ux = "RiotClientUx";
    public const string UxRender = "RiotClientUxRender";

    public const string LeagueGame = "League of Legends";
    public const string LeagueClient = "LeagueClient";
    public const string LeagueClientUx = "LeagueClientUx";
    public const string LeagueClientUxRender = "LeagueClientUxRender";
    public const string Valorant = "VALORANT";
    public const string ValorantShipping = "VALORANT-Win64-Shipping";
    public const string LegendsOfRuneterra = "LoR";

    public static readonly string[] RiotProcesses =
    {
        ClientUi, Service, CrashHandler, Ux, UxRender
    };

    public static readonly string[] LeagueClientProcesses =
    {
        LeagueClient, LeagueClientUx, LeagueClientUxRender
    };

    public static bool IsRiot(string processName) =>
        RiotProcesses.Any(n => string.Equals(n, processName, StringComparison.OrdinalIgnoreCase));
}

public sealed record RiotProcessInfo(int Id, string Name, DateTime? StartTimeLocal)
{
    public bool IsClientUi => string.Equals(Name, RiotProcessNames.ClientUi, StringComparison.OrdinalIgnoreCase);
    public bool IsService => string.Equals(Name, RiotProcessNames.Service, StringComparison.OrdinalIgnoreCase);
    public bool IsCrashHandler => string.Equals(Name, RiotProcessNames.CrashHandler, StringComparison.OrdinalIgnoreCase);
}

public interface IRiotProcessController
{
    IReadOnlyList<RiotProcessInfo> FindRiotProcesses();
    RiotProcessInfo? FindClientUi();
    RiotProcessInfo? FindService();

    /// <summary>Ferme l'UI (WM_CLOSE) puis force si nécessaire. Retourne true si plus d'UI.</summary>
    bool TryCloseClientUi(TimeSpan timeout, out bool graceful);

    bool TryKill(RiotProcessInfo process, TimeSpan timeout);

    /// <summary>Tue crash handler + service + UI, avec quelques tentatives de respawn. Retourne le nombre restant.</summary>
    int TryKillRiotStack(TimeSpan timeout);

    /// <summary>Ferme le client League (pas le jeu) après confirmation. Retourne true si plus de client.</summary>
    bool TryKillLeagueClient(TimeSpan timeout);

    bool StartService(string? launchProduct, string? launchPatchline = "live");

    RiotClientWindowInfo? WaitForClientWindow(TimeSpan timeout);
}

public sealed class RiotProcessController : IRiotProcessController
{
    private readonly RiotPaths _paths;

    public RiotProcessController(RiotPaths paths)
    {
        _paths = paths ?? throw new ArgumentNullException(nameof(paths));
    }

    public IReadOnlyList<RiotProcessInfo> FindRiotProcesses() => FindProcesses(RiotProcessNames.IsRiot);

    public RiotProcessInfo? FindClientUi() => FindProcessByName(RiotProcessNames.ClientUi);

    public RiotProcessInfo? FindService() => FindProcessByName(RiotProcessNames.Service);

    public bool TryCloseClientUi(TimeSpan timeout, out bool graceful)
    {
        graceful = false;
        var ui = FindClientUi();
        if (ui is null)
        {
            graceful = true;
            return true;
        }

        var window = RiotClientWindow.Find();
        var handle = window?.Handle ?? IntPtr.Zero;
        if (handle == IntPtr.Zero)
        {
            try
            {
                using var process = Process.GetProcessById(ui.Id);
                handle = process.MainWindowHandle;
            }
            catch
            {
                // Processus déjà terminé.
            }
        }

        if (handle != IntPtr.Zero)
        {
            try
            {
                Interop.NativeMethods.PostMessage(handle, Interop.NativeMethods.WM_CLOSE, IntPtr.Zero, IntPtr.Zero);
            }
            catch
            {
                // Fallback kill.
            }

            if (WaitForProcessExit(ui.Id, timeout))
            {
                graceful = true;
                return true;
            }
        }

        TryKill(ui, TimeSpan.FromSeconds(5));
        return FindClientUi() is null;
    }

    public bool TryKill(RiotProcessInfo process, TimeSpan timeout)
    {
        try
        {
            using var instance = Process.GetProcessById(process.Id);
            if (instance.HasExited) return true;

            instance.Kill(entireProcessTree: false);
            return WaitForProcessExit(process.Id, timeout);
        }
        catch (ArgumentException)
        {
            return true;
        }
        catch
        {
            return false;
        }
    }

    public int TryKillRiotStack(TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow + timeout;

        for (var attempt = 0; attempt < 3; attempt++)
        {
            var processes = FindRiotProcesses();
            if (processes.Count == 0) return 0;

            foreach (var process in processes
                         .OrderBy(p => p.IsCrashHandler ? 0 : p.IsService ? 1 : 2)
                         .ThenBy(p => p.Id))
            {
                TryKill(process, TimeSpan.FromSeconds(4));
            }

            if (WaitForNoRiotProcesses(TimeSpan.FromSeconds(2))) return 0;
            if (DateTime.UtcNow >= deadline) break;

            Thread.Sleep(700);
        }

        return FindRiotProcesses().Count;
    }

    public bool TryKillLeagueClient(TimeSpan timeout)
    {
        var processes = FindProcesses(n => RiotProcessNames.LeagueClientProcesses
            .Any(name => string.Equals(name, n, StringComparison.OrdinalIgnoreCase)));

        if (processes.Count == 0) return true;

        foreach (var process in processes)
        {
            try
            {
                using var instance = Process.GetProcessById(process.Id);
                if (!instance.HasExited)
                {
                    instance.CloseMainWindow();
                }
            }
            catch
            {
                // Best-effort.
            }
        }

        WaitForProcessesExit(processes.Select(p => p.Id), TimeSpan.FromSeconds(2));

        foreach (var process in processes)
        {
            TryKill(process, TimeSpan.FromSeconds(3));
        }

        return FindProcesses(n => RiotProcessNames.LeagueClientProcesses
            .Any(name => string.Equals(name, n, StringComparison.OrdinalIgnoreCase))).Count == 0;
    }

    public bool StartService(string? launchProduct, string? launchPatchline = "live")
    {
        if (!File.Exists(_paths.ServiceExe)) return false;

        var psi = BuildServiceStartInfo(_paths, launchProduct, launchPatchline);

        try
        {
            using var started = Process.Start(psi);
            return true;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>
    /// Construit le démarrage du service Riot. Le service transmet son environnement
    /// à l'UX Electron ; un environnement hérité de l'hôte (par ex. ELECTRON_RUN_AS_NODE
    /// positionné par un shell/une IDE) ferait démarrer l'UX en mode Node, qui sort
    /// immédiatement avec le code 9 et laisse le client sans interface. On lance donc
    /// le service avec un environnement nettoyé de ces variables.
    /// </summary>
    public static ProcessStartInfo BuildServiceStartInfo(
        RiotPaths paths,
        string? launchProduct,
        string? launchPatchline = "live")
    {
        ArgumentNullException.ThrowIfNull(paths);

        var psi = new ProcessStartInfo
        {
            FileName = paths.ServiceExe,
            WorkingDirectory = paths.InstallRoot,
            UseShellExecute = false,
            CreateNoWindow = true
        };

        foreach (var key in psi.Environment.Keys
                     .Where(k => string.Equals(k, "ELECTRON_RUN_AS_NODE", StringComparison.OrdinalIgnoreCase) ||
                                 string.Equals(k, "ELECTRON_NO_ATTACH_CONSOLE", StringComparison.OrdinalIgnoreCase))
                     .ToList())
        {
            psi.Environment.Remove(key);
        }

        if (!string.IsNullOrWhiteSpace(launchProduct) &&
            !string.Equals(launchProduct, "none", StringComparison.OrdinalIgnoreCase))
        {
            var patchline = string.IsNullOrWhiteSpace(launchPatchline) ? "live" : launchPatchline;
            psi.Arguments = $"--launch-product={launchProduct} --launch-patchline={patchline}";
        }

        return psi;
    }

    public RiotClientWindowInfo? WaitForClientWindow(TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            var window = RiotClientWindow.Find();
            if (window is not null) return window;
            Thread.Sleep(250);
        }

        return RiotClientWindow.Find();
    }

    private RiotProcessInfo? FindProcessByName(string name)
    {
        return FindProcesses(n => string.Equals(n, name, StringComparison.OrdinalIgnoreCase)).FirstOrDefault();
    }

    private static List<RiotProcessInfo> FindProcesses(Func<string, bool> predicate)
    {
        var result = new List<RiotProcessInfo>();

        Process[] processes;
        try
        {
            processes = Process.GetProcesses();
        }
        catch
        {
            return result;
        }

        foreach (var process in processes)
        {
            try
            {
                var name = process.ProcessName;
                if (!predicate(name)) continue;
                result.Add(new RiotProcessInfo(process.Id, name, SafeStartTime(process)));
            }
            catch
            {
                // Processus inaccessible ou terminé : ignorer.
            }
            finally
            {
                process.Dispose();
            }
        }

        return result;
    }

    private static DateTime? SafeStartTime(Process process)
    {
        try
        {
            return process.StartTime;
        }
        catch
        {
            return null;
        }
    }

    private static bool WaitForProcessExit(int pid, TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            if (!IsProcessRunning(pid)) return true;
            Thread.Sleep(100);
        }

        return !IsProcessRunning(pid);
    }

    private static void WaitForProcessesExit(IEnumerable<int> pids, TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow + timeout;
        var remaining = pids.Distinct().ToList();
        while (DateTime.UtcNow < deadline && remaining.Count > 0)
        {
            remaining.RemoveAll(pid => !IsProcessRunning(pid));
            if (remaining.Count == 0) return;
            Thread.Sleep(100);
        }
    }

    private static bool IsProcessRunning(int pid)
    {
        try
        {
            using var process = Process.GetProcessById(pid);
            return !process.HasExited;
        }
        catch (ArgumentException)
        {
            return false;
        }
        catch
        {
            return false;
        }
    }

    private static bool WaitForNoRiotProcesses(TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            var any = false;
            try
            {
                foreach (var process in Process.GetProcesses())
                {
                    try
                    {
                        if (RiotProcessNames.IsRiot(process.ProcessName))
                        {
                            any = true;
                            break;
                        }
                    }
                    catch
                    {
                        // Ignorer.
                    }
                    finally
                    {
                        process.Dispose();
                    }
                }
            }
            catch
            {
                return true;
            }

            if (!any) return true;
            Thread.Sleep(150);
        }

        return !HasAnyRiotProcess();
    }

    private static bool HasAnyRiotProcess()
    {
        try
        {
            foreach (var process in Process.GetProcesses())
            {
                try
                {
                    if (RiotProcessNames.IsRiot(process.ProcessName)) return true;
                }
                catch
                {
                    // Ignorer.
                }
                finally
                {
                    process.Dispose();
                }
            }
        }
        catch
        {
            // Ignorer.
        }

        return false;
    }
}
