using System.Diagnostics;
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
                    if (!string.Equals(ReadTitle(hwnd), WindowTitle, StringComparison.Ordinal)) return true;

                    NativeMethods.GetWindowThreadProcessId(hwnd, out var pid);
                    if (!IsRiotClientProcess(pid)) return true;
                    if (!NativeMethods.GetWindowRect(hwnd, out var rect)) return true;
                    if (rect.Width < MinWidth || rect.Height < MinHeight) return true;

                    var exStyle = (uint)NativeMethods.GetWindowLong(hwnd, NativeMethods.GWL_EXSTYLE);
                    var topMost = (exStyle & (uint)NativeMethods.WS_EX_TOPMOST) != 0;

                    // Le splash est topmost et petit ; la fenêtre principale est ~1536x864.
                    if (topMost && (rect.Width < 1400 || rect.Height < 800)) return true;

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
