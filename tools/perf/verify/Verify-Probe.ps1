# =============================================================================
# Verify-Probe.ps1 — verification independante (phase A du harnais verifier)
#
# Objectif : mesurer et verifier, SANS les outils du Lead (sampler/driver/probe),
#   1) le delai "fenetre Riot Client detectee -> overlay affiche" a partir du
#      log applicatif %LOCALAPPDATA%\RiotSwitch\logs\app.log (horodatages UTC) ;
#   2) la presence et la geometrie de la fenetre overlay par un EnumWindows
#      P/Invoke ecrit ici (titre exact "RiotSwitch", process RiotSwitch,
#      visible, rect, ExStyle, owner) ;
#   3) un cross-check log <-> fenetres reellement observees.
#
# Modes :
#   -Mode Analyze   (defaut) analyse le(s) log(s) et calcule les latences.
#   -Mode Snapshot  enumere les fenetres maintenant (overlay / Riot Client).
#   -Mode Watch     observe les transitions de fenetres pendant N secondes et
#                   compare la latence observee a celle du log.
#   -Mode SelfTest  auto-test du harnais sur le log existant + EnumWindows.
#
# Ce script n'interagit JAMAIS avec l'UI (aucun clic, foreground, deplacement,
# minimisation) ; il ne tue aucun processus ; il ne fait que lire le log et
# enumerer les fenetres (lecture passive). Aucune dependance a tools/perf/driver,
# tools/perf/probe ni tools/perf/sampler.
#
# Sorties CSV/JSON en culture invariante (point decimal) dans
# tools/perf/verify/results/ par defaut.
#
# Codes de sortie : 0 OK ; 1 erreur inattendue ; 2 log absent/vide ;
#                   3 usage invalide ; 4 auto-test FAIL ; 5 attente non
#                   satisfaite (-ExpectOverlay / -ExpectRiotClient) ;
#                   6 incoherence fenetre stricte (-StrictWindows).
# =============================================================================

[CmdletBinding()]
param(
    [ValidateSet('Analyze', 'Snapshot', 'Watch', 'SelfTest')]
    [string]$Mode = 'Analyze',

    # Log a analyser (fichier ou dossier). Par defaut : app.log local de l'app.
    [string]$LogPath = '',

    # Inclure les archives app.log.N (analyse chronologique).
    [switch]$IncludeRotated,

    # Watch : duree d'observation et periode de scrutation.
    [int]$DurationSec = 30,
    [int]$PollMs = 250,

    # Au-dela de ce delai, une paire detection->affichage est rejetee.
    [int]$MaxLatencyMs = 10000,

    # Dossier de sortie (cree si absent).
    [string]$OutDir = '',

    # Suffixe ajoute aux noms de fichiers.
    [string]$Tag = '',

    # Snapshot/Watch : exiger la presence de l'overlay / du client Riot.
    [switch]$ExpectOverlay,
    [switch]$ExpectRiotClient,

    # Analyze : une incoherence de handles log <-> fenetres devient une erreur.
    [switch]$StrictWindows,

    # SelfTest : conserver les fichiers produits par l'auto-test.
    [switch]$KeepSelfTestArtifacts,

    # Reduire la sortie console.
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ToolName = 'Verify-Probe'
$script:ToolVersion = '1.0.0'
$script:Inv = [System.Globalization.CultureInfo]::InvariantCulture
$script:Quiet = [bool]$Quiet

# ---------------------------------------------------------------------------
# Helpers generaux
# ---------------------------------------------------------------------------

function Format-Inv {
    param(
        $Value,
        [string]$Fmt = 'F3'
    )
    if ($null -eq $Value) { return '' }
    return [string]::Format($script:Inv, ('{0:' + $Fmt + '}'), [double]$Value)
}

function Write-Status {
    param([string]$Message)
    if (-not $script:Quiet) { Write-Host $Message }
}

function Test-Prop {
    # Teste l'existence d'une propriete sans declencher Set-StrictMode.
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $false }
    return ($null -ne $Object.PSObject.Properties[$Name])
}

function Get-Stamp {
    return [DateTimeOffset]::UtcNow.ToString('yyyyMMdd-HHmmss', $script:Inv)
}

function Get-SafeTag {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    return ($Value -replace '[^A-Za-z0-9._-]', '-')
}

function Initialize-OutDir {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = Join-Path $PSScriptRoot 'results'
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        $null = New-Item -ItemType Directory -Path $Path -Force
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Write-CsvRows {
    param(
        [string]$Path,
        [string[]]$Headers,
        [object[]]$Rows
    )
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine(($Headers -join ','))
    foreach ($row in $Rows) {
        $fields = New-Object System.Collections.Generic.List[string]
        foreach ($cell in $row) {
            $text = [string]$cell
            if ($text.IndexOf(',') -ge 0 -or $text.IndexOf('"') -ge 0 -or
                $text.IndexOf("`r") -ge 0 -or $text.IndexOf("`n") -ge 0) {
                $text = '"' + $text.Replace('"', '""') + '"'
            }
            $fields.Add($text)
        }
        [void]$sb.AppendLine(($fields -join ','))
    }
    [System.IO.File]::WriteAllText($Path, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
}

function Write-JsonFile {
    param([string]$Path, $Object)
    $oldCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
    try {
        [System.Threading.Thread]::CurrentThread.CurrentCulture = $script:Inv
        $text = ($Object | ConvertTo-Json -Depth 12)
    }
    finally {
        [System.Threading.Thread]::CurrentThread.CurrentCulture = $oldCulture
    }
    [System.IO.File]::WriteAllText($Path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-Stats {
    # Statistiques descriptives d'une serie de doubles (retourne $null si vide).
    param([object]$Values)
    $vals = New-Object System.Collections.Generic.List[double]
    foreach ($v in @($Values)) {
        if ($null -ne $v) { $vals.Add([double]$v) }
    }
    if ($vals.Count -eq 0) { return $null }

    $sorted = $vals.ToArray()
    [Array]::Sort($sorted)
    $n = $sorted.Count
    $sum = 0.0
    foreach ($x in $sorted) { $sum += $x }
    $mean = $sum / $n
    if ($n % 2 -eq 1) {
        $median = [double]$sorted[[int](($n - 1) / 2)]
    }
    else {
        $median = ([double]$sorted[($n / 2) - 1] + [double]$sorted[$n / 2]) / 2.0
    }
    $p95Index = [int][Math]::Ceiling(0.95 * $n) - 1
    if ($p95Index -lt 0) { $p95Index = 0 }
    if ($p95Index -ge $n) { $p95Index = $n - 1 }
    $varSum = 0.0
    foreach ($x in $sorted) {
        $d = $x - $mean
        $varSum += $d * $d
    }
    $std = [Math]::Sqrt($varSum / $n)

    return [pscustomobject]@{
        Count  = $n
        Min    = [double]$sorted[0]
        Mean   = [double]$mean
        Median = [double]$median
        P95    = [double]$sorted[$p95Index]
        Max    = [double]$sorted[$n - 1]
        StdDev = [double]$std
    }
}

# ---------------------------------------------------------------------------
# P/Invoke : EnumWindows, titre, classe, visibilite, rectangle, ExStyle, owner.
# Import direct user32 (aucune dependance au code des autres equipiers).
# ---------------------------------------------------------------------------

$nativeSource = @'
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class RSVerifyProbeNative
{
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern int GetWindowTextLength(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    public static int[] GetWindowRectArray(IntPtr hWnd)
    {
        RECT r;
        if (!GetWindowRect(hWnd, out r)) return null;
        return new int[] { r.Left, r.Top, r.Right, r.Bottom };
    }

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll")]
    public static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
    private static extern IntPtr GetWindowLongPtr64(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongW")]
    private static extern IntPtr GetWindowLong32(IntPtr hWnd, int nIndex);

    public static IntPtr GetWindowLongPtr(IntPtr hWnd, int nIndex)
    {
        return IntPtr.Size == 8 ? GetWindowLongPtr64(hWnd, nIndex) : GetWindowLong32(hWnd, nIndex);
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }
}
'@

if (-not ('RSVerifyProbeNative' -as [type])) {
    Add-Type -TypeDefinition $nativeSource -ErrorAction Stop
}

$script:GW_OWNER = 4
$script:GWL_EXSTYLE = -20
$script:WS_EX_LAYERED = [int64]0x00080000
$script:WS_EX_TOOLWINDOW = [int64]0x00000080
$script:WS_EX_NOACTIVATE = [int64]0x08000000

$script:RiotClientTitle = 'Riot Client'
$script:RiotClientProcessName = 'Riot Client'
$script:OverlayTitle = 'RiotSwitch'
$script:OverlayProcessName = 'RiotSwitch'

# Cache des noms de processus pour les enumerations repetees (Watch).
$script:ProcessNameCache = @{}

function Get-ProcessNameCached {
    param([int]$ProcessId)
    if ($script:ProcessNameCache.ContainsKey($ProcessId)) {
        return $script:ProcessNameCache[$ProcessId]
    }
    $name = $null
    try {
        $proc = Get-Process -Id $ProcessId -ErrorAction Stop
        $name = [string]$proc.ProcessName
    }
    catch {
        $name = $null
    }
    $script:ProcessNameCache[$ProcessId] = $name
    return $name
}

function Read-WindowRect {
    param([IntPtr]$Hwnd)
    $arr = [RSVerifyProbeNative]::GetWindowRectArray($Hwnd)
    if ($null -eq $arr) { return $null }
    return [pscustomobject]@{
        Left   = [int]$arr[0]
        Top    = [int]$arr[1]
        Right  = [int]$arr[2]
        Bottom = [int]$arr[3]
        Width  = [int]($arr[2] - $arr[0])
        Height = [int]($arr[3] - $arr[1])
    }
}

function Read-WindowExStyle {
    param([IntPtr]$Hwnd)
    try {
        $v = [RSVerifyProbeNative]::GetWindowLongPtr($Hwnd, $script:GWL_EXSTYLE)
        return [int64]$v.ToInt64()
    }
    catch {
        return $null
    }
}

function Test-OverlayWindow {
    param($Window)
    if ($null -eq $Window) { return $false }
    return ([string]::Equals($Window.Title, $script:OverlayTitle, [StringComparison]::Ordinal) -and
            [string]::Equals($Window.ProcessName, $script:OverlayProcessName, [StringComparison]::OrdinalIgnoreCase) -and
            [bool]$Window.Visible)
}

function Test-RiotClientWindow {
    param($Window)
    if ($null -eq $Window) { return $false }
    return ([string]::Equals($Window.Title, $script:RiotClientTitle, [StringComparison]::Ordinal) -and
            [string]::Equals($Window.ProcessName, $script:RiotClientProcessName, [StringComparison]::OrdinalIgnoreCase) -and
            [bool]$Window.Visible)
}

function Get-WindowInventory {
    # Enumere toutes les fenetres de premier niveau avec titre non vide.
    # Lecture passive uniquement.
    $handles = New-Object System.Collections.Generic.List[IntPtr]
    $callback = [RSVerifyProbeNative+EnumWindowsProc]{
        param([IntPtr]$hWnd, [IntPtr]$lParam)
        $handles.Add($hWnd)
        return $true
    }
    $enumOk = [RSVerifyProbeNative]::EnumWindows($callback, [IntPtr]::Zero)
    if (-not $enumOk) {
        throw 'EnumWindows a echoue.'
    }

    $items = New-Object System.Collections.Generic.List[object]
    foreach ($h in $handles) {
        $len = 0
        try { $len = [RSVerifyProbeNative]::GetWindowTextLength($h) } catch { $len = 0 }
        if ($len -le 0) { continue }

        $sb = New-Object System.Text.StringBuilder ($len + 2)
        $copied = 0
        try { $copied = [RSVerifyProbeNative]::GetWindowText($h, $sb, $sb.Capacity) } catch { $copied = 0 }
        $title = $sb.ToString()
        if ([string]::IsNullOrWhiteSpace($title)) { continue }

        $className = ''
        try {
            $cb = New-Object System.Text.StringBuilder 256
            [void][RSVerifyProbeNative]::GetClassName($h, $cb, $cb.Capacity)
            $className = $cb.ToString()
        }
        catch { $className = '' }

        $rawPid = [uint32]0
        try { [void][RSVerifyProbeNative]::GetWindowThreadProcessId($h, [ref]$rawPid) } catch { $rawPid = 0 }
        $winPid = [int]$rawPid

        $visible = $false
        try { $visible = [RSVerifyProbeNative]::IsWindowVisible($h) } catch { $visible = $false }

        $rectObj = $null
        try { $rectObj = Read-WindowRect -Hwnd $h } catch { $rectObj = $null }

        $ownerRaw = [IntPtr]::Zero
        try { $ownerRaw = [RSVerifyProbeNative]::GetWindow($h, [uint32]$script:GW_OWNER) } catch { $ownerRaw = [IntPtr]::Zero }

        $procName = $null
        if ($winPid -gt 0) { $procName = Get-ProcessNameCached -ProcessId $winPid }

        $items.Add([pscustomobject]@{
            Hwnd        = [int64]$h.ToInt64()
            Title       = $title
            ClassName   = $className
            Pid         = $winPid
            ProcessName = $procName
            Visible     = [bool]$visible
            Left        = $(if ($null -ne $rectObj) { $rectObj.Left } else { $null })
            Top         = $(if ($null -ne $rectObj) { $rectObj.Top } else { $null })
            Width       = $(if ($null -ne $rectObj) { $rectObj.Width } else { $null })
            Height      = $(if ($null -ne $rectObj) { $rectObj.Height } else { $null })
            ExStyle     = $(if ($visible) { Read-WindowExStyle -Hwnd $h } else { $null })
            OwnerHwnd   = [int64]$ownerRaw.ToInt64()
            IsOverlay   = $false
            IsRiotClient = $false
        })
    }

    # Classification + informations d'owner (apres construction de la liste).
    $byHwnd = @{}
    foreach ($w in $items) { $byHwnd[[int64]$w.Hwnd] = $w }
    foreach ($w in $items) {
        $w.IsOverlay = Test-OverlayWindow -Window $w
        $w.IsRiotClient = Test-RiotClientWindow -Window $w
        $owner = $null
        if ([int64]$w.OwnerHwnd -ne 0 -and $byHwnd.ContainsKey([int64]$w.OwnerHwnd)) {
            $owner = $byHwnd[[int64]$w.OwnerHwnd]
        }
        $w | Add-Member -NotePropertyName OwnerTitle -NotePropertyValue $(if ($null -ne $owner) { $owner.Title } else { $null }) -Force
        $w | Add-Member -NotePropertyName OwnerProcessName -NotePropertyValue $(if ($null -ne $owner) { $owner.ProcessName } else { $null }) -Force
        $w | Add-Member -NotePropertyName OwnerIsRiotClient -NotePropertyValue $(if ($null -ne $owner) { Test-RiotClientWindow -Window $owner } else { $false }) -Force
    }

    return [pscustomobject]@{
        TotalWindows  = $handles.Count
        TitledWindows = $items.Count
        Items         = $items.ToArray()
    }
}

function Get-WindowSummary {
    param([object[]]$Windows)
    $overlays = New-Object System.Collections.Generic.List[object]
    $riots = New-Object System.Collections.Generic.List[object]
    foreach ($w in @($Windows)) {
        if ($w.IsOverlay) { $overlays.Add($w) }
        if ($w.IsRiotClient) { $riots.Add($w) }
    }
    return [pscustomobject]@{
        Overlays     = $overlays.ToArray()
        RiotClients  = $riots.ToArray()
    }
}

function Format-WindowLine {
    param($Window)
    if ($null -eq $Window) { return '(absent)' }
    $rectText = if ($null -ne $Window.Width) { "(x={0},y={1},{2}x{3})" -f $Window.Left, $Window.Top, $Window.Width, $Window.Height } else { '(rect indisponible)' }
    $ex = if ($null -ne $Window.ExStyle) { ('0x{0:X}' -f [int64]$Window.ExStyle) } else { 'n/a' }
    return ("hwnd={0} pid={1} proc='{2}' visible={3} rect={4} exStyle={5} owner={6}" -f `
        $Window.Hwnd, $Window.Pid, $Window.ProcessName, $Window.Visible, $rectText, $ex, $Window.OwnerHwnd)
}

# ---------------------------------------------------------------------------
# Lecture du log applicatif
# ---------------------------------------------------------------------------

$script:RxLine = [regex]'^(?<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+[+-]\d{2}:\d{2}) \[(?<level>[A-Z]+)\] (?<msg>.*)$'
$script:RxDetect = [regex]'^Tracker : fenêtre Riot Client détectée hwnd=(?<hwnd>\d+)(?: pid=(?<pid>\d+))?(?: rect=\((?<x>-?\d+),(?<y>-?\d+),(?<w>\d+)x(?<h>\d+)\))?\.$'
$script:RxCreated = [regex]'^WatchContext : création de l''overlay\.$'
$script:RxBuilt = [regex]'^WatchContext : overlay construit, affichage\.$'
$script:RxShown = [regex]'^WatchContext : overlay affiché \(handle=(?<handle>\d+), visible=(?<vis>True|False), created=(?<created>True|False)\)\.$'
$script:RxAbsent = [regex]'^Tracker : fenêtre Riot Client absente\.$'
$script:RxMinimized = [regex]'^Tracker : fenêtre Riot Client minimisée détectée'
$script:RxNoFocus = [regex]'^Tracker : fenêtre Riot Client sans focus'

function Get-DefaultLogPath {
    return (Join-Path $env:LOCALAPPDATA 'RiotSwitch\logs\app.log')
}

function Get-AnalysisLogFiles {
    param(
        [string]$Path,
        [bool]$WithRotated
    )
    $main = $Path
    if ([string]::IsNullOrWhiteSpace($main)) { $main = Get-DefaultLogPath }
    if (Test-Path -LiteralPath $main -PathType Container) {
        $main = Join-Path (Resolve-Path -LiteralPath $main).Path 'app.log'
    }

    $files = New-Object System.Collections.Generic.List[object]
    if ($WithRotated) {
        $dir = Split-Path -Parent $main
        $leaf = Split-Path -Leaf $main
        if (Test-Path -LiteralPath $dir) {
            $rotated = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like ($leaf + '.*') } |
                Sort-Object -Property LastWriteTimeUtc)
            foreach ($r in $rotated) { $files.Add($r.FullName) }
        }
    }
    if (Test-Path -LiteralPath $main -PathType Leaf) { $files.Add($main) }
    return $files.ToArray()
}

function Read-LogFileLines {
    # Lecture partagee (ReadWrite) : le logger applicatif garde le fichier ouvert.
    param([string]$Path)
    $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
    try {
        $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8, $true)
        $lines = New-Object System.Collections.Generic.List[string]
        while ($true) {
            $line = $sr.ReadLine()
            if ($null -eq $line) { break }
            $lines.Add($line)
        }
        return $lines.ToArray()
    }
    finally {
        $fs.Dispose()
    }
}

function ConvertTo-LogEvent {
    param(
        [string]$Line,
        [string]$SourceFile,
        [int64]$LineNumber
    )
    $m = $script:RxLine.Match($Line)
    if (-not $m.Success) { return $null }

    $tsText = $m.Groups['ts'].Value
    $dto = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($tsText, $script:Inv, [System.Globalization.DateTimeStyles]::None, [ref]$dto)) {
        return $null
    }
    $msg = $m.Groups['msg'].Value
    $kind = 'other'
    $data = @{}

    $dm = $script:RxDetect.Match($msg)
    if ($dm.Success) {
        $kind = 'detect'
        $data['Hwnd'] = [int64]$dm.Groups['hwnd'].Value
        # Les anciennes versions du log ne consignaient ni pid ni rect :
        # les regex sont optionnelles et les champs restent vides (information
        # non disponible, pas une erreur de parsing).
        if ($dm.Groups['pid'].Success) { $data['Pid'] = [int]$dm.Groups['pid'].Value } else { $data['Pid'] = '' }
        if ($dm.Groups['x'].Success) {
            $data['Rect'] = ('{0},{1},{2}x{3}' -f $dm.Groups['x'].Value, $dm.Groups['y'].Value, $dm.Groups['w'].Value, $dm.Groups['h'].Value)
        }
        else { $data['Rect'] = '' }
    }
    elseif ($script:RxCreated.IsMatch($msg)) { $kind = 'created' }
    elseif ($script:RxBuilt.IsMatch($msg)) { $kind = 'built' }
    else {
        $sm = $script:RxShown.Match($msg)
        if ($sm.Success) {
            $kind = 'shown'
            $data['OverlayHandle'] = [int64]$sm.Groups['handle'].Value
            $data['Visible'] = [string]::Equals($sm.Groups['vis'].Value, 'True', [StringComparison]::Ordinal)
            $data['Created'] = [string]::Equals($sm.Groups['created'].Value, 'True', [StringComparison]::Ordinal)
        }
        elseif ($script:RxAbsent.IsMatch($msg)) { $kind = 'absent' }
        elseif ($script:RxMinimized.IsMatch($msg)) { $kind = 'riot-minimized' }
        elseif ($script:RxNoFocus.IsMatch($msg)) { $kind = 'riot-nofocus' }
    }

    return [pscustomobject]@{
        Ts         = $dto
        Level      = $m.Groups['level'].Value
        Msg        = $msg
        Kind       = $kind
        SourceFile = $SourceFile
        LineNumber = $LineNumber
        Data       = [pscustomobject]$data
    }
}

function Read-LogEvents {
    param(
        [string[]]$Files
    )
    $events = New-Object System.Collections.Generic.List[object]
    $fileInfos = New-Object System.Collections.Generic.List[object]
    $unparsed = 0
    $partialTail = $false
    $unparsedSamples = New-Object System.Collections.Generic.List[string]

    for ($fi = 0; $fi -lt $Files.Count; $fi++) {
        $path = $Files[$fi]
        $isLastFile = ($fi -eq ($Files.Count - 1))
        $lines = Read-LogFileLines -Path $path
        $firstTs = $null
        $lastTs = $null
        for ($li = 0; $li -lt $lines.Count; $li++) {
            $line = $lines[$li]
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $evt = ConvertTo-LogEvent -Line $line -SourceFile $path -LineNumber ($li + 1)
            if ($null -eq $evt) {
                if ($isLastFile -and $li -eq ($lines.Count - 1)) {
                    # Ligne finale partielle : le logger ecrit peut-etre encore.
                    $partialTail = $true
                }
                else {
                    $unparsed++
                    if ($unparsedSamples.Count -lt 3) { $unparsedSamples.Add(('{0}:{1}: {2}' -f (Split-Path -Leaf $path), ($li + 1), $line)) }
                }
                continue
            }
            if ($null -eq $firstTs -or $evt.Ts -lt $firstTs) { $firstTs = $evt.Ts }
            if ($null -eq $lastTs -or $evt.Ts -gt $lastTs) { $lastTs = $evt.Ts }
            $events.Add($evt)
        }
        $fileInfos.Add([pscustomobject]@{
            Path    = $path
            Bytes   = (Get-Item -LiteralPath $path).Length
            Lines   = $lines.Count
            FirstTs = $(if ($null -ne $firstTs) { $firstTs.ToString('o', $script:Inv) } else { $null })
            LastTs  = $(if ($null -ne $lastTs) { $lastTs.ToString('o', $script:Inv) } else { $null })
        })
    }

    # Tri chronologique (les fichiers sont deja ordonnes ; Sort-Object est stable
    # sur les dates identiques dans la pratique, les rafales etant separees).
    $eventsArray = @($events | Sort-Object -Property Ts)

    return [pscustomobject]@{
        Events         = $eventsArray
        Files          = $fileInfos.ToArray()
        Unparsed       = $unparsed
        PartialTail    = $partialTail
        UnparsedSamples = $unparsedSamples.ToArray()
    }
}

# ---------------------------------------------------------------------------
# Appariement des cycles "detection -> overlay affiche"
# ---------------------------------------------------------------------------

function Get-OverlayCycles {
    param([object[]]$Events)

    $counts = @{
        detect = 0; created = 0; built = 0; shown = 0; absent = 0
        'riot-minimized' = 0; 'riot-nofocus' = 0; other = 0
    }
    $cycles = New-Object System.Collections.Generic.List[object]
    $pending = $null
    $orphanCreated = 0
    $orphanBuilt = 0
    $orphanShown = 0

    foreach ($e in @($Events)) {
        $k = [string]$e.Kind
        if ($counts.ContainsKey($k)) { $counts[$k] = $counts[$k] + 1 }
        else { $counts['other'] = $counts['other'] + 1 }

        switch ($k) {
            'detect' {
                if ($null -ne $pending) {
                    $pending.Status = 'abandoned-new-detect'
                    $cycles.Add($pending)
                }
                $pending = [pscustomobject]@{
                    Detect  = $e
                    Created = $null
                    Built   = $null
                    Shown   = $null
                    Status  = 'pending'
                }
            }
            'created' {
                if ($null -ne $pending -and $null -eq $pending.Created) { $pending.Created = $e }
                else { $orphanCreated++ }
            }
            'built' {
                if ($null -ne $pending -and $null -ne $pending.Created -and $null -eq $pending.Built) { $pending.Built = $e }
                else { $orphanBuilt++ }
            }
            'shown' {
                if ($null -ne $pending) {
                    $pending.Shown = $e
                    $pending.Status = 'complete'
                    $cycles.Add($pending)
                    $pending = $null
                }
                else { $orphanShown++ }
            }
            'absent' {
                if ($null -ne $pending) {
                    $pending.Status = 'abandoned-absent'
                    $cycles.Add($pending)
                    $pending = $null
                }
            }
            default { }
        }
    }
    if ($null -ne $pending) {
        $pending.Status = 'partial-end'
        $cycles.Add($pending)
    }

    return [pscustomobject]@{
        Cycles         = $cycles
        Counts         = [pscustomobject]$counts
        OrphanCreated  = $orphanCreated
        OrphanBuilt    = $orphanBuilt
        OrphanShown    = $orphanShown
    }
}

function Get-CycleStats {
    param([object[]]$Cycles)

    $l1 = New-Object System.Collections.Generic.List[double]
    $l2 = New-Object System.Collections.Generic.List[double]
    $l3 = New-Object System.Collections.Generic.List[double]
    $l4 = New-Object System.Collections.Generic.List[double]
    $negative = 0
    $tooLong = New-Object System.Collections.Generic.List[object]

    foreach ($c in @($Cycles)) {
        if ($null -ne $c.Created) {
            $ms = ($c.Created.Ts - $c.Detect.Ts).TotalMilliseconds
            if ($ms -ge 0) { $l1.Add($ms) }
        }
        if ($null -ne $c.Created -and $null -ne $c.Built) {
            $ms = ($c.Built.Ts - $c.Created.Ts).TotalMilliseconds
            if ($ms -ge 0) { $l2.Add($ms) }
        }
        if ($null -ne $c.Built -and $null -ne $c.Shown) {
            $ms = ($c.Shown.Ts - $c.Built.Ts).TotalMilliseconds
            if ($ms -ge 0) { $l3.Add($ms) }
        }
        if ($null -ne $c.Shown) {
            $ms = ($c.Shown.Ts - $c.Detect.Ts).TotalMilliseconds
            if ($ms -lt 0) { $negative++ }
            elseif ($ms -gt $MaxLatencyMs) { $tooLong.Add($c) }
            else { $l4.Add($ms) }
        }
    }

    return [pscustomobject]@{
        DetectToCreated = Get-Stats -Values $l1.ToArray()
        CreatedToBuilt  = Get-Stats -Values $l2.ToArray()
        BuiltToShown    = Get-Stats -Values $l3.ToArray()
        DetectToShown   = Get-Stats -Values $l4.ToArray()
        NegativeCount   = $negative
        TooLongCount    = $tooLong.Count
    }
}

# ---------------------------------------------------------------------------
# Mode Analyze
# ---------------------------------------------------------------------------

function Invoke-AnalyzeMode {
    param(
        [string]$TagValue,
        [string]$OutDirResolved
    )

    $stamp = Get-Stamp
    $safeTag = Get-SafeTag -Value $TagValue
    $suffix = if ([string]::IsNullOrWhiteSpace($safeTag)) { '' } else { '-' + $safeTag }

    $files = Get-AnalysisLogFiles -Path $LogPath -WithRotated ([bool]$IncludeRotated)
    if (@($files).Count -eq 0) {
        Write-Status ("ERREUR : aucun log trouve ({0})." -f $(if ([string]::IsNullOrWhiteSpace($LogPath)) { Get-DefaultLogPath } else { $LogPath }))
        return [pscustomobject]@{ ExitCode = 2; Result = $null; Files = $null }
    }

    $read = Read-LogEvents -Files $files
    $pairing = Get-OverlayCycles -Events $read.Events
    $complete = New-Object System.Collections.Generic.List[object]
    $abandonedAbsent = 0
    $abandonedNewDetect = 0
    $partialEnd = 0
    foreach ($c in $pairing.Cycles) {
        switch ([string]$c.Status) {
            'complete' { $complete.Add($c) }
            'abandoned-absent' { $abandonedAbsent++ }
            'abandoned-new-detect' { $abandonedNewDetect++ }
            'partial-end' { $partialEnd++ }
            default { }
        }
    }
    $stats = Get-CycleStats -Cycles $pairing.Cycles

    # Cross-check log <-> fenetres observees maintenant.
    $inventory = Get-WindowInventory
    $summary = Get-WindowSummary -Windows $inventory.Items
    $crossStatus = 'NO-PAIR'
    $crossNotes = New-Object System.Collections.Generic.List[string]
    $lastCycle = $null
    if ($complete.Count -gt 0) { $lastCycle = $complete[$complete.Count - 1] }

    $overlayMatches = @()
    $riotMatches = @()
    if ($null -ne $lastCycle) {
        $logOverlayHandle = [int64]$lastCycle.Shown.Data.OverlayHandle
        $logDetectHwnd = [int64]$lastCycle.Detect.Data.Hwnd
        $overlayMatches = @($summary.Overlays | Where-Object { [int64]$_.Hwnd -eq $logOverlayHandle })
        $riotMatches = @($summary.RiotClients | Where-Object { [int64]$_.Hwnd -eq $logDetectHwnd })

        if ($summary.Overlays.Count -eq 0 -and $summary.RiotClients.Count -eq 0) {
            $crossStatus = 'WINDOWS-ABSENT'
            if ([bool]$lastCycle.Shown.Data.Created) { $crossNotes.Add('Le log indique un overlay cree/visible mais aucune fenetre overlay n''est enumeree maintenant (app peut-etre fermee ou overlay detruit).') }
        }
        elseif ($overlayMatches.Count -gt 0 -and $riotMatches.Count -gt 0) {
            $crossStatus = 'PASS'
            $ov = $overlayMatches[0]
            if ([bool]$lastCycle.Shown.Data.Visible -and -not [bool]$ov.Visible) {
                $crossStatus = 'MISMATCH'
                $crossNotes.Add('Le log dit visible=True, la fenetre observee est invisible.')
            }
            $layered = ($null -ne $ov.ExStyle -and (([int64]$ov.ExStyle -band $script:WS_EX_LAYERED) -ne 0))
            if ($null -ne $ov.ExStyle -and -not $layered) { $crossNotes.Add('WS_EX_LAYERED absent de l''overlay observe.') }
            if ($null -ne $ov.ExStyle -and ([int64]$ov.ExStyle -band $script:WS_EX_TOOLWINDOW) -eq 0) { $crossNotes.Add('WS_EX_TOOLWINDOW absent de l''overlay observe.') }
            if ($null -ne $ov.OwnerHwnd -and [int64]$ov.OwnerHwnd -ne 0 -and -not [bool]$ov.OwnerIsRiotClient) {
                $crossNotes.Add(("L'owner de l'overlay n'est pas la fenetre Riot Client (owner hwnd={0}, proc='{1}')." -f $ov.OwnerHwnd, $ov.OwnerProcessName))
            }
        }
        else {
            $crossStatus = 'MISMATCH'
            $crossNotes.Add(("Handles du log : overlay={0}, Riot={1} ; overlays observes={2}, clients Riot observes={3}." -f `
                $logOverlayHandle, $logDetectHwnd, $summary.Overlays.Count, $summary.RiotClients.Count))
        }
    }
    else {
        $crossNotes.Add('Aucun cycle complet dans le log : rien a comparer aux fenetres.')
        if ($summary.Overlays.Count -gt 0) {
            $crossNotes.Add(("Une fenetre overlay est pourtant visible maintenant : hwnd={0}." -f $summary.Overlays[0].Hwnd))
        }
    }

    # Fichiers de sortie.
    $pairsCsvPath = Join-Path $OutDirResolved ('verify-probe-{0}{1}-pairs.csv' -f $stamp, $suffix)
    $jsonPath = Join-Path $OutDirResolved ('verify-probe-{0}{1}.json' -f $stamp, $suffix)

    $headers = @('Index', 'Status', 'DetectTsUtc', 'CreatedTsUtc', 'BuiltTsUtc', 'ShownTsUtc',
        'DetectToCreatedMs', 'CreatedToBuiltMs', 'BuiltToShownMs', 'DetectToShownMs',
        'DetectHwnd', 'DetectPid', 'DetectRect', 'OverlayHandle', 'LogVisible', 'LogCreated', 'SourceFile')
    $rows = New-Object System.Collections.Generic.List[object]
    $idx = 0
    foreach ($c in $complete) {
        $idx++
        $d2c = $null; $c2b = $null; $b2s = $null; $d2s = $null
        if ($null -ne $c.Created) { $d2c = ($c.Created.Ts - $c.Detect.Ts).TotalMilliseconds }
        if ($null -ne $c.Created -and $null -ne $c.Built) { $c2b = ($c.Built.Ts - $c.Created.Ts).TotalMilliseconds }
        if ($null -ne $c.Built -and $null -ne $c.Shown) { $b2s = ($c.Shown.Ts - $c.Built.Ts).TotalMilliseconds }
        if ($null -ne $c.Shown) { $d2s = ($c.Shown.Ts - $c.Detect.Ts).TotalMilliseconds }
        $rows.Add(@(
                [string]$idx,
                'complete',
                $c.Detect.Ts.ToString('o', $script:Inv),
                $(if ($null -ne $c.Created) { $c.Created.Ts.ToString('o', $script:Inv) } else { '' }),
                $(if ($null -ne $c.Built) { $c.Built.Ts.ToString('o', $script:Inv) } else { '' }),
                $c.Shown.Ts.ToString('o', $script:Inv),
                $(if ($null -ne $d2c) { Format-Inv -Value $d2c -Fmt 'F3' } else { '' }),
                $(if ($null -ne $c2b) { Format-Inv -Value $c2b -Fmt 'F3' } else { '' }),
                $(if ($null -ne $b2s) { Format-Inv -Value $b2s -Fmt 'F3' } else { '' }),
                $(if ($null -ne $d2s) { Format-Inv -Value $d2s -Fmt 'F3' } else { '' }),
                [string]$c.Detect.Data.Hwnd,
                [string]$c.Detect.Data.Pid,
                [string]$c.Detect.Data.Rect,
                [string]$c.Shown.Data.OverlayHandle,
                [string]$c.Shown.Data.Visible,
                [string]$c.Shown.Data.Created,
                $c.Detect.SourceFile
            ))
    }
    Write-CsvRows -Path $pairsCsvPath -Headers $headers -Rows $rows.ToArray()

    $lastPairs = New-Object System.Collections.Generic.List[object]
    $startIdx = [Math]::Max(0, $complete.Count - 20)
    for ($i = $startIdx; $i -lt $complete.Count; $i++) {
        $c = $complete[$i]
        $lastPairs.Add([pscustomobject]@{
            DetectTsUtc    = $c.Detect.Ts.ToString('o', $script:Inv)
            ShownTsUtc     = $c.Shown.Ts.ToString('o', $script:Inv)
            LatencyMs      = [Math]::Round(($c.Shown.Ts - $c.Detect.Ts).TotalMilliseconds, 3)
            DetectHwnd     = [int64]$c.Detect.Data.Hwnd
            OverlayHandle  = [int64]$c.Shown.Data.OverlayHandle
        })
    }

    $result = [pscustomobject]@{
        tool          = $script:ToolName
        version       = $script:ToolVersion
        mode          = 'Analyze'
        timestampUtc  = [DateTimeOffset]::UtcNow.ToString('o', $script:Inv)
        host          = $env:COMPUTERNAME
        culture       = [string][System.Globalization.CultureInfo]::CurrentCulture.Name
        logRequested  = $(if ([string]::IsNullOrWhiteSpace($LogPath)) { Get-DefaultLogPath } else { $LogPath })
        logFiles      = $read.Files
        lines         = [pscustomobject]@{
            total          = [int](($read.Files | ForEach-Object { $_.Lines } | Measure-Object -Sum).Sum)
            unparsed       = $read.Unparsed
            partialTail    = $read.PartialTail
            unparsedSamples = $read.UnparsedSamples
        }
        eventCounts   = $pairing.Counts
        cycles        = [pscustomobject]@{
            complete            = $complete.Count
            abandonedAbsent     = $abandonedAbsent
            abandonedNewDetect  = $abandonedNewDetect
            partialEnd          = $partialEnd
            orphanCreated       = $pairing.OrphanCreated
            orphanBuilt         = $pairing.OrphanBuilt
            orphanShown         = $pairing.OrphanShown
        }
        latencyMs     = [pscustomobject]@{
            detectToCreated = $stats.DetectToCreated
            createdToBuilt  = $stats.CreatedToBuilt
            builtToShown    = $stats.BuiltToShown
            detectToShown   = $stats.DetectToShown
            negativeCount   = $stats.NegativeCount
            tooLongCount    = $stats.TooLongCount
        }
        lastPairs     = $lastPairs.ToArray()
        windows       = [pscustomobject]@{
            totalWindows  = $inventory.TotalWindows
            titledWindows = $inventory.TitledWindows
            overlayCount  = $summary.Overlays.Count
            riotClientCount = $summary.RiotClients.Count
            overlays      = @($summary.Overlays | ForEach-Object { Format-WindowLine -Window $_ })
            riotClients   = @($summary.RiotClients | ForEach-Object { Format-WindowLine -Window $_ })
            crossCheck    = [pscustomobject]@{
                status     = $crossStatus
                notes      = $crossNotes.ToArray()
                logOverlayHandle = $(if ($null -ne $lastCycle) { [int64]$lastCycle.Shown.Data.OverlayHandle } else { $null })
                logDetectHwnd    = $(if ($null -ne $lastCycle) { [int64]$lastCycle.Detect.Data.Hwnd } else { $null })
                lastPairDetectTs = $(if ($null -ne $lastCycle) { $lastCycle.Detect.Ts.ToString('o', $script:Inv) } else { $null })
                lastPairShownTs  = $(if ($null -ne $lastCycle) { $lastCycle.Shown.Ts.ToString('o', $script:Inv) } else { $null })
            }
        }
        files         = [pscustomobject]@{ pairsCsv = $pairsCsvPath; json = $jsonPath }
    }
    Write-JsonFile -Path $jsonPath -Object $result

    # Affichage console.
    Write-Status ""
    Write-Status ("=== {0} {1} - analyse du log ===" -f $script:ToolName, $script:ToolVersion)
    Write-Status ("Culture : {0} (sorties en culture invariante)" -f [System.Globalization.CultureInfo]::CurrentCulture.Name)
    foreach ($f in $read.Files) {
        Write-Status ("Log : {0} ({1} o, {2} lignes, {3} .. {4})" -f $f.Path, $f.Bytes, $f.Lines, $f.FirstTs, $f.LastTs)
    }
    Write-Status ("Lignes non parsees : {0}{1}" -f $read.Unparsed, $(if ($read.PartialTail) { ' (+1 ligne finale partielle toleree)' } else { '' }))
    Write-Status ("Evenements : detect={0} created={1} built={2} shown={3} absent={4} mini={5} nofocus={6} autres={7}" -f `
        $pairing.Counts.detect, $pairing.Counts.created, $pairing.Counts.built, $pairing.Counts.shown,
        $pairing.Counts.absent, $pairing.Counts.'riot-minimized', $pairing.Counts.'riot-nofocus', $pairing.Counts.other)
    Write-Status ("Cycles : complets={0} | abandonnes(absente)={1} | abandonnes(nouvelle detection)={2} | partiels={3} | orphelins created={4} built={5} shown={6}" -f `
        $complete.Count, $abandonedAbsent, $abandonedNewDetect, $partialEnd, $pairing.OrphanCreated, $pairing.OrphanBuilt, $pairing.OrphanShown)
    if ($null -ne $stats.DetectToShown) {
        $s = $stats.DetectToShown
        Write-Status ("Latence detection -> overlay affiche (ms) : n={0} min {1} / moy {2} / med {3} / p95 {4} / max {5} / ecart-type {6}" -f `
            $s.Count, (Format-Inv $s.Min), (Format-Inv $s.Mean), (Format-Inv $s.Median), (Format-Inv $s.P95), (Format-Inv $s.Max), (Format-Inv $s.StdDev -Fmt 'F3'))
    }
    $steps = @(
        @{ Name = 'detection -> creation'; Stats = $stats.DetectToCreated },
        @{ Name = 'creation -> construction'; Stats = $stats.CreatedToBuilt },
        @{ Name = 'construction -> affichage'; Stats = $stats.BuiltToShown }
    )
    foreach ($st in $steps) {
        if ($null -ne $st.Stats) {
            Write-Status ("  {0} (ms) : n={1} min {2} / moy {3} / med {4} / max {5}" -f $st.Name, $st.Stats.Count, (Format-Inv $st.Stats.Min), (Format-Inv $st.Stats.Mean), (Format-Inv $st.Stats.Median), (Format-Inv $st.Stats.Max))
        }
    }
    if ($stats.NegativeCount -gt 0) { Write-Status ("ATTENTION : {0} latence(s) negative(s) ignoree(s)." -f $stats.NegativeCount) }
    if ($stats.TooLongCount -gt 0) { Write-Status ("ATTENTION : {0} paire(s) au-dela de {1} ms ignoree(s) (probable dechet log)." -f $stats.TooLongCount, $MaxLatencyMs) }
    Write-Status ("Cross-check fenetres : {0}" -f $crossStatus)
    foreach ($n in $crossNotes) { Write-Status ("  note : {0}" -f $n) }
    if ($summary.Overlays.Count -gt 0) { foreach ($o in $summary.Overlays) { Write-Status ("  overlay observe : {0}" -f (Format-WindowLine -Window $o)) } }
    if ($summary.RiotClients.Count -gt 0) { foreach ($r in $summary.RiotClients) { Write-Status ("  client Riot observe : {0}" -f (Format-WindowLine -Window $r)) } }
    Write-Status ""
    Write-Status ("Fichiers : {0}" -f $pairsCsvPath)
    Write-Status ("           {0}" -f $jsonPath)

    $exitCode = 0
    if ($StrictWindows -and $crossStatus -eq 'MISMATCH') { $exitCode = 6 }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Result   = $result
        Files    = $result.files
        Stats    = $stats
        Complete = $complete.Count
    }
}

# ---------------------------------------------------------------------------
# Mode Snapshot
# ---------------------------------------------------------------------------

function Invoke-SnapshotMode {
    param(
        [string]$TagValue,
        [string]$OutDirResolved
    )
    $inventory = Get-WindowInventory
    $summary = Get-WindowSummary -Windows $inventory.Items
    $stamp = Get-Stamp
    $safeTag = Get-SafeTag -Value $TagValue
    $suffix = if ([string]::IsNullOrWhiteSpace($safeTag)) { '' } else { '-' + $safeTag }

    $jsonPath = Join-Path $OutDirResolved ('verify-probe-snapshot-{0}{1}.json' -f $stamp, $suffix)
    $csvPath = Join-Path $OutDirResolved ('verify-probe-snapshot-{0}{1}.csv' -f $stamp, $suffix)

    $overlaySatisfied = ($summary.Overlays.Count -gt 0)
    $riotSatisfied = ($summary.RiotClients.Count -gt 0)
    $verdict = 'PASS'
    if ($ExpectOverlay -and -not $overlaySatisfied) { $verdict = 'NO-OVERLAY' }
    if ($ExpectRiotClient -and -not $riotSatisfied) { $verdict = 'NO-RIOT-CLIENT' }

    $result = [pscustomobject]@{
        tool         = $script:ToolName
        version      = $script:ToolVersion
        mode         = 'Snapshot'
        timestampUtc = [DateTimeOffset]::UtcNow.ToString('o', $script:Inv)
        host         = $env:COMPUTERNAME
        culture      = [string][System.Globalization.CultureInfo]::CurrentCulture.Name
        windows      = [pscustomobject]@{
            totalWindows  = $inventory.TotalWindows
            titledWindows = $inventory.TitledWindows
            overlayCount  = $summary.Overlays.Count
            riotClientCount = $summary.RiotClients.Count
            overlays      = @($summary.Overlays | ForEach-Object {
                    [pscustomobject]@{
                        hwnd = [int64]$_.Hwnd; title = $_.Title; className = $_.ClassName
                        pid = $_.Pid; processName = $_.ProcessName; visible = $_.Visible
                        rect = [pscustomobject]@{ left = $_.Left; top = $_.Top; width = $_.Width; height = $_.Height }
                        exStyle = $_.ExStyle
                        layered = ($null -ne $_.ExStyle -and (([int64]$_.ExStyle -band $script:WS_EX_LAYERED) -ne 0))
                        toolWindow = ($null -ne $_.ExStyle -and (([int64]$_.ExStyle -band $script:WS_EX_TOOLWINDOW) -ne 0))
                        noActivate = ($null -ne $_.ExStyle -and (([int64]$_.ExStyle -band $script:WS_EX_NOACTIVATE) -ne 0))
                        ownerHwnd = [int64]$_.OwnerHwnd
                        ownerTitle = $_.OwnerTitle
                        ownerProcessName = $_.OwnerProcessName
                        ownerIsRiotClient = $_.OwnerIsRiotClient
                    }
                })
            riotClients   = @($summary.RiotClients | ForEach-Object {
                    [pscustomobject]@{
                        hwnd = [int64]$_.Hwnd; title = $_.Title; className = $_.ClassName
                        pid = $_.Pid; processName = $_.ProcessName; visible = $_.Visible
                        rect = [pscustomobject]@{ left = $_.Left; top = $_.Top; width = $_.Width; height = $_.Height }
                        minSizeOk = ($null -ne $_.Width -and $_.Width -ge 1000 -and $_.Height -ge 700)
                    }
                })
            expectations = [pscustomobject]@{
                expectOverlay = [bool]$ExpectOverlay
                expectRiotClient = [bool]$ExpectRiotClient
                overlaySatisfied = $overlaySatisfied
                riotClientSatisfied = $riotSatisfied
                verdict = $verdict
            }
        }
        files        = [pscustomobject]@{ csv = $csvPath; json = $jsonPath }
    }
    Write-JsonFile -Path $jsonPath -Object $result

    $headers = @('Class', 'Hwnd', 'Title', 'ClassName', 'Pid', 'ProcessName', 'Visible',
        'Left', 'Top', 'Width', 'Height', 'ExStyle', 'OwnerHwnd', 'OwnerTitle', 'OwnerProcessName')
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($w in $summary.Overlays) {
        $rows.Add(@('overlay', [string]$w.Hwnd, $w.Title, $w.ClassName, [string]$w.Pid, [string]$w.ProcessName, [string]$w.Visible,
                [string]$w.Left, [string]$w.Top, [string]$w.Width, [string]$w.Height,
                $(if ($null -ne $w.ExStyle) { [string]$w.ExStyle } else { '' }), [string]$w.OwnerHwnd, [string]$w.OwnerTitle, [string]$w.OwnerProcessName)) | Out-Null
    }
    foreach ($w in $summary.RiotClients) {
        $rows.Add(@('riot-client', [string]$w.Hwnd, $w.Title, $w.ClassName, [string]$w.Pid, [string]$w.ProcessName, [string]$w.Visible,
                [string]$w.Left, [string]$w.Top, [string]$w.Width, [string]$w.Height,
                $(if ($null -ne $w.ExStyle) { [string]$w.ExStyle } else { '' }), [string]$w.OwnerHwnd, [string]$w.OwnerTitle, [string]$w.OwnerProcessName)) | Out-Null
    }
    Write-CsvRows -Path $csvPath -Headers $headers -Rows $rows.ToArray()

    Write-Status ""
    Write-Status ("=== {0} {1} - instantane des fenetres ===" -f $script:ToolName, $script:ToolVersion)
    Write-Status ("Fenetres de premier niveau : {0} (avec titre : {1})" -f $inventory.TotalWindows, $inventory.TitledWindows)
    Write-Status ("Overlays 'RiotSwitch' visibles : {0}" -f $summary.Overlays.Count)
    foreach ($o in $summary.Overlays) { Write-Status ("  {0}" -f (Format-WindowLine -Window $o)) }
    Write-Status ("Fenetres 'Riot Client' visibles : {0}" -f $summary.RiotClients.Count)
    foreach ($r in $summary.RiotClients) { Write-Status ("  {0}" -f (Format-WindowLine -Window $r)) }
    Write-Status ("Verdict : {0}" -f $verdict)
    Write-Status ("Fichiers : {0}" -f $csvPath)
    Write-Status ("           {0}" -f $jsonPath)

    $exitCode = 0
    if (($ExpectOverlay -and -not $overlaySatisfied) -or ($ExpectRiotClient -and -not $riotSatisfied)) { $exitCode = 5 }
    return [pscustomobject]@{ ExitCode = $exitCode; Result = $result; Files = $result.files }
}

# ---------------------------------------------------------------------------
# Mode Watch
# ---------------------------------------------------------------------------

function Get-LastLogPairAfter {
    # Derniere paire complete du log dont l'affichage est posterieur a SinceUtc.
    param([DateTimeOffset]$SinceUtc)
    $files = Get-AnalysisLogFiles -Path $LogPath -WithRotated $false
    if (@($files).Count -eq 0) { return $null }
    $read = Read-LogEvents -Files $files
    $pairing = Get-OverlayCycles -Events $read.Events
    $last = $null
    foreach ($c in $pairing.Cycles) {
        if ([string]$c.Status -ne 'complete') { continue }
        if ($null -eq $c.Shown) { continue }
        if ($c.Shown.Ts -ge $SinceUtc) { $last = $c }
    }
    return $last
}

function Invoke-WatchMode {
    param(
        [string]$TagValue,
        [string]$OutDirResolved
    )
    $stamp = Get-Stamp
    $safeTag = Get-SafeTag -Value $TagValue
    $suffix = if ([string]::IsNullOrWhiteSpace($safeTag)) { '' } else { '-' + $safeTag }
    $jsonPath = Join-Path $OutDirResolved ('verify-probe-watch-{0}{1}.json' -f $stamp, $suffix)
    $csvPath = Join-Path $OutDirResolved ('verify-probe-watch-{0}{1}-transitions.csv' -f $stamp, $suffix)

    $watchStart = [DateTimeOffset]::UtcNow
    $deadline = $watchStart.AddSeconds($DurationSec)
    $transitions = New-Object System.Collections.Generic.List[object]
    $pollCount = 0
    $errors = 0

    $prevOverlay = @{}
    $prevRiot = @{}
    $firstRiotSeen = $null
    $firstOverlaySeen = $null
    $firstOverlayInfo = $null

    Write-Status ""
    Write-Status ("=== {0} {1} - observation des fenetres ({2} s, scrutation {3} ms) ===" -f $script:ToolName, $script:ToolVersion, $DurationSec, $PollMs)

    # Etat initial : les fenetres deja presentes au demarrage sont la ligne de
    # base et ne comptent pas comme des transitions (sinon une apparition
    # ancienne serait datee a tort au debut de la veille).
    try {
        $initialInventory = Get-WindowInventory
        $initialSummary = Get-WindowSummary -Windows $initialInventory.Items
        foreach ($o in $initialSummary.Overlays) { $prevOverlay[[int64]$o.Hwnd] = $o }
        foreach ($r in $initialSummary.RiotClients) { $prevRiot[[int64]$r.Hwnd] = $r }
    }
    catch { $errors++ }

    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $pollCount++
        $now = [DateTimeOffset]::UtcNow
        try {
            $inventory = Get-WindowInventory
            $summary = Get-WindowSummary -Windows $inventory.Items
            $currentOverlay = @{}
            foreach ($o in $summary.Overlays) { $currentOverlay[[int64]$o.Hwnd] = $o }
            $currentRiot = @{}
            foreach ($r in $summary.RiotClients) { $currentRiot[[int64]$r.Hwnd] = $r }

            foreach ($h in $currentRiot.Keys) {
                if (-not $prevRiot.ContainsKey($h)) {
                    $w = $currentRiot[$h]
                    $transitions.Add([pscustomobject]@{ Kind = 'riot-appear'; Utc = $now; Hwnd = [int64]$h; Window = $w })
                    if ($null -eq $firstRiotSeen) { $firstRiotSeen = $now }
                }
            }
            foreach ($h in $prevRiot.Keys) {
                if (-not $currentRiot.ContainsKey($h)) {
                    $transitions.Add([pscustomobject]@{ Kind = 'riot-disappear'; Utc = $now; Hwnd = [int64]$h; Window = $null })
                }
            }
            foreach ($h in $currentOverlay.Keys) {
                if (-not $prevOverlay.ContainsKey($h)) {
                    $w = $currentOverlay[$h]
                    $transitions.Add([pscustomobject]@{ Kind = 'overlay-appear'; Utc = $now; Hwnd = [int64]$h; Window = $w })
                    if ($null -eq $firstOverlaySeen) {
                        $firstOverlaySeen = $now
                        $firstOverlayInfo = $w
                    }
                }
            }
            foreach ($h in $prevOverlay.Keys) {
                if (-not $currentOverlay.ContainsKey($h)) {
                    $transitions.Add([pscustomobject]@{ Kind = 'overlay-disappear'; Utc = $now; Hwnd = [int64]$h; Window = $null })
                }
            }
            $prevOverlay = $currentOverlay
            $prevRiot = $currentRiot
        }
        catch {
            $errors++
        }
        $remainingMs = [int]($deadline - [DateTimeOffset]::UtcNow).TotalMilliseconds
        if ($remainingMs -le 0) { break }
        Start-Sleep -Milliseconds ([Math]::Min($PollMs, $remainingMs))
    }

    # Comparaison avec le log applicatif (derniere paire affichee pendant la veille).
    $logPair = $null
    try { $logPair = Get-LastLogPairAfter -SinceUtc $watchStart.AddSeconds(-5) } catch { $logPair = $null }

    $observedLatencyMs = $null
    if ($null -ne $firstRiotSeen -and $null -ne $firstOverlaySeen) {
        $observedLatencyMs = ($firstOverlaySeen - $firstRiotSeen).TotalMilliseconds
    }
    $logLatencyMs = $null
    $logDetectToObservedOverlayMs = $null
    $logShowToObservedOverlayMs = $null
    if ($null -ne $logPair) {
        $logLatencyMs = ($logPair.Shown.Ts - $logPair.Detect.Ts).TotalMilliseconds
        if ($null -ne $firstOverlaySeen) {
            $logDetectToObservedOverlayMs = ($firstOverlaySeen - $logPair.Detect.Ts).TotalMilliseconds
            $logShowToObservedOverlayMs = ($firstOverlaySeen - $logPair.Shown.Ts).TotalMilliseconds
        }
    }

    $compareStatus = 'NO-DATA'
    $compareToleranceMs = 2 * $PollMs + 100
    if ($null -ne $observedLatencyMs -and $null -ne $logLatencyMs) {
        $diff = $observedLatencyMs - $logLatencyMs
        if ([Math]::Abs($diff) -le $compareToleranceMs) { $compareStatus = 'PASS' }
        else { $compareStatus = 'DIFF' }
    }
    elseif ($null -eq $firstOverlaySeen -and $null -ne $logPair) {
        $compareStatus = 'OVERLAY-NOT-OBSERVED'
    }

    $overlaySeen = ($null -ne $firstOverlaySeen)
    $riotSeen = ($null -ne $firstRiotSeen -or $null -ne $logPair)
    $verdict = 'PASS'
    if ($ExpectOverlay -and -not $overlaySeen) { $verdict = 'NO-OVERLAY' }
    if ($ExpectRiotClient -and -not $riotSeen) { $verdict = 'NO-RIOT-CLIENT' }

    $result = [pscustomobject]@{
        tool         = $script:ToolName
        version      = $script:ToolVersion
        mode         = 'Watch'
        timestampUtc = [DateTimeOffset]::UtcNow.ToString('o', $script:Inv)
        host         = $env:COMPUTERNAME
        culture      = [string][System.Globalization.CultureInfo]::CurrentCulture.Name
        watch        = [pscustomobject]@{
            startUtc      = $watchStart.ToString('o', $script:Inv)
            endUtc        = [DateTimeOffset]::UtcNow.ToString('o', $script:Inv)
            durationSec   = $DurationSec
            pollMs        = $PollMs
            pollCount     = $pollCount
            pollErrors    = $errors
            transitionCount = $transitions.Count
            firstRiotSeenUtc = $(if ($null -ne $firstRiotSeen) { $firstRiotSeen.ToString('o', $script:Inv) } else { $null })
            firstOverlaySeenUtc = $(if ($null -ne $firstOverlaySeen) { $firstOverlaySeen.ToString('o', $script:Inv) } else { $null })
            firstOverlay = $(if ($null -ne $firstOverlayInfo) { Format-WindowLine -Window $firstOverlayInfo } else { $null })
        }
        observedLatencyMs = $observedLatencyMs
        logPair      = $(if ($null -ne $logPair) {
                [pscustomobject]@{
                    detectTsUtc   = $logPair.Detect.Ts.ToString('o', $script:Inv)
                    shownTsUtc    = $logPair.Shown.Ts.ToString('o', $script:Inv)
                    latencyMs     = $logLatencyMs
                    detectHwnd    = [int64]$logPair.Detect.Data.Hwnd
                    overlayHandle = [int64]$logPair.Shown.Data.OverlayHandle
                }
            } else { $null })
        comparison   = [pscustomobject]@{
            logLatencyMs          = $logLatencyMs
            observedLatencyMs     = $observedLatencyMs
            diffMs                = $(if ($null -ne $observedLatencyMs -and $null -ne $logLatencyMs) { $observedLatencyMs - $logLatencyMs } else { $null })
            toleranceMs           = $compareToleranceMs
            status                = $compareStatus
            logDetectToObservedOverlayMs = $logDetectToObservedOverlayMs
            logShowToObservedOverlayMs   = $logShowToObservedOverlayMs
        }
        expectations = [pscustomobject]@{
            expectOverlay    = [bool]$ExpectOverlay
            expectRiotClient = [bool]$ExpectRiotClient
            overlaySeen      = $overlaySeen
            riotSeen         = $riotSeen
            verdict          = $verdict
        }
        transitions  = @($transitions | ForEach-Object {
                [pscustomobject]@{
                    kind = $_.Kind
                    utc  = $_.Utc.ToString('o', $script:Inv)
                    hwnd = $_.Hwnd
                    window = $(if ($null -ne $_.Window) { Format-WindowLine -Window $_.Window } else { $null })
                }
            })
        files        = [pscustomobject]@{ transitionsCsv = $csvPath; json = $jsonPath }
    }
    Write-JsonFile -Path $jsonPath -Object $result

    $headers = @('Kind', 'Utc', 'Hwnd', 'Window')
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($t in $transitions) {
        $rows.Add(@($t.Kind, $t.Utc.ToString('o', $script:Inv), [string]$t.Hwnd,
                $(if ($null -ne $t.Window) { Format-WindowLine -Window $t.Window } else { '' }))) | Out-Null
    }
    Write-CsvRows -Path $csvPath -Headers $headers -Rows $rows.ToArray()

    Write-Status ("Scrutations : {0} (erreurs : {1}) | transitions : {2}" -f $pollCount, $errors, $transitions.Count)
    foreach ($t in $transitions) {
        Write-Status ("  {0} hwnd={1} a {2}" -f $t.Kind, $t.Hwnd, $t.Utc.ToString('HH:mm:ss.fff', $script:Inv))
    }
    if ($null -ne $observedLatencyMs) { Write-Status ("Latence observee (fenetres) : {0} ms" -f (Format-Inv $observedLatencyMs)) }
    else { Write-Status 'Latence observee : indisponible (fenetre Riot et/ou overlay non observees pendant la veille).' }
    if ($null -ne $logPair) {
        Write-Status ("Paire log : {0} -> {1} = {2} ms" -f $logPair.Detect.Ts.ToString('HH:mm:ss.fff', $script:Inv), $logPair.Shown.Ts.ToString('HH:mm:ss.fff', $script:Inv), (Format-Inv $logLatencyMs))
    }
    Write-Status ("Comparaison log/observe : {0} (tolerance {1} ms)" -f $compareStatus, $compareToleranceMs)
    Write-Status ("Verdict : {0}" -f $verdict)
    Write-Status ("Fichiers : {0}" -f $csvPath)
    Write-Status ("           {0}" -f $jsonPath)

    $exitCode = 0
    if (($ExpectOverlay -and -not $overlaySeen) -or ($ExpectRiotClient -and -not $riotSeen)) { $exitCode = 5 }
    return [pscustomobject]@{ ExitCode = $exitCode; Result = $result; Files = $result.files }
}

# ---------------------------------------------------------------------------
# Mode SelfTest
# ---------------------------------------------------------------------------

function Split-CsvLine {
    # Decoupe une ligne CSV en respectant les champs entre guillemets (double "" = ").
    param([string]$Line)
    $fields = New-Object System.Collections.Generic.List[string]
    $sb = New-Object System.Text.StringBuilder
    $inQuotes = $false
    $i = 0
    while ($i -lt $Line.Length) {
        $ch = $Line[$i]
        if ($inQuotes) {
            if ($ch -eq [char]'"') {
                if (($i + 1) -lt $Line.Length -and $Line[$i + 1] -eq [char]'"') {
                    [void]$sb.Append('"')
                    $i++
                }
                else {
                    $inQuotes = $false
                }
            }
            else {
                [void]$sb.Append($ch)
            }
        }
        else {
            if ($ch -eq [char]'"') { $inQuotes = $true }
            elseif ($ch -eq [char]',') {
                $fields.Add($sb.ToString())
                [void]$sb.Clear()
            }
            else { [void]$sb.Append($ch) }
        }
        $i++
    }
    $fields.Add($sb.ToString())
    return $fields.ToArray()
}

function Read-CsvForValidation {
    param([string]$Path)
    $lines = [System.IO.File]::ReadAllLines($Path, (New-Object System.Text.UTF8Encoding($false)))
    if ($lines.Count -lt 2) { throw ('CSV vide : {0}' -f $Path) }
    $header = $lines[0]
    $expected = (Split-CsvLine -Line $header).Count
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($line in @($lines | Select-Object -Skip 1)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $fields = Split-CsvLine -Line $line
        if ($fields.Count -ne $expected) { throw ('CSV {0} : {1} champs au lieu de {2}' -f $Path, $fields.Count, $expected) }
        $rows.Add($fields)
    }
    return [pscustomobject]@{ Header = $header; FieldCount = $expected; Rows = $rows.ToArray() }
}

function Invoke-SelfTestMode {
    param([string]$OutDirResolved)

    $failures = New-Object System.Collections.Generic.List[string]
    $details = New-Object System.Collections.Generic.List[string]
    Write-Status ""
    Write-Status ("=== AUTO-TEST {0} {1} ===" -f $script:ToolName, $script:ToolVersion)
    Write-Status 'Aucune interaction UI ; lecture passive des fenetres et des logs ; RiotSwitch n''est pas manipule.'

    # --- Test 1 : EnumWindows / P/Invoke ---------------------------------------
    try {
        $inventory = Get-WindowInventory
        if ($inventory.TotalWindows -lt 1) { $failures.Add('Test 1 : EnumWindows ne retourne aucune fenetre de premier niveau') }
        if ($inventory.TitledWindows -lt 1) { $failures.Add('Test 1 : aucune fenetre avec titre exploitable') }

        $probe = $null
        foreach ($w in $inventory.Items) {
            if ($w.Visible -and $w.Pid -gt 4 -and -not [string]::IsNullOrWhiteSpace($w.ProcessName) -and
                $null -ne $w.Width -and $w.Width -gt 0 -and $w.Height -gt 0) {
                $probe = $w
                break
            }
        }
        if ($null -eq $probe) {
            $failures.Add('Test 1 : aucune fenetre visible credible (pid/process/rect) pour valider GetWindowRect')
        }
        else {
            if ($null -eq $probe.ExStyle) { $failures.Add('Test 1 : GetWindowLongPtr n a pas retourne ExStyle') }
            $details.Add(("EnumWindows : {0} fenetres de premier niveau, {1} avec titre ; sonde hwnd={2} proc='{3}' rect={4}x{5} exStyle={6}" -f `
                $inventory.TotalWindows, $inventory.TitledWindows, $probe.Hwnd, $probe.ProcessName, $probe.Width, $probe.Height, $probe.ExStyle))
        }

        $summary = Get-WindowSummary -Windows $inventory.Items
        $details.Add(("Instantane : overlays={0}, clients Riot={1} (classification passive, aucune attente)" -f $summary.Overlays.Count, $summary.RiotClients.Count))
        foreach ($w in $inventory.Items) {
            if ([string]::Equals($w.Title, $script:OverlayTitle, [StringComparison]::Ordinal) -and -not $w.IsOverlay) {
                $details.Add(("Fenetre titree '{0}' non classee overlay : proc='{1}' visible={2} (information)" -f $w.Title, $w.ProcessName, $w.Visible))
            }
        }
    }
    catch {
        $failures.Add(('Test 1 : exception EnumWindows : ' + [string]$_.Exception.Message))
    }

    # --- Test 2 : analyse du log existant -------------------------------------
    $analyzeResult = $null
    $selftestTag = 'selftest'
    try {
        $analyzeResult = Invoke-AnalyzeMode -TagValue $selftestTag -OutDirResolved $OutDirResolved
        if ($analyzeResult.ExitCode -eq 2) {
            $failures.Add('Test 2 : log applicatif introuvable ou vide')
        }
        elseif ($null -eq $analyzeResult.Result) {
            $failures.Add('Test 2 : aucun resultat d analyse produit')
        }
        else {
            $r = $analyzeResult.Result
            if ($r.lines.unparsed -gt 0) { $failures.Add(("Test 2 : {0} ligne(s) non parsee(s) hors ligne finale partielle" -f $r.lines.unparsed)) }
            if ($r.eventCounts.detect -lt 1) { $failures.Add('Test 2 : aucune detection Riot dans le log') }
            if ($r.cycles.complete -lt 1) { $failures.Add('Test 2 : aucun cycle detection->affichage complet') }
            if ($r.lastPairs.Count -lt 1) { $failures.Add('Test 2 : aucune paire exploitable') }

            $st = $analyzeResult.Stats.DetectToShown
            if ($null -eq $st) { $failures.Add('Test 2 : statistiques detect->shown absentes') }
            else {
                if ($st.Count -lt 1) { $failures.Add('Test 2 : statistiques detect->shown vides') }
                if ($st.Min -lt 0) { $failures.Add('Test 2 : latence minimale negative') }
                if ($st.Min -gt $st.Max) { $failures.Add('Test 2 : min > max') }
                if ($st.Median -lt $st.Min -or $st.Median -gt $st.Max) { $failures.Add('Test 2 : mediane hors bornes') }
                if ($st.Mean -lt $st.Min -or $st.Mean -gt $st.Max) { $failures.Add('Test 2 : moyenne hors bornes') }
                if ($st.StdDev -lt 0) { $failures.Add('Test 2 : ecart-type negatif') }
                if ($st.Max -gt $MaxLatencyMs) { $failures.Add('Test 2 : latence maximale au-dela du seuil') }
                $details.Add(("Log : {0} lignes, {1} detections, {2} cycles complets ; latence detect->shown : n={3} min {4} / moy {5} / med {6} / p95 {7} / max {8} ms" -f `
                    $r.lines.total, $r.eventCounts.detect, $r.cycles.complete, $st.Count, (Format-Inv $st.Min), (Format-Inv $st.Mean), (Format-Inv $st.Median), (Format-Inv $st.P95), (Format-Inv $st.Max)))
            }
            $details.Add(("Cross-check fenetres (analyse) : {0}" -f $r.windows.crossCheck.status))
            if ($r.windows.crossCheck.status -eq 'MISMATCH') {
                $details.Add('Cross-check fenetres MISMATCH (informatif en phase A : aucune exigence de coherence hors GO).')
            }

            # CSV des paires
            if (-not (Test-Path -LiteralPath $r.files.pairsCsv)) { $failures.Add('Test 2 : CSV des paires absent') }
            else {
                try {
                    $csv = Read-CsvForValidation -Path $r.files.pairsCsv
                    if ($csv.Rows.Count -ne $r.cycles.complete) { throw ("CSV : {0} lignes pour {1} cycles complets" -f $csv.Rows.Count, $r.cycles.complete) }
                    foreach ($row in $csv.Rows) {
                        foreach ($cell in @($row[0], $row[6], $row[9])) {
                            if ([string]$cell -notmatch '^-?\d+(\.\d+)?$') { throw ("CSV : valeur non numerique '{0}'" -f $cell) }
                        }
                    }
                    $details.Add(("CSV des paires : {0} lignes, {1} champs, decimales invariantes" -f $csv.Rows.Count, $csv.FieldCount))
                }
                catch { $failures.Add([string]$_.Exception.Message) }
            }

            # JSON
            if (-not (Test-Path -LiteralPath $r.files.json)) { $failures.Add('Test 2 : JSON absent') }
            else {
                try {
                    $jsonRaw = [System.IO.File]::ReadAllText($r.files.json, (New-Object System.Text.UTF8Encoding($false)))
                    $json = $jsonRaw | ConvertFrom-Json
                    if ($json.mode -ne 'Analyze') { throw 'JSON : mode inattendu' }
                    if ($null -eq $json.latencyMs.detectToShown) { throw 'JSON : stats detect->shown absentes' }
                    if ([int]$json.latencyMs.detectToShown.Count -ne $r.cycles.complete) { throw 'JSON : nombre de latences incoherent' }
                    if ($jsonRaw -match '"(Min|Mean|Median|P95|Max|StdDev|LatencyMs)"\s*:\s*-?\d+,\d+') { throw 'JSON : decimales a virgule detectees' }
                    $details.Add('JSON : relu et structure valide (decimales invariantes)')
                }
                catch { $failures.Add([string]$_.Exception.Message) }
            }
        }
    }
    catch {
        $failures.Add(('Test 2 : exception analyse du log : ' + [string]$_.Exception.Message))
    }

    # --- Nettoyage des artefacts de l'auto-test -------------------------------
    if (-not $KeepSelfTestArtifacts -and $null -ne $analyzeResult -and $null -ne $analyzeResult.Files) {
        try {
            foreach ($f in @($analyzeResult.Files.pairsCsv, $analyzeResult.Files.json)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$f) -and (Test-Path -LiteralPath $f)) {
                    $leaf = Split-Path -Leaf $f
                    if ($leaf -match 'selftest') { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
                }
            }
            $details.Add('Artefacts de l auto-test supprimes (utiliser -KeepSelfTestArtifacts pour les conserver).')
        }
        catch { }
    }

    Write-Status ''
    foreach ($d in $details) { Write-Status ('  ' + $d) }
    Write-Status ''
    if ($failures.Count -eq 0) {
        Write-Status 'SELFTEST : PASS'
        return 0
    }
    Write-Status 'SELFTEST : FAIL'
    foreach ($f in $failures) { Write-Status ('  - ' + $f) }
    return 4
}

# ---------------------------------------------------------------------------
# Point d'entree
# ---------------------------------------------------------------------------

function Invoke-Main {
    $outDirResolved = Initialize-OutDir -Path $OutDir
    switch ($Mode) {
        'Analyze' { return (Invoke-AnalyzeMode -TagValue $Tag -OutDirResolved $outDirResolved) }
        'Snapshot' { return (Invoke-SnapshotMode -TagValue $Tag -OutDirResolved $outDirResolved) }
        'Watch' { return (Invoke-WatchMode -TagValue $Tag -OutDirResolved $outDirResolved) }
        'SelfTest' { return [pscustomobject]@{ ExitCode = (Invoke-SelfTestMode -OutDirResolved $outDirResolved) } }
        default { throw ('Mode inconnu : {0}' -f $Mode) }
    }
}

try {
    $main = Invoke-Main
    exit ([int]$main.ExitCode)
}
catch {
    Write-Host ''
    Write-Host ('ERREUR INATTENDUE {0} : {1}' -f $script:ToolName, $_)
    Write-Host ($_.ScriptStackTrace)
    exit 1
}
