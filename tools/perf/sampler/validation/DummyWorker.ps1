# DummyWorker.ps1
# Processus factice de validation pour ProcessSampler.ps1.
#
# Il cree une charge CONTROLEE et mesurable dans SON propre processus :
#   * N threads consommant chacun ~100 % d'un coeur (runspaces .NET in-process) ;
#   * un bloc memoire alloue et touche (working set prive resident) ;
#   * des handles de fichiers ouverts pendant toute la duree ;
#   * un volume d'E/S disque ecrit puis relu (compteurs GetProcessIoCounters) ;
#   * optionnellement une fenetre WinForms invisible (objets USER/GDI).
#
# Aucune interaction avec d'autres processus : ce script ne doit etre utilise que sur
# lui-meme, pour les tests du sampler. Il n'est jamais lance sur RiotSwitch.
#
# Exemple :
#   powershell -NoProfile -STA -File validation\DummyWorker.ps1 -DurationSeconds 90 `
#       -CpuThreads 2 -AllocMb 200 -IoMb 32 -HandleCount 60 -Gui

[CmdletBinding()]
param(
    [ValidateRange(5, 3600)][int]$DurationSeconds = 90,
    [ValidateRange(0, 32)][int]$CpuThreads = 2,
    [ValidateRange(0, 2048)][int]$AllocMb = 200,
    [ValidateRange(0, 2048)][int]$IoMb = 32,
    [ValidateRange(0, 500)][int]$HandleCount = 60,
    [switch]$Gui,
    [string]$MarkerPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$workerPid = $PID
if ([string]::IsNullOrWhiteSpace($MarkerPath)) {
    $MarkerPath = Join-Path $env:TEMP ('dummyworker-ready-' + $workerPid + '.json')
}
$stopFile = Join-Path $env:TEMP ('dummyworker-stop-' + $workerPid + '.flag')
if (Test-Path -LiteralPath $stopFile) { Remove-Item -LiteralPath $stopFile -Force }

$tempRoot = Join-Path $env:TEMP ('dummyworker-' + $workerPid)
if (-not (Test-Path -LiteralPath $tempRoot)) {
    [void](New-Item -ItemType Directory -Path $tempRoot -Force)
}

$runspaceJobs = New-Object System.Collections.Generic.List[object]
$fileStreams = New-Object System.Collections.Generic.List[object]
$tempFiles = New-Object System.Collections.Generic.List[string]
$buffer = $null
$form = $null
$ioLoopStream = $null
$ioLoopChunk = $null
$ioLoopBuffer = $null

Write-Output ('DUMMY_PID=' + $workerPid)
Write-Output ('DUMMY_MARKER=' + $MarkerPath)
Write-Output ('DUMMY_STOP=' + $stopFile)

try {
    # --- 1. Threads brulants (runspaces .NET du meme processus) ---------------
    for ($burner = 1; $burner -le $CpuThreads; $burner++) {
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.ThreadOptions = 'ReuseThread'
        $runspace.Open()

        $powerShell = [powershell]::Create()
        $powerShell.Runspace = $runspace
        [void]$powerShell.AddScript({
            param($StopFlagPath, $Seed)
            $value = [long]$Seed
            while (-not (Test-Path -LiteralPath $StopFlagPath)) {
                # Boucle serree volontaire : consomme pres de 100 % d'un coeur.
                for ($i = 0; $i -lt 100000; $i++) {
                    $value = $value + 1
                    if ($value -gt 1000000000) { $value = 1 }
                }
            }
            return $value
        }).AddArgument($stopFile).AddArgument([long]($burner * 1000))

        $async = $powerShell.BeginInvoke()
        $runspaceJobs.Add([pscustomobject]@{
            PowerShell = $powerShell
            Runspace   = $runspace
            Async      = $async
        })
    }

    # --- 2. Memoire : allocation touchee (working set prive) ------------------
    if ($AllocMb -gt 0) {
        $byteCount = [int64]$AllocMb * 1MB
        $buffer = New-Object byte[] $byteCount
        for ($offset = 0; $offset -lt $buffer.Length; $offset += 4096) {
            $buffer[$offset] = [byte]1
        }
    }

    # --- 3. Handles de fichiers ouverts --------------------------------------
    for ($handle = 1; $handle -le $HandleCount; $handle++) {
        $filePath = Join-Path $tempRoot ('handle-' + $handle + '.tmp')
        $tempFiles.Add($filePath)
        $stream = [System.IO.File]::Open(
            $filePath,
            [System.IO.FileMode]::Create,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::ReadWrite)
        $payload = [System.Text.Encoding]::ASCII.GetBytes('dummy-handle-' + $handle + [Environment]::NewLine)
        $stream.Write($payload, 0, $payload.Length)
        $stream.Flush()
        $fileStreams.Add($stream)
    }

    # --- 4. E/S disque : ecriture puis relecture -----------------------------
    $ioReadBytes = 0L
    $ioWriteBytes = 0L
    if ($IoMb -gt 0) {
        $ioPath = Join-Path $tempRoot 'io.bin'
        $tempFiles.Add($ioPath)
        $chunk = New-Object byte[] (1MB)
        $random = New-Object System.Random(12345)
        $random.NextBytes($chunk)
        $writeStream = [System.IO.File]::Create($ioPath)
        try {
            for ($chunkIndex = 1; $chunkIndex -le $IoMb; $chunkIndex++) {
                $writeStream.Write($chunk, 0, $chunk.Length)
                $ioWriteBytes += $chunk.Length
            }
            $writeStream.Flush()
        }
        finally {
            $writeStream.Dispose()
        }
        $readStream = [System.IO.File]::OpenRead($ioPath)
        try {
            $readBuffer = New-Object byte[] (1MB)
            while (($read = $readStream.Read($readBuffer, 0, $readBuffer.Length)) -gt 0) {
                $ioReadBytes += $read
            }
        }
        finally {
            $readStream.Dispose()
        }

        # Flux persistant : produit des E/S mesurables PENDANT la mesure du sampler
        # (64 Kio ecrits puis relus toutes les 500 ms, soit ~128 Kio/s par sens).
        $ioLoopStream = [System.IO.File]::Open(
            $ioPath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::ReadWrite)
        $ioLoopChunk = New-Object byte[] (64KB)
        $random.NextBytes($ioLoopChunk)
        $ioLoopBuffer = New-Object byte[] (64KB)
        $fileStreams.Add($ioLoopStream)
    }

    # --- 5. Objets USER/GDI (fenetre invisible) ------------------------------
    if ($Gui) {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
        if ($null -ne ('System.Windows.Forms.Form' -as [type])) {
            $form = New-Object System.Windows.Forms.Form
            $form.Text = 'DummyWorker (invisible)'
            $form.ShowInTaskbar = $false
            $form.WindowState = [System.Windows.Forms.FormWindowState]::Minimized
            $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
            $form.Location = New-Object System.Drawing.Point(-32000, -32000)
            $form.Size = New-Object System.Drawing.Size(200, 120)
            for ($labelIndex = 1; $labelIndex -le 3; $labelIndex++) {
                $label = New-Object System.Windows.Forms.Label
                $label.Text = 'dummy ' + $labelIndex
                $label.AutoSize = $true
                [void]$form.Controls.Add($label)
            }
            $form.Show()
            [System.Windows.Forms.Application]::DoEvents()
        }
    }

    # --- 6. Marqueur de disponibilite ---------------------------------------
    $readyAt = (Get-Date).ToUniversalTime()
    $marker = [pscustomobject]@{
        pid             = $workerPid
        ready_at_utc    = $readyAt.ToString('o')
        duration_s      = $DurationSeconds
        cpu_threads     = $CpuThreads
        alloc_mb        = $AllocMb
        handle_count    = $HandleCount
        io_mb           = $IoMb
        io_read_bytes   = $ioReadBytes
        io_write_bytes  = $ioWriteBytes
        gui             = [bool]$Gui
        stop_file       = $stopFile
        temp_root       = $tempRoot
    }
    $markerJson = $marker | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($MarkerPath, $markerJson + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
    Write-Output 'DUMMY_READY'

    # --- 7. Activite legere reguliere (CPU + E/S) jusqu'a la fin ------------
    $deadline = $readyAt.AddSeconds($DurationSeconds)
    $tick = 0
    while ((Get-Date).ToUniversalTime() -lt $deadline) {
        if (Test-Path -LiteralPath $stopFile) { break }
        Start-Sleep -Milliseconds 500
        $tick++
        # E/S periodiques pendant toute la duree (deltas mesurables par le sampler).
        if ($null -ne $ioLoopStream) {
            [void]$ioLoopStream.Seek(0, [System.IO.SeekOrigin]::Begin)
            $ioLoopStream.Write($ioLoopChunk, 0, $ioLoopChunk.Length)
            $ioLoopStream.Flush()
            [void]$ioLoopStream.Seek(0, [System.IO.SeekOrigin]::Begin)
            [void]$ioLoopStream.Read($ioLoopBuffer, 0, $ioLoopBuffer.Length)
        }
    }
}
finally {
    # --- 8. Nettoyage -------------------------------------------------------
    [System.IO.File]::WriteAllText($stopFile, 'stop', (New-Object System.Text.UTF8Encoding($false)))

    foreach ($job in $runspaceJobs) {
        try { [void]$job.PowerShell.EndInvoke($job.Async) } catch { }
        try { $job.PowerShell.Dispose() } catch { }
        try { $job.Runspace.Dispose() } catch { }
    }
    foreach ($stream in $fileStreams) {
        try { $stream.Dispose() } catch { }
    }
    if ($null -ne $form) {
        try { $form.Dispose() } catch { }
    }
    foreach ($filePath in $tempFiles) {
        try { if (Test-Path -LiteralPath $filePath) { Remove-Item -LiteralPath $filePath -Force } } catch { }
    }
    if (Test-Path -LiteralPath $tempRoot) {
        try { Remove-Item -LiteralPath $tempRoot -Recurse -Force } catch { }
    }
    if (Test-Path -LiteralPath $stopFile) {
        try { Remove-Item -LiteralPath $stopFile -Force } catch { }
    }
    if (Test-Path -LiteralPath $MarkerPath) {
        try { Remove-Item -LiteralPath $MarkerPath -Force } catch { }
    }
    $buffer = $null
    Write-Output 'DUMMY_EXIT'
}
