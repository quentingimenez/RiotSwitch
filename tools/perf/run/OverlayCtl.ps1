<#
.SYNOPSIS
    Controle externe de l'overlay RiotSwitch pour la campagne de mesure (lecture + actions
    synthetiques, sans toucher a la souris reelle, sans redemarrer l'application).

.DESCRIPTION
    Outil du Lead (scope tools/perf/run). Il ne modifie ni src ni dist ; il se contente
    d'observer les fenetres (EnumWindows, GetWindowRect) et d'envoyer des messages de souris
    a la fenetre overlay (WM_MOUSEMOVE, WM_LBUTTONDOWN/UP, WM_MOUSEWHEEL), de mettre une
    fenetre au premier plan et de deplacer la fenetre du Riot Client pour mesurer la latence
    de suivi de l'overlay.

    Toutes les latences chaudes (premier changement observe, apparition de l'overlay) sont
    mesurees dans le helper C# avec un Stopwatch pour eviter la granularite de PowerShell.
    L'horodatage des mesures externes est UTC ISO.

    Actions :
      discover        etat complet : PID RiotSwitch, overlay (hwnd, rect, etat), Riot Client
                      (hwnd, rect, foreground), DPI, offsets des settings, foreground global.
      state           etat overlay + foreground uniquement.
      foreground-riot met la fenetre Riot Client au premier plan (plusieurs strategies).
      wait-overlay    attend l'apparition de l'overlay visible (mesure de latence).
      expand          developpe le panneau (clic synthetique sur le bouton replie).
      collapse        replie le panneau (clic synthetique sur la croix).
      hover           serie de WM_MOUSEMOVE sur le panneau (compteur d'activite).
      wheel           serie de WM_MOUSEWHEEL sur le panneau.
      move-riot       deplace la fenetre Riot Client par pas et mesure la latence de suivi
                      de l'overlay (unites : millisecondes avec 3 decimales).
      list-windows    liste des fenetres top-level visibles (diagnostic).
      quit-watcher    arret PROPRE du veilleur via le message "RiotSwitch.Quit" + attente.

    Sortie : un objet JSON unique sur stdout. Code de sortie 2 en cas d'echec (JSON ok=false).

.PARAMETER Action
    Voir ci-dessus.

.PARAMETER TimeoutMs
    Delai maximal pour wait-overlay / move-riot / foreground-riot (defaut 3000).

.PARAMETER Count
    Nombre de repetitions pour hover / wheel (defaut 10).

.PARAMETER IntervalMs
    Intervalle entre repetitions pour hover / wheel (defaut 80).

.PARAMETER Delta
    Delta de molette en unites Windows pour wheel (defaut 120 = un cran).

.PARAMETER DeltaX, DeltaY
    Deplacement par pas pour move-riot (pixels, defaut +120/0).

.PARAMETER Steps
    Nombre de pas pour move-riot (defaut 10, alternance aller/retour si -ZigZag).

.PARAMETER StepIntervalMs
    Pause entre deux pas de move-riot (defaut 120 ms).

.PARAMETER Restore
    Pour move-riot : restaure la position d'origine de la fenetre Riot a la fin (defaut : oui,
    utiliser -Restore:$false pour la laisser deplacee).

.EXAMPLE
    .\OverlayCtl.ps1 -Action discover
.EXAMPLE
    .\OverlayCtl.ps1 -Action foreground-riot -TimeoutMs 2000
.EXAMPLE
    .\OverlayCtl.ps1 -Action move-riot -DeltaX 120 -Steps 10 -StepIntervalMs 120
#>
[CmdletBinding()]
param(
    [ValidateSet('discover', 'state', 'foreground-riot', 'wait-overlay', 'expand', 'collapse',
                 'hover', 'wheel', 'move-riot', 'minimize-riot', 'minimize-riot-window', 'hide-riot-window', 'wait-overlay-absent', 'cycles', 'foreground-riot-wait', 'list-windows', 'quit-watcher')]
    [string]$Action = 'discover',
    [ValidateRange(50, 60000)][int]$TimeoutMs = 3000,
    [ValidateRange(1, 10000)][int]$Count = 10,
    [ValidateRange(0, 5000)][int]$IntervalMs = 80,
    [int]$Delta = 120,
    [int]$DeltaX = 120,
    [int]$DeltaY = 0,
    [ValidateRange(1, 200)][int]$Steps = 10,
    [ValidateRange(0, 5000)][int]$StepIntervalMs = 120,
    [switch]$Restore,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$Invariant = [System.Globalization.CultureInfo]::InvariantCulture

$nativeSource = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace RiotSwitchPerf.RunCtl
{
    public static class RunCtl
    {
        public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

        [StructLayout(LayoutKind.Sequential)]
        public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

        [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
        [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder sb, int max);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, StringBuilder sb, int max);
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
        [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
        [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
        [DllImport("user32.dll")] public static extern void SwitchToThisWindow(IntPtr hWnd, bool fAltTab);
        [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
        [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern uint GetDpiForSystem();
        [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern uint RegisterWindowMessage(string lpString);
        [DllImport("user32.dll", SetLastError = true)] public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

        public const int WM_LBUTTONDOWN = 0x0201;
        public const int WM_LBUTTONUP = 0x0202;
        public const int WM_MOUSEMOVE = 0x0200;
        public const int WM_MOUSEWHEEL = 0x020A;
        public const uint SWP_NOSIZE = 0x0001;
        public const uint SWP_NOZORDER = 0x0004;
        public const uint SWP_NOACTIVATE = 0x0010;
        public const int SW_HIDE = 0;
        public const int SW_RESTORE = 9;
        public const int SW_MINIMIZE = 6;
        public const int WM_BROADCAST = 0xFFFF; // HWND_BROADCAST

        private static readonly NumberFormatInfoFake Inv = new NumberFormatInfoFake();

        // Format invariant, sans dependance CultureInfo (C# 5).
        private sealed class NumberFormatInfoFake { }

        private static string F3(double v) { return v.ToString("0.###", System.Globalization.CultureInfo.InvariantCulture); }

        public static void MakeDpiAware()
        {
            try { SetProcessDPIAware(); } catch (Exception) { }
        }

        public static string[] ListTopWindows()
        {
            List<string> list = new List<string>();
            EnumWindows(delegate(IntPtr h, IntPtr l)
            {
                StringBuilder t = new StringBuilder(512);
                GetWindowText(h, t, 512);
                StringBuilder c = new StringBuilder(256);
                GetClassName(h, c, 256);
                uint pid;
                GetWindowThreadProcessId(h, out pid);
                RECT r;
                GetWindowRect(h, out r);
                list.Add(string.Format(System.Globalization.CultureInfo.InvariantCulture,
                    "{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}|{9}",
                    h.ToInt64(), pid, c.ToString(), t.ToString(),
                    r.Left, r.Top, r.Right, r.Bottom,
                    IsWindowVisible(h) ? 1 : 0, IsIconic(h) ? 1 : 0));
                return true;
            }, IntPtr.Zero);
            return list.ToArray();
        }

        public static IntPtr FindTopWindow(uint pid, string title, string classPrefix)
        {
            IntPtr found = IntPtr.Zero;
            EnumWindows(delegate(IntPtr h, IntPtr l)
            {
                uint p;
                GetWindowThreadProcessId(h, out p);
                if (p != pid) return true;
                StringBuilder c = new StringBuilder(256);
                GetClassName(h, c, 256);
                if (c.ToString().StartsWith(classPrefix))
                {
                    StringBuilder t = new StringBuilder(512);
                    GetWindowText(h, t, 512);
                    if (title.Length == 0 || t.ToString() == title)
                    {
                        found = h;
                        return false;
                    }
                }
                return true;
            }, IntPtr.Zero);
            return found;
        }

        public static string GetTitleOf(IntPtr h) { StringBuilder t = new StringBuilder(512); GetWindowText(h, t, 512); return t.ToString(); }

        public static bool TryGetRect(IntPtr h, out RECT r) { return GetWindowRect(h, out r); }

        public static string RectString(IntPtr h)
        {
            RECT r;
            if (!GetWindowRect(h, out r)) return "0,0,0,0";
            return string.Format(System.Globalization.CultureInfo.InvariantCulture, "{0},{1},{2},{3}", r.Left, r.Top, r.Right, r.Bottom);
        }

        public static string ForegroundString()
        {
            IntPtr h = GetForegroundWindow();
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            return h.ToInt64().ToString(System.Globalization.CultureInfo.InvariantCulture) + "|" + pid.ToString(System.Globalization.CultureInfo.InvariantCulture) + "|" + GetTitleOf(h);
        }

        public static int DpiOf(IntPtr h)
        {
            try { return (int)GetDpiForWindow(h); } catch (Exception) { return 96; }
        }

        // Essaie plusieurs strategies pour mettre hwnd au premier plan. Retourne "method|latency_ms|ok".
        public static string ForceForeground(IntPtr hwnd)
        {
            Stopwatch sw = Stopwatch.StartNew();
            string method = "none";
            ShowWindow(hwnd, SW_RESTORE);
            System.Threading.Thread.Sleep(20);
            if (GetForegroundWindow() == hwnd) { method = "already"; return method + "|" + F3(sw.Elapsed.TotalMilliseconds) + "|1"; }

            method = "setforeground";
            SetForegroundWindow(hwnd);
            System.Threading.Thread.Sleep(30);
            if (GetForegroundWindow() == hwnd) return method + "|" + F3(sw.Elapsed.TotalMilliseconds) + "|1";

            method = "attachinput";
            uint fgPid;
            IntPtr fg = GetForegroundWindow();
            uint fgThread = GetWindowThreadProcessId(fg, out fgPid);
            uint thisThread = GetCurrentThreadId();
            bool attached = false;
            try
            {
                attached = AttachThreadInput(thisThread, fgThread, true);
                BringWindowToTop(hwnd);
                SetForegroundWindow(hwnd);
                System.Threading.Thread.Sleep(40);
            }
            finally
            {
                if (attached) AttachThreadInput(thisThread, fgThread, false);
            }
            if (GetForegroundWindow() == hwnd) return method + "|" + F3(sw.Elapsed.TotalMilliseconds) + "|1";

            method = "switchtothiswindow";
            SwitchToThisWindow(hwnd, true);
            System.Threading.Thread.Sleep(50);
            if (GetForegroundWindow() == hwnd) return method + "|" + F3(sw.Elapsed.TotalMilliseconds) + "|1";

            method = "attachinput_second_try";
            fg = GetForegroundWindow();
            fgThread = GetWindowThreadProcessId(fg, out fgPid);
            thisThread = GetCurrentThreadId();
            attached = false;
            try
            {
                attached = AttachThreadInput(thisThread, fgThread, true);
                ShowWindow(hwnd, SW_RESTORE);
                SetForegroundWindow(hwnd);
                System.Threading.Thread.Sleep(80);
            }
            finally
            {
                if (attached) AttachThreadInput(thisThread, fgThread, false);
            }
            return method + "|" + F3(sw.Elapsed.TotalMilliseconds) + "|" + (GetForegroundWindow() == hwnd ? "1" : "0");
        }

        // Attend l'apparition d'une fenetre visible du PID avec la classe prefixee et le titre.
        // Retourne "found|latency_ms|hwnd|rect" ou "timeout|latency_ms|0|0,0,0,0".
        public static string WaitOverlayVisible(uint pid, string title, string classPrefix, int timeoutMs)
        {
            Stopwatch sw = Stopwatch.StartNew();
            IntPtr found = IntPtr.Zero;
            while (sw.Elapsed.TotalMilliseconds < timeoutMs)
            {
                found = FindTopWindow(pid, title, classPrefix);
                if (found != IntPtr.Zero && IsWindowVisible(found)) break;
                found = IntPtr.Zero;
                System.Threading.Thread.Sleep(1);
            }
            if (found == IntPtr.Zero) return "timeout|" + F3(sw.Elapsed.TotalMilliseconds) + "|0|0,0,0,0";
            return "found|" + F3(sw.Elapsed.TotalMilliseconds) + "|" + found.ToInt64().ToString(System.Globalization.CultureInfo.InvariantCulture) + "|" + RectString(found);
        }

        // Clic gauche synthetique (down, pause, up) ; retourne la duree totale en ms.
        public static string ClickLeft(IntPtr hwnd, int x, int y, int holdMs)
        {
            IntPtr lp = (IntPtr)((y << 16) | (x & 0xFFFF));
            Stopwatch sw = Stopwatch.StartNew();
            SendMessage(hwnd, WM_MOUSEMOVE, IntPtr.Zero, lp);
            SendMessage(hwnd, WM_LBUTTONDOWN, (IntPtr)1, lp);
            if (holdMs > 0) System.Threading.Thread.Sleep(holdMs);
            SendMessage(hwnd, WM_LBUTTONUP, IntPtr.Zero, lp);
            sw.Stop();
            return F3(sw.Elapsed.TotalMilliseconds);
        }

        // Envoie WM_MOUSEMOVE ; retourne la duree en ms.
        public static string MouseMoveTo(IntPtr hwnd, int x, int y)
        {
            IntPtr lp = (IntPtr)((y << 16) | (x & 0xFFFF));
            Stopwatch sw = Stopwatch.StartNew();
            SendMessage(hwnd, WM_MOUSEMOVE, IntPtr.Zero, lp);
            sw.Stop();
            return F3(sw.Elapsed.TotalMilliseconds);
        }

        // Envoie WM_MOUSEWHEEL au point ecran (x,y) ; delta en unites de 120.
        public static string MouseWheel(IntPtr hwnd, int screenX, int screenY, int delta)
        {
            IntPtr wParam = (IntPtr)((delta << 16) & unchecked((int)0xFFFF0000));
            IntPtr lParam = (IntPtr)((screenY << 16) | (screenX & 0xFFFF));
            Stopwatch sw = Stopwatch.StartNew();
            SendMessage(hwnd, WM_MOUSEWHEEL, wParam, lParam);
            sw.Stop();
            return F3(sw.Elapsed.TotalMilliseconds);
        }

        // Deplace la fenetre riot de (dx,dy) puis mesure la latence jusqu'au premier changement
        // de position de l'overlay. Retourne "latency_ms|beforeRect|afterRect|riotRect".
        public static string MoveRiotStep(IntPtr riot, IntPtr overlay, int dx, int dy, int timeoutMs)
        {
            RECT overlayBefore;
            RECT riotBefore;
            GetWindowRect(overlay, out overlayBefore);
            GetWindowRect(riot, out riotBefore);
            Stopwatch sw = Stopwatch.StartNew();
            SetWindowPos(riot, IntPtr.Zero, riotBefore.Left + dx, riotBefore.Top + dy, 0, 0,
                SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
            RECT overlayAfter = overlayBefore;
            bool changed = false;
            while (sw.Elapsed.TotalMilliseconds < timeoutMs)
            {
                RECT now;
                if (GetWindowRect(overlay, out now))
                {
                    if (now.Left != overlayBefore.Left || now.Top != overlayBefore.Top)
                    {
                        overlayAfter = now;
                        changed = true;
                        break;
                    }
                }
                // Pas de Sleep : on veut la meilleure resolution possible.
            }
            sw.Stop();
            RECT riotAfter;
            GetWindowRect(riot, out riotAfter);
            string res = F3(sw.Elapsed.TotalMilliseconds) + "|" + RectToString(overlayBefore) + "|" + RectToString(overlayAfter) + "|" + RectToString(riotAfter) + "|" + (changed ? "1" : "0");
            return res;
        }

        private static string RectToString(RECT r)
        {
            return string.Format(System.Globalization.CultureInfo.InvariantCulture, "{0},{1},{2},{3}", r.Left, r.Top, r.Right, r.Bottom);
        }

        // Deplace la fenetre riot a une position absolue (sans activation).
        public static void MoveWindowTo(IntPtr hwnd, int x, int y)
        {
            SetWindowPos(hwnd, IntPtr.Zero, x, y, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
        }

        public static void MinimizeWindow(IntPtr hwnd)
        {
            ShowWindow(hwnd, SW_MINIMIZE);
        }

        public static void HideWindow(IntPtr hwnd)
        {
            ShowWindow(hwnd, SW_HIDE);
        }

        public static bool BroadcastQuit()
        {
            uint msg = RegisterWindowMessage("RiotSwitch.Quit");
            return PostMessage(new IntPtr(WM_BROADCAST), msg, IntPtr.Zero, IntPtr.Zero);
        }
    }
}
'@

Add-Type -TypeDefinition $nativeSource -Language CSharp

function Write-Result {
    param([object]$Object)
    $json = $Object | ConvertTo-Json -Compress -Depth 8
    Write-Output $json
}

function Fail {
    param([string]$Message, [object]$Extra = $null)
    $o = [ordered]@{
        ok      = $false
        action  = $Action
        error   = $Message
        at_utc  = (Get-Date).ToUniversalTime().ToString('o')
    }
    if ($null -ne $Extra) {
        foreach ($k in $Extra.Keys) { $o[$k] = $Extra[$k] }
    }
    Write-Result $o
    exit 2
}

function Get-InvariantDouble {
    param([string]$Text)
    return [double]::Parse($Text, $Invariant)
}

function Get-ParsedWindows {
    $records = [RiotSwitchPerf.RunCtl.RunCtl]::ListTopWindows()
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($rec in $records) {
        $parts = $rec -split '\|'
        if ($parts.Count -lt 10) { continue }
        # Le titre peut contenir '|' : les six derniers champs sont numériques et
        # forment la géométrie/flags, tout ce qui reste entre class et eux est le titre.
        $titleEnd = $parts.Count - 7
        $tail = $parts.Count - 6
        $list.Add([pscustomobject]@{
            hwnd    = [int64]$parts[0]
            pid     = [uint32]$parts[1]
            class   = [string]$parts[2]
            title   = (@($parts[3..$titleEnd]) -join '|')
            left    = [int]$parts[$tail]
            top     = [int]$parts[$tail + 1]
            right   = [int]$parts[$tail + 2]
            bottom  = [int]$parts[$tail + 3]
            visible = ([string]$parts[$tail + 4] -eq '1')
            iconic  = ([string]$parts[$tail + 5] -eq '1')
        })
    }
    return $list
}

function Get-RiotSwitchProcess {
    $procs = @(Get-Process -Name 'RiotSwitch' -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { Fail 'Aucun processus RiotSwitch en cours.' }
    if ($procs.Count -gt 1) {
        Fail ('Plusieurs processus RiotSwitch : ' + (($procs | ForEach-Object { $_.Id }) -join ','))
    }
    return $procs[0]
}

function Get-OverlayWindow {
    param([int]$RiotSwitchPid, [bool]$RequireVisible = $true)
    $wins = Get-ParsedWindows
    $candidates = @($wins | Where-Object {
        $_.pid -eq $RiotSwitchPid -and $_.class -like 'WindowsForms10*' -and $_.title -eq 'RiotSwitch'
    })
    if ($candidates.Count -eq 0) { return $null }
    if ($RequireVisible) {
        $visible = @($candidates | Where-Object { $_.visible })
        if ($visible.Count -gt 0) { return $visible[0] }
        return $null
    }
    return $candidates[0]
}

function Get-RiotWindow {
    $wins = Get-ParsedWindows
    $candidates = @($wins | Where-Object { $_.title -eq 'Riot Client' -and $_.class -like 'Chrome_WidgetWin*' })
    if ($candidates.Count -eq 0) {
        $candidates = @($wins | Where-Object { $_.title -eq 'Riot Client' })
    }
    if ($candidates.Count -eq 0) { return $null }
    return $candidates[0]
}

function Get-SettingsInfo {
    $path = Join-Path $env:LOCALAPPDATA 'RiotSwitch\settings.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $s = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        return [pscustomobject]@{
            path                  = $path
            overlayOffsetRightDip = [double]$s.overlayOffsetRightDip
            overlayOffsetTopDip   = [double]$s.overlayOffsetTopDip
            overlayPinned         = [bool]$s.overlayPinned
            backgroundMode        = $s.backgroundMode
            autoCheckUpdates      = $s.autoCheckUpdates
        }
    } catch { return $null }
}

function Get-Scale {
    param([object]$WindowRecord)
    if ($null -eq $WindowRecord) { return 1.0 }
    $dpi = [RiotSwitchPerf.RunCtl.RunCtl]::DpiOf([IntPtr]$WindowRecord.hwnd)
    return [math]::Round($dpi / 96.0, 3)
}

function Get-OverlayState {
    param([object]$Win, [double]$Scale)
    if ($null -eq $Win) { return $null }
    $w = $Win.right - $Win.left
    $h = $Win.bottom - $Win.top
    $expanded = ($w -gt [int][math]::Round(100 * $Scale))
    return [pscustomobject]@{ expanded = $expanded; width = $w; height = $h }
}

function Wait-OverlayWidth {
    param([int64]$Hwnd, [bool]$ExpectExpanded, [double]$Scale, [int]$TimeoutMs)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $target = $null
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        $rec = [RiotSwitchPerf.RunCtl.RunCtl]::RectString([IntPtr]$Hwnd)
        $p = $rec -split ','
        $w = [int]$p[2] - [int]$p[0]
        $exp = ($w -gt [int][math]::Round(100 * $Scale))
        if ($exp -eq $ExpectExpanded) {
            $target = [pscustomobject]@{ rect = $rec; width = $w; height = ([int]$p[3] - [int]$p[1]) }
            break
        }
        Start-Sleep -Milliseconds 1
    }
    $sw.Stop()
    if ($null -eq $target) { return $null }
    return [pscustomobject]@{ rect = $target.rect; width = $target.width; height = $target.height; latency_ms = [math]::Round($sw.Elapsed.TotalMilliseconds, 3) }
}

[RiotSwitchPerf.RunCtl.RunCtl]::MakeDpiAware()

try {
    switch ($Action) {
        'discover' {
            $rs = Get-RiotSwitchProcess
            $overlay = Get-OverlayWindow -RiotSwitchPid $rs.Id -RequireVisible $false
            $overlayVisible = Get-OverlayWindow -RiotSwitchPid $rs.Id -RequireVisible $true
            $riot = Get-RiotWindow
            $settings = Get-SettingsInfo
            $scale = Get-Scale -WindowRecord $overlay
            if ($null -eq $overlay) { $scale = Get-Scale -WindowRecord $riot }
            $fgRaw = [RiotSwitchPerf.RunCtl.RunCtl]::ForegroundString() -split '\|'
            $overlayState = $null
            $overlayRect = $null
            if ($null -ne $overlay) {
                $overlayState = Get-OverlayState -Win $overlay -Scale $scale
                $overlayRect = "$($overlay.left),$($overlay.top),$($overlay.right),$($overlay.bottom)"
            }
            Write-Result ([ordered]@{
                ok          = $true
                action      = 'discover'
                at_utc      = (Get-Date).ToUniversalTime().ToString('o')
                riotswitch  = [ordered]@{
                    pid         = $rs.Id
                    cpu_total_s = [math]::Round($rs.CPU, 3)
                    ws_bytes    = $rs.WorkingSet64
                    commit_bytes = $rs.PrivateMemorySize64
                    handles     = $rs.HandleCount
                    threads     = $rs.Threads.Count
                    start_local = $rs.StartTime.ToString('o')
                }
                overlay     = [ordered]@{
                    present         = ($null -ne $overlay)
                    visible         = ($null -ne $overlayVisible)
                    hwnd            = $(if ($null -ne $overlay) { $overlay.hwnd } else { 0 })
                    rect            = $overlayRect
                    state           = $(if ($null -ne $overlayState -and $overlayState.expanded) { 'expanded' } elseif ($null -ne $overlayState) { 'collapsed' } else { 'absent' })
                    width_px        = $(if ($null -ne $overlayState) { $overlayState.width } else { 0 })
                    height_px       = $(if ($null -ne $overlayState) { $overlayState.height } else { 0 })
                }
                riot_client = [ordered]@{
                    present = ($null -ne $riot)
                    hwnd    = $(if ($null -ne $riot) { $riot.hwnd } else { 0 })
                    rect    = $(if ($null -ne $riot) { "$($riot.left),$($riot.top),$($riot.right),$($riot.bottom)" } else { $null })
                    visible = $(if ($null -ne $riot) { $riot.visible } else { $false })
                    iconic  = $(if ($null -ne $riot) { $riot.iconic } else { $false })
                }
                foreground  = [ordered]@{ hwnd = [int64]$fgRaw[0]; pid = [uint32]$fgRaw[1]; title = $fgRaw[2] }
                dpi_scale   = $scale
                settings    = $(if ($null -ne $settings) { [ordered]@{ overlayOffsetRightDip = $settings.overlayOffsetRightDip; overlayOffsetTopDip = $settings.overlayOffsetTopDip; overlayPinned = $settings.overlayPinned; backgroundMode = $settings.backgroundMode; autoCheckUpdates = $settings.autoCheckUpdates } } else { $null })
            })
        }

        'state' {
            $rs = Get-RiotSwitchProcess
            $overlay = Get-OverlayWindow -RiotSwitchPid $rs.Id -RequireVisible $false
            $overlayVisible = Get-OverlayWindow -RiotSwitchPid $rs.Id -RequireVisible $true
            $scale = Get-Scale -WindowRecord $overlay
            $st = Get-OverlayState -Win $overlay -Scale $scale
            $fgRaw = [RiotSwitchPerf.RunCtl.RunCtl]::ForegroundString() -split '\|'
            Write-Result ([ordered]@{
                ok         = $true
                action     = 'state'
                at_utc     = (Get-Date).ToUniversalTime().ToString('o')
                riotswitch_pid = $rs.Id
                overlay_present = ($null -ne $overlay)
                overlay_visible = ($null -ne $overlayVisible)
                overlay_hwnd    = $(if ($null -ne $overlay) { $overlay.hwnd } else { 0 })
                overlay_rect    = $(if ($null -ne $overlay) { "$($overlay.left),$($overlay.top),$($overlay.right),$($overlay.bottom)" } else { $null })
                overlay_state   = $(if ($null -ne $st -and $st.expanded) { 'expanded' } elseif ($null -ne $st) { 'collapsed' } else { 'absent' })
                foreground      = [ordered]@{ hwnd = [int64]$fgRaw[0]; pid = [uint32]$fgRaw[1]; title = $fgRaw[2] }
            })
        }

        'foreground-riot' {
            $riot = Get-RiotWindow
            if ($null -eq $riot) { Fail 'Fenetre Riot Client introuvable.' }
            $res = [RiotSwitchPerf.RunCtl.RunCtl]::ForceForeground([IntPtr]$riot.hwnd) -split '\|'
            $fgRaw = [RiotSwitchPerf.RunCtl.RunCtl]::ForegroundString() -split '\|'
            $ok = ($res[2] -eq '1')
            Write-Result ([ordered]@{
                ok          = $ok
                action      = 'foreground-riot'
                at_utc      = (Get-Date).ToUniversalTime().ToString('o')
                riot_hwnd   = $riot.hwnd
                riot_rect   = "$($riot.left),$($riot.top),$($riot.right),$($riot.bottom)"
                method      = $res[0]
                latency_ms  = [double]$res[1]
                foreground  = [ordered]@{ hwnd = [int64]$fgRaw[0]; pid = [uint32]$fgRaw[1]; title = $fgRaw[2] }
                error       = $(if ($ok) { $null } else { 'La fenetre Riot Client ne devient pas premier plan.' })
            })
            if (-not $ok) { exit 2 }
        }

        'foreground-riot-wait' {
            $riot = Get-RiotWindow
            if ($null -eq $riot) { Fail 'Fenetre Riot Client introuvable.' }
            $rs = Get-RiotSwitchProcess
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $res = [RiotSwitchPerf.RunCtl.RunCtl]::ForceForeground([IntPtr]$riot.hwnd) -split '\|'
            $fgRaw = [RiotSwitchPerf.RunCtl.RunCtl]::ForegroundString() -split '\|'
            $fgOk = ($res[2] -eq '1')
            $visible = $false
            $hwnd = 0
            $rect = $null
            while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
                $ov = Get-OverlayWindow -RiotSwitchPid $rs.Id -RequireVisible $true
                if ($null -ne $ov) {
                    $visible = $true
                    $hwnd = $ov.hwnd
                    $rect = "$($ov.left),$($ov.top),$($ov.right),$($ov.bottom)"
                    break
                }
                Start-Sleep -Milliseconds 1
            }
            $sw.Stop()
            $scale = Get-Scale -WindowRecord (Get-OverlayWindow -RiotSwitchPid $rs.Id -RequireVisible $false)
            $st = Get-OverlayState -Win (Get-OverlayWindow -RiotSwitchPid $rs.Id -RequireVisible $false) -Scale $scale
            Write-Result ([ordered]@{
                ok                = ($fgOk -and $visible)
                action            = 'foreground-riot-wait'
                at_utc            = (Get-Date).ToUniversalTime().ToString('o')
                riot_hwnd         = $riot.hwnd
                riot_rect         = "$($riot.left),$($riot.top),$($riot.right),$($riot.bottom)"
                fg_method         = $res[0]
                fg_latency_ms     = [double]$res[1]
                overlay_visible   = $visible
                overlay_total_ms  = [math]::Round($sw.Elapsed.TotalMilliseconds, 3)
                overlay_hwnd      = $hwnd
                overlay_rect      = $rect
                overlay_state     = $(if ($null -ne $st -and $st.expanded) { 'expanded' } elseif ($null -ne $st) { 'collapsed' } else { 'absent' })
                foreground        = [ordered]@{ hwnd = [int64]$fgRaw[0]; pid = [uint32]$fgRaw[1]; title = $fgRaw[2] }
                error             = $(if ($fgOk -and $visible) { $null } else { 'Echec foreground ou overlay non visible.' })
            })
            if (-not ($fgOk -and $visible)) { exit 2 }
        }

        'minimize-riot' {
            $riot = Get-RiotWindow
            if ($null -eq $riot) { Fail 'Fenetre Riot Client introuvable.' }
            $rs = Get-RiotSwitchProcess
            $ovBefore = Get-OverlayWindow -RiotSwitchPid $rs.Id -RequireVisible $true
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            [RiotSwitchPerf.RunCtl.RunCtl]::MinimizeWindow([IntPtr]$riot.hwnd)
            $gone = $false
            $lastSeen = $null
            while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
                # L'overlay masque sa fenetre au lieu de la detruire : l'absence
                # fonctionnelle = plus aucune fenetre VISIBLE.
                $ov = Get-OverlayWindow -RiotSwitchPid $rs.Id -RequireVisible $true
                if ($null -eq $ov) { $gone = $true; break }
                $lastSeen = $ov
                Start-Sleep -Milliseconds 2
            }
            $sw.Stop()
            $presentAfter = ($null -ne (Get-OverlayWindow -RiotSwitchPid $rs.Id -RequireVisible $false))
            Write-Result ([ordered]@{
                ok                   = $gone
                action               = 'minimize-riot'
                at_utc               = (Get-Date).ToUniversalTime().ToString('o')
                riot_hwnd            = $riot.hwnd
                riot_rect_before     = "$($riot.left),$($riot.top),$($riot.right),$($riot.bottom)"
                overlay_before_rect  = $(if ($null -ne $ovBefore) { "$($ovBefore.left),$($ovBefore.top),$($ovBefore.right),$($ovBefore.bottom)" } else { $null })
                overlay_gone_after_ms = [math]::Round($sw.Elapsed.TotalMilliseconds, 3)
                overlay_absent       = $gone
                overlay_window_present_after = $presentAfter
                last_overlay_rect    = $(if ($null -ne $lastSeen) { "$($lastSeen.left),$($lastSeen.top),$($lastSeen.right),$($lastSeen.bottom)" } else { $null })
                error                = $(if ($gone) { $null } else { "Overlay visible toujours present apres $TimeoutMs ms." })
            })
            if (-not $gone) { exit 2 }
        }

        'minimize-riot-window' {
            # Minimise la fenetre Riot SANS exiger un veilleur RiotSwitch en cours.
            $riot = Get-RiotWindow
            if ($null -eq $riot) { Fail 'Fenetre Riot Client introuvable.' }
            $iconicBefore = [bool]$riot.iconic
            $rectBefore = "$($riot.left),$($riot.top),$($riot.right),$($riot.bottom)"
            [RiotSwitchPerf.RunCtl.RunCtl]::MinimizeWindow([IntPtr]$riot.hwnd)
            Start-Sleep -Milliseconds 250
            $after = Get-RiotWindow
            $iconicAfter = $false
            $rectAfter = $null
            if ($null -ne $after) {
                $iconicAfter = [bool]$after.iconic
                $rectAfter = "$($after.left),$($after.top),$($after.right),$($after.bottom)"
            }
            Write-Result ([ordered]@{
                ok                 = $iconicAfter
                action             = 'minimize-riot-window'
                at_utc             = (Get-Date).ToUniversalTime().ToString('o')
                riot_hwnd          = $riot.hwnd
                iconic_before      = $iconicBefore
                iconic_after       = $iconicAfter
                riot_rect_before   = $rectBefore
                riot_rect_after    = $rectAfter
                error              = $(if ($iconicAfter) { $null } else { 'La fenetre Riot Client ne devient pas iconique.' })
            })
            if (-not $iconicAfter) { exit 2 }
        }

        'hide-riot-window' {
            # Masque completement la fenetre Riot (SW_HIDE) SANS exiger un veilleur.
            # Contrairement a la minimisation, le tracker ne declenche pas sa restauration
            # unique de demarrage : utile pour un demarrage a froid sans overlay.
            $riot = Get-RiotWindow
            if ($null -eq $riot) { Fail 'Fenetre Riot Client introuvable.' }
            $visibleBefore = [bool]$riot.visible
            $rectBefore = "$($riot.left),$($riot.top),$($riot.right),$($riot.bottom)"
            [RiotSwitchPerf.RunCtl.RunCtl]::HideWindow([IntPtr]$riot.hwnd)
            Start-Sleep -Milliseconds 250
            $after = Get-RiotWindow
            $visibleAfter = $true
            if ($null -ne $after) { $visibleAfter = [bool]$after.visible }
            Write-Result ([ordered]@{
                ok                = (-not $visibleAfter)
                action            = 'hide-riot-window'
                at_utc            = (Get-Date).ToUniversalTime().ToString('o')
                riot_hwnd         = $riot.hwnd
                visible_before    = $visibleBefore
                visible_after     = $visibleAfter
                riot_rect_before  = $rectBefore
                error             = $(if (-not $visibleAfter) { $null } else { 'La fenetre Riot Client reste visible.' })
            })
            if ($visibleAfter) { exit 2 }
        }

        'wait-overlay-absent' {
            $rs = Get-RiotSwitchProcess
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $lastSeen = $null
            $gone = $false
            while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
                # Absence fonctionnelle = plus aucune fenetre overlay visible (elle
                # peut rester presente mais cachee, pour etre reutilisee au retour).
                $ov = Get-OverlayWindow -RiotSwitchPid $rs.Id -RequireVisible $true
                if ($null -eq $ov) { $gone = $true; break }
                $lastSeen = $ov
                Start-Sleep -Milliseconds 2
            }
            $sw.Stop()
            Write-Result ([ordered]@{
                ok                 = $gone
                action             = 'wait-overlay-absent'
                at_utc             = (Get-Date).ToUniversalTime().ToString('o')
                absent_after_ms    = [math]::Round($sw.Elapsed.TotalMilliseconds, 3)
                overlay_window_present_after = ($null -ne (Get-OverlayWindow -RiotSwitchPid $rs.Id -RequireVisible $false))
                last_overlay_rect  = $(if ($null -ne $lastSeen) { "$($lastSeen.left),$($lastSeen.top),$($lastSeen.right),$($lastSeen.bottom)" } else { $null })
                error              = $(if ($gone) { $null } else { "Overlay visible toujours present apres $TimeoutMs ms." })
            })
            if (-not $gone) { exit 2 }
        }

        'cycles' {
            $rs = Get-RiotSwitchProcess
            $overlay = Get-OverlayWindow -RiotSwitchPid $rs.Id -RequireVisible $true
            if ($null -eq $overlay) { Fail 'Overlay visible introuvable.' }
            $scale = Get-Scale -WindowRecord $overlay
            $st = Get-OverlayState -Win $overlay -Scale $scale
            if ($st.expanded) {
                $cx0 = [int][math]::Round(349 * $scale)
                $cy0 = [int][math]::Round(31 * $scale)
                [void][RiotSwitchPerf.RunCtl.RunCtl]::ClickLeft([IntPtr]$overlay.hwnd, $cx0, $cy0, 60)
                $wc = Wait-OverlayWidth -Hwnd $overlay.hwnd -ExpectExpanded $false -Scale $scale -TimeoutMs $TimeoutMs
                if ($null -eq $wc) { Fail 'Etat initial : le panneau ne se replie pas.' }
            }
            $cx = [int][math]::Round(349 * $scale)
            $cy = [int][math]::Round(31 * $scale)
            $list = New-Object System.Collections.Generic.List[object]
            $swAll = [System.Diagnostics.Stopwatch]::StartNew()
            for ($i = 1; $i -le $Count; $i++) {
                $swC = [System.Diagnostics.Stopwatch]::StartNew()
                $clickE = [RiotSwitchPerf.RunCtl.RunCtl]::ClickLeft([IntPtr]$overlay.hwnd, 20, 20, 60)
                $we = Wait-OverlayWidth -Hwnd $overlay.hwnd -ExpectExpanded $true -Scale $scale -TimeoutMs $TimeoutMs
                if ($null -eq $we) { Fail ("Cycle $i : le panneau ne se deplie pas.") }
                $tExp = $swC.Elapsed.TotalMilliseconds
                $swC.Restart()
                $clickC = [RiotSwitchPerf.RunCtl.RunCtl]::ClickLeft([IntPtr]$overlay.hwnd, $cx, $cy, 60)
                $wc2 = Wait-OverlayWidth -Hwnd $overlay.hwnd -ExpectExpanded $false -Scale $scale -TimeoutMs $TimeoutMs
                if ($null -eq $wc2) { Fail ("Cycle $i : le panneau ne se replie pas.") }
                $tCol = $swC.Elapsed.TotalMilliseconds
                $swC.Stop()
                $list.Add([ordered]@{
                    cycle           = $i
                    expand_ms       = [math]::Round($tExp, 3)
                    collapse_ms     = [math]::Round($tCol, 3)
                    expand_rect_ms  = [double]$we.latency_ms
                    collapse_rect_ms = [double]$wc2.latency_ms
                    expand_click_ms = [double]$clickE
                    collapse_click_ms = [double]$clickC
                    expanded_rect   = $we.rect
                    collapsed_rect  = $wc2.rect
                })
            }
            $swAll.Stop()
            $exp = @($list | ForEach-Object { $_.expand_ms })
            $col = @($list | ForEach-Object { $_.collapse_ms })
            Write-Result ([ordered]@{
                ok            = $true
                action        = 'cycles'
                at_utc        = (Get-Date).ToUniversalTime().ToString('o')
                count         = $Count
                total_ms      = [math]::Round($swAll.Elapsed.TotalMilliseconds, 3)
                start_state   = 'collapsed'
                end_state     = 'collapsed'
                expand_ms     = [ordered]@{ min = [math]::Round((($exp | Measure-Object -Minimum).Minimum), 3); mean = [math]::Round((($exp | Measure-Object -Average).Average), 3); max = [math]::Round((($exp | Measure-Object -Maximum).Maximum), 3) }
                collapse_ms   = [ordered]@{ min = [math]::Round((($col | Measure-Object -Minimum).Minimum), 3); mean = [math]::Round((($col | Measure-Object -Average).Average), 3); max = [math]::Round((($col | Measure-Object -Maximum).Maximum), 3) }
                cycles        = $list
            })
        }

        'wait-overlay' {
            $rs = Get-RiotSwitchProcess
            $res = [RiotSwitchPerf.RunCtl.RunCtl]::WaitOverlayVisible([uint32]$rs.Id, 'RiotSwitch', 'WindowsForms10', $TimeoutMs) -split '\|'
            $found = ($res[0] -eq 'found')
            Write-Result ([ordered]@{
                ok          = $found
                action      = 'wait-overlay'
                at_utc      = (Get-Date).ToUniversalTime().ToString('o')
                latency_ms  = [double]$res[1]
                overlay_hwnd = [int64]$res[2]
                overlay_rect = $res[3]
                error       = $(if ($found) { $null } else { "Overlay non visible apres $TimeoutMs ms." })
            })
            if (-not $found) { exit 2 }
        }

        'expand' {
            $rs = Get-RiotSwitchProcess
            $overlay = Get-OverlayWindow -RiotSwitchPid $rs.Id -RequireVisible $true
            if ($null -eq $overlay) { Fail 'Overlay visible introuvable.' }
            $scale = Get-Scale -WindowRecord $overlay
            $st = Get-OverlayState -Win $overlay -Scale $scale
            if ($st.expanded) {
                Write-Result ([ordered]@{ ok = $true; action = 'expand'; already = $true; overlay_rect = "$($overlay.left),$($overlay.top),$($overlay.right),$($overlay.bottom)" })
                break
            }
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $clickMs = [RiotSwitchPerf.RunCtl.RunCtl]::ClickLeft([IntPtr]$overlay.hwnd, 20, 20, 60)
            $wait = Wait-OverlayWidth -Hwnd $overlay.hwnd -ExpectExpanded $true -Scale $scale -TimeoutMs $TimeoutMs
            $sw.Stop()
            if ($null -eq $wait) { Fail 'Le panneau ne s''est pas deplie apres le clic synthetique.' }
            Write-Result ([ordered]@{
                ok             = $true
                action         = 'expand'
                at_utc         = (Get-Date).ToUniversalTime().ToString('o')
                click_ms       = [double]$clickMs
                latency_ms     = $wait.latency_ms
                total_ms       = [math]::Round($sw.Elapsed.TotalMilliseconds, 3)
                overlay_rect   = $wait.rect
                overlay_width  = $wait.width
                overlay_height = $wait.height
            })
        }

        'collapse' {
            $rs = Get-RiotSwitchProcess
            $overlay = Get-OverlayWindow -RiotSwitchPid $rs.Id -RequireVisible $true
            if ($null -eq $overlay) { Fail 'Overlay visible introuvable.' }
            $scale = Get-Scale -WindowRecord $overlay
            $st = Get-OverlayState -Win $overlay -Scale $scale
            if (-not $st.expanded) {
                Write-Result ([ordered]@{ ok = $true; action = 'collapse'; already = $true; overlay_rect = "$($overlay.left),$($overlay.top),$($overlay.right),$($overlay.bottom)" })
                break
            }
            $cx = [int][math]::Round(349 * $scale)
            $cy = [int][math]::Round(31 * $scale)
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $clickMs = [RiotSwitchPerf.RunCtl.RunCtl]::ClickLeft([IntPtr]$overlay.hwnd, $cx, $cy, 60)
            $wait = Wait-OverlayWidth -Hwnd $overlay.hwnd -ExpectExpanded $false -Scale $scale -TimeoutMs $TimeoutMs
            $sw.Stop()
            if ($null -eq $wait) { Fail 'Le panneau ne s''est pas replie apres le clic synthetique.' }
            Write-Result ([ordered]@{
                ok             = $true
                action         = 'collapse'
                at_utc         = (Get-Date).ToUniversalTime().ToString('o')
                click_x        = $cx
                click_y        = $cy
                click_ms       = [double]$clickMs
                latency_ms     = $wait.latency_ms
                total_ms       = [math]::Round($sw.Elapsed.TotalMilliseconds, 3)
                overlay_rect   = $wait.rect
                overlay_width  = $wait.width
                overlay_height = $wait.height
            })
        }

        'hover' {
            $rs = Get-RiotSwitchProcess
            $overlay = Get-OverlayWindow -RiotSwitchPid $rs.Id -RequireVisible $true
            if ($null -eq $overlay) { Fail 'Overlay visible introuvable.' }
            $scale = Get-Scale -WindowRecord $overlay
            $points = @(
                @(120, 120), @(120, 170), @(120, 220), @(120, 270),
                @(300, 120), @(300, 170), @(300, 220), @(60, 80), @(200, 60)
            )
            $durations = New-Object System.Collections.Generic.List[double]
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            for ($i = 0; $i -lt $Count; $i++) {
                $pt = $points[$i % $points.Count]
                $x = [int][math]::Round($pt[0] * $scale)
                $y = [int][math]::Round($pt[1] * $scale)
                $ms = [RiotSwitchPerf.RunCtl.RunCtl]::MouseMoveTo([IntPtr]$overlay.hwnd, $x, $y)
                $durations.Add([double]$ms)
                if ($IntervalMs -gt 0) { Start-Sleep -Milliseconds $IntervalMs }
            }
            $sw.Stop()
            # réinitialise l'état de survol
            [void][RiotSwitchPerf.RunCtl.RunCtl]::MouseMoveTo([IntPtr]$overlay.hwnd, 2, 2)
            Write-Result ([ordered]@{
                ok            = $true
                action        = 'hover'
                at_utc        = (Get-Date).ToUniversalTime().ToString('o')
                count         = $Count
                interval_ms   = $IntervalMs
                total_ms      = [math]::Round($sw.Elapsed.TotalMilliseconds, 3)
                send_mean_ms  = [math]::Round((($durations | Measure-Object -Average).Average), 4)
                send_max_ms   = [math]::Round((($durations | Measure-Object -Maximum).Maximum), 4)
            })
        }

        'wheel' {
            $rs = Get-RiotSwitchProcess
            $overlay = Get-OverlayWindow -RiotSwitchPid $rs.Id -RequireVisible $true
            if ($null -eq $overlay) { Fail 'Overlay visible introuvable.' }
            $cx = [int](($overlay.left + $overlay.right) / 2)
            $cy = [int](($overlay.top + $overlay.bottom) / 2)
            $durations = New-Object System.Collections.Generic.List[double]
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            for ($i = 0; $i -lt $Count; $i++) {
                $d = $Delta
                if (($i % 2) -eq 1) { $d = -$Delta }
                $ms = [RiotSwitchPerf.RunCtl.RunCtl]::MouseWheel([IntPtr]$overlay.hwnd, $cx, $cy, $d)
                $durations.Add([double]$ms)
                if ($IntervalMs -gt 0) { Start-Sleep -Milliseconds $IntervalMs }
            }
            $sw.Stop()
            Write-Result ([ordered]@{
                ok           = $true
                action       = 'wheel'
                at_utc       = (Get-Date).ToUniversalTime().ToString('o')
                count        = $Count
                delta        = $Delta
                interval_ms  = $IntervalMs
                total_ms     = [math]::Round($sw.Elapsed.TotalMilliseconds, 3)
                send_mean_ms = [math]::Round((($durations | Measure-Object -Average).Average), 4)
                send_max_ms  = [math]::Round((($durations | Measure-Object -Maximum).Maximum), 4)
            })
        }

        'move-riot' {
            $rs = Get-RiotSwitchProcess
            $overlay = Get-OverlayWindow -RiotSwitchPid $rs.Id -RequireVisible $true
            if ($null -eq $overlay) { Fail 'Overlay visible introuvable.' }
            $riot = Get-RiotWindow
            if ($null -eq $riot) { Fail 'Fenetre Riot Client introuvable.' }
            $origRect = [RiotSwitchPerf.RunCtl.RunCtl]::RectString([IntPtr]$riot.hwnd)
            $op = $origRect -split ','
            $origX = [int]$op[0]
            $origY = [int]$op[1]
            $stepList = New-Object System.Collections.Generic.List[object]
            $dir = 1
            for ($i = 1; $i -le $Steps; $i++) {
                $dx = $DeltaX * $dir
                $dy = $DeltaY * $dir
                $res = [RiotSwitchPerf.RunCtl.RunCtl]::MoveRiotStep([IntPtr]$riot.hwnd, [IntPtr]$overlay.hwnd, $dx, $dy, $TimeoutMs) -split '\|'
                $stepList.Add([ordered]@{
                    step        = $i
                    dx          = $dx
                    dy          = $dy
                    latency_ms  = [double]$res[0]
                    before_rect = $res[1]
                    after_rect  = $res[2]
                    riot_rect   = $res[3]
                    changed     = ($res[4] -eq '1')
                })
                if ($StepIntervalMs -gt 0) { Start-Sleep -Milliseconds $StepIntervalMs }
                if (($i % 2) -eq 0) { $dir = -$dir }
            }
            $restored = $false
            if ($Restore -or (-not $PSBoundParameters.ContainsKey('Restore'))) {
                [RiotSwitchPerf.RunCtl.RunCtl]::MoveWindowTo([IntPtr]$riot.hwnd, $origX, $origY)
                Start-Sleep -Milliseconds 200
                $restored = $true
            }
            $lat = @($stepList | ForEach-Object { $_.latency_ms })
            Write-Result ([ordered]@{
                ok             = $true
                action         = 'move-riot'
                at_utc         = (Get-Date).ToUniversalTime().ToString('o')
                steps_count    = $Steps
                delta_x        = $DeltaX
                delta_y        = $DeltaY
                interval_ms    = $StepIntervalMs
                original_rect  = $origRect
                restored       = $restored
                latency_ms     = [ordered]@{
                    min  = [math]::Round((($lat | Measure-Object -Minimum).Minimum), 3)
                    mean = [math]::Round((($lat | Measure-Object -Average).Average), 3)
                    max  = [math]::Round((($lat | Measure-Object -Maximum).Maximum), 3)
                }
                changed_count  = @($stepList | Where-Object { $_.changed }).Count
                steps          = $stepList
            })
        }

        'list-windows' {
            $wins = Get-ParsedWindows
            $rows = @($wins | Where-Object { $_.visible } | ForEach-Object {
                [ordered]@{
                    hwnd = $_.hwnd; pid = $_.pid; class = $_.class; title = $_.title
                    rect = "$($_.left),$($_.top),$($_.right),$($_.bottom)"
                }
            })
            Write-Result ([ordered]@{ ok = $true; action = 'list-windows'; at_utc = (Get-Date).ToUniversalTime().ToString('o'); count = $rows.Count; windows = $rows })
        }

        'quit-watcher' {
            $rs = Get-RiotSwitchProcess
            $posted = [RiotSwitchPerf.RunCtl.RunCtl]::BroadcastQuit()
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $exited = $false
            while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
                if ($null -eq (Get-Process -Id $rs.Id -ErrorAction SilentlyContinue)) { $exited = $true; break }
                Start-Sleep -Milliseconds 50
            }
            $sw.Stop()
            Write-Result ([ordered]@{
                ok        = $exited
                action    = 'quit-watcher'
                at_utc    = (Get-Date).ToUniversalTime().ToString('o')
                pid       = $rs.Id
                posted    = $posted
                exited    = $exited
                waited_ms = [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
                error     = $(if ($exited) { $null } else { 'Le veilleur ne s''est pas arrete dans le delai.' })
            })
            if (-not $exited) { exit 2 }
        }

        default { Fail "Action inconnue : $Action" }
    }
} catch {
    $detail = ''
    if ($null -ne $_.InvocationInfo) {
        $detail = ' @ligne ' + $_.InvocationInfo.ScriptLineNumber + ' : ' + ([string]$_.InvocationInfo.Line).Trim()
    }
    Fail ('Exception : ' + $_.Exception.Message + $detail)
}
