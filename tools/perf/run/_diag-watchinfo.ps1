$ErrorActionPreference = 'Continue'
$procs = @(Get-CimInstance Win32_Process -Filter "Name='RiotSwitch.exe'" -ErrorAction SilentlyContinue)
Write-Host ("cim_count=" + $procs.Count)
foreach ($p in $procs) { Write-Host ("cim pid=" + $p.ProcessId + " cmd=" + $p.CommandLine) }
$ps = @(Get-Process -Name 'RiotSwitch' -ErrorAction SilentlyContinue)
Write-Host ("getprocess_count=" + $ps.Count)
foreach ($p in $ps) { Write-Host ("gp pid=" + $p.Id) }
$out = New-Object System.Collections.Generic.List[object]
foreach ($p in $procs) {
    $cmd = $null
    try { $cmd = $p.CommandLine } catch { $cmd = 'ERR' }
    $out.Add([pscustomobject]@{ pid = [int]$p.ProcessId; command_line = $cmd })
}
Write-Host ("list_count=" + $out.Count)
$r = $out
Write-Host ("ret_count=" + @($r).Count)
