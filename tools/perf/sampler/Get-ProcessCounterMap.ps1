# Get-ProcessCounterMap.ps1
# Resolution des compteurs de performance Windows pour un processus, SANS dependre
# de la langue de l'OS. Windows francais expose "\Processus(*)\% temps processeur" ;
# Windows anglais expose "\Process(*)\% Processor Time". On decouvre les noms reels
# par introspection (Get-Counter -ListSet *), on garde le gabarit de chemin renvoye
# par l'OS (il contient deja le prefixe machine et le wildcard d'instance), puis on
# remplace "(*)" par le nom d'instance de performance du PID cible.
#
# Utilise par ProcessSampler.ps1 (-CrossCheck) et par validation/Validate-Sampler.ps1.
# Aucune ecriture, uniquement des lectures de compteurs.

Set-StrictMode -Version Latest

# Extrait la feuille (dernier segment) d'un chemin de compteur :
#   "\\machine\processus(powershell#3)\% temps processeur" -> "% temps processeur"
function Get-CounterLeafName {
    param([Parameter(Mandatory = $true)][string]$Path)

    $parts = $Path -split '\\'
    if ($parts.Count -eq 0) {
        return $Path
    }
    return $parts[$parts.Count - 1].Trim()
}

# Cherche, dans un jeu de compteurs, les chemins CPU / plage de travail / plage de
# travail privee. Renvoie $null si le jeu ne contient pas le trio attendu.
function Find-ProcessCounterSet {
    param(
        [Parameter(Mandatory = $true)]$CounterSet,
        [Parameter(Mandatory = $true)][string]$SetName
    )

    $cpuRegex = '(?i)^%\s*(temps processeur|processor time|processor|prozessorzeit|tiempo de procesador|tempo del processore|czas procesora|processor\s*time)'
    $wsRegex = '(?i)^(plage de travail|working set)$'
    $wsPrivateRegex = '(?i)^(plage de travail - priv|working set - private)'

    $cpuPath = $null
    $wsPath = $null
    $wsPrivatePath = $null

    foreach ($path in @($CounterSet.Paths)) {
        if ([string]::IsNullOrWhiteSpace([string]$path)) {
            continue
        }
        $leaf = Get-CounterLeafName -Path ([string]$path)
        if ($null -eq $cpuPath -and $leaf -match $cpuRegex) {
            $cpuPath = [string]$path
        }
        elseif ($null -eq $wsPath -and $leaf -match $wsRegex) {
            $wsPath = [string]$path
        }
        elseif ($null -eq $wsPrivatePath -and $leaf -match $wsPrivateRegex) {
            $wsPrivatePath = [string]$path
        }
    }

    if ($null -eq $cpuPath -or $null -eq $wsPath) {
        return $null
    }

    return [pscustomobject]@{
        SetName       = $SetName
        CpuPath       = $cpuPath
        WsPath        = $wsPath
        WsPrivatePath = $wsPrivatePath
    }
}

# Detecte les chemins de compteurs du processus, quelle que soit la langue.
# Retourne un objet { SetName, CpuPath, WsPath, WsPrivatePath, Detection } ou $null.
# Les chemins renvoyes contiennent encore "(*)" a la place de l'instance.
function Get-ProcessPerfCounterPaths {
    [CmdletBinding()]
    param()

    $candidates = @()
    $localizedSets = $null
    $detection = 'introuvable'

    try {
        $localizedSets = @(Get-Counter -ListSet * -ErrorAction Stop)
    }
    catch {
        Write-Verbose ("Get-Counter -ListSet * a echoue : " + $_.Exception.Message)
    }

    if ($null -ne $localizedSets -and $localizedSets.Count -gt 0) {
        foreach ($set in $localizedSets) {
            $found = Find-ProcessCounterSet -CounterSet $set -SetName ([string]$set.CounterSetName)
            if ($null -ne $found) {
                $candidates += $found
            }
        }
    }

    # Priorite a un jeu dont le nom ressemble a "Process/Processus" (le jeu "Processeur"
    # est exclu par le fait qu'il ne contient pas de plage de travail par instance).
    $ordered = @()
    foreach ($candidate in $candidates) {
        if ($candidate.SetName -match '(?i)^(process|processus|processo|proceso|prozess|процесс|进程|プロセス)$') {
            $ordered += $candidate
        }
    }
    foreach ($candidate in $candidates) {
        if ($ordered -notcontains $candidate) {
            $ordered += $candidate
        }
    }

    if ($ordered.Count -gt 0) {
        $best = $ordered[0]
        $detection = 'localise'
        return [pscustomobject]@{
            SetName       = $best.SetName
            CpuPath       = $best.CpuPath
            WsPath        = $best.WsPath
            WsPrivatePath = $best.WsPrivatePath
            Detection     = $detection
        }
    }

    # Repli : noms anglais standard. Les chemins seront peut-etre invalides sur un OS
    # localise, mais ils servent de dernier recours et l'appelant doit tolerer l'echec.
    Write-Verbose 'Aucun jeu de compteurs processus detecte : repli sur les noms anglais.'
    return [pscustomobject]@{
        SetName       = 'Process'
        CpuPath       = '\\{0}\Process(*)\% Processor Time' -f $env:COMPUTERNAME
        WsPath        = '\\{0}\Process(*)\Working Set' -f $env:COMPUTERNAME
        WsPrivatePath = '\\{0}\Process(*)\Working Set - Private' -f $env:COMPUTERNAME
        Detection     = 'repli-anglais'
    }
}

# Nom d'instance de performance du processus (ex : "powershell#3") pour un PID.
# Win32_PerfFormattedData_PerfProc_Process est accessible via CIM/WMI ; ses noms de
# proprietes ne sont PAS localises (seuls les noms de compteurs Get-Counter le sont).
function Resolve-PerfProcessInstanceName {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][int]$ProcessId)

    $obj = $null
    try {
        $obj = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfProc_Process `
            -Filter ("IDProcess = " + $ProcessId) -ErrorAction Stop | Select-Object -First 1
    }
    catch {
        Write-Verbose ('CIM a echoue : ' + $_.Exception.Message)
        try {
            $obj = Get-WmiObject -Class Win32_PerfFormattedData_PerfProc_Process `
                -Filter ("IDProcess = " + $ProcessId) -ErrorAction Stop | Select-Object -First 1
        }
        catch {
            Write-Verbose ('WMI a echoue : ' + $_.Exception.Message)
            return $null
        }
    }

    if ($null -eq $obj -or [string]::IsNullOrWhiteSpace([string]$obj.Name)) {
        return $null
    }
    return [string]$obj.Name
}

# Remplace le wildcard d'instance "(*)" par "($Instance)" dans un gabarit de chemin.
function New-ProcessCounterPath {
    param(
        [Parameter(Mandatory = $true)][string]$Template,
        [Parameter(Mandatory = $true)][string]$Instance
    )
    return $Template.Replace('(*)', ('(' + $Instance + ')'))
}

# Scriptblock execute dans un job pour collecter simultanement CPU et plage de travail
# via Get-Counter. Retourne { Cpu = double[], Ws = double[], Errors = string[] }.
# Le premier echantillon CPU est jete par l'appelant (les compteurs de type taux
# renvoient 0 au premier echantillon).
function Get-CrossCheckCollectorScript {
    return {
        param(
            [string]$CpuPath,
            [string]$WsPath,
            [int]$SampleCount,
            [int]$SampleInterval
        )
        $errors = New-Object System.Collections.Generic.List[string]
        $cpu = New-Object System.Collections.Generic.List[double]
        $ws = New-Object System.Collections.Generic.List[double]
        try {
            $sets = @(Get-Counter -Counter @($CpuPath, $WsPath) -SampleInterval $SampleInterval -MaxSamples $SampleCount -ErrorAction Stop)
            foreach ($set in $sets) {
                foreach ($sample in @($set.CounterSamples)) {
                    $leaf = ([string]$sample.Path -split '\\')[-1]
                    if ($leaf -match '(?i)^%\s*(temps processeur|processor)') {
                        $cpu.Add([double]$sample.CookedValue)
                    }
                    elseif ($leaf -match '(?i)^(plage de travail|working set)$') {
                        $ws.Add([double]$sample.CookedValue)
                    }
                }
            }
        }
        catch {
            $errors.Add($_.Exception.Message)
        }
        return [pscustomobject]@{
            Cpu    = @($cpu)
            Ws     = @($ws)
            Errors = @($errors)
        }
    }
}
