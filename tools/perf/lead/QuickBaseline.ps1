<#
    QuickBaseline.ps1 - mesure provisoire du Lead (en attendant le sampler complet).
    Échantillonne un process externe à 1 Hz : CPU (% d'un cœur), working set, commit, handles, threads.
    PowerShell 5.1 compatible.
#>
param(
    [int]$ProcessId = 0,
    [string]$ProcessName = 'RiotSwitch',
    [int]$DurationSeconds = 120,
    [int]$IntervalMs = 1000,
    [string]$Label = 'W',
    [string]$Csv = ''
)

$ErrorActionPreference = 'Stop'
if ($ProcessId -gt 0) {
    $proc = Get-Process -Id $ProcessId
} else {
    $proc = Get-Process -Name $ProcessName -ErrorAction Stop | Sort-Object StartTime -Descending | Select-Object -First 1
}
$ProcessId = $proc.Id
$proc.Refresh()
$startTime = $proc.StartTime

$rows = New-Object System.Collections.Generic.List[object]
$prevCpu = $proc.TotalProcessorTime.TotalSeconds
$prevTime = [DateTime]::UtcNow
$t0 = [DateTime]::UtcNow
$maxSamples = [Math]::Ceiling($DurationSeconds * 1000.0 / $IntervalMs)

for ($i = 0; $i -lt $maxSamples; $i++) {
    Start-Sleep -Milliseconds $IntervalMs
    $proc.Refresh()
    $now = [DateTime]::UtcNow
    $cpu = $proc.TotalProcessorTime.TotalSeconds
    $wall = ($now - $prevTime).TotalSeconds
    $pct = 0.0
    if ($wall -gt 0) { $pct = ($cpu - $prevCpu) / $wall * 100.0 }
    $rows.Add([pscustomobject]@{
        iso_utc      = $now.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
        elapsed_s    = [Math]::Round(($now - $t0).TotalSeconds, 3)
        cpu_pct_core = [Math]::Round($pct, 3)
        cpu_total_s  = [Math]::Round($cpu, 4)
        ws_bytes     = $proc.WorkingSet64
        commit_bytes = $proc.PrivateMemorySize64
        handles      = $proc.HandleCount
        threads      = $proc.Threads.Count
    })
    $prevCpu = $cpu
    $prevTime = $now
}

$corePcts = @($rows | ForEach-Object { $_.cpu_pct_core } | Sort-Object)
function Get-Min($a) { if ($a.Count -eq 0) { 0 } else { $a[0] } }
function Get-Max($a) { if ($a.Count -eq 0) { 0 } else { $a[$a.Count - 1] } }
function Get-Median($a) {
    if ($a.Count -eq 0) { return 0 }
    $mid = [int][Math]::Floor($a.Count / 2)
    if ($a.Count % 2 -eq 1) { return $a[$mid] }
    return ($a[$mid - 1] + $a[$mid]) / 2.0
}
$cpuAvg = if ($corePcts.Count) { ($corePcts | Measure-Object -Average).Average } else { 0 }
$cpuTotalDelta = $rows[$rows.Count - 1].cpu_total_s - $rows[0].cpu_total_s + $rows[0].cpu_pct_core / 100.0  # approximation, le 1er échantillon démarre du début
$wallTotal = ($rows[$rows.Count - 1].elapsed_s) - 0
$ws = @($rows | ForEach-Object { $_.ws_bytes } | Sort-Object)
$commit = @($rows | ForEach-Object { $_.commit_bytes } | Sort-Object)
$handles = @($rows | ForEach-Object { $_.handles } | Sort-Object)
$threads = @($rows | ForEach-Object { $_.threads } | Sort-Object)

$summary = [pscustomobject]@{
    label             = $Label
    pid               = $ProcessId
    process           = $proc.ProcessName
    start_time_local  = $startTime.ToString("yyyy-MM-dd HH:mm:ss")
    measured_utc_from = $t0.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
    duration_s        = $wallTotal
    samples           = $rows.Count
    interval_ms       = $IntervalMs
    cores_logical     = [Environment]::ProcessorCount
    cpu_avg_pct_core  = [Math]::Round($cpuAvg, 3)
    cpu_avg_pct_machine = [Math]::Round($cpuAvg / [Environment]::ProcessorCount, 4)
    cpu_min_pct_core  = [Math]::Round((Get-Min $corePcts), 3)
    cpu_p50_pct_core  = [Math]::Round((Get-Median $corePcts), 3)
    cpu_max_pct_core  = [Math]::Round((Get-Max $corePcts), 3)
    cpu_used_s        = [Math]::Round($rows[$rows.Count - 1].cpu_total_s - ($rows[0].cpu_total_s - $rows[0].cpu_pct_core / 100.0 * ($rows[1].elapsed_s - $rows[0].elapsed_s)), 4)
    ws_min_mb         = [Math]::Round((Get-Min $ws) / 1MB, 2)
    ws_median_mb      = [Math]::Round((Get-Median $ws) / 1MB, 2)
    ws_max_mb         = [Math]::Round((Get-Max $ws) / 1MB, 2)
    commit_min_mb     = [Math]::Round((Get-Min $commit) / 1MB, 2)
    commit_median_mb  = [Math]::Round((Get-Median $commit) / 1MB, 2)
    commit_max_mb     = [Math]::Round((Get-Max $commit) / 1MB, 2)
    handles_min       = Get-Min $handles
    handles_median    = Get-Median $handles
    handles_max       = Get-Max $handles
    threads_min       = Get-Min $threads
    threads_max       = Get-Max $threads
}

if ($Csv -ne '') {
    $rows | Export-Csv -Path $Csv -NoTypeInformation -Encoding ASCII
}
Write-Output "SUMMARY_JSON"
$summary | ConvertTo-Json -Depth 4
Write-Output "SAMPLES_CSV"
if ($Csv -ne '') { Write-Output $Csv } else { $rows | ConvertTo-Csv -NoTypeInformation }
