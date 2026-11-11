# riotswitch-driver.ps1 - UI/overlay driver for the RiotSwitch performance campaign.
#
# Scope : tools/perf/driver/ only. Does not modify src/, does not rebuild, never kills
# Riot Client / RiotSwitch. Read-only access to RiotSwitch settings/accounts JSON files.
#
# One action per invocation. Emits exactly one JSON object on stdout (ASCII-safe,
# invariant decimal point). Exit code 0 = success, 2 = failure.
#
# Interactive actions (foreground-riot, click, expand, collapse, toggle, move-riot,
# hover, wheel, restore) require -AllowInteraction. click -Target footer:0 (add/switch
# account) additionally requires -Force.
#
# Source comments are ASCII-only on purpose (Windows PowerShell 5.1 script encoding).

[CmdletBinding()]
param(
    [string]$Action = 'discover',
    [string]$TimeoutMs = '',
    [string]$Target = '',
    [string]$Dx = '',
    [string]$Dy = '',
    [string]$Steps = '',
    [string]$Count = '',
    [string]$IntervalMs = '',
    [string]$Delta = '',
    [string]$PressMs = '',
    [switch]$AllowInteraction,
    [switch]$Force,
    [switch]$SaveBaseline,
    [switch]$RestorePin,
    [switch]$RestoreForeground,
    [switch]$SkipSettingsClose,
    [switch]$NoLog
)

$ErrorActionPreference = 'Stop'

$script:Invariant = [System.Globalization.CultureInfo]::InvariantCulture
$script:DriverRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($script:DriverRoot)) { $script:DriverRoot = (Get-Location).Path }
$script:StateDir = Join-Path $script:DriverRoot '.state'
$script:LogDir = Join-Path $script:DriverRoot 'logs'
$script:BaselinePath = Join-Path $script:StateDir 'baseline.json'
$script:LogPath = Join-Path $script:LogDir 'driver.jsonl'
$script:QpcFreq = [System.Diagnostics.Stopwatch]::Frequency
if ($script:QpcFreq -le 0) { $script:QpcFreq = 10000000 }
$script:Warnings = New-Object 'System.Collections.Generic.List[string]'
$script:ProcCache = @{}
$script:ScriptStartQpc = [System.Diagnostics.Stopwatch]::GetTimestamp()
$script:StartedUtcIso = [DateTime]::UtcNow.ToString('o', $script:Invariant)
$script:PostTypeQpc = $script:ScriptStartQpc
$script:ActionStartQpc = $script:ScriptStartQpc
$script:Context = $null
$script:Options = $null
$script:ActionName = 'discover'
$script:LogEnabled = (-not $NoLog.IsPresent)

# Geometry (DIP) mirrored from src/RiotSwitcher.App/OverlayForm.cs.
$script:DipCollapsedSize = 40.0
$script:DipPanelWidth = 380.0
$script:DipHeaderTop = 11.0
$script:DipHeaderHeight = 40.0
$script:DipHeaderButtonSize = 28.0
$script:DipHeaderButtonGap = 2.0
$script:DipHeaderButtonsY = 17.0
$script:DipContentLeft = 17.0
$script:DipContentWidth = 346.0
$script:DipFooterGap = 8.0
$script:DipFooterHeight = 36.0
$script:DipFooterButtonWidth = 110.0
$script:DipListTop = 92.0
$script:EdgeMarginDip = 8.0
$script:DipCloseX = 335.0
$script:DipPinX = 305.0

$script:WM_MOUSEMOVE = 0x0200
$script:WM_LBUTTONDOWN = 0x0201
$script:WM_LBUTTONUP = 0x0202
$script:WM_MOUSEWHEEL = 0x020A
$script:WM_MOUSELEAVE = 0x02A3
$script:WM_CLOSE = 0x0010
$script:SWP_NOSIZE = [uint32]0x0001
$script:SWP_NOZORDER = [uint32]0x0004
$script:SWP_NOACTIVATE = [uint32]0x0010
$script:SWP_NOOWNERZORDER = [uint32]0x0200
$script:MONITOR_DEFAULT = 0

# ---------------------------------------------------------------------------
# Utility functions (no P/Invoke dependency).
# ---------------------------------------------------------------------------

function Get-QpcTicks { [System.Diagnostics.Stopwatch]::GetTimestamp() }

function Get-DeltaMs {
    param([long]$From, [long]$To)
    return [Math]::Round((($To - $From) * 1000.0) / $script:QpcFreq, 3)
}

function Format-HexValue {
    param([IntPtr]$Value)
    return ('0x{0:X}' -f $Value.ToInt64())
}

function Get-ProcessNameSafe {
    param([int]$ProcessId)
    if ($ProcessId -le 0) { return $null }
    if ($script:ProcCache.ContainsKey($ProcessId)) { return $script:ProcCache[$ProcessId] }
    $name = $null
    try {
        $p = Get-Process -Id $ProcessId -ErrorAction Stop
        $name = $p.ProcessName
    } catch {
        $name = $null
    }
    $script:ProcCache[$ProcessId] = $name
    return $name
}

function ConvertTo-DriverJsonString {
    param([string]$Value)
    if ($null -eq $Value) { $Value = '' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $Value.ToCharArray()) {
        $code = [int]$ch
        if ($ch -eq '"') { [void]$sb.Append('\"') }
        elseif ($ch -eq '\') { [void]$sb.Append('\\') }
        elseif ($code -eq 8) { [void]$sb.Append('\b') }
        elseif ($code -eq 9) { [void]$sb.Append('\t') }
        elseif ($code -eq 10) { [void]$sb.Append('\n') }
        elseif ($code -eq 12) { [void]$sb.Append('\f') }
        elseif ($code -eq 13) { [void]$sb.Append('\r') }
        elseif ($code -lt 32) { [void]$sb.Append(('\u{0:x4}' -f $code)) }
        elseif ($code -gt 126) { [void]$sb.Append(('\u{0:x4}' -f $code)) }
        else { [void]$sb.Append($ch) }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function ConvertTo-DriverJson {
    param($Value)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [string]) { return (ConvertTo-DriverJsonString $Value) }
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [int16] -or $Value -is [byte] -or
        $Value -is [uint16] -or $Value -is [uint32] -or $Value -is [uint64]) {
        return $Value.ToString($script:Invariant)
    }
    if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) {
        $d = [double]$Value
        if ([double]::IsNaN($d) -or [double]::IsInfinity($d)) { return 'null' }
        return $d.ToString('0.######', $script:Invariant)
    }
    if ($Value -is [DateTime]) {
        return (ConvertTo-DriverJsonString ([DateTime]$Value).ToUniversalTime().ToString('o', $script:Invariant))
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $parts = New-Object 'System.Collections.Generic.List[string]'
        foreach ($key in $Value.Keys) {
            $keyText = [string]$key
            if ($keyText.StartsWith('__')) { continue }
            $parts.Add((ConvertTo-DriverJsonString $keyText) + ':' + (ConvertTo-DriverJson $Value[$key]))
        }
        return '{' + ($parts -join ',') + '}'
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $parts = New-Object 'System.Collections.Generic.List[string]'
        foreach ($prop in $Value.PSObject.Properties) {
            if ($prop.Name.StartsWith('__')) { continue }
            $parts.Add((ConvertTo-DriverJsonString $prop.Name) + ':' + (ConvertTo-DriverJson $prop.Value))
        }
        return '{' + ($parts -join ',') + '}'
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $parts = New-Object 'System.Collections.Generic.List[string]'
        foreach ($item in $Value) { $parts.Add((ConvertTo-DriverJson $item)) }
        return '[' + ($parts -join ',') + ']'
    }
    return (ConvertTo-DriverJsonString ([string]$Value))
}

function Throw-DriverFault {
    param([string]$Code, [string]$Message, $Details)
    throw ([DriverFaultException]::new($Code, $Message, $Details))
}

function Add-Warning {
    param([string]$Message)
    if (-not $script:Warnings.Contains($Message)) { [void]$script:Warnings.Add($Message) }
}

function Get-IntArg {
    param([string]$Name, [string]$Value, [int]$Default, [int]$Min, [int]$Max)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $Default }
    $tmp = 0
    if (-not [int]::TryParse($Value.Trim(), [ref]$tmp)) {
        Throw-DriverFault 'invalid_args' ("Argument -$Name must be an integer (got '" + $Value + "').") $null
    }
    if ($tmp -lt $Min -or $tmp -gt $Max) {
        Throw-DriverFault 'invalid_args' ("Argument -$Name out of range [$Min..$Max] (got $tmp).") $null
    }
    return $tmp
}

function Get-NumberStats {
    param([double[]]$Values)
    $empty = [ordered]@{ count = 0; min = $null; mean = $null; median = $null; max = $null }
    if ($null -eq $Values -or $Values.Count -eq 0) { return $empty }
    $arr = @($Values | Sort-Object)
    $n = $arr.Count
    $sum = 0.0
    foreach ($v in $arr) { $sum += [double]$v }
    if ($n -eq 1) {
        $med = [double]$arr[0]
    } elseif (($n % 2) -eq 1) {
        $med = [double]$arr[[int](($n - 1) / 2)]
    } else {
        $med = (([double]$arr[[int]($n / 2) - 1]) + ([double]$arr[[int]($n / 2)])) / 2.0
    }
    return [ordered]@{
        count = $n
        min = [Math]::Round([double]$arr[0], 3)
        mean = [Math]::Round($sum / $n, 3)
        median = [Math]::Round($med, 3)
        max = [Math]::Round([double]$arr[$n - 1], 3)
    }
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $text = [System.IO.File]::ReadAllText($Path)
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        return ($text | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Save-TextFileAtomic {
    param([string]$Path, [string]$Text)
    $dir = [System.IO.Path]::GetDirectoryName($Path)
    if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $tmp = $Path + '.tmp'
    [System.IO.File]::WriteAllText($tmp, $Text, (New-Object System.Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Ensure-Directories {
    foreach ($dir in @($script:StateDir, $script:LogDir)) {
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    }
}

function Write-ActionLog {
    param($Response)
    if (-not $script:LogEnabled) { return }
    try {
        Ensure-Directories
        $record = [ordered]@{
            tsUtc = [DateTime]::UtcNow.ToString('o', $script:Invariant)
            action = $Response.action
            ok = $Response.ok
            exitCode = $Response.exitCode
            durationMs = $Response.timing.totalMs
            qpc = $Response.timing.qpc
            errorCode = $null
            riot = $null
            overlay = $null
            target = $null
            notes = $Response.warnings
        }
        if ($null -ne $Response.error) { $record.errorCode = $Response.error.code }
        if ($null -ne $script:Context) {
            if ($null -ne $script:Context.riotWindow) {
                $record.riot = [ordered]@{ hwnd = $script:Context.riotWindow.hwnd; pid = $script:Context.riotWindow.pid; iconic = $script:Context.riotWindow.iconic; rect = $script:Context.riotWindow.rect }
            }
            if ($null -ne $script:Context.overlayWindow) {
                $record.overlay = [ordered]@{ hwnd = $script:Context.overlayWindow.hwnd; visible = $script:Context.overlayWindow.visible; rect = $script:Context.overlayWindow.rect; state = $script:Context.classification.state }
            }
        }
        if ($null -ne $script:Options -and -not [string]::IsNullOrWhiteSpace($script:Options.Target)) { $record.target = $script:Options.Target }
        $line = ConvertTo-DriverJson $record
        [System.IO.File]::AppendAllText($script:LogPath, $line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        # Logging must never fail the action.
    }
}

function Get-RiotProcessIds {
    $ids = @()
    try {
        $ids = @(Get-Process -Name 'Riot Client' -ErrorAction SilentlyContinue | ForEach-Object { [int]$_.Id })
    } catch { $ids = @() }
    return $ids
}

# ---------------------------------------------------------------------------
# Native layer (P/Invoke + helpers). Add-Type is done first thing below.
# ---------------------------------------------------------------------------

try {
    $nativeSource = @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class DriverFaultException : Exception
{
    public string Code;
    public object Details;
    public DriverFaultException(string code, string message, object details) : base(message)
    {
        this.Code = code;
        this.Details = details;
    }
}

public static class RiotPerfNative
{
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr hWnd, ref POINT lpPoint);
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam, uint fuFlags, uint uTimeout, out IntPtr lpdwResult);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT lpPoint);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hwnd, int dwAttribute, out int pvAttribute, int cbAttribute);

    public static IntPtr[] TopLevelWindows()
    {
        List<IntPtr> list = new List<IntPtr>();
        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam) { list.Add(hWnd); return true; }, IntPtr.Zero);
        return list.ToArray();
    }

    public static string Title(IntPtr hWnd)
    {
        StringBuilder sb = new StringBuilder(1024);
        GetWindowTextW(hWnd, sb, sb.Capacity);
        return sb.ToString();
    }

    public static string ClassName(IntPtr hWnd)
    {
        StringBuilder sb = new StringBuilder(512);
        GetClassNameW(hWnd, sb, sb.Capacity);
        return sb.ToString();
    }

    public static int ProcessId(IntPtr hWnd)
    {
        uint pid;
        GetWindowThreadProcessId(hWnd, out pid);
        return (int)pid;
    }

    public static RECT Rect(IntPtr hWnd) { RECT r; GetWindowRect(hWnd, out r); return r; }
    public static RECT ClientRect(IntPtr hWnd) { RECT r; GetClientRect(hWnd, out r); return r; }
    public static uint Dpi(IntPtr hWnd) { return GetDpiForWindow(hWnd); }
    public static int ExStyle(IntPtr hWnd) { return GetWindowLong(hWnd, -20); }
    public static IntPtr Owner(IntPtr hWnd) { return GetWindow(hWnd, 4); }
    public static bool Cloaked(IntPtr hWnd) { int v = 0; int hr = DwmGetWindowAttribute(hWnd, 14, out v, 4); return hr == 0 && v != 0; }

    public static int[] ClientOrigin(IntPtr hWnd)
    {
        POINT p; p.X = 0; p.Y = 0;
        ClientToScreen(hWnd, ref p);
        return new int[] { p.X, p.Y };
    }

    public static IntPtr MakeLParam(int x, int y)
    {
        uint xv = ((uint)x) & 0xFFFFu;
        uint yv = ((uint)y) & 0xFFFFu;
        long v = (((long)yv) << 16) | ((long)xv);
        return new IntPtr(v);
    }

    public static IntPtr PackWheelWParam(int delta)
    {
        uint dv = ((uint)delta) & 0xFFFFu;
        long v = ((long)dv) << 16;
        return new IntPtr(v);
    }

    public static IntPtr Ptr(int value) { return new IntPtr(value); }

    public static bool ForceForeground(IntPtr hWnd)
    {
        if (hWnd == IntPtr.Zero || !IsWindow(hWnd)) return false;
        if (SetForegroundWindow(hWnd)) return true;

        IntPtr foreground = GetForegroundWindow();
        uint foregroundThread = 0;
        if (foreground != IntPtr.Zero) { GetWindowThreadProcessId(foreground, out foregroundThread); }
        uint currentThread = GetCurrentThreadId();
        bool attached = foregroundThread != 0 && foregroundThread != currentThread &&
                        AttachThreadInput(currentThread, foregroundThread, true);
        try
        {
            BringWindowToTop(hWnd);
            return SetForegroundWindow(hWnd);
        }
        finally
        {
            if (attached) AttachThreadInput(currentThread, foregroundThread, false);
        }
    }
}
'@
    Add-Type -TypeDefinition $nativeSource -Language CSharp -ErrorAction Stop
    $script:PostTypeQpc = Get-QpcTicks
} catch {
    $errResp = [ordered]@{
        schema = 'riotswitch.perf.driver/1'
        action = $Action
        ok = $false
        exitCode = 2
        startedUtc = $script:StartedUtcIso
        finishedUtc = [DateTime]::UtcNow.ToString('o', $script:Invariant)
        error = [ordered]@{
            code = 'native_layer_failed'
            message = ('Add-Type (P/Invoke layer) failed: ' + $_.Exception.Message)
            details = $null
        }
        warnings = @()
    }
    [Console]::Out.WriteLine((ConvertTo-DriverJson $errResp))
    exit 2
}

# ---------------------------------------------------------------------------
# Window discovery.
# ---------------------------------------------------------------------------

function New-WindowSnapshot {
    param([IntPtr]$Hwnd)
    $rect = [RiotPerfNative]::Rect($Hwnd)
    $client = [RiotPerfNative]::ClientRect($Hwnd)
    $dpi = [int][RiotPerfNative]::Dpi($Hwnd)
    $ex = [int][RiotPerfNative]::ExStyle($Hwnd)
    $owner = [RiotPerfNative]::Owner($Hwnd)
    $pidValue = [int][RiotPerfNative]::ProcessId($Hwnd)
    $origin = @([RiotPerfNative]::ClientOrigin($Hwnd))
    return [ordered]@{
        __hwnd = $Hwnd
        hwnd = (Format-HexValue $Hwnd)
        pid = $pidValue
        process = (Get-ProcessNameSafe $pidValue)
        title = [RiotPerfNative]::Title($Hwnd)
        class = [RiotPerfNative]::ClassName($Hwnd)
        valid = [bool][RiotPerfNative]::IsWindow($Hwnd)
        visible = [bool][RiotPerfNative]::IsWindowVisible($Hwnd)
        iconic = [bool][RiotPerfNative]::IsIconic($Hwnd)
        zoomed = [bool][RiotPerfNative]::IsZoomed($Hwnd)
        enabled = [bool][RiotPerfNative]::IsWindowEnabled($Hwnd)
        cloaked = [bool][RiotPerfNative]::Cloaked($Hwnd)
        ownerHwnd = (Format-HexValue $owner)
        rect = [ordered]@{ x = [int]$rect.Left; y = [int]$rect.Top; w = [int]($rect.Right - $rect.Left); h = [int]($rect.Bottom - $rect.Top) }
        client = [ordered]@{ w = [int]($client.Right - $client.Left); h = [int]($client.Bottom - $client.Top) }
        clientOriginScreen = [ordered]@{ x = [int]$origin[0]; y = [int]$origin[1] }
        dpi = $dpi
        scale = [Math]::Round((Get-ScaleFromDpi $dpi), 6)
        exStyle = ('0x' + $ex.ToString('X8'))
        layered = [bool](($ex -band 0x00080000) -ne 0)
        toolWindow = [bool](($ex -band 0x00000080) -ne 0)
        noActivate = [bool](($ex -band 0x08000000) -ne 0)
        topmost = [bool](($ex -band 0x00000008) -ne 0)
    }
}

function Get-ScaleFromDpi {
    param([int]$Dpi)
    if ($Dpi -le 0) { $Dpi = 96 }
    $s = $Dpi / 96.0
    if ($s -lt 1.0) { $s = 1.0 }
    if ($s -gt 2.5) { $s = 2.5 }
    return $s
}

function Get-RiotCriteriaReasons {
    param($Snapshot)
    $reasons = New-Object 'System.Collections.Generic.List[string]'
    if (-not $Snapshot.visible) { $reasons.Add('not_visible') }
    if ($Snapshot.iconic) { $reasons.Add('minimized') }
    if ($Snapshot.cloaked) { $reasons.Add('cloaked') }
    if ($Snapshot.title -cne 'Riot Client') { $reasons.Add('title_mismatch') }
    if ($Snapshot.process -ne 'Riot Client') { $reasons.Add('process_mismatch') }
    if ($Snapshot.rect.w -lt 1000 -or $Snapshot.rect.h -lt 700) { $reasons.Add('rect_smaller_than_1000x700') }
    if ($Snapshot.topmost -and ($Snapshot.rect.w -lt 1400 -or $Snapshot.rect.h -lt 800)) { $reasons.Add('topmost_and_smaller_than_1400x800') }
    return $reasons
}

function Find-RiotWindows {
    $list = New-Object 'System.Collections.Generic.List[object]'
    foreach ($h in [RiotPerfNative]::TopLevelWindows()) {
        $title = [RiotPerfNative]::Title($h)
        $proc = Get-ProcessNameSafe ([int][RiotPerfNative]::ProcessId($h))
        $isTitleMatch = ($title -ceq 'Riot Client')
        $isProcessCandidate = ($proc -ne $null) -and ($proc -eq 'Riot Client')
        $cls = [RiotPerfNative]::ClassName($h)
        $include = $isTitleMatch -or ($isProcessCandidate -and $title -ne '' -and $cls.StartsWith('Chrome_WidgetWin'))
        if (-not $include) { continue }
        $snap = New-WindowSnapshot $h
        $reasons = @(Get-RiotCriteriaReasons $snap)
        $snap['appCriteriaOk'] = ($reasons.Count -eq 0)
        $snap['rejectionReasons'] = $reasons
        $snap['lenientTitleMatch'] = $isTitleMatch
        $list.Add($snap)
    }
    $arr = @($list.ToArray())
    $arr = @($arr | Sort-Object -Property @{ Expression = { if ($_.appCriteriaOk) { 0 } else { 1 } } }, @{ Expression = { -([long]$_.rect.w * [long]$_.rect.h) } })
    return $arr
}

function Find-OverlayWindows {
    $list = New-Object 'System.Collections.Generic.List[object]'
    foreach ($h in [RiotPerfNative]::TopLevelWindows()) {
        if ([RiotPerfNative]::Title($h) -cne 'RiotSwitch') { continue }
        $cls = [RiotPerfNative]::ClassName($h)
        if (-not $cls.StartsWith('WindowsForms10')) { continue }
        $proc = Get-ProcessNameSafe ([int][RiotPerfNative]::ProcessId($h))
        if ($proc -ne 'RiotSwitch') { continue }
        $list.Add((New-WindowSnapshot $h))
    }
    $arr = @($list.ToArray())
    $arr = @($arr | Sort-Object -Property @{ Expression = { if ($_.visible) { 0 } else { 1 } } }, @{ Expression = { -([long]$_.rect.w * [long]$_.rect.h) } })
    return $arr
}

function Get-VisibleOverlayWindow {
    foreach ($w in @(Find-OverlayWindows)) {
        if ($w.visible -and $w.rect.w -gt 0 -and $w.rect.h -gt 0) { return $w }
    }
    return $null
}

function Find-SettingsDialog {
    foreach ($h in [RiotPerfNative]::TopLevelWindows()) {
        $proc = Get-ProcessNameSafe ([int][RiotPerfNative]::ProcessId($h))
        if ($proc -ne 'RiotSwitch') { continue }
        $title = [RiotPerfNative]::Title($h)
        if ($title -ceq 'RiotSwitch' -or $title -ceq 'RiotSwitch.Watch') { continue }
        if ($title.IndexOf('Param', [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        $cls = [RiotPerfNative]::ClassName($h)
        if (-not $cls.StartsWith('WindowsForms10')) { continue }
        $snap = New-WindowSnapshot $h
        if ($snap.visible) { return $snap }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Read-only RiotSwitch vault access (settings + accounts).
# ---------------------------------------------------------------------------

function Read-SettingsInfo {
    $path = Join-Path $env:LOCALAPPDATA 'RiotSwitch\settings.json'
    $info = [ordered]@{
        path = $path
        readOk = $false
        schemaVersion = $null
        overlayPinned = $null
        overlayOffsetRightDip = $null
        overlayOffsetTopDip = $null
        overlayPositionSet = $null
        error = $null
    }
    try {
        $obj = Read-JsonFile $path
        if ($null -ne $obj) {
            $info.readOk = $true
            $info.schemaVersion = $obj.schemaVersion
            $info.overlayPinned = $obj.overlayPinned
            $info.overlayOffsetRightDip = $obj.overlayOffsetRightDip
            $info.overlayOffsetTopDip = $obj.overlayOffsetTopDip
            $info.overlayPositionSet = $obj.overlayPositionSet
        }
    } catch {
        $info.error = $_.Exception.Message
    }
    return $info
}

function Read-AccountsInfo {
    $path = Join-Path $env:LOCALAPPDATA 'RiotSwitch\accounts.json'
    $info = [ordered]@{ path = $path; readOk = $false; count = $null; error = $null }
    try {
        $obj = Read-JsonFile $path
        if ($null -ne $obj) {
            $info.readOk = $true
            if ($null -ne $obj.accounts) { $info.count = @($obj.accounts).Count } else { $info.count = 0 }
        }
    } catch {
        $info.error = $_.Exception.Message
    }
    return $info
}

function Read-BaselineFile {
    $path = $script:BaselinePath
    $info = [ordered]@{ exists = $false; path = $path; savedUtc = $null; source = $null; data = $null; error = $null }
    try {
        $obj = Read-JsonFile $path
        if ($null -ne $obj) {
            $info.exists = $true
            $info.savedUtc = $obj.savedUtc
            $info.source = $obj.source
            $info.data = $obj
        }
    } catch {
        $info.error = $_.Exception.Message
    }
    return $info
}

function Save-BaselineFile {
    param($RiotSnapshot, $OverlaySnapshot, [double]$Scale, $SettingsInfo, [string]$Source, [string]$OverlayState)
    Ensure-Directories
    $doc = [ordered]@{
        schemaVersion = 1
        savedUtc = [DateTime]::UtcNow.ToString('o', $script:Invariant)
        source = $Source
        driverSchema = 'riotswitch.perf.driver/1'
        riot = $null
        overlay = $null
        settings = $null
        foregroundHwnd = (Format-HexValue ([RiotPerfNative]::GetForegroundWindow()))
    }
    if ($null -ne $RiotSnapshot) {
        $doc.riot = [ordered]@{
            hwnd = $RiotSnapshot.hwnd
            pid = $RiotSnapshot.pid
            rect = $RiotSnapshot.rect
        }
    }
    if ($null -ne $OverlaySnapshot) {
        $doc.overlay = [ordered]@{
            hwnd = $OverlaySnapshot.hwnd
            visible = $OverlaySnapshot.visible
            rect = $OverlaySnapshot.rect
            state = $OverlayState
        }
    }
    if ($null -ne $SettingsInfo -and $SettingsInfo.readOk) {
        $doc.settings = [ordered]@{
            overlayPinned = $SettingsInfo.overlayPinned
            overlayOffsetRightDip = $SettingsInfo.overlayOffsetRightDip
            overlayOffsetTopDip = $SettingsInfo.overlayOffsetTopDip
        }
    }
    Save-TextFileAtomic $script:BaselinePath (ConvertTo-DriverJson $doc)
    return $doc
}

# ---------------------------------------------------------------------------
# Geometry / classification.
# ---------------------------------------------------------------------------

function New-PointPx {
    param([double]$DipX, [double]$DipY, [double]$Scale)
    return [ordered]@{
        x = [int][Math]::Round($DipX * $Scale)
        y = [int][Math]::Round($DipY * $Scale)
    }
}

function Get-AnchorComparison {
    param($Riot, $Overlay, [double]$Scale, $SettingsInfo)
    if ($null -eq $Riot -or $null -eq $Overlay -or -not $Overlay.visible) { return $null }
    $w = [int]$Overlay.rect.w
    $h = [int]$Overlay.rect.h
    $right = [int]($Riot.rect.x + $Riot.rect.w)
    $bottom = [int]($Riot.rect.y + $Riot.rect.h)
    $inferredRight = [Math]::Round((($right - [int]$Overlay.rect.x - $w) / $Scale), 3)
    $inferredTop = [Math]::Round((([int]$Overlay.rect.y - [int]$Riot.rect.y) / $Scale), 3)
    $offsetRight = [double]$inferredRight
    $offsetTop = [double]$inferredTop
    $source = 'inferred'
    if ($null -ne $SettingsInfo -and $SettingsInfo.readOk -and $null -ne $SettingsInfo.overlayOffsetRightDip -and $null -ne $SettingsInfo.overlayOffsetTopDip) {
        $offsetRight = [double]$SettingsInfo.overlayOffsetRightDip
        $offsetTop = [double]$SettingsInfo.overlayOffsetTopDip
        $source = 'settings'
    }
    $margin = [int][Math]::Round($script:EdgeMarginDip * $Scale)
    $expX = [int][Math]::Round(($right - ($offsetRight * $Scale) - $w))
    $expY = [int][Math]::Round(([int]$Riot.rect.y + ($offsetTop * $Scale)))
    $minX = [int]$Riot.rect.x + $margin
    $maxX = $right - $w - $margin
    if ($maxX -lt $minX) { $maxX = $minX }
    $minY = [int]$Riot.rect.y + $margin
    $maxY = $bottom - $h - $margin
    if ($maxY -lt $minY) { $maxY = $minY }
    $clampedX = $false
    $clampedY = $false
    if ($expX -lt $minX) { $expX = $minX; $clampedX = $true } elseif ($expX -gt $maxX) { $expX = $maxX; $clampedX = $true }
    if ($expY -lt $minY) { $expY = $minY; $clampedY = $true } elseif ($expY -gt $maxY) { $expY = $maxY; $clampedY = $true }
    $devX = [int]$Overlay.rect.x - $expX
    $devY = [int]$Overlay.rect.y - $expY
    return [ordered]@{
        source = $source
        offsetRightDip = [double]$offsetRight
        offsetTopDip = [double]$offsetTop
        inferredOffsets = [ordered]@{ rightDip = [double]$inferredRight; topDip = [double]$inferredTop }
        expected = [ordered]@{ x = $expX; y = $expY; widthPx = $w; heightPx = $h }
        deviationPx = [ordered]@{ x = $devX; y = $devY }
        clamped = [ordered]@{ x = $clampedX; y = $clampedY }
        marginPx = $margin
        matches = ([Math]::Abs($devX) -le 2 -and [Math]::Abs($devY) -le 2)
    }
}

function New-ClickTarget {
    param(
        [string]$TargetName,
        [double]$PointX,
        [double]$PointY,
        [double]$RectX,
        [double]$RectY,
        [double]$RectW,
        [double]$RectH,
        [string]$Effect,
        [string]$Expects,
        [bool]$RequiresForce,
        [string]$Notes,
        [double]$Scale
    )
    return [ordered]@{
        target = $TargetName
        pointDip = [ordered]@{ x = $PointX; y = $PointY }
        rectDip = [ordered]@{ x = $RectX; y = $RectY; w = $RectW; h = $RectH }
        pointPx = (New-PointPx $PointX $PointY $Scale)
        effect = $Effect
        expects = $Expects
        requiresForce = $RequiresForce
        notes = $Notes
    }
}

function New-ClickTargets {
    param([string]$State, $FooterYDip, [double]$Scale)
    $map = [ordered]@{}
    if ($State -eq 'collapsed') {
        $map['collapsed'] = New-ClickTarget -TargetName 'collapsed' -PointX 20 -PointY 20 -RectX 0 -RectY 0 -RectW 40 -RectH 40 `
            -Effect 'expand overlay panel (Expand)' -Expects 'expanded' -RequiresForce $false `
            -Notes 'collapsed button; mouse down+up with no movement; hit area is the whole 40x40 rect' -Scale $Scale
        return $map
    }
    if ($State -eq 'expanded' -and $null -ne $FooterYDip) {
        $footerY = [double]$FooterYDip
        $map['close'] = New-ClickTarget -TargetName 'close' -PointX 349 -PointY 31 -RectX 335 -RectY 17 -RectW 28 -RectH 28 `
            -Effect 'collapse overlay panel (Collapse; expanded state is not persisted)' -Expects 'collapsed' -RequiresForce $false `
            -Notes 'CloseRect; action fires on mouse-up inside the rect' -Scale $Scale
        $map['pin'] = New-ClickTarget -TargetName 'pin' -PointX 319 -PointY 31 -RectX 305 -RectY 17 -RectW 28 -RectH 28 `
            -Effect 'toggle overlayPinned in settings.json and show a transient status block (+24 or +40 DIP for 5s info retention)' -Expects 'pin_toggled' -RequiresForce $false `
            -Notes 'PinRect; persists settings immediately, so panel height changes during the status retention' -Scale $Scale
        $map['header'] = New-ClickTarget -TargetName 'header' -PointX 190 -PointY 31 -RectX 17 -RectY 11 -RectW 286 -RectH 40 `
            -Effect 'begin drag; on mouse-up saves settings (no visual change)' -Expects 'none' -RequiresForce $false `
            -Notes 'safe header point: not over PinRect/CloseRect/rows; writes settings.json with unchanged values' -Scale $Scale
        $map['settings'] = New-ClickTarget -TargetName 'settings' -PointX 190 -PointY ($footerY + 18) -RectX 135 -RectY $footerY -RectW 110 -RectH 36 `
            -Effect 'open the modal SettingsForm dialog (blocks the overlay UI thread until the dialog is closed)' -Expects 'settings_dialog' -RequiresForce $false `
            -Notes 'opening a modal window is intrusive for measurements; run restore (or -SkipSettingsClose:$false default) to close it' -Scale $Scale
        $map['footer:0'] = New-ClickTarget -TargetName 'footer:0' -PointX 72 -PointY ($footerY + 18) -RectX 17 -RectY $footerY -RectW 110 -RectH 36 `
            -Effect 'CaptureCurrent: add/switch the current Riot account (writes the account vault, may restart the client)' -Expects 'none' -RequiresForce $true `
            -Notes 'dangerous and non-reversible from the driver; requires -Force in addition to -AllowInteraction' -Scale $Scale
        $map['footer:1'] = New-ClickTarget -TargetName 'footer:1' -PointX 190 -PointY ($footerY + 18) -RectX 135 -RectY $footerY -RectW 110 -RectH 36 `
            -Effect 'open the modal SettingsForm dialog (same handler as target settings)' -Expects 'settings_dialog' -RequiresForce $false `
            -Notes 'same behavior as target settings' -Scale $Scale
        $map['footer:2'] = New-ClickTarget -TargetName 'footer:2' -PointX 308 -PointY ($footerY + 18) -RectX 253 -RectY $footerY -RectW 110 -RectH 36 `
            -Effect 'ReloadData(update: true): refresh the account list' -Expects 'none' -RequiresForce $false `
            -Notes 'safe; no persisted change expected' -Scale $Scale
    }
    return $map
}

function Get-OverlayClassification {
    param($Overlay, $Riot, $SettingsInfo, $AccountsInfo, [double]$Scale)
    $cls = [ordered]@{
        state = 'unknown'
        widthDip = $null
        heightDip = $null
        accountRows = $null
        accountCountFromVault = $null
        statusBlockDip = $null
        statusLines = $null
        footerYDip = $null
        expectedHeightDip = $null
        residualDip = $null
        confidence = 'none'
        heightCandidates = @()
        clickTargets = [ordered]@{}
        anchor = $null
        warnings = @()
    }
    if ($null -ne $AccountsInfo -and $AccountsInfo.readOk) { $cls.accountCountFromVault = $AccountsInfo.count }
    if ($null -eq $Overlay) { $cls.state = 'absent'; return $cls }
    $cls.anchor = Get-AnchorComparison -Riot $Riot -Overlay $Overlay -Scale $Scale -SettingsInfo $SettingsInfo
    if (-not $Overlay.visible -or $Overlay.rect.w -le 0 -or $Overlay.rect.h -le 0) {
        $cls.state = 'hidden'
        return $cls
    }
    $wDip = [Math]::Round(([double]$Overlay.rect.w / $Scale), 3)
    $hDip = [Math]::Round(([double]$Overlay.rect.h / $Scale), 3)
    $cls.widthDip = $wDip
    $cls.heightDip = $hDip
    if ([Math]::Abs($wDip - $script:DipCollapsedSize) -le 2.5 -and [Math]::Abs($hDip - $script:DipCollapsedSize) -le 2.5) {
        $cls.state = 'collapsed'
        $cls.accountRows = 0
        $cls.confidence = 'exact'
        $cls.clickTargets = New-ClickTargets -State 'collapsed' -FooterYDip $null -Scale $Scale
        return $cls
    }
    if ([Math]::Abs($wDip - $script:DipPanelWidth) -le 3.0) {
        $candidates = New-Object 'System.Collections.Generic.List[object]'
        for ($n = 0; $n -le 5; $n++) {
            $rows = [Math]::Min($n, 5)
            if ($n -eq 0) { $listH = 64 } else { $listH = $rows * 48 + [Math]::Max(0, $rows - 1) * 4 }
            $footerY = $script:DipListTop + $listH + 12
            foreach ($status in @(0, 24, 40)) {
                $total = $footerY + $script:DipFooterHeight + $status + 12 + 1
                $residual = [Math]::Round([Math]::Abs($total - $hDip), 3)
                $lines = 0
                if ($status -eq 24) { $lines = 1 } elseif ($status -eq 40) { $lines = 2 }
                $candidates.Add([ordered]@{
                    accountRows = $n
                    accountRowsVisible = $rows
                    accountCountCandidate = $n
                    statusBlockDip = $status
                    statusLines = $lines
                    footerYDip = [double]$footerY
                    expectedHeightDip = [double]$total
                    residualDip = $residual
                })
            }
        }
        $best = $null
        foreach ($c in $candidates) {
            if ($null -eq $best -or $c.residualDip -lt $best.residualDip) { $best = $c }
        }
        $sorted = @($candidates | Sort-Object -Property residualDip)
        $cls.heightCandidates = @($sorted | Select-Object -First 3)
        if ($best.residualDip -le 1.5) {
            $cls.state = 'expanded'
            $cls.accountRows = $best.accountRowsVisible
            $cls.statusBlockDip = [double]$best.statusBlockDip
            $cls.statusLines = [int]$best.statusLines
            $cls.footerYDip = [double]$best.footerYDip
            $cls.expectedHeightDip = [double]$best.expectedHeightDip
            $cls.residualDip = [double]$best.residualDip
            $confidence = 'approx'
            if ($best.residualDip -le 0.5) { $confidence = 'exact' }
            if ($null -ne $cls.accountCountFromVault) {
                $expectedRows = [Math]::Min([int]$cls.accountCountFromVault, 5)
                if ($best.accountRowsVisible -ne $expectedRows) {
                    $confidence = 'low'
                    $cls.warnings += ('height_matches_' + $best.accountRowsVisible + '_rows_but_vault_has_' + $cls.accountCountFromVault + '_accounts')
                }
            }
            $cls.confidence = $confidence
            $cls.clickTargets = New-ClickTargets -State 'expanded' -FooterYDip $cls.footerYDip -Scale $Scale
            return $cls
        }
        $cls.warnings += 'panel_height_does_not_match_known_layout'
        return $cls
    }
    $cls.warnings += 'overlay_size_does_not_match_40_or_380_dip_width'
    return $cls
}

function Get-ClassificationSummary {
    param($Classification)
    if ($null -eq $Classification) { return $null }
    return [ordered]@{
        state = $Classification.state
        widthDip = $Classification.widthDip
        heightDip = $Classification.heightDip
        accountRows = $Classification.accountRows
        statusBlockDip = $Classification.statusBlockDip
        statusLines = $Classification.statusLines
        footerYDip = $Classification.footerYDip
        confidence = $Classification.confidence
        residualDip = $Classification.residualDip
        anchorMatches = $(if ($null -ne $Classification.anchor) { $Classification.anchor.matches } else { $null })
    }
}

function Get-ClassificationNow {
    param($Ctx, [double]$Scale)
    $ov = Get-VisibleOverlayWindow
    return (Get-OverlayClassification -Overlay $ov -Riot $Ctx.riotWindow -SettingsInfo $Ctx.settings -AccountsInfo $Ctx.accounts -Scale $Scale)
}

function Get-PredictedOverlayRect {
    param(
        [int]$RiotX, [int]$RiotY, [int]$RiotW, [int]$RiotH,
        [double]$Scale, [int]$WidthPx, [int]$HeightPx,
        [double]$OffsetRightDip, [double]$OffsetTopDip
    )
    $margin = [int][Math]::Round($script:EdgeMarginDip * $Scale)
    $right = $RiotX + $RiotW
    $bottom = $RiotY + $RiotH
    $x = [int][Math]::Round(($right - ($OffsetRightDip * $Scale) - $WidthPx))
    $y = [int][Math]::Round(($RiotY + ($OffsetTopDip * $Scale)))
    $minX = $RiotX + $margin
    $maxX = $right - $WidthPx - $margin
    if ($maxX -lt $minX) { $maxX = $minX }
    $minY = $RiotY + $margin
    $maxY = $bottom - $HeightPx - $margin
    if ($maxY -lt $minY) { $maxY = $minY }
    $clampedX = $false
    $clampedY = $false
    if ($x -lt $minX) { $x = $minX; $clampedX = $true } elseif ($x -gt $maxX) { $x = $maxX; $clampedX = $true }
    if ($y -lt $minY) { $y = $minY; $clampedY = $true } elseif ($y -gt $maxY) { $y = $maxY; $clampedY = $true }
    return [ordered]@{ x = $x; y = $y; clampedX = $clampedX; clampedY = $clampedY }
}

function Get-OffsetsForPrediction {
    param($Riot, $Overlay, [double]$Scale, $SettingsInfo)
    $inferredRight = [Math]::Round(((([int]$Riot.rect.x + [int]$Riot.rect.w) - [int]$Overlay.rect.x - [int]$Overlay.rect.w) / $Scale), 3)
    $inferredTop = [Math]::Round((([int]$Overlay.rect.y - [int]$Riot.rect.y) / $Scale), 3)
    $right = [double]$inferredRight
    $top = [double]$inferredTop
    $source = 'inferred'
    $settingsOffsets = $null
    if ($null -ne $SettingsInfo -and $SettingsInfo.readOk -and $null -ne $SettingsInfo.overlayOffsetRightDip -and $null -ne $SettingsInfo.overlayOffsetTopDip) {
        $settingsOffsets = [ordered]@{ rightDip = [double]$SettingsInfo.overlayOffsetRightDip; topDip = [double]$SettingsInfo.overlayOffsetTopDip }
        $delta = [Math]::Abs([double]$SettingsInfo.overlayOffsetRightDip - $inferredRight) + [Math]::Abs([double]$SettingsInfo.overlayOffsetTopDip - $inferredTop)
        if ($delta -gt 1.0) {
            Add-Warning 'settings_offsets_differ_from_observed_overlay_position'
        } else {
            $right = [double]$SettingsInfo.overlayOffsetRightDip
            $top = [double]$SettingsInfo.overlayOffsetTopDip
            $source = 'settings'
        }
    }
    return [ordered]@{
        rightDip = $right
        topDip = $top
        source = $source
        inferred = [ordered]@{ rightDip = [double]$inferredRight; topDip = [double]$inferredTop }
        settings = $settingsOffsets
    }
}

# ---------------------------------------------------------------------------
# Environment snapshot + baseline helpers.
# ---------------------------------------------------------------------------

function Get-EnvironmentSnapshot {
    $riotWindows = @(Find-RiotWindows)
    $overlayWindows = @(Find-OverlayWindows)
    $riotSelected = $null
    foreach ($w in $riotWindows) { if ($w.appCriteriaOk) { $riotSelected = $w; break } }
    $riotReady = ($null -ne $riotSelected)
    if ($null -eq $riotSelected -and $riotWindows.Count -gt 0) { $riotSelected = $riotWindows[0] }
    $overlaySelected = $null
    foreach ($w in $overlayWindows) {
        if ($w.visible -and $w.rect.w -gt 0 -and $w.rect.h -gt 0) { $overlaySelected = $w; break }
    }
    if ($null -eq $overlaySelected -and $overlayWindows.Count -gt 0) { $overlaySelected = $overlayWindows[0] }
    $scale = 1.0
    $scaleSource = 'default_96dpi'
    if ($null -ne $riotSelected -and [int]$riotSelected.dpi -gt 0) {
        $scale = Get-ScaleFromDpi ([int]$riotSelected.dpi)
        $scaleSource = 'riot_client_dpi'
    } elseif ($null -ne $overlaySelected -and [int]$overlaySelected.dpi -gt 0) {
        $scale = Get-ScaleFromDpi ([int]$overlaySelected.dpi)
        $scaleSource = 'overlay_dpi'
    }
    $settings = Read-SettingsInfo
    $accounts = Read-AccountsInfo
    $baseline = Read-BaselineFile
    $classification = Get-OverlayClassification -Overlay $overlaySelected -Riot $riotSelected -SettingsInfo $settings -AccountsInfo $accounts -Scale $scale
    $overlayVisible = ($null -ne $overlaySelected) -and $overlaySelected.visible -and ($overlaySelected.rect.w -gt 0) -and ($overlaySelected.rect.h -gt 0)
    $expectation = 'unknown'
    if ($null -eq $riotSelected) {
        $expectation = 'riot_window_missing'
    } elseif (-not $riotReady) {
        if ($riotSelected.iconic) { $expectation = 'riot_minimized' } else { $expectation = 'riot_window_not_ready' }
    } elseif (-not $overlayVisible) {
        $expectation = 'overlay_not_created'
    } else {
        $expectation = 'overlay_visible'
    }
    return [ordered]@{
        riotWindow = $riotSelected
        riotWindows = $riotWindows
        overlayWindow = $overlaySelected
        overlayWindows = $overlayWindows
        scale = $scale
        scaleSource = $scaleSource
        settings = $settings
        accounts = $accounts
        baseline = $baseline
        classification = $classification
        riotReady = $riotReady
        overlayVisible = $overlayVisible
        overlayExpectation = $expectation
    }
}

function Ensure-Baseline {
    param($Ctx)
    if ($null -ne $Ctx.baseline -and $Ctx.baseline.exists) { return }
    if ($Ctx.riotReady -and $null -ne $Ctx.overlayWindow -and $Ctx.overlayWindow.visible) {
        $doc = Save-BaselineFile -RiotSnapshot $Ctx.riotWindow -OverlaySnapshot $Ctx.overlayWindow -Scale $Ctx.scale -SettingsInfo $Ctx.settings -OverlayState $Ctx.classification.state -Source 'auto-first-interactive'
        $Ctx.baseline = [ordered]@{ exists = $true; path = $script:BaselinePath; savedUtc = $doc.savedUtc; source = $doc.source; data = $doc; error = $null }
        Add-Warning 'baseline_auto_captured_before_first_interactive_action'
    } else {
        Add-Warning 'baseline_missing_capture_not_possible'
    }
}

function Get-StateDiagnosis {
    param($Ctx)
    $explanation = ''
    $hint = ''
    switch ($Ctx.overlayExpectation) {
        'riot_window_missing' { $explanation = 'No Riot Client top-level window was found.'; $hint = 'Start Riot Client / RiotSwitch, then run discover again.' }
        'riot_minimized' { $explanation = 'Riot Client is minimized. RiotSwitch disposes the overlay while the target window is not visible, so the overlay is absent by design.'; $hint = 'Run -Action foreground-riot -AllowInteraction to restore the Riot Client window and let the overlay reappear (campaign phase only).' }
        'riot_window_not_ready' { $explanation = 'A Riot Client window exists but does not satisfy the RiotSwitch tracker criteria (visible, not minimized, not cloaked, exact title, rect at least 1000x700).'; $hint = 'Check rejectionReasons of the riot window and restore it with -Action foreground-riot.' }
        'overlay_not_created' { $explanation = 'Riot Client is ready but no visible RiotSwitch overlay window exists.'; $hint = 'Run -Action wait-overlay -TimeoutMs 3000, or -Action foreground-riot -AllowInteraction.' }
        'overlay_visible' { $explanation = 'Riot Client and the RiotSwitch overlay are both present.'; $hint = '' }
        default { $explanation = 'Environment state could not be classified.'; $hint = 'Inspect windows/classification in this JSON output.' }
    }
    return [ordered]@{
        expectation = $Ctx.overlayExpectation
        explanation = $explanation
        hint = $hint
        riotReady = $Ctx.riotReady
        overlayVisible = $Ctx.overlayVisible
        scale = $Ctx.scale
        scaleSource = $Ctx.scaleSource
        overlayState = $Ctx.classification.state
    }
}

# ---------------------------------------------------------------------------
# Wait helpers (poll based, QPC measured).
# ---------------------------------------------------------------------------

function Wait-RiotWindowReady {
    param([IntPtr]$Hwnd, [int]$TimeoutMs, [int]$PollMs)
    $t0 = Get-QpcTicks
    while ($true) {
        $snap = New-WindowSnapshot $Hwnd
        if ($snap.valid -and $snap.visible -and -not $snap.iconic -and $snap.rect.w -ge 1000 -and $snap.rect.h -ge 700) {
            return [ordered]@{ ok = $true; elapsedMs = (Get-DeltaMs $t0 (Get-QpcTicks)); window = $snap }
        }
        if ((Get-DeltaMs $t0 (Get-QpcTicks)) -ge $TimeoutMs) {
            return [ordered]@{ ok = $false; elapsedMs = (Get-DeltaMs $t0 (Get-QpcTicks)); window = $snap }
        }
        Start-Sleep -Milliseconds $PollMs
    }
}

function Wait-ForegroundWindow {
    param([IntPtr]$Hwnd, [int]$TimeoutMs, [int]$PollMs)
    $t0 = Get-QpcTicks
    $target = $Hwnd.ToInt64()
    while ($true) {
        $fg = [RiotPerfNative]::GetForegroundWindow()
        if ($fg.ToInt64() -eq $target) {
            return [ordered]@{ ok = $true; elapsedMs = (Get-DeltaMs $t0 (Get-QpcTicks)); foreground = (Format-HexValue $fg) }
        }
        if ((Get-DeltaMs $t0 (Get-QpcTicks)) -ge $TimeoutMs) {
            return [ordered]@{ ok = $false; elapsedMs = (Get-DeltaMs $t0 (Get-QpcTicks)); foreground = (Format-HexValue $fg) }
        }
        Start-Sleep -Milliseconds $PollMs
    }
}

function Wait-OverlayVisible {
    param([int]$TimeoutMs, [int]$PollMs)
    $t0 = Get-QpcTicks
    while ($true) {
        $ov = Get-VisibleOverlayWindow
        if ($null -ne $ov) {
            return [ordered]@{ ok = $true; elapsedMs = (Get-DeltaMs $t0 (Get-QpcTicks)); window = $ov }
        }
        if ((Get-DeltaMs $t0 (Get-QpcTicks)) -ge $TimeoutMs) {
            return [ordered]@{ ok = $false; elapsedMs = (Get-DeltaMs $t0 (Get-QpcTicks)); window = $null }
        }
        Start-Sleep -Milliseconds $PollMs
    }
}

function Wait-OverlayState {
    param([double]$Scale, [string]$ExpectedState, [int]$TimeoutMs, [int]$PollMs)
    $t0 = Get-QpcTicks
    $lastState = 'absent'
    while ($true) {
        $ov = Get-VisibleOverlayWindow
        if ($null -ne $ov) {
            $cls = Get-OverlayClassification -Overlay $ov -Riot $null -SettingsInfo $null -AccountsInfo $null -Scale $Scale
            $lastState = $cls.state
            if ($cls.state -eq $ExpectedState) {
                return [ordered]@{ ok = $true; elapsedMs = (Get-DeltaMs $t0 (Get-QpcTicks)); state = $cls.state; window = $ov; classification = $cls }
            }
        } else {
            $lastState = 'absent'
        }
        if ((Get-DeltaMs $t0 (Get-QpcTicks)) -ge $TimeoutMs) {
            return [ordered]@{ ok = $false; elapsedMs = (Get-DeltaMs $t0 (Get-QpcTicks)); state = $lastState; window = $null; classification = $null }
        }
        Start-Sleep -Milliseconds $PollMs
    }
}

function Wait-OverlayRect {
    param([int]$ExpectedX, [int]$ExpectedY, [int]$TolerancePx, [int]$TimeoutMs, [int]$PollMs)
    $t0 = Get-QpcTicks
    $lastWindow = $null
    while ($true) {
        $ov = Get-VisibleOverlayWindow
        if ($null -ne $ov) {
            $lastWindow = $ov
            if ([Math]::Abs([int]$ov.rect.x - $ExpectedX) -le $TolerancePx -and [Math]::Abs([int]$ov.rect.y - $ExpectedY) -le $TolerancePx) {
                return [ordered]@{ ok = $true; elapsedMs = (Get-DeltaMs $t0 (Get-QpcTicks)); window = $ov }
            }
        }
        if ((Get-DeltaMs $t0 (Get-QpcTicks)) -ge $TimeoutMs) {
            return [ordered]@{ ok = $false; elapsedMs = (Get-DeltaMs $t0 (Get-QpcTicks)); window = $lastWindow }
        }
        Start-Sleep -Milliseconds $PollMs
    }
}

function Wait-RiotRect {
    param([IntPtr]$Hwnd, [int]$ExpectedX, [int]$ExpectedY, [int]$TolerancePx, [int]$TimeoutMs, [int]$PollMs)
    $t0 = Get-QpcTicks
    $last = $null
    while ($true) {
        $snap = New-WindowSnapshot $Hwnd
        $last = $snap
        if ([Math]::Abs([int]$snap.rect.x - $ExpectedX) -le $TolerancePx -and [Math]::Abs([int]$snap.rect.y - $ExpectedY) -le $TolerancePx) {
            return [ordered]@{ ok = $true; elapsedMs = (Get-DeltaMs $t0 (Get-QpcTicks)); window = $snap }
        }
        if ((Get-DeltaMs $t0 (Get-QpcTicks)) -ge $TimeoutMs) {
            return [ordered]@{ ok = $false; elapsedMs = (Get-DeltaMs $t0 (Get-QpcTicks)); window = $last }
        }
        Start-Sleep -Milliseconds $PollMs
    }
}

function Wait-WindowGone {
    param([IntPtr]$Hwnd, [int]$TimeoutMs, [int]$PollMs)
    $t0 = Get-QpcTicks
    $target = $Hwnd.ToInt64()
    while ($true) {
        $still = $false
        foreach ($h in [RiotPerfNative]::TopLevelWindows()) {
            if ($h.ToInt64() -eq $target) { $still = $true; break }
        }
        if (-not $still) {
            return [ordered]@{ ok = $true; elapsedMs = (Get-DeltaMs $t0 (Get-QpcTicks)) }
        }
        if ((Get-DeltaMs $t0 (Get-QpcTicks)) -ge $TimeoutMs) {
            return [ordered]@{ ok = $false; elapsedMs = (Get-DeltaMs $t0 (Get-QpcTicks)) }
        }
        Start-Sleep -Milliseconds $PollMs
    }
}

function Wait-PinState {
    param([bool]$ExpectedPinned, [int]$TimeoutMs, [int]$PollMs)
    $t0 = Get-QpcTicks
    $last = $null
    while ($true) {
        $s = Read-SettingsInfo
        if ($s.readOk -and $null -ne $s.overlayPinned) {
            $last = [bool]$s.overlayPinned
            if ($last -eq $ExpectedPinned) {
                return [ordered]@{ ok = $true; elapsedMs = (Get-DeltaMs $t0 (Get-QpcTicks)); pinned = $last }
            }
        }
        if ((Get-DeltaMs $t0 (Get-QpcTicks)) -ge $TimeoutMs) {
            return [ordered]@{ ok = $false; elapsedMs = (Get-DeltaMs $t0 (Get-QpcTicks)); pinned = $last }
        }
        Start-Sleep -Milliseconds $PollMs
    }
}

function Wait-SettingsDialog {
    param([int]$TimeoutMs, [int]$PollMs)
    $t0 = Get-QpcTicks
    while ($true) {
        $dlg = Find-SettingsDialog
        if ($null -ne $dlg) {
            return [ordered]@{ ok = $true; elapsedMs = (Get-DeltaMs $t0 (Get-QpcTicks)); window = $dlg }
        }
        if ((Get-DeltaMs $t0 (Get-QpcTicks)) -ge $TimeoutMs) {
            return [ordered]@{ ok = $false; elapsedMs = (Get-DeltaMs $t0 (Get-QpcTicks)); window = $null }
        }
        Start-Sleep -Milliseconds $PollMs
    }
}

# ---------------------------------------------------------------------------
# Synthetic mouse messages.
# ---------------------------------------------------------------------------

function Send-ClickAt {
    param([IntPtr]$Hwnd, [int]$X, [int]$Y, [int]$PressHoldMs, [bool]$TimeoutUp, [int]$UpTimeoutMs)
    $lat = [ordered]@{
        moveMs = 0.0
        downMs = 0.0
        upMs = 0.0
        upTimedOut = $false
        pressHoldMs = $PressHoldMs
    }
    $lp = [RiotPerfNative]::MakeLParam($X, $Y)
    $t = Get-QpcTicks
    [void][RiotPerfNative]::SendMessage($Hwnd, [uint32]$script:WM_MOUSEMOVE, [IntPtr]::Zero, $lp)
    $lat['moveMs'] = Get-DeltaMs $t (Get-QpcTicks)
    $t = Get-QpcTicks
    [void][RiotPerfNative]::SendMessage($Hwnd, [uint32]$script:WM_LBUTTONDOWN, [RiotPerfNative]::Ptr(1), $lp)
    $lat['downMs'] = Get-DeltaMs $t (Get-QpcTicks)
    if ($PressHoldMs -gt 0) { Start-Sleep -Milliseconds $PressHoldMs }
    $t = Get-QpcTicks
    if ($TimeoutUp) {
        $out = [IntPtr]::Zero
        $res = [RiotPerfNative]::SendMessageTimeout($Hwnd, [uint32]$script:WM_LBUTTONUP, [IntPtr]::Zero, $lp, 0x0002, [uint32]$UpTimeoutMs, [ref]$out)
        $lat['upMs'] = Get-DeltaMs $t (Get-QpcTicks)
        if ($res -eq [IntPtr]::Zero) { $lat['upTimedOut'] = $true }
    } else {
        [void][RiotPerfNative]::SendMessage($Hwnd, [uint32]$script:WM_LBUTTONUP, [IntPtr]::Zero, $lp)
        $lat['upMs'] = Get-DeltaMs $t (Get-QpcTicks)
    }
    return $lat
}

function Send-MouseMoveAt {
    param([IntPtr]$Hwnd, [int]$X, [int]$Y)
    $lp = [RiotPerfNative]::MakeLParam($X, $Y)
    $t = Get-QpcTicks
    [void][RiotPerfNative]::SendMessage($Hwnd, [uint32]$script:WM_MOUSEMOVE, [IntPtr]::Zero, $lp)
    return (Get-DeltaMs $t (Get-QpcTicks))
}

function Send-MouseLeave {
    param([IntPtr]$Hwnd)
    $t = Get-QpcTicks
    $out = [IntPtr]::Zero
    [void][RiotPerfNative]::SendMessageTimeout($Hwnd, [uint32]$script:WM_MOUSELEAVE, [IntPtr]::Zero, [IntPtr]::Zero, 0x0002, 500, [ref]$out)
    return (Get-DeltaMs $t (Get-QpcTicks))
}

function Send-WheelAt {
    param([IntPtr]$Hwnd, [int]$Delta, [int]$ScreenX, [int]$ScreenY)
    $wp = [RiotPerfNative]::PackWheelWParam($Delta)
    $lp = [RiotPerfNative]::MakeLParam($ScreenX, $ScreenY)
    $t = Get-QpcTicks
    [void][RiotPerfNative]::SendMessage($Hwnd, [uint32]$script:WM_MOUSEWHEEL, $wp, $lp)
    return (Get-DeltaMs $t (Get-QpcTicks))
}

function Normalize-Target {
    param([string]$TargetText)
    if ([string]::IsNullOrWhiteSpace($TargetText)) {
        Throw-DriverFault 'invalid_args' 'Missing -Target. Valid values: collapsed | close | pin | settings | header | footer:0 | footer:1 | footer:2' $null
    }
    $t = $TargetText.Trim().ToLowerInvariant()
    switch ($t) {
        'collapsed' { return 'collapsed' }
        'close' { return 'close' }
        'pin' { return 'pin' }
        'header' { return 'header' }
        'settings' { return 'settings' }
        'footer:0' { return 'footer:0' }
        'footer:1' { return 'footer:1' }
        'footer:2' { return 'footer:2' }
        'add' { return 'footer:0' }
        'refresh' { return 'footer:2' }
        'footer:add' { return 'footer:0' }
        'footer:settings' { return 'footer:1' }
        'footer:refresh' { return 'footer:2' }
        default {
            Throw-DriverFault 'invalid_args' ("Unknown -Target '" + $TargetText + "'.") ([ordered]@{ validTargets = @('collapsed', 'close', 'pin', 'settings', 'header', 'footer:0', 'footer:1', 'footer:2') })
        }
    }
}

function Resolve-ClickTarget {
    param($Ctx, [string]$TargetText)
    $normalized = Normalize-Target $TargetText
    $cls = $Ctx.classification
    if ($normalized -eq 'collapsed') {
        if ($cls.state -ne 'collapsed') {
            Throw-DriverFault 'invalid_state' ("-Target collapsed requires a collapsed overlay (current state: " + $cls.state + ").") ([ordered]@{ currentState = $cls.state })
        }
        $entry = $cls.clickTargets['collapsed']
        return [ordered]@{ normalized = $normalized; entry = $entry }
    }
    if ($normalized -eq 'close') {
        if ($cls.state -ne 'expanded') {
            Throw-DriverFault 'invalid_state' ("-Target close requires an expanded overlay (current state: " + $cls.state + ").") ([ordered]@{ currentState = $cls.state })
        }
        $entry = $cls.clickTargets['close']
        return [ordered]@{ normalized = $normalized; entry = $entry }
    }
    if ($cls.state -ne 'expanded') {
        Throw-DriverFault 'invalid_state' ("-Target " + $normalized + " requires an expanded overlay (current state: " + $cls.state + ").") ([ordered]@{ currentState = $cls.state })
    }
    $entry = $cls.clickTargets[$normalized]
    if ($null -eq $entry) {
        Throw-DriverFault 'invalid_target' ("Target '" + $normalized + "' is not available for the current classification (footerY=" + $cls.footerYDip + ", confidence=" + $cls.confidence + ").") ([ordered]@{ state = $cls.state; footerYDip = $cls.footerYDip; confidence = $cls.confidence })
    }
    return [ordered]@{ normalized = $normalized; entry = $entry }
}

function Assert-ClickPointInsideClient {
    param($Overlay, $PointPx)
    $cw = [int]$Overlay.client.w
    $ch = [int]$Overlay.client.h
    if ($PointPx.x -lt 0 -or $PointPx.y -lt 0 -or $PointPx.x -ge $cw -or $PointPx.y -ge $ch) {
        Throw-DriverFault 'click_point_outside_overlay' 'Computed click point is outside the overlay client rect.' ([ordered]@{ pointPx = $PointPx; client = [ordered]@{ w = $cw; h = $ch } })
    }
}

function Get-OverlayForAction {
    param($Ctx)
    $ov = Get-VisibleOverlayWindow
    if ($null -eq $ov) {
        Throw-DriverFault 'overlay_not_found' 'No visible RiotSwitch overlay window was found.' ([ordered]@{ expectation = $Ctx.overlayExpectation; hint = 'Run -Action foreground-riot -AllowInteraction first (campaign phase) or -Action wait-overlay.' })
    }
    return $ov
}

# ---------------------------------------------------------------------------
# Overlay state transitions (used by expand/collapse/toggle/click/restore).
# ---------------------------------------------------------------------------

function Invoke-ExpandOverlay {
    param($Ctx, [int]$PressMs, [int]$TimeoutMs)
    $ov = Get-OverlayForAction $Ctx
    $cls = Get-OverlayClassification -Overlay $ov -Riot $Ctx.riotWindow -SettingsInfo $Ctx.settings -AccountsInfo $Ctx.accounts -Scale $Ctx.scale
    if ($cls.state -eq 'expanded') {
        return [ordered]@{ performed = $false; reason = 'already_expanded'; latencies = $null; transition = $null; post = (Get-ClassificationSummary $cls); pointPx = $null }
    }
    if ($cls.state -ne 'collapsed') {
        Throw-DriverFault 'overlay_state_unknown' ("Cannot expand: overlay classification is '" + $cls.state + "'.") ([ordered]@{ classification = (Get-ClassificationSummary $cls) })
    }
    Ensure-Baseline $Ctx
    $point = New-PointPx 20 20 $Ctx.scale
    Assert-ClickPointInsideClient -Overlay $ov -PointPx $point
    $lat = Send-ClickAt -Hwnd $ov.__hwnd -X $point.x -Y $point.y -PressHoldMs $PressMs -TimeoutUp $false -UpTimeoutMs 0
    $wait = Wait-OverlayState -Scale $Ctx.scale -ExpectedState 'expanded' -TimeoutMs $TimeoutMs -PollMs 8
    if (-not $wait.ok) {
        Throw-DriverFault 'transition_not_observed' 'Click on the collapsed overlay did not expand the panel.' ([ordered]@{ expected = 'expanded'; observedState = $wait.state; elapsedMs = $wait.elapsedMs; latencies = $lat; pointPx = $point })
    }
    $post = Get-ClassificationNow $Ctx $Ctx.scale
    return [ordered]@{ performed = $true; reason = $null; latencies = $lat; transition = [ordered]@{ expected = 'expanded'; observed = $wait.state; elapsedMs = $wait.elapsedMs }; post = (Get-ClassificationSummary $post); pointPx = $point; postClassification = $post }
}

function Invoke-CollapseOverlay {
    param($Ctx, [int]$PressMs, [int]$TimeoutMs)
    $ov = Get-OverlayForAction $Ctx
    $cls = Get-OverlayClassification -Overlay $ov -Riot $Ctx.riotWindow -SettingsInfo $Ctx.settings -AccountsInfo $Ctx.accounts -Scale $Ctx.scale
    if ($cls.state -eq 'collapsed') {
        return [ordered]@{ performed = $false; reason = 'already_collapsed'; latencies = $null; transition = $null; post = (Get-ClassificationSummary $cls); pointPx = $null }
    }
    if ($cls.state -ne 'expanded') {
        Throw-DriverFault 'overlay_state_unknown' ("Cannot collapse: overlay classification is '" + $cls.state + "'.") ([ordered]@{ classification = (Get-ClassificationSummary $cls) })
    }
    Ensure-Baseline $Ctx
    $entry = $cls.clickTargets['close']
    $point = $entry.pointPx
    Assert-ClickPointInsideClient -Overlay $ov -PointPx $point
    $lat = Send-ClickAt -Hwnd $ov.__hwnd -X $point.x -Y $point.y -PressHoldMs $PressMs -TimeoutUp $false -UpTimeoutMs 0
    $wait = Wait-OverlayState -Scale $Ctx.scale -ExpectedState 'collapsed' -TimeoutMs $TimeoutMs -PollMs 8
    if (-not $wait.ok) {
        Throw-DriverFault 'transition_not_observed' 'Click on the overlay close button did not collapse the panel.' ([ordered]@{ expected = 'collapsed'; observedState = $wait.state; elapsedMs = $wait.elapsedMs; latencies = $lat; pointPx = $point })
    }
    $post = Get-ClassificationNow $Ctx $Ctx.scale
    return [ordered]@{ performed = $true; reason = $null; latencies = $lat; transition = [ordered]@{ expected = 'collapsed'; observed = $wait.state; elapsedMs = $wait.elapsedMs }; post = (Get-ClassificationSummary $post); pointPx = $point; postClassification = $post }
}

function Invoke-PinToggle {
    param($Ctx, [int]$PressMs, [bool]$ExpectedPinned)
    $ov = Get-OverlayForAction $Ctx
    $cls = Get-OverlayClassification -Overlay $ov -Riot $Ctx.riotWindow -SettingsInfo $Ctx.settings -AccountsInfo $Ctx.accounts -Scale $Ctx.scale
    if ($cls.state -ne 'expanded') {
        Throw-DriverFault 'invalid_state' ("Pin target requires an expanded overlay (current state: " + $cls.state + ").") ([ordered]@{ currentState = $cls.state })
    }
    Ensure-Baseline $Ctx
    $entry = $cls.clickTargets['pin']
    $point = $entry.pointPx
    Assert-ClickPointInsideClient -Overlay $ov -PointPx $point
    $pre = Read-SettingsInfo
    $lat = Send-ClickAt -Hwnd $ov.__hwnd -X $point.x -Y $point.y -PressHoldMs $PressMs -TimeoutUp $false -UpTimeoutMs 0
    $wait = [ordered]@{ ok = $false; elapsedMs = 0.0; pinned = $null }
    if ($pre.readOk -and $null -ne $pre.overlayPinned) {
        $wait = Wait-PinState -ExpectedPinned $ExpectedPinned -TimeoutMs 1500 -PollMs 20
    }
    $post = Get-ClassificationNow $Ctx $Ctx.scale
    $postSettings = Read-SettingsInfo
    return [ordered]@{
        performed = $true
        pointPx = $point
        latencies = $lat
        prePinned = $pre.overlayPinned
        expectedPinned = $ExpectedPinned
        observedPinned = $wait.pinned
        verified = $wait.ok
        verifyWaitMs = $wait.elapsedMs
        post = (Get-ClassificationSummary $post)
        settingsAfter = [ordered]@{ overlayPinned = $postSettings.overlayPinned; readOk = $postSettings.readOk }
    }
}

# ---------------------------------------------------------------------------
# Actions.
# ---------------------------------------------------------------------------

function Invoke-DiscoverAction {
    param($Ctx)
    if ($null -eq $Ctx.riotWindow) {
        Throw-DriverFault 'riot_window_not_found' 'No top-level window matching Riot Client (title + process) was found.' ([ordered]@{ riotProcessIds = @(Get-RiotProcessIds) })
    }
    if (-not $Ctx.riotReady) {
        $reasons = @($Ctx.riotWindow.rejectionReasons)
        Throw-DriverFault 'riot_window_not_ready' ('Riot Client window found but it does not satisfy the RiotSwitch tracker criteria: ' + ($reasons -join ', ') + '.') ([ordered]@{ rejectionReasons = $reasons; iconic = $Ctx.riotWindow.iconic; rect = $Ctx.riotWindow.rect; hint = 'Run -Action foreground-riot -AllowInteraction to restore the window (campaign phase only).' })
    }
    if (-not $Ctx.overlayVisible) {
        Throw-DriverFault 'overlay_not_found' 'Riot Client is ready but no visible RiotSwitch overlay window exists.' ([ordered]@{ hint = 'Run -Action foreground-riot -AllowInteraction (campaign phase) then discover again.'; overlayCandidates = $Ctx.overlayWindows })
    }
    return [ordered]@{
        ready = $true
        riotHwnd = $Ctx.riotWindow.hwnd
        overlayHwnd = $Ctx.overlayWindow.hwnd
        overlayState = $Ctx.classification.state
        scale = $Ctx.scale
        scaleSource = $Ctx.scaleSource
        note = 'All interactions use synthetic window messages; the physical mouse cursor and keyboard focus are not moved.'
    }
}

function Invoke-StateAction {
    param($Ctx, [bool]$SaveBaselineRequested)
    if ($null -eq $Ctx.riotWindow) {
        Throw-DriverFault 'riot_window_not_found' 'No top-level window matching Riot Client (title + process) was found.' ([ordered]@{ riotProcessIds = @(Get-RiotProcessIds) })
    }
    $result = [ordered]@{
        ready = ($Ctx.riotReady -and $Ctx.overlayVisible)
        riotReady = $Ctx.riotReady
        overlayVisible = $Ctx.overlayVisible
        diagnosis = (Get-StateDiagnosis $Ctx)
        clickTargets = $Ctx.classification.clickTargets
        anchor = $Ctx.classification.anchor
        classificationWarnings = $Ctx.classification.warnings
        baseline = [ordered]@{ exists = $Ctx.baseline.exists; path = $Ctx.baseline.path; savedUtc = $Ctx.baseline.savedUtc; source = $Ctx.baseline.source }
        settingsReadOnly = $Ctx.settings
        accountsReadOnly = $Ctx.accounts
    }
    if ($SaveBaselineRequested) {
        if (-not $Ctx.riotReady) {
            Throw-DriverFault 'baseline_capture_failed' 'Cannot save baseline: Riot Client window is not ready.' ([ordered]@{ rejectionReasons = @($Ctx.riotWindow.rejectionReasons) })
        }
        if ($Ctx.baseline.exists) { Add-Warning 'baseline_overwritten' }
        $doc = Save-BaselineFile -RiotSnapshot $Ctx.riotWindow -OverlaySnapshot $Ctx.overlayWindow -Scale $Ctx.scale -SettingsInfo $Ctx.settings -OverlayState $Ctx.classification.state -Source 'manual-state'
        if (-not $Ctx.overlayVisible) { Add-Warning 'baseline_saved_without_visible_overlay' }
        $result['baselineSaved'] = [ordered]@{ path = $script:BaselinePath; savedUtc = $doc.savedUtc; source = $doc.source; overlayState = $Ctx.classification.state }
    }
    return $result
}

function Invoke-ForegroundRiotAction {
    param($Ctx, [int]$TimeoutMs, [int]$PressMs)
    if ($null -eq $Ctx.riotWindow) {
        Throw-DriverFault 'riot_window_not_found' 'No top-level window matching Riot Client (title + process) was found.' ([ordered]@{ riotProcessIds = @(Get-RiotProcessIds) })
    }
    $hwnd = $Ctx.riotWindow.__hwnd
    $lat = [ordered]@{ restoreFromMinimizedMs = 0.0; foregroundCallMs = 0.0; foregroundObservedMs = 0.0; overlayAppearMs = 0.0 }
    $pre = New-WindowSnapshot $hwnd
    $restoreNeeded = [bool]$pre.iconic
    if ($restoreNeeded) {
        $t = Get-QpcTicks
        [void][RiotPerfNative]::ShowWindow($hwnd, 9)
        $lat['showWindowRestoreCallMs'] = Get-DeltaMs $t (Get-QpcTicks)
        $readyWait = Wait-RiotWindowReady -Hwnd $hwnd -TimeoutMs 3000 -PollMs 10
        $lat['restoreFromMinimizedMs'] = $readyWait.elapsedMs
        if (-not $readyWait.ok) {
            Throw-DriverFault 'riot_restore_timeout' 'ShowWindow(SW_RESTORE) did not bring the Riot Client window back to a normal visible state.' ([ordered]@{ window = $readyWait.window; latencies = $lat })
        }
    }
    $postRestore = New-WindowSnapshot $hwnd
    $reasons = @(Get-RiotCriteriaReasons $postRestore)
    if ($reasons.Count -gt 0) {
        Throw-DriverFault 'riot_window_not_ready' ('Riot Client window still does not satisfy the tracker criteria after restore: ' + ($reasons -join ', ') + '.') ([ordered]@{ rejectionReasons = $reasons; window = $postRestore })
    }
    $alreadyForeground = $false
    $fgBefore = [RiotPerfNative]::GetForegroundWindow()
    if ($fgBefore.ToInt64() -ne $hwnd.ToInt64()) {
        $t = Get-QpcTicks
        $okFg = [RiotPerfNative]::ForceForeground($hwnd)
        $lat['foregroundCallMs'] = Get-DeltaMs $t (Get-QpcTicks)
        $fgWait = Wait-ForegroundWindow -Hwnd $hwnd -TimeoutMs 1500 -PollMs 10
        $lat['foregroundObservedMs'] = $fgWait.elapsedMs
        if (-not $fgWait.ok) { Add-Warning 'foreground_not_observed' }
    } else {
        $alreadyForeground = $true
    }
    $ovWait = Wait-OverlayVisible -TimeoutMs $TimeoutMs -PollMs 20
    $lat['overlayAppearMs'] = $ovWait.elapsedMs
    if (-not $ovWait.ok) {
        Throw-DriverFault 'overlay_timeout' ("Riot Client is ready but the RiotSwitch overlay did not appear within " + $TimeoutMs + " ms.") ([ordered]@{ timeoutMs = $TimeoutMs; latencies = $lat; hint = 'Check RiotSwitch.exe is running; then retry or run -Action wait-overlay.' })
    }
    $finalRiot = New-WindowSnapshot $hwnd
    $ov = Get-VisibleOverlayWindow
    $cls = Get-OverlayClassification -Overlay $ov -Riot $finalRiot -SettingsInfo $Ctx.settings -AccountsInfo $Ctx.accounts -Scale $Ctx.scale
    if ($cls.state -ne 'collapsed') { Add-Warning ('overlay_state_after_foreground_' + $cls.state) }
    $baselineInfo = [ordered]@{ savedNow = $false; path = $script:BaselinePath; savedUtc = $Ctx.baseline.savedUtc; source = $Ctx.baseline.source }
    if (-not $Ctx.baseline.exists) {
        $doc = Save-BaselineFile -RiotSnapshot $finalRiot -OverlaySnapshot $ov -Scale $Ctx.scale -SettingsInfo $Ctx.settings -OverlayState $cls.state -Source 'foreground-riot'
        $baselineInfo = [ordered]@{ savedNow = $true; path = $script:BaselinePath; savedUtc = $doc.savedUtc; source = $doc.source }
        Add-Warning 'baseline_captured_after_foreground'
    }
    return [ordered]@{
        alreadyForeground = $alreadyForeground
        restoreNeeded = $restoreNeeded
        latencies = $lat
        riot = [ordered]@{ hwnd = $finalRiot.hwnd; pid = $finalRiot.pid; rect = $finalRiot.rect; iconic = $finalRiot.iconic; visible = $finalRiot.visible; zoomed = $finalRiot.zoomed; dpi = $finalRiot.dpi }
        overlay = [ordered]@{ hwnd = $ov.hwnd; rect = $ov.rect; state = $cls.state; widthDip = $cls.widthDip; heightDip = $cls.heightDip }
        anchor = $cls.anchor
        baseline = $baselineInfo
    }
}

function Invoke-WaitOverlayAction {
    param($Ctx, [int]$TimeoutMs)
    $ovWait = Wait-OverlayVisible -TimeoutMs $TimeoutMs -PollMs 20
    if (-not $ovWait.ok) {
        Throw-DriverFault 'overlay_timeout' ("RiotSwitch overlay did not appear within " + $TimeoutMs + " ms.") ([ordered]@{ timeoutMs = $TimeoutMs; expectation = $Ctx.overlayExpectation; hint = 'If Riot Client is minimized, run -Action foreground-riot -AllowInteraction first.' })
    }
    $cls = Get-OverlayClassification -Overlay $ovWait.window -Riot $Ctx.riotWindow -SettingsInfo $Ctx.settings -AccountsInfo $Ctx.accounts -Scale $Ctx.scale
    return [ordered]@{
        found = $true
        elapsedMs = $ovWait.elapsedMs
        overlayHwnd = $ovWait.window.hwnd
        overlayState = $cls.state
        classification = (Get-ClassificationSummary $cls)
    }
}

function Invoke-ClickAction {
    param($Ctx, [string]$TargetText, [int]$PressMs)
    $ov = Get-OverlayForAction $Ctx
    $cls = Get-OverlayClassification -Overlay $ov -Riot $Ctx.riotWindow -SettingsInfo $Ctx.settings -AccountsInfo $Ctx.accounts -Scale $Ctx.scale
    $normalized = Normalize-Target $TargetText
    if ($normalized -eq 'collapsed') {
        $r = Invoke-ExpandOverlay $Ctx $PressMs 1500
        $entry = $cls.clickTargets['collapsed']
        return [ordered]@{
            target = $normalized
            performed = $r.performed
            alreadyInTargetState = (-not $r.performed)
            pointDip = $entry.pointDip
            pointPx = $r.pointPx
            latencies = $r.latencies
            transition = $r.transition
            post = $r.post
        }
    }
    if ($normalized -eq 'close') {
        $r = Invoke-CollapseOverlay $Ctx $PressMs 1500
        $entry = $cls.clickTargets['close']
        return [ordered]@{
            target = $normalized
            performed = $r.performed
            alreadyInTargetState = (-not $r.performed)
            pointDip = $entry.pointDip
            pointPx = $r.pointPx
            latencies = $r.latencies
            transition = $r.transition
            post = $r.post
        }
    }
    if ($cls.state -ne 'expanded') {
        Throw-DriverFault 'invalid_state' ("-Target " + $normalized + " requires an expanded overlay (current state: " + $cls.state + ").") ([ordered]@{ currentState = $cls.state })
    }
    $entry = $cls.clickTargets[$normalized]
    if ($null -eq $entry) {
        Throw-DriverFault 'invalid_target' ("Target '" + $normalized + "' is not available for the current classification.") ([ordered]@{ state = $cls.state; footerYDip = $cls.footerYDip; confidence = $cls.confidence })
    }
    if ($entry.requiresForce -and -not $script:ForceFlag) {
        Throw-DriverFault 'force_required' ("Target '" + $normalized + "' changes the account vault and requires -Force in addition to -AllowInteraction.") ([ordered]@{ target = $normalized })
    }
    Ensure-Baseline $Ctx
    $point = $entry.pointPx
    Assert-ClickPointInsideClient -Overlay $ov -PointPx $point
    if ($normalized -eq 'pin') {
        $preSettings = Read-SettingsInfo
        $expectedPinned = $true
        if ($preSettings.readOk -and $null -ne $preSettings.overlayPinned) { $expectedPinned = -not [bool]$preSettings.overlayPinned }
        $r = Invoke-PinToggle $Ctx $PressMs $expectedPinned
        return [ordered]@{
            target = $normalized
            performed = $true
            pointDip = $entry.pointDip
            pointPx = $point
            latencies = $r.latencies
            transition = [ordered]@{ expected = 'pin_toggled'; observedPinned = $r.observedPinned; verified = $r.verified; elapsedMs = $r.verifyWaitMs }
            prePinned = $r.prePinned
            settingsAfter = $r.settingsAfter
            post = $r.post
        }
    }
    $timeoutUp = ($normalized -eq 'settings' -or $normalized -like 'footer:*')
    $upTimeoutMs = 2000
    $lat = Send-ClickAt -Hwnd $ov.__hwnd -X $point.x -Y $point.y -PressHoldMs $PressMs -TimeoutUp $timeoutUp -UpTimeoutMs $upTimeoutMs
    $transition = [ordered]@{ expected = $entry.expects; observed = $null; verified = $null; elapsedMs = $null }
    if ($normalized -eq 'settings' -or $normalized -eq 'footer:1') {
        $dlgWait = Wait-SettingsDialog -TimeoutMs 2500 -PollMs 25
        $transition['verified'] = $dlgWait.ok
        $transition['elapsedMs'] = $dlgWait.elapsedMs
        if ($dlgWait.ok) {
            $transition['observed'] = 'settings_dialog'
            $transition['settingsDialog'] = [ordered]@{ hwnd = $dlgWait.window.hwnd; title = $dlgWait.window.title; rect = $dlgWait.window.rect; pid = $dlgWait.window.pid }
            Add-Warning 'modal_settings_dialog_opened'
        } else {
            Throw-DriverFault 'transition_not_observed' 'Click on the settings footer button did not open the SettingsForm dialog.' ([ordered]@{ target = $normalized; latencies = $lat; upTimedOut = $lat.upTimedOut; hint = 'The overlay may be busy (account switch) or the click target changed.' })
        }
    } elseif ($normalized -eq 'footer:2') {
        $transition['observed'] = 'refresh_reloaddata'
        $transition['verified'] = $true
    } elseif ($normalized -eq 'footer:0') {
        $transition['observed'] = 'capture_current'
        $transition['verified'] = $null
        Add-Warning 'footer_add_is_destructive_and_not_reversible_by_restore'
    } else {
        $transition['observed'] = 'none'
        $transition['verified'] = $true
    }
    if ($lat.upTimedOut) { Add-Warning 'mouse_up_handler_did_not_return_before_timeout' }
    $postCls = Get-ClassificationNow $Ctx $Ctx.scale
    $postSettings = Read-SettingsInfo
    return [ordered]@{
        target = $normalized
        performed = $true
        pointDip = $entry.pointDip
        pointPx = $point
        latencies = $lat
        transition = $transition
        pre = [ordered]@{ state = $cls.state; heightDip = $cls.heightDip; footerYDip = $cls.footerYDip; confidence = $cls.confidence; pinned = $Ctx.settings.overlayPinned }
        post = (Get-ClassificationSummary $postCls)
        settingsAfter = [ordered]@{ overlayPinned = $postSettings.overlayPinned; readOk = $postSettings.readOk }
    }
}

function Invoke-ExpandAction {
    param($Ctx, [int]$PressMs)
    $r = Invoke-ExpandOverlay $Ctx $PressMs 1500
    return [ordered]@{
        performed = $r.performed
        alreadyExpanded = (-not $r.performed)
        latencies = $r.latencies
        transition = $r.transition
        post = $r.post
    }
}

function Invoke-CollapseAction {
    param($Ctx, [int]$PressMs)
    $r = Invoke-CollapseOverlay $Ctx $PressMs 1500
    return [ordered]@{
        performed = $r.performed
        alreadyCollapsed = (-not $r.performed)
        latencies = $r.latencies
        transition = $r.transition
        post = $r.post
    }
}

function Invoke-ToggleAction {
    param($Ctx, [int]$PressMs)
    $ov = Get-OverlayForAction $Ctx
    $cls = Get-OverlayClassification -Overlay $ov -Riot $Ctx.riotWindow -SettingsInfo $Ctx.settings -AccountsInfo $Ctx.accounts -Scale $Ctx.scale
    if ($cls.state -eq 'collapsed') {
        $r = Invoke-ExpandOverlay $Ctx $PressMs 1500
        return [ordered]@{ direction = 'expanded'; performed = $r.performed; latencies = $r.latencies; transition = $r.transition; post = $r.post }
    }
    if ($cls.state -eq 'expanded') {
        $r = Invoke-CollapseOverlay $Ctx $PressMs 1500
        return [ordered]@{ direction = 'collapsed'; performed = $r.performed; latencies = $r.latencies; transition = $r.transition; post = $r.post }
    }
    Throw-DriverFault 'overlay_state_unknown' ("Cannot toggle: overlay classification is '" + $cls.state + "'.") ([ordered]@{ classification = (Get-ClassificationSummary $cls) })
}

function Invoke-MoveRiotAction {
    param($Ctx, [int]$DxValue, [int]$DyValue, [int]$StepCount, [int]$PressMs)
    $ov = Get-OverlayForAction $Ctx
    if (-not $Ctx.riotReady) {
        Throw-DriverFault 'riot_window_not_ready' 'move-riot requires a ready Riot Client window (run -Action foreground-riot first).' ([ordered]@{ rejectionReasons = @($Ctx.riotWindow.rejectionReasons) })
    }
    if ($DxValue -eq 0 -and $DyValue -eq 0) {
        Throw-DriverFault 'invalid_args' 'move-riot requires a non-zero -Dx or -Dy.' $null
    }
    $riotHwnd = $Ctx.riotWindow.__hwnd
    $startRiot = New-WindowSnapshot $riotHwnd
    $cls = Get-OverlayClassification -Overlay $ov -Riot $startRiot -SettingsInfo $Ctx.settings -AccountsInfo $Ctx.accounts -Scale $Ctx.scale
    if ($cls.state -ne 'collapsed' -and $cls.state -ne 'expanded') {
        Throw-DriverFault 'overlay_state_unknown' ("move-riot requires a classified overlay (current: " + $cls.state + ").") ([ordered]@{ classification = (Get-ClassificationSummary $cls) })
    }
    Ensure-Baseline $Ctx
    $panelW = [int]$ov.rect.w
    $panelH = [int]$ov.rect.h
    $offsets = Get-OffsetsForPrediction -Riot $startRiot -Overlay $ov -Scale $Ctx.scale -SettingsInfo $Ctx.settings
    if ($cls.state -eq 'expanded' -and [double]$cls.statusBlockDip -gt 0) { Add-Warning 'transient_status_active_may_change_panel_height_during_move' }
    if ($cls.state -eq 'expanded' -and $cls.confidence -eq 'low') { Add-Warning 'panel_height_low_confidence_prediction' }
    $pollTimeoutMs = 150
    $stepRecords = New-Object 'System.Collections.Generic.List[object]'
    $pendingFault = $null
    $restore = $null
    try {
        for ($i = 1; $i -le $StepCount; $i++) {
            $tx = [int][Math]::Round([int]$startRiot.rect.x + (([double]$DxValue * $i) / $StepCount))
            $ty = [int][Math]::Round([int]$startRiot.rect.y + (([double]$DyValue * $i) / $StepCount))
            $expected = Get-PredictedOverlayRect -RiotX $tx -RiotY $ty -RiotW ([int]$startRiot.rect.w) -RiotH ([int]$startRiot.rect.h) -Scale $Ctx.scale -WidthPx $panelW -HeightPx $panelH -OffsetRightDip $offsets.rightDip -OffsetTopDip $offsets.topDip
            $tMove = Get-QpcTicks
            $moveOk = [RiotPerfNative]::SetWindowPos($riotHwnd, [IntPtr]::Zero, $tx, $ty, 0, 0, ([uint32]($script:SWP_NOSIZE -bor $script:SWP_NOZORDER -bor $script:SWP_NOACTIVATE)))
            $moveCallMs = Get-DeltaMs $tMove (Get-QpcTicks)
            $detect = Wait-OverlayRect -ExpectedX $expected.x -ExpectedY $expected.y -TolerancePx 2 -TimeoutMs $pollTimeoutMs -PollMs 2
            $actual = $null
            $residualX = $null
            $residualY = $null
            if ($null -ne $detect.window) {
                $actual = [ordered]@{ x = [int]$detect.window.rect.x; y = [int]$detect.window.rect.y }
                $residualX = [int]$detect.window.rect.x - [int]$expected.x
                $residualY = [int]$detect.window.rect.y - [int]$expected.y
            }
            $record = [ordered]@{
                index = $i
                riotX = $tx
                riotY = $ty
                moveCallOk = [bool]$moveOk
                moveCallMs = $moveCallMs
                overlayDetected = [bool]$detect.ok
                detectionMs = [double]$detect.elapsedMs
                expectedOverlay = [ordered]@{ x = [int]$expected.x; y = [int]$expected.y; clampedX = [bool]$expected.clampedX; clampedY = [bool]$expected.clampedY }
                actualOverlay = $actual
                residualPx = $(if ($null -ne $residualX) { [ordered]@{ x = $residualX; y = $residualY } } else { $null })
            }
            $stepRecords.Add($record)
        }
    } catch {
        $pendingFault = $_
    } finally {
        $tRestore = Get-QpcTicks
        $restoreOk = [RiotPerfNative]::SetWindowPos($riotHwnd, [IntPtr]::Zero, [int]$startRiot.rect.x, [int]$startRiot.rect.y, 0, 0, ([uint32]($script:SWP_NOSIZE -bor $script:SWP_NOZORDER -bor $script:SWP_NOACTIVATE)))
        $restoreCallMs = Get-DeltaMs $tRestore (Get-QpcTicks)
        $back = Wait-OverlayRect -ExpectedX ([int]$ov.rect.x) -ExpectedY ([int]$ov.rect.y) -TolerancePx 2 -TimeoutMs 500 -PollMs 3
        $finalRiot = New-WindowSnapshot $riotHwnd
        $riotBack = ([Math]::Abs([int]$finalRiot.rect.x - [int]$startRiot.rect.x) -le 1 -and [Math]::Abs([int]$finalRiot.rect.y - [int]$startRiot.rect.y) -le 1)
        $restore = [ordered]@{
            riotTarget = [ordered]@{ x = [int]$startRiot.rect.x; y = [int]$startRiot.rect.y }
            moveCallOk = [bool]$restoreOk
            moveCallMs = $restoreCallMs
            overlayBack = [bool]$back.ok
            overlayBackMs = [double]$back.elapsedMs
            riotRectRestored = [bool]$riotBack
            overlayRect = $(if ($null -ne $back.window) { $back.window.rect } else { $null })
        }
        if (-not $riotBack) { Add-Warning 'riot_rect_not_restored_after_move_riot' }
        if (-not $back.ok) { Add-Warning 'overlay_position_not_restored_after_move_riot' }
    }
    if ($null -ne $pendingFault) { throw $pendingFault }
    $latencies = New-Object 'System.Collections.Generic.List[double]'
    $maxResidual = 0
    $detected = 0
    foreach ($r in $stepRecords) {
        if ($r.overlayDetected) { $latencies.Add([double]$r.detectionMs) }
        if ($null -ne $r.residualPx) {
            $m = [Math]::Max([Math]::Abs([int]$r.residualPx.x), [Math]::Abs([int]$r.residualPx.y))
            if ($m -gt $maxResidual) { $maxResidual = $m }
        }
    }
    $detected = @($stepRecords | Where-Object { $_.overlayDetected }).Count
    return [ordered]@{
        move = [ordered]@{
            dx = $DxValue
            dy = $DyValue
            steps = $StepCount
            from = [ordered]@{ x = [int]$startRiot.rect.x; y = [int]$startRiot.rect.y }
            to = [ordered]@{ x = [int]($startRiot.rect.x + $DxValue); y = [int]($startRiot.rect.y + $DyValue) }
        }
        offsets = $offsets
        panelSizePx = [ordered]@{ w = $panelW; h = $panelH }
        overlayStateAtStart = $cls.state
        tracking = [ordered]@{
            steps = $StepCount
            detected = $detected
            withinTolerance = ($detected -eq $StepCount)
            latencyMs = (Get-NumberStats $latencies.ToArray())
            maxAbsResidualPx = [int]$maxResidual
            pollTimeoutMs = $pollTimeoutMs
        }
        steps = @($stepRecords.ToArray())
        restore = $restore
    }
}

function Invoke-HoverAction {
    param($Ctx, [string]$TargetText, [int]$MoveCount, [int]$Interval, [int]$PressMs)
    $ov = Get-OverlayForAction $Ctx
    $cls = Get-OverlayClassification -Overlay $ov -Riot $Ctx.riotWindow -SettingsInfo $Ctx.settings -AccountsInfo $Ctx.accounts -Scale $Ctx.scale
    $normalized = ''
    if ([string]::IsNullOrWhiteSpace($TargetText)) {
        if ($cls.state -eq 'collapsed') { $normalized = 'collapsed' } else { $normalized = 'header' }
    } else {
        $normalized = Normalize-Target $TargetText
    }
    $pointDip = $null
    $rowIndex = $null
    if ($normalized.StartsWith('row:')) {
        if ($cls.state -ne 'expanded') {
            Throw-DriverFault 'invalid_state' 'Hover on a row requires an expanded overlay.' ([ordered]@{ currentState = $cls.state })
        }
        $rowIndex = 0
        $parsed = [int]::TryParse($normalized.Substring(4), [ref]$rowIndex)
        if (-not $parsed -or $rowIndex -lt 0 -or $rowIndex -gt 4) {
            Throw-DriverFault 'invalid_args' 'Row target must be row:0 .. row:4.' ([ordered]@{ target = $normalized })
        }
        $rowCount = 5
        if ($null -ne $Ctx.accounts -and $Ctx.accounts.readOk -and $null -ne $Ctx.accounts.count) { $rowCount = [Math]::Min([int]$Ctx.accounts.count, 5) }
        if ($rowIndex -ge $rowCount) { Add-Warning 'hover_row_has_no_account' }
        $pointDip = [ordered]@{ x = 190.0; y = ([double]($script:DipListTop + 52 * $rowIndex + 24)) }
    } else {
        $entry = $cls.clickTargets[$normalized]
        if ($null -eq $entry) {
            Throw-DriverFault 'invalid_target' ("Hover target '" + $normalized + "' is not available for the current overlay state (" + $cls.state + ").") ([ordered]@{ state = $cls.state })
        }
        $pointDip = $entry.pointDip
    }
    $point = New-PointPx $pointDip.x $pointDip.y $Ctx.scale
    Assert-ClickPointInsideClient -Overlay $ov -PointPx $point
    $latencies = New-Object 'System.Collections.Generic.List[double]'
    $gaps = New-Object 'System.Collections.Generic.List[double]'
    $tStart = Get-QpcTicks
    for ($i = 1; $i -le $MoveCount; $i++) {
        $latencies.Add((Send-MouseMoveAt -Hwnd $ov.__hwnd -X $point.x -Y $point.y))
        if ($i -lt $MoveCount -and $Interval -gt 0) {
            $tGap = Get-QpcTicks
            Start-Sleep -Milliseconds $Interval
            $gaps.Add((Get-DeltaMs $tGap (Get-QpcTicks)))
        }
    }
    $cleanupMs = Send-MouseLeave -Hwnd $ov.__hwnd
    $totalMs = Get-DeltaMs $tStart (Get-QpcTicks)
    $postCls = Get-ClassificationNow $Ctx $Ctx.scale
    return [ordered]@{
        target = $normalized
        rowIndex = $rowIndex
        pointDip = $pointDip
        pointPx = $point
        countSent = $MoveCount
        intervalRequestedMs = $Interval
        latenciesMs = @($latencies.ToArray())
        latencyStats = (Get-NumberStats $latencies.ToArray())
        gapStats = (Get-NumberStats $gaps.ToArray())
        cleanupMs = $cleanupMs
        totalDurationMs = $totalMs
        post = (Get-ClassificationSummary $postCls)
    }
}

function Invoke-WheelAction {
    param($Ctx, [int]$DeltaValue, [int]$WheelCount, [int]$Interval)
    $ov = Get-OverlayForAction $Ctx
    $cls = Get-OverlayClassification -Overlay $ov -Riot $Ctx.riotWindow -SettingsInfo $Ctx.settings -AccountsInfo $Ctx.accounts -Scale $Ctx.scale
    if ($cls.state -ne 'expanded') {
        Throw-DriverFault 'invalid_state' ("wheel requires an expanded overlay (current state: " + $cls.state + ").") ([ordered]@{ currentState = $cls.state })
    }
    $vaultCount = $null
    if ($null -ne $Ctx.accounts -and $Ctx.accounts.readOk) { $vaultCount = $Ctx.accounts.count }
    $inert = $true
    if ($null -ne $vaultCount -and [int]$vaultCount -gt 5) { $inert = $false }
    if ($inert) { Add-Warning 'wheel_inert_because_account_count_is_5_or_less' }
    $clientW = [int]$ov.client.w
    $clientH = [int]$ov.client.h
    $clientX = [int][Math]::Round($clientW / 2.0)
    $clientY = [int][Math]::Round($clientH / 2.0)
    $screenX = [int]$ov.clientOriginScreen.x + $clientX
    $screenY = [int]$ov.clientOriginScreen.y + $clientY
    $latencies = New-Object 'System.Collections.Generic.List[double]'
    $gaps = New-Object 'System.Collections.Generic.List[double]'
    $tStart = Get-QpcTicks
    for ($i = 1; $i -le $WheelCount; $i++) {
        $latencies.Add((Send-WheelAt -Hwnd $ov.__hwnd -Delta $DeltaValue -ScreenX $screenX -ScreenY $screenY))
        if ($i -lt $WheelCount -and $Interval -gt 0) {
            $tGap = Get-QpcTicks
            Start-Sleep -Milliseconds $Interval
            $gaps.Add((Get-DeltaMs $tGap (Get-QpcTicks)))
        }
    }
    $totalMs = Get-DeltaMs $tStart (Get-QpcTicks)
    $postCls = Get-ClassificationNow $Ctx $Ctx.scale
    return [ordered]@{
        delta = $DeltaValue
        countSent = $WheelCount
        intervalRequestedMs = $Interval
        inert = $inert
        accountCount = $vaultCount
        screenPoint = [ordered]@{ x = $screenX; y = $screenY }
        latenciesMs = @($latencies.ToArray())
        latencyStats = (Get-NumberStats $latencies.ToArray())
        gapStats = (Get-NumberStats $gaps.ToArray())
        totalDurationMs = $totalMs
        post = (Get-ClassificationSummary $postCls)
    }
}

function Invoke-RestoreRiotStep {
    param([IntPtr]$Hwnd, $Baseline, [int]$PressMs)
    $step = [ordered]@{
        step = 'restore_riot_rect'
        empty = $false
        alreadyOk = $false
        restored = $false
        target = $null
        moveCallMs = 0.0
        waitMs = 0.0
        waitOk = $false
        before = $null
        after = $null
    }
    $cur = New-WindowSnapshot $Hwnd
    $step['before'] = [ordered]@{ iconic = [bool]$cur.iconic; rect = $cur.rect }
    $targetRect = $null
    if ($null -ne $Baseline -and $null -ne $Baseline.riot -and $null -ne $Baseline.riot.rect) {
        $targetRect = $Baseline.riot.rect
    }
    if ($null -eq $targetRect) {
        if ($cur.iconic) {
            [void][RiotPerfNative]::ShowWindow($Hwnd, 9)
            $ready = Wait-RiotWindowReady -Hwnd $Hwnd -TimeoutMs 3000 -PollMs 10
            $step['restored'] = $true
            $step['waitOk'] = $ready.ok
            $step['waitMs'] = [double]$ready.elapsedMs
            Add-Warning 'baseline_riot_rect_missing_restore_minimized_only'
        }
        $step['after'] = (New-WindowSnapshot $Hwnd).rect
        return $step
    }
    $tx = [int]$targetRect.x
    $ty = [int]$targetRect.y
    $tw = [int]$targetRect.w
    $th = [int]$targetRect.h
    $step['target'] = [ordered]@{ x = $tx; y = $ty; w = $tw; h = $th }
    if ($cur.iconic) {
        $t = Get-QpcTicks
        [void][RiotPerfNative]::ShowWindow($Hwnd, 9)
        $step['showWindowRestoreCallMs'] = Get-DeltaMs $t (Get-QpcTicks)
        $ready = Wait-RiotWindowReady -Hwnd $Hwnd -TimeoutMs 3000 -PollMs 10
        $step['restoreFromMinimizedMs'] = [double]$ready.elapsedMs
        $cur = New-WindowSnapshot $Hwnd
    }
    $dx = [Math]::Abs([int]$cur.rect.x - $tx)
    $dy = [Math]::Abs([int]$cur.rect.y - $ty)
    $dw = [Math]::Abs([int]$cur.rect.w - $tw)
    $dh = [Math]::Abs([int]$cur.rect.h - $th)
    if ($dx -le 1 -and $dy -le 1 -and $dw -le 1 -and $dh -le 1) {
        $step['alreadyOk'] = $true
        $step['after'] = $cur.rect
        return $step
    }
    $flags = [uint32]($script:SWP_NOZORDER -bor $script:SWP_NOACTIVATE)
    $cx = 0
    $cy = 0
    if ($dw -gt 1 -or $dh -gt 1) { $cx = $tw; $cy = $th } else { $flags = [uint32]($flags -bor $script:SWP_NOSIZE) }
    $t = Get-QpcTicks
    $moveOk = [RiotPerfNative]::SetWindowPos($Hwnd, [IntPtr]::Zero, $tx, $ty, $cx, $cy, $flags)
    $step['moveCallMs'] = Get-DeltaMs $t (Get-QpcTicks)
    $step['moveCallOk'] = [bool]$moveOk
    $wait = Wait-RiotRect -Hwnd $Hwnd -ExpectedX $tx -ExpectedY $ty -TolerancePx 1 -TimeoutMs 2000 -PollMs 15
    $step['restored'] = $true
    $step['waitOk'] = [bool]$wait.ok
    $step['waitMs'] = [double]$wait.elapsedMs
    $step['after'] = (New-WindowSnapshot $Hwnd).rect
    if (-not $wait.ok) { Add-Warning 'riot_rect_restore_not_observed' }
    return $step
}

function Invoke-RestoreAction {
    param($Ctx, [int]$PressMs, [bool]$PinRequested, [bool]$ForegroundRequested, [bool]$SkipDialogClose)
    $baselineInfo = $Ctx.baseline
    $baseline = $null
    if ($baselineInfo.exists) { $baseline = $baselineInfo.data }
    $steps = New-Object 'System.Collections.Generic.List[object]'
    $result = [ordered]@{
        baselineAvailable = [bool]$baselineInfo.exists
        baselinePath = $script:BaselinePath
        baselineSavedUtc = $baselineInfo.savedUtc
        steps = @()
        final = $null
        verified = $false
        riotRectMatchesBaseline = $null
        overlayCollapsed = $null
        anchorMatches = $null
    }
    if (-not $baselineInfo.exists) { Add-Warning 'baseline_missing_best_effort_restore' }

    # 1) Close an intrusive modal SettingsForm dialog if one is open.
    if (-not $SkipDialogClose) {
        $dlg = Find-SettingsDialog
        if ($null -ne $dlg) {
            $t = Get-QpcTicks
            [void][RiotPerfNative]::PostMessage($dlg.__hwnd, [uint32]$script:WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)
            $gone = Wait-WindowGone -Hwnd $dlg.__hwnd -TimeoutMs 2500 -PollMs 20
            $steps.Add([ordered]@{ step = 'close_settings_dialog'; hwnd = $dlg.hwnd; title = $dlg.title; callMs = (Get-DeltaMs $t (Get-QpcTicks)); closed = [bool]$gone.ok; waitMs = [double]$gone.elapsedMs })
            if (-not $gone.ok) { Add-Warning 'settings_dialog_still_open_after_restore' }
        }
    }

    # 2) Restore the pin state when requested (requires expanding/collapsing the panel).
    if ($PinRequested) {
        $currentSettings = Read-SettingsInfo
        $expectedPinned = $null
        if ($null -ne $baseline -and $null -ne $baseline.settings -and $null -ne $baseline.settings.overlayPinned) {
            $expectedPinned = [bool]$baseline.settings.overlayPinned
        }
        if ($null -ne $expectedPinned -and $currentSettings.readOk -and $null -ne $currentSettings.overlayPinned -and ([bool]$currentSettings.overlayPinned -ne $expectedPinned)) {
            $sub = [ordered]@{ step = 'restore_pin_state'; expectedPinned = $expectedPinned; substeps = @() }
            $ovNow = Get-VisibleOverlayWindow
            if ($null -ne $ovNow) {
                $clsNow = Get-OverlayClassification -Overlay $ovNow -Riot $Ctx.riotWindow -SettingsInfo $Ctx.settings -AccountsInfo $Ctx.accounts -Scale $Ctx.scale
                if ($clsNow.state -eq 'collapsed') {
                    $e = Invoke-ExpandOverlay $Ctx $PressMs 2000
                    $sub['substeps'] += [ordered]@{ step = 'expand_for_pin'; performed = $e.performed; transition = $e.transition }
                }
                $clsNow = Get-ClassificationNow $Ctx $Ctx.scale
                if ($clsNow.state -eq 'expanded') {
                    $pinResult = Invoke-PinToggle $Ctx $PressMs $expectedPinned
                    $sub['substeps'] += [ordered]@{ step = 'pin_toggle'; verified = $pinResult.verified; prePinned = $pinResult.prePinned; expectedPinned = $pinResult.expectedPinned; observedPinned = $pinResult.observedPinned; latencies = $pinResult.latencies }
                } else {
                    Add-Warning 'pin_restore_skipped_overlay_not_expanded'
                    $sub['skipped'] = 'overlay_not_expanded'
                }
                $c = Invoke-CollapseOverlay $Ctx $PressMs 2000
                $sub['substeps'] += [ordered]@{ step = 'collapse_after_pin'; performed = $c.performed; transition = $c.transition }
            } else {
                $sub['skipped'] = 'overlay_not_visible'
                Add-Warning 'pin_restore_skipped_overlay_not_visible'
            }
            $steps.Add($sub)
        }
    }

    # 3) Restore the Riot Client rect from the baseline (also un-minimizes).
    $riotSnapshot = $Ctx.riotWindow
    if ($null -eq $riotSnapshot -and $Ctx.riotWindows.Count -gt 0) { $riotSnapshot = $Ctx.riotWindows[0] }
    if ($null -eq $riotSnapshot) {
        Throw-DriverFault 'riot_window_not_found' 'Restore impossible: no Riot Client window found.' ([ordered]@{ steps = @($steps.ToArray()) })
    }
    $riotHwnd = $riotSnapshot.__hwnd
    $riotStep = Invoke-RestoreRiotStep -Hwnd $riotHwnd -Baseline $baseline -PressMs $PressMs
    $steps.Add($riotStep)

    # 4) Make sure the overlay is back.
    $ovWait = Wait-OverlayVisible -TimeoutMs 2500 -PollMs 20
    if (-not $ovWait.ok) {
        [void][RiotPerfNative]::ForceForeground($riotHwnd)
        $fgWait = Wait-ForegroundWindow -Hwnd $riotHwnd -TimeoutMs 1500 -PollMs 10
        $ovWait = Wait-OverlayVisible -TimeoutMs 2500 -PollMs 20
        $steps.Add([ordered]@{ step = 'foreground_fallback_for_overlay'; foregroundObserved = [bool]$fgWait.ok; overlayVisible = [bool]$ovWait.ok; overlayWaitMs = [double]$ovWait.elapsedMs })
    }
    if (-not $ovWait.ok) {
        Throw-DriverFault 'overlay_not_found' 'Restore failed: the RiotSwitch overlay did not reappear after restoring the Riot Client window.' ([ordered]@{ steps = @($steps.ToArray()) })
    }

    # 5) Final collapse + verification.
    $freshCls = Get-ClassificationNow $Ctx $Ctx.scale
    if ($freshCls.state -eq 'expanded') {
        $collapse = Invoke-CollapseOverlay $Ctx $PressMs 2000
        $steps.Add([ordered]@{ step = 'collapse_overlay'; performed = $collapse.performed; transition = $collapse.transition })
    } elseif ($freshCls.state -eq 'collapsed') {
        $steps.Add([ordered]@{ step = 'collapse_overlay'; performed = $false; reason = 'already_collapsed' })
    } else {
        Add-Warning 'overlay_state_unknown_after_restore'
    }

    # 6) Optional foreground restoration.
    if ($ForegroundRequested -and $null -ne $baseline -and -not [string]::IsNullOrWhiteSpace([string]$baseline.foregroundHwnd)) {
        $fgTarget = [IntPtr]::Zero
        try {
            $hex = ([string]$baseline.foregroundHwnd).Trim()
            if ($hex.StartsWith('0x')) { $hex = $hex.Substring(2) }
            $fgTarget = [IntPtr][Convert]::ToInt64($hex, 16)
        } catch { $fgTarget = [IntPtr]::Zero }
        if ($fgTarget -ne [IntPtr]::Zero -and [RiotPerfNative]::IsWindow($fgTarget)) {
            $t = Get-QpcTicks
            $ok = [RiotPerfNative]::ForceForeground($fgTarget)
            $fgWait = Wait-ForegroundWindow -Hwnd $fgTarget -TimeoutMs 1500 -PollMs 10
            $steps.Add([ordered]@{ step = 'restore_foreground'; target = $baseline.foregroundHwnd; observed = [bool]$fgWait.ok; callMs = (Get-DeltaMs $t (Get-QpcTicks)) })
            if (-not $fgWait.ok) { Add-Warning 'foreground_restore_not_observed' }
        } else {
            Add-Warning 'baseline_foreground_window_no_longer_exists'
        }
    }

    # 7) Final verification.
    $finalRiot = New-WindowSnapshot $riotHwnd
    $finalOv = Get-VisibleOverlayWindow
    $finalCls = $null
    if ($null -ne $finalOv) {
        $finalCls = Get-OverlayClassification -Overlay $finalOv -Riot $finalRiot -SettingsInfo (Read-SettingsInfo) -AccountsInfo $Ctx.accounts -Scale $Ctx.scale
    }
    $riotMatches = $true
    if ($null -ne $baseline -and $null -ne $baseline.riot -and $null -ne $baseline.riot.rect) {
        $riotMatches = ([Math]::Abs([int]$finalRiot.rect.x - [int]$baseline.riot.rect.x) -le 1 -and
                        [Math]::Abs([int]$finalRiot.rect.y - [int]$baseline.riot.rect.y) -le 1 -and
                        [Math]::Abs([int]$finalRiot.rect.w - [int]$baseline.riot.rect.w) -le 1 -and
                        [Math]::Abs([int]$finalRiot.rect.h - [int]$baseline.riot.rect.h) -le 1)
    }
    $overlayCollapsed = ($null -ne $finalCls -and $finalCls.state -eq 'collapsed')
    $anchorMatches = $null
    if ($null -ne $finalCls -and $null -ne $finalCls.anchor) { $anchorMatches = [bool]$finalCls.anchor.matches }
    $result['riotRectMatchesBaseline'] = [bool]$riotMatches
    $result['overlayCollapsed'] = [bool]$overlayCollapsed
    $result['anchorMatches'] = $anchorMatches
    $result['verified'] = ([bool]$riotMatches -and [bool]$overlayCollapsed -and ($anchorMatches -ne $false))
    if (-not $result['verified']) { Add-Warning 'restore_verification_incomplete' }
    $result['final'] = [ordered]@{
        riot = [ordered]@{ hwnd = $finalRiot.hwnd; pid = $finalRiot.pid; iconic = $finalRiot.iconic; visible = $finalRiot.visible; rect = $finalRiot.rect }
        overlay = (Get-ClassificationSummary $finalCls)
        overlayVisible = ($null -ne $finalOv)
        foreground = (Format-HexValue ([RiotPerfNative]::GetForegroundWindow()))
    }
    $result['steps'] = @($steps.ToArray())
    return $result
}

# ---------------------------------------------------------------------------
# Response assembly + main dispatch.
# ---------------------------------------------------------------------------

function New-DriverResponse {
    param($Result, [string]$FaultCode, [string]$FaultMessage, $FaultDetails)
    $now = Get-QpcTicks
    $ok = [string]::IsNullOrWhiteSpace($FaultCode)
    $resp = [ordered]@{
        schema = 'riotswitch.perf.driver/1'
        action = $script:ActionName
        ok = $ok
        exitCode = $(if ($ok) { 0 } else { 2 })
        startedUtc = $script:StartedUtcIso
        finishedUtc = [DateTime]::UtcNow.ToString('o', $script:Invariant)
        timing = [ordered]@{
            processStartupMs = (Get-DeltaMs $script:ScriptStartQpc $script:PostTypeQpc)
            actionMs = (Get-DeltaMs $script:ActionStartQpc $now)
            totalMs = (Get-DeltaMs $script:ScriptStartQpc $now)
            qpc = [ordered]@{ frequency = $script:QpcFreq; start = $script:ScriptStartQpc; end = $now; actionStart = $script:ActionStartQpc }
        }
        allowInteraction = [bool]$script:AllowInteractionFlag
        host = [ordered]@{
            pid = $PID
            powershell = $PSVersionTable.PSVersion.ToString()
            os = [Environment]::OSVersion.VersionString
            is64 = [Environment]::Is64BitProcess
        }
        windows = $null
        windowsSummary = $null
        ready = $null
        classification = $null
        settings = $null
        accounts = $null
        baseline = $null
        result = $null
        warnings = @()
        error = $null
    }
    if ($null -ne $script:Context) {
        $ctx = $script:Context
        $resp['windows'] = [ordered]@{
            riot = $ctx.riotWindow
            riotCandidates = $ctx.riotWindows
            overlay = $ctx.overlayWindow
            overlayCandidates = $ctx.overlayWindows
        }
        $resp['ready'] = [bool]($ctx.riotReady -and $ctx.overlayVisible)
        $resp['classification'] = $ctx.classification
        $resp['settings'] = $ctx.settings
        $resp['accounts'] = $ctx.accounts
        $resp['baseline'] = $ctx.baseline
        $resp['windowsSummary'] = [ordered]@{
            riotHwnd = $(if ($null -ne $ctx.riotWindow) { $ctx.riotWindow.hwnd } else { $null })
            riotIconic = $(if ($null -ne $ctx.riotWindow) { $ctx.riotWindow.iconic } else { $null })
            overlayHwnd = $(if ($null -ne $ctx.overlayWindow) { $ctx.overlayWindow.hwnd } else { $null })
            overlayVisible = [bool]$ctx.overlayVisible
            overlayState = $ctx.classification.state
            scale = $ctx.scale
            scaleSource = $ctx.scaleSource
            overlayExpectation = $ctx.overlayExpectation
        }
    }
    if ($null -ne $Result) { $resp['result'] = $Result }
    $resp['warnings'] = @($script:Warnings.ToArray())
    if (-not $ok) {
        $resp['error'] = [ordered]@{ code = $FaultCode; message = $FaultMessage; details = $FaultDetails }
    }
    return $resp
}

# ---------------------------------------------------------------------------
# Main.
# ---------------------------------------------------------------------------

$script:ActionName = 'discover'
if (-not [string]::IsNullOrWhiteSpace($Action)) { $script:ActionName = $Action.Trim().ToLowerInvariant() }
$script:AllowInteractionFlag = $AllowInteraction.IsPresent
$script:ForceFlag = $Force.IsPresent

try {
    $validActions = @('discover', 'state', 'foreground-riot', 'wait-overlay', 'click', 'expand', 'collapse', 'toggle', 'move-riot', 'hover', 'wheel', 'restore')
    if ($validActions -notcontains $script:ActionName) {
        Throw-DriverFault 'invalid_args' ("Unknown -Action '" + $Action + "'. Valid values: " + ($validActions -join ', ') + '.') $null
    }
    $script:Options = [ordered]@{
        Action = $script:ActionName
        TimeoutMs = (Get-IntArg 'TimeoutMs' $TimeoutMs 3000 50 60000)
        Target = $(if ([string]::IsNullOrWhiteSpace($Target)) { '' } else { $Target.Trim() })
        Dx = (Get-IntArg 'Dx' $Dx 0 -10000 10000)
        Dy = (Get-IntArg 'Dy' $Dy 0 -10000 10000)
        Steps = (Get-IntArg 'Steps' $Steps 20 1 200)
        Count = (Get-IntArg 'Count' $Count 1 1 10000)
        IntervalMs = (Get-IntArg 'IntervalMs' $IntervalMs 20 0 60000)
        Delta = (Get-IntArg 'Delta' $Delta -120 -32768 32767)
        PressMs = (Get-IntArg 'PressMs' $PressMs 15 0 5000)
        Force = [bool]$Force.IsPresent
    }
    if ($script:ActionName -eq 'click' -and [string]::IsNullOrWhiteSpace($script:Options.Target)) {
        Throw-DriverFault 'invalid_args' 'click requires -Target (collapsed | close | pin | settings | header | footer:0 | footer:1 | footer:2).' $null
    }
    if ($script:ActionName -eq 'click' -and $script:Options.Target -eq 'footer:0' -and -not $script:ForceFlag) {
        Throw-DriverFault 'force_required' 'click -Target footer:0 adds/switches a Riot account and requires -Force.' $null
    }
    if ($SaveBaseline.IsPresent -and $script:ActionName -ne 'state') {
        Add-Warning 'save_baseline_only_applies_to_action_state'
    }
    $interactiveActions = @('foreground-riot', 'click', 'expand', 'collapse', 'toggle', 'move-riot', 'hover', 'wheel', 'restore')
    if ($interactiveActions -contains $script:ActionName -and -not $script:AllowInteractionFlag) {
        Throw-DriverFault 'interaction_not_allowed' ("Action '" + $script:ActionName + "' can interact with the UI and requires -AllowInteraction (campaign phase only).") ([ordered]@{ action = $script:ActionName; passiveActions = @('discover', 'state', 'wait-overlay') })
    }
    if ($script:ActionName -eq 'hover' -or $script:ActionName -eq 'wheel') {
        if ($script:ActionName -eq 'hover' -and $script:Options.IntervalMs -gt 5000) { Add-Warning 'large_hover_interval' }
    }

    $script:Context = Get-EnvironmentSnapshot
    $ctx = $script:Context
    $script:ActionStartQpc = Get-QpcTicks
    $result = $null
    switch ($script:ActionName) {
        'discover' { $result = Invoke-DiscoverAction $ctx }
        'state' { $result = Invoke-StateAction $ctx ($SaveBaseline.IsPresent) }
        'foreground-riot' { $result = Invoke-ForegroundRiotAction $ctx $script:Options.TimeoutMs $script:Options.PressMs }
        'wait-overlay' { $result = Invoke-WaitOverlayAction $ctx $script:Options.TimeoutMs }
        'click' { $result = Invoke-ClickAction $ctx $script:Options.Target $script:Options.PressMs }
        'expand' { $result = Invoke-ExpandAction $ctx $script:Options.PressMs }
        'collapse' { $result = Invoke-CollapseAction $ctx $script:Options.PressMs }
        'toggle' { $result = Invoke-ToggleAction $ctx $script:Options.PressMs }
        'move-riot' { $result = Invoke-MoveRiotAction $ctx $script:Options.Dx $script:Options.Dy $script:Options.Steps $script:Options.PressMs }
        'hover' { $result = Invoke-HoverAction $ctx $script:Options.Target $script:Options.Count $script:Options.IntervalMs $script:Options.PressMs }
        'wheel' { $result = Invoke-WheelAction $ctx $script:Options.Delta $script:Options.Count $script:Options.IntervalMs }
        'restore' { $result = Invoke-RestoreAction $ctx $script:Options.PressMs $RestorePin.IsPresent $RestoreForeground.IsPresent $SkipSettingsClose.IsPresent }
    }
    $response = New-DriverResponse -Result $result
} catch {
    $ex = $_.Exception
    $faultCode = 'internal_error'
    $faultMessage = $ex.Message
    $faultDetails = [ordered]@{ exceptionType = $ex.GetType().FullName }
    if ($ex -is [DriverFaultException]) {
        $faultCode = $ex.Code
        $faultMessage = $ex.Message
        $faultDetails = $ex.Details
    } else {
        $faultDetails['scriptStackTrace'] = $_.ScriptStackTrace
    }
    try {
        $response = New-DriverResponse -Result $null -FaultCode $faultCode -FaultMessage $faultMessage -FaultDetails $faultDetails
    } catch {
        $response = [ordered]@{
            schema = 'riotswitch.perf.driver/1'
            action = $script:ActionName
            ok = $false
            exitCode = 2
            error = [ordered]@{ code = 'response_build_failed'; message = $_.Exception.Message; details = $null }
            warnings = @()
        }
    }
}

$jsonLine = ConvertTo-DriverJson $response
[Console]::Out.WriteLine($jsonLine)
if ($script:LogEnabled) { try { Write-ActionLog $response } catch { } }
exit ([int]$response.exitCode)
