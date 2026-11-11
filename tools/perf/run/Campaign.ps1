#requires -Version 5.1
<#
.SYNOPSIS
    Campagne de mesure officielle RiotSwitch (etats W / A / B / C / D / E / E2, demarrage a froid F).

.DESCRIPTION
    Orchestration complete, sequencee, d'une campagne de mesure de performance du veilleur
    RiotSwitch. Utilise les outils de tools/perf/sampler (mesure process externe), tools/perf/probe
    (comptage WinEvent, optionnel) et tools/perf/run/OverlayCtl.ps1 (pilotage UI et latences).
    Les resultats sont ecrits dans tools/perf/results/campaign-<Tag>/ (un sous-dossier par phase).

    Definitions des etats:
      W_launcher : veilleur lance en mode launcher (--launch-riot --ephemeral), overlay absent (Riot minimise).
      A_launcher : veilleur launcher, overlay replie visible.
      F          : arret propre puis redemarrage en --watch ; snapshots memoire a 1.5/3/13/25 s ;
                   mesure de latence jusqu'a overlay visible ; verifie les claims de demarrage.
      W_watch    : veilleur --watch, overlay absent (Riot minimise) - etat "veilleur seul".
      A_watch    : veilleur --watch, overlay replie visible.
      B_watch    : veilleur --watch, panneau deplie (statique).
      C          : interactions survol + molette sur panneau deplie (CPU delta 60 s).
      D          : suivi de fenetre (deplacement programme de Riot, latences de suivi + CPU).
      E          : cycles depliage/repliage (N) avec snapshots avant/apres (fuites).
      E2         : cycles destruction/recreation de l'overlay (minimiser / premier plan) avec snapshots.

    Le script est concu pour tourner en job d'arriere-plan pendant ~15 min (machine silencieuse).
#>
param(
    [string[]]$Phases = @('W_launcher', 'A_launcher', 'F', 'W_watch', 'A_watch', 'B_watch', 'C', 'D', 'E', 'E2'),
    [int]$DurationSeconds = 150,
    [int]$ShortSeconds = 60,
    [int]$Cycles = 30,
    [int]$E2Cycles = 5,
    [switch]$Quick,
    [switch]$Probe,
    [string]$Tag = (Get-Date -Format 'yyyyMMdd-HHmmss'),
    [string]$OutRoot = '',
    # Executable a mesurer (par defaut le binaire publie dans dist\). Permet de
    # comparer un build local (ex. tools\perf\build) sans toucher a dist\.
    [string]$ExePath = ''
)

$ErrorActionPreference = 'Stop'

# Depuis une ligne de commande native, "-Phases a,b" arrive comme une seule chaine : on la decoupe.
if ($Phases.Count -eq 1 -and $Phases[0] -match ',') { $Phases = @($Phases[0] -split ',') }
$Phases = @($Phases | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -gt 0 })

if ($Quick) {
    $DurationSeconds = 8
    $ShortSeconds = 8
    $Cycles = 3
    $E2Cycles = 2
}

$RunDir = $PSScriptRoot
$PerfDir = (Resolve-Path (Join-Path $RunDir '..')).Path
$Root = (Resolve-Path (Join-Path $PerfDir '..\..')).Path
if ([string]::IsNullOrEmpty($OutRoot)) { $OutRoot = Join-Path $PerfDir 'results' }
$CampaignDir = Join-Path $OutRoot ("campaign-" + $Tag)
$LogPath = Join-Path $CampaignDir 'campaign.log'
$CtlPath = Join-Path $RunDir 'OverlayCtl.ps1'
$SamplerPath = Join-Path $PerfDir 'sampler\ProcessSampler.ps1'
$ProbePath = Join-Path $PerfDir 'probe\EventProbe.ps1'
if ([string]::IsNullOrEmpty($ExePath)) {
    $ExePath = Join-Path $Root 'dist\RiotSwitch.exe'
} elseif (-not [System.IO.Path]::IsPathRooted($ExePath)) {
    $ExePath = Join-Path $Root $ExePath
}
$AppLogPath = Join-Path $env:LOCALAPPDATA 'RiotSwitch\logs\app.log'
$SettingsPath = Join-Path $env:LOCALAPPDATA 'RiotSwitch\settings.json'

New-Item -ItemType Directory -Force -Path $CampaignDir | Out-Null
if (-not (Test-Path -LiteralPath $LogPath)) { Set-Content -LiteralPath $LogPath -Value '' -Encoding UTF8 }

$script:CaseDir = $CampaignDir
$script:WatcherPid = 0
$script:TransitionResults = New-Object System.Collections.Generic.List[object]

function Write-Log {
    param([string]$Message)
    $line = ('[{0}] {1}' -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss.fffZ'), $Message)
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    Write-Host $line
}

function Read-JsonFile {
    param([string]$Path)
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    return ($raw | ConvertFrom-Json)
}

function Invoke-Ctl {
    param([string]$Action, [string[]]$ExtraArgs = @())
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $CtlPath, '-Action', $Action)
    if ($ExtraArgs.Count -gt 0) { $argList += $ExtraArgs }
    $raw = & powershell.exe @argList 2>$null | Out-String
    $code = $LASTEXITCODE
    $obj = $null
    $trimmed = $raw.Trim()
    if ($trimmed.Length -gt 0) {
        try { $obj = $trimmed | ConvertFrom-Json } catch { $obj = $null }
    }
    return [pscustomobject]@{ exit = $code; result = $obj; raw = $trimmed }
}

function Get-NewestMatch {
    param([string]$Dir, [string]$Pattern)
    $f = @(Get-ChildItem -LiteralPath $Dir -Filter $Pattern -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)
    if ($f.Count -eq 0) { return $null }
    return $f[$f.Count - 1].FullName
}

function Start-SamplerProcess {
    param([string]$Label, [int]$Seconds, [string]$Dir)
    $csv = Join-Path $Dir ($Label + '.csv')
    $json = Join-Path $Dir ($Label + '.json')
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $SamplerPath,
                 '-ProcessId', ("{0}" -f $script:WatcherPid), '-DurationSeconds', ("{0}" -f $Seconds),
                 '-IntervalMs', '1000', '-IncludeThreads', '-Csv', $csv, '-Json', $json,
                 '-Label', $Label, '-Quiet')
    $p = Start-Process -FilePath powershell.exe -ArgumentList $argList -PassThru -WindowStyle Hidden
    return [pscustomobject]@{ process = $p; csv = $csv; json = $json }
}

function Start-ProbeProcess {
    param([string]$Label, [int]$Seconds, [string]$Dir)
    if (-not $Probe) { return $null }
    $csv = Join-Path $Dir ('probe-' + $Label + '.csv')
    $json = Join-Path $Dir ('probe-' + $Label + '.json')
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ProbePath,
                 '-DurationSeconds', ("{0}" -f $Seconds), '-IntervalMs', '1000',
                 '-SamplerPid', ("{0}" -f $script:WatcherPid), '-Label', $Label,
                 '-Csv', $csv, '-Json', $json)
    $p = Start-Process -FilePath powershell.exe -ArgumentList $argList -PassThru -WindowStyle Hidden
    return [pscustomobject]@{ process = $p; csv = $csv; json = $json }
}

function Wait-Jobs {
    param([object[]]$Jobs)
    foreach ($j in $Jobs) {
        if ($null -eq $j) { continue }
        if (-not $j.process.HasExited) {
            if (-not $j.process.WaitForExit(($DurationSeconds + 120) * 1000)) {
                try { $j.process.Kill() } catch { }
                throw ('Timeout du job ' + $j.json)
            }
        }
    }
}

function Get-Snapshot {
    param([string]$Label, [string]$Dir, [int]$ProcessId = 0)
    $targetPid = $(if ($ProcessId -gt 0) { $ProcessId } else { [int]$script:WatcherPid })
    $json = Join-Path $Dir ('snapshot-' + $Label + '.json')
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $SamplerPath,
                 '-ProcessId', ("{0}" -f $targetPid), '-Snapshot',
                 '-Json', $json, '-Label', $Label)
    & powershell.exe @argList 2>$null | Out-Null
    if (-not (Test-Path -LiteralPath $json)) { return $null }
    return (Read-JsonFile $json)
}

function Snapshot-Brief {
    param([object]$Snap)
    if ($null -eq $Snap) { return $null }
    $c = $Snap.counters
    return [ordered]@{
        label              = $Snap.label
        uptime_s           = [math]::Round([double]$Snap.target.uptime_s, 3)
        cpu_total_s        = [double]$c.cpu_total_seconds
        ws_bytes           = [int64]$c.ws_bytes
        private_ws_bytes   = [int64]$c.private_ws_bytes
        commit_bytes       = [int64]$c.commit_bytes
        peak_ws_bytes      = [int64]$c.peak_ws_bytes
        handles            = [int]$c.handles
        gdi_objects        = [int]$c.gdi_objects
        user_objects       = [int]$c.user_objects
        threads            = [int]$c.threads
    }
}

function Run-MeasureCase {
    param([string]$Label, [string]$Dir, [int]$SamplerSeconds, [int]$ProbeSeconds)
    Write-Log ("  mesure {0} : sampler {1} s{2}" -f $Label, $SamplerSeconds, $(if ($Probe) { " + probe $ProbeSeconds s" } else { '' }))
    $snapBefore = Get-Snapshot ('before-' + $Label) $Dir
    $samplerJob = Start-SamplerProcess -Label $Label -Seconds $SamplerSeconds -Dir $Dir
    $probeJob = $null
    if ($Probe) { $probeJob = Start-ProbeProcess -Label $Label -Seconds $ProbeSeconds -Dir $Dir }
    Wait-Jobs @($samplerJob, $probeJob)
    Start-Sleep -Milliseconds 400
    $snapAfter = Get-Snapshot ('after-' + $Label) $Dir
    $sampler = $null
    if (Test-Path -LiteralPath $samplerJob.json) { $sampler = Read-JsonFile $samplerJob.json }
    $probe = $null
    if ($null -ne $probeJob -and (Test-Path -LiteralPath $probeJob.json)) { $probe = Read-JsonFile $probeJob.json }
    return [ordered]@{
        label      = $Label
        sampler    = $sampler
        probe      = $probe
        snapshot_before = (Snapshot-Brief $snapBefore)
        snapshot_after  = (Snapshot-Brief $snapAfter)
        csv        = $samplerJob.csv
        json       = $samplerJob.json
    }
}

function Add-PhaseResult {
    param([string]$Name, [object]$Value)
    $script:TransitionResults.Add([pscustomobject]@{ phase = $Name; value = $Value })
}

function Get-WatcherInfo {
    $procs = @(Get-CimInstance Win32_Process -Filter "Name='RiotSwitch.exe'" -ErrorAction SilentlyContinue)
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($p in $procs) {
        $out.Add([pscustomobject]@{
            pid = [int]$p.ProcessId
            command_line = $p.CommandLine
            creation_utc = $(try { $p.CreationDate.ToUniversalTime().ToString('o') } catch { $null })
        })
    }
    return $out
}

# ----------------------------------------------------------------------------
# Preparation / verification de l'environnement
# ----------------------------------------------------------------------------
Write-Log '=== CAMPAGNE DE MESURE RIOTSWITCH ==='
Write-Log ("tag={0} dir={1}" -f $Tag, $CampaignDir)
Write-Log ("phases={0} duration={1}s short={2}s cycles={3} e2={4} probe={5} quick={6}" -f ($Phases -join ','), $DurationSeconds, $ShortSeconds, $Cycles, $E2Cycles, $Probe, $Quick)

$watchers = @(Get-WatcherInfo)
if ($watchers.Count -gt 1) { throw ('Plusieurs processus RiotSwitch : ' + (($watchers | ForEach-Object { $_.pid }) -join ',')) }
if ($watchers.Count -eq 1) {
    $script:WatcherPid = [int]$watchers[0].pid
    Write-Log ("veilleur existant : PID {0} ; cmdline = {1}" -f $script:WatcherPid, $watchers[0].command_line)
} elseif ($Phases | Where-Object { $_ -in @('W_launcher', 'A_launcher') }) {
    throw 'Aucun veilleur RiotSwitch en cours : les phases W_launcher/A_launcher exigent une instance existante.'
}

$envInfo = [ordered]@{
    generated_at_utc = (Get-Date).ToUniversalTime().ToString('o')
    campaign_dir     = $CampaignDir
    tag              = $Tag
    quick            = [bool]$Quick
    probe_enabled    = [bool]$Probe
    durations        = [ordered]@{ main_s = $DurationSeconds; short_s = $ShortSeconds; cycles = $Cycles; e2_cycles = $E2Cycles }
    exe_path         = $ExePath
    exe_length       = $(if (Test-Path -LiteralPath $ExePath) { (Get-Item -LiteralPath $ExePath).Length } else { $null })
    exe_last_write_utc = $(if (Test-Path -LiteralPath $ExePath) { (Get-Item -LiteralPath $ExePath).LastWriteTimeUtc.ToString('o') } else { $null })
    os               = (Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber)
    logical_processors = [Environment]::ProcessorCount
    screen           = $null
    foreground_initial = $null
    riot_client      = $null
    settings         = $(if (Test-Path -LiteralPath $SettingsPath) { Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json } else { $null })
    app_log_path     = $AppLogPath
    app_log_length_before = $(if (Test-Path -LiteralPath $AppLogPath) { (Get-Item -LiteralPath $AppLogPath).Length } else { $null })
    notes            = @(
        'La machine peut etre utilisee par l utilisateur pendant la campagne (navigateur, video) : le bruit systeme affecte le debit WinEvent et le CPU global, pas les temps CPU du processus mesure.',
        'Chaque mesure est separee et sequencee ; les 2 premiers echantillons sont exclus a l analyse (warmup).',
        'Le sampler ajoute ~0,8 % d un coeur (process PowerShell hote), identique dans tous les etats.'
    )
}
$envInfo.screen = (Get-CimInstance Win32_DesktopMonitor | Select-Object -First 1 ScreenWidth, ScreenHeight)
$disc0 = Invoke-Ctl 'discover'
if ($null -ne $disc0.result) {
    $envInfo.foreground_initial = $disc0.result.foreground
    $envInfo.riot_client = $disc0.result.riot_client
    $envInfo.dpi_scale = $disc0.result.dpi_scale
}
$envFile = Join-Path $CampaignDir 'environment.json'
($envInfo | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $envFile -Encoding UTF8
Write-Log ("environnement ecrit : {0}" -f $envFile)

function Start-CaseDir {
    param([string]$Name)
    $d = Join-Path $CampaignDir $Name
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    $script:CaseDir = $d
    return $d
}

$overlayState = Invoke-Ctl 'state'
if ($null -ne $overlayState.result) { Write-Log ("etat initial : overlay={0} rect={1} fg={2}" -f $overlayState.result.overlay_state, $overlayState.result.overlay_rect, $overlayState.result.foreground.title) }

# ----------------------------------------------------------------------------
# Phase W_launcher
# ----------------------------------------------------------------------------
if ($Phases -contains 'W_launcher') {
    $d = Start-CaseDir 'W-launcher'
    Write-Log '--- PHASE W_launcher (veilleur launcher, overlay absent) ---'
    $min = Invoke-Ctl 'minimize-riot' @('-TimeoutMs', '8000')
    Write-Log ("  minimize-riot : ok={0} overlay_gone_after_ms={1}" -f $min.result.ok, $min.result.overlay_gone_after_ms)
    if (-not $min.result.ok) { throw 'Impossible de faire disparaitre l overlay (minimize-riot).' }
    Write-Log '  attente stabilisation trim (12 s)...'
    Start-Sleep -Seconds 12
    $case = Run-MeasureCase -Label 'W-launcher' -Dir $d -SamplerSeconds $DurationSeconds -ProbeSeconds ([math]::Min(60, $DurationSeconds))
    Add-PhaseResult 'W_launcher' $case
    Write-Log '  W_launcher termine.'
}

# ----------------------------------------------------------------------------
# Phase A_launcher
# ----------------------------------------------------------------------------
if ($Phases -contains 'A_launcher') {
    $d = Start-CaseDir 'A-launcher'
    Write-Log '--- PHASE A_launcher (veilleur launcher, overlay replie) ---'
    $fg = Invoke-Ctl 'foreground-riot-wait' @('-TimeoutMs', '5000')
    Write-Log ("  foreground-riot-wait : ok={0} fg_latency_ms={1} overlay_total_ms={2} state={3}" -f $fg.result.ok, $fg.result.fg_latency_ms, $fg.result.overlay_total_ms, $fg.result.overlay_state)
    Add-PhaseResult 'A_launcher_transition' $fg.result
    Start-Sleep -Seconds 2
    $case = Run-MeasureCase -Label 'A-launcher' -Dir $d -SamplerSeconds $DurationSeconds -ProbeSeconds ([math]::Min(60, $DurationSeconds))
    Add-PhaseResult 'A_launcher' $case
    Write-Log '  A_launcher termine.'
}

# ----------------------------------------------------------------------------
# Phase F : arret propre + demarrage a froid en --watch
# ----------------------------------------------------------------------------
if ($Phases -contains 'F') {
    $d = Start-CaseDir 'F-coldstart'
    Write-Log '--- PHASE F (arret propre + demarrage a froid --watch) ---'
    if ($script:WatcherPid) {
        $quit = Invoke-Ctl 'quit-watcher' @('-TimeoutMs', '15000')
        Write-Log ("  quit-watcher : ok={0} exited={1} waited_ms={2}" -f $quit.result.ok, $quit.result.exited, $quit.result.waited_ms)
        if (-not $quit.result.ok) { throw 'Le veilleur ne s est pas arrete proprement.' }
        Start-Sleep -Seconds 2
    } else {
        Write-Log '  aucun veilleur en cours : pas d arret a faire.'
    }
    # Demarrage a froid dans l'etat "veilleur seul" : Riot Client masque (SW_HIDE, pas minimise
    # pour ne pas declencher la restauration unique du tracker) afin que le trim puisse s'executer
    # (il est saute tant qu'un overlay est affiche).
    $minw = Invoke-Ctl 'hide-riot-window' @()
    Write-Log ("  hide-riot-window : ok={0} visible_after={1}" -f $minw.result.ok, $minw.result.visible_after)
    $logBefore = $(if (Test-Path -LiteralPath $AppLogPath) { (Get-Item -LiteralPath $AppLogPath).Length } else { 0 })
    $swStart = [System.Diagnostics.Stopwatch]::StartNew()
    $newProc = Start-Process -FilePath $ExePath -ArgumentList '--watch' -PassThru
    Write-Log ("  demarrage --watch : pid={0}" -f $newProc.Id)
    $snaps = New-Object System.Collections.Generic.List[object]
    $targets = @(1.5, 3.0, 13.0, 25.0)
    foreach ($t in $targets) {
        $waitMs = [int](($t * 1000) - $swStart.Elapsed.TotalMilliseconds)
        if ($waitMs -gt 0) { Start-Sleep -Milliseconds $waitMs }
        $s = Get-Snapshot ("t+{0}" -f $t) $d -ProcessId ([int]$newProc.Id)
        $snaps.Add((Snapshot-Brief $s))
        Write-Log ("  snapshot t+{0}s : uptime={1}s ws={2} commit={3} private_ws={4}" -f $t, $s.target.uptime_s, $s.counters.ws_bytes, $s.counters.commit_bytes, $s.counters.private_ws_bytes)
    }
    $script:WatcherPid = [int]$newProc.Id
    $fg = Invoke-Ctl 'foreground-riot-wait' @('-TimeoutMs', '8000')
    Write-Log ("  foreground -> overlay : ok={0} fg_latency_ms={1} overlay_total_ms={2} rect={3}" -f $fg.result.ok, $fg.result.fg_latency_ms, $fg.result.overlay_total_ms, $fg.result.overlay_rect)
    Start-Sleep -Seconds 2
    $case = [ordered]@{
        new_pid = $newProc.Id
        log_length_before = $logBefore
        snapshots = $snaps
        foreground_transition = $fg.result
        notes = @('Le controle de mise a jour differe (AutoCheckUpdates) se declenche ~20 s apres le demarrage : il peut ajouter un pic CPU reseau vers t+20 s.')
    }
    Add-PhaseResult 'F_coldstart' $case
    Write-Log '  F termine.'
}

# ----------------------------------------------------------------------------
# Phase W_watch
# ----------------------------------------------------------------------------
if ($Phases -contains 'W_watch') {
    $d = Start-CaseDir 'W-watch'
    Write-Log '--- PHASE W_watch (--watch, overlay absent) ---'
    $min = Invoke-Ctl 'minimize-riot' @('-TimeoutMs', '8000')
    Write-Log ("  minimize-riot : ok={0} overlay_gone_after_ms={1}" -f $min.result.ok, $min.result.overlay_gone_after_ms)
    if (-not $min.result.ok) { throw 'Impossible de faire disparaitre l overlay (minimize-riot).' }
    Write-Log '  attente stabilisation trim (12 s)...'
    Start-Sleep -Seconds 12
    $case = Run-MeasureCase -Label 'W-watch' -Dir $d -SamplerSeconds $DurationSeconds -ProbeSeconds ([math]::Min(60, $DurationSeconds))
    Add-PhaseResult 'W_watch' $case
    Write-Log '  W_watch termine.'
}

# ----------------------------------------------------------------------------
# Phase A_watch
# ----------------------------------------------------------------------------
if ($Phases -contains 'A_watch') {
    $d = Start-CaseDir 'A-watch'
    Write-Log '--- PHASE A_watch (--watch, overlay replie) ---'
    $fg = Invoke-Ctl 'foreground-riot-wait' @('-TimeoutMs', '8000')
    Write-Log ("  foreground-riot-wait : ok={0} fg_latency_ms={1} overlay_total_ms={2} state={3}" -f $fg.result.ok, $fg.result.fg_latency_ms, $fg.result.overlay_total_ms, $fg.result.overlay_state)
    Add-PhaseResult 'A_watch_transition' $fg.result
    Start-Sleep -Seconds 2
    $case = Run-MeasureCase -Label 'A-watch' -Dir $d -SamplerSeconds $DurationSeconds -ProbeSeconds ([math]::Min(60, $DurationSeconds))
    Add-PhaseResult 'A_watch' $case
    Write-Log '  A_watch termine.'
}

# ----------------------------------------------------------------------------
# Phase B_watch
# ----------------------------------------------------------------------------
if ($Phases -contains 'B_watch') {
    $d = Start-CaseDir 'B-watch-expanded'
    Write-Log '--- PHASE B_watch (panneau deplie statique) ---'
    $exp = Invoke-Ctl 'expand' @('-TimeoutMs', '3000')
    Write-Log ("  expand : ok={0} latency_ms={1} rect={2}" -f $exp.result.ok, $exp.result.latency_ms, $exp.result.overlay_rect)
    Add-PhaseResult 'B_watch_transition' $exp.result
    Start-Sleep -Seconds 1
    $case = Run-MeasureCase -Label 'B-watch-expanded' -Dir $d -SamplerSeconds $DurationSeconds -ProbeSeconds ([math]::Min(60, $DurationSeconds))
    Add-PhaseResult 'B_watch' $case
    Write-Log '  B_watch termine.'
}

# ----------------------------------------------------------------------------
# Phase C : interactions survol + molette
# ----------------------------------------------------------------------------
if ($Phases -contains 'C') {
    $d = Start-CaseDir 'C-interactions'
    Write-Log '--- PHASE C (survol + molette sur panneau deplie, sampler concurrent) ---'
    $exp = Invoke-Ctl 'expand' @('-TimeoutMs', '3000')
    if ($null -eq $exp.result -or -not $exp.result.ok) { throw 'Panneau non deplie pour la phase C.' }
    $snapBefore = Get-Snapshot 'before-C' $d
    $samplerJob = Start-SamplerProcess -Label 'C-interactions' -Seconds $ShortSeconds -Dir $d
    $probeJob = $null
    if ($Probe) { $probeJob = Start-ProbeProcess -Label 'C-interactions' -Seconds $ShortSeconds -Dir $d }
    Start-Sleep -Milliseconds 300
    $hover = Invoke-Ctl 'hover' @('-Count', '40', '-IntervalMs', '40')
    $wheel = Invoke-Ctl 'wheel' @('-Delta', '120', '-Count', '20', '-IntervalMs', '40')
    Wait-Jobs @($samplerJob, $probeJob)
    Start-Sleep -Milliseconds 300
    $snapAfter = Get-Snapshot 'after-C' $d
    $case = [ordered]@{
        label = 'C-interactions'
        hover = $hover.result
        wheel = $wheel.result
        sampler = $(if (Test-Path -LiteralPath $samplerJob.json) { Read-JsonFile $samplerJob.json } else { $null })
        probe = $(if ($null -ne $probeJob -and (Test-Path -LiteralPath $probeJob.json)) { Read-JsonFile $probeJob.json } else { $null })
        snapshot_before = (Snapshot-Brief $snapBefore)
        snapshot_after  = (Snapshot-Brief $snapAfter)
    }
    Add-PhaseResult 'C_interactions' $case
    Write-Log ("  C termine (hover send_mean={0} ms, wheel send_mean={1} ms)." -f $case.hover.send_mean_ms, $case.wheel.send_mean_ms)
}

# ----------------------------------------------------------------------------
# Phase D : suivi de fenetre
# ----------------------------------------------------------------------------
if ($Phases -contains 'D') {
    $d = Start-CaseDir 'D-follow'
    Write-Log '--- PHASE D (suivi deplacement Riot Client) ---'
    $col = Invoke-Ctl 'collapse' @('-TimeoutMs', '3000')
    if ($null -eq $col.result -or -not $col.result.ok) { throw 'Panneau non replie pour la phase D.' }
    Start-Sleep -Milliseconds 500
    $snapBefore = Get-Snapshot 'before-D' $d
    $samplerJob = Start-SamplerProcess -Label 'D-follow' -Seconds $ShortSeconds -Dir $d
    $probeJob = $null
    if ($Probe) { $probeJob = Start-ProbeProcess -Label 'D-follow' -Seconds $ShortSeconds -Dir $d }
    Start-Sleep -Milliseconds 300
    $mv1 = Invoke-Ctl 'move-riot' @('-DeltaX', '120', '-DeltaY', '0', '-Steps', '10', '-StepIntervalMs', '60')
    $mv2 = Invoke-Ctl 'move-riot' @('-DeltaX', '-60', '-DeltaY', '40', '-Steps', '10', '-StepIntervalMs', '60')
    $mv3 = Invoke-Ctl 'move-riot' @('-DeltaX', '0', '-DeltaY', '-80', '-Steps', '10', '-StepIntervalMs', '60')
    Wait-Jobs @($samplerJob, $probeJob)
    Start-Sleep -Milliseconds 300
    $snapAfter = Get-Snapshot 'after-D' $d
    $case = [ordered]@{
        label = 'D-follow'
        moves = @($mv1.result, $mv2.result, $mv3.result)
        sampler = $(if (Test-Path -LiteralPath $samplerJob.json) { Read-JsonFile $samplerJob.json } else { $null })
        probe = $(if ($null -ne $probeJob -and (Test-Path -LiteralPath $probeJob.json)) { Read-JsonFile $probeJob.json } else { $null })
        snapshot_before = (Snapshot-Brief $snapBefore)
        snapshot_after  = (Snapshot-Brief $snapAfter)
    }
    Add-PhaseResult 'D_follow' $case
    Write-Log '  D termine.'
}

# ----------------------------------------------------------------------------
# Phase E : cycles depliage/repliage
# ----------------------------------------------------------------------------
if ($Phases -contains 'E') {
    $d = Start-CaseDir 'E-cycles'
    Write-Log '--- PHASE E (cycles depliage/repliage) ---'
    $col = Invoke-Ctl 'collapse' @('-TimeoutMs', '3000')
    if ($null -eq $col.result -or -not $col.result.ok) { throw 'Panneau non replie pour la phase E.' }
    Start-Sleep -Milliseconds 500
    $snapBefore = Get-Snapshot 'before-E' $d
    $cpuBefore = $snapBefore.counters.cpu_total_seconds
    $cycleRun = Invoke-Ctl 'cycles' @('-Count', ("{0}" -f $Cycles), '-TimeoutMs', '3000')
    Start-Sleep -Milliseconds 500
    $snapAfter = Get-Snapshot 'after-E' $d
    $cpuAfter = $snapAfter.counters.cpu_total_seconds
    $case = [ordered]@{
        label = 'E-cycles'
        requested_cycles = $Cycles
        result = $cycleRun.result
        snapshot_before = (Snapshot-Brief $snapBefore)
        snapshot_after  = (Snapshot-Brief $snapAfter)
        cpu_seconds_delta = [math]::Round(($cpuAfter - $cpuBefore), 4)
        cpu_ms_per_cycle = [math]::Round((($cpuAfter - $cpuBefore) * 1000.0 / [math]::Max(1, $Cycles)), 3)
    }
    Add-PhaseResult 'E_cycles' $case
    Write-Log '  E termine.'
}

# ----------------------------------------------------------------------------
# Phase E2 : cycles destruction/recreation de l'overlay
# ----------------------------------------------------------------------------
if ($Phases -contains 'E2') {
    $d = Start-CaseDir 'E2-recreate'
    Write-Log '--- PHASE E2 (destruction/recreation overlay) ---'
    $col = Invoke-Ctl 'collapse' @('-TimeoutMs', '3000')
    if ($null -eq $col.result -or -not $col.result.ok) { throw 'Panneau non replie pour la phase E2.' }
    Start-Sleep -Milliseconds 500
    $snapBefore = Get-Snapshot 'before-E2' $d
    $iterations = New-Object System.Collections.Generic.List[object]
    for ($i = 1; $i -le $E2Cycles; $i++) {
        $gone = Invoke-Ctl 'minimize-riot' @('-TimeoutMs', '8000')
        $back = Invoke-Ctl 'foreground-riot-wait' @('-TimeoutMs', '8000')
        $iterations.Add([ordered]@{
            iteration             = $i
            overlay_gone_after_ms = $gone.result.overlay_gone_after_ms
            overlay_back_total_ms = $back.result.overlay_total_ms
            fg_latency_ms         = $back.result.fg_latency_ms
            overlay_rect          = $back.result.overlay_rect
            ok                    = [bool]($gone.result.ok -and $back.result.ok)
        })
        Write-Log ("  E2 iteration {0} : gone={1} ms, back={2} ms" -f $i, $gone.result.overlay_gone_after_ms, $back.result.overlay_total_ms)
        Start-Sleep -Milliseconds 300
    }
    $snapAfter = Get-Snapshot 'after-E2' $d
    $case = [ordered]@{
        label = 'E2-recreate'
        requested_cycles = $E2Cycles
        iterations = $iterations
        snapshot_before = (Snapshot-Brief $snapBefore)
        snapshot_after  = (Snapshot-Brief $snapAfter)
    }
    Add-PhaseResult 'E2_recreate' $case
    Write-Log '  E2 termine.'
}

# ----------------------------------------------------------------------------
# Fin propre : overlay replie, Riot au premier plan, veilleur en --watch
# ----------------------------------------------------------------------------
Write-Log '--- FIN : etat propre (veilleur --watch, overlay replie, Riot au premier plan) ---'
$st = Invoke-Ctl 'state'
if ($null -ne $st.result -and $st.result.overlay_state -eq 'expanded') { Invoke-Ctl 'collapse' @('-TimeoutMs', '3000') | Out-Null }
$finalFg = Invoke-Ctl 'foreground-riot-wait' @('-TimeoutMs', '8000')
$finalState = Invoke-Ctl 'state'
Write-Log ("  final : overlay={0} rect={1} fg={2}" -f $finalState.result.overlay_state, $finalState.result.overlay_rect, $finalState.result.foreground.title)

# ----------------------------------------------------------------------------
# Sortie de synthese
# ----------------------------------------------------------------------------
$summary = [ordered]@{
    campaign = [ordered]@{
        tag              = $Tag
        generated_at_utc = (Get-Date).ToUniversalTime().ToString('o')
        dir              = $CampaignDir
        quick            = [bool]$Quick
        probe_enabled    = [bool]$Probe
        phases           = $Phases
    }
    environment = $envInfo
    watcher_final_pid = $script:WatcherPid
    final_state = $finalState.result
    final_foreground_transition = $finalFg.result
    phases = $script:TransitionResults
}
$summaryPath = Join-Path $CampaignDir 'campaign-summary.json'
($summary | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $summaryPath -Encoding UTF8
Write-Log ("SYNTHESE : {0}" -f $summaryPath)
Write-Log '=== CAMPAGNE TERMINEE ==='
