using System.Runtime.InteropServices;
using RiotSwitcher.Core.Settings;

namespace RiotSwitcher.App;

/// <summary>Crée/supprime les raccourcis Windows (démarrage, bureau) sans dépendance externe.</summary>
internal static class ShortcutService
{
    public static string? Apply(AppSettings settings)
    {
        if (settings.BackgroundMode == BackgroundMode.Launcher)
            return RemoveStartupShortcut();

        return settings.Autostart ? CreateStartupShortcut() : RemoveStartupShortcut();
    }

    public static string? CreateStartupShortcut()
    {
        var lnk = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.Startup),
            "RiotSwitch.lnk");

        return CreateShortcut(
            lnk,
            Application.ExecutablePath,
            "--watch",
            "RiotSwitch — veilleur d'arrière-plan");
    }

    public static string? RemoveStartupShortcut()
    {
        try
        {
            var lnk = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.Startup),
                "RiotSwitch.lnk");
            if (File.Exists(lnk)) File.Delete(lnk);
            return null;
        }
        catch (Exception ex)
        {
            return ex.Message;
        }
    }

    public static string? CreateDesktopShortcuts()
    {
        var desktop = Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
        var exe = Application.ExecutablePath;

        var error = CreateShortcut(
            Path.Combine(desktop, "Riot Client (Switch).lnk"),
            exe,
            "--launch-riot --ephemeral",
            "Lance Riot Client avec le sélecteur de compte RiotSwitch");

        return error ?? CreateShortcut(
            Path.Combine(desktop, "RiotSwitch Paramètres.lnk"),
            exe,
            "--settings",
            "Paramètres de RiotSwitch");
    }

    private static string? CreateShortcut(string path, string targetPath, string arguments, string description)
    {
        if (string.IsNullOrWhiteSpace(targetPath) || !File.Exists(targetPath))
            return "Chemin de RiotSwitch introuvable.";

        object? shell = null;
        object? shortcut = null;

        try
        {
            var shellType = Type.GetTypeFromProgID("WScript.Shell");
            if (shellType is null) return "WScript.Shell est indisponible sur ce système.";

            shell = Activator.CreateInstance(shellType);
            if (shell is null) return "Impossible de créer l'objet WScript.Shell.";

            var shellObject = (dynamic)shell;
            shortcut = shellObject.CreateShortcut(path);

            var shortcutObject = (dynamic)shortcut;
            shortcutObject.TargetPath = targetPath;
            shortcutObject.Arguments = arguments;
            shortcutObject.WorkingDirectory = Path.GetDirectoryName(targetPath) ?? AppContext.BaseDirectory;
            shortcutObject.WindowStyle = 7; // réduit : le processus n'a aucune fenêtre en mode veille
            shortcutObject.Description = description;
            shortcutObject.IconLocation = targetPath + ",0";
            shortcutObject.Save();
            return null;
        }
        catch (Exception ex)
        {
            return ex.Message;
        }
        finally
        {
            try
            {
                if (shortcut is not null) Marshal.FinalReleaseComObject(shortcut);
            }
            catch
            {
                // COM déjà libéré.
            }

            try
            {
                if (shell is not null) Marshal.FinalReleaseComObject(shell);
            }
            catch
            {
                // COM déjà libéré.
            }
        }
    }
}
