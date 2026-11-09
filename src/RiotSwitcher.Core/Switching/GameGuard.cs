using System.Diagnostics;
using RiotSwitcher.Core.Riot;

namespace RiotSwitcher.Core.Switching;

public enum GameGuardResult
{
    Allow = 0,
    LeagueClientRunning = 1,
    GameRunning = 2
}

public sealed record GameGuardStatus(GameGuardResult Result, IReadOnlyList<string> Processes, string Message)
{
    public bool IsHardBlock => Result == GameGuardResult.GameRunning;
    public bool NeedsConfirmation => Result == GameGuardResult.LeagueClientRunning;

    public static GameGuardStatus Allow() => new(GameGuardResult.Allow, Array.Empty<string>(), "Aucun jeu en cours.");
}

public interface IGameGuard
{
    GameGuardStatus Check();
}

/// <summary>
/// Garde-fou : bloque le switch pendant une partie, demande confirmation si seul le client League est ouvert.
/// </summary>
public sealed class GameGuard : IGameGuard
{
    public static readonly string[] HardBlockedProcesses =
    {
        RiotProcessNames.LeagueGame,
        RiotProcessNames.Valorant,
        RiotProcessNames.ValorantShipping,
        RiotProcessNames.LegendsOfRuneterra
    };

    public static readonly string[] LeagueClientProcesses = RiotProcessNames.LeagueClientProcesses;

    public GameGuardStatus Check()
    {
        var hardBlocked = Find(HardBlockedProcesses);
        if (hardBlocked.Count > 0)
        {
            var names = string.Join(", ", hardBlocked);
            return new GameGuardStatus(
                GameGuardResult.GameRunning,
                hardBlocked,
                $"Une partie est en cours ({names}). Ferme le jeu avant de changer de compte.");
        }

        var leagueClient = Find(LeagueClientProcesses);
        if (leagueClient.Count > 0)
        {
            var names = string.Join(", ", leagueClient);
            return new GameGuardStatus(
                GameGuardResult.LeagueClientRunning,
                leagueClient,
                $"Le client League of Legends est ouvert ({names}). Le switch va le fermer. Continuer ?");
        }

        return GameGuardStatus.Allow();
    }

    private static List<string> Find(IEnumerable<string> names)
    {
        var wanted = new HashSet<string>(names, StringComparer.OrdinalIgnoreCase);
        var found = new List<string>();

        try
        {
            foreach (var process in Process.GetProcesses())
            {
                try
                {
                    var name = process.ProcessName;
                    if (wanted.Contains(name) && !found.Contains(name, StringComparer.OrdinalIgnoreCase))
                    {
                        found.Add(name);
                    }
                }
                catch
                {
                    // Processus inaccessible : ignorer.
                }
                finally
                {
                    process.Dispose();
                }
            }
        }
        catch
        {
            // Énumération impossible : laisser passer, le switch échouera proprement plus tard.
        }

        return found;
    }
}
