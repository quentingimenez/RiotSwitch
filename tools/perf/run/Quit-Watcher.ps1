<#
.SYNOPSIS
    Arret PROPRE du veilleur RiotSwitch via son message inter-instances (pas de kill).

.DESCRIPTION
    Poste le message enregistre "RiotSwitch.Quit" (RegisterWindowMessage) a HWND_BROADCAST,
    exactement comme le fait WatchMessageWindow.QuitMessage de l'application, puis attend la
    sortie du processus cible (graceful, Dispose des fenetres/timers/hooks).

    Aucun Stop-Process n'est utilise par defaut. -ForceKill existe en dernier recours
    (a n'utiliser que si -VerifiedExit retourne false), mais n'est PAS employe dans la
    campagne de mesure.

.PARAMETER ProcessId
    PID du veilleur RiotSwitch a arreter. Si absent : premier processus RiotSwitch trouve.

.PARAMETER TimeoutSeconds
    Delai maximum d'attente de sortie (defaut 10 s).

.PARAMETER ForceKill
    Si la sortie propre echoue dans le delai, tue le processus (defaut : non).

.OUTPUTS
    JSON sur stdout : { ok, pid, exited, waited_ms, forced, error }

.EXAMPLE
    .\Quit-Watcher.ps1
#>
[CmdletBinding()]
param(
    [int]$ProcessId = 0,
    [ValidateRange(1, 120)][int]$TimeoutSeconds = 10,
    [switch]$ForceKill
)

$ErrorActionPreference = 'Stop'

$nativeSource = @'
using System;
using System.Runtime.InteropServices;

namespace RiotSwitchPerf.Run
{
    public static class WatcherControl
    {
        public const int WM_BROADCAST = 0xFFFF;

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern uint RegisterWindowMessage(string lpString);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

        public static uint GetQuitMessage() { return RegisterWindowMessage("RiotSwitch.Quit"); }
        public static uint GetShowSettingsMessage() { return RegisterWindowMessage("RiotSwitch.ShowSettings"); }
        public static bool BroadcastQuit() { return PostMessage(new IntPtr(WM_BROADCAST), GetQuitMessage(), IntPtr.Zero, IntPtr.Zero); }
        public static bool BroadcastShowSettings() { return PostMessage(new IntPtr(WM_BROADCAST), GetShowSettingsMessage(), IntPtr.Zero, IntPtr.Zero); }
    }
}
'@

Add-Type -TypeDefinition $nativeSource -Language CSharp

function Write-JsonResult {
    param($Object)
    $json = $Object | ConvertTo-Json -Compress -Depth 6
    Write-Output $json
}

$target = $null
if ($ProcessId -gt 0) {
    $target = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
}
if ($null -eq $target) {
    $candidates = @(Get-Process -Name 'RiotSwitch' -ErrorAction SilentlyContinue)
    if ($candidates.Count -eq 1) { $target = $candidates[0] }
    elseif ($candidates.Count -gt 1) {
        Write-JsonResult ([pscustomobject]@{
            ok = $false; pid = 0; exited = $false; waited_ms = 0; forced = $false
            error = "Plusieurs processus RiotSwitch : preciser -ProcessId (" + (($candidates | ForEach-Object { $_.Id }) -join ',') + ")."
        })
        exit 2
    }
}
if ($null -eq $target) {
    Write-JsonResult ([pscustomobject]@{ ok = $false; pid = 0; exited = $false; waited_ms = 0; forced = $false; error = 'Aucun processus RiotSwitch trouve.' })
    exit 2
}

$watcherPid = $target.Id
$watch = [System.Diagnostics.Stopwatch]::StartNew()
$posted = $false
$errorText = $null
try {
    $posted = [RiotSwitchPerf.Run.WatcherControl]::BroadcastQuit()
} catch {
    $errorText = $_.Exception.Message
}

$exited = $false
$forced = $false
while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
    $proc = Get-Process -Id $watcherPid -ErrorAction SilentlyContinue
    if ($null -eq $proc) { $exited = $true; break }
    Start-Sleep -Milliseconds 100
}

if (-not $exited -and $ForceKill) {
    try {
        Stop-Process -Id $watcherPid -Force -ErrorAction Stop
        $forced = $true
        Start-Sleep -Milliseconds 300
        $exited = ($null -eq (Get-Process -Id $watcherPid -ErrorAction SilentlyContinue))
    } catch {
        $errorText = "ForceKill: " + $_.Exception.Message
    }
}

$watch.Stop()
Write-JsonResult ([pscustomobject]@{
    ok       = $exited
    pid      = $watcherPid
    posted   = $posted
    exited   = $exited
    waited_ms = [math]::Round($watch.Elapsed.TotalMilliseconds, 1)
    forced   = $forced
    error    = $errorText
})
if (-not $exited) { exit 2 }
