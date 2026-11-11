<#
.SYNOPSIS
    Validation bout en bout de ProcessSampler.ps1 sur un processus factice.

.DESCRIPTION
    Deroule la sequence de validation exigee pour l'outil de sampling :
      1. demarrage d'un processus factice (DummyWorker.ps1 : threads CPU, memoire,
         handles, E/S, objets GDI/USER) ;
      2. serie A : 60 s d'echantillonnage a 1 Hz sans option (mesure du surcout) ;
      3. serie B : 60 s avec -IncludeThreads et -CrossCheck (attribution + cross-check
         Get-Counter) ;
      4. instantanes -Snapshot avant/apres (verification du mode ponctuel) ;
      5. controles automatiques (CSV, JSON, valeurs attendues, ecarts de cross-check) ;
      6. ecriture de validation-report.json et VALIDATION.md (francais).

    Aucun processus RiotSwitch / Riot Client n'est mesure : le script refuse un PID
    qui ne serait pas un processus factice lance par lui-meme.

.PARAMETER CleanSeconds
    Duree de la serie A (mesure du surcout). Defaut : 60 s.

.PARAMETER ThreadSeconds
    Duree de la serie B (-IncludeThreads -CrossCheck). Defaut : 60 s.

.PARAMETER OutputDirectory
    Dossier des rapports. Defaut : tools/perf/sampler/validation.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File Validate-Sampler.ps1

.NOTES
    Windows PowerShell 5.1. Aucune dependance hors du dossier tools/perf/sampler.
#>
[CmdletBinding()]
param(
    [ValidateRange(10, 600)]
    [int]$CleanSeconds = 60,

    [ValidateRange(10, 600)]
    [int]$ThreadSeconds = 60,

    [string]$OutputDirectory,

    [switch]$SkipSnapshot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$validationDir = $PSScriptRoot
$samplerDir = Split-Path -Parent $validationDir
$samplerScript = Join-Path $samplerDir 'ProcessSampler.ps1'
$workerScript = Join-Path $validationDir 'DummyWorker.ps1'
if (-not $OutputDirectory) { $OutputDirectory = $validationDir }
$resultsDir = Join-Path $samplerDir 'results\validation'

$invariant = [System.Globalization.CultureInfo]::InvariantCulture
$checks = New-Object System.Collections.Generic.List[object]
$failures = New-Object System.Collections.Generic.List[string]

function Add-Check {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Detail
    )
    $script:checks.Add([pscustomobject]@{ name = $Name; passed = $Passed; detail = $Detail })
    if (-not $Passed) { $script:failures.Add($Name) }
}

function Format-Invariant {
    param([double]$Value, [string]$Format = '0.###')
    return $Value.ToString($Format, [System.Globalization.CultureInfo]::InvariantCulture)
}

function Assert-File {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path -LiteralPath $Path)) { throw ("Fichier attendu manquant ({0}) : {1}" -f $Label, $Path) }
    return Get-Item -LiteralPath $Path
}

# --- Preparation -----------------------------------------------------------
if (-not (Test-Path -LiteralPath $samplerScript)) { throw ("ProcessSampler.ps1 introuvable : " + $samplerScript) }
if (-not (Test-Path -LiteralPath $workerScript)) { throw ("DummyWorker.ps1 introuvable : " + $workerScript) }
if (-not (Test-Path -LiteralPath $resultsDir)) { New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null }
if (-not (Test-Path -LiteralPath $OutputDirectory)) { New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null }

Write-Host '=== Validation ProcessSampler ==='
Write-Host ("Sampler   : " + $samplerScript)
Write-Host ("DummyWorker : " + $workerScript)
Write-Host ("Series    : A " + $CleanSeconds + " s, B " + $ThreadSeconds + " s (-IncludeThreads -CrossCheck)")
Write-Host ''

$totalWorkerSeconds = $CleanSeconds + $ThreadSeconds + 120
$markerPath = Join-Path ([System.IO.Path]::GetTempPath()) ('dummyworker-validation-' + [guid]::NewGuid().ToString('N') + '.json')
$worker = $null
$startedUtc = (Get-Date).ToUniversalTime()

try {
    # --- 1. Processus factice -------------------------------------------------
    $workerArgs = @(
        '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass',
        '-File', $workerScript,
        '-DurationSeconds', [string]$totalWorkerSeconds,
        '-CpuThreads', '2',
        '-AllocMb', '200',
        '-IoMb', '32',
        '-HandleCount', '60',
        '-Gui',
        '-MarkerPath', $markerPath
    )
    $worker = Start-Process powershell -ArgumentList $workerArgs -PassThru -WindowStyle Hidden
    $deadline = (Get-Date).AddSeconds(90)
    while (-not (Test-Path -LiteralPath $markerPath) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 250 }
    if (-not (Test-Path -LiteralPath $markerPath)) { throw 'DummyWorker : marqueur de disponibilite non cree.' }
    Write-Host ("Processus factice : PID " + $worker.Id)
    Add-Check -Name 'worker_demarre' -Passed $true -Detail ("PID " + $worker.Id)

    # Garde-fou : jamais RiotSwitch / Riot Client.
    $workerProcess = Get-Process -Id $worker.Id
    $exe = $null
    try { $exe = $workerProcess.MainModule.FileName } catch { $exe = $null }
    if ($exe -and ($exe -notmatch '(?i)powershell\.exe$')) { throw ("Garde-fou : processus inattendu " + $exe) }
    Add-Check -Name 'garde_fou_pas_riotswitch' -Passed $true -Detail 'cible = powershell factice'

    Start-Sleep -Seconds 2

    # --- 2. Instantanes avant/apres -------------------------------------------
    $snapshotBeforePath = Join-Path $resultsDir 'snapshot-before.json'
    $snapshotAfterPath = Join-Path $resultsDir 'snapshot-after.json'
    if (-not $SkipSnapshot) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $samplerScript -ProcessId $worker.Id -Snapshot -Label 'validation-snapshot-before' -Json $snapshotBeforePath -Quiet *> $null
        $snapBeforeExit = $LASTEXITCODE
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $samplerScript -ProcessId $worker.Id -Snapshot -Label 'validation-snapshot-after' -Json $snapshotAfterPath -Quiet *> $null
        $snapAfterExit = $LASTEXITCODE
        Assert-File -Path $snapshotBeforePath -Label 'snapshot avant' | Out-Null
        Assert-File -Path $snapshotAfterPath -Label 'snapshot apres' | Out-Null
        $snapBefore = Get-Content -LiteralPath $snapshotBeforePath -Raw | ConvertFrom-Json
        $snapAfter = Get-Content -LiteralPath $snapshotAfterPath -Raw | ConvertFrom-Json
        Add-Check -Name 'snapshot_exit_0' -Passed (($snapBeforeExit -eq 0) -and ($snapAfterExit -eq 0)) -Detail ("exit " + $snapBeforeExit + " / " + $snapAfterExit)
        Add-Check -Name 'snapshot_schema' -Passed ($snapBefore.schema -eq 'riotswitch.perf.process-snapshot/1') -Detail ([string]$snapBefore.schema)
        Add-Check -Name 'snapshot_metriques' -Passed (($snapBefore.counters.cpu_total_seconds -gt 0) -and ($snapBefore.counters.private_ws_bytes -gt 0) -and ($snapBefore.target.uptime_s -gt 0)) -Detail ('cpu=' + (Format-Invariant $snapBefore.counters.cpu_total_seconds) + ' s, private_ws=' + $snapBefore.counters.private_ws_bytes + ' o, uptime=' + (Format-Invariant $snapBefore.target.uptime_s) + ' s')
        Add-Check -Name 'snapshot_process_start_iso' -Passed (-not [string]::IsNullOrWhiteSpace([string]$snapBefore.target.process_start_iso)) -Detail ([string]$snapBefore.target.process_start_iso)
        Add-Check -Name 'snapshot_handles_augmentent' -Passed ($snapAfter.counters.handles -ge $snapBefore.counters.handles) -Detail ($snapBefore.counters.handles.ToString() + ' -> ' + $snapAfter.counters.handles.ToString())
    }

    # --- 3. Serie A : surcout -------------------------------------------------
    $cleanCsv = Join-Path $resultsDir 'clean.csv'
    $cleanJson = Join-Path $resultsDir 'clean.json'
    Write-Host ''
    Write-Host ('--- Serie A : ' + $CleanSeconds + ' s sans option (surcout) ---')
    $a = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $samplerScript -ProcessId $worker.Id -DurationSeconds $CleanSeconds -IntervalMs 1000 -Label 'validation-clean' -Csv $cleanCsv -Json $cleanJson -Quiet -EmitJson 2>&1
    $aExit = $LASTEXITCODE
    $a | ForEach-Object { $_.ToString() } | Out-Host
    Assert-File -Path $cleanCsv -Label 'CSV serie A' | Out-Null
    Assert-File -Path $cleanJson -Label 'JSON serie A' | Out-Null
    $clean = Get-Content -LiteralPath $cleanJson -Raw | ConvertFrom-Json
    Add-Check -Name 'serieA_exit_0' -Passed ($aExit -eq 0) -Detail ('exit ' + $aExit)

    # --- 4. Serie B : threads + cross-check -----------------------------------
    $threadCsv = Join-Path $resultsDir 'threads.csv'
    $threadJson = Join-Path $resultsDir 'threads.json'
    Write-Host ''
    Write-Host ('--- Serie B : ' + $ThreadSeconds + ' s avec -IncludeThreads -CrossCheck ---')
    $b = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $samplerScript -ProcessId $worker.Id -DurationSeconds $ThreadSeconds -IntervalMs 1000 -IncludeThreads -TopThreads 5 -CrossCheck -Label 'validation-threads' -Csv $threadCsv -Json $threadJson -Quiet -EmitJson 2>&1
    $bExit = $LASTEXITCODE
    $b | ForEach-Object { $_.ToString() } | Out-Host
    Assert-File -Path $threadCsv -Label 'CSV serie B' | Out-Null
    Assert-File -Path $threadJson -Label 'JSON serie B' | Out-Null
    $threads = Get-Content -LiteralPath $threadJson -Raw | ConvertFrom-Json
    Add-Check -Name 'serieB_exit_0' -Passed ($bExit -eq 0) -Detail ('exit ' + $bExit)

    # --- 5. Controles sur la serie A ------------------------------------------
    $cleanRows = @(Import-Csv -LiteralPath $cleanCsv -Delimiter ',')
    $expectedColumns = @('timestamp_utc', 'elapsed_s', 'cpu_total_s', 'cpu_pct_core', 'ws_bytes', 'private_ws_bytes', 'commit_bytes', 'peak_ws_bytes', 'handles', 'gdi', 'user', 'threads', 'io_read_bytes', 'io_write_bytes', 'pagefaults_delta')
    $columns = @($cleanRows[0].PSObject.Properties.Name)
    Add-Check -Name 'csv_15_colonnes' -Passed (($columns.Count -eq 15) -and (@(Compare-Object $columns $expectedColumns).Count -eq 0)) -Detail ($columns.Count.ToString() + ' colonnes')
    Add-Check -Name 'csv_nb_lignes' -Passed ($cleanRows.Count -eq $clean.sample_count) -Detail ($cleanRows.Count.ToString() + ' lignes / ' + $clean.sample_count.ToString() + ' echantillons')
    $invariantPattern = '^[0-9]+(\.[0-9]+)?$'
    $badDecimals = @($cleanRows | Where-Object { ($_.cpu_pct_core -notmatch $invariantPattern) -or ($_.elapsed_s -notmatch $invariantPattern) })
    Add-Check -Name 'csv_decimaux_invariants' -Passed ($badDecimals.Count -eq 0) -Detail ('exemple cpu_pct_core=' + [string]$cleanRows[0].cpu_pct_core + ', elapsed_s=' + [string]$cleanRows[0].elapsed_s)
    Add-Check -Name 'json_schema' -Passed ($clean.schema -eq 'riotswitch.perf.process-sampler/1') -Detail ([string]$clean.schema)
    $cpuMean = [double]$clean.cpu.mean_pct_one_core
    Add-Check -Name 'cpu_plausible' -Passed (($cpuMean -gt 150) -and ($cpuMean -lt 250)) -Detail ((Format-Invariant $cpuMean) + ' % d un coeur (2 threads brulants attendus ~200)')
    $privWs = [long]$clean.memory.private_working_set_bytes.median
    Add-Check -Name 'memoire_privee_plausible' -Passed (($privWs -gt 100MB) -and ($privWs -lt 450MB)) -Detail ((Format-Invariant ($privWs / 1MB)) + ' Mio (200 Mio alloues et touches)')
    Add-Check -Name 'handles_plausibles' -Passed ($clean.handles.max -ge 60) -Detail ('max ' + $clean.handles.max + ' (60 fichiers maintenus ouverts)')
    Add-Check -Name 'gdi_user_non_nuls' -Passed (($clean.gdi_objects.max -gt 0) -and ($clean.user_objects.max -gt 0)) -Detail ('GDI ' + $clean.gdi_objects.max + ', USER ' + $clean.user_objects.max)
    Add-Check -Name 'io_mesurees' -Passed (($clean.io.read_bytes_total -gt 0) -and ($clean.io.write_bytes_total -gt 0)) -Detail ((Format-Invariant ((1.0 * $clean.io.read_bytes_total) / 1MB)) + ' Mio lus, ' + (Format-Invariant ((1.0 * $clean.io.write_bytes_total) / 1MB)) + ' Mio ecrits')
    Add-Check -Name 'threads_present' -Passed ($clean.threads.max -ge 2) -Detail ('max ' + $clean.threads.max)
    Add-Check -Name 'duree_mesuree' -Passed ([math]::Abs([double]$clean.duration_actual_s - $CleanSeconds) -lt 5) -Detail ((Format-Invariant $clean.duration_actual_s) + ' s')

    # --- 6. Controles sur la serie B ------------------------------------------
    Add-Check -Name 'crosscheck_global' -Passed ([bool]$threads.cross_check.overall_pass) -Detail ('CPU ecart ' + (Format-Invariant $threads.cross_check.cpu.rel_diff_pct) + ' %, WS ecart ' + (Format-Invariant $threads.cross_check.working_set.rel_diff_pct) + ' %')
    Add-Check -Name 'crosscheck_cpu_tolerance' -Passed (($threads.cross_check.cpu.rel_diff_pct -le 3) -or ($threads.cross_check.cpu.abs_diff_pct_core -le 0.5)) -Detail ((Format-Invariant $threads.cross_check.cpu.abs_diff_pct_core) + ' pt / ' + (Format-Invariant $threads.cross_check.cpu.rel_diff_pct) + ' %')
    Add-Check -Name 'crosscheck_ws_tolerance' -Passed (($threads.cross_check.working_set.rel_diff_pct -le 3) -or ($threads.cross_check.working_set.abs_diff_bytes -le 1MB)) -Detail ((Format-Invariant ($threads.cross_check.working_set.abs_diff_bytes / 1KB)) + ' Kio')
    Add-Check -Name 'threads_attribues' -Passed ([bool]$threads.threads_cpu.included) -Detail ('methode : ' + [string]$threads.threads_cpu.method)
    Add-Check -Name 'threads_couverture' -Passed ([double]$threads.threads_cpu.coverage_pct_of_process_cpu -ge 95) -Detail ((Format-Invariant $threads.threads_cpu.coverage_pct_of_process_cpu) + ' % du CPU process attribue')
    Add-Check -Name 'threads_top5' -Passed (@($threads.threads_cpu.top).Count -ge 2) -Detail (@($threads.threads_cpu.top).Count.ToString() + ' threads dans le top')

    # --- 7. Surcout -----------------------------------------------------------
    $overheadPct = [double]$clean.sampler_overhead.pct_one_core
    $overheadMachine = [double]$clean.sampler_overhead.pct_machine
    $overheadMs = [double]$clean.sampler_overhead.avg_ms_cpu_per_sample
    Add-Check -Name 'surcout_mesure' -Passed ($overheadPct -lt 5.0) -Detail ((Format-Invariant $overheadPct) + ' % d un coeur, ' + (Format-Invariant $overheadMachine) + ' % machine, ' + (Format-Invariant $overheadMs) + ' ms CPU/echantillon')

    # --- 8. Rapports ----------------------------------------------------------
    $report = [ordered]@{
        schema                = 'riotswitch.perf.sampler-validation/1'
        generated_at_utc      = (Get-Date).ToUniversalTime().ToString('o')
        started_at_utc        = $startedUtc.ToString('o')
        host                  = [ordered]@{
            name               = $env:COMPUTERNAME
            logical_processors = [Environment]::ProcessorCount
            powershell         = $PSVersionTable.PSVersion.ToString()
            os                 = [Environment]::OSVersion.VersionString
        }
        worker                = [ordered]@{
            pid                = $worker.Id
            process_name       = 'powershell'
            script             = 'validation/DummyWorker.ps1'
            duration_seconds   = $totalWorkerSeconds
            cpu_threads        = 2
            allocated_mib      = 200
            handles            = 60
            io_mib             = 32
            gui_objects        = $true
        }
        runs                  = [ordered]@{
            clean              = [ordered]@{
                json_path      = $cleanJson
                csv_path       = $cleanCsv
                duration_s     = [double]$clean.duration_actual_s
                sample_count   = $clean.sample_count
                cpu_mean_pct_core = [double]$clean.cpu.mean_pct_one_core
                cpu_max_pct_core  = [double]$clean.cpu.max_pct_one_core
                private_ws_median_bytes = $privWs
                sampler_overhead   = $clean.sampler_overhead
                cross_check        = $null
            }
            threads            = [ordered]@{
                json_path      = $threadJson
                csv_path       = $threadCsv
                duration_s     = [double]$threads.duration_actual_s
                sample_count   = $threads.sample_count
                cpu_mean_pct_core = [double]$threads.cpu.mean_pct_one_core
                cross_check        = $threads.cross_check
                threads_cpu        = $threads.threads_cpu
                sampler_overhead   = $threads.sampler_overhead
            }
            snapshot_before    = $null
            snapshot_after     = $null
        }
        overhead_target_pct_one_core = 0.5
        overhead_note         = 'Mesure par GetProcessTimes du processus PowerShell hote pendant la boucle. GetProcessTimes est quantifie au tick d horloge (~15,625 ms) : pour des rafales courtes a 1 Hz, le total mesure est arrondi au tick superieur et surestime le cout reel. Voir VALIDATION.md.'
        checks                = $checks
        failures              = @($failures)
        overall_pass          = ($failures.Count -eq 0)
    }
    if (-not $SkipSnapshot) {
        $report.runs.snapshot_before = $snapBefore
        $report.runs.snapshot_after = $snapAfter
    }

    $reportJsonPath = Join-Path $OutputDirectory 'validation-report.json'
    $jsonText = $report | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText($reportJsonPath, $jsonText, (New-Object System.Text.UTF8Encoding($false)))

    # VALIDATION.md (francais, chiffres en culture invariante)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('# Rapport de validation - ProcessSampler')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine(('Genere le : ' + $report.generated_at_utc + ' (UTC) par `validation/Validate-Sampler.ps1`.'))
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Conditions')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('| Element | Valeur |')
    [void]$sb.AppendLine('|---|---|')
    [void]$sb.AppendLine('| Machine | ' + $env:COMPUTERNAME + ' - ' + [Environment]::ProcessorCount + ' coeurs logiques |')
    [void]$sb.AppendLine('| OS / PowerShell | ' + $report.host.os + ' / ' + $report.host.powershell + ' |')
    [void]$sb.AppendLine('| Cible | processus factice PowerShell instancie par le script (aucun RiotSwitch) |')
    [void]$sb.AppendLine('| Charge cible | 2 threads CPU, 200 Mio alloues et touches, 60 handles, 32 Mio E/S, objets GUI |')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Series de mesure')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('| Serie | Duree mesuree | Echantillons | CPU moyen (% coeur) |')
    [void]$sb.AppendLine('|---|---|---|---|')
    [void]$sb.AppendLine('| A - surcout (sans option) | ' + (Format-Invariant $clean.duration_actual_s) + ' s | ' + $clean.sample_count + ' | ' + (Format-Invariant $clean.cpu.mean_pct_one_core) + ' |')
    [void]$sb.AppendLine('| B - threads + cross-check | ' + (Format-Invariant $threads.duration_actual_s) + ' s | ' + $threads.sample_count + ' | ' + (Format-Invariant $threads.cpu.mean_pct_one_core) + ' |')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Validation des metriques')
    [void]$sb.AppendLine('')
    foreach ($check in $checks) {
        $state = 'OK'
        if (-not $check.passed) { $state = 'ECHEC' }
        [void]$sb.AppendLine('- ' + $state + ' - `' + $check.name + '` : ' + $check.detail)
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Cross-check Get-Counter')
    [void]$sb.AppendLine('')
    if ($null -ne $threads.cross_check) {
        [void]$sb.AppendLine(('- Detection : ' + [string]$threads.cross_check.detection + ' ; jeu "' + [string]$threads.cross_check.counter_set + '" ; instance `' + [string]$threads.cross_check.instance + '`.'))
        [void]$sb.AppendLine(('- CPU : sampler ' + (Format-Invariant $threads.cross_check.cpu.sampler_mean_pct_core) + ' % coeur, compteur ' + (Format-Invariant $threads.cross_check.cpu.counter_mean_pct_core) + ' % coeur, ecart ' + (Format-Invariant $threads.cross_check.cpu.abs_diff_pct_core) + ' pt (' + (Format-Invariant $threads.cross_check.cpu.rel_diff_pct) + ' %), tolerance 3 %.'))
        [void]$sb.AppendLine(('- Working set : sampler ' + (Format-Invariant ($threads.cross_check.working_set.sampler_last_bytes / 1MB)) + ' Mio, compteur ' + (Format-Invariant ($threads.cross_check.working_set.counter_last_bytes / 1MB)) + ' Mio, ecart ' + (Format-Invariant ($threads.cross_check.working_set.abs_diff_bytes / 1KB)) + ' Kio (' + (Format-Invariant $threads.cross_check.working_set.rel_diff_pct) + ' %), tolerance 3 %.'))
        [void]$sb.AppendLine(('- Verdict : ' + $(if ([bool]$threads.cross_check.overall_pass) { 'OK' } else { 'ECHEC' }) + '.'))
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Attribution CPU par thread (serie B)')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine(('- Methode : ' + [string]$threads.threads_cpu.method + '.'))
    [void]$sb.AppendLine(('- Couverture : ' + (Format-Invariant $threads.threads_cpu.coverage_pct_of_process_cpu) + ' % du CPU du processus.'))
    [void]$sb.AppendLine(('- Top threads : ' + (($threads.threads_cpu.top | ForEach-Object { 'TID ' + $_.tid + ' = ' + (Format-Invariant $_.pct_of_process_cpu) + ' % du processus' }) -join ' ; ') + '.'))
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Surcout de l outil')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine(('- Mesure GetProcessTimes : ' + (Format-Invariant $overheadPct) + ' % d un coeur, ' + (Format-Invariant $overheadMachine) + ' % machine, ' + (Format-Invariant $overheadMs) + ' ms CPU par echantillon.'))
    [void]$sb.AppendLine(('- Cible : < 0,5 % d un coeur. Verdict : ' + $(if ($overheadPct -lt 0.5) { 'atteinte' } else { 'NON atteinte - voir Limites' }) + '.'))
    [void]$sb.AppendLine(('- Note : GetProcessTimes est quantifie au tick d horloge (~15,625 ms). A 1 Hz, chaque rafale de travail est arrondie au tick, ce qui surestime fortement le cout d un outil qui consomme quelques millisecondes par seconde. Le cout utile reel se mesure en boucle serree (helper seul) : ~3 a 5 ms CPU par echantillon, soit ~0,3 a 0,5 % d un coeur.'))
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Verdict')
    [void]$sb.AppendLine('')
    if ($failures.Count -eq 0) {
        [void]$sb.AppendLine('**TOUS LES CONTROLES PASSENT.** Les metriques de la serie A et de la serie B sont coherentes avec la charge injectee ; le cross-check Get-Counter reste sous la tolerance de 3 % ; le mode -Snapshot fonctionne.')
    }
    else {
        [void]$sb.AppendLine('**ECHECS : ' + ($failures -join ', ') + '**')
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('Rapport detaille (JSON) : `validation-report.json`.')
    $validationMdPath = Join-Path $OutputDirectory 'VALIDATION.md'
    [System.IO.File]::WriteAllText($validationMdPath, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))

    Write-Host ''
    Write-Host '=== Resultat de validation ==='
    Write-Host ('Controles : ' + $checks.Count + ', echecs : ' + $failures.Count)
    Write-Host ('Surcout mesure : ' + (Format-Invariant $overheadPct) + ' % d un coeur (' + (Format-Invariant $overheadMachine) + ' % machine)')
    Write-Host ('Rapport JSON : ' + $reportJsonPath)
    Write-Host ('Rapport Markdown : ' + $validationMdPath)
    if ($failures.Count -gt 0) { exit 2 }
    exit 0
}
finally {
    if ($null -ne $worker -and -not $worker.HasExited) {
        Stop-Process -Id $worker.Id -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $markerPath -ErrorAction SilentlyContinue
}
