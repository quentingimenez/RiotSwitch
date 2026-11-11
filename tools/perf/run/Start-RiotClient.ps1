param(
    [int]$WaitSeconds = 90
)

$ErrorActionPreference = 'Stop'

$exe = 'C:\Riot Games\Riot Client\RiotClientServices.exe'
$installRoot = 'C:\Riot Games\Riot Client'
if (-not (Test-Path -LiteralPath $exe)) { throw "RiotClientServices.exe introuvable : $exe" }

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $exe
$psi.Arguments = ''
$psi.WorkingDirectory = $installRoot
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
foreach ($k in @($psi.EnvironmentVariables.Keys)) {
    if ($k -ieq 'ELECTRON_RUN_AS_NODE' -or $k -ieq 'ELECTRON_NO_ATTACH_CONSOLE') {
        [void]$psi.EnvironmentVariables.Remove($k)
    }
}
$started = [System.Diagnostics.Process]::Start($psi)
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$uiPids = @()
$windowFound = $false
while ($sw.Elapsed.TotalSeconds -lt $WaitSeconds) {
    $uiPids = @(Get-Process -Name 'Riot Client' -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
    if ($uiPids.Count -gt 0) {
        # attendre que la fenetre principale expose un titre
        $cand = @(Get-Process -Name 'Riot Client' -ErrorAction SilentlyContinue)
        foreach ($p in $cand) {
            if ($p.MainWindowHandle -ne 0 -and -not [string]::IsNullOrWhiteSpace($p.MainWindowTitle)) {
                $windowFound = $true
                break
            }
        }
        if ($windowFound) { break }
    }
    Start-Sleep -Milliseconds 500
}
$sw.Stop()

[ordered]@{
    ok                = $windowFound
    service_pid       = $started.Id
    ui_pids           = $uiPids
    window_found      = $windowFound
    waited_ms         = [math]::Round($sw.Elapsed.TotalMilliseconds, 0)
    lockfile_exists   = (Test-Path (Join-Path $env:LOCALAPPDATA 'Riot Games\Riot Client\Config\lockfile'))
} | ConvertTo-Json -Compress
