#requires -Version 5
<#
  _EventGen.ps1 - generateur d'evenements WinEvent pour l'auto-test de la sonde.
  1) Cree une fenetre WinForms HORS ECRAN (position -32000) et la deplace, la cache,
     la re-affiche puis la ferme -> evenements OBJECT idObject == 0 (fenetre).
     Aucune fenetre existante n'est touchee, aucune activation/focus (SWP_NOACTIVATE).
  2) Emet en plus quelques evenements SYNTHETIQUES via NotifyWinEvent() avec un
     idObject != 0 (OBJID_CARET=-8 / OBJID_CURSOR=-9 / OBJID_CLIENT=-4), pour prouver
     que la sonde compte bien la partition idObject != 0 (evenements que l'application
     RiotSwitch filtre immediatement). NotifyWinEvent ne touche aucune fenetre : il
     signale seulement l'evenement aux hooks enregistres.
  Usage : powershell -NoProfile -File _EventGen.ps1 -DurationMs 12000
#>
param(
    [int]$DurationMs = 12000,
    [int]$StepMs = 10,
    [int]$SyntheticCount = 2000
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class EventGenNative
{
    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

    [DllImport("user32.dll")]
    public static extern void NotifyWinEvent(uint eventId, IntPtr hwnd, int idObject, int idChild);

    public const uint SWP_NOSIZE = 0x0001;
    public const uint SWP_NOZORDER = 0x0004;
    public const uint SWP_NOACTIVATE = 0x0010;

    public const uint EVENT_OBJECT_CREATE = 0x8000;
    public const uint EVENT_OBJECT_SHOW = 0x8002;
    public const uint EVENT_OBJECT_LOCATIONCHANGE = 0x800B;

    public const int OBJID_CLIENT = -4;
    public const int OBJID_CARET = -8;
    public const int OBJID_CURSOR = -9;
    public const int CHILDID_SELF = 0;
}
'@

$form = New-Object System.Windows.Forms.Form
$form.Text = 'ProbeSelfTest'
$form.ShowInTaskbar = $false
$form.StartPosition = 'Manual'
$form.Location = New-Object System.Drawing.Point(-32000, -32000)
$form.Size = New-Object System.Drawing.Size(120, 80)
$form.Show()

$h = $form.Handle
Write-Output ("GEN_READY pid=" + $PID + " duration_ms=" + $DurationMs + " synthetic_target=" + $SyntheticCount)

# Les evenements synthetiques (idObject != 0) sont emis PENDANT la boucle principale,
# afin de tomber dans la fenetre de mesure de la sonde (pas seulement avant).
$sent = 0
$flags = [EventGenNative]::SWP_NOSIZE -bor [EventGenNative]::SWP_NOZORDER -bor [EventGenNative]::SWP_NOACTIVATE
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$i = 0
$hidden = $false

while ($sw.ElapsedMilliseconds -lt $DurationMs)
{
    # Deplacement horizontal hors ecran -> EVENT_OBJECT_LOCATIONCHANGE (0x800B, idObject=0).
    $x = -32000 + (($i % 40) * 8)
    [void][EventGenNative]::SetWindowPos($h, [IntPtr]::Zero, $x, -32000, 0, 0, $flags)
    $i++

    # Toutes les 20 pas : cacher puis re-afficher -> EVENT_OBJECT_HIDE/SHOW (idObject=0).
    if (($i % 20) -eq 0)
    {
        if ($hidden) { $form.Show(); $hidden = $false } else { $form.Hide(); $hidden = $true }
        [System.Threading.Thread]::Sleep(15)
    }

    # Toutes les 20 pas : evenements synthetiques idObject != 0 (partition non-window).
    if (($i % 20) -eq 0 -and $sent -lt $SyntheticCount)
    {
        [EventGenNative]::NotifyWinEvent([EventGenNative]::EVENT_OBJECT_CREATE, $h, [EventGenNative]::OBJID_CLIENT, [EventGenNative]::CHILDID_SELF)
        [EventGenNative]::NotifyWinEvent([EventGenNative]::EVENT_OBJECT_SHOW, $h, [EventGenNative]::OBJID_CARET, [EventGenNative]::CHILDID_SELF)
        [EventGenNative]::NotifyWinEvent([EventGenNative]::EVENT_OBJECT_LOCATIONCHANGE, $h, [EventGenNative]::OBJID_CURSOR, [EventGenNative]::CHILDID_SELF)
        $sent += 3
    }
    [System.Threading.Thread]::Sleep($StepMs)
}

# Fermeture -> EVENT_OBJECT_DESTROY.
$form.Close()
Write-Output ("GEN_DONE pid=" + $PID + " moves=" + $i + " synthetic=" + $sent)
