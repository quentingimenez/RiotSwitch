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
                    if (!IsWindowCenterVisible(hwnd, (int)pid, rect)) return true;

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
    /// Vérifie que le centre de la fenêtre Riot est bien visible : le premier élément
    /// sous le point central doit appartenir au processus Riot (la fenêtre n'est pas
    /// entièrement recouverte par l'installateur, une autre application ou le bureau).
    /// </summary>
    private static bool IsWindowCenterVisible(IntPtr hwnd, int processId, NativeMethods.RECT rect)
    {
        try
        {
            var center = new NativeMethods.POINT
            {
                X = rect.Left + rect.Width / 2,
                Y = rect.Top + rect.Height / 2
            };

            var top = NativeMethods.WindowFromPoint(center);
            if (top == IntPtr.Zero) return false;

            NativeMethods.GetWindowThreadProcessId(top, out var topProcessId);

            // Notre propre overlay peut être au-dessus du client : il ne doit pas
            // être interprété comme une fenêtre étrangère qui masque le client.
            if (topProcessId == (uint)Environment.ProcessId) return true;

            return topProcessId == (uint)processId;
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
