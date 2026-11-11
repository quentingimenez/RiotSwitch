# Re-mesure ciblee B (panneau deplie, longue fenetre) et E (cycles expand/collapse)
# Genere: tools/perf/results/campaign-official-06/B-long/ et E-long/
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))  # ...\RiotSwitch
Set-Location $root
$out = Join-Path $root 'tools\perf\results\campaign-official-06'
$sampler = Join-Path $root 'tools\perf\sampler\ProcessSampler.ps1'
$ctl = Join-Path $root 'tools\perf\run\OverlayCtl.ps1'

function Call-Ctl([string]$action, [string[]]$extra = @()) {
    $raw = & $ctl -Action $action -Quiet @extra
    return ($raw | ConvertFrom-Json)
}

$state = Call-Ctl 'state'
$procId = [int]$state.riotswitch_pid
Write-Output ("START pid={0} overlay={1} visible={2} fg={3} utc={4}" -f $procId, $state.overlay_state, $state.overlay_visible, $state.foreground.title, (Get-Date).ToUniversalTime().ToString('o'))

# ---- B-long : panneau deplie, 300 s ----
$bDir = Join-Path $out 'B-long'
New-Item -ItemType Directory -Force -Path $bDir | Out-Null
$exp = Call-Ctl 'expand'
Write-Output ("EXPAND ok={0} latency_ms={1} rect={2}" -f $exp.ok, $exp.latency_ms, $exp.overlay_rect)
Start-Sleep -Seconds 3
$snapBefore = & $sampler -ProcessId $procId -Snapshot -Json (Join-Path $bDir 'snapshot-before-B-long.json') -Quiet
$csv = Join-Path $bDir 'B-long.csv'
$json = Join-Path $bDir 'B-long.json'
& $sampler -ProcessId $procId -DurationSeconds 300 -IntervalMs 1000 -Csv $csv -Json $json -Label 'B-long' -IncludeThreads -Quiet
Write-Output 'B-LONG SAMPLER DONE'
$snapAfter = & $sampler -ProcessId $procId -Snapshot -Json (Join-Path $bDir 'snapshot-after-B-long.json') -Quiet
$col = Call-Ctl 'collapse'
Write-Output ("COLLAPSE ok={0} latency_ms={1}" -f $col.ok, $col.latency_ms)

# ---- E-long : 60 cycles ----
$eDir = Join-Path $out 'E-long'
New-Item -ItemType Directory -Force -Path $eDir | Out-Null
$snapE0 = & $sampler -ProcessId $procId -Snapshot -Json (Join-Path $eDir 'snapshot-before-E-long.json') -Quiet
$cycRaw = & $ctl -Action cycles -Count 60 -IntervalMs 120 -Quiet
$cyc = $cycRaw | ConvertFrom-Json
$cyc | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $eDir 'cycles-raw.json') -Encoding UTF8
$snapE1 = & $sampler -ProcessId $procId -Snapshot -Json (Join-Path $eDir 'snapshot-after-E-long.json') -Quiet
Write-Output ("CYCLES ok={0} total_ms={1}" -f $cyc.ok, $cyc.total_ms)
Write-Output 'ALL DONE'
