<#
.SYNOPSIS
    ProcessSampler - echantillonneur exact et a faible surcout d'un processus Windows.

.DESCRIPTION
    Echantillonne un processus EXTERNE (par PID ou par nom) a intervalle fixe, via des
    appels P/Invoke Win32 (ProcessNative.cs) et non via System.Diagnostics.Process :
      * GetProcessTimes        -> temps CPU noyau + utilisateur (unites 100 ns)
      * GetProcessMemoryInfo   -> PROCESS_MEMORY_COUNTERS_EX : WS, pic WS, commit,
                                  pic commit, defauts de page, PrivateUsage
      * QueryWorkingSet        -> working set PRIVE exact (pages valides non partagees)
      * GetProcessHandleCount  -> nombre de handles
      * GetGuiResources        -> objets GDI et USER
      * GetProcessIoCounters   -> octets et operations d'E/S (compteurs cumules)
      * NtQuerySystemInformation -> nombre de threads et CPU par thread (repli GetThreadTimes)

    Sorties :
      * un CSV par echantillon (15 colonnes, separateur virgule, decimales invariantes)
      * un JSON de synthese (statistiques, metadonnees, surcout de l'outil, cross-check)
      * un resume lisible sur stdout

    Le processus cible n'est JAMAIS modifie : seuls des handles en lecture seule sont
    ouverts (PROCESS_QUERY_* / PROCESS_VM_READ), puis fermes. Aucune interaction UI.

.PARAMETER ProcessId
    PID du processus cible. Obligatoire si -ProcessName n'est pas fourni.

.PARAMETER ProcessName
    Nom du processus cible (avec ou sans .exe). Doit correspondre a UN SEUL processus,
    sinon l'outil refuse et liste les PID candidats (utiliser -ProcessId).

.PARAMETER DurationSeconds
    Duree de mesure en secondes (defaut 60).

.PARAMETER IntervalMs
    Periode d'echantillonnage en millisecondes (defaut 1000, minimum 50).

.PARAMETER Csv
    Chemin du CSV de sortie. Defaut : <dossier script>\results\sampler-<label>-<pid>-<horodatage>.csv

.PARAMETER Json
    Chemin du JSON de sortie. Defaut : meme nom que le CSV avec .json

.PARAMETER Label
    Etiquette libre recopiee dans le JSON (defaut : nom du processus).

.PARAMETER IncludeThreads
    Active la lecture par thread (NtQuerySystemInformation, repli GetThreadTimes) et l'attribution CPU top N
    dans le JSON. Cout CPU supplementaire de l'outil (croit avec le nombre de threads).

.PARAMETER TopThreads
    Nombre de threads remontes dans l'attribution CPU (defaut 5).

.PARAMETER CrossCheck
    Active la verification croisee CPU / plage de travail via Get-Counter, en parallele
    de la mesure, pendant la meme fenetre temporelle. Les noms de compteurs localises
    (ex. Windows francais : "\Processus(*)\% temps processeur") sont decouverts
    dynamiquement ; repli sur les noms anglais. Ajoute un processus job temporaire.

.PARAMETER Snapshot
    Mode instantane : ne boucle pas et lit UNE seule fois toutes les metriques du
    processus (CPU total user+noyau, WS, WS prive, commit, pic WS, handles, GDI,
    USER, threads, E/S cumulees, defauts de page), ecrit le JSON puis sort. Le CSV
    n'est pas produit et -DurationSeconds / -IntervalMs / -IncludeThreads / -CrossCheck
    sont ignores. Utile pour comparer l'etat d'un processus avant/apres un cycle
    d'ouverture-fermeture (deltas GDI, handles, WS).

.PARAMETER EmitJson
    Emet le JSON de synthese sur stdout entre les marqueurs SUMMARY_JSON et
    SUMMARY_JSON_END (les autres messages restent sur stdout, en texte).

.PARAMETER Quiet
    N'affiche que le resume final (pas de messages de progression).

.EXAMPLE
    .\ProcessSampler.ps1 -ProcessName notepad -DurationSeconds 60

.EXAMPLE
    .\ProcessSampler.ps1 -ProcessId 4242 -DurationSeconds 120 -IntervalMs 500 `
        -Csv .\results\run.csv -Json .\results\run.json -Label "campagne-A" -IncludeThreads

.EXAMPLE
    .\ProcessSampler.ps1 -ProcessId 4242 -DurationSeconds 60 -CrossCheck -EmitJson

.NOTES
    Windows PowerShell 5.1 / .NET Framework 4.x. Droits normaux suffisent pour la
    plupart des processus ; un processus protege (systeme, anti-triche) peut refuser
    totalement l'ouverture de handle (erreur explicite).
    Ne pas mesurer RiotSwitch pendant la campagne : utiliser un processus factice.
#>

[CmdletBinding()]
param(
    [int]$ProcessId = 0,
    [string]$ProcessName = '',
    [ValidateRange(1, 86400)][int]$DurationSeconds = 60,
    [ValidateRange(50, 60000)][int]$IntervalMs = 1000,
    [string]$Csv = '',
    [string]$Json = '',
    [string]$Label = '',
    [switch]$IncludeThreads,
    [ValidateRange(1, 64)][int]$TopThreads = 5,
    [switch]$CrossCheck,
    [switch]$Snapshot,
    [switch]$EmitJson,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ToolName = 'ProcessSampler'
$script:ToolVersion = '1.0.0'
$script:Invariant = [System.Globalization.CultureInfo]::InvariantCulture
$script:MaxSamples = 200000
$script:Warnings = New-Object System.Collections.Generic.List[string]
$script:Notes = New-Object System.Collections.Generic.List[string]

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$Level = 'INFO'
    )
    if (-not $Quiet) {
        Write-Host ('[{0}] {1}' -f $Level, $Message)
    }
}

function Add-Warning {
    param([Parameter(Mandatory = $true)][string]$Message)
    [void]$script:Warnings.Add($Message)
    Write-Log -Message $Message -Level 'AVERT'
}

function Resolve-FullPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$BaseDirectory = '.'
    )
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ([System.IO.Path]::IsPathRooted($expanded)) {
        return [System.IO.Path]::GetFullPath($expanded)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $BaseDirectory $expanded))
}

function Ensure-ParentDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)
    $parent = [System.IO.Path]::GetDirectoryName($Path)
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        [void](New-Item -ItemType Directory -Path $parent -Force)
    }
}

function Format-Inv {
    param(
        [double]$Value,
        [Parameter(Mandatory = $true)][string]$Format
    )
    return $Value.ToString($Format, $script:Invariant)
}

function Format-Int64Inv {
    param([long]$Value)
    return $Value.ToString($script:Invariant)
}

function Get-PercentileValue {
    param(
        [Parameter(Mandatory = $true)][double[]]$SortedValues,
        [Parameter(Mandatory = $true)][double]$Percentile
    )
    $n = $SortedValues.Count
    if ($n -eq 0) {
        return $null
    }
    if ($n -eq 1) {
        return $SortedValues[0]
    }
    $rank = ($Percentile / 100.0) * ($n - 1)
    $lower = [int][math]::Floor($rank)
    $upper = [int][math]::Ceiling($rank)
    if ($lower -eq $upper) {
        return [double]$SortedValues[$lower]
    }
    $fraction = $rank - $lower
    return [double]($SortedValues[$lower] + ($SortedValues[$upper] - $SortedValues[$lower]) * $fraction)
}

function Get-NumericStats {
    param([double[]]$Values)
    $clean = New-Object System.Collections.Generic.List[double]
    if ($null -ne $Values) {
        foreach ($value in $Values) {
            if ($null -eq $value) { continue }
            $asDouble = [double]$value
            if ([double]::IsNaN($asDouble) -or [double]::IsInfinity($asDouble)) { continue }
            $clean.Add($asDouble)
        }
    }
    $count = $clean.Count
    if ($count -eq 0) {
        return [pscustomobject]@{
            count = 0
            mean  = $null
            min   = $null
            max   = $null
            p50   = $null
            p95   = $null
            sum   = $null
        }
    }
    $sorted = $clean.ToArray()
    [Array]::Sort($sorted)
    $sum = 0.0
    foreach ($value in $sorted) { $sum += $value }
    return [pscustomobject]@{
        count = $count
        mean  = $sum / $count
        min   = [double]$sorted[0]
        max   = [double]$sorted[$count - 1]
        p50   = (Get-PercentileValue -SortedValues $sorted -Percentile 50.0)
        p95   = (Get-PercentileValue -SortedValues $sorted -Percentile 95.0)
        sum   = $sum
    }
}

function Format-BytesForDisplay {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} Gio' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} Mio' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N2} Kio' -f ($Bytes / 1KB)) }
    return ('{0} octets' -f $Bytes)
}

# ---------------------------------------------------------------------------
# 1. Chargement du helper natif P/Invoke
# ---------------------------------------------------------------------------
$nativeSource = Join-Path $PSScriptRoot 'ProcessNative.cs'
if (-not ($null -ne ('RiotSwitchPerf.ProcessNative' -as [type]))) {
    if (-not (Test-Path -LiteralPath $nativeSource)) {
        throw "Helper natif introuvable : $nativeSource"
    }
    try {
        Add-Type -Path $nativeSource -ErrorAction Stop
    }
    catch {
        throw ("Compilation du helper P/Invoke impossible : " + $_.Exception.Message)
    }
}
$native = 'RiotSwitchPerf.ProcessNative' -as [type]
if ($null -eq $native) {
    throw 'Le type RiotSwitchPerf.ProcessNative est introuvable apres Add-Type.'
}

# ---------------------------------------------------------------------------
# 2. Resolution de la cible
# ---------------------------------------------------------------------------
if ($ProcessId -le 0 -and [string]::IsNullOrWhiteSpace($ProcessName)) {
    throw 'Fournir -ProcessId ou -ProcessName.'
}
if ($ProcessId -le 0) {
    $nameToMatch = $ProcessName.Trim()
    if ($nameToMatch -match '(?i)\.exe$') {
        $nameToMatch = $nameToMatch -replace '(?i)\.exe$', ''
    }
    $nameMatches = @(Get-Process -Name $nameToMatch -ErrorAction SilentlyContinue)
    if ($nameMatches.Count -eq 0) {
        throw ("Aucun processus nomme '" + $nameToMatch + "'.")
    }
    if ($nameMatches.Count -gt 1) {
        $idList = ($nameMatches | ForEach-Object { [string]$_.Id }) -join ', '
        throw ("Plusieurs processus nommes '" + $nameToMatch + "' (PID : " + $idList + "). Utiliser -ProcessId.")
    }
    $ProcessId = [int]$nameMatches[0].Id
}

$targetProcess = $null
try {
    $targetProcess = Get-Process -Id $ProcessId -ErrorAction Stop
}
catch {
    throw ("Processus introuvable (PID " + $ProcessId + ") : " + $_.Exception.Message)
}

$targetName = [string]$targetProcess.ProcessName
$targetExePath = ''
try {
    $targetExePath = [string]$targetProcess.MainModule.FileName
}
catch {
    Write-Verbose ('Chemin du binaire indisponible : ' + $_.Exception.Message)
}
$targetStartUtc = $null
try {
    $targetStartUtc = $targetProcess.StartTime.ToUniversalTime()
}
catch {
    Write-Verbose ('Heure de demarrage indisponible : ' + $_.Exception.Message)
}

if ([string]::IsNullOrWhiteSpace($Label)) {
    $Label = $targetName
}

$sampleCount = 1
if (-not $Snapshot) {
    $sampleCount = [int][math]::Floor(($DurationSeconds * 1000.0) / $IntervalMs)
    if ($sampleCount -lt 1) { $sampleCount = 1 }
    if ($sampleCount -gt $script:MaxSamples) {
        throw ("Nombre d'echantillons trop eleve (" + $sampleCount + ") : reduire la duree ou augmenter -IntervalMs (max " + $script:MaxSamples + ").")
    }
}

$startStamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
$resultsRoot = Join-Path $PSScriptRoot 'results'
$safeLabel = ($Label -replace '[^A-Za-z0-9_.-]', '_')
if ($Snapshot) {
    if (-not [string]::IsNullOrWhiteSpace($Csv)) {
        Add-Warning '-Csv ignore en mode -Snapshot (aucun echantillonnage, aucun CSV produit).'
        $Csv = ''
    }
    if ([string]::IsNullOrWhiteSpace($Json)) {
        $Json = Join-Path $resultsRoot ('snapshot-' + $safeLabel + '-' + $ProcessId + '-' + $startStamp + '.json')
    }
    else {
        $Json = Resolve-FullPath -Path $Json
    }
    Ensure-ParentDirectory -Path $Json
}
else {
    if ([string]::IsNullOrWhiteSpace($Csv)) {
        $Csv = Join-Path $resultsRoot ('sampler-' + $safeLabel + '-' + $ProcessId + '-' + $startStamp + '.csv')
    }
    else {
        $Csv = Resolve-FullPath -Path $Csv
    }
    if ([string]::IsNullOrWhiteSpace($Json)) {
        $Json = [System.IO.Path]::ChangeExtension($Csv, '.json')
    }
    else {
        $Json = Resolve-FullPath -Path $Json
    }
    Ensure-ParentDirectory -Path $Csv
    Ensure-ParentDirectory -Path $Json
}

Write-Log ("Cible : " + $targetName + " (PID " + $ProcessId + ")")
if ($Snapshot) {
    Write-Log 'Mode : snapshot unique (aucune boucle, aucun CSV)'
    Write-Log ("JSON : " + $Json)
}
else {
    Write-Log ("Duree : " + $DurationSeconds + " s, intervalle " + $IntervalMs + " ms, " + $sampleCount + " echantillons")
    Write-Log ("CSV : " + $Csv)
    Write-Log ("JSON : " + $Json)
}

# ---------------------------------------------------------------------------
# 2 bis. Mode -Snapshot : une seule lecture, JSON immediat, sortie
# ---------------------------------------------------------------------------
if ($Snapshot) {
    $snapshotWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $snapshotHandle = [IntPtr]::Zero
    [uint32]$snapshotGranted = 0
    $snapshotSample = $null
    [long]$snapshotCreation100ns = 0
    $snapshotPrivateSupported = $false
    try {
        $snapshotHandle = [RiotSwitchPerf.ProcessNative]::OpenSamplingHandle($ProcessId, [ref]$snapshotGranted)
        if ($snapshotHandle -eq [IntPtr]::Zero) {
            $snapshotLastError = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw ("Impossible d'ouvrir un handle de mesure sur le PID " + $ProcessId + " (erreur Win32 " + $snapshotLastError + "). Processus protege, termine ou droits insuffisants.")
        }
        $snapshotPrivateSupported = ((($snapshotGranted -band 0x0410) -eq 0x0410))
        $snapshotSample = [RiotSwitchPerf.ProcessNative]::ReadSample($snapshotHandle, $ProcessId, $snapshotPrivateSupported)
        [void][RiotSwitchPerf.ProcessNative]::TryGetCreationTime100ns($snapshotHandle, [ref]$snapshotCreation100ns)
    }
    finally {
        if ($snapshotHandle -ne [IntPtr]::Zero) {
            [RiotSwitchPerf.ProcessNative]::CloseSamplingHandle($snapshotHandle)
            $snapshotHandle = [IntPtr]::Zero
        }
    }
    $snapshotWatch.Stop()

    if (-not $snapshotSample.TimesValid -or -not $snapshotSample.MemoryValid) {
        throw 'Lecture snapshot impossible (GetProcessTimes ou GetProcessMemoryInfo en echec).'
    }

    $snapshotNowUtc = (Get-Date).ToUniversalTime()
    $snapshotStartUtc = $null
    if ($snapshotCreation100ns -gt 0) {
        $snapshotStartUtc = [System.DateTime]::FromFileTimeUtc([long]$snapshotCreation100ns)
    }
    elseif ($null -ne $targetStartUtc) {
        $snapshotStartUtc = $targetStartUtc
    }
    $snapshotStartIso = $null
    $snapshotUptime = $null
    if ($null -ne $snapshotStartUtc) {
        $snapshotStartIso = $snapshotStartUtc.ToString('o')
        $snapshotUptime = [math]::Round(($snapshotNowUtc - $snapshotStartUtc).TotalSeconds, 3)
    }
    else {
        Add-Warning 'Date de demarrage du processus indisponible : uptime_s = null.'
    }

    $snapshotPrivateWs = -1L
    if ($snapshotSample.PrivateWorkingSetValid) {
        $snapshotPrivateWs = [long]$snapshotSample.PrivateWorkingSetBytes
    }
    elseif (-not $snapshotPrivateSupported) {
        Add-Warning 'Snapshot : working set prive indisponible (PROCESS_VM_READ non accorde).'
    }
    $snapshotHandles = -1L
    if ($snapshotSample.HandleCountValid) { $snapshotHandles = [long]$snapshotSample.HandleCount }
    $snapshotGdi = -1L
    $snapshotUserObjects = -1L
    if ($snapshotSample.GuiResourcesValid) {
        $snapshotGdi = [long]$snapshotSample.GdiObjects
        $snapshotUserObjects = [long]$snapshotSample.UserObjects
    }

    $snapshotCounters = [pscustomobject]@{
        cpu_total_seconds  = [math]::Round((([long]$snapshotSample.Kernel100ns + [long]$snapshotSample.User100ns) / 10000000.0), 6)
        cpu_user_seconds   = [math]::Round(([long]$snapshotSample.User100ns / 10000000.0), 6)
        cpu_kernel_seconds = [math]::Round(([long]$snapshotSample.Kernel100ns / 10000000.0), 6)
        ws_bytes           = [long]$snapshotSample.WorkingSetBytes
        private_ws_bytes   = [long]$snapshotPrivateWs
        commit_bytes       = [long]$snapshotSample.CommitBytes
        peak_ws_bytes      = [long]$snapshotSample.PeakWorkingSetBytes
        handles            = [long]$snapshotHandles
        gdi_objects        = [long]$snapshotGdi
        user_objects       = [long]$snapshotUserObjects
        threads            = [int]$snapshotSample.ThreadCount
        io_read_bytes      = [long]$snapshotSample.IoReadBytes
        io_write_bytes     = [long]$snapshotSample.IoWriteBytes
        io_other_bytes     = [long]$snapshotSample.IoOtherBytes
        io_read_operations = [long]$snapshotSample.IoReadOperations
        io_write_operations = [long]$snapshotSample.IoWriteOperations
        io_other_operations = [long]$snapshotSample.IoOtherOperations
        page_faults        = [long]$snapshotSample.PageFaultCount
    }

    $snapshotNotes = @(
        'Mode snapshot : une seule lecture P/Invoke, aucune boucle, aucun CSV.',
        'Les compteurs E/S et les defauts de page sont CUMULES depuis le demarrage du processus (pas des deltas).',
        'cpu_total_seconds = temps CPU noyau + utilisateur cumule (GetProcessTimes, unites 100 ns).',
        'private_ws_bytes = pages valides non partagees (QueryWorkingSet) x taille de page ; -1 si indisponible.',
        'Comparer deux snapshots (avant/apres) pour obtenir les deltas handles / GDI / USER / WS.'
    )

    $snapshotTarget = [pscustomobject]@{
        pid                        = [int]$ProcessId
        process_name               = $targetName
        exe_path                   = $targetExePath
        process_start_iso          = $snapshotStartIso
        uptime_s                   = $snapshotUptime
        sampling_access_rights     = ('0x{0:X}' -f $snapshotGranted)
        private_working_set_supported = [bool]$snapshotPrivateSupported
    }

    $snapshotSummary = [pscustomobject]@{
        schema       = 'riotswitch.perf.process-snapshot/1'
        mode         = 'snapshot'
        tool         = [pscustomobject]@{
            name               = $script:ToolName
            version            = $script:ToolVersion
            script             = 'ProcessSampler.ps1'
            native_helper      = 'ProcessNative.cs'
            powershell_version = $PSVersionTable.PSVersion.ToString()
            os                 = [System.Environment]::OSVersion.VersionString
        }
        label        = $Label
        generated_at_utc = $snapshotNowUtc.ToString('o')
        host         = [pscustomobject]@{
            name        = [string]$env:COMPUTERNAME
            user        = [string]$env:USERNAME
            logical_processors = [int][Environment]::ProcessorCount
            os_caption  = ([string]$env:OS)
        }
        target       = $snapshotTarget
        counters     = $snapshotCounters
        sampler_overhead = [pscustomobject]@{
            snapshot_read_ms = [math]::Round($snapshotWatch.Elapsed.TotalMilliseconds, 3)
            note             = 'Duree murale de la lecture snapshot (hors ouverture/fermeture du handle).'
        }
        warnings     = $script:Warnings.ToArray()
        notes        = $snapshotNotes
    }

    $snapshotJsonText = $snapshotSummary | ConvertTo-Json -Depth 12
    $snapshotUtf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Json, $snapshotJsonText + [Environment]::NewLine, $snapshotUtf8)

    Write-Host ''
    Write-Host ('=== Snapshot : ' + $targetName + ' (PID ' + $ProcessId + ') ===')
    Write-Host ('CPU totale         : ' + ('{0:N3}' -f $snapshotCounters.cpu_total_seconds) + ' s (user ' + ('{0:N3}' -f $snapshotCounters.cpu_user_seconds) + ' / noyau ' + ('{0:N3}' -f $snapshotCounters.cpu_kernel_seconds) + ')')
    Write-Host ('Memoire            : WS ' + (Format-BytesForDisplay -Bytes ([long]$snapshotCounters.ws_bytes)) + ', prive ' + $(if ($snapshotCounters.private_ws_bytes -ge 0) { Format-BytesForDisplay -Bytes ([long]$snapshotCounters.private_ws_bytes) } else { 'n/d' }) + ', commit ' + (Format-BytesForDisplay -Bytes ([long]$snapshotCounters.commit_bytes)) + ', pic WS ' + (Format-BytesForDisplay -Bytes ([long]$snapshotCounters.peak_ws_bytes)))
    Write-Host ('Handles / GDI / USER : ' + $snapshotCounters.handles + ' / ' + $snapshotCounters.gdi_objects + ' / ' + $snapshotCounters.user_objects + ' ; threads ' + $snapshotCounters.threads)
    Write-Host ('E/S cumulees       : lecture ' + (Format-BytesForDisplay -Bytes ([long]$snapshotCounters.io_read_bytes)) + ', ecriture ' + (Format-BytesForDisplay -Bytes ([long]$snapshotCounters.io_write_bytes)) + ' ; defauts de page ' + $snapshotCounters.page_faults)
    if ($null -ne $snapshotUptime) {
        Write-Host ('Demarrage          : ' + $snapshotStartIso + ' (uptime ' + ('{0:N1}' -f $snapshotUptime) + ' s)')
    }
    if ($script:Warnings.Count -gt 0) {
        foreach ($warning in $script:Warnings) { Write-Host ('AVERTISSEMENT      : ' + $warning) }
    }
    Write-Host ('JSON               : ' + $Json)
    Write-Host ''
    exit 0
}

# ---------------------------------------------------------------------------
# 3. Ouverture du handle de mesure
# ---------------------------------------------------------------------------
$processHandle = [IntPtr]::Zero
[uint32]$grantedAccess = 0
$privateWorkingSetSupported = $false
$exitedEarly = $false
$crossCheckJob = $null
$crossCheckData = $null
$threadPrevious = @{}
$threadTotals = @{}
$threadCountSeen = 0
$rows = New-Object System.Collections.Generic.List[object]
$stopwatch = $null
$baseline = $null
$finalSample = $null
[long]$processCreation100ns = 0
$processStartUtc = $null

try {
    $processHandle = [RiotSwitchPerf.ProcessNative]::OpenSamplingHandle($ProcessId, [ref]$grantedAccess)
    if ($processHandle -eq [IntPtr]::Zero) {
        $lastError = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw ("Impossible d'ouvrir un handle de mesure sur le PID " + $ProcessId + " (erreur Win32 " + $lastError + "). Processus protege, terminee ou droits insuffisants.")
    }
    # 0x0010 = PROCESS_VM_READ, 0x0410 = PROCESS_QUERY_INFORMATION | PROCESS_VM_READ
    $privateWorkingSetSupported = ((($grantedAccess -band 0x0410) -eq 0x0410))
    if (-not $privateWorkingSetSupported) {
        Add-Warning "Droits VM_READ non accordes : working set prive indisponible (colonne private_ws_bytes = -1)."
    }

    # Date de demarrage exacte via GetProcessTimes (repli : StartTime de .NET).
    [void][RiotSwitchPerf.ProcessNative]::TryGetCreationTime100ns($processHandle, [ref]$processCreation100ns)
    if ($processCreation100ns -gt 0) {
        $processStartUtc = [System.DateTime]::FromFileTimeUtc([long]$processCreation100ns)
    }
    elseif ($null -ne $targetStartUtc) {
        $processStartUtc = $targetStartUtc
    }

    # -----------------------------------------------------------------------
    # 4. Cross-check optionnel : collecte Get-Counter en parallele
    # -----------------------------------------------------------------------
    if ($CrossCheck) {
        $counterMapScript = Join-Path $PSScriptRoot 'Get-ProcessCounterMap.ps1'
        if (-not (Test-Path -LiteralPath $counterMapScript)) {
            Add-Warning ('Cross-check ignore : ' + $counterMapScript + ' introuvable.')
        }
        else {
            . $counterMapScript
            $templates = Get-ProcessPerfCounterPaths
            $instanceName = Resolve-PerfProcessInstanceName -ProcessId $ProcessId
            if ($null -eq $instanceName) {
                Add-Warning ("Cross-check ignore : impossible de resoudre l'instance de performance du PID " + $ProcessId + " (WMI/CIM).")
            }
            elseif ($null -eq $templates) {
                Add-Warning 'Cross-check ignore : aucun jeu de compteurs processus detecte.'
            }
            else {
                $cpuCounterPath = New-ProcessCounterPath -Template $templates.CpuPath -Instance $instanceName
                $wsCounterPath = New-ProcessCounterPath -Template $templates.WsPath -Instance $instanceName
                $counterSamples = $DurationSeconds + 2
                $collector = Get-CrossCheckCollectorScript
                Write-Log ("Cross-check : Get-Counter [" + $templates.SetName + " / " + $instanceName + "], " + $counterSamples + " echantillons a 1 s.")
                $crossCheckJob = Start-Job -Name ('sampler-crosscheck-' + $ProcessId) -ScriptBlock $collector `
                    -ArgumentList @($cpuCounterPath, $wsCounterPath, $counterSamples, 1)
                $crossCheckData = [pscustomobject]@{
                    Enabled              = $true
                    Method               = 'Get-Counter (chemins localises detectes dynamiquement)'
                    Detection            = $templates.Detection
                    CounterSetName       = $templates.SetName
                    InstanceName         = $instanceName
                    CpuCounterPath       = $cpuCounterPath
                    WsCounterPath        = $wsCounterPath
                    Cpu                  = $null
                    Ws                   = $null
                    Errors               = New-Object System.Collections.Generic.List[string]
                }
            }
        }
    }

    # -----------------------------------------------------------------------
    # 5. Ligne de base
    # -----------------------------------------------------------------------
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $baseline = [RiotSwitchPerf.ProcessNative]::ReadSample($processHandle, $ProcessId, $privateWorkingSetSupported, $IncludeThreads)
    if (-not $baseline.TimesValid) {
        throw 'Lecture CPU initiale impossible (GetProcessTimes).'
    }
    $baselineCpu100ns = [long]$baseline.Kernel100ns + [long]$baseline.User100ns
    $baselineKernel100ns = [long]$baseline.Kernel100ns
    $baselineUser100ns = [long]$baseline.User100ns
    $previousCpu100ns = $baselineCpu100ns
    $previousFaults = [long]$baseline.PageFaultCount
    $previousIoRead = [long]$baseline.IoReadBytes
    $previousIoWrite = [long]$baseline.IoWriteBytes
    $previousIoOther = [long]$baseline.IoOtherBytes
    $previousIoSample = [long]$baseline.IoReadOperations + [long]$baseline.IoWriteOperations + [long]$baseline.IoOtherOperations
    $previousElapsedMs = 0.0

    if ($IncludeThreads) {
        $threadPairs = $baseline.ThreadCpuPairs
        if ($null -eq $threadPairs) {
            Add-Warning 'Attribution threads : lecture initiale des threads indisponible.'
        }
        else {
            for ($index = 0; $index -lt $threadPairs.Count; $index += 2) {
                $threadId = [int]$threadPairs[$index]
                $threadCpu = [long]$threadPairs[$index + 1]
                if ($threadCpu -lt 0) { continue }
                $threadPrevious[$threadId] = $threadCpu
                $threadTotals[$threadId] = 0L
            }
            $threadCountSeen = $threadTotals.Count
        }
    }

    $ownCpuStart = $null
    [long]$ownKernel = 0
    [long]$ownUser = 0
    if ([RiotSwitchPerf.ProcessNative]::TryGetCurrentProcessTimes([ref]$ownKernel, [ref]$ownUser)) {
        $ownCpuStart = $ownKernel + $ownUser
    }

    # -----------------------------------------------------------------------
    # 6. Boucle d'echantillonnage
    # -----------------------------------------------------------------------
    $timestampFormat = 'o'
    for ($index = 1; $index -le $sampleCount; $index++) {
        $targetMs = [double]$index * [double]$IntervalMs
        $remainingMs = $targetMs - $stopwatch.Elapsed.TotalMilliseconds
        if ($remainingMs -gt 0.5) {
            Start-Sleep -Milliseconds ([int][math]::Round($remainingMs))
        }

        $sample = [RiotSwitchPerf.ProcessNative]::ReadSample($processHandle, $ProcessId, $privateWorkingSetSupported, $IncludeThreads)
        $elapsedMs = $stopwatch.Elapsed.TotalMilliseconds
        $deltaSeconds = ($elapsedMs - $previousElapsedMs) / 1000.0
        if ($deltaSeconds -le 0) { $deltaSeconds = 0.001 }

        if (-not $sample.TimesValid -or -not $sample.MemoryValid) {
            $exitedEarly = $true
            Add-Warning ('Le processus cible a disparu a l echantillon ' + $index + ' (mesure partielle conservee).')
            break
        }

        $cpuNow100ns = [long]$sample.Kernel100ns + [long]$sample.User100ns
        $deltaCpu100ns = $cpuNow100ns - $previousCpu100ns
        if ($deltaCpu100ns -lt 0) { $deltaCpu100ns = 0 }
        $cpuTotalSeconds = $cpuNow100ns / 10000000.0
        $cpuPctOneCore = ($deltaCpu100ns / 10000000.0) / $deltaSeconds * 100.0

        $faultsDelta = [long]$sample.PageFaultCount - $previousFaults
        if ($faultsDelta -lt 0) {
            # PageFaultCount est un DWORD 32 bits : correction de debordement.
            $faultsDelta = 4294967296L - $previousFaults + [long]$sample.PageFaultCount
        }

        $ioReadDelta = [long]$sample.IoReadBytes - $previousIoRead
        if ($ioReadDelta -lt 0) { $ioReadDelta = 0 }
        $ioWriteDelta = [long]$sample.IoWriteBytes - $previousIoWrite
        if ($ioWriteDelta -lt 0) { $ioWriteDelta = 0 }

        $privateWsBytes = -1L
        if ($sample.PrivateWorkingSetValid) {
            $privateWsBytes = [long]$sample.PrivateWorkingSetBytes
        }
        $gdiValue = -1L
        $userValue = -1L
        if ($sample.GuiResourcesValid) {
            $gdiValue = [long]$sample.GdiObjects
            $userValue = [long]$sample.UserObjects
        }
        $handleValue = -1L
        if ($sample.HandleCountValid) {
            $handleValue = [long]$sample.HandleCount
        }

        $row = [pscustomobject]@{
            timestamp_utc  = (Get-Date).ToUniversalTime().ToString($timestampFormat)
            elapsed_s      = [double]($elapsedMs / 1000.0)
            cpu_total_s    = [double]$cpuTotalSeconds
            cpu_pct_core   = [double]$cpuPctOneCore
            ws_bytes       = [long]$sample.WorkingSetBytes
            private_ws_bytes = [long]$privateWsBytes
            commit_bytes   = [long]$sample.CommitBytes
            peak_ws_bytes  = [long]$sample.PeakWorkingSetBytes
            handles        = [long]$handleValue
            gdi            = [long]$gdiValue
            user           = [long]$userValue
            threads        = [int]$sample.ThreadCount
            io_read_bytes  = [long]$ioReadDelta
            io_write_bytes = [long]$ioWriteDelta
            pagefaults_delta = [long]$faultsDelta
        }
        $rows.Add($row)

        $previousCpu100ns = $cpuNow100ns
        $previousFaults = [long]$sample.PageFaultCount
        $previousIoRead = [long]$sample.IoReadBytes
        $previousIoWrite = [long]$sample.IoWriteBytes
        $previousIoOther = [long]$sample.IoOtherBytes
        $previousIoSample = [long]$sample.IoReadOperations + [long]$sample.IoWriteOperations + [long]$sample.IoOtherOperations
        $previousElapsedMs = $elapsedMs

        if ($IncludeThreads) {
            $pairs = $sample.ThreadCpuPairs
            if ($null -ne $pairs) {
            $newPrevious = @{}
            for ($pairIndex = 0; $pairIndex -lt $pairs.Count; $pairIndex += 2) {
                $threadId = [int]$pairs[$pairIndex]
                $threadCpu = [long]$pairs[$pairIndex + 1]
                if ($threadCpu -lt 0) { continue }
                $delta = 0L
                if ($threadPrevious.ContainsKey($threadId)) {
                    $delta = $threadCpu - [long]$threadPrevious[$threadId]
                    if ($delta -lt 0) { $delta = 0 }
                }
                if (-not $threadTotals.ContainsKey($threadId)) {
                    $threadTotals[$threadId] = 0L
                    $threadCountSeen = $threadTotals.Count
                }
                $threadTotals[$threadId] = [long]$threadTotals[$threadId] + $delta
                $newPrevious[$threadId] = $threadCpu
            }
            $threadPrevious = $newPrevious
            }
        }
    }

    # Echantillon final (hors CSV) : ferme la mesure CPU et l'attribution des threads
    # jusqu'a la fin reelle de la boucle.
    if (-not $exitedEarly) {
        $finalSample = [RiotSwitchPerf.ProcessNative]::ReadSample($processHandle, $ProcessId, $privateWorkingSetSupported, $IncludeThreads)
        if ($IncludeThreads -and $finalSample.TimesValid) {
            $pairs = $finalSample.ThreadCpuPairs
            if ($null -ne $pairs) {
            for ($pairIndex = 0; $pairIndex -lt $pairs.Count; $pairIndex += 2) {
                $threadId = [int]$pairs[$pairIndex]
                $threadCpu = [long]$pairs[$pairIndex + 1]
                if ($threadCpu -lt 0) { continue }
                $delta = 0L
                if ($threadPrevious.ContainsKey($threadId)) {
                    $delta = $threadCpu - [long]$threadPrevious[$threadId]
                    if ($delta -lt 0) { $delta = 0 }
                }
                if (-not $threadTotals.ContainsKey($threadId)) {
                    $threadTotals[$threadId] = 0L
                }
                $threadTotals[$threadId] = [long]$threadTotals[$threadId] + $delta
            }
            }
        }
    }

    # La fenetre de mesure et le surcout s'arretent ICI : la recuperation du job
    # Get-Counter (attente + deserialisation) ne fait pas partie de la mesure.
    $loopElapsedSeconds = $stopwatch.Elapsed.TotalSeconds
    [long]$ownKernelEnd = 0
    [long]$ownUserEnd = 0
    $ownCpuEnd = $null
    if ([RiotSwitchPerf.ProcessNative]::TryGetCurrentProcessTimes([ref]$ownKernelEnd, [ref]$ownUserEnd)) {
        $ownCpuEnd = $ownKernelEnd + $ownUserEnd
    }
    $stopwatch.Stop()

    # -----------------------------------------------------------------------
    # 7. Recuperation du cross-check
    # -----------------------------------------------------------------------
    if ($null -ne $crossCheckJob) {
        $waitSeconds = $DurationSeconds + 60
        [void]($crossCheckJob | Wait-Job -Timeout $waitSeconds)
        if ($crossCheckJob.State -ne 'Completed') {
            $crossCheckData.Errors.Add('Job Get-Counter non termine dans le delai imparti.')
            Add-Warning 'Cross-check : job Get-Counter non termine, comparaison partielle ignoree.'
        }
        else {
            $jobErrors = @()
            $jobOutput = @(Receive-Job -Job $crossCheckJob -ErrorVariable jobErrors -ErrorAction SilentlyContinue -WarningAction SilentlyContinue)
            if ($jobErrors.Count -gt 0) {
                foreach ($jobError in $jobErrors) { $crossCheckData.Errors.Add([string]$jobError) }
            }
            if ($jobOutput.Count -gt 0) {
                $jobResult = $jobOutput[$jobOutput.Count - 1]
                if ($null -ne $jobResult.PSObject.Properties['Cpu']) {
                    $crossCheckData.Cpu = @($jobResult.Cpu)
                    $crossCheckData.Ws = @($jobResult.Ws)
                }
                else {
                    $crossCheckData.Errors.Add('Sortie du job Get-Counter inattendue.')
                }
            }
            else {
                $crossCheckData.Errors.Add('Aucune sortie recue du job Get-Counter.')
            }
        }
        Stop-Job -Job $crossCheckJob -ErrorAction SilentlyContinue
        Remove-Job -Job $crossCheckJob -Force -ErrorAction SilentlyContinue
        $crossCheckJob = $null
    }
}
finally {
    if ($null -ne $crossCheckJob) {
        Stop-Job -Job $crossCheckJob -ErrorAction SilentlyContinue
        Remove-Job -Job $crossCheckJob -Force -ErrorAction SilentlyContinue
        $crossCheckJob = $null
    }
    if ($processHandle -ne [IntPtr]::Zero) {
        [RiotSwitchPerf.ProcessNative]::CloseSamplingHandle($processHandle)
        $processHandle = [IntPtr]::Zero
    }
    if ($null -ne $stopwatch) {
        $stopwatch.Stop()
    }
}

# ---------------------------------------------------------------------------
# 8. Ecriture du CSV
# ---------------------------------------------------------------------------
$columns = @(
    'timestamp_utc', 'elapsed_s', 'cpu_total_s', 'cpu_pct_core', 'ws_bytes',
    'private_ws_bytes', 'commit_bytes', 'peak_ws_bytes', 'handles', 'gdi', 'user',
    'threads', 'io_read_bytes', 'io_write_bytes', 'pagefaults_delta'
)
$builder = New-Object System.Text.StringBuilder
[void]$builder.AppendLine([string]::Join(',', [string[]]$columns))
foreach ($row in $rows) {
    $values = @('', '', '', '', '', '', '', '', '', '', '', '', '', '', '')
    $values[0] = [string]$row.timestamp_utc
    $values[1] = Format-Inv -Value ([double]$row.elapsed_s) -Format 'F3'
    $values[2] = Format-Inv -Value ([double]$row.cpu_total_s) -Format 'F6'
    $values[3] = Format-Inv -Value ([double]$row.cpu_pct_core) -Format 'F3'
    $values[4] = Format-Int64Inv -Value ([long]$row.ws_bytes)
    $values[5] = Format-Int64Inv -Value ([long]$row.private_ws_bytes)
    $values[6] = Format-Int64Inv -Value ([long]$row.commit_bytes)
    $values[7] = Format-Int64Inv -Value ([long]$row.peak_ws_bytes)
    $values[8] = Format-Int64Inv -Value ([long]$row.handles)
    $values[9] = Format-Int64Inv -Value ([long]$row.gdi)
    $values[10] = Format-Int64Inv -Value ([long]$row.user)
    $values[11] = Format-Int64Inv -Value ([long]$row.threads)
    $values[12] = Format-Int64Inv -Value ([long]$row.io_read_bytes)
    $values[13] = Format-Int64Inv -Value ([long]$row.io_write_bytes)
    $values[14] = Format-Int64Inv -Value ([long]$row.pagefaults_delta)
    [void]$builder.AppendLine([string]::Join(',', [string[]]$values))
}
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($Csv, $builder.ToString(), $utf8NoBom)

# ---------------------------------------------------------------------------
# 9. Statistiques et JSON de synthese
# ---------------------------------------------------------------------------
$durationActual = $loopElapsedSeconds
$coreCount = [Environment]::ProcessorCount

$cpuPctCoreValues = New-Object System.Collections.Generic.List[double]
$wsValues = New-Object System.Collections.Generic.List[double]
$privateWsValues = New-Object System.Collections.Generic.List[double]
$commitValues = New-Object System.Collections.Generic.List[double]
$peakWsValues = New-Object System.Collections.Generic.List[double]
$handleValues = New-Object System.Collections.Generic.List[double]
$gdiValues = New-Object System.Collections.Generic.List[double]
$userValues = New-Object System.Collections.Generic.List[double]
$threadValues = New-Object System.Collections.Generic.List[double]
$periodValues = New-Object System.Collections.Generic.List[double]
$ioReadTotal = 0L
$ioWriteTotal = 0L
$ioOtherTotal = 0L
$faultsTotal = 0L
$previousPeriodElapsed = 0.0

foreach ($row in $rows) {
    $cpuPctCoreValues.Add([double]$row.cpu_pct_core)
    $wsValues.Add([double]$row.ws_bytes)
    if ([long]$row.private_ws_bytes -ge 0) { $privateWsValues.Add([double]$row.private_ws_bytes) }
    $commitValues.Add([double]$row.commit_bytes)
    $peakWsValues.Add([double]$row.peak_ws_bytes)
    if ([long]$row.handles -ge 0) { $handleValues.Add([double]$row.handles) }
    if ([long]$row.gdi -ge 0) { $gdiValues.Add([double]$row.gdi) }
    if ([long]$row.user -ge 0) { $userValues.Add([double]$row.user) }
    $threadValues.Add([double]$row.threads)
    $ioReadTotal += [long]$row.io_read_bytes
    $ioWriteTotal += [long]$row.io_write_bytes
    $faultsTotal += [long]$row.pagefaults_delta
    $periodValues.Add(([double]$row.elapsed_s - $previousPeriodElapsed) * 1000.0)
    $previousPeriodElapsed = [double]$row.elapsed_s
}

$cpuStats = Get-NumericStats -Values $cpuPctCoreValues.ToArray()
$wsStats = Get-NumericStats -Values $wsValues.ToArray()
$privateWsStats = Get-NumericStats -Values $privateWsValues.ToArray()
$commitStats = Get-NumericStats -Values $commitValues.ToArray()
$peakWsStats = Get-NumericStats -Values $peakWsValues.ToArray()
$handleStats = Get-NumericStats -Values $handleValues.ToArray()
$gdiStats = Get-NumericStats -Values $gdiValues.ToArray()
$userStats = Get-NumericStats -Values $userValues.ToArray()
$threadStats = Get-NumericStats -Values $threadValues.ToArray()
$periodStats = Get-NumericStats -Values $periodValues.ToArray()

# Totaux CPU a partir de l'echantillon final (borne la fenetre au dernier point connu).
$cpuMeasured100ns = 0L
$userSeconds = 0.0
$kernelSeconds = 0.0
$cpuWindowSeconds = $durationActual
$lastSampleForTotals = $null
if ($null -ne $finalSample -and $finalSample.TimesValid) {
    $lastSampleForTotals = $finalSample
}
elseif ($rows.Count -gt 0) {
    $lastRow = $rows[$rows.Count - 1]
    if ($null -ne $lastRow) {
        $cpuMeasured100ns = [long]([double]$lastRow.cpu_total_s * 10000000.0) - $baselineCpu100ns
    }
}
if ($null -ne $lastSampleForTotals) {
    $cpuMeasured100ns = ([long]$lastSampleForTotals.Kernel100ns + [long]$lastSampleForTotals.User100ns) - $baselineCpu100ns
    $userSeconds = ([long]$lastSampleForTotals.User100ns - $baselineUser100ns) / 10000000.0
    $kernelSeconds = ([long]$lastSampleForTotals.Kernel100ns - $baselineKernel100ns) / 10000000.0
    if ($userSeconds -lt 0) { $userSeconds = 0.0 }
    if ($kernelSeconds -lt 0) { $kernelSeconds = 0.0 }
}
elseif ($rows.Count -gt 0) {
    # Processus disparu : dernier cumul lisible = derniere ligne CSV.
    $lastRow = $rows[$rows.Count - 1]
    $cpuMeasured100ns = [long]([double]$lastRow.cpu_total_s * 10000000.0) - $baselineCpu100ns
}
if ($cpuMeasured100ns -lt 0) { $cpuMeasured100ns = 0 }
$totalCpuSeconds = $cpuMeasured100ns / 10000000.0
$aggregatePctCore = 0.0
if ($cpuWindowSeconds -gt 0) {
    $aggregatePctCore = ($totalCpuSeconds / $cpuWindowSeconds) * 100.0
}
$aggregatePctMachine = $aggregatePctCore / $coreCount

# Surcout mesure de l'outil (CPU de CE processus PowerShell pendant la boucle seule).
$ownCpuSeconds = $null
$overheadPctCore = $null
$overheadPctMachine = $null
$overheadMsPerSample = $null
if ($null -ne $ownCpuStart -and $null -ne $ownCpuEnd) {
    $ownCpuSeconds = ($ownCpuEnd - $ownCpuStart) / 10000000.0
    if ($ownCpuSeconds -lt 0) { $ownCpuSeconds = 0 }
    if ($durationActual -gt 0) {
        $overheadPctCore = ($ownCpuSeconds / $durationActual) * 100.0
        $overheadPctMachine = $overheadPctCore / $coreCount
    }
    if ($sampleCount -gt 0) {
        $overheadMsPerSample = ($ownCpuSeconds * 1000.0) / $sampleCount
    }
}

# Attribution CPU par thread.
$threadAttribution = $null
if ($IncludeThreads) {
    $threadEntries = New-Object System.Collections.Generic.List[object]
    $attributed100ns = 0L
    foreach ($threadId in $threadTotals.Keys) {
        $cpu100 = [long]$threadTotals[$threadId]
        if ($cpu100 -le 0) { continue }
        $attributed100ns += $cpu100
        $cpuSeconds = $cpu100 / 10000000.0
        $pctOfProcess = 0.0
        if ($totalCpuSeconds -gt 0) { $pctOfProcess = ($cpuSeconds / $totalCpuSeconds) * 100.0 }
        $pctOneCore = 0.0
        if ($durationActual -gt 0) { $pctOneCore = ($cpuSeconds / $durationActual) * 100.0 }
        $threadEntries.Add([pscustomobject]@{
            tid               = [int]$threadId
            cpu_seconds       = [math]::Round($cpuSeconds, 6)
            pct_of_process_cpu = [math]::Round($pctOfProcess, 2)
            pct_of_one_core   = [math]::Round($pctOneCore, 2)
        })
    }
    $sortedThreads = @($threadEntries | Sort-Object -Property cpu_seconds -Descending)
    $top = New-Object System.Collections.Generic.List[object]
    $rank = 1
    foreach ($entry in $sortedThreads) {
        if ($rank -gt $TopThreads) { break }
        $top.Add([pscustomobject]@{
            rank               = [int]$rank
            tid                = [int]$entry.tid
            cpu_seconds        = [double]$entry.cpu_seconds
            pct_of_process_cpu = [double]$entry.pct_of_process_cpu
            pct_of_one_core    = [double]$entry.pct_of_one_core
        })
        $rank++
    }
    $attributedSeconds = $attributed100ns / 10000000.0
    $coveragePct = 0.0
    if ($totalCpuSeconds -gt 0) { $coveragePct = ($attributedSeconds / $totalCpuSeconds) * 100.0 }
    $threadAttribution = [pscustomobject]@{
        included            = $true
        method              = 'NtQuerySystemInformation(SystemProcessInformation) + GetThreadTimes de secours, deltas par intervalle'
        thread_count_seen   = [int]$threadCountSeen
        attributed_cpu_seconds = [math]::Round($attributedSeconds, 6)
        coverage_pct_of_process_cpu = [math]::Round($coveragePct, 2)
        top                 = $top.ToArray()
    }
    if ($coveragePct -lt 90.0) {
        Add-Warning ('Attribution threads : couverture ' + [math]::Round($coveragePct, 1) + ' % du CPU process (threads crees en cours de mesure ou sortis entre deux lectures).')
    }
}
else {
    $threadAttribution = [pscustomobject]@{
        included = $false
        note     = 'Activer -IncludeThreads pour l attribution CPU par thread.'
    }
}

# Cross-check : comparaison CPU moyenne et WS final.
$crossCheckResult = [pscustomobject]@{ enabled = $false }
if ($null -ne $crossCheckData) {
    $crossCheckResult = [pscustomobject]@{
        enabled         = $true
        method          = $crossCheckData.Method
        detection       = $crossCheckData.Detection
        counter_set     = $crossCheckData.CounterSetName
        instance        = $crossCheckData.InstanceName
        cpu_counter     = $crossCheckData.CpuCounterPath
        ws_counter      = $crossCheckData.WsCounterPath
        errors          = $crossCheckData.Errors.ToArray()
        cpu             = $null
        working_set     = $null
        overall_pass    = $null
    }
    $counterCpuValues = @()
    if ($null -ne $crossCheckData.Cpu) {
        $rawCpu = @($crossCheckData.Cpu)
        if ($rawCpu.Count -gt 2) {
            $counterCpuValues = @($rawCpu | Select-Object -Skip 1)
        }
        else {
            $counterCpuValues = @($rawCpu)
        }
    }
    if ($counterCpuValues.Count -gt 0) {
        $counterCpuStats = Get-NumericStats -Values ([double[]]$counterCpuValues)
        $ourMean = $null
        if ($null -ne $cpuStats.mean) { $ourMean = [double]$cpuStats.mean }
        $counterMean = $counterCpuStats.mean
        $absDiff = $null
        $relDiffPct = $null
        $cpuPass = $false
        if ($null -ne $ourMean -and $null -ne $counterMean) {
            $absDiff = [math]::Abs($ourMean - $counterMean)
            $denominator = [math]::Max([math]::Abs($ourMean), [math]::Abs($counterMean))
            if ($denominator -gt 0.5) { $relDiffPct = ($absDiff / $denominator) * 100.0 }
            else { $relDiffPct = 0.0 }
            $cpuPass = (($relDiffPct -le 3.0) -or ($absDiff -le 0.5))
        }
        $crossCheckResult.cpu = [pscustomobject]@{
            sample_count          = [int]$counterCpuStats.count
            sampler_mean_pct_core = $ourMean
            counter_mean_pct_core = $counterMean
            abs_diff_pct_core     = $absDiff
            rel_diff_pct          = $relDiffPct
            tolerance_pct         = 3.0
            pass                  = $cpuPass
        }
    }
    if ($null -ne $crossCheckData.Ws -and @($crossCheckData.Ws).Count -gt 0) {
        $counterWsValues = @($crossCheckData.Ws)
        $counterWsLast = [double]$counterWsValues[$counterWsValues.Count - 1]
        $ourWsLast = $null
        if ($wsValues.Count -gt 0) { $ourWsLast = $wsValues[$wsValues.Count - 1] }
        $wsAbsDiff = $null
        $wsRelDiffPct = $null
        $wsPass = $false
        if ($null -ne $ourWsLast) {
            $wsAbsDiff = [math]::Abs($ourWsLast - $counterWsLast)
            $wsDenominator = [math]::Max([math]::Abs($ourWsLast), [math]::Abs($counterWsLast))
            if ($wsDenominator -gt 0) { $wsRelDiffPct = ($wsAbsDiff / $wsDenominator) * 100.0 }
            $wsPass = (($wsRelDiffPct -le 3.0) -or ($wsAbsDiff -le 1MB))
        }
        $crossCheckResult.working_set = [pscustomobject]@{
            sampler_last_bytes    = $ourWsLast
            counter_last_bytes    = $counterWsLast
            abs_diff_bytes        = $wsAbsDiff
            rel_diff_pct          = $wsRelDiffPct
            tolerance_pct         = 3.0
            pass                  = $wsPass
        }
    }
    $passes = @()
    if ($null -ne $crossCheckResult.cpu -and $null -ne $crossCheckResult.cpu.pass) { $passes += [bool]$crossCheckResult.cpu.pass }
    if ($null -ne $crossCheckResult.working_set -and $null -ne $crossCheckResult.working_set.pass) { $passes += [bool]$crossCheckResult.working_set.pass }
    if ($passes.Count -gt 0) {
        $crossCheckResult.overall_pass = -not ($passes -contains $false)
    }
}

# Notes de contexte.
[void]$script:Notes.Add('Mesure lecture seule : handles PROCESS_QUERY_* / PROCESS_VM_READ uniquement, aucun impact code injecte, aucune action UI.')
[void]$script:Notes.Add('CPU % d un coeur = delta CPU du processus / delta temps reel * 100 ; peut depasser 100 sur un processus multithread (somme des threads, comme le compteur PerfMon).')
[void]$script:Notes.Add('% machine = % d un coeur / nombre de processeurs logiques (' + $coreCount + ').')
[void]$script:Notes.Add('p50/p95 : percentiles par interpolation lineaire sur les valeurs par intervalle (rang = p/100*(n-1)).')
[void]$script:Notes.Add('io_read_bytes / io_write_bytes du CSV = octets echanges PENDANT l intervalle (delta), pas un cumul ; le JSON donne les totaux et les debits.')
[void]$script:Notes.Add('pagefaults_delta = delta du compteur 32 bits PageFaultCount sur l intervalle (correction de debordement incluse).')
[void]$script:Notes.Add('private_ws_bytes = pages du working set non partagees (QueryWorkingSet) multipliees par la taille de page ; commit_bytes = PROCESS_MEMORY_COUNTERS_EX.PagefileUsage.')
[void]$script:Notes.Add('Surcout mesure = temps CPU de CE processus PowerShell pendant la boucle d echantillonnage seule (hors chargement du helper, hors ecriture des fichiers).')
[void]$script:Notes.Add('Attribution threads : le premier passage d un thread sert de ligne de base ; un thread cree en cours de mesure perd au plus la fraction de CPU de son premier intervalle.')
if ($exitedEarly) { [void]$script:Notes.Add('Le processus cible s est termine pendant la mesure : les statistiques portent sur les echantillons collectes avant sa disparition.') }

$targetObject = [pscustomobject]@{
    pid                        = [int]$ProcessId
    process_name               = $targetName
    exe_path                   = $targetExePath
    start_time_utc             = $null
    process_start_iso          = $null
    uptime_s                   = $null
    sampling_access_rights     = ('0x{0:X}' -f $grantedAccess)
    private_working_set_supported = [bool]$privateWorkingSetSupported
    exited_during_measurement  = [bool]$exitedEarly
}
if ($null -ne $processStartUtc) {
    $targetObject.start_time_utc = $processStartUtc.ToString('o')
    $targetObject.process_start_iso = $processStartUtc.ToString('o')
    $targetObject.uptime_s = [math]::Round(((Get-Date).ToUniversalTime() - $processStartUtc).TotalSeconds, 3)
}
elseif ($null -ne $targetStartUtc) {
    $targetObject.start_time_utc = $targetStartUtc.ToString('o')
    $targetObject.process_start_iso = $targetStartUtc.ToString('o')
    $targetObject.uptime_s = [math]::Round(((Get-Date).ToUniversalTime() - $targetStartUtc).TotalSeconds, 3)
}

$summary = [pscustomobject]@{
    schema               = 'riotswitch.perf.process-sampler/1'
    tool                 = [pscustomobject]@{
        name               = $script:ToolName
        version            = $script:ToolVersion
        script             = 'ProcessSampler.ps1'
        native_helper      = 'ProcessNative.cs'
        powershell_version = $PSVersionTable.PSVersion.ToString()
        os                 = [System.Environment]::OSVersion.VersionString
    }
    label                = $Label
    generated_at_utc     = (Get-Date).ToUniversalTime().ToString('o')
    duration_requested_s = [int]$DurationSeconds
    duration_actual_s    = [math]::Round($durationActual, 3)
    interval_requested_ms = [int]$IntervalMs
    sample_count         = [int]$rows.Count
    sample_period_ms     = [pscustomobject]@{
        mean = $periodStats.mean
        min  = $periodStats.min
        max  = $periodStats.max
    }
    host                 = [pscustomobject]@{
        name        = [string]$env:COMPUTERNAME
        user        = [string]$env:USERNAME
        logical_processors = [int]$coreCount
        os_caption  = ([string]$env:OS)
    }
    target               = $targetObject
    cpu                  = [pscustomobject]@{
        mean_pct_one_core      = $cpuStats.mean
        min_pct_one_core       = $cpuStats.min
        max_pct_one_core       = $cpuStats.max
        p50_pct_one_core       = $cpuStats.p50
        p95_pct_one_core       = $cpuStats.p95
        aggregate_pct_one_core = $aggregatePctCore
        mean_pct_machine       = $(if ($null -ne $cpuStats.mean) { $cpuStats.mean / $coreCount } else { $null })
        max_pct_machine        = $(if ($null -ne $cpuStats.max) { $cpuStats.max / $coreCount } else { $null })
        p50_pct_machine        = $(if ($null -ne $cpuStats.p50) { $cpuStats.p50 / $coreCount } else { $null })
        p95_pct_machine        = $(if ($null -ne $cpuStats.p95) { $cpuStats.p95 / $coreCount } else { $null })
        aggregate_pct_machine  = $aggregatePctMachine
        total_cpu_seconds      = [math]::Round($totalCpuSeconds, 6)
        user_seconds           = [math]::Round($userSeconds, 6)
        kernel_seconds         = [math]::Round($kernelSeconds, 6)
    }
    memory               = [pscustomobject]@{
        working_set_bytes         = [pscustomobject]@{ min = $wsStats.min; median = $wsStats.p50; max = $wsStats.max }
        private_working_set_bytes = [pscustomobject]@{ min = $privateWsStats.min; median = $privateWsStats.p50; max = $privateWsStats.max; available = ($privateWsStats.count -gt 0) }
        commit_bytes              = [pscustomobject]@{ min = $commitStats.min; median = $commitStats.p50; max = $commitStats.max }
        peak_working_set_bytes    = [pscustomobject]@{ max = $peakWsStats.max }
        first_ws_bytes            = $(if ($wsValues.Count -gt 0) { $wsValues[0] } else { $null })
        last_ws_bytes             = $(if ($wsValues.Count -gt 0) { $wsValues[$wsValues.Count - 1] } else { $null })
        ws_change_bytes           = $(if ($wsValues.Count -gt 1) { $wsValues[$wsValues.Count - 1] - $wsValues[0] } else { $null })
    }
    handles              = [pscustomobject]@{ min = $handleStats.min; max = $handleStats.max; first = $(if ($handleValues.Count -gt 0) { $handleValues[0] } else { $null }); last = $(if ($handleValues.Count -gt 0) { $handleValues[$handleValues.Count - 1] } else { $null }) }
    gdi_objects          = [pscustomobject]@{ min = $gdiStats.min; max = $gdiStats.max; available = ($gdiStats.count -gt 0) }
    user_objects         = [pscustomobject]@{ min = $userStats.min; max = $userStats.max; available = ($userStats.count -gt 0) }
    threads              = [pscustomobject]@{ min = $threadStats.min; max = $threadStats.max; first = $(if ($threadValues.Count -gt 0) { $threadValues[0] } else { $null }); last = $(if ($threadValues.Count -gt 0) { $threadValues[$threadValues.Count - 1] } else { $null }) }
    io                   = [pscustomobject]@{
        read_bytes_total   = [long]$ioReadTotal
        write_bytes_total  = [long]$ioWriteTotal
        read_bytes_per_s   = $(if ($durationActual -gt 0) { $ioReadTotal / $durationActual } else { 0 })
        write_bytes_per_s  = $(if ($durationActual -gt 0) { $ioWriteTotal / $durationActual } else { 0 })
        other_bytes_total  = [long]$ioOtherTotal
    }
    page_faults          = [pscustomobject]@{
        total = [long]$faultsTotal
        per_s = $(if ($durationActual -gt 0) { $faultsTotal / $durationActual } else { 0 })
    }
    threads_cpu          = $threadAttribution
    sampler_overhead     = [pscustomobject]@{
        own_cpu_seconds          = $(if ($null -ne $ownCpuSeconds) { [math]::Round($ownCpuSeconds, 6) } else { $null })
        pct_one_core             = $(if ($null -ne $overheadPctCore) { [math]::Round($overheadPctCore, 4) } else { $null })
        pct_machine              = $(if ($null -ne $overheadPctMachine) { [math]::Round($overheadPctMachine, 4) } else { $null })
        avg_ms_cpu_per_sample    = $(if ($null -ne $overheadMsPerSample) { [math]::Round($overheadMsPerSample, 4) } else { $null })
        measurement_window_s     = [math]::Round($durationActual, 3)
        note                     = 'Temps CPU du processus PowerShell hote pendant la boucle uniquement.'
    }
    cross_check          = $crossCheckResult
    csv                  = [pscustomobject]@{ path = $Csv; columns = [int]$columns.Count; delimiter = ',' }
    json                 = [pscustomobject]@{ path = $Json }
    warnings             = $script:Warnings.ToArray()
    notes                = $script:Notes.ToArray()
}

$jsonText = $summary | ConvertTo-Json -Depth 12
[System.IO.File]::WriteAllText($Json, $jsonText + [Environment]::NewLine, $utf8NoBom)

# ---------------------------------------------------------------------------
# 10. Resume lisible
# ---------------------------------------------------------------------------
$summaryLines = New-Object System.Collections.Generic.List[string]
$summaryLines.Add('')
$summaryLines.Add('=== ProcessSampler : ' + $Label + ' (PID ' + $ProcessId + ') ===')
$summaryLines.Add(('Duree mesuree      : {0:N3} s - {1} echantillons (periode moyenne {2:N0} ms)' -f $durationActual, $rows.Count, $(if ($null -ne $periodStats.mean) { $periodStats.mean } else { 0 })))
$cpuLine = 'CPU                : '
if ($null -ne $cpuStats.mean) {
    $cpuLine += ('moyenne {0:N2} % d''un coeur ({1:N3} % machine), min {2:N2}, max {3:N2}, p50 {4:N2}, p95 {5:N2}' -f $cpuStats.mean, ($cpuStats.mean / $coreCount), $cpuStats.min, $cpuStats.max, $cpuStats.p50, $cpuStats.p95)
}
else {
    $cpuLine += 'aucune donnee'
}
$summaryLines.Add($cpuLine)
$summaryLines.Add(('CPU agrege         : {0:N2} % d''un coeur ({1:N3} % machine) - {2:N3} s CPU total' -f $aggregatePctCore, $aggregatePctMachine, $totalCpuSeconds))
$wsLine = 'Memoire            : '
if ($null -ne $wsStats.mean) {
    $wsLine += ('WS median ' + (Format-BytesForDisplay -Bytes ([long]$wsStats.p50)) + ', prive median ')
    if ($null -ne $privateWsStats.p50) { $wsLine += (Format-BytesForDisplay -Bytes ([long]$privateWsStats.p50)) } else { $wsLine += 'n/d' }
    $wsLine += (', commit median ' + (Format-BytesForDisplay -Bytes ([long]$commitStats.p50)) + ', pic WS ' + (Format-BytesForDisplay -Bytes ([long]$peakWsStats.max)))
}
else {
    $wsLine += 'aucune donnee'
}
$summaryLines.Add($wsLine)
$summaryLines.Add(('Handles / GDI / USER : {0} / {1} / {2} (max) ; threads min {3} max {4}' -f $(if ($null -ne $handleStats.max) { [long]$handleStats.max } else { 'n/d' }), $(if ($null -ne $gdiStats.max) { [long]$gdiStats.max } else { 'n/d' }), $(if ($null -ne $userStats.max) { [long]$userStats.max } else { 'n/d' }), $(if ($null -ne $threadStats.min) { [long]$threadStats.min } else { 'n/d' }), $(if ($null -ne $threadStats.max) { [long]$threadStats.max } else { 'n/d' })))
$summaryLines.Add(('E/S                : lecture {0}, ecriture {1} ; defauts de page {2:N0} ({3:N1}/s)' -f (Format-BytesForDisplay -Bytes ([long]$ioReadTotal)), (Format-BytesForDisplay -Bytes ([long]$ioWriteTotal)), $faultsTotal, $(if ($durationActual -gt 0) { $faultsTotal / $durationActual } else { 0 })))
if ($null -ne $overheadPctCore) {
    $summaryLines.Add(('Surcout outil      : {0:N4} % d''un coeur ({1:N5} % machine), {2:N4} ms CPU/echantillon' -f $overheadPctCore, $overheadPctMachine, $overheadMsPerSample))
}
else {
    $summaryLines.Add('Surcout outil      : non mesure (GetProcessTimes sur le processus courant indisponible)')
}
if ($IncludeThreads -and $null -ne $threadAttribution) {
    $threadParts = @()
    foreach ($entry in $threadAttribution.top) {
        $threadParts += ('tid ' + $entry.tid + ' ' + ('{0:N1}' -f $entry.pct_of_process_cpu) + ' %')
    }
    $summaryLines.Add(('Top threads CPU    : ' + ($threadParts -join ' | ')))
}
if ($null -ne $crossCheckResult -and $crossCheckResult.enabled -eq $true) {
    $checkLine = 'Cross-check        : '
    if ($null -ne $crossCheckResult.cpu -and $null -ne $crossCheckResult.cpu.pass) {
        $checkLine += ('CPU ecart {0:N3} pt ({1:N2} %) ' -f $crossCheckResult.cpu.abs_diff_pct_core, $crossCheckResult.cpu.rel_diff_pct)
        $checkLine += $(if ($crossCheckResult.cpu.pass) { 'OK' } else { 'ECHEC' })
    }
    else {
        $checkLine += 'CPU n/d'
    }
    if ($null -ne $crossCheckResult.working_set -and $null -ne $crossCheckResult.working_set.pass) {
        $checkLine += (' ; WS ecart ' + (Format-BytesForDisplay -Bytes ([long][math]::Abs($crossCheckResult.working_set.abs_diff_bytes))) + ' ')
        $checkLine += $(if ($crossCheckResult.working_set.pass) { 'OK' } else { 'ECHEC' })
    }
    if ($null -ne $crossCheckResult.overall_pass) {
        $checkLine += $(if ($crossCheckResult.overall_pass) { ' -> global OK' } else { ' -> a examiner' })
    }
    $summaryLines.Add($checkLine)
}
if ($script:Warnings.Count -gt 0) {
    foreach ($warning in $script:Warnings) { $summaryLines.Add('AVERTISSEMENT      : ' + $warning) }
}
$summaryLines.Add('CSV                : ' + $Csv)
$summaryLines.Add('JSON               : ' + $Json)
$summaryLines.Add('')
foreach ($line in $summaryLines) { Write-Host $line }

if ($EmitJson) {
    Write-Output 'SUMMARY_JSON'
    Write-Output $jsonText
    Write-Output 'SUMMARY_JSON_END'
}

exit 0
