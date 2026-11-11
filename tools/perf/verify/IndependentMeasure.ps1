#requires -Version 5.1
<#
.SYNOPSIS
    Mesure INDEPENDANTE de la consommation d'un processus Windows (CPU, RAM, GDI,
    handles) pour la campagne de verification RiotSwitch.

.DESCRIPTION
    Outil de verification independante : il ne reutilise AUCUN code de
    tools/perf/sampler, tools/perf/driver ou tools/perf/probe. Deux methodes
    distinctes sont utilisees puis comparees (cross-check) :

      1) Methode "compteurs de performance" (sous-systeme PDH de Windows) :
         Get-Counter sur les compteurs localises du jeu "Processus"/"Process",
         dont les noms sont decouverts DYNAMIQUEMENT (pas de noms codes en dur
         pour le francais). Le nom d'instance de performance du PID est resolu
         par ligne de commande : CIM/WMI Win32_PerfFormattedData_PerfProc_Process.
      2) Methode "processus direct" : Get-Process a 1 Hz pendant N secondes
         (.TotalProcessorTime, .WorkingSet64, .PrivateMemorySize64,
         .HandleCount, .Threads.Count), + GetGuiResources (P/Invoke user32)
         pour les objets GDI/USER.

    Les deux methodes tournent SIMULTANEMENT (collection Get-Counter dans un
    runspace dedie) afin de mesurer la meme fenetre temporelle.
    Le premier echantillon de chaque serie est exclu du cross-check (chauffe PDH
    des compteurs de type taux), ce qui est documente dans le README.

.PARAMETER ProcessName
    Nom du processus cible (sans .exe), resolu par nom a l'execution.
    Defaut : RiotSwitch. La mesure d'un processus de la famille Riot
    (RiotSwitch, Riot Client, LeagueClient, VALORANT...) est BLOQUEE sans
    -AllowAppProcess : cette securite evite toute mesure reelle avant le GO de
    la phase B.

.PARAMETER ProcessId
    PID cible. A utiliser si plusieurs processus partagent le meme nom.

.PARAMETER DurationSec
    Duree de la fenetre de mesure, en secondes (defaut 60).

.PARAMETER IntervalSec
    Periode d'echantillonnage directe, en secondes (defaut 1.0 = 1 Hz).

.PARAMETER Tag
    Etiquette libre ajoutee aux noms de fichiers de sortie (ex. W, R, S).

.PARAMETER OutDir
    Dossier de sortie (defaut : tools/perf/verify/results).

.PARAMETER AllowAppProcess
    Autorise la mesure d'un processus de la famille Riot. A n'utiliser qu'en
    phase B, apres le GO du Lead, et seulement pour des mesures serialisees.

.PARAMETER SkipCounterCrossCheck
    N'execute pas la methode compteurs (mesure directe seule). Le cross-check
    est alors marque SKIPPED. A reserver aux depannages.

.PARAMETER SelfTest
    Auto-test du harnais : compile un processus factice a charge CPU controlee
    (nom unique), le mesure, verifie le cross-check, les formats CSV/JSON
    invariants, puis verifie la robustesse a un arret du processus en cours de
    mesure. Aucune interaction UI. Ne mesure JAMAIS RiotSwitch.

.PARAMETER KeepSelfTestArtifacts
    Conserve l'executable factice dans tools/perf/verify/.selftest (sinon il est
    supprime en fin d'auto-test).

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\perf\verify\IndependentMeasure.ps1 -SelfTest

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\perf\verify\IndependentMeasure.ps1 `
        -ProcessName RiotSwitch -AllowAppProcess -DurationSec 60 -IntervalSec 1 -Tag W

.NOTES
    Sortie : CSV directe + CSV compteurs + JSON resume dans -OutDir.
    Codes de sortie : 0 OK, 1 erreur inattendue, 2 processus introuvable,
    3 garde de phase (processus Riot non autorise), 4 mesure interrompue
    (processus termine), 5 cross-check en echec, 6 compteurs indisponibles,
    7 echec de l'auto-test.
#>

[CmdletBinding()]
param(
    [string]$ProcessName = 'RiotSwitch',
    [int]$ProcessId = 0,
    [ValidateRange(5, 3600)][int]$DurationSec = 60,
    [ValidateRange(0.2, 10.0)][double]$IntervalSec = 1.0,
    [string]$Tag = '',
    [string]$OutDir = '',
    [switch]$AllowAppProcess,
    [switch]$SkipCounterCrossCheck,
    [switch]$SelfTest,
    [switch]$KeepSelfTestArtifacts
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Inv = [System.Globalization.CultureInfo]::InvariantCulture
$script:ToolName = 'IndependentMeasure'
$script:ToolVersion = '1.0.0'
$script:MB = 1048576.0
$script:TolerancePct = 5.0
$script:CpuNoiseFloorPct = 0.5
$script:WsNoiseFloorMB = 2.0
$script:MaxPairMs = 10000.0
$script:Quiet = $false

if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $OutDir = Join-Path $PSScriptRoot 'results'
}
$OutDir = [System.IO.Path]::GetFullPath($OutDir)

# ---------------------------------------------------------------------------
# Petites fonctions utilitaires (culture invariante obligatoire : machine fr-FR)
# ---------------------------------------------------------------------------

function Format-Inv {
    param([object]$Value, [string]$Fmt = 'F3')
    if ($null -eq $Value) { return '' }
    return [string]::Format($script:Inv, ('{0:' + $Fmt + '}'), [double]$Value)
}

function New-IsoUtc {
    param([DateTimeOffset]$Value)
    return $Value.ToString('yyyy-MM-ddTHH:mm:ss.fffffffzzz', $script:Inv)
}

function Get-UtcStamp {
    return [DateTimeOffset]::UtcNow.ToString('yyyyMMdd-HHmmss', $script:Inv)
}

function Get-SafeTag {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    return ($Value -replace '[^A-Za-z0-9._-]', '-')
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

function Get-ValueStats {
    param([object]$Values)
    $vals = New-Object System.Collections.Generic.List[double]
    foreach ($v in @($Values)) {
        if ($null -ne $v) { $vals.Add([double]$v) }
    }
    if ($vals.Count -eq 0) { return $null }

    $sorted = @($vals.ToArray() | Sort-Object)
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
            if ($text.IndexOf(',') -ge 0 -or $text.IndexOf('"') -ge 0) {
                $text = '"' + $text.Replace('"', '""') + '"'
            }
            $fields.Add($text)
        }
        [void]$sb.AppendLine(($fields -join ','))
    }
    [System.IO.File]::WriteAllText($Path, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
}

# ---------------------------------------------------------------------------
# P/Invoke minimal : GetGuiResources (objets GDI et USER d'un processus).
# Aucune dependance a ProcessNative.cs du sampler : import direct user32.
# ---------------------------------------------------------------------------

$nativeSource = @'
using System;
using System.Runtime.InteropServices;

public static class RSVerifyNative
{
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, int dwProcessId);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool CloseHandle(IntPtr hObject);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint GetGuiResources(IntPtr hProcess, uint uiFlags);

    public const uint PROCESS_QUERY_INFORMATION = 0x0400;
    public const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
    public const uint GR_GDIOBJECTS = 0;
    public const uint GR_USEROBJECTS = 1;
}
'@

try {
    Add-Type -TypeDefinition $nativeSource -ErrorAction Stop
}
catch {
    if ([string]$_.Exception.Message -notmatch 'already exists') { throw }
}

function Test-AppProcessName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    $clean = $Name
    if ($clean -match '(?i)\.exe$') { $clean = $clean.Substring(0, $clean.Length - 4) }
    return ($clean -match '(?i)^(riotswitch|riot client|riotclient|riotclientservices|riotclientux|riotclientuxrender|leagueclient|leagueclientux|valorant|vgtray|riotclientcrashhandler)$')
}

function Resolve-TargetProcess {
    param(
        [string]$Name,
        [int]$Id
    )
    if ($Id -gt 0) {
        $proc = $null
        try { $proc = Get-Process -Id $Id -ErrorAction Stop } catch { throw ("Aucun processus avec le PID {0}." -f $Id) }
        return ConvertTo-TargetInfo -Process $proc
    }

    $cleanName = $Name
    if ([string]::IsNullOrWhiteSpace($cleanName)) { throw 'Le nom de processus cible est vide.' }
    if ($cleanName -match '(?i)\.exe$') { $cleanName = $cleanName.Substring(0, $cleanName.Length - 4) }

    $matches = @(Get-Process -Name $cleanName -ErrorAction SilentlyContinue)
    if ($matches.Count -eq 0) {
        throw ("Processus '{0}' introuvable (aucune instance en cours)." -f $cleanName)
    }
    if ($matches.Count -gt 1) {
        $details = ($matches | ForEach-Object { "{0} (demarre {1})" -f $_.Id, $_.StartTime.ToString('yyyy-MM-dd HH:mm:ss', $script:Inv) }) -join ' ; '
        throw ("{0} processus nommes '{1}' : {2}. Precisez -ProcessId pour lever l'ambiguite." -f $matches.Count, $cleanName, $details)
    }
    return ConvertTo-TargetInfo -Process $matches[0]
}

function ConvertTo-TargetInfo {
    param($Process)
    $path = $null
    try { $path = $Process.Path } catch { $path = $null }
    $sessionId = $null
    try { $sessionId = $Process.SessionId } catch { $sessionId = $null }
    $startUtc = $null
    try { $startUtc = $Process.StartTime.ToUniversalTime() } catch { $startUtc = $null }
    return [pscustomobject]@{
        Id           = [int]$Process.Id
        ProcessName  = [string]$Process.ProcessName
        StartTimeUtc = $startUtc
        Path         = $path
        SessionId    = $sessionId
    }
}

# ---------------------------------------------------------------------------
# Decouverte DYNAMIQUE des compteurs localises (francais ou autre langue).
# On interroge Get-Counter -ListSet * et on identifie le jeu "Processus/Process"
# par la presence de ses compteurs CPU + Ensemble de travail, sans coder en dur
# le nom francais. Les gabarits de chemins renvoyes par l'OS sont reutilises.
# ---------------------------------------------------------------------------

function Get-CounterLeaf {
    param([string]$Path)
    $parts = $Path -split '\\'
    if ($parts.Count -eq 0) { return $Path }
    return ([string]$parts[$parts.Count - 1]).Trim()
}

function ConvertTo-CounterKey {
    # Normalise un nom de compteur : minuscules, sans accents, sans espaces superflus.
    # Permet de reconnaitre les compteurs localises (francais ou autre langue) sans
    # coder en dur les libelles exacts ni la casse.
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $normalized = $Text.Normalize([System.Text.NormalizationForm]::FormD)
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $normalized.ToCharArray()) {
        $category = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch)
        if ($category -ne [System.Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$sb.Append($ch)
        }
    }
    return $sb.ToString().ToLowerInvariant().Trim()
}

function Find-ProcessCounterSet {
    param($CounterSet)
    $cpuPath = $null
    $wsPath = $null
    $privatePath = $null
    $handlePath = $null
    foreach ($rawPath in @($CounterSet.Paths)) {
        if ([string]::IsNullOrWhiteSpace([string]$rawPath)) { continue }
        $path = [string]$rawPath
        $leaf = ConvertTo-CounterKey -Text (Get-CounterLeaf -Path $path)
        if ($null -eq $cpuPath -and $leaf -match '(% temps processeur|% processor time|% prozessorzeit|% tiempo de procesador|% tempo del processore)' -and
            $leaf -notmatch '(privilegie|privileged|utilisateur|user|inactivite|idle|interruption|dpc|systeme|system)') {
            $cpuPath = $path
        }
        elseif ($null -eq $wsPath -and ($leaf -eq 'plage de travail' -or $leaf -eq 'working set')) {
            $wsPath = $path
        }
        elseif ($null -eq $privatePath -and ($leaf -eq 'octets prives' -or $leaf -eq 'private bytes' -or $leaf -eq 'octets prives - privatifs')) {
            $privatePath = $path
        }
        elseif ($null -eq $handlePath -and ($leaf -eq 'nombre de handles' -or $leaf -eq 'handle count')) {
            $handlePath = $path
        }
    }
    if ($null -eq $cpuPath -or $null -eq $wsPath) { return $null }
    return [pscustomobject]@{
        SetName     = [string]$CounterSet.CounterSetName
        CpuPath     = $cpuPath
        WsPath      = $wsPath
        PrivatePath = $privatePath
        HandlePath  = $handlePath
        CpuLeaf     = (Get-CounterLeaf -Path $cpuPath)
        WsLeaf      = (Get-CounterLeaf -Path $wsPath)
        PrivateLeaf = $(if ($null -ne $privatePath) { Get-CounterLeaf -Path $privatePath } else { $null })
        HandleLeaf  = $(if ($null -ne $handlePath) { Get-CounterLeaf -Path $handlePath } else { $null })
    }
}

function Get-ProcessCounterMap {
    $sets = @(Get-Counter -ListSet * -ErrorAction SilentlyContinue)
    if ($sets.Count -eq 0) { return $null }

    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($set in $sets) {
        $found = Find-ProcessCounterSet -CounterSet $set
        if ($null -ne $found) { $candidates.Add($found) }
    }
    if ($candidates.Count -eq 0) { return $null }

    # Priorite : nom du jeu exactement "Process"/"Processus" (+ jeu le plus complet).
    $ordered = @($candidates | Sort-Object -Property `
        @{ Expression = { if ($_.SetName -match '(?i)^(process|processus|processo|proceso|prozess)$') { 0 } else { 1 } }; Ascending = $true }, `
        @{ Expression = { if ($null -ne $_.PrivatePath) { 0 } else { 1 } }; Ascending = $true }, `
        @{ Expression = { if ($null -ne $_.HandlePath) { 0 } else { 1 } }; Ascending = $true })
    return $ordered[0]
}

function Resolve-PerfInstanceName {
    param(
        [int]$TargetPid,
        [string]$BaseName,
        [int]$TimeoutSec = 10
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    $lastError = $null
    while ([DateTime]::UtcNow -lt $deadline) {
        $obj = $null
        try {
            $obj = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfProc_Process -Filter ("IDProcess = {0}" -f $TargetPid) -ErrorAction Stop | Select-Object -First 1
            if ($null -ne $obj) { return [pscustomobject]@{ Name = [string]$obj.Name; Method = 'CIM' } }
        }
        catch { $lastError = [string]$_.Exception.Message }
        if ($null -eq $obj) {
            try {
                $obj = Get-WmiObject -Class Win32_PerfFormattedData_PerfProc_Process -Filter ("IDProcess = {0}" -f $TargetPid) -ErrorAction Stop | Select-Object -First 1
                if ($null -ne $obj) { return [pscustomobject]@{ Name = [string]$obj.Name; Method = 'WMI' } }
            }
            catch { $lastError = [string]$_.Exception.Message }
        }
        Start-Sleep -Milliseconds 500
    }

    # Repli : nom de base si une seule instance du processus existe.
    $procs = @(Get-Process -Name $BaseName -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 1) {
        return [pscustomobject]@{ Name = $BaseName; Method = 'nom-unique'; Warning = ("Instance de performance deduite du nom ({0}) ; CIM/WMI indisponible : {1}" -f $BaseName, $lastError) }
    }
    return $null
}

function New-CounterCollector {
    param(
        [object[]]$CounterSpecs,
        [int]$SampleIntervalSec,
        [int]$MaxSamples
    )
    $paths = @($CounterSpecs | ForEach-Object { $_.Path })
    $leafNames = @($CounterSpecs | ForEach-Object { $_.Leaf })
    $metricNames = @($CounterSpecs | ForEach-Object { $_.Metric })

    $runner = [powershell]::Create()
    [void]$runner.AddScript({
        param($Paths, $LeafNames, $MetricNames, $IntervalSec, $MaxSamples)
        $inv = [System.Globalization.CultureInfo]::InvariantCulture
        try {
            $leafToMetric = @{}
            for ($i = 0; $i -lt $LeafNames.Count; $i++) { $leafToMetric[[string]$LeafNames[$i]] = [string]$MetricNames[$i] }
            $sets = @(Get-Counter -Counter $Paths -SampleInterval $IntervalSec -MaxSamples $MaxSamples -ErrorAction Stop)
            $bag = New-Object System.Collections.Generic.List[object]
            foreach ($set in $sets) {
                $ts = [DateTimeOffset]$set.Timestamp
                $map = @{ Timestamp = $ts.ToString('o', $inv) }
                foreach ($sample in @($set.CounterSamples)) {
                    $leaf = ([string]$sample.Path -split '\\')[-1]
                    if ($leafToMetric.ContainsKey($leaf)) {
                        $map[$leafToMetric[$leaf]] = [double]$sample.CookedValue
                    }
                }
                $bag.Add([pscustomobject]$map)
            }
            [pscustomobject]@{ Ok = $true; Error = $null; Samples = [object[]]$bag.ToArray() }
        }
        catch {
            [pscustomobject]@{ Ok = $false; Error = [string]$_.Exception.Message; Samples = @() }
        }
    })
    [void]$runner.AddArgument($paths)
    [void]$runner.AddArgument($leafNames)
    [void]$runner.AddArgument($metricNames)
    [void]$runner.AddArgument($SampleIntervalSec)
    [void]$runner.AddArgument($MaxSamples)
    $async = $runner.BeginInvoke()
    return [pscustomobject]@{ Runner = $runner; Async = $async }
}

function Open-GuiResourceHandle {
    param([int]$TargetPid)
    foreach ($access in @([uint32]0x0400, [uint32]0x1000)) {
        $h = [RSVerifyNative]::OpenProcess($access, $false, $TargetPid)
        if ($h -ne [IntPtr]::Zero) { return $h }
    }
    return [IntPtr]::Zero
}

# ---------------------------------------------------------------------------
# Stats + cross-check
# ---------------------------------------------------------------------------

function Compare-CrossCheckSeries {
    param(
        [object[]]$DirectSamples,
        [object[]]$CounterSamples
    )
    if ($DirectSamples.Count -lt 3 -or $CounterSamples.Count -lt 3) {
        return [pscustomobject]@{ Available = $false; Reason = 'series trop courtes pour un cross-check fiable' }
    }
    $directKept = @($DirectSamples | Select-Object -Skip 1)
    $counterKept = @($CounterSamples | Select-Object -Skip 1)
    $n = [Math]::Min($directKept.Count, $counterKept.Count)
    if ($n -lt 2) {
        return [pscustomobject]@{ Available = $false; Reason = 'pas assez d echantillons communs apres exclusion du premier' }
    }
    $directCpu = @($directKept | Select-Object -First $n | ForEach-Object { [double]$_.CpuPctOneCore })
    $counterCpu = @($counterKept | Select-Object -First $n | ForEach-Object { if ($null -ne $_.CpuPctOneCore) { [double]$_.CpuPctOneCore } else { $null } })
    $directWs = @($directKept | Select-Object -First $n | ForEach-Object { [double]$_.WorkingSetMB })
    $counterWs = @($counterKept | Select-Object -First $n | ForEach-Object { if ($null -ne $_.WorkingSetMB) { [double]$_.WorkingSetMB } else { $null } })

    $directCpuMean = Get-MeanOf -Values $directCpu
    $counterCpuMean = Get-MeanOf -Values $counterCpu
    $directWsMean = Get-MeanOf -Values $directWs
    $counterWsMean = Get-MeanOf -Values $counterWs

    $cpuAbs = $null; $cpuRel = $null; $cpuPass = $false; $cpuPassBy = 'n/a'
    if ($null -ne $directCpuMean -and $null -ne $counterCpuMean) {
        $cpuAbs = [Math]::Abs($directCpuMean - $counterCpuMean)
        $cpuRel = Get-RelativeDiffPct -Reference $counterCpuMean -Value $directCpuMean
        if ($cpuRel -le $script:TolerancePct) { $cpuPass = $true; $cpuPassBy = 'relative' }
        elseif ($cpuAbs -le $script:CpuNoiseFloorPct) { $cpuPass = $true; $cpuPassBy = 'plancher-de-bruit' }
    }
    $wsAbs = $null; $wsRel = $null; $wsPass = $false; $wsPassBy = 'n/a'
    if ($null -ne $directWsMean -and $null -ne $counterWsMean) {
        $wsAbs = [Math]::Abs($directWsMean - $counterWsMean)
        $wsRel = Get-RelativeDiffPct -Reference $counterWsMean -Value $directWsMean
        if ($wsRel -le $script:TolerancePct) { $wsPass = $true; $wsPassBy = 'relative' }
        elseif ($wsAbs -le $script:WsNoiseFloorMB) { $wsPass = $true; $wsPassBy = 'plancher-de-bruit' }
    }

    $directPrivateMean = Get-MeanOf -Values @($directKept | Select-Object -First $n | ForEach-Object { [double]$_.PrivateMB })
    $counterPrivateMean = Get-MeanOf -Values @($counterKept | Select-Object -First $n | ForEach-Object { if ($null -ne $_.PrivateMB) { [double]$_.PrivateMB } else { $null } })
    $directHandleMean = Get-MeanOf -Values @($directKept | Select-Object -First $n | ForEach-Object { [double]$_.HandleCount })
    $counterHandleMean = Get-MeanOf -Values @($counterKept | Select-Object -First $n | ForEach-Object { if ($null -ne $_.HandleCount) { [double]$_.HandleCount } else { $null } })

    $available = ($null -ne $directCpuMean -and $null -ne $counterCpuMean -and $null -ne $directWsMean -and $null -ne $counterWsMean)
    return [pscustomobject]@{
        Available            = $available
        Reason               = $(if ($available) { $null } else { 'valeurs CPU/WS manquantes dans une des deux series' })
        SamplesCompared      = $n
        Exclusion            = 'premier echantillon de chaque serie exclu (chauffe des compteurs de type taux)'
        CpuDirectMean        = $directCpuMean
        CpuCounterMean       = $counterCpuMean
        CpuAbsDiff           = $cpuAbs
        CpuRelDiffPct        = $cpuRel
        CpuTolerancePct      = $script:TolerancePct
        CpuNoiseFloorPct     = $script:CpuNoiseFloorPct
        CpuPass              = $cpuPass
        CpuPassBy            = $cpuPassBy
        WsDirectMeanMB       = $directWsMean
        WsCounterMeanMB      = $counterWsMean
        WsAbsDiffMB          = $wsAbs
        WsRelDiffPct         = $wsRel
        WsTolerancePct       = $script:TolerancePct
        WsNoiseFloorMB       = $script:WsNoiseFloorMB
        WsPass               = $wsPass
        WsPassBy             = $wsPassBy
        PrivateDirectMeanMB  = $directPrivateMean
        PrivateCounterMeanMB = $counterPrivateMean
        PrivateRelDiffPct    = Get-RelativeDiffPct -Reference $counterPrivateMean -Value $directPrivateMean
        HandlesDirectMean    = $directHandleMean
        HandlesCounterMean   = $counterHandleMean
        HandlesRelDiffPct    = Get-RelativeDiffPct -Reference $counterHandleMean -Value $directHandleMean
        Pass                 = ($cpuPass -and $wsPass)
    }
}

function Get-MeanOf {
    param([object]$Values)
    $sum = 0.0
    $count = 0
    foreach ($v in @($Values)) {
        if ($null -ne $v) { $sum += [double]$v; $count++ }
    }
    if ($count -eq 0) { return $null }
    return $sum / $count
}

function Get-RelativeDiffPct {
    param([object]$Reference, [object]$Value)
    if ($null -eq $Reference -or $null -eq $Value) { return $null }
    $ref = [double]$Reference
    $val = [double]$Value
    $denom = [Math]::Abs($ref)
    if ($denom -lt 1e-9) {
        $denom = [Math]::Max([Math]::Abs($val), 1e-9)
    }
    return ([Math]::Abs($val - $ref) / $denom) * 100.0
}

# ---------------------------------------------------------------------------
# Coeur de la mesure : renvoie un objet resultat (pas de sortie process ici).
# ---------------------------------------------------------------------------

function Invoke-Measurement {
    param(
        [string]$TargetName,
        [int]$TargetId,
        [int]$DurationSec,
        [double]$IntervalSec,
        [string]$Tag,
        [string]$OutDir,
        [bool]$AllowAppProcess,
        [bool]$SkipCounterCrossCheck,
        [switch]$Quiet
    )

    $script:Quiet = [bool]$Quiet
    $warnings = New-Object System.Collections.Generic.List[string]
    $startedAt = [DateTimeOffset]::UtcNow
    $safeTag = Get-SafeTag -Value $Tag
    $stamp = Get-UtcStamp
    $baseName = 'independent-measure-' + $stamp
    if (-not [string]::IsNullOrWhiteSpace($safeTag)) { $baseName += '-' + $safeTag }

    $target = $null
    try {
        $target = Resolve-TargetProcess -Name $TargetName -Id $TargetId
    }
    catch {
        $msg = [string]$_.Exception.Message
        Write-Status ("ERREUR : {0}" -f $msg)
        return [pscustomobject]@{ ExitCode = 2; Error = $msg; Result = $null; Files = $null; CrossCheck = $null; Aborted = $false; Warnings = $warnings.ToArray() }
    }

    if (-not $AllowAppProcess -and (Test-AppProcessName -Name $target.ProcessName)) {
        $msg = ("Garde de phase : le processus '{0}' (PID {1}) fait partie de la famille Riot. " -f $target.ProcessName, $target.Id) +
               "La mesure reelle n'est autorisee qu'en phase B, apres le GO du Lead : relancer avec -AllowAppProcess."
        Write-Status ("REFUS : {0}" -f $msg)
        return [pscustomobject]@{ ExitCode = 3; Error = $msg; Result = $null; Files = $null; CrossCheck = $null; Aborted = $false; Warnings = $warnings.ToArray() }
    }

    $logicalCores = [Environment]::ProcessorCount
    $expectedSamples = [int][Math]::Floor($DurationSec / $IntervalSec)
    if ($expectedSamples -lt 3) {
        $msg = ("Fenetre trop courte : {0} echantillons attendus (minimum 3)." -f $expectedSamples)
        Write-Status ("ERREUR : {0}" -f $msg)
        return [pscustomobject]@{ ExitCode = 2; Error = $msg; Result = $null; Files = $null; CrossCheck = $null; Aborted = $false; Warnings = $warnings.ToArray() }
    }

    Write-Status ""
    Write-Status "=== IndependentMeasure $($script:ToolVersion) - mesure independante ==="
    Write-Status ("Cible        : {0} (PID {1})" -f $target.ProcessName, $target.Id)
    if ($null -ne $target.StartTimeUtc) { Write-Status ("Demarrage    : {0}" -f (New-IsoUtc -Value ([DateTimeOffset]$target.StartTimeUtc))) }
    if (-not [string]::IsNullOrWhiteSpace([string]$target.Path)) { Write-Status ("Chemin       : {0}" -f $target.Path) }
    Write-Status ("Fenetre      : {0} s, periode {1} s, {2} echantillons directs attendus" -f $DurationSec, (Format-Inv -Value $IntervalSec -Fmt '0.###'), $expectedSamples)
    Write-Status ("Coeurs logiques : {0}" -f $logicalCores)

    # --- 1) Decouverte des compteurs localises ---------------------------------
    $counterMap = $null
    $instanceInfo = $null
    $counterAvailable = $false
    $counterMethodError = $null
    $counterSpecs = @()
    if (-not $SkipCounterCrossCheck) {
        Write-Status "Decouverte des compteurs de performance localises..."
        try {
            $counterMap = Get-ProcessCounterMap
        }
        catch {
            $counterMap = $null
            $counterMethodError = ('decouverte impossible : ' + [string]$_.Exception.Message)
        }
        if ($null -eq $counterMap) {
            if ($null -eq $counterMethodError) { $counterMethodError = 'aucun jeu de compteurs processus CPU+WS trouve' }
            $warnings.Add($counterMethodError)
            Write-Status ("ATTENTION : {0}" -f $counterMethodError)
        }
        else {
            Write-Status ("Jeu de compteurs detecte : '{0}' (CPU='{1}', WS='{2}', prive='{3}', handles='{4}')" -f `
                $counterMap.SetName, $counterMap.CpuLeaf, $counterMap.WsLeaf, $counterMap.PrivateLeaf, $counterMap.HandleLeaf)
            $instanceInfo = Resolve-PerfInstanceName -TargetPid $target.Id -BaseName $target.ProcessName -TimeoutSec 10
            if ($null -eq $instanceInfo) {
                $counterMethodError = 'nom d instance de performance introuvable (CIM/WMI) et nom de processus non unique'
                $warnings.Add($counterMethodError)
                Write-Status ("ATTENTION : {0}" -f $counterMethodError)
            }
            else {
                if ($instanceInfo.PSObject.Properties.Name -contains 'Warning' -and -not [string]::IsNullOrWhiteSpace([string]$instanceInfo.Warning)) {
                    $warnings.Add([string]$instanceInfo.Warning)
                    Write-Status ("ATTENTION : {0}" -f $instanceInfo.Warning)
                }
                $instance = [string]$instanceInfo.Name
                Write-Status ("Instance de performance : '{0}' (resolution {1})" -f $instance, $instanceInfo.Method)
                $counterSpecs += [pscustomobject]@{ Metric = 'CpuPctOneCore'; Leaf = $counterMap.CpuLeaf; Path = $counterMap.CpuPath.Replace('(*)', ('({0})' -f $instance)) }
                $counterSpecs += [pscustomobject]@{ Metric = 'WorkingSetMB'; Leaf = $counterMap.WsLeaf; Path = $counterMap.WsPath.Replace('(*)', ('({0})' -f $instance)) }
                if ($null -ne $counterMap.PrivatePath) {
                    $counterSpecs += [pscustomobject]@{ Metric = 'PrivateMB'; Leaf = $counterMap.PrivateLeaf; Path = $counterMap.PrivatePath.Replace('(*)', ('({0})' -f $instance)) }
                }
                if ($null -ne $counterMap.HandlePath) {
                    $counterSpecs += [pscustomobject]@{ Metric = 'HandleCount'; Leaf = $counterMap.HandleLeaf; Path = $counterMap.HandlePath.Replace('(*)', ('({0})' -f $instance)) }
                }
                $counterAvailable = $true
            }
        }
    }
    else {
        $warnings.Add('cross-check compteurs desactive par -SkipCounterCrossCheck')
    }

    # --- 2) Handle GDI/USER -----------------------------------------------------
    $guiHandle = [IntPtr]::Zero
    $guiAvailable = $false
    try {
        $guiHandle = Open-GuiResourceHandle -TargetPid $target.Id
        $guiAvailable = ($guiHandle -ne [IntPtr]::Zero)
    }
    catch {
        $guiAvailable = $false
    }
    if (-not $guiAvailable) {
        $warnings.Add('GetGuiResources indisponible (OpenProcess refuse) : colonnes GDI/USER laissees vides')
        Write-Status 'ATTENTION : compteurs GDI/USER indisponibles (acces processus refuse).'
    }

    # --- 3) Collecte simultanee -------------------------------------------------
    $maxCounterSamples = $expectedSamples + 2
    $collector = $null
    $ownCpuBefore = $null
    $ownCpuAfter = $null
    $measureElapsed = 0.0
    $samples = New-Object System.Collections.Generic.List[object]
    $jitters = New-Object System.Collections.Generic.List[double]
    $aborted = $false
    $abortReason = $null
    $pidReused = $false
    $processGoneDuringMeasure = $false
    $counterSamples = New-Object System.Collections.Generic.List[object]
    $counterSamplesReceived = 0
    $counterCollectionSeconds = $null
    $counterError = $null

    try {
        if ($counterAvailable) {
            try {
                $collector = New-CounterCollector -CounterSpecs $counterSpecs -SampleIntervalSec ([int][Math]::Round($IntervalSec)) -MaxSamples $maxCounterSamples
            }
            catch {
                $counterAvailable = $false
                $counterError = ('lancement du collecteur de compteurs impossible : ' + [string]$_.Exception.Message)
                $warnings.Add($counterError)
            }
        }

        $selfProcBefore = Get-Process -Id $PID -ErrorAction Stop
        $ownCpuBefore = $selfProcBefore.TotalProcessorTime
        $selfBeforeAt = [DateTimeOffset]::UtcNow

        $firstProc = $null
        try {
            $firstProc = Get-Process -Id $target.Id -ErrorAction Stop
        }
        catch {
            $processGoneDuringMeasure = $true
            $aborted = $true
            $abortReason = ('processus {0} (PID {1}) deja termine avant le debut de la fenetre de mesure' -f $target.ProcessName, $target.Id)
        }
        $targetStartUtc = $target.StartTimeUtc
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        if ($null -ne $firstProc) {
            $lastCpu = $firstProc.TotalProcessorTime
            $previousElapsed = 0.0
        }

        for ($k = 1; $k -le $expectedSamples -and -not $aborted; $k++) {
            $planned = $k * $IntervalSec
            while ($true) {
                $remain = $planned - $sw.Elapsed.TotalSeconds
                if ($remain -le 0.0015) { break }
                if ($remain -gt 0.020) {
                    $sleepMs = [int][Math]::Floor(($remain - 0.010) * 1000.0)
                    if ($sleepMs -gt 0) { Start-Sleep -Milliseconds $sleepMs }
                }
                else {
                    Start-Sleep -Milliseconds 1
                }
            }

            $actual = $sw.Elapsed.TotalSeconds
            $jitter = $actual - $planned
            $jitters.Add($jitter)
            $wall = $actual - $previousElapsed
            if ($wall -le 0) { $wall = $IntervalSec }

            $proc = $null
            try {
                $proc = Get-Process -Id $target.Id -ErrorAction Stop
            }
            catch {
                $processGoneDuringMeasure = $true
                $aborted = $true
                $abortReason = ('processus {0} (PID {1}) termine pendant la mesure (echantillon {2}/{3})' -f $target.ProcessName, $target.Id, $k, $expectedSamples)
                break
            }

            if ($null -ne $targetStartUtc) {
                $startNow = $null
                try { $startNow = $proc.StartTime.ToUniversalTime() } catch { $startNow = $null }
                if ($null -ne $startNow -and [Math]::Abs(($startNow - $targetStartUtc).TotalSeconds) -gt 0.01) {
                    $pidReused = $true
                    $aborted = $true
                    $abortReason = ('PID {0} reutilise par un autre processus pendant la mesure' -f $target.Id)
                    break
                }
            }

            $cpuTotal = $proc.TotalProcessorTime
            $deltaCpuSec = ($cpuTotal - $lastCpu).TotalSeconds
            $lastCpu = $cpuTotal
            $cpuOneCore = if ($wall -gt 0) { ($deltaCpuSec / $wall) * 100.0 } else { 0.0 }

            $gdi = $null
            $user = $null
            if ($guiAvailable) {
                try {
                    $gdi = [int][RSVerifyNative]::GetGuiResources($guiHandle, [RSVerifyNative]::GR_GDIOBJECTS)
                    $user = [int][RSVerifyNative]::GetGuiResources($guiHandle, [RSVerifyNative]::GR_USEROBJECTS)
                }
                catch {
                    $gdi = $null; $user = $null
                }
            }

            $nowUtc = [DateTimeOffset]::UtcNow
            $threadCount = $null
            try { $threadCount = $proc.Threads.Count } catch { $threadCount = $null }
            $sample = [pscustomobject]@{
                Index         = $k
                TimestampUtc  = (New-IsoUtc -Value $nowUtc)
                ElapsedSec    = [Math]::Round($actual, 6)
                IntervalSec   = [Math]::Round($wall, 6)
                CpuDeltaSec   = [Math]::Round($deltaCpuSec, 6)
                CpuPctOneCore = [Math]::Round($cpuOneCore, 6)
                CpuPctTotal   = [Math]::Round($cpuOneCore / [double]$logicalCores, 6)
                WorkingSetMB  = [Math]::Round($proc.WorkingSet64 / $script:MB, 6)
                PrivateMB     = [Math]::Round($proc.PrivateMemorySize64 / $script:MB, 6)
                HandleCount   = [int]$proc.HandleCount
                ThreadCount   = $threadCount
                GdiObjects    = $gdi
                UserObjects   = $user
            }
            $samples.Add($sample)
            $previousElapsed = $actual
        }

        $measureElapsed = $sw.Elapsed.TotalSeconds
        $sw.Stop()

        # --- 4) Recuperation des echantillons compteurs -------------------------
        if ($null -ne $collector) {
          if ($aborted) {
            try { $collector.Runner.Stop() } catch { }
            $counterError = 'collecte des compteurs interrompue : processus cible termine (echantillons compteurs non exploites)'
            $warnings.Add($counterError)
          }
          else {
            $waitMs = [int](($DurationSec + 30) * 1000)
            $counterStartWait = [DateTimeOffset]::UtcNow
            $signaled = $collector.Async.AsyncWaitHandle.WaitOne($waitMs)
            if (-not $signaled) {
                $counterError = 'delai d attente du collecteur de compteurs depasse'
                $warnings.Add($counterError)
                try { $collector.Runner.Stop() } catch { }
            }
            else {
                try {
                    $output = @($collector.Runner.EndInvoke($collector.Async))
                    $counterCollectionSeconds = ([DateTimeOffset]::UtcNow - $counterStartWait).TotalSeconds
                    if ($output.Count -gt 0 -and $null -ne $output[0]) {
                        $payload = $output[0]
                        if ([bool]$payload.Ok) {
                            foreach ($rawSample in @($payload.Samples)) {
                                if ($null -eq $rawSample) { continue }
                                $cpuVal = $null
                                $wsVal = $null
                                $privVal = $null
                                $handleVal = $null
                                if ($rawSample.PSObject.Properties.Name -contains 'CpuPctOneCore') { $cpuVal = $rawSample.CpuPctOneCore }
                                if ($rawSample.PSObject.Properties.Name -contains 'WorkingSetMB') { $wsVal = $rawSample.WorkingSetMB }
                                if ($rawSample.PSObject.Properties.Name -contains 'PrivateMB') { $privVal = $rawSample.PrivateMB }
                                if ($rawSample.PSObject.Properties.Name -contains 'HandleCount') { $handleVal = $rawSample.HandleCount }
                                $ts = [DateTimeOffset]::Parse([string]$rawSample.Timestamp, $script:Inv)
                                $counterSamples.Add([pscustomobject]@{
                                    TimestampUtc  = (New-IsoUtc -Value $ts)
                                    CpuPctOneCore = $(if ($null -ne $cpuVal) { [double]$cpuVal } else { $null })
                                    WorkingSetMB  = $(if ($null -ne $wsVal) { [Math]::Round([double]$wsVal / $script:MB, 6) } else { $null })
                                    PrivateMB     = $(if ($null -ne $privVal) { [Math]::Round([double]$privVal / $script:MB, 6) } else { $null })
                                    HandleCount   = $(if ($null -ne $handleVal) { [int]$handleVal } else { $null })
                                })
                            }
                            $counterSamplesReceived = $counterSamples.Count
                        }
                        else {
                            $counterError = [string]$payload.Error
                            $warnings.Add(('collecte des compteurs en echec : ' + $counterError))
                        }
                    }
                    else {
                        $counterError = 'collecteur de compteurs sans sortie exploitable'
                        $warnings.Add($counterError)
                    }
                }
                catch {
                    $counterError = [string]$_.Exception.Message
                    $warnings.Add(('lecture du collecteur de compteurs en echec : ' + $counterError))
                }
            }
          }
        }

        $selfProcAfter = Get-Process -Id $PID -ErrorAction Stop
        $ownCpuAfter = $selfProcAfter.TotalProcessorTime
        $ownCpuSec = ($ownCpuAfter - $ownCpuBefore).TotalSeconds
    }
    finally {
        if ($null -ne $collector) {
            try { $collector.Runner.Dispose() } catch { }
        }
        if ($guiHandle -ne [IntPtr]::Zero) {
            try { [void][RSVerifyNative]::CloseHandle($guiHandle) } catch { }
        }
    }

    if ($samples.Count -eq 0) {
        $aborted = $true
        if ($null -eq $abortReason) { $abortReason = 'aucun echantillon direct collecte' }
        $warnings.Add($abortReason)
    }

    # --- 5) Statistiques -------------------------------------------------------
    $directStats = [ordered]@{
        CpuPctOneCore = Get-ValueStats -Values @($samples | ForEach-Object { $_.CpuPctOneCore })
        CpuPctTotal   = Get-ValueStats -Values @($samples | ForEach-Object { $_.CpuPctTotal })
        WorkingSetMB  = Get-ValueStats -Values @($samples | ForEach-Object { $_.WorkingSetMB })
        PrivateMB     = Get-ValueStats -Values @($samples | ForEach-Object { $_.PrivateMB })
        HandleCount   = Get-ValueStats -Values @($samples | ForEach-Object { $_.HandleCount })
        ThreadCount   = Get-ValueStats -Values @($samples | ForEach-Object { $_.ThreadCount })
        GdiObjects    = Get-ValueStats -Values @($samples | ForEach-Object { $_.GdiObjects })
        UserObjects   = Get-ValueStats -Values @($samples | ForEach-Object { $_.UserObjects })
    }
    $counterStats = [ordered]@{
        CpuPctOneCore = Get-ValueStats -Values @($counterSamples | ForEach-Object { $_.CpuPctOneCore })
        WorkingSetMB  = Get-ValueStats -Values @($counterSamples | ForEach-Object { $_.WorkingSetMB })
        PrivateMB     = Get-ValueStats -Values @($counterSamples | ForEach-Object { $_.PrivateMB })
        HandleCount   = Get-ValueStats -Values @($counterSamples | ForEach-Object { $_.HandleCount })
    }

    $jitterStats = Get-ValueStats -Values @($jitters | ForEach-Object { [Math]::Abs($_) })
    $crossCheck = $null
    if ($SkipCounterCrossCheck) {
        $crossCheck = [pscustomobject]@{ Status = 'SKIPPED'; Pass = $null; Reason = 'cross-check desactive par -SkipCounterCrossCheck' }
    }
    elseif (-not $counterAvailable -or $counterSamples.Count -eq 0) {
        $crossCheck = [pscustomobject]@{ Status = 'UNAVAILABLE'; Pass = $null; Reason = $counterError; SamplesCompared = 0 }
    }
    else {
        $cross = Compare-CrossCheckSeries -DirectSamples $samples.ToArray() -CounterSamples $counterSamples.ToArray()
        if ($cross.Available) {
            $crossCheck = [pscustomobject]@{
                Status            = $(if ($cross.Pass) { 'PASS' } else { 'FAIL' })
                Pass              = [bool]$cross.Pass
                SamplesCompared   = $cross.SamplesCompared
                Exclusion         = $cross.Exclusion
                Cpu               = [pscustomobject]@{
                    DirectMeanPctOneCore  = $cross.CpuDirectMean
                    CounterMeanPctOneCore = $cross.CpuCounterMean
                    AbsDiffPct            = $cross.CpuAbsDiff
                    RelDiffPct            = $cross.CpuRelDiffPct
                    TolerancePct          = $cross.CpuTolerancePct
                    NoiseFloorPct         = $cross.CpuNoiseFloorPct
                    Pass                  = [bool]$cross.CpuPass
                    PassBy                = $cross.CpuPassBy
                }
                WorkingSet        = [pscustomobject]@{
                    DirectMeanMB  = $cross.WsDirectMeanMB
                    CounterMeanMB = $cross.WsCounterMeanMB
                    AbsDiffMB     = $cross.WsAbsDiffMB
                    RelDiffPct    = $cross.WsRelDiffPct
                    TolerancePct  = $cross.WsTolerancePct
                    NoiseFloorMB  = $cross.WsNoiseFloorMB
                    Pass          = [bool]$cross.WsPass
                    PassBy        = $cross.WsPassBy
                }
                PrivateBytesInfo  = [pscustomobject]@{
                    DirectMeanMB  = $cross.PrivateDirectMeanMB
                    CounterMeanMB = $cross.PrivateCounterMeanMB
                    RelDiffPct    = $cross.PrivateRelDiffPct
                    Informational = $true
                }
                HandlesInfo       = [pscustomobject]@{
                    DirectMean    = $cross.HandlesDirectMean
                    CounterMean   = $cross.HandlesCounterMean
                    RelDiffPct    = $cross.HandlesRelDiffPct
                    Informational = $true
                }
            }
        }
        else {
            $crossCheck = [pscustomobject]@{ Status = 'UNAVAILABLE'; Pass = $null; Reason = $cross.Reason; SamplesCompared = 0 }
        }
    }

    # --- 6) Determination du code de sortie ------------------------------------
    $exitCode = 0
    if ($aborted) { $exitCode = 4 }
    elseif (-not $SkipCounterCrossCheck) {
        if ($null -eq $crossCheck.Pass) { $exitCode = 6 }
        elseif (-not [bool]$crossCheck.Pass) { $exitCode = 5 }
    }
    if ($exitCode -ne 0) {
        if ($null -ne $abortReason) { $warnings.Add($abortReason) }
        elseif (Test-Prop -Object $crossCheck -Name 'Reason') { $warnings.Add([string]$crossCheck.Reason) }
    }

    # --- 7) Ecriture des fichiers ----------------------------------------------
    if (-not (Test-Path -LiteralPath $OutDir)) {
        [void](New-Item -ItemType Directory -Force -Path $OutDir)
    }
    $directCsvPath = Join-Path $OutDir ($baseName + '-direct.csv')
    $counterCsvPath = Join-Path $OutDir ($baseName + '-counters.csv')
    $jsonPath = Join-Path $OutDir ($baseName + '.json')

    $directHeaders = @('sample_index', 'timestamp_utc', 'elapsed_sec', 'interval_sec', 'cpu_delta_sec', 'cpu_pct_one_core', 'cpu_pct_total', 'working_set_mb', 'private_mb', 'handle_count', 'thread_count', 'gdi_objects', 'user_objects')
    $directRows = New-Object System.Collections.Generic.List[object]
    foreach ($s in $samples) {
        $directRows.Add(@(
            [string]$s.Index,
            [string]$s.TimestampUtc,
            (Format-Inv -Value $s.ElapsedSec -Fmt 'F6'),
            (Format-Inv -Value $s.IntervalSec -Fmt 'F6'),
            (Format-Inv -Value $s.CpuDeltaSec -Fmt 'F6'),
            (Format-Inv -Value $s.CpuPctOneCore -Fmt 'F6'),
            (Format-Inv -Value $s.CpuPctTotal -Fmt 'F6'),
            (Format-Inv -Value $s.WorkingSetMB -Fmt 'F6'),
            (Format-Inv -Value $s.PrivateMB -Fmt 'F6'),
            [string]$s.HandleCount,
            $(if ($null -ne $s.ThreadCount) { [string]$s.ThreadCount } else { '' }),
            $(if ($null -ne $s.GdiObjects) { [string]$s.GdiObjects } else { '' }),
            $(if ($null -ne $s.UserObjects) { [string]$s.UserObjects } else { '' })
        ))
    }
    Write-CsvRows -Path $directCsvPath -Headers $directHeaders -Rows $directRows.ToArray()

    $counterHeaders = @('sample_index', 'timestamp_utc', 'cpu_pct_one_core', 'working_set_mb', 'private_mb', 'handle_count')
    $counterRows = New-Object System.Collections.Generic.List[object]
    $ci = 0
    foreach ($c in $counterSamples) {
        $ci++
        $counterRows.Add(@(
            [string]$ci,
            [string]$c.TimestampUtc,
            (Format-Inv -Value $c.CpuPctOneCore -Fmt 'F6'),
            (Format-Inv -Value $c.WorkingSetMB -Fmt 'F6'),
            (Format-Inv -Value $c.PrivateMB -Fmt 'F6'),
            $(if ($null -ne $c.HandleCount) { [string]$c.HandleCount } else { '' })
        ))
    }
    Write-CsvRows -Path $counterCsvPath -Headers $counterHeaders -Rows $counterRows.ToArray()

    $ownCpuPct = $null
    if ($null -ne $ownCpuBefore -and $null -ne $ownCpuAfter -and $measureElapsed -gt 0) {
        $ownCpuPct = ($ownCpuSec / $measureElapsed) * 100.0
    }

    $result = [ordered]@{
        tool                  = $script:ToolName
        version               = $script:ToolVersion
        generatedAtUtc        = (New-IsoUtc -Value $startedAt)
        finishedAtUtc         = (New-IsoUtc -Value ([DateTimeOffset]::UtcNow))
        computerName          = [string]$env:COMPUTERNAME
        userName              = [string]$env:USERNAME
        powershellVersion     = [string]$PSVersionTable.PSVersion
        culture               = [string][System.Globalization.CultureInfo]::CurrentCulture.Name
        osVersion             = [string][System.Environment]::OSVersion.VersionString
        logicalCores          = $logicalCores
        parameters            = [ordered]@{
            processName  = $TargetName
            processId    = $TargetId
            durationSec  = $DurationSec
            intervalSec  = $IntervalSec
            tag          = $Tag
            allowAppProcess = $AllowAppProcess
            skipCounterCrossCheck = $SkipCounterCrossCheck
        }
        target                = [ordered]@{
            pid           = $target.Id
            processName   = $target.ProcessName
            path          = $target.Path
            startTimeUtc  = $(if ($null -ne $target.StartTimeUtc) { New-IsoUtc -Value ([DateTimeOffset]$target.StartTimeUtc) } else { $null })
            sessionId     = $target.SessionId
        }
        methods               = [ordered]@{
            direct = 'Get-Process a 1 Hz (TotalProcessorTime, WorkingSet64, PrivateMemorySize64, HandleCount, Threads) + GetGuiResources'
            counter = 'Get-Counter localise (decouverte dynamique) sur compteurs Processus/Process, collecte simultanee en runspace'
        }
        counterMethod         = [ordered]@{
            requested             = (-not $SkipCounterCrossCheck)
            available             = $counterAvailable
            counterSetName        = $(if ($null -ne $counterMap) { $counterMap.SetName } else { $null })
            cpuCounterName        = $(if ($null -ne $counterMap) { $counterMap.CpuLeaf } else { $null })
            wsCounterName         = $(if ($null -ne $counterMap) { $counterMap.WsLeaf } else { $null })
            privateCounterName    = $(if ($null -ne $counterMap) { $counterMap.PrivateLeaf } else { $null })
            handleCounterName     = $(if ($null -ne $counterMap) { $counterMap.HandleLeaf } else { $null })
            instanceName          = $(if ($null -ne $instanceInfo) { $instanceInfo.Name } else { $null })
            instanceResolution    = $(if ($null -ne $instanceInfo) { $instanceInfo.Method } else { $null })
            counterPaths          = @($counterSpecs | ForEach-Object { $_.Path })
            samplesReceived       = $counterSamplesReceived
            collectionSeconds     = $counterCollectionSeconds
            error                 = $counterError
        }
        directMethod          = [ordered]@{
            samplesCount      = $samples.Count
            expectedSamples   = $expectedSamples
            durationSec       = [Math]::Round($measureElapsed, 6)
            meanIntervalMs    = $(if ($jitterStats -and $samples.Count -gt 0) { [Math]::Round($measureElapsed / $samples.Count * 1000.0, 3) } else { $null })
            meanAbsJitterMs   = $(if ($jitterStats) { [Math]::Round($jitterStats.Mean, 3) } else { $null })
            maxAbsJitterMs    = $(if ($jitterStats) { [Math]::Round($jitterStats.Max, 3) } else { $null })
            gdiUserAvailable  = $guiAvailable
        }
        stats                 = [ordered]@{
            direct  = $directStats
            counter = $counterStats
        }
        crossCheck            = $crossCheck
        harnessOverhead       = [ordered]@{
            ownCpuSeconds       = $(if ($null -ne $ownCpuBefore -and $null -ne $ownCpuAfter) { [Math]::Round($ownCpuSec, 6) } else { $null })
            ownCpuPctOneCore    = $(if ($null -ne $ownCpuPct) { [Math]::Round($ownCpuPct, 6) } else { $null })
            note                = 'CPU du processus harnais pendant la fenetre (runspace compteurs inclus)'
        }
        aborted               = $aborted
        abortReason           = $abortReason
        pidReused             = $pidReused
        processExited         = $processGoneDuringMeasure
        exitCode              = $exitCode
        warnings              = $warnings.ToArray()
        outputFiles           = [ordered]@{
            directCsv  = $directCsvPath
            counterCsv = $counterCsvPath
            json       = $jsonPath
        }
    }

    $oldCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
    try {
        [System.Threading.Thread]::CurrentThread.CurrentCulture = $script:Inv
        $jsonText = ($result | ConvertTo-Json -Depth 10)
    }
    finally {
        [System.Threading.Thread]::CurrentThread.CurrentCulture = $oldCulture
    }
    [System.IO.File]::WriteAllText($jsonPath, $jsonText + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))

    # --- 8) Resume console ------------------------------------------------------
    Write-Status ""
    if ($null -ne $jitterStats) {
        Write-Status ("Echantillons directs : {0}/{1} (duree reelle {2} s, gigue moyenne |{3}| ms, max |{4}| ms)" -f `
            $samples.Count, $expectedSamples, (Format-Inv -Value $measureElapsed -Fmt 'F3'), `
            (Format-Inv -Value $jitterStats.Mean -Fmt 'F3'), (Format-Inv -Value $jitterStats.Max -Fmt 'F3'))
    }
    else {
        Write-Status ("Echantillons directs : 0/{0} (aucun echantillon exploitable)" -f $expectedSamples)
    }
    if ($null -ne $directStats.CpuPctOneCore) {
        Write-Status ("CPU (% d'un coeur)  : min {0} / moy {1} / med {2} / p95 {3} / max {4}" -f `
            (Format-Inv -Value $directStats.CpuPctOneCore.Min -Fmt 'F3'), (Format-Inv -Value $directStats.CpuPctOneCore.Mean -Fmt 'F3'), `
            (Format-Inv -Value $directStats.CpuPctOneCore.Median -Fmt 'F3'), (Format-Inv -Value $directStats.CpuPctOneCore.P95 -Fmt 'F3'), `
            (Format-Inv -Value $directStats.CpuPctOneCore.Max -Fmt 'F3'))
        Write-Status ("WS (Mo)              : min {0} / moy {1} / med {2} / max {3}" -f `
            (Format-Inv -Value $directStats.WorkingSetMB.Min -Fmt 'F3'), (Format-Inv -Value $directStats.WorkingSetMB.Mean -Fmt 'F3'), `
            (Format-Inv -Value $directStats.WorkingSetMB.Median -Fmt 'F3'), (Format-Inv -Value $directStats.WorkingSetMB.Max -Fmt 'F3'))
        Write-Status ("Prive (Mo)           : moy {0} | Handles : moy {1} | GDI : moy {2}" -f `
            (Format-Inv -Value $directStats.PrivateMB.Mean -Fmt 'F3'), (Format-Inv -Value $directStats.HandleCount.Mean -Fmt 'F1'), `
            $(if ($null -ne $directStats.GdiObjects) { Format-Inv -Value $directStats.GdiObjects.Mean -Fmt 'F1' } else { 'n/a' }))
    }
    if ($null -ne $counterStats.CpuPctOneCore) {
        Write-Status ("Compteurs Get-Counter: CPU moy {0} | WS moy {1} Mo ({2} echantillons)" -f `
            (Format-Inv -Value $counterStats.CpuPctOneCore.Mean -Fmt 'F3'), (Format-Inv -Value $counterStats.WorkingSetMB.Mean -Fmt 'F3'), $counterSamples.Count)
    }

    if ($null -ne $crossCheck) {
        Write-Status ("Cross-check          : {0}" -f $crossCheck.Status)
        if (Test-Prop -Object $crossCheck -Name 'Cpu') {
            Write-Status ("  CPU : direct {0} vs compteur {1} (% coeur) -> ecart {2} % ({3})" -f `
                (Format-Inv -Value $crossCheck.Cpu.DirectMeanPctOneCore -Fmt 'F3'), (Format-Inv -Value $crossCheck.Cpu.CounterMeanPctOneCore -Fmt 'F3'), `
                (Format-Inv -Value $crossCheck.Cpu.RelDiffPct -Fmt 'F2'), $crossCheck.Cpu.PassBy)
            Write-Status ("  WS  : direct {0} vs compteur {1} Mo -> ecart {2} % ({3})" -f `
                (Format-Inv -Value $crossCheck.WorkingSet.DirectMeanMB -Fmt 'F3'), (Format-Inv -Value $crossCheck.WorkingSet.CounterMeanMB -Fmt 'F3'), `
                (Format-Inv -Value $crossCheck.WorkingSet.RelDiffPct -Fmt 'F2'), $crossCheck.WorkingSet.PassBy)
        }
        elseif (Test-Prop -Object $crossCheck -Name 'Reason') {
            Write-Status ("  raison : {0}" -f $crossCheck.Reason)
        }
    }
    if ($null -ne $ownCpuPct) {
        Write-Status ("Surcout harnais      : {0} % d'un coeur ({1} s CPU)" -f (Format-Inv -Value $ownCpuPct -Fmt 'F3'), (Format-Inv -Value $ownCpuSec -Fmt 'F3'))
    }
    foreach ($w in $warnings) { Write-Status ("ATTENTION : {0}" -f $w) }
    Write-Status ""
    Write-Status ("Fichiers : {0}" -f $directCsvPath)
    Write-Status ("           {0}" -f $counterCsvPath)
    Write-Status ("           {0}" -f $jsonPath)
    Write-Status ("Code de sortie : {0}" -f $exitCode)

    return [pscustomobject]@{
        ExitCode  = $exitCode
        Error     = $(if ($exitCode -eq 0 -or $exitCode -eq 4) { $null } else { $(if (Test-Prop -Object $crossCheck -Name 'Reason') { [string]$crossCheck.Reason } else { $null }) })
        Result    = [pscustomobject]$result
        Files     = [pscustomobject]@{ DirectCsv = $directCsvPath; CounterCsv = $counterCsvPath; Json = $jsonPath }
        CrossCheck = $crossCheck
        Aborted   = $aborted
        Warnings  = $warnings.ToArray()
    }
}

# ---------------------------------------------------------------------------
# Auto-test du harnais : processus factice a charge CPU controlee.
# Aucune fenetre UI : simple application console .NET compilee dans
# tools/perf/verify/.selftest, lancee avec une fenetre masquee, puis arretee
# uniquement par ce script (jamais un processus Riot/RiotSwitch).
# ---------------------------------------------------------------------------

function New-SelfTestDummy {
    param([int]$LifetimeSec, [int]$MemoryMb)
    $selftestDir = Join-Path $PSScriptRoot '.selftest'
    if (-not (Test-Path -LiteralPath $selftestDir)) {
        [void](New-Item -ItemType Directory -Force -Path $selftestDir)
    }
    $suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $exeName = 'RSV' + $suffix + '.exe'
    $exePath = Join-Path $selftestDir $exeName
    $dummySource = @'
using System;
using System.Diagnostics;
using System.Globalization;
using System.Threading;

public static class Program
{
    public static void Main(string[] args)
    {
        int seconds = 30;
        int memoryMb = 96;
        if (args.Length > 0) seconds = int.Parse(args[0], CultureInfo.InvariantCulture);
        if (args.Length > 1) memoryMb = int.Parse(args[1], CultureInfo.InvariantCulture);

        // Alloue et touche la memoire pour rendre le Working Set mesurable.
        byte[] buffer = new byte[memoryMb * 1024 * 1024];
        for (long i = 0; i < buffer.LongLength; i += 4096) buffer[i] = (byte)(i & 0xFF);

        Stopwatch total = Stopwatch.StartNew();
        while (total.Elapsed.TotalSeconds < seconds)
        {
            // ~70 % d'un coeur : 70 ms de calcul puis 30 ms de sommeil.
            Stopwatch slice = Stopwatch.StartNew();
            while (slice.Elapsed.TotalMilliseconds < 70.0)
            {
                Thread.SpinWait(200);
            }
            Thread.Sleep(30);
        }
    }
}
'@
    Add-Type -TypeDefinition $dummySource -OutputAssembly $exePath -OutputType ConsoleApplication -ErrorAction Stop
    $proc = Start-Process -FilePath $exePath -ArgumentList @([string]$LifetimeSec, [string]$MemoryMb) -WindowStyle Hidden -PassThru -ErrorAction Stop
    return [pscustomobject]@{
        Process   = $proc
        ExePath   = $exePath
        ProcessId = $proc.Id
        StartedAt = [DateTimeOffset]::UtcNow
    }
}

function Stop-SelfTestDummy {
    param($Dummy, [int]$WaitMs = 3000)
    if ($null -eq $Dummy -or $null -eq $Dummy.Process) { return $true }
    $expected = $Dummy.Process
    $alive = $null
    try { $alive = Get-Process -Id $expected.Id -ErrorAction Stop } catch { $alive = $null }
    if ($null -eq $alive) { return $true }

    # Securite : n'arreter que le processus factice que NOUS avons lance.
    if ($alive.ProcessName -ne $expected.ProcessName) { return $false }
    try {
        if ([Math]::Abs(($alive.StartTime - $expected.StartTime).TotalSeconds) -gt 0.01) { return $false }
    }
    catch {
        return $false
    }
    try {
        $expected.WaitForExit($WaitMs)
        if (-not $expected.HasExited) {
            Stop-Process -Id $expected.Id -Force -ErrorAction Stop
            [void]$expected.WaitForExit(3000)
        }
        return $true
    }
    catch {
        return $false
    }
}

function Read-DirectCsvForValidation {
    param([string]$Path)
    $lines = [System.IO.File]::ReadAllLines($Path, (New-Object System.Text.UTF8Encoding($false)))
    if ($lines.Count -lt 2) { throw 'CSV direct vide' }
    $header = $lines[0]
    $expectedFieldCount = @($header -split ',').Count
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($line in @($lines | Select-Object -Skip 1)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $fields = @($line -split ',')
        if ($fields.Count -ne $expectedFieldCount) { throw ("CSV direct : nombre de champs {0} au lieu de {1} : {2}" -f $fields.Count, $expectedFieldCount, $line) }
        $rows.Add([pscustomobject]@{ Fields = $fields })
    }
    return [pscustomobject]@{ Header = $header; FieldCount = $expectedFieldCount; Rows = $rows }
}

function Invoke-SelfTest {
    $script:Quiet = $false
    $failures = New-Object System.Collections.Generic.List[string]
    $details = New-Object System.Collections.Generic.List[string]
    $selftestTag = 'selftest'
    $selfTestDuration = 20

    Write-Host ""
    Write-Host "=== AUTO-TEST IndependentMeasure $($script:ToolVersion) ==="
    Write-Host "Processus factice uniquement ; aucune interaction UI ; RiotSwitch n'est pas mesure."

    # --- Test 1 : processus factice a 70 % de charge ---------------------------
    $dummy1 = $null
    $result1 = $null
    try {
        Write-Host ""
        Write-Host "[Test 1] Compilation et lancement du processus factice (charge ~70 % d'un coeur, 96 Mo)..."
        $dummy1 = New-SelfTestDummy -LifetimeSec ($selfTestDuration + 20) -MemoryMb 96
        Write-Host ("[Test 1] Factice PID {0} ({1})" -f $dummy1.ProcessId, (Split-Path -Leaf $dummy1.ExePath))
        Start-Sleep -Milliseconds 1200
        $result1 = Invoke-Measurement -TargetName '' -TargetId $dummy1.ProcessId -DurationSec $selfTestDuration -IntervalSec 1.0 -Tag $selftestTag -OutDir $OutDir -AllowAppProcess $false -SkipCounterCrossCheck $false
        Write-Host ("[Test 1] Code de sortie mesure : {0}" -f $result1.ExitCode)

        if ($result1.ExitCode -ne 0) { $failures.Add(("Test 1 : code de sortie {0} au lieu de 0 ({1})" -f $result1.ExitCode, ([string]($result1.Result.warnings -join ' | ')))) }
        if ($null -eq $result1.Result) {
            $failures.Add('Test 1 : aucun resultat JSON produit')
        }
        else {
            if (-not $result1.Result.counterMethod.available) { $failures.Add('Test 1 : methode compteurs indisponible') }
            if (-not $result1.Result.directMethod.gdiUserAvailable) { $failures.Add('Test 1 : GetGuiResources indisponible (GDI/USER non verifies)') }
            $cc = $result1.Result.crossCheck
            if ($null -eq $cc -or $null -eq $cc.Pass) {
                $ccReason = ''
                if (Test-Prop -Object $cc -Name 'Reason') { $ccReason = [string]$cc.Reason }
                $failures.Add(("Test 1 : cross-check non execute ({0})" -f $ccReason))
            }
            elseif (-not [bool]$cc.Pass) {
                $failures.Add(("Test 1 : cross-check en echec (CPU ecart {0} %, WS ecart {1} %)" -f $cc.Cpu.RelDiffPct, $cc.WorkingSet.RelDiffPct))
            }
            if (-not (Test-Path -LiteralPath $result1.Files.DirectCsv)) { $failures.Add('Test 1 : CSV direct absent') }
            elseif (-not (Test-Path -LiteralPath $result1.Files.CounterCsv)) { $failures.Add('Test 1 : CSV compteurs absent') }
            elseif (-not (Test-Path -LiteralPath $result1.Files.Json)) { $failures.Add('Test 1 : JSON absent') }
            else {
                # CSV : decimales invariantes (point), champs complets.
                try {
                    $csv = Read-DirectCsvForValidation -Path $result1.Files.DirectCsv
                    foreach ($row in $csv.Rows) {
                        foreach ($numeric in @($row.Fields[2], $row.Fields[5], $row.Fields[6], $row.Fields[7], $row.Fields[8])) {
                            if ($numeric -notmatch '^-?\d+\.\d+$') { throw ("CSV direct : decimal non invariant '{0}'" -f $numeric) }
                        }
                    }
                    if ($csv.Rows.Count -lt ($selfTestDuration - 2)) { throw ("CSV direct : seulement {0} lignes" -f $csv.Rows.Count) }
                }
                catch { $failures.Add([string]$_.Exception.Message) }

                # JSON : parse + valeurs numeriques au point.
                try {
                    $jsonRaw = [System.IO.File]::ReadAllText($result1.Files.Json, (New-Object System.Text.UTF8Encoding($false)))
                    $json = $jsonRaw | ConvertFrom-Json
                    if ($null -ne $cc -and $null -ne $cc.Pass -and [string]$json.crossCheck.Status -ne 'PASS') { throw ("JSON : statut cross-check inattendu '{0}'" -f $json.crossCheck.Status) }
                    if ($jsonRaw -notmatch '"CpuPctOneCore"\s*:\s*\{\s*"Count"') { throw 'JSON : structure stats CPU inattendue' }
                    if ($jsonRaw -match '"RelDiffPct"\s*:\s*-?\d+,\d+') { throw 'JSON : decimales a virgule detectees' }
                    if ($null -eq $json.stats.direct.CpuPctOneCore.Mean) { throw 'JSON : stats CPU absentes' }
                    if ($null -eq $json.harnessOverhead.ownCpuPctOneCore) { throw 'JSON : surcout harnais absent' }
                }
                catch { $failures.Add([string]$_.Exception.Message) }

                $overhead = $result1.Result.harnessOverhead.ownCpuPctOneCore
                if (Test-Prop -Object $cc -Name 'Cpu') {
                    $details.Add(("CPU factice : direct moy {0} % / compteur moy {1} % -> ecart {2} % ({3})" -f `
                        (Format-Inv -Value $cc.Cpu.DirectMeanPctOneCore -Fmt 'F3'), (Format-Inv -Value $cc.Cpu.CounterMeanPctOneCore -Fmt 'F3'), `
                        (Format-Inv -Value $cc.Cpu.RelDiffPct -Fmt 'F2'), $cc.Cpu.PassBy))
                    $details.Add(("WS factice : direct moy {0} Mo / compteur moy {1} Mo -> ecart {2} % ({3})" -f `
                        (Format-Inv -Value $cc.WorkingSet.DirectMeanMB -Fmt 'F3'), (Format-Inv -Value $cc.WorkingSet.CounterMeanMB -Fmt 'F3'), `
                        (Format-Inv -Value $cc.WorkingSet.RelDiffPct -Fmt 'F2'), $cc.WorkingSet.PassBy))
                }
                $details.Add(("Surcout harnais mesure : {0} % d'un coeur ({1} s CPU sur {2} s)" -f `
                    (Format-Inv -Value $overhead -Fmt 'F3'), (Format-Inv -Value $result1.Result.harnessOverhead.ownCpuSeconds -Fmt 'F3'), `
                    (Format-Inv -Value $result1.Result.directMethod.durationSec -Fmt 'F3')))
                $details.Add(("Gigue echantillonnage : moyenne |{0}| ms, max |{1}| ms ; {2} echantillons directs" -f `
                    (Format-Inv -Value $result1.Result.directMethod.meanAbsJitterMs -Fmt 'F3'), (Format-Inv -Value $result1.Result.directMethod.maxAbsJitterMs -Fmt 'F3'), `
                    $result1.Result.directMethod.samplesCount))
                $details.Add(("Compteurs decouverts : jeu '{0}', CPU='{1}', WS='{2}' (instance '{3}')" -f `
                    $result1.Result.counterMethod.counterSetName, $result1.Result.counterMethod.cpuCounterName, `
                    $result1.Result.counterMethod.wsCounterName, $result1.Result.counterMethod.instanceName))
            }
        }
    }
    catch {
        $failures.Add(('Test 1 : exception inattendue : ' + [string]$_.Exception.Message))
    }
    finally {
        if ($null -ne $dummy1) {
            $stopped = Stop-SelfTestDummy -Dummy $dummy1
            if (-not $stopped) { $failures.Add('Test 1 : impossible d arreter proprement le processus factice') }
        }
    }

    # --- Test 2 : robustesse a la disparition du processus ---------------------
    $dummy2 = $null
    $result2 = $null
    try {
        Write-Host ""
        # Compteurs desactives : le chemin d'abandon doit etre deterministe (~5 s de vie).
        $test2Lifetime = 5
        $test2Duration = 20
        Write-Host ("[Test 2] Robustesse : processus factice de duree {0} s mesure sur {1} s (arret en cours de fenetre attendu)..." -f $test2Lifetime, $test2Duration)
        $dummy2 = New-SelfTestDummy -LifetimeSec $test2Lifetime -MemoryMb 32
        Start-Sleep -Milliseconds 400
        $result2 = Invoke-Measurement -TargetName '' -TargetId $dummy2.ProcessId -DurationSec $test2Duration -IntervalSec 1.0 -Tag 'selftest-exit' -OutDir $OutDir -AllowAppProcess $false -SkipCounterCrossCheck $true
        Write-Host ("[Test 2] Code de sortie mesure : {0} (attendu 4)" -f $result2.ExitCode)
        if ($null -eq $result2.Result) {
            $failures.Add('Test 2 : aucun resultat JSON produit')
        }
        else {
            if ($result2.ExitCode -ne 4) { $failures.Add(("Test 2 : code {0} au lieu de 4 (arret detecte)" -f $result2.ExitCode)) }
            if (-not [bool]$result2.Result.processExited) { $failures.Add('Test 2 : la disparition du processus n a pas ete tracee') }
            if ($result2.Result.aborted -ne $true) { $failures.Add('Test 2 : resultat non marque aborted') }
            if (-not (Test-Path -LiteralPath $result2.Files.Json)) { $failures.Add('Test 2 : JSON absent malgre l interruption') }
            else {
                try {
                    $json2 = [System.IO.File]::ReadAllText($result2.Files.Json, (New-Object System.Text.UTF8Encoding($false))) | ConvertFrom-Json
                    if ($json2.aborted -ne $true) { throw 'JSON : aborted != true' }
                }
                catch { $failures.Add([string]$_.Exception.Message) }
            }
            $samples2 = [int]$result2.Result.directMethod.samplesCount
            if ($samples2 -ge $test2Duration) { $failures.Add('Test 2 : la boucle ne s est pas arretee a la disparition du processus') }
            if ($samples2 -lt 1) { $failures.Add('Test 2 : aucun echantillon collecte avant la disparition') }
            $details.Add(("Test 2 : {0} echantillons directs avant disparition, code 4, JSON ecrit" -f $samples2))
        }
    }
    catch {
        $failures.Add(('Test 2 : exception inattendue : ' + [string]$_.Exception.Message))
    }
    finally {
        if ($null -ne $dummy2) {
            [void](Stop-SelfTestDummy -Dummy $dummy2 -WaitMs 1000)
        }
    }

    # --- Nettoyage des executables factices ------------------------------------
    try {
        $selftestDir = Join-Path $PSScriptRoot '.selftest'
        if (Test-Path -LiteralPath $selftestDir) {
            $running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like 'RSV*' })
            if ($KeepSelfTestArtifacts -or $running.Count -gt 0) {
                Write-Host ("[Nettoyage] Artefacts conserves dans {0}" -f $selftestDir)
            }
            else {
                Remove-Item -LiteralPath $selftestDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
    catch { }

    # --- Verdict ---------------------------------------------------------------
    Write-Host ""
    foreach ($d in $details) { Write-Host ("  " + $d) }
    Write-Host ""
    if ($failures.Count -eq 0) {
        Write-Host "SELFTEST : PASS"
        return 0
    }
    Write-Host "SELFTEST : FAIL"
    foreach ($f in $failures) { Write-Host ("  - " + $f) }
    return 7
}

# ---------------------------------------------------------------------------
# Point d'entree
# ---------------------------------------------------------------------------

if ($SelfTest) {
    $code = Invoke-SelfTest
    exit $code
}

$mainResult = Invoke-Measurement -TargetName $ProcessName -TargetId $ProcessId -DurationSec $DurationSec -IntervalSec $IntervalSec -Tag $Tag -OutDir $OutDir -AllowAppProcess ([bool]$AllowAppProcess) -SkipCounterCrossCheck ([bool]$SkipCounterCrossCheck)
exit ([int]$mainResult.ExitCode)
