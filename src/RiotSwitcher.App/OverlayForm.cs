using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.Windows.Forms;
using RiotSwitcher.App.Interop;
using RiotSwitcher.Core.Riot;
using RiotSwitcher.Core.Settings;
using RiotSwitcher.Core.Switching;
using RiotSwitcher.Core.Vault;

namespace RiotSwitcher.App;

/// <summary>
/// Overlay léger attaché à la fenêtre du Riot Client : bouton 40 DIP + panneau de comptes.
/// Fenêtre layered GDI+ (pas de WPF, pas de navigateur embarqué, aucune animation).
/// </summary>
internal sealed class OverlayForm : Form
{
    private const double ButtonSizeDip = 40;
    private const double PanelWidthDip = 380;
    private const int VisibleRows = 5;
    private const float RowHeightDip = 52;
    private const float HeaderHeightDip = 52;
    private const float CurrentHeightDip = 64;
    private const float FooterButtonHeightDip = 32;
    private const float StatusHeightDip = 24;
    private const float PaddingDip = 12;

    private static readonly Color PanelColor = Color.FromArgb(255, 21, 21, 27);
    private static readonly Color PanelBorderColor = Color.FromArgb(255, 46, 46, 56);
    private static readonly Color AccentColor = Color.FromArgb(255, 209, 54, 57);
    private static readonly Color AccentDarkColor = Color.FromArgb(255, 156, 32, 42);
    private static readonly Color TextColor = Color.FromArgb(255, 245, 245, 248);
    private static readonly Color MutedColor = Color.FromArgb(255, 186, 186, 198);
    private static readonly Color HoverColor = Color.FromArgb(255, 30, 30, 38);
    private static readonly Color ButtonColor = Color.FromArgb(255, 32, 32, 41);
    private static readonly Color CurrentRowColor = Color.FromArgb(255, 40, 24, 28);

    private readonly RiotPaths _paths;
    private readonly SessionVault _vault;
    private readonly SwitchService _switchService;
    private readonly SettingsStore _settingsStore;
    private readonly AppSettings _settings;
    private readonly Action _openSettings;
    private readonly System.Windows.Forms.Timer _positionTimer;
    private readonly System.Windows.Forms.Timer _outsideTimer;

    private RiotClientWindowInfo _target;
    private List<AccountRecord> _accounts = new();
    private AccountRecord? _current;
    private OverlayLayoutState _layout = new();
    private bool _expanded;
    private bool _busy;
    private string? _status;
    private int _scroll;
    private int _hoverRow = -1;
    private double _scale = 1;

    private bool _dragging;
    private bool _dragMoved;
    private Point _dragStartCursor;
    private double _dragStartRight;
    private double _dragStartTop;

    public OverlayForm(
        RiotPaths paths,
        SessionVault vault,
        SwitchService switchService,
        SettingsStore settingsStore,
        AppSettings settings,
        Action openSettings,
        RiotClientWindowInfo target)
    {
        _paths = paths;
        _vault = vault;
        _switchService = switchService;
        _settingsStore = settingsStore;
        _settings = settings;
        _openSettings = openSettings;
        _target = target;

        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        TopMost = false;
        AutoScaleMode = AutoScaleMode.None;
        BackColor = Color.Black;
        Text = "RiotSwitch";
        DoubleBuffered = true;
        SetStyle(
            ControlStyles.OptimizedDoubleBuffer |
            ControlStyles.AllPaintingInWmPaint |
            ControlStyles.UserPaint,
            true);

        _positionTimer = new System.Windows.Forms.Timer { Interval = 500 };
        _positionTimer.Tick += (_, _) =>
        {
            if (!IsDisposed && !Disposing) UpdatePosition();
        };

        _outsideTimer = new System.Windows.Forms.Timer { Interval = 120 };
        _outsideTimer.Tick += (_, _) =>
        {
            if (!IsDisposed && !Disposing) CheckOutsideClick();
        };

        Load += (_, _) => UpdateLayered();
    }

    protected override bool ShowWithoutActivation => true;

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= AppNativeMethods.WS_EX_LAYERED |
                          AppNativeMethods.WS_EX_TOOLWINDOW |
                          AppNativeMethods.WS_EX_NOACTIVATE;

            const int wsCaption = 0x00C00000;
            const int wsSysMenu = 0x00080000;
            const int wsThickFrame = 0x00040000;
            const int wsMinimizeBox = 0x00020000;
            const int wsMaximizeBox = 0x00010000;
            cp.Style &= ~(wsCaption | wsSysMenu | wsThickFrame | wsMinimizeBox | wsMaximizeBox);
            return cp;
        }
    }

    public void ShowAttached(RiotClientWindowInfo target)
    {
        if (IsDisposed || Disposing) return;

        _target = target;
        _ = Handle; // crée le handle pour pouvoir définir l'owner et dessiner.
        AppNativeMethods.SetOwner(Handle, target.Handle);

        ReloadData(update: false);

        if (!Visible) Show();
        _positionTimer.Start();
        UpdateLayered();
    }

    public void UpdateTarget(RiotClientWindowInfo target)
    {
        if (IsDisposed || Disposing) return;

        var ownerChanged = target.Handle != _target.Handle;
        _target = target;

        if (IsWindowUnavailable(target))
        {
            Hide();
            return;
        }

        if (ownerChanged && IsHandleCreated)
        {
            AppNativeMethods.SetOwner(Handle, target.Handle);
        }

        if (!Visible) Show();
        UpdateLayered();
    }

    public void RefreshAccounts()
    {
        if (IsDisposed || Disposing) return;
        ReloadData(update: true);
    }

    protected override void OnPaintBackground(PaintEventArgs e)
    {
        // Dessin entièrement délégué à UpdateLayeredWindow.
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        // Idem.
    }

    private void ReloadData(bool update)
    {
        try
        {
            // L'ordre du coffre est l'ordre choisi par l'utilisateur (Paramètres > Comptes).
            _accounts = _vault.ListAccounts().ToList();
        }
        catch
        {
            _accounts = new List<AccountRecord>();
        }

        _current = null;
        try
        {
            if (File.Exists(_paths.LiveSessionFile))
            {
                var live = RiotSessionReader.ReadFile(_paths.LiveSessionFile, waitForStable: false);
                _current = _vault.FindByPuuid(live.Info.Puuid);
            }
        }
        catch
        {
            // Session en cours d'écriture ou absente : pas grave.
        }

        _scroll = Math.Clamp(_scroll, 0, Math.Max(0, _accounts.Count - VisibleRows));

        if (update) UpdateLayered();
    }

    private void UpdatePosition()
    {
        if (IsDisposed || Disposing || _target.Handle == IntPtr.Zero) return;

        if (IsWindowUnavailable(_target))
        {
            Hide();
            return;
        }

        if (!AppNativeMethods.GetWindowRect(_target.Handle, out var rect)) return;
        if (rect.Width < 800 || rect.Height < 600) return;

        var changed = rect.Left != _target.X ||
                      rect.Top != _target.Y ||
                      rect.Width != _target.Width ||
                      rect.Height != _target.Height;

        if (changed)
        {
            _target = _target with
            {
                X = rect.Left,
                Y = rect.Top,
                Width = rect.Width,
                Height = rect.Height
            };
            UpdateLayered();
        }
    }

    private static bool IsWindowUnavailable(RiotClientWindowInfo target) =>
        target.Handle == IntPtr.Zero ||
        !AppNativeMethods.IsWindow(target.Handle) ||
        !AppNativeMethods.IsWindowVisible(target.Handle) ||
        AppNativeMethods.IsIconic(target.Handle);

    private void UpdateLayered()
    {
        if (IsDisposed || Disposing || !IsHandleCreated) return;
        if (_target.Handle == IntPtr.Zero) return;

        if (IsWindowUnavailable(_target))
        {
            Hide();
            return;
        }

        _scale = GetScale();
        ComputeLayout();

        var width = _layout.WindowWidthPx;
        var height = _layout.WindowHeightPx;
        if (width <= 0 || height <= 0) return;

        using var bitmap = new Bitmap(width, height, PixelFormat.Format32bppArgb);
        using (var graphics = Graphics.FromImage(bitmap))
        {
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            graphics.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
            graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
            graphics.Clear(Color.Transparent);
            graphics.ScaleTransform((float)_scale, (float)_scale);
            Draw(graphics);
        }

        ApplyLayeredWindow(bitmap, _layout.WindowRectPx);
    }

    private double GetScale()
    {
        try
        {
            var dpi = AppNativeMethods.GetDpiForWindow(_target.Handle);
            if (dpi == 0) dpi = 96;
            return Math.Clamp(dpi / 96.0, 1.0, 2.5);
        }
        catch
        {
            return 1.0;
        }
    }

    private void ComputeLayout()
    {
        AppNativeMethods.GetWindowRect(_target.Handle, out var client);

        var screen = Screen.FromHandle(_target.Handle);
        var work = screen.WorkingArea;

        if (!_expanded)
        {
            var w = (int)Math.Round(ButtonSizeDip * _scale);
            var h = (int)Math.Round(ButtonSizeDip * _scale);
            int x, y;
            if (_settings.OverlayPinned)
            {
                (x, y) = GetPinnedOrigin(w, h);
            }
            else
            {
                x = (int)Math.Round(client.Right - _settings.OverlayOffsetRightDip * _scale - w);
                y = (int)Math.Round(client.Top + _settings.OverlayOffsetTopDip * _scale);
                x = Clamp(x, work.Left + (int)(8 * _scale), work.Right - w - (int)(8 * _scale));
                y = Clamp(y, work.Top + (int)(8 * _scale), work.Bottom - h - (int)(8 * _scale));
            }

            _layout = new OverlayLayoutState
            {
                Expanded = false,
                WindowRectPx = new Rectangle(x, y, w, h),
                WindowWidthPx = w,
                WindowHeightPx = h,
                ButtonRect = new RectangleF(0, 0, (float)ButtonSizeDip, (float)ButtonSizeDip)
            };
            return;
        }

        var currentHeight = _current is null ? 0 : CurrentHeightDip;
        var rowCount = Math.Min(_accounts.Count, VisibleRows);
        var listHeight = _accounts.Count == 0 ? 68 : Math.Max(rowCount, 1) * RowHeightDip;
        var statusHeight = string.IsNullOrWhiteSpace(_status) ? 0 : StatusHeightDip;
        var baseHeight = HeaderHeightDip + currentHeight + listHeight;
        var statusGap = statusHeight > 0 ? PaddingDip : 0;
        var totalHeight = baseHeight + FooterButtonHeightDip + PaddingDip + statusHeight + statusGap;

        var panelW = (int)Math.Round(PanelWidthDip * _scale);
        var panelH = (int)Math.Round(totalHeight * _scale);

        int px, py;
        if (_settings.OverlayPinned)
        {
            (px, py) = GetPinnedOrigin(panelW, panelH);
        }
        else
        {
            px = (int)Math.Round(client.Right - _settings.OverlayOffsetRightDip * _scale - panelW);
            py = (int)Math.Round(client.Top + _settings.OverlayOffsetTopDip * _scale);

            px = Clamp(px, work.Left + (int)(8 * _scale), work.Right - panelW - (int)(8 * _scale));
            py = Clamp(py, work.Top + (int)(8 * _scale), work.Bottom - panelH - (int)(8 * _scale));
        }

        var listTop = HeaderHeightDip + currentHeight;
        var footerY = baseHeight;
        var statusY = footerY + FooterButtonHeightDip + PaddingDip;

        var rows = new List<RectangleF>();
        for (var i = 0; i < rowCount; i++)
        {
            rows.Add(new RectangleF(
                (float)PaddingDip,
                (float)(listTop + i * RowHeightDip),
                (float)(PanelWidthDip - PaddingDip * 2),
                RowHeightDip - 4));
        }

        const float innerWidth = (float)(PanelWidthDip - PaddingDip * 2);
        const float gap = 6;
        var buttonWidth = (innerWidth - gap * 2) / 3;
        var addRect = new RectangleF((float)PaddingDip, (float)footerY, buttonWidth, FooterButtonHeightDip);
        var settingsRect = new RectangleF((float)PaddingDip + buttonWidth + gap, (float)footerY, buttonWidth, FooterButtonHeightDip);
        var refreshRect = new RectangleF((float)PaddingDip + (buttonWidth + gap) * 2, (float)footerY, buttonWidth, FooterButtonHeightDip);

        _layout = new OverlayLayoutState
        {
            Expanded = true,
            WindowRectPx = new Rectangle(px, py, panelW, panelH),
            WindowWidthPx = panelW,
            WindowHeightPx = panelH,
            PanelWidth = (float)PanelWidthDip,
            PanelHeight = (float)totalHeight,
            HeaderHeight = HeaderHeightDip,
            CurrentHeight = currentHeight,
            ListTop = (float)listTop,
            ListHeight = (float)listHeight,
            FooterY = (float)footerY,
            StatusY = (float)statusY,
            PinRect = new RectangleF((float)PanelWidthDip - 72, 10, 24, 24),
            CloseRect = new RectangleF((float)PanelWidthDip - 38, 10, 24, 24),
            Rows = rows,
            AddRect = addRect,
            SettingsRect = settingsRect,
            RefreshRect = refreshRect
        };
    }

    private static int Clamp(int value, int min, int max)
    {
        if (max < min) return min;
        return Math.Clamp(value, min, max);
    }

    /// <summary>
    /// Origine de l'overlay épinglé : on conserve le bord droit et le haut en
    /// coordonnées écran, pour que le bouton replié et le panneau ouvert restent
    /// alignés. L'overlay ne suit plus les déplacements de la fenêtre Riot.
    /// </summary>
    private (int X, int Y) GetPinnedOrigin(int width, int height)
    {
        var right = _settings.OverlayPinnedRightPx;
        var top = _settings.OverlayPinnedTopPx;
        var screen = Screen.FromPoint(new Point(right - 1, top + 1));
        var work = screen.WorkingArea;

        var x = right - width;
        var y = top;
        x = Clamp(x, work.Left + (int)(8 * _scale), work.Right - width - (int)(8 * _scale));
        y = Clamp(y, work.Top + (int)(8 * _scale), work.Bottom - height - (int)(8 * _scale));
        return (x, y);
    }

    private void ApplyLayeredWindow(Bitmap bitmap, Rectangle screenRect)
    {
        var screenDc = AppNativeMethods.GetDC(IntPtr.Zero);
        var memDc = AppNativeMethods.CreateCompatibleDC(screenDc);
        var hBitmap = bitmap.GetHbitmap(Color.FromArgb(0, 0, 0, 0));
        var old = AppNativeMethods.SelectObject(memDc, hBitmap);

        try
        {
            var ptDst = new AppNativeMethods.POINT { X = screenRect.X, Y = screenRect.Y };
            var size = new AppNativeMethods.SIZE { cx = screenRect.Width, cy = screenRect.Height };
            var ptSrc = new AppNativeMethods.POINT();
            var blend = new AppNativeMethods.BLENDFUNCTION
            {
                BlendOp = AppNativeMethods.AC_SRC_OVER,
                BlendFlags = 0,
                SourceConstantAlpha = 255,
                AlphaFormat = AppNativeMethods.AC_SRC_ALPHA
            };

            AppNativeMethods.UpdateLayeredWindow(
                Handle,
                screenDc,
                ref ptDst,
                ref size,
                memDc,
                ref ptSrc,
                0,
                ref blend,
                AppNativeMethods.ULW_ALPHA);
        }
        finally
        {
            AppNativeMethods.SelectObject(memDc, old);
            AppNativeMethods.DeleteObject(hBitmap);
            AppNativeMethods.DeleteDC(memDc);
            AppNativeMethods.ReleaseDC(IntPtr.Zero, screenDc);
        }
    }

    private void Draw(Graphics g)
    {
        if (!_layout.Expanded)
        {
            DrawButton(g);
            return;
        }

        DrawPanel(g);
    }

    private void DrawButton(Graphics g)
    {
        var rect = new RectangleF(1, 3, 38, 38);
        using (var shadowPath = RoundedRect(new RectangleF(2, 4, 36, 38), 9))
        using (var shadow = new SolidBrush(Color.FromArgb(90, 0, 0, 0)))
            g.FillPath(shadow, shadowPath);

        using var path = RoundedRect(new RectangleF(0, 0, 40, 40), 9);
        using var brush = new LinearGradientBrush(
            new RectangleF(0, 0, 40, 40),
            Color.FromArgb(255, 226, 66, 70),
            AccentDarkColor,
            LinearGradientMode.ForwardDiagonal);
        g.FillPath(brush, path);

        using var pen = new Pen(Color.FromArgb(255, 255, 255, 255), 2.2f)
        {
            StartCap = LineCap.Round,
            EndCap = LineCap.Round
        };

        // Double flèche ⇄ dessinée à la main.
        g.DrawLine(pen, 12f, 16f, 27f, 16f);
        g.DrawLine(pen, 23f, 12f, 27f, 16f);
        g.DrawLine(pen, 23f, 20f, 27f, 16f);

        g.DrawLine(pen, 28f, 24f, 13f, 24f);
        g.DrawLine(pen, 17f, 20f, 13f, 24f);
        g.DrawLine(pen, 17f, 28f, 13f, 24f);
    }

    private void DrawPanel(Graphics g)
    {
        var w = _layout.PanelWidth;
        var h = _layout.PanelHeight;

        using (var shadowPath = RoundedRect(new RectangleF(2, 5, w - 4, h - 4), 11))
        using (var shadow = new SolidBrush(Color.FromArgb(110, 0, 0, 0)))
            g.FillPath(shadow, shadowPath);

        using (var panelPath = RoundedRect(new RectangleF(0, 0, w, h - 2), 9))
        using (var fill = new SolidBrush(PanelColor))
            g.FillPath(fill, panelPath);

        using (var border = new Pen(PanelBorderColor, 1))
        using (var panelPath = RoundedRect(new RectangleF(0.5f, 0.5f, w - 1, h - 3), 9))
            g.DrawPath(border, panelPath);

        DrawHeader(g);
        DrawCurrentAccount(g);
        DrawAccounts(g);
        DrawFooter(g);
        DrawStatus(g);
    }

    private void DrawHeader(Graphics g)
    {
        using var titleFont = new Font("Segoe UI", 13f, FontStyle.Bold);
        using var titleBrush = new SolidBrush(TextColor);
        g.DrawString("Comptes Riot", titleFont, titleBrush, 14, 13);

        DrawPin(g);

        using var closeFont = new Font("Segoe UI", 15f, FontStyle.Regular);
        using var closeBrush = new SolidBrush(MutedColor);
        var close = _layout.CloseRect;
        var format = new StringFormat
        {
            Alignment = StringAlignment.Center,
            LineAlignment = StringAlignment.Center
        };
        g.DrawString("×", closeFont, closeBrush, close, format);
    }

    private void DrawPin(Graphics g)
    {
        var rect = _layout.PinRect;
        var color = _settings.OverlayPinned ? AccentColor : MutedColor;
        var centerX = rect.X + rect.Width / 2;
        var headY = rect.Y + 8;

        // Tête de punaise + pointe, dessinées à la main pour rester lisibles en GDI+.
        using (var headBrush = new SolidBrush(color))
            g.FillEllipse(headBrush, centerX - 3, headY - 3, 6, 6);

        using var pen = new Pen(color, 1.6f)
        {
            StartCap = LineCap.Round,
            EndCap = LineCap.Round
        };
        g.DrawLine(pen, centerX, headY + 3, centerX, headY + 10);
        g.DrawLine(pen, centerX - 4, headY + 12, centerX + 4, headY + 12);
    }

    private void DrawCurrentAccount(Graphics g)
    {
        if (_current is null) return;

        using var labelFont = new Font("Segoe UI", 8.5f, FontStyle.Bold);
        using var labelBrush = new SolidBrush(AccentColor);
        g.DrawString("ACTUEL", labelFont, labelBrush, 16, 51);

        using var nameFont = new Font("Segoe UI", 12f, FontStyle.Bold);
        using var nameBrush = new SolidBrush(TextColor);
        g.DrawString(_current.DisplayName, nameFont, nameBrush, 16, 62);

        if (!string.IsNullOrWhiteSpace(_current.RiotId) &&
            !string.Equals(_current.RiotId, _current.DisplayName, StringComparison.OrdinalIgnoreCase))
        {
            using var idFont = new Font("Segoe UI", 9.5f, FontStyle.Regular);
            using var idBrush = new SolidBrush(MutedColor);
            g.DrawString(_current.RiotId, idFont, idBrush, 16, 83);
        }
    }

    private void DrawAccounts(Graphics g)
    {
        if (_accounts.Count == 0)
        {
            using var emptyFont = new Font("Segoe UI", 9.5f, FontStyle.Regular);
            using var emptyBrush = new SolidBrush(MutedColor);
            var rect = new RectangleF(20, _layout.ListTop + 14, (float)(PanelWidthDip - 40), 46);
            var format = new StringFormat
            {
                Alignment = StringAlignment.Center,
                LineAlignment = StringAlignment.Center
            };
            g.DrawString(
                "Aucun compte enregistré.\nConnecte-toi dans le client Riot, puis clique sur « Ajouter ».",
                emptyFont, emptyBrush, rect, format);
            return;
        }

        for (var i = 0; i < _layout.Rows.Count; i++)
        {
            var accountIndex = _scroll + i;
            if (accountIndex >= _accounts.Count) break;

            var account = _accounts[accountIndex];
            var row = _layout.Rows[i];
            var isCurrent = _current is not null && string.Equals(account.Id, _current.Id, StringComparison.Ordinal);
            var isHover = _hoverRow == accountIndex;

            if (isCurrent || isHover)
            {
                using var rowPath = RoundedRect(row, 6);
                using var rowBrush = new SolidBrush(isCurrent ? CurrentRowColor : HoverColor);
                g.FillPath(rowBrush, rowPath);
            }

            var initial = string.IsNullOrWhiteSpace(account.DisplayName)
                ? "?"
                : account.DisplayName[..1].ToUpperInvariant();

            using (var avatarBrush = new SolidBrush(isCurrent ? AccentColor : ButtonColor))
                g.FillEllipse(avatarBrush, row.X + 8, row.Y + 8, 28, 28);

            using var initialFont = new Font("Segoe UI", 11f, FontStyle.Bold);
            using var initialBrush = new SolidBrush(TextColor);
            var initialRect = new RectangleF(row.X + 8, row.Y + 8, 28, 28);
            var center = new StringFormat
            {
                Alignment = StringAlignment.Center,
                LineAlignment = StringAlignment.Center
            };
            g.DrawString(initial, initialFont, initialBrush, initialRect, center);

            using var nameFont = new Font("Segoe UI", 10.5f, FontStyle.Bold);
            using var nameBrush = new SolidBrush(TextColor);
            g.DrawString(
                account.DisplayName,
                nameFont,
                nameBrush,
                new RectangleF(row.X + 44, row.Y + 8, 220, 18));

            if (!string.IsNullOrWhiteSpace(account.RiotId) &&
                !string.Equals(account.RiotId, account.DisplayName, StringComparison.OrdinalIgnoreCase))
            {
                using var idFont = new Font("Segoe UI", 9.5f, FontStyle.Regular);
                using var idBrush = new SolidBrush(MutedColor);
                g.DrawString(
                    account.RiotId,
                    idFont,
                    idBrush,
                    new RectangleF(row.X + 44, row.Y + 27, 230, 16));
            }

            using var usedFont = new Font("Segoe UI", 9f, FontStyle.Regular);
            using var usedBrush = new SolidBrush(MutedColor);
            var used = account.LastUsedUtc?.ToLocalTime().ToString("dd/MM HH:mm") ?? "—";
            var usedFormat = new StringFormat { Alignment = StringAlignment.Far };
            g.DrawString(used, usedFont, usedBrush, new RectangleF(row.Right - 82, row.Y + 17, 74, 16), usedFormat);
        }
    }

    private void DrawFooter(Graphics g)
    {
        DrawFooterButton(g, _layout.AddRect, "+", "Ajouter");
        DrawFooterButton(g, _layout.SettingsRect, "⚙", "Paramètres");
        DrawFooterButton(g, _layout.RefreshRect, "↻", "Actualiser");
    }

    private void DrawFooterButton(Graphics g, RectangleF rect, string icon, string text)
    {
        using (var path = RoundedRect(rect, 6))
        using (var brush = new SolidBrush(ButtonColor))
            g.FillPath(brush, path);

        using var iconFont = new Font("Segoe UI Symbol", 10.5f, FontStyle.Regular);
        using var iconBrush = new SolidBrush(MutedColor);
        using var textFont = new Font("Segoe UI", 9f, FontStyle.Regular);
        using var textBrush = new SolidBrush(TextColor);

        var iconSize = g.MeasureString(icon, iconFont);
        var textSize = g.MeasureString(text, textFont);
        const float iconGap = 4f;
        var contentWidth = iconSize.Width + iconGap + textSize.Width;
        var startX = rect.X + Math.Max(0f, (rect.Width - contentWidth) / 2f);

        using var format = new StringFormat
        {
            Alignment = StringAlignment.Near,
            LineAlignment = StringAlignment.Center,
            FormatFlags = StringFormatFlags.NoWrap
        };

        g.DrawString(icon, iconFont, iconBrush,
            new RectangleF(startX, rect.Y, iconSize.Width + 1, rect.Height), format);
        g.DrawString(text, textFont, textBrush,
            new RectangleF(startX + iconSize.Width + iconGap, rect.Y, textSize.Width + 1, rect.Height), format);
    }

    private void DrawStatus(Graphics g)
    {
        if (string.IsNullOrWhiteSpace(_status)) return;

        using var font = new Font("Segoe UI", 9f, FontStyle.Regular);
        using var brush = new SolidBrush(_busy ? AccentColor : MutedColor);
        g.DrawString(
            _status,
            font,
            brush,
            new RectangleF(PaddingDip, _layout.StatusY, (float)(PanelWidthDip - PaddingDip * 2), 18));
    }

    private static GraphicsPath RoundedRect(RectangleF rect, float radius)
    {
        var path = new GraphicsPath();
        var diameter = Math.Min(radius * 2, Math.Min(rect.Width, rect.Height));

        path.AddArc(rect.X, rect.Y, diameter, diameter, 180, 90);
        path.AddArc(rect.Right - diameter, rect.Y, diameter, diameter, 270, 90);
        path.AddArc(rect.Right - diameter, rect.Bottom - diameter, diameter, diameter, 0, 90);
        path.AddArc(rect.X, rect.Bottom - diameter, diameter, diameter, 90, 90);
        path.CloseFigure();
        return path;
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        base.OnMouseDown(e);
        if (e.Button != MouseButtons.Left || _busy) return;

        var dip = ToDip(e.Location);

        if (!_layout.Expanded)
        {
            BeginDrag();
            return;
        }

        if (_layout.PinRect.Contains(dip))
        {
            TogglePin();
            return;
        }

        if (_layout.CloseRect.Contains(dip))
        {
            Collapse();
            return;
        }

        for (var i = 0; i < _layout.Rows.Count; i++)
        {
            if (!_layout.Rows[i].Contains(dip)) continue;
            var index = _scroll + i;
            if (index < _accounts.Count) BeginSwitch(_accounts[index]);
            return;
        }

        if (_layout.AddRect.Contains(dip))
        {
            CaptureCurrent();
            return;
        }

        if (_layout.SettingsRect.Contains(dip))
        {
            _openSettings();
            ReloadData(update: true);
            return;
        }

        if (_layout.RefreshRect.Contains(dip))
        {
            ReloadData(update: true);
            return;
        }

        BeginDrag();
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);

        if (_dragging && !_settings.OverlayPinned && (Control.MouseButtons & MouseButtons.Left) != 0)
        {
            var delta = Cursor.Position;
            var dx = delta.X - _dragStartCursor.X;
            var dy = delta.Y - _dragStartCursor.Y;
            if (Math.Abs(dx) > 3 || Math.Abs(dy) > 3) _dragMoved = true;

            _settings.OverlayOffsetRightDip = Math.Clamp(_dragStartRight - dx / _scale, -2000, 2000);
            _settings.OverlayOffsetTopDip = Math.Clamp(_dragStartTop + dy / _scale, -2000, 2000);
            UpdateLayered();
            return;
        }

        if (!_layout.Expanded) return;

        var dip = ToDip(e.Location);
        var hover = -1;
        for (var i = 0; i < _layout.Rows.Count; i++)
        {
            if (!_layout.Rows[i].Contains(dip)) continue;
            var index = _scroll + i;
            if (index < _accounts.Count) hover = index;
            break;
        }

        if (hover != _hoverRow)
        {
            _hoverRow = hover;
            Cursor = hover >= 0 ? Cursors.Hand : Cursors.Default;
            UpdateLayered();
        }
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        base.OnMouseUp(e);
        if (e.Button != MouseButtons.Left) return;

        var wasDragging = _dragging;
        var moved = _dragMoved;
        _dragging = false;
        _dragMoved = false;
        Capture = false;

        if (!wasDragging) return;

        if (!moved)
        {
            if (!_layout.Expanded)
            {
                Expand();
            }
            else
            {
                _settingsStore.Save(_settings);
            }

            return;
        }

        _settingsStore.Save(_settings);
        UpdateLayered();
    }

    protected override void OnMouseWheel(MouseEventArgs e)
    {
        base.OnMouseWheel(e);
        if (!_layout.Expanded) return;

        var max = Math.Max(0, _accounts.Count - VisibleRows);
        if (max == 0) return;

        _scroll = Math.Clamp(_scroll - Math.Sign(e.Delta), 0, max);
        UpdateLayered();
    }

    protected override void OnMouseLeave(EventArgs e)
    {
        base.OnMouseLeave(e);
        if (_dragging) return;

        if (_hoverRow != -1)
        {
            _hoverRow = -1;
            Cursor = Cursors.Default;
            UpdateLayered();
        }
    }

    private void BeginDrag()
    {
        _dragging = true;
        _dragMoved = false;
        _dragStartCursor = Cursor.Position;
        _dragStartRight = _settings.OverlayOffsetRightDip;
        _dragStartTop = _settings.OverlayOffsetTopDip;
        Capture = true;
    }

    /// <summary>
    /// Épingle l'overlay à sa position écran actuelle (il ne suit plus la fenêtre
    /// Riot et ne peut plus être déplacé), ou le libère en conservant sa place.
    /// </summary>
    private void TogglePin()
    {
        if (!_settings.OverlayPinned)
        {
            _settings.OverlayPinned = true;
            _settings.OverlayPinnedRightPx = _layout.WindowRectPx.Right;
            _settings.OverlayPinnedTopPx = _layout.WindowRectPx.Top;
            _status = "Position épinglée.";
        }
        else
        {
            if (AppNativeMethods.GetWindowRect(_target.Handle, out var client))
            {
                _settings.OverlayOffsetRightDip = Math.Clamp(
                    (client.Right - _layout.WindowRectPx.Right) / _scale, -2000, 2000);
                _settings.OverlayOffsetTopDip = Math.Clamp(
                    (_layout.WindowRectPx.Top - client.Top) / _scale, -2000, 2000);
            }

            _settings.OverlayPinned = false;
            _status = "Position libre.";
        }

        _settingsStore.Save(_settings);
        UpdateLayered();
    }

    private void Expand()
    {
        _expanded = true;
        _outsideTimer.Start();
        UpdateLayered();
    }

    private void Collapse()
    {
        _expanded = false;
        _outsideTimer.Stop();
        _hoverRow = -1;
        UpdateLayered();
    }

    private void CheckOutsideClick()
    {
        if (IsDisposed || Disposing || !IsHandleCreated || !_expanded) return;

        if ((AppNativeMethods.GetAsyncKeyState(AppNativeMethods.VK_ESCAPE) & 0x8000) != 0)
        {
            Collapse();
            return;
        }

        if ((AppNativeMethods.GetAsyncKeyState(AppNativeMethods.VK_LBUTTON) & 0x8000) == 0) return;
        if (!AppNativeMethods.GetCursorPos(out var cursor)) return;

        if (!AppNativeMethods.GetWindowRect(Handle, out var rect)) return;
        var within = cursor.X >= rect.Left && cursor.X <= rect.Right &&
                     cursor.Y >= rect.Top && cursor.Y <= rect.Bottom;

        if (!within)
        {
            // Clic hors du panneau : le clic n'est pas capturé, on referme simplement.
            Collapse();
        }
    }

    private void BeginSwitch(AccountRecord account)
    {
        if (_busy) return;

        if (_current is not null && string.Equals(account.Id, _current.Id, StringComparison.Ordinal))
        {
            _status = "Ce compte est déjà actif.";
            UpdateLayered();
            return;
        }

        var guard = new GameGuard().Check();
        if (guard.IsHardBlock)
        {
            _status = guard.Message;
            UpdateLayered();
            return;
        }

        if (guard.NeedsConfirmation)
        {
            var answer = MessageBox.Show(
                this,
                guard.Message,
                "RiotSwitch",
                MessageBoxButtons.YesNo,
                MessageBoxIcon.Warning,
                MessageBoxDefaultButton.Button2);

            if (answer != DialogResult.Yes) return;
        }

        _busy = true;
        _status = $"Changement vers {account.DisplayName}…";
        UpdateLayered();

        var targetId = account.Id;
        _ = Task.Run(() =>
        {
            SwitchResult result;
            try
            {
                result = _switchService.Switch(new SwitchRequest
                {
                    AccountId = targetId,
                    ConfirmClientClose = _ => true,
                    ReportProgress = progress =>
                    {
                        try
                        {
                            if (!IsDisposed && IsHandleCreated)
                            {
                                BeginInvoke(() =>
                                {
                                    if (IsDisposed) return;
                                    _status = progress.Message;
                                    UpdateLayered();
                                });
                            }
                        }
                        catch
                        {
                            // L'overlay peut disparaître avec la fenêtre Riot.
                        }
                    }
                });
            }
            catch (Exception ex)
            {
                result = SwitchResult.Fail(SwitchOutcome.UnknownError, "Erreur inattendue.", error: ex.Message);
            }

            try
            {
                if (!IsDisposed && IsHandleCreated)
                {
                    BeginInvoke(() => OnSwitchFinished(result));
                }
            }
            catch
            {
                // Overlay détruit : le prochain sera recréé par le veilleur.
            }
        });
    }

    private void OnSwitchFinished(SwitchResult result)
    {
        if (IsDisposed) return;

        _busy = false;
        _status = result.Message;

        if (result.IsSuccess)
        {
            ReloadData(update: false);
            if (_layout.Expanded) UpdateLayered();
            return;
        }

        UpdateLayered();

        if (result.Outcome is not SwitchOutcome.AlreadyCurrent)
        {
            MessageBox.Show(
                this,
                result.Message + (string.IsNullOrWhiteSpace(result.Error) ? string.Empty : "\n\n" + result.Error),
                "RiotSwitch",
                MessageBoxButtons.OK,
                MessageBoxIcon.Warning);
        }
    }

    private void CaptureCurrent()
    {
        try
        {
            if (!File.Exists(_paths.LiveSessionFile))
            {
                _status = "Session Riot introuvable.";
                UpdateLayered();
                return;
            }

            var snapshot = RiotSessionReader.ReadFile(_paths.LiveSessionFile, waitForStable: false);
            if (!snapshot.Info.CanSwitch)
            {
                _status = snapshot.Info.UnsupportedReason ?? "Session non exploitable.";
                UpdateLayered();
                return;
            }

            var account = _vault.Capture(snapshot, label: null, includeProfile: _settings.CaptureElectronProfile);
            _status = $"{account.DisplayName} ajouté.";
            ReloadData(update: true);
        }
        catch (Exception ex)
        {
            _status = "Ajout impossible : " + ex.Message;
            UpdateLayered();
        }
    }

    private PointF ToDip(Point point) =>
        new((float)(point.X / _scale), (float)(point.Y / _scale));

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        StopTimers();
        base.OnFormClosing(e);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            StopTimers();
        }

        base.Dispose(disposing);
    }

    private void StopTimers()
    {
        try
        {
            _positionTimer.Stop();
            _outsideTimer.Stop();
            _positionTimer.Dispose();
            _outsideTimer.Dispose();
        }
        catch
        {
            // La fenêtre peut déjà être détruite par son owner Riot.
        }
    }

    private sealed class OverlayLayoutState
    {
        public bool Expanded;
        public Rectangle WindowRectPx;
        public int WindowWidthPx;
        public int WindowHeightPx;
        public float PanelWidth;
        public float PanelHeight;
        public float HeaderHeight;
        public float CurrentHeight;
        public float ListTop;
        public float ListHeight;
        public float FooterY;
        public float StatusY;
        public RectangleF ButtonRect;
        public RectangleF PinRect;
        public RectangleF CloseRect;
        public List<RectangleF> Rows = new();
        public RectangleF AddRect;
        public RectangleF SettingsRect;
        public RectangleF RefreshRect;
    }
}
