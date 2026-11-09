using System.Diagnostics;
using RiotSwitcher.Core.Infrastructure;
using RiotSwitcher.Core.Riot;
using RiotSwitcher.Core.Vault;

namespace RiotSwitcher.Core.Switching;

/// <summary>
/// Orchestration du changement de compte : fermeture propre, capture, remplacement du YAML, relance, vérification, rollback.
/// </summary>
public sealed class SwitchService
{
    private readonly RiotPaths _paths;
    private readonly SessionVault _vault;
    private readonly IRiotProcessController _processes;
    private readonly IGameGuard _gameGuard;
    private readonly IRiotLocalApi _localApi;
    private readonly IAppLogger _logger;
    private readonly SwitchJournal _journal;

    public SwitchService(
        RiotPaths paths,
        SessionVault vault,
        IRiotProcessController? processes = null,
        IGameGuard? gameGuard = null,
        IAppLogger? logger = null,
        SwitchJournal? journal = null,
        IRiotLocalApi? localApi = null)
    {
        _paths = paths ?? throw new ArgumentNullException(nameof(paths));
        _vault = vault ?? throw new ArgumentNullException(nameof(vault));
        _logger = logger ?? NullLogger.Instance;
        _processes = processes ?? new RiotProcessController(paths);
        _gameGuard = gameGuard ?? new GameGuard();
        _journal = journal ?? new SwitchJournal(paths, _logger);
        _localApi = localApi ?? new RiotLocalApi(paths);
    }

    public SwitchJournal Journal => _journal;

    public SwitchResult Switch(SwitchRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);

        var total = Stopwatch.StartNew();
        AccountRecord? target = null;
        VaultBundle? targetBundle = null;
        RiotSessionSnapshot? currentBefore = null;
        RiotSessionSnapshot? currentSnapshot = null;
        BackupEntry? backup = null;
        var clientClosed = false;
        var journalStarted = false;

        void Report(string stage, string message, int? percent = null)
        {
            try
            {
                request.ReportProgress?.Invoke(new SwitchProgress(stage, message, percent));
            }
            catch
            {
                // Un callback UI défaillant ne doit pas interrompre le switch.
            }
        }

        SwitchResult Fail(SwitchOutcome outcome, string message, string? error = null, bool rolledBack = false)
            => SwitchResult.Fail(outcome, message, target, error, rolledBack, total.Elapsed);

        try
        {
            if (string.IsNullOrWhiteSpace(request.AccountId))
                return Fail(SwitchOutcome.SessionUnusable, "Aucun compte cible.");

            try
            {
                targetBundle = _vault.GetBundle(request.AccountId.Trim());
                target = targetBundle.Account;
            }
            catch (VaultException ex)
            {
                _logger.Warn($"Compte cible inaccessible : {ex.Message}");
                return Fail(SwitchOutcome.SessionUnusable, ex.Message, ex.Message);
            }

            if (!targetBundle.Session.Info.HasSession)
                return Fail(SwitchOutcome.SessionUnusable, "La session du compte cible est vide.");

            if (!targetBundle.Session.Info.CanSwitch)
            {
                return Fail(
                    SwitchOutcome.SessionUnusable,
                    $"La session de {target.DisplayName} est inutilisable : {targetBundle.Session.Info.UnsupportedReason ?? "format non supporté"}");
            }

            if (!_paths.InstallExists)
                return Fail(SwitchOutcome.ClientNotInstalled, "Riot Client introuvable. Vérifie l'installation de Riot Games.");

            currentBefore = TryReadLiveSession();
            if (IsSameAsTarget(currentBefore, targetBundle))
            {
                return SwitchResult.Fail(
                    SwitchOutcome.AlreadyCurrent,
                    $"Le compte {target.DisplayName} est déjà le compte actif.",
                    target,
                    null,
                    false,
                    total.Elapsed);
            }

            var guard = _gameGuard.Check();
            if (guard.IsHardBlock)
                return Fail(SwitchOutcome.GameRunning, guard.Message);

            if (guard.NeedsConfirmation)
            {
                if (request.ConfirmClientClose is null)
                {
                    return Fail(
                        SwitchOutcome.ConfirmationDeclined,
                        "Confirmation requise pour fermer le client League of Legends.");
                }

                bool confirmed;
                try
                {
                    confirmed = request.ConfirmClientClose(guard);
                }
                catch
                {
                    confirmed = false;
                }

                if (!confirmed)
                    return Fail(SwitchOutcome.ConfirmationDeclined, "Switch annulé : le client League of Legends reste ouvert.");
            }

            using var switchGuard = MutexGuard.TryAcquire(AppInfo.SwitchMutexName, TimeSpan.FromSeconds(2));
            if (switchGuard is null)
                return Fail(SwitchOutcome.Busy, "Un changement de compte est déjà en cours.");

            using var switchSignal = SwitchSignal.Activate();

            var currentAccount = currentBefore?.Info.Puuid is null
                ? null
                : _vault.FindByPuuid(currentBefore.Info.Puuid);

            _journal.Begin(target.Id, target.DisplayName, currentAccount?.Id, null);
            journalStarted = true;
            _journal.SetPhase("client-close");

            Report("Fermeture du client Riot", "Fermeture de l'interface Riot...", 10);

            if (_processes.FindClientUi() is not null)
            {
                if (!_processes.TryCloseClientUi(TimeSpan.FromSeconds(10), out _))
                {
                    _journal.Clear();
                    return Fail(
                        SwitchOutcome.AccessDenied,
                        "Impossible de fermer le client Riot. Il est peut-être lancé en administrateur : ferme-le manuellement ou lance RiotSwitch en administrateur.");
                }

                clientClosed = true;
            }

            _journal.Update(entry =>
            {
                entry.ClientClosed = true;
                entry.Phase = "session-capture";
            });

            // Relire APRÈS la fermeture : le client flushe ses tokens à ce moment-là.
            var currentAfter = TryReadLiveSession();
            currentSnapshot = PreferValid(currentAfter, currentBefore);

            if (currentSnapshot is not null && currentSnapshot.Info.HasSession)
            {
                if (request.CaptureCurrentSession)
                {
                    try
                    {
                        _vault.Capture(currentSnapshot, includeProfile: false);
                    }
                    catch (VaultException ex)
                    {
                        _logger.Warn($"Capture du compte courant impossible : {ex.Message}");
                    }
                }

                try
                {
                    backup = _vault.CreateBackup(currentSnapshot, "pre-switch");
                }
                catch (Exception ex) when (ex is VaultException or IOException or UnauthorizedAccessException)
                {
                    _logger.Warn($"Sauvegarde de la session courante impossible : {ex.Message}");
                }

                if (backup is not null)
                    _journal.Update(entry => entry.CurrentBackupFile = backup.FileName);

                currentAccount ??= currentSnapshot.Info.Puuid is null
                    ? null
                    : _vault.FindByPuuid(currentSnapshot.Info.Puuid);
            }

            _journal.Update(entry =>
            {
                entry.CurrentAccountId = currentAccount?.Id;
                entry.Phase = "service-stop";
            });

            Report("Arrêt du service Riot", "Arrêt du service Riot...", 25);
            var remaining = _processes.TryKillRiotStack(TimeSpan.FromSeconds(15));
            if (remaining > 0)
            {
                _journal.Clear();
                if (clientClosed) _processes.StartService(null);
                return Fail(SwitchOutcome.ProcessError, "Le service Riot n'a pas pu être arrêté. Vérifie qu'il n'est pas lancé en administrateur.", null);
            }

            _journal.Update(entry =>
            {
                entry.ServiceStopped = true;
                entry.Phase = "writing";
            });

            if (guard.NeedsConfirmation)
            {
                try
                {
                    _processes.TryKillLeagueClient(TimeSpan.FromSeconds(10));
                }
                catch (Exception ex)
                {
                    _logger.Warn($"Fermeture du client League impossible : {ex.Message}");
                }
            }

            // Re-vérification juste avant d'écrire : une partie a pu démarrer entre-temps.
            var recheck = _gameGuard.Check();
            if (recheck.IsHardBlock)
            {
                _journal.Clear();
                var rolled = TryRollback(backup, target);
                return Fail(SwitchOutcome.GameRunning, recheck.Message, null, rolled);
            }

            Report("Installation du compte", $"Installation de {target.DisplayName}...", 45);

            try
            {
                var dataDirectory = Path.GetDirectoryName(_paths.LiveSessionFile);
                if (!string.IsNullOrEmpty(dataDirectory)) Directory.CreateDirectory(dataDirectory);

                AtomicFile.WriteAllBytes(_paths.LiveSessionFile, targetBundle.Contents.YamlBytes);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                var rolled = TryRollback(backup, target);
                if (!rolled) _journal.Clear();
                return Fail(SwitchOutcome.WriteFailed, "Impossible d'écrire la session du compte cible.", ex.Message, rolled);
            }

            _journal.Update(entry =>
            {
                entry.TargetWritten = true;
                entry.Phase = "launching";
            });

            if (targetBundle.Contents.ProfileFiles.Count > 0)
            {
                try
                {
                    ElectronProfileCollector.Restore(_paths, targetBundle.Contents.ProfileFiles);
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                {
                    _logger.Warn($"Restauration du profil Electron impossible : {ex.Message}");
                }
            }

            var product = NormalizeProduct(request.LaunchProduct ?? target.AutoLaunchProduct);

            if (!request.LaunchAfterSwitch)
            {
                _journal.Clear();
                TryMarkSwitched(target);
                return SwitchResult.Ok(
                    target,
                    total.Elapsed,
                    $"Session de {target.DisplayName} installée. Le prochain démarrage du client utilisera ce compte.");
            }

            Report("Démarrage du client Riot", "Démarrage du client Riot...", 60);
            if (!_processes.StartService(product, "live"))
            {
                _journal.Clear();
                TryMarkSwitched(target);
                return Fail(
                    SwitchOutcome.ProcessError,
                    "La session du compte a été installée, mais le client Riot n'a pas pu démarrer. Lance-le manuellement.");
            }

            Report("Vérification", "Attente de la fenêtre du client Riot...", 75);
            var window = _processes.WaitForClientWindow(TimeSpan.FromSeconds(60));
            if (window is null)
            {
                _journal.Clear();
                TryMarkSwitched(target);
                return Fail(
                    SwitchOutcome.Timeout,
                    "La session du compte a été installée, mais la fenêtre Riot n'est pas apparue. Vérifie le client.");
            }

            if (!VerifyAccountAfterStartup(targetBundle.Session, window, TimeSpan.FromSeconds(15)))
            {
                var rolled = TryRollback(backup, target);
                if (rolled) _journal.Clear();
                return Fail(
                    SwitchOutcome.VerificationFailed,
                    "Le client n'a pas confirmé le compte cible. Retour au compte précédent.",
                    null,
                    rolled);
            }

            _journal.Clear();
            TryMarkSwitched(target);
            Report("Terminé", "Compte changé.", 100);

            return SwitchResult.Ok(
                target,
                total.Elapsed,
                $"Compte {target.DisplayName} activé et vérifié dans le client Riot.");
        }
        catch (Exception ex)
        {
            _logger.Error("Erreur inattendue pendant le changement de compte.", ex);
            var rolled = TryRollback(backup, target);
            if (rolled || journalStarted) _journal.Clear();
            return Fail(SwitchOutcome.UnknownError, "Erreur inattendue pendant le changement de compte.", ex.Message, rolled);
        }
    }

    private RiotSessionSnapshot? TryReadLiveSession()
    {
        try
        {
            if (!File.Exists(_paths.LiveSessionFile)) return null;
            return RiotSessionReader.ReadFile(_paths.LiveSessionFile);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            _logger.Warn($"Lecture de la session Riot impossible : {ex.Message}");
            return null;
        }
    }

    private static RiotSessionSnapshot? PreferValid(RiotSessionSnapshot? after, RiotSessionSnapshot? before)
    {
        if (after is not null && after.Info.HasSession) return after;
        if (before is not null && before.Info.HasSession) return before;
        return null;
    }

    private static bool IsSameAsTarget(RiotSessionSnapshot? current, VaultBundle target)
    {
        if (current is null || !current.Info.HasSession) return false;

        var targetPuuid = target.Session.Info.Puuid;
        if (!string.IsNullOrWhiteSpace(targetPuuid))
        {
            return string.Equals(current.Info.Puuid, targetPuuid, StringComparison.Ordinal);
        }

        return string.Equals(current.Sha256, target.Session.Sha256, StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>
    /// Vérifie que le client a réellement ouvert la session cible.
    /// Quand une vraie fenêtre existe, l'API locale du client est la source de vérité :
    /// le fichier YAML vient d'être écrit par nous, donc le relire ne prouve rien.
    /// En test (fenêtre factice sans handle), on retombe sur la vérification du fichier.
    /// </summary>
    private bool VerifyAccountAfterStartup(
        RiotSessionSnapshot target,
        RiotClientWindowInfo? window,
        TimeSpan timeout)
    {
        var targetPuuid = target.Info.Puuid;
        if (string.IsNullOrWhiteSpace(targetPuuid)) return true;

        if (window is { Handle: not 0 })
        {
            var deadline = DateTime.UtcNow + timeout;
            while (DateTime.UtcNow < deadline)
            {
                var authorization = _localApi.TryGetAuthorization(TimeSpan.FromSeconds(2));
                if (!string.IsNullOrWhiteSpace(authorization?.Subject))
                {
                    if (string.Equals(authorization.Subject, targetPuuid, StringComparison.Ordinal))
                        return true;

                    _logger.Warn("L'API locale du client Riot signale un autre compte que la cible.");
                    return false;
                }

                Thread.Sleep(350);
            }

            _logger.Warn("L'API locale du client Riot n'a pas confirmé le compte cible dans le délai imparti.");
            return false;
        }

        // Pas de fenêtre réelle exploitable (tests, mode headless) : vérification du fichier.
        return WaitForSessionSub(target, TimeSpan.FromSeconds(8));
    }

    private bool WaitForSessionSub(RiotSessionSnapshot target, TimeSpan timeout)
    {
        var targetPuuid = target.Info.Puuid;
        if (string.IsNullOrWhiteSpace(targetPuuid)) return true;

        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            try
            {
                var live = RiotSessionReader.ReadFile(_paths.LiveSessionFile, waitForStable: false);
                if (live.Info.HasSession &&
                    string.Equals(live.Info.Puuid, targetPuuid, StringComparison.Ordinal))
                {
                    return true;
                }
            }
            catch
            {
                // Le client est peut-être en train d'écrire : réessayer.
            }

            Thread.Sleep(300);
        }

        return false;
    }

    private bool TryRollback(BackupEntry? backup, AccountRecord? target)
    {
        try
        {
            if (backup is not null)
            {
                var current = _vault.OpenBackup(backup.FileName);
                AtomicFile.WriteAllBytes(_paths.LiveSessionFile, current.Contents.YamlBytes);
                _logger.Info($"Session précédente restaurée depuis {backup.FileName}.");
            }

            _processes.TryKillRiotStack(TimeSpan.FromSeconds(10));
            var started = _processes.StartService(null);

            if (target is not null)
            {
                try
                {
                    _vault.SetLastError(target.Id, "Switch annulé : retour au compte précédent.");
                }
                catch (VaultException ex)
                {
                    _logger.Warn($"Mise à jour de l'erreur du compte impossible : {ex.Message}");
                }
            }

            if (!started) _logger.Warn("Rollback effectué, mais le client Riot n'a pas pu être relancé.");
            return true;
        }
        catch (Exception ex)
        {
            _logger.Error("Rollback impossible.", ex);
            return false;
        }
    }

    private void TryMarkSwitched(AccountRecord target)
    {
        try
        {
            _vault.MarkSwitched(target.Id, DateTimeOffset.UtcNow);
        }
        catch (VaultException ex)
        {
            _logger.Warn($"Mise à jour des métadonnées du compte impossible : {ex.Message}");
        }
    }

    private static string? NormalizeProduct(string? product)
    {
        return (product ?? string.Empty).Trim().ToLowerInvariant() switch
        {
            "league" or "lol" or "league_of_legends" => "league_of_legends",
            "valorant" or "val" => "valorant",
            _ => null
        };
    }
}
