using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using RiotSwitcher.Core.Interop;

namespace RiotSwitcher.Core.Riot;

public sealed record RiotClientWindowInfo(
    IntPtr Handle,
    int ProcessId,
    string Title,
    int X,
    int Y,
    int Width,
    int Height,
    bool IsTopMost);

/// <summary>
/// Détecte la fenêtre principale visible du client Riot (Electron), pas le splash ni le service.
/// </summary>
public static class RiotClientWindow
{
    public const string WindowTitle = "Riot Client";
    private const int MinWidth = 1000;
    private const int MinHeight = 700;

    public static RiotClientWindowInfo? Find()
    {
        RiotClientWindowInfo? best = null;

        try
        {
            NativeMethods.EnumWindows((hwnd, _) =>
            {
                try
                {
                    if (!NativeMethods.IsWindowVisible(hwnd)) return true;
                    if (NativeMethods.IsIconic(hwnd)) return true;
                    if (IsWindowCloaked(hwnd)) return true;
                    if (!string.Equals(ReadTitle(hwnd), WindowTitle, StringComparison.Ordinal)) return true;

                    NativeMethods.GetWindowThreadProcessId(hwnd, out var pid);
                    if (!IsRiotClientProcess(pid)) return true;
                    if (!NativeMethods.GetWindowRect(hwnd, out var rect)) return true;
                    if (rect.Width < MinWidth || rect.Height < MinHeight) return true;

                    var exStyle = (uint)NativeMethods.GetWindowLong(hwnd, NativeMethods.GWL_EXSTYLE);
                    var topMost = (exStyle & (uint)NativeMethods.WS_EX_TOPMOST) != 0;

                    // Le splash est topmost et petit ; la fenêtre principale est ~1536x864.
                    if (topMost && (rect.Width < 1400 || rect.Height < 800)) return true;

                    // Évite les fenêtres hors écran, cachées derrière l'installateur ou
                    // réduites dans la zone de notification sans être réellement visibles.
                    if (!IsWindowSufficientlyOnScreen(hwnd, rect)) return true;
                    if (!IsWindowSufficientlyVisible(hwnd, (int)pid, rect)) return true;

                    if (best is null || (long)rect.Width * rect.Height > (long)best.Width * best.Height)
                    {
                        best = new RiotClientWindowInfo(
                            hwnd,
                            (int)pid,
                            WindowTitle,
                            rect.Left,
                            rect.Top,
                            rect.Width,
                            rect.Height,
                            topMost);
                    }
                }
                catch
                {
                    // Fenêtre disparue pendant l'énumération : ignorer.
                }

                return true;
            }, IntPtr.Zero);
        }
        catch
        {
            return null;
        }

        return best;
    }

    /// <summary>
    /// Cherche une fenêtre principale Riot Client réduite (minimisée). Elle n'est
    /// volontairement pas retenue par <see cref="Find"/> puisque l'overlay ne doit
    /// apparaître que sur une fenêtre réellement visible. Le tracker s'en sert pour
    /// restaurer une seule fois le client si l'utilisateur vient de le lancer alors
    /// qu'il s'est ouvert réduit.
    /// </summary>
    public static RiotClientWindowInfo? FindMinimized()
    {
        RiotClientWindowInfo? best = null;

        try
        {
            NativeMethods.EnumWindows((hwnd, _) =>
            {
                try
                {
                    if (!NativeMethods.IsWindowVisible(hwnd)) return true;
                    if (!NativeMethods.IsIconic(hwnd)) return true;
                    if (!string.Equals(ReadTitle(hwnd), WindowTitle, StringComparison.Ordinal)) return true;

                    NativeMethods.GetWindowThreadProcessId(hwnd, out var pid);
                    if (!IsRiotClientProcess(pid)) return true;

                    var exStyle = (uint)NativeMethods.GetWindowLong(hwnd, NativeMethods.GWL_EXSTYLE);
                    var topMost = (exStyle & (uint)NativeMethods.WS_EX_TOPMOST) != 0;

                    // Exclut le splash (topmost) ; la fenêtre principale ne l'est pas.
                    if (topMost) return true;

                    if (!NativeMethods.GetWindowRect(hwnd, out var rect)) return true;

                    best = new RiotClientWindowInfo(
                        hwnd,
                        (int)pid,
                        WindowTitle,
                        rect.Left,
                        rect.Top,
                        rect.Width,
                        rect.Height,
                        false);

                    return false;
                }
                catch
                {
                    // Fenêtre disparue pendant l'énumération : ignorer.
                }

                return true;
            }, IntPtr.Zero);
        }
        catch
        {
            return null;
        }

        return best;
    }

    private static string ReadTitle(IntPtr hwnd)
    {
        var length = NativeMethods.GetWindowTextLength(hwnd);
        if (length <= 0) return string.Empty;
        var builder = new StringBuilder(length + 1);
        NativeMethods.GetWindowText(hwnd, builder, builder.Capacity);
        return builder.ToString();
    }

    /// <summary>
    /// Détecte les fenêtres masquées par le gestionnaire de fenêtres (autre bureau virtuel,
    /// fenêtre « cloaked » par le shell, etc.) alors que IsWindowVisible reste vrai.
    /// </summary>
    private static bool IsWindowCloaked(IntPtr hwnd)
    {
        try
        {
            var hr = NativeMethods.DwmGetWindowAttribute(
                hwnd,
                NativeMethods.DWMWA_CLOAKED,
                out int cloaked,
                sizeof(int));

            return hr == 0 && cloaked != 0;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>
    /// Vérifie qu'une partie suffisante de la fenêtre est réellement dans la zone de travail
    /// d'un écran (pas une fenêtre déplacée hors écran par l'installateur ou une mise à jour).
    /// </summary>
    private static bool IsWindowSufficientlyOnScreen(IntPtr hwnd, NativeMethods.RECT rect)
    {
        try
        {
            var monitor = NativeMethods.MonitorFromWindow(hwnd, NativeMethods.MONITOR_DEFAULTTONEAREST);
            if (monitor == IntPtr.Zero) return false;

            var info = new NativeMethods.MONITORINFO
            {
                cbSize = Marshal.SizeOf<NativeMethods.MONITORINFO>()
            };

            if (!NativeMethods.GetMonitorInfo(monitor, ref info)) return true;

            var left = Math.Max(rect.Left, info.rcWork.Left);
            var top = Math.Max(rect.Top, info.rcWork.Top);
            var right = Math.Min(rect.Right, info.rcWork.Right);
            var bottom = Math.Min(rect.Bottom, info.rcWork.Bottom);

            var visibleWidth = Math.Max(0, right - left);
            var visibleHeight = Math.Max(0, bottom - top);
            var totalArea = (long)rect.Width * rect.Height;
            var visibleArea = (long)visibleWidth * visibleHeight;

            return totalArea > 0 && visibleArea * 4 >= totalArea;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>
    /// Vérifie qu'une partie suffisante de la fenêtre Riot est réellement visible à
    /// l'écran. Un simple test du centre est trop strict : une petite fenêtre posée
    /// au milieu du client faisait disparaître l'overlay alors que le client restait
    /// largement visible. On échantillonne donc une grille de points ; chaque point
    /// est considéré comme visible s'il est couvert par le client Riot lui-même ou
    /// par notre propre overlay (qui suit le client).
    /// </summary>
    private static bool IsWindowSufficientlyVisible(IntPtr hwnd, int processId, NativeMethods.RECT rect)
    {
        try
        {
            // Si le client est au premier plan, il est visible par définition : pas
            // besoin d'échantillonner (et cela évite les faux négatifs quand l'overlay
            // ou le menu Démarrer recouvre une partie de la fenêtre).
            if (NativeMethods.GetForegroundWindow() == hwnd) return true;

            const int columns = 5;
            const int rows = 5;
            var visible = 0;
            var total = 0;

            for (var row = 0; row < rows; row++)
            {
                for (var column = 0; column < columns; column++)
                {
                    var point = new NativeMethods.POINT
                    {
                        X = rect.Left + (int)((column + 0.5) * rect.Width / columns),
                        Y = rect.Top + (int)((row + 0.5) * rect.Height / rows)
                    };

                    var top = NativeMethods.WindowFromPoint(point);
                    if (top == IntPtr.Zero) continue;

                    NativeMethods.GetWindowThreadProcessId(top, out var topProcessId);
                    total++;

                    // Le client Riot lui-même, ou notre overlay (même processus que
                    // l'application qui exécute cette vérification), comptent comme
                    // visibles. Une autre application compte comme masquant le client.
                    if (topProcessId == (uint)processId || topProcessId == (uint)Environment.ProcessId)
                    {
                        visible++;
                    }
                }
            }

            // Au moins 20 % de la grille doit être réellement exposée. En dessous,
            // le client est essentiellement recouvert (installateur, autre fenêtre
            // plein écran, etc.) et l'overlay ne doit pas apparaître.
            return total > 0 && visible * 5 >= total;
        }
        catch
        {
            return false;
        }
    }

    private static bool IsRiotClientProcess(uint pid)
    {
        try
        {
            using var process = Process.GetProcessById((int)pid);
            return string.Equals(process.ProcessName, RiotProcessNames.ClientUi, StringComparison.OrdinalIgnoreCase);
        }
        catch
        {
            return false;
        }
    }
}
