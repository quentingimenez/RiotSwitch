<#
.SYNOPSIS
    Demarre une instance de veilleur RiotSwitch pour la campagne de mesure.

.DESCRIPTION
    Lance <dist>\RiotSwitch.exe avec le mode demande (--watch par defaut), note le PID, le
    temps de demarrage (UTC + QPC) et la taille du log applicatif AVANT lancement, pour
    permettre ensuite de mesurer la latence de demarrage a froid.

    Ne lance JAMAIS Riot Client (--watch n'appelle pas StartRiot). Ne tue rien.
    Verifie que le processus est bien proprietaire de l'instance unique (mutex).

.PARAMETER Mode
    'watch' : RiotSwitch.exe --watch (veilleur persistant, mode par defaut documente).
    'launcher' : RiotSwitch.exe --launch-riot --ephemeral (mode zero fond, utilise seulement
                 pour restaurer l'etat initial apres la campagne ; peut lancer Riot Client).

.PARAMETER ExePath
    Chemin de l'executable (defaut : <repo>\dist\RiotSwitch.exe).

.PARAMETER WaitReadyMs
    Attente maximale de stabilisation du processus avant sortie (defaut 1500 ms).

.OUTPUTS
    JSON sur stdout : { ok, pid, mode, started_utc, log_length_before, exe, error }
#>
[CmdletBinding()]
param(
    [ValidateSet('watch', 'launcher')][string]$Mode = 'watch',
    [string]$ExePath = '',
    [ValidateRange(0, 60000)][int]$WaitReadyMs = 1500
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
if (-not $ExePath) { $ExePath = Join-Path $repoRoot 'dist\RiotSwitch.exe' }
if (-not (Test-Path -LiteralPath $ExePath)) {
    ([pscustomobject]@{ ok = $false; pid = 0; mode = $Mode; started_utc = $null; log_length_before = 0; exe = $ExePath; error = "Executable introuvable : $ExePath" } | ConvertTo-Json -Compress)
    exit 2
}

$logPath = Join-Path $env:LOCALAPPDATA 'RiotSwitch\logs\app.log'
$logLengthBefore = 0
if (Test-Path -LiteralPath $logPath) { $logLengthBefore = (Get-Item -LiteralPath $logPath).Length }

$existing = @(Get-Process -Name 'RiotSwitch' -ErrorAction SilentlyContinue)
if ($existing.Count -gt 0) {
    ([pscustomobject]@{
        ok = $false; pid = 0; mode = $Mode; started_utc = $null; log_length_before = $logLengthBefore; exe = $ExePath
        error = "Un veilleur tourne deja (PID " + (($existing | ForEach-Object { $_.Id }) -join ',') + ") : arreter proprement avant de demarrer."
    } | ConvertTo-Json -Compress)
    exit 2
}

$arguments = @()
if ($Mode -eq 'watch') { $arguments = @('--watch') }
else { $arguments = @('--launch-riot', '--ephemeral') }

$startedUtc = (Get-Date).ToUniversalTime().ToString('o')
$qpc = [System.Diagnostics.Stopwatch]::GetTimestamp()

try {
    $proc = Start-Process -FilePath $ExePath -ArgumentList $arguments -WorkingDirectory (Split-Path -Parent $ExePath) -PassThru
} catch {
    ([pscustomobject]@{ ok = $false; pid = 0; mode = $Mode; started_utc = $startedUtc; log_length_before = $logLengthBefore; exe = $ExePath; error = $_.Exception.Message } | ConvertTo-Json -Compress)
    exit 2
}

Start-Sleep -Milliseconds $WaitReadyMs

$alive = $null -ne (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue)
$errorText = $null
if (-not $alive) {
    $errorText = "Le processus a quitte pendant la stabilisation (une autre instance est peut-etre deja proprietaire du mutex)."
}

([pscustomobject]@{
    ok             = $alive
    pid            = $proc.Id
    mode           = $Mode
    args           = $arguments
    started_utc    = $startedUtc
    qpc_start      = $qpc
    qpc_end        = [System.Diagnostics.Stopwatch]::GetTimestamp()
    log_length_before = $logLengthBefore
    log_path       = $logPath
    exe            = $ExePath
    error          = $errorText
} | ConvertTo-Json -Compress)
if (-not $alive) { exit 2 }
