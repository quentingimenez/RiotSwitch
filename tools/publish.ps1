[CmdletBinding()]
param(
    [string]$Configuration = "Release",
    [string]$Runtime = "win-x64",
    [string]$Output = "dist"
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw "dotnet introuvable. Installe le SDK .NET 8 : https://dotnet.microsoft.com/download"
}

$root = Split-Path -Parent $PSScriptRoot
$appProject = Join-Path $root "src\RiotSwitcher.App\RiotSwitcher.App.csproj"
$cliProject = Join-Path $root "src\RiotSwitcher.Cli\RiotSwitcher.Cli.csproj"
$outputPath = Join-Path $root $Output
$cliOutputPath = Join-Path $outputPath "cli"

Write-Host "== RiotSwitch publication =="
Write-Host "Configuration : $Configuration"
Write-Host "Runtime       : $Runtime"
Write-Host "Sortie        : $outputPath"
Write-Host ""

New-Item -ItemType Directory -Force -Path $outputPath | Out-Null

Write-Host "[1/3] Publication de l'application..."
dotnet publish $appProject -c $Configuration -r $Runtime --self-contained false -o $outputPath --nologo
if ($LASTEXITCODE -ne 0) { throw "La publication de l'application a echoue (code $LASTEXITCODE)." }

Write-Host "[2/3] Publication du CLI de diagnostic..."
dotnet publish $cliProject -c $Configuration -r $Runtime --self-contained false -o $cliOutputPath --nologo
if ($LASTEXITCODE -ne 0) { throw "La publication du CLI a echoue (code $LASTEXITCODE)." }

Write-Host "[3/3] Copie de la documentation..."
Copy-Item -LiteralPath (Join-Path $root "README.md") -Destination $outputPath -Force
$docsSource = Join-Path $root "docs"
if (Test-Path -LiteralPath $docsSource) {
    Copy-Item -LiteralPath $docsSource -Destination $outputPath -Recurse -Force
}

Write-Host ""
Write-Host "Termine :"
Write-Host "  $outputPath\RiotSwitch.exe"
Write-Host "  $cliOutputPath\RiotSwitch.Cli.exe"
Write-Host ""
Write-Host "Le binaire est framework-dependent : il necessite le .NET 8 Desktop Runtime."
