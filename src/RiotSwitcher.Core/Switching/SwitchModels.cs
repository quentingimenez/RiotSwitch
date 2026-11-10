using RiotSwitcher.Core.Riot;
using RiotSwitcher.Core.Vault;

namespace RiotSwitcher.Core.Switching;

public enum SwitchOutcome
{
    Success = 0,
    AlreadyCurrent,
    Canceled,
    GameRunning,
    ConfirmationDeclined,
    Busy,
    ClientNotInstalled,
    SessionUnusable,
    WriteFailed,
    VerificationFailed,
    ProcessError,
    AccessDenied,
    Timeout,
    RolledBack,

    /// <summary>
    /// La session cible n'a pas été acceptée (session expirée ou révoquée) : le client Riot est resté
    /// sur l'écran de connexion. La session cible reste installée et aucun retour au compte précédent
    /// n'a été effectué.
    /// </summary>
    ReconnectRequired,

    UnknownError
}

public sealed record SwitchProgress(string Stage, string Message, int? Percent = null);

public sealed class SwitchRequest
{
    public required string AccountId { get; init; }

    /// <summary>league_of_legends, valorant, ou none/null pour ne pas lancer de jeu.</summary>
    public string? LaunchProduct { get; init; }

    public bool LaunchAfterSwitch { get; init; } = true;
    public bool CaptureCurrentSession { get; init; } = true;

    /// <summary>Confirmation pour fermer le client League. Retourner false annule le switch.</summary>
    public Func<GameGuardStatus, bool>? ConfirmClientClose { get; init; }

    public Action<SwitchProgress>? ReportProgress { get; init; }
}

public sealed class SwitchResult
{
    public SwitchOutcome Outcome { get; init; }
    public string Message { get; init; } = string.Empty;
    public string? Error { get; init; }
    public AccountRecord? Account { get; init; }
    public bool RolledBack { get; init; }
    public TimeSpan Duration { get; init; }

    public bool IsSuccess => Outcome == SwitchOutcome.Success;

    public static SwitchResult Ok(AccountRecord account, TimeSpan duration, string message) => new()
    {
        Outcome = SwitchOutcome.Success,
        Account = account,
        Duration = duration,
        Message = message
    };

    public static SwitchResult Fail(
        SwitchOutcome outcome,
        string message,
        AccountRecord? account = null,
        string? error = null,
        bool rolledBack = false,
        TimeSpan duration = default) => new()
    {
        Outcome = outcome,
        Message = message,
        Account = account,
        Error = error,
        RolledBack = rolledBack,
        Duration = duration
    };
}
