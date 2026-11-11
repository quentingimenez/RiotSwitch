# Comparaison A/B finale sous activite utilisateur reelle (sans interaction UI)
# NEW (build Release) -> OLD (dist) -> NEW, 180 s chacun, sampler 1 Hz.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
Set-Location $root
$out = Join-Path $root 'tools\perf\results\compare'
$sampler = Join-Path $root 'tools\perf\sampler\ProcessSampler.ps1'
$ctl = Join-Path $root 'tools\perf\run\OverlayCtl.ps1'
$start = Join-Path $root 'tools\perf\run\Start-Watcher.ps1'
$newExe = Join-Path $root 'src\RiotSwitcher.App\bin\Release\net8.0-windows\RiotSwitch.exe'
$oldExe = Join-Path $root 'dist\RiotSwitch.exe'

function Sample-Run([string]$label, [int]$procId) {
    $csv = Join-Path $out ("abactive-$label.csv")
    $json = Join-Path $out ("abactive-$label.json")
    & $sampler -ProcessId $procId -DurationSeconds 180 -IntervalMs 1000 -Csv $csv -Json $json -Label "abactive-$label" -IncludeThreads -Quiet
    $d = Get-Content -LiteralPath $json -Raw -Encoding UTF8 | ConvertFrom-Json
    $c = $d.cpu
    $ws = $d.memory.working_set_bytes
    $wsMed = if ($ws -is [System.Management.Automation.PSCustomObject]) { $ws.median } else { $null }
    Write-Output ("RESULT {0} pid={1} cpu_agg={2} mean={3} max={4} total_s={5} ws_med={6} commit={7} handles={8}" -f $label, $procId, $c.aggregate_pct_one_core, $c.mean_pct_one_core, $c.max_pct_one_core, $c.total_cpu_seconds, $wsMed, $d.memory.commit_bytes, ($d.handles | ConvertTo-Json -Compress))
}

# 1) NEW (watcher deja en place)
$st = (& $ctl -Action state -Quiet | ConvertFrom-Json)
$newPid = [int]$st.riotswitch_pid
Write-Output ("PHASE NEW1 pid={0} utc={1}" -f $newPid, (Get-Date).ToUniversalTime().ToString('o'))
Sample-Run 'new1' $newPid

# 2) OLD
(& $ctl -Action quit-watcher -Quiet | Out-Null)
Start-Sleep -Seconds 2
$w = (& $start -Mode watch -ExePath $oldExe | ConvertFrom-Json)
Write-Output ("PHASE OLD pid={0}" -f $w.pid)
Start-Sleep -Seconds 15
Sample-Run 'old' ([int]$w.pid)

# 3) NEW2
(& $ctl -Action quit-watcher -Quiet | Out-Null)
Start-Sleep -Seconds 2
$w2 = (& $start -Mode watch -ExePath $newExe | ConvertFrom-Json)
Write-Output ("PHASE NEW2 pid={0}" -f $w2.pid)
Start-Sleep -Seconds 15
Sample-Run 'new2' ([int]$w2.pid)

Write-Output 'ABACTIVE DONE'
