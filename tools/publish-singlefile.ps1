[CmdletBinding()]
param(
    [string]$Configuration = "Release",
    [string]$Runtime = "win-x64",
    [string]$Output = "dist-singlefile"
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw "dotnet introuvable. Installe le SDK .NET 8 : https://dotnet.microsoft.com/download"
}

$root = Split-Path -Parent $PSScriptRoot
$appProject = Join-Path $root "src\RiotSwitcher.App\RiotSwitcher.App.csproj"
$outputPath = Join-Path $root $Output

Write-Host "== RiotSwitch publication autonome =="
Write-Host "Configuration : $Configuration"
Write-Host "Runtime       : $Runtime"
Write-Host "Sortie        : $outputPath"
Write-Host ""

if (Test-Path -LiteralPath $outputPath) {
    Remove-Item -LiteralPath $outputPath -Recurse -Force
}

dotnet publish $appProject `
    -c $Configuration `
    -r $Runtime `
    --self-contained true `
    -p:PublishSingleFile=true `
    -p:EnableCompressionInSingleFile=true `
    -p:IncludeNativeLibrariesForSelfExtract=true `
    -p:DebugType=None `
    -o $outputPath `
    --nologo
if ($LASTEXITCODE -ne 0) { throw "La publication autonome a echoue (code $LASTEXITCODE)." }

$exe = Join-Path $outputPath "RiotSwitch.exe"
if (-not (Test-Path -LiteralPath $exe)) {
    throw "RiotSwitch.exe absent de la publication autonome."
}

$sizeMb = [math]::Round((Get-Item -LiteralPath $exe).Length / 1MB, 1)
Write-Host ""
Write-Host "Executable autonome : $exe ($sizeMb Mo)"
