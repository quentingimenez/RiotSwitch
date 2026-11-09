using System.Diagnostics;
using System.Text;
using RiotSwitcher.Core.Infrastructure;

namespace RiotSwitcher.App.Updates;

/// <summary>
/// Remplacement des fichiers après fermeture du processus courant, via un petit script PowerShell.
/// Le script attend la fin de RiotSwitch, sauvegarde l'installation, copie le staging, puis relance.
/// </summary>
internal static class UpdateApplier
{
    public static bool CanApply(string targetDirectory, out string reason)
    {
        reason = string.Empty;

        if (string.IsNullOrWhiteSpace(targetDirectory))
        {
            reason = "Dossier d'installation introuvable.";
            return false;
        }

        var directory = Path.GetFullPath(targetDirectory)
            .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);

        if (!File.Exists(Path.Combine(directory, "RiotSwitch.exe")))
        {
            reason = "RiotSwitch.exe est introuvable dans ce dossier.";
            return false;
        }

        var buildMarker = Path.DirectorySeparatorChar + "bin" + Path.DirectorySeparatorChar;
        if (directory.Contains(buildMarker, StringComparison.OrdinalIgnoreCase))
        {
            reason = "Cette copie est lancée depuis un dossier de compilation ; l'auto-update est désactivé.";
            return false;
        }

        return true;
    }

    public static bool Launch(
        string targetDirectory,
        string stagingDirectory,
        int waitForProcessId,
        string restartArguments,
        IAppLogger logger)
    {
        ArgumentNullException.ThrowIfNull(logger);

        try
        {
            var target = Path.GetFullPath(targetDirectory)
                .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            var staging = Path.GetFullPath(stagingDirectory)
                .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);

            var scriptPath = Path.Combine(
                Path.GetTempPath(),
                "RiotSwitch-update-" + Guid.NewGuid().ToString("N") + ".ps1");

            File.WriteAllText(
                scriptPath,
                BuildScript(target, staging, waitForProcessId, restartArguments),
                new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));

            var startInfo = new ProcessStartInfo("powershell.exe")
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden,
                Arguments =
                    "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " +
                    Quote(scriptPath)
            };

            using var process = Process.Start(startInfo);
            if (process is null)
            {
                logger.Error("Impossible de lancer le script de mise à jour.", null);
                return false;
            }

            logger.Info("Mise à jour : script de remplacement lancé ; RiotSwitch va redémarrer.");
            return true;
        }
        catch (Exception ex)
        {
            logger.Error("Impossible de préparer le remplacement des fichiers", ex);
            return false;
        }
    }

    private static string BuildScript(
        string targetDirectory,
        string stagingDirectory,
        int waitForProcessId,
        string restartArguments)
    {
        var builder = new StringBuilder();
        builder.AppendLine("$ErrorActionPreference = 'Stop'");
        builder.AppendLine("$log = Join-Path $env:TEMP 'RiotSwitch-update.log'");
        builder.AppendLine("function Write-UpdateLog([string]$message) {");
        builder.AppendLine("  Add-Content -LiteralPath $log -Value (\"[{0}] {1}\" -f (Get-Date -Format o), $message)");
        builder.AppendLine("}");
        builder.AppendLine("$target = " + Ps(targetDirectory));
        builder.AppendLine("$source = " + Ps(stagingDirectory));
        builder.AppendLine("$backup = Join-Path ([IO.Path]::GetTempPath()) (\"RiotSwitch-backup-\" + (Get-Date -Format 'yyyyMMdd-HHmmss'))");
        builder.AppendLine("try {");
        builder.AppendLine("  Write-UpdateLog 'Attente de la fermeture de RiotSwitch.'");
        builder.AppendLine("  Wait-Process -Id " + waitForProcessId + " -Timeout 60 -ErrorAction SilentlyContinue");
        builder.AppendLine("  Start-Sleep -Milliseconds 800");
        builder.AppendLine("  Write-UpdateLog (\"Sauvegarde de \" + $target + \" vers \" + $backup)");
        builder.AppendLine("  Copy-Item -LiteralPath $target -Destination $backup -Recurse -Force");
        builder.AppendLine("  Write-UpdateLog (\"Copie de \" + $source + \" vers \" + $target)");
        builder.AppendLine("  Copy-Item -Path (Join-Path $source '*') -Destination $target -Recurse -Force");
        builder.AppendLine("  Write-UpdateLog 'Mise à jour installée.'");
        builder.AppendLine(
            "  Start-Process -FilePath (Join-Path $target 'RiotSwitch.exe') -ArgumentList " +
            Ps(restartArguments) + " -WorkingDirectory $target");
        builder.AppendLine("  Write-UpdateLog 'RiotSwitch redémarré.'");
        builder.AppendLine("  Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue");
        builder.AppendLine("  Remove-Item -LiteralPath $source -Recurse -Force -ErrorAction SilentlyContinue");
        builder.AppendLine("} catch {");
        builder.AppendLine("  Write-UpdateLog (\"ERREUR: \" + $_.Exception.Message)");
        builder.AppendLine("  try {");
        builder.AppendLine(
            "    Start-Process -FilePath (Join-Path $target 'RiotSwitch.exe') -ArgumentList " +
            Ps(restartArguments) + " -WorkingDirectory $target");
        builder.AppendLine("  } catch {}");
        builder.AppendLine("} finally {");
        builder.AppendLine("  Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue");
        builder.AppendLine("}");
        return builder.ToString();
    }

    private static string Ps(string value) => "'" + value.Replace("'", "''", StringComparison.Ordinal) + "'";

    private static string Quote(string value) => "\"" + value.Replace("\"", "\\\"", StringComparison.Ordinal) + "\"";
}
