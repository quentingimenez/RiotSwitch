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
/// État d'une fenêtre Riot connue, obtenu sans énumérer toutes les fenêtres.
/// </summary>
public enum RiotWindowState
{
    /// <summary>Aucune fenêtre Riot valide (fenêtre fermée ou ce n'est plus elle).</summary>
    None,

    /// <summary>Fenêtre principale visible et suffisamment exposée : l'overlay peut s'afficher.</summary>
    Visible,

    /// <summary>Fenêtre principale minimisée.</summary>
    Minimized,

    /// <summary>Fenêtre principale visible mais recouverte : l'overlay doit rester masqué.</summary>
    Present,

    /// <summary>Fenêtre présente mais non affichable (cachée, cloaked, hors écran, trop petite).</summary>
    Hidden
}

/// <summary>
/// Résultat d'une énumération unique : les trois candidats utiles au tracker.
/// </summary>
public sealed record RiotWindowScan(
    RiotClientWindowInfo? Visible,
    RiotClientWindowInfo? Minimized,
    RiotClientWindowInfo? Present);

/// <summary>
/// Détecte la fenêtre principale visible du client Riot (Electron), pas le splash ni le service.
/// </summary>
public static class RiotClientWindow
{
    public const string WindowTitle = "Riot Client";
    private const int MinWidth = 1000;
    private const int MinHeight = 700;
    private static readonly int TitleLength = WindowTitle.Length;

    /// <summary>
    /// Énumère les fenêtres de haut niveau une seule fois et retient les trois candidats
    /// (visible, minimisée, présente mais recouverte) en un seul passage. Le tracker
    /// évite ainsi jusqu'à quatre énumérations EnumWindows par vérification.
    /// </summary>
    public static RiotWindowScan Scan()
    {
        RiotClientWindowInfo? visible = null;
        RiotClientWindowInfo? minimized = null;
        RiotClientWindowInfo? present = null;

        try
        {
            NativeMethods.EnumWindows((hwnd, _) =>
            {
                try
                {
                    if (!NativeMethods.IsWindowVisible(hwnd)) return true;
                    if (!HasRiotTitle(hwnd)) return true;

                    NativeMethods.GetWindowThreadProcessId(hwnd, out var pid);
                    if (!IsRiotClientProcess(pid)) return true;
                    if (!NativeMethods.GetWindowRect(hwnd, out var rect)) return true;

                    var exStyle = (uint)NativeMethods.GetWindowLong(hwnd, NativeMethods.GWL_EXSTYLE);
                    var topMost = (exStyle & (uint)NativeMethods.WS_EX_TOPMOST) != 0;

                    // Fenêtre minimisée : candidate à une restauration unique.
                    if (NativeMethods.IsIconic(hwnd))
                    {
                        // Exclut le splash (topmost) ; la fenêtre principale ne l'est pas.
                        if (!topMost && minimized is null)
                        {
                            minimized = new RiotClientWindowInfo(
                                hwnd,
                                (int)pid,
                                WindowTitle,
                                rect.Left,
                                rect.Top,
                                rect.Width,
                                rect.Height,
                                false);
                        }

                        return true;
                    }

                    if (IsWindowCloaked(hwnd)) return true;
                    if (rect.Width < MinWidth || rect.Height < MinHeight) return true;

                    // Le splash est topmost et petit ; la fenêtre principale est ~1536x864.
                    if (topMost && (rect.Width < 1400 || rect.Height < 800)) return true;

                    // Évite les fenêtres hors écran, cachées derrière l'installateur ou
                    // réduites dans la zone de notification sans être réellement visibles.
                    if (!IsWindowSufficientlyOnScreen(hwnd, rect)) return true;

                    var candidate = new RiotClientWindowInfo(
                        hwnd,
                        (int)pid,
                        WindowTitle,
                        rect.Left,
                        rect.Top,
                        rect.Width,
                        rect.Height,
                        topMost);

                    if (IsWindowSufficientlyVisible(hwnd, (int)pid, rect))
                    {
                        if (visible is null ||
                            (long)rect.Width * rect.Height > (long)visible.Width * visible.Height)
                        {
                            visible = candidate;
                        }
                    }
                    else if (present is null ||
                             (long)rect.Width * rect.Height > (long)present.Width * present.Height)
                    {
                        present = candidate;
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
            return new RiotWindowScan(null, null, null);
        }

        return new RiotWindowScan(visible, minimized, present);
    }

    public static RiotClientWindowInfo? Find() => Scan().Visible;

    /// <summary>
    /// Cherche une fenêtre principale Riot Client réduite (minimisée). Elle n'est
    /// volontairement pas retenue par <see cref="Find"/> puisque l'overlay ne doit
    /// apparaître que sur une fenêtre réellement visible. Le tracker s'en sert pour
    /// restaurer une seule fois le client si l'utilisateur vient de le lancer alors
    /// qu'il s'est ouvert réduit.
    /// </summary>
    public static RiotClientWindowInfo? FindMinimized() => Scan().Minimized;

    /// <summary>
    /// Cherche une fenêtre principale Riot Client visible et non minimisée, même
    /// totalement recouverte par une autre application. Le tracker s'en sert pour
    /// remonter le client une seule fois lorsqu'il vient d'être lancé derrière une
    /// autre fenêtre (par exemple un client de messagerie en plein écran).
    /// </summary>
    public static RiotClientWindowInfo? FindPresent() => Scan().Present;

    /// <summary>
    /// Vérifie une fenêtre déjà connue sans énumérer toutes les fenêtres : le cas
    /// courant (fenêtre visible, minimisée ou recouverte de façon stable) coûte
    /// quelques dizaines d'appels Win32 au lieu d'un EnumWindows complet.
    /// </summary>
    public static RiotClientWindowInfo? Inspect(IntPtr hwnd, int processId, out RiotWindowState state)
    {
        state = RiotWindowState.None;

        try
        {
            if (hwnd == IntPtr.Zero || !NativeMethods.IsWindow(hwnd)) return null;
            if (!NativeMethods.IsWindowVisible(hwnd)) return null;
            if (!HasRiotTitle(hwnd)) return null;
            if (!NativeMethods.GetWindowRect(hwnd, out var rect)) return null;

            NativeMethods.GetWindowThreadProcessId(hwnd, out var pid);
            if ((int)pid != processId) return null;

            var exStyle = (uint)NativeMethods.GetWindowLong(hwnd, NativeMethods.GWL_EXSTYLE);
            var topMost = (exStyle & (uint)NativeMethods.WS_EX_TOPMOST) != 0;

            var info = new RiotClientWindowInfo(
                hwnd,
                processId,
                WindowTitle,
                rect.Left,
                rect.Top,
                rect.Width,
                rect.Height,
                topMost);

            if (NativeMethods.IsIconic(hwnd))
            {
                state = RiotWindowState.Minimized;
                return info;
            }

            if (IsWindowCloaked(hwnd) || rect.Width < MinWidth || rect.Height < MinHeight)
            {
                state = RiotWindowState.Hidden;
                return info;
            }

            if (topMost && (rect.Width < 1400 || rect.Height < 800))
            {
                state = RiotWindowState.Hidden;
                return info;
            }

            if (!IsWindowSufficientlyOnScreen(hwnd, rect))
            {
                state = RiotWindowState.Hidden;
                return info;
            }

            state = IsWindowSufficientlyVisible(hwnd, processId, rect)
                ? RiotWindowState.Visible
                : RiotWindowState.Present;

            return info;
        }
        catch
        {
            state = RiotWindowState.None;
            return null;
        }
    }

    private static bool HasRiotTitle(IntPtr hwnd)
    {
        var length = NativeMethods.GetWindowTextLength(hwnd);
        if (length != TitleLength) return false;

        var builder = new StringBuilder(TitleLength + 1);
        NativeMethods.GetWindowText(hwnd, builder, builder.Capacity);
        return string.Equals(builder.ToString(), WindowTitle, StringComparison.Ordinal);
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
