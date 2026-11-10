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

    // Géométrie DIP — cf. docs/overlay-ui/spec-overlay.fr.md §3.4 et §4.
    private const float RowHeightDip = 48;
    private const float RowGapDip = 4;
    private const float HeaderHeightDip = 40;
    private const float ConnectedHeightDip = 24;
    private const float ConnectedGapDip = 2;
    private const float DividerGapTopDip = 5;
    private const float DividerGapBottomDip = 9;
    private const float FooterGapDip = 12;
    private const float FooterButtonHeightDip = 36;
    private const float FooterButtonGapDip = 8;
    private const float StatusGapDip = 8;
    private const float StatusLineHeightDip = 16;
    private const float StatusIconSizeDip = 14;
    private const float EmptyListHeightDip = 64;
    private const float PaddingDip = 16;      // marges latérales
    private const float PaddingTopDip = 10;
    private const float PaddingBottomDip = 12;
    private const float ScrollbarWidthDip = 3;
    private const float ScrollbarRightDip = 10;
    private const float HeaderButtonSizeDip = 28;
    private const float HeaderButtonGapDip = 2;
    private const int EdgeMarginDip = 8;

    private static readonly float ContentLeftDip = 1f + PaddingDip;
    private static readonly float ContentRightDip = (float)PanelWidthDip - 1f - PaddingDip;
    private static readonly float ContentWidthDip = ContentRightDip - ContentLeftDip;
    private static readonly float HeaderTopDip = 1f + PaddingTopDip;
    private static readonly float ConnectedTopDip = HeaderTopDip + HeaderHeightDip + ConnectedGapDip;
    private static readonly float DividerYDip = ConnectedTopDip + ConnectedHeightDip + DividerGapTopDip;
    private static readonly float ListTopDip = DividerYDip + 1f + DividerGapBottomDip;
    private static readonly float ScrollbarX = (float)PanelWidthDip - ScrollbarRightDip;
    private static readonly float StatusTextXDip = ContentLeftDip + StatusIconSizeDip + 6f;
    private static readonly float StatusTextWidthDip = ContentRightDip - StatusTextXDip;

    /// <summary>Durée d'affichage des messages de statut informatifs (5 s).</summary>
    private const int StatusInfoRetentionMs = 5000;

    /// <summary>Durée d'affichage des avertissements et erreurs (8 s).</summary>
    private const int StatusWarningRetentionMs = 8000;

    // Palette de la maquette (contrastes WCAG mesurés dans docs/overlay-ui/spec-overlay.fr.md §3.1).
    private static readonly Color PanelColor = Color.FromArgb(255, 23, 23, 30);         // surface-1 #17171E
    private static readonly Color PanelBorderColor = Color.FromArgb(255, 42, 42, 53);    // line-1 #2A2A35
    private static readonly Color AccentColor = Color.FromArgb(255, 226, 59, 65);       // red-500 #E23B41
    private static readonly Color AccentTextColor = Color.FromArgb(255, 255, 156, 156); // red-300 #FF9C9C
    private static readonly Color AccentHoverColor = Color.FromArgb(255, 240, 82, 88);  // red-400 #F05258
    private static readonly Color AccentHoverMidColor = Color.FromArgb(255, 210, 58, 66); // #D23A42
    private static readonly Color AccentHoverDarkColor = Color.FromArgb(255, 176, 42, 50); // #B02A32
    private static readonly Color AccentMidColor = Color.FromArgb(255, 194, 47, 55);    // #C22F37
    private static readonly Color AccentDarkColor = Color.FromArgb(255, 168, 35, 43);   // red-600 #A8232B
    private static readonly Color AccentPressedColor = Color.FromArgb(255, 158, 31, 39); // #9E1F27
    private static readonly Color AccentPressedDarkColor = Color.FromArgb(255, 142, 28, 36); // red-700 #8E1C24
    private static readonly Color TextColor = Color.FromArgb(255, 242, 242, 247);       // text-1 #F2F2F7
    private static readonly Color TextSecondaryColor = Color.FromArgb(255, 196, 196, 208); // text-2 #C4C4D0
    private static readonly Color MutedColor = Color.FromArgb(255, 166, 166, 184);      // text-3 #A6A6B8
    private static readonly Color Surface2Color = Color.FromArgb(255, 31, 31, 40);      // surface-2 #1F1F28
    private static readonly Color Surface3Color = Color.FromArgb(255, 38, 38, 49);      // surface-3 #262631
    private static readonly Color Surface4Color = Color.FromArgb(255, 46, 46, 58);      // surface-4 #2E2E3A
    private static readonly Color Line2Color = Color.FromArgb(255, 58, 58, 72);         // line-2 #3A3A48
    private static readonly Color CurrentRowColor = Color.FromArgb(255, 42, 24, 29);    // red-row #2A181D
    private static readonly Color CurrentRowHoverColor = Color.FromArgb(255, 50, 32, 39); // red-row-hover #322027
    private static readonly Color BadgeBackgroundColor = Color.FromArgb(255, 58, 32, 39); // red-badge #3A2027
    private static readonly Color BadgeBorderColor = Color.FromArgb(255, 90, 42, 50);   // red-badge-line #5A2A32
    private static readonly Color SuccessColor = Color.FromArgb(255, 123, 224, 163);    // green-300 #7BE0A3
    private static readonly Color WarningColor = Color.FromArgb(255, 244, 195, 107);    // amber-300 #F4C36B
    private static readonly Color ErrorColor = Color.FromArgb(255, 255, 133, 133);      // error-300 #FF8585
    private static readonly Color ScrollThumbColor = Color.FromArgb(255, 117, 117, 138); // #75758A
    private static readonly Color ScrollTrackColor = Color.FromArgb(255, 42, 42, 53);   // #2A2A35

    private readonly RiotPaths _paths;
    private readonly SessionVault _vault;
    private readonly SwitchService _switchService;
    private readonly SettingsStore _settingsStore;
    private readonly AppSettings _settings;
    private readonly Action _openSettings;
    private readonly System.Windows.Forms.Timer _positionTimer;
    private readonly System.Windows.Forms.Timer _outsideTimer;
    private readonly System.Windows.Forms.Timer _statusTimer;
    private readonly AppNativeMethods.WinEventDelegate _winEventCallback;
    private IntPtr _locationHook;
    private IntPtr _foregroundHook;

    private RiotClientWindowInfo _target;
    private List<AccountRecord> _accounts = new();
    private AccountRecord? _current;
    private OverlayLayoutState _layout = new();
    private bool _expanded;
    private bool _busy;
    private string? _status;
    private StatusKind _statusKind = StatusKind.Info;
    private DateTime _statusExpiresUtc = DateTime.MaxValue;
    private int _scroll;
    private int _hoverRow = -1;
    private int _hoverButton = -1;
    private bool _hoverPin;
    private bool _hoverClose;
    private bool _hoverCollapsed;
    private bool _collapsedPressed;
    private bool _pressedPin;
    private bool _pressedClose;
    private int _pressedFooterButton = -1;
    private int _statusLines;
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
            if (IsDisposed || Disposing) return;

            // Filet de sécurité : le hook de déplacement met l'overlay à jour
            // immédiatement, et l'ordre Z est réaffirmé au cas où une activation
            // du client aurait remis celui-ci au-dessus de l'overlay.
            UpdatePosition();
            EnsureAboveOwner();
        };

        _outsideTimer = new System.Windows.Forms.Timer { Interval = 120 };
        _outsideTimer.Tick += (_, _) =>
        {
            if (!IsDisposed && !Disposing) CheckOutsideClick();
        };

        // Rétention des messages de statut : un seul timer one-shot, redémarré
        // à chaque nouveau message, efface le texte à l'échéance.
        _statusTimer = new System.Windows.Forms.Timer { Interval = StatusInfoRetentionMs };
        _statusTimer.Tick += (_, _) => ExpireStatus();

        // L'overlay suit la fenêtre du client en temps réel : un hook sur les
        // changements de position de la cible évite le délai du timer (500 ms).
        // Le hook sur la fenêtre active permet de réaffirmer l'ordre Z quand le
        // client redevient au premier plan.
        _winEventCallback = OnTargetWinEvent;
        _locationHook = AppNativeMethods.SetWinEventHook(
            AppNativeMethods.EVENT_OBJECT_LOCATIONCHANGE,
            AppNativeMethods.EVENT_OBJECT_LOCATIONCHANGE,
            IntPtr.Zero,
            _winEventCallback,
            0,
            0,
            AppNativeMethods.WINEVENT_OUTOFCONTEXT | AppNativeMethods.WINEVENT_SKIPOWNPROCESS);

        _foregroundHook = AppNativeMethods.SetWinEventHook(
            AppNativeMethods.EVENT_SYSTEM_FOREGROUND,
            AppNativeMethods.EVENT_SYSTEM_FOREGROUND,
            IntPtr.Zero,
            _winEventCallback,
            0,
            0,
            AppNativeMethods.WINEVENT_OUTOFCONTEXT | AppNativeMethods.WINEVENT_SKIPOWNPROCESS);

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
        EnsureAboveOwner();
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
        EnsureAboveOwner();
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

        if (!changed) return;

        _target = _target with
        {
            X = rect.Left,
            Y = rect.Top,
            Width = rect.Width,
            Height = rect.Height
        };

        if (!IsHandleCreated || !Visible)
        {
            UpdateLayered();
            return;
        }

        // Déplacement pur (même taille) : inutile de redessiner le bitmap
        // layered, on déplace simplement la fenêtre. Le hook de déplacement
        // s'appuie sur ce chemin pour suivre le client en temps réel.
        var previousWidth = _layout.WindowWidthPx;
        var previousHeight = _layout.WindowHeightPx;
        ComputeLayout();

        if (_layout.WindowWidthPx == previousWidth && _layout.WindowHeightPx == previousHeight)
        {
            AppNativeMethods.SetWindowPos(
                Handle,
                IntPtr.Zero,
                _layout.WindowRectPx.X,
                _layout.WindowRectPx.Y,
                0,
                0,
                AppNativeMethods.SWP_NOSIZE |
                AppNativeMethods.SWP_NOZORDER |
                AppNativeMethods.SWP_NOACTIVATE |
                AppNativeMethods.SWP_NOOWNERZORDER);
            return;
        }

        UpdateLayered();
    }

    /// <summary>
    /// Réagit aux événements Windows de la fenêtre cible : déplacement (suivi
    /// immédiat, sans attendre le timer de secours) et passage au premier plan
    /// (l'activation peut remettre le client au-dessus de l'overlay).
    /// </summary>
    private void OnTargetWinEvent(
        IntPtr hWinEventHook,
        uint eventType,
        IntPtr hwnd,
        int idObject,
        int idChild,
        uint dwEventThread,
        uint dwmsEventTime)
    {
        if (idObject != 0 || idChild != 0) return;
        if (IsDisposed || Disposing) return;

        try
        {
            if (eventType == AppNativeMethods.EVENT_OBJECT_LOCATIONCHANGE)
            {
                if (hwnd == _target.Handle) UpdatePosition();
                return;
            }

            if (eventType == AppNativeMethods.EVENT_SYSTEM_FOREGROUND &&
                hwnd == _target.Handle &&
                Visible)
            {
                EnsureAboveOwner();
            }
        }
        catch
        {
            // La fenêtre cible peut disparaître pendant le traitement.
        }
    }

    /// <summary>
    /// Garantit que l'overlay est au-dessus de la fenêtre Riot. L'owner seul ne
    /// suffit pas : au moment où le client est activé (ou juste après sa
    /// création), Windows peut afficher la fenêtre possédée derrière lui. On
    /// replace alors l'overlay juste au-dessus de son owner, sans le remonter
    /// au-dessus des autres applications.
    /// </summary>
    private void EnsureAboveOwner()
    {
        if (IsDisposed || Disposing || !IsHandleCreated || !Visible) return;

        var owner = _target.Handle;
        if (owner == IntPtr.Zero || !AppNativeMethods.IsWindow(owner)) return;
        if (!AppNativeMethods.IsWindowVisible(owner)) return;

        var ownerTopMost = (AppNativeMethods.GetWindowLong(owner, AppNativeMethods.GWL_EXSTYLE) &
                            AppNativeMethods.WS_EX_TOPMOST) != 0;
        var selfTopMost = (AppNativeMethods.GetWindowLong(Handle, AppNativeMethods.GWL_EXSTYLE) &
                           AppNativeMethods.WS_EX_TOPMOST) != 0;

        if (ownerTopMost)
        {
            // Splash screen topmost : l'overlay doit l'être aussi pour rester visible.
            if (!selfTopMost)
            {
                AppNativeMethods.SetWindowPos(
                    Handle,
                    AppNativeMethods.HWND_TOPMOST,
                    0, 0, 0, 0,
                    AppNativeMethods.SWP_NOSIZE |
                    AppNativeMethods.SWP_NOMOVE |
                    AppNativeMethods.SWP_NOACTIVATE);
            }

            return;
        }

        if (selfTopMost)
        {
            // Le client n'est plus topmost : revenir dans la bande normale puis se
            // replacer juste au-dessus de lui.
            AppNativeMethods.SetWindowPos(
                Handle,
                AppNativeMethods.HWND_NOTOPMOST,
                0, 0, 0, 0,
                AppNativeMethods.SWP_NOSIZE |
                AppNativeMethods.SWP_NOMOVE |
                AppNativeMethods.SWP_NOACTIVATE);

            InsertDirectlyAboveOwner(owner);
            return;
        }

        if (IsAboveOwner(owner)) return;

        InsertDirectlyAboveOwner(owner);
    }

    private void InsertDirectlyAboveOwner(IntPtr owner)
    {
        var previous = AppNativeMethods.GetWindow(owner, AppNativeMethods.GW_HWNDPREV);
        if (previous != IntPtr.Zero &&
            (AppNativeMethods.GetWindowLong(previous, AppNativeMethods.GWL_EXSTYLE) &
             AppNativeMethods.WS_EX_TOPMOST) != 0)
        {
            // La fenêtre précédente est topmost : se placer en haut de la bande
            // normale plutôt que sous une fenêtre d'une autre bande.
            previous = IntPtr.Zero;
        }

        AppNativeMethods.SetWindowPos(
            Handle,
            previous == IntPtr.Zero ? AppNativeMethods.HWND_TOP : previous,
            0, 0, 0, 0,
            AppNativeMethods.SWP_NOSIZE |
            AppNativeMethods.SWP_NOMOVE |
            AppNativeMethods.SWP_NOACTIVATE |
            AppNativeMethods.SWP_NOOWNERZORDER);
    }

    /// <summary>
    /// Vrai si l'overlay est déjà au-dessus de son owner dans l'ordre Z. On
    /// remonte depuis l'owner : croiser l'overlay avant la bande topmost signifie
    /// qu'il est au-dessus.
    /// </summary>
    private bool IsAboveOwner(IntPtr owner)
    {
        var current = AppNativeMethods.GetWindow(owner, AppNativeMethods.GW_HWNDPREV);
        for (var guard = 0; current != IntPtr.Zero && guard < 256; guard++)
        {
            if (current == Handle) return true;

            var exStyle = AppNativeMethods.GetWindowLong(current, AppNativeMethods.GWL_EXSTYLE);
            if ((exStyle & AppNativeMethods.WS_EX_TOPMOST) != 0) return false;

            current = AppNativeMethods.GetWindow(current, AppNativeMethods.GW_HWNDPREV);
        }

        return false;
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

        using var bitmap = RenderBitmap(width, height, TextHint);
        ApplyLayeredWindow(bitmap, _layout.WindowRectPx);
    }

    /// <summary>
    /// Rendu du texte. <see cref="TextRenderingHint.AntiAliasGridFit"/> (l'ancien
    /// rendu) laisse GDI+ dessiner des glyphes non accrochés à la grille : à
    /// 100 %, le texte du panneau paraît flou à côté de celui du Riot Client.
    /// ClearTypeGridFit accroche les glyphes aux sous-pixels : le texte redevient
    /// net, comme le reste du client (vérifié par capture écran 1:1).
    /// </summary>
    private const TextRenderingHint TextHint = TextRenderingHint.ClearTypeGridFit;

    /// <summary>Rendu hors écran du panneau complet dans son état courant.</summary>
    private Bitmap RenderBitmap(int width, int height, TextRenderingHint hint)
    {
        var bitmap = new Bitmap(width, height, PixelFormat.Format32bppArgb);
        using var graphics = Graphics.FromImage(bitmap);
        graphics.SmoothingMode = SmoothingMode.AntiAlias;
        graphics.TextRenderingHint = hint;
        graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
        graphics.Clear(Color.Transparent);
        graphics.ScaleTransform((float)_scale, (float)_scale);
        Draw(graphics);
        return bitmap;
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
        var margin = EdgeMarginPx();

        if (!_expanded)
        {
            var w = (int)Math.Round(ButtonSizeDip * _scale);
            var h = (int)Math.Round(ButtonSizeDip * _scale);
            var x = (int)Math.Round(client.Right - _settings.OverlayOffsetRightDip * _scale - w);
            var y = (int)Math.Round(client.Top + _settings.OverlayOffsetTopDip * _scale);
            x = Clamp(x, client.Left + margin, client.Right - w - margin);
            y = Clamp(y, client.Top + margin, client.Bottom - h - margin);

            _layout = new OverlayLayoutState
            {
                Expanded = false,
                WindowRectPx = new Rectangle(x, y, w, h),
                WindowWidthPx = w,
                WindowHeightPx = h
            };
            return;
        }

        var rowCount = Math.Min(_accounts.Count, VisibleRows);
        var listHeight = _accounts.Count == 0
            ? EmptyListHeightDip
            : rowCount * RowHeightDip + Math.Max(0, rowCount - 1) * RowGapDip;

        var statusBlock = _status is null ? 0f : StatusGapDip + _statusLines * StatusLineHeightDip;
        var footerY = ListTopDip + listHeight + FooterGapDip;
        var statusY = footerY + FooterButtonHeightDip + StatusGapDip;
        var totalHeight = footerY + FooterButtonHeightDip + statusBlock + PaddingBottomDip + 1f;

        var panelW = (int)Math.Round(PanelWidthDip * _scale);
        var panelH = (int)Math.Round(totalHeight * _scale);

        var px = (int)Math.Round(client.Right - _settings.OverlayOffsetRightDip * _scale - panelW);
        var py = (int)Math.Round(client.Top + _settings.OverlayOffsetTopDip * _scale);

        px = Clamp(px, client.Left + margin, client.Right - panelW - margin);
        py = Clamp(py, client.Top + margin, client.Bottom - panelH - margin);

        var rows = new List<RectangleF>();
        for (var i = 0; i < rowCount; i++)
        {
            rows.Add(new RectangleF(
                ContentLeftDip,
                ListTopDip + i * (RowHeightDip + RowGapDip),
                ContentWidthDip,
                RowHeightDip));
        }

        var buttonWidth = (ContentWidthDip - FooterButtonGapDip * 2) / 3;
        var addRect = new RectangleF(ContentLeftDip, footerY, buttonWidth, FooterButtonHeightDip);
        var settingsRect = new RectangleF(
            ContentLeftDip + buttonWidth + FooterButtonGapDip,
            footerY,
            buttonWidth,
            FooterButtonHeightDip);
        var refreshRect = new RectangleF(
            ContentLeftDip + (buttonWidth + FooterButtonGapDip) * 2,
            footerY,
            buttonWidth,
            FooterButtonHeightDip);

        var scrollTrack = RectangleF.Empty;
        var scrollThumb = RectangleF.Empty;
        if (_accounts.Count > VisibleRows)
        {
            var thumbHeight = Math.Max(24f, listHeight * VisibleRows / _accounts.Count);
            var travel = Math.Max(0f, listHeight - thumbHeight);
            var maxScroll = _accounts.Count - VisibleRows;
            var thumbY = ListTopDip + (maxScroll > 0 ? travel * _scroll / maxScroll : 0f);
            scrollTrack = new RectangleF(ScrollbarX, ListTopDip, ScrollbarWidthDip, listHeight);
            scrollThumb = new RectangleF(ScrollbarX, thumbY, ScrollbarWidthDip, thumbHeight);
        }

        var headerButtonsY = HeaderTopDip + (HeaderHeightDip - HeaderButtonSizeDip) / 2;
        var closeX = ContentRightDip - HeaderButtonSizeDip;
        var pinX = closeX - HeaderButtonSizeDip - HeaderButtonGapDip;

        _layout = new OverlayLayoutState
        {
            Expanded = true,
            WindowRectPx = new Rectangle(px, py, panelW, panelH),
            WindowWidthPx = panelW,
            WindowHeightPx = panelH,
            PanelWidth = (float)PanelWidthDip,
            PanelHeight = totalHeight,
            ListTop = ListTopDip,
            FooterY = footerY,
            StatusY = statusY,
            PinRect = new RectangleF(pinX, headerButtonsY, HeaderButtonSizeDip, HeaderButtonSizeDip),
            CloseRect = new RectangleF(closeX, headerButtonsY, HeaderButtonSizeDip, HeaderButtonSizeDip),
            Rows = rows,
            AddRect = addRect,
            SettingsRect = settingsRect,
            RefreshRect = refreshRect,
            ScrollTrackRect = scrollTrack,
            ScrollThumbRect = scrollThumb
        };
    }

    private static int Clamp(int value, int min, int max)
    {
        if (max < min) return min;
        return Math.Clamp(value, min, max);
    }

    private int EdgeMarginPx() => (int)Math.Round(EdgeMarginDip * _scale);

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
        var rect = new RectangleF(0, 0, 40, 40);
        var (shadowX, shadowY, shadowAlpha) = _collapsedPressed
            ? (1f, 2f, 90)
            : _hoverCollapsed
                ? (3f, 5f, 105)
                : (2f, 4f, 90);
        using (var shadowPath = RoundedRect(new RectangleF(shadowX, shadowY, 36, 36), 10))
        using (var shadow = new SolidBrush(Color.FromArgb(shadowAlpha, 0, 0, 0)))
            g.FillPath(shadow, shadowPath);

        var (top, mid, bottom) = _collapsedPressed
            ? (AccentMidColor, AccentPressedColor, AccentPressedDarkColor)
            : _hoverCollapsed
                ? (AccentHoverColor, AccentHoverMidColor, AccentHoverDarkColor)
                : (AccentColor, AccentMidColor, AccentDarkColor);

        using var path = RoundedRect(rect, 10);
        using (var brush = new LinearGradientBrush(rect, top, bottom, 160f)
        {
            InterpolationColors = new ColorBlend
            {
                Colors = new[] { top, mid, bottom },
                Positions = new[] { 0f, 0.55f, 1f }
            }
        })
        {
            g.FillPath(brush, path);
        }

        // Liseré supérieur : donne du relief au bouton en GDI+ (pas de flou possible).
        using (var sheen = new Pen(Color.FromArgb(51, 255, 255, 255), 1f))
            g.DrawLine(sheen, 10, 1.2f, 30, 1.2f);

        if (_collapsedPressed)
        {
            // Enfoncement : ombre interne sombre sous le liseré.
            using var inner = new Pen(Color.FromArgb(90, 0, 0, 0), 1f);
            g.DrawLine(inner, 10f, 2.4f, 30f, 2.4f);
        }

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

        // Ombre portée (principe conservé : rectangle arrondi décalé, noir alpha 110).
        using (var shadowPath = RoundedRect(new RectangleF(2, 5, w - 4, h - 4), 11))
        using (var shadow = new SolidBrush(Color.FromArgb(110, 0, 0, 0)))
            g.FillPath(shadow, shadowPath);

        using (var panelPath = RoundedRect(new RectangleF(0, 0, w, h), 12))
        using (var fill = new SolidBrush(PanelColor))
            g.FillPath(fill, panelPath);

        using (var borderPath = RoundedRect(new RectangleF(0.5f, 0.5f, w - 1, h - 1), 12))
        using (var border = new Pen(PanelBorderColor, 1))
            g.DrawPath(border, borderPath);

        DrawHeader(g);
        DrawConnected(g);
        DrawDivider(g);
        DrawAccounts(g);
        DrawFooter(g);
        DrawStatus(g);
    }

    private void DrawDivider(Graphics g)
    {
        using var pen = new Pen(PanelBorderColor, 1);
        var y = DividerYDip + 0.5f;
        g.DrawLine(pen, ContentLeftDip, y, ContentRightDip, y);
    }

    private void DrawHeader(Graphics g)
    {
        using (var titleFont = new Font("Segoe UI", 11.25f, FontStyle.Bold))
        using (var titleBrush = new SolidBrush(TextColor))
        using (var format = new StringFormat
        {
            Alignment = StringAlignment.Near,
            LineAlignment = StringAlignment.Center,
            FormatFlags = StringFormatFlags.NoWrap,
            Trimming = StringTrimming.EllipsisCharacter
        })
        {
            var titleWidth = Math.Max(0f, _layout.PinRect.X - ContentLeftDip - 12f);
            g.DrawString(
                "Comptes Riot",
                titleFont,
                titleBrush,
                new RectangleF(ContentLeftDip, HeaderTopDip, titleWidth, HeaderHeightDip),
                format);
        }

        DrawPinButton(g);
        DrawCloseButton(g);
    }

    private void DrawPinButton(Graphics g)
    {
        var rect = _layout.PinRect;
        var pinned = _settings.OverlayPinned;
        var pressed = _pressedPin;

        if (pinned || pressed || _hoverPin)
        {
            var fillColor = pinned
                ? BadgeBackgroundColor
                : pressed ? Surface3Color : Surface2Color;
            using var path = RoundedRect(rect, 6);
            using var fill = new SolidBrush(fillColor);
            g.FillPath(fill, path);
        }

        var color = pinned
            ? AccentTextColor
            : pressed || _hoverPin ? TextColor : MutedColor;

        DrawGlyph(g, pinned ? IconGlyph.PinFilled : IconGlyph.Pin,
            CenteredBox(rect, 14f), color, 1.6f);
    }

    private void DrawCloseButton(Graphics g)
    {
        var rect = _layout.CloseRect;
        if (_pressedClose || _hoverClose)
        {
            var fillColor = _pressedClose ? Surface3Color : Surface2Color;
            using var path = RoundedRect(rect, 6);
            using var fill = new SolidBrush(fillColor);
            g.FillPath(fill, path);
        }

        DrawGlyph(g, IconGlyph.Close, CenteredBox(rect, 12f),
            _pressedClose || _hoverClose ? TextColor : MutedColor, 1.6f);
    }

    private static RectangleF CenteredBox(RectangleF rect, float size) =>
        new(rect.X + (rect.Width - size) / 2f, rect.Y + (rect.Height - size) / 2f, size, size);

    private void DrawConnected(Graphics g)
    {
        using var labelFont = new Font("Segoe UI", 8.25f, FontStyle.Bold);
        using var whoFont = new Font("Segoe UI", 9f, FontStyle.Bold);
        using var format = new StringFormat
        {
            Alignment = StringAlignment.Near,
            LineAlignment = StringAlignment.Center,
            FormatFlags = StringFormatFlags.NoWrap,
            Trimming = StringTrimming.EllipsisCharacter
        };

        // Coche 13 px quand un compte est connecté ; icône info 14 px sinon.
        var iconSize = _current is null ? StatusIconSizeDip : 13f;
        var iconBox = new RectangleF(
            ContentLeftDip,
            ConnectedTopDip + (ConnectedHeightDip - iconSize) / 2f,
            iconSize,
            iconSize);

        if (_current is null)
        {
            DrawGlyph(g, IconGlyph.Info, iconBox, MutedColor, 1.5f);

            using var offlineBrush = new SolidBrush(TextSecondaryColor);
            g.DrawString(
                "Client Riot non détecté",
                whoFont,
                offlineBrush,
                new RectangleF(
                    ContentLeftDip + iconSize + 6f,
                    ConnectedTopDip,
                    ContentWidthDip - iconSize - 6f,
                    ConnectedHeightDip),
                format);
            return;
        }

        DrawGlyph(g, IconGlyph.Check, iconBox, SuccessColor, 1.7f);

        var x = ContentLeftDip + iconSize + 6f;

        using var labelBrush = new SolidBrush(SuccessColor);
        var label = "Connecté";
        var labelWidth = g.MeasureString(label, labelFont, int.MaxValue, StringFormat.GenericTypographic).Width;
        g.DrawString(
            label,
            labelFont,
            labelBrush,
            new RectangleF(x, ConnectedTopDip, labelWidth + 10f, ConnectedHeightDip),
            format);
        x += labelWidth + 6f;

        using var dotFont = new Font("Segoe UI", 9f, FontStyle.Regular);
        using var dotBrush = new SolidBrush(MutedColor);
        var dot = "·";
        var dotWidth = g.MeasureString(dot, dotFont, int.MaxValue, StringFormat.GenericTypographic).Width;
        g.DrawString(
            dot,
            dotFont,
            dotBrush,
            new RectangleF(x, ConnectedTopDip, dotWidth + 2f, ConnectedHeightDip),
            format);
        x += dotWidth + 6f;

        var who = string.IsNullOrWhiteSpace(_current.RiotId) ? _current.DisplayName : _current.RiotId;
        using var whoBrush = new SolidBrush(TextSecondaryColor);
        g.DrawString(
            who,
            whoFont,
            whoBrush,
            new RectangleF(x, ConnectedTopDip, Math.Max(0f, ContentRightDip - x), ConnectedHeightDip),
            format);
    }

    private void DrawAccounts(Graphics g)
    {
        if (_accounts.Count == 0)
        {
            DrawEmptyState(g);
            return;
        }

        using var nameFont = new Font("Segoe UI", 10.5f, FontStyle.Bold);
        using var idFont = new Font("Segoe UI", 9f, FontStyle.Regular);
        using var dateFont = new Font("Segoe UI", 9f, FontStyle.Regular);
        using var badgeFont = new Font("Segoe UI", 7.875f, FontStyle.Bold);
        using var nameBrush = new SolidBrush(TextColor);
        using var mutedBrush = new SolidBrush(MutedColor);
        using var badgeTextBrush = new SolidBrush(AccentTextColor);
        // Mesure et rendu typographiques (même moteur, pas de marge interne) : le
        // badge peut ainsi être placé exactement à 8 px du nom sans troncature.
        using var nameFormat = new StringFormat(StringFormat.GenericTypographic)
        {
            Alignment = StringAlignment.Near,
            LineAlignment = StringAlignment.Center,
            FormatFlags = StringFormatFlags.NoWrap,
            Trimming = StringTrimming.EllipsisCharacter
        };
        using var dateFormat = new StringFormat
        {
            Alignment = StringAlignment.Far,
            LineAlignment = StringAlignment.Center,
            FormatFlags = StringFormatFlags.NoWrap
        };

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
                var fill = isCurrent
                    ? (isHover ? CurrentRowHoverColor : CurrentRowColor)
                    : Surface2Color;
                using var rowPath = RoundedRect(row, 8);
                using var rowBrush = new SolidBrush(fill);
                g.FillPath(rowBrush, rowPath);
            }

            if (isCurrent)
            {
                using var railPath = RoundedRect(
                    new RectangleF(row.X + 4, row.Y + 9, 3, 30), 2);
                using var railBrush = new SolidBrush(AccentColor);
                g.FillPath(railBrush, railPath);
            }

            const float contentLeftOffset = 14f;
            var contentLeft = row.X + contentLeftOffset;
            var contentWidth = row.Width - 24f;
            var line1Top = row.Y + 6.5f;
            var line2Top = row.Y + 25.5f;

            var nameWidth = g.MeasureString(
                account.DisplayName, nameFont, int.MaxValue, StringFormat.GenericTypographic).Width;
            var badgeWidth = isCurrent ? MeasureBadgeWidth(g, badgeFont) : 0f;
            var nameAvailable = Math.Max(0f, contentWidth - badgeWidth - (isCurrent ? 12f : 0f));
            var nameWidthClamped = Math.Min(nameWidth, nameAvailable);
            // Le rendu anti-aliasé peut dépasser la mesure d'une fraction de pixel :
            // on élargit légèrement le seul rectangle de dessin (le badge reste à
            // 8 px de la largeur mesurée) pour ne jamais tronquer un nom qui tient.
            var nameDrawWidth = nameWidth <= nameAvailable
                ? Math.Min(nameWidth + 6f, contentWidth)
                : nameAvailable;

            g.DrawString(
                account.DisplayName,
                nameFont,
                nameBrush,
                new RectangleF(contentLeft, line1Top, nameDrawWidth, 18),
                nameFormat);

            if (isCurrent)
            {
                DrawCurrentBadge(
                    g,
                    badgeFont,
                    badgeTextBrush,
                    new RectangleF(
                        contentLeft + nameWidthClamped + 8f,
                        row.Y + 7.5f,
                        MeasureBadgeWidth(g, badgeFont),
                        16));
            }

            if (!string.IsNullOrWhiteSpace(account.RiotId) &&
                !string.Equals(account.RiotId, account.DisplayName, StringComparison.OrdinalIgnoreCase))
            {
                g.DrawString(
                    account.RiotId,
                    idFont,
                    mutedBrush,
                    new RectangleF(contentLeft, line2Top, contentWidth - 90f, 16),
                    nameFormat);
            }

            var used = account.LastUsedUtc?.ToLocalTime().ToString("dd/MM HH:mm") ?? "—";
            g.DrawString(
                used,
                dateFont,
                mutedBrush,
                new RectangleF(row.Right - 90f, line2Top, 80f, 16),
                dateFormat);
        }

        if (_layout.ScrollTrackRect.Width > 0)
        {
            using (var trackPath = RoundedRect(_layout.ScrollTrackRect, 2f))
            using (var trackBrush = new SolidBrush(ScrollTrackColor))
                g.FillPath(trackBrush, trackPath);

            using (var thumbPath = RoundedRect(_layout.ScrollThumbRect, 2f))
            using (var thumbBrush = new SolidBrush(ScrollThumbColor))
                g.FillPath(thumbBrush, thumbPath);
        }
    }

    private void DrawEmptyState(Graphics g)
    {
        using var titleFont = new Font("Segoe UI", 9.75f, FontStyle.Bold);
        using var subFont = new Font("Segoe UI", 9f, FontStyle.Regular);
        using var titleBrush = new SolidBrush(TextColor);
        using var subBrush = new SolidBrush(MutedColor);
        using var titleFormat = new StringFormat
        {
            Alignment = StringAlignment.Near,
            LineAlignment = StringAlignment.Near,
            FormatFlags = StringFormatFlags.NoWrap,
            Trimming = StringTrimming.EllipsisCharacter
        };
        using var subFormat = new StringFormat
        {
            Alignment = StringAlignment.Near,
            LineAlignment = StringAlignment.Near,
            Trimming = StringTrimming.EllipsisWord
        };

        var contentTop = _layout.ListTop + (EmptyListHeightDip - 36f) / 2f;
        g.DrawString(
            "Aucun compte enregistré",
            titleFont,
            titleBrush,
            new RectangleF(ContentLeftDip, contentTop, ContentWidthDip, 18),
            titleFormat);

        g.DrawString(
            "Connecte-toi dans le client Riot, puis clique sur « Ajouter ».",
            subFont,
            subBrush,
            new RectangleF(ContentLeftDip, contentTop + 20f, ContentWidthDip, 24),
            subFormat);
    }

    private static float MeasureBadgeWidth(Graphics g, Font badgeFont) =>
        g.MeasureString("Actuel", badgeFont, int.MaxValue, StringFormat.GenericTypographic).Width + 14f;

    private static void DrawCurrentBadge(
        Graphics g,
        Font badgeFont,
        Brush textBrush,
        RectangleF rect)
    {
        using (var path = RoundedRect(rect, 5))
        {
            using (var fill = new SolidBrush(BadgeBackgroundColor))
                g.FillPath(fill, path);

            using (var border = new Pen(BadgeBorderColor, 1))
                g.DrawPath(border, path);
        }

        using var format = new StringFormat
        {
            Alignment = StringAlignment.Center,
            LineAlignment = StringAlignment.Center,
            FormatFlags = StringFormatFlags.NoWrap
        };
        g.DrawString("Actuel", badgeFont, textBrush, rect, format);
    }

    private void DrawFooter(Graphics g)
    {
        DrawFooterButton(g, _layout.AddRect, 0, IconGlyph.Plus, "Ajouter", primary: true);
        DrawFooterButton(g, _layout.SettingsRect, 1, IconGlyph.Sliders, "Paramètres", primary: false);
        DrawFooterButton(g, _layout.RefreshRect, 2, IconGlyph.Refresh, "Actualiser", primary: false);
    }

    private void DrawFooterButton(
        Graphics g,
        RectangleF rect,
        int index,
        IconGlyph glyph,
        string label,
        bool primary)
    {
        var hover = _hoverButton == index;
        var pressed = _pressedFooterButton == index;

        Color fill;
        Color border;
        if (pressed)
        {
            fill = Surface4Color;
            border = Line2Color;
        }
        else if (hover)
        {
            fill = primary ? Surface4Color : Surface3Color;
            border = Line2Color;
        }
        else
        {
            fill = primary ? Surface3Color : Surface2Color;
            border = primary ? Line2Color : PanelBorderColor;
        }

        using (var path = RoundedRect(rect, 8))
        using (var brush = new SolidBrush(fill))
            g.FillPath(brush, path);

        using (var borderPath = RoundedRect(
                   new RectangleF(rect.X + 0.5f, rect.Y + 0.5f, rect.Width - 1, rect.Height - 1), 8))
        using (var pen = new Pen(border, 1))
            g.DrawPath(pen, borderPath);

        using var textFont = new Font("Segoe UI", 9f, FontStyle.Regular);
        using var textBrush = new SolidBrush(TextColor);
        var iconColor = primary ? TextColor : TextSecondaryColor;

        var textWidth = g.MeasureString(label, textFont, int.MaxValue, StringFormat.GenericTypographic).Width;
        const float iconSize = 14f;
        const float iconGap = 6f;
        var contentWidth = iconSize + iconGap + textWidth;
        var startX = rect.X + Math.Max(0f, (rect.Width - contentWidth) / 2f);

        DrawGlyph(
            g,
            glyph,
            new RectangleF(startX, rect.Y + (rect.Height - iconSize) / 2f, iconSize, iconSize),
            iconColor,
            1.6f);

        using var format = new StringFormat
        {
            Alignment = StringAlignment.Near,
            LineAlignment = StringAlignment.Center,
            FormatFlags = StringFormatFlags.NoWrap
        };
        g.DrawString(
            label,
            textFont,
            textBrush,
            new RectangleF(startX + iconSize + iconGap, rect.Y, textWidth + 10f, rect.Height),
            format);
    }

    private void DrawStatus(Graphics g)
    {
        if (string.IsNullOrWhiteSpace(_status)) return;

        var (glyph, textColor, iconColor) = _statusKind switch
        {
            StatusKind.Success => (IconGlyph.Check, SuccessColor, SuccessColor),
            StatusKind.Warning => (IconGlyph.Alert, WarningColor, WarningColor),
            StatusKind.Error => (IconGlyph.XCircle, ErrorColor, ErrorColor),
            StatusKind.Progress => (IconGlyph.Refresh, AccentTextColor, AccentTextColor),
            _ => (IconGlyph.Info, TextSecondaryColor, MutedColor)
        };

        DrawGlyph(
            g,
            glyph,
            new RectangleF(ContentLeftDip, _layout.StatusY + 1f, StatusIconSizeDip, StatusIconSizeDip),
            iconColor,
            1.5f);

        using var font = new Font("Segoe UI", 9f, FontStyle.Regular);
        using var brush = new SolidBrush(textColor);
        using var format = CreateStatusFormat();
        var visibleLines = Math.Clamp(_statusLines, 1, 2);
        g.DrawString(
            _status,
            font,
            brush,
            new RectangleF(
                StatusTextXDip,
                _layout.StatusY,
                StatusTextWidthDip,
                visibleLines * StatusLineHeightDip),
            format);
    }

    private void DrawGlyph(Graphics g, IconGlyph glyph, RectangleF box, Color color, float stroke)
    {
        var x = box.X;
        var y = box.Y;
        var w = box.Width;
        var h = box.Height;
        var cx = x + w / 2f;
        var cy = y + h / 2f;

        using var pen = new Pen(color, stroke)
        {
            StartCap = LineCap.Round,
            EndCap = LineCap.Round,
            LineJoin = LineJoin.Round
        };
        using var brush = new SolidBrush(color);

        switch (glyph)
        {
            case IconGlyph.Pin:
                g.DrawEllipse(pen, cx - 2.5f, y + h * 0.18f, 5f, 5f);
                g.DrawLine(pen, cx, y + h * 0.18f + 5f, cx, y + h * 0.72f);
                g.DrawLine(pen, cx - 3f, y + h * 0.8f, cx + 3f, y + h * 0.8f);
                break;

            case IconGlyph.PinFilled:
                g.FillEllipse(brush, cx - 2.5f, y + h * 0.18f, 5f, 5f);
                g.DrawLine(pen, cx, y + h * 0.18f + 5f, cx, y + h * 0.72f);
                g.DrawLine(pen, cx - 3f, y + h * 0.8f, cx + 3f, y + h * 0.8f);
                break;

            case IconGlyph.Close:
                g.DrawLine(pen, x + w * 0.2f, y + h * 0.2f, x + w * 0.8f, y + h * 0.8f);
                g.DrawLine(pen, x + w * 0.8f, y + h * 0.2f, x + w * 0.2f, y + h * 0.8f);
                break;

            case IconGlyph.Plus:
                g.DrawLine(pen, cx, y + h * 0.18f, cx, y + h * 0.82f);
                g.DrawLine(pen, x + w * 0.18f, cy, x + w * 0.82f, cy);
                break;

            case IconGlyph.Sliders:
                g.DrawLine(pen, x + w * 0.2f, y + h * 0.28f, x + w * 0.8f, y + h * 0.28f);
                g.DrawLine(pen, x + w * 0.2f, cy, x + w * 0.8f, cy);
                g.DrawLine(pen, x + w * 0.2f, y + h * 0.72f, x + w * 0.8f, y + h * 0.72f);
                g.FillEllipse(brush, x + w * 0.58f - 1.6f, y + h * 0.28f - 1.6f, 3.2f, 3.2f);
                g.FillEllipse(brush, x + w * 0.34f - 1.6f, cy - 1.6f, 3.2f, 3.2f);
                g.FillEllipse(brush, x + w * 0.66f - 1.6f, y + h * 0.72f - 1.6f, 3.2f, 3.2f);
                break;

            case IconGlyph.Refresh:
                var refreshRect = new RectangleF(x + w * 0.15f, y + h * 0.15f, w * 0.7f, h * 0.7f);
                g.DrawArc(pen, refreshRect, 35f, 290f);
                g.FillPolygon(brush, new[]
                {
                    new PointF(x + w * 0.86f, y + h * 0.14f),
                    new PointF(x + w * 0.86f, y + h * 0.42f),
                    new PointF(x + w * 0.6f, y + h * 0.26f)
                });
                break;

            case IconGlyph.Check:
                g.DrawLine(pen, x + w * 0.18f, cy + 1f, x + w * 0.42f, y + h * 0.74f);
                g.DrawLine(pen, x + w * 0.42f, y + h * 0.74f, x + w * 0.84f, y + h * 0.26f);
                break;

            case IconGlyph.Info:
                g.DrawEllipse(pen, x + w * 0.12f, y + h * 0.12f, w * 0.76f, h * 0.76f);
                g.FillEllipse(brush, cx - 1f, y + h * 0.3f, 2f, 2f);
                g.DrawLine(pen, cx, y + h * 0.44f, cx, y + h * 0.7f);
                break;

            case IconGlyph.Alert:
                g.DrawLine(pen, x + w * 0.5f, y + h * 0.14f, x + w * 0.12f, y + h * 0.84f);
                g.DrawLine(pen, x + w * 0.5f, y + h * 0.14f, x + w * 0.88f, y + h * 0.84f);
                g.DrawLine(pen, x + w * 0.12f, y + h * 0.84f, x + w * 0.88f, y + h * 0.84f);
                g.FillEllipse(brush, cx - 1f, y + h * 0.44f, 2f, 2f);
                g.DrawLine(pen, cx, y + h * 0.54f, cx, y + h * 0.66f);
                break;

            case IconGlyph.XCircle:
                g.DrawEllipse(pen, x + w * 0.12f, y + h * 0.12f, w * 0.76f, h * 0.76f);
                g.DrawLine(pen, x + w * 0.38f, y + h * 0.38f, x + w * 0.62f, y + h * 0.62f);
                g.DrawLine(pen, x + w * 0.62f, y + h * 0.38f, x + w * 0.38f, y + h * 0.62f);
                break;
        }
    }

    private enum IconGlyph
    {
        Pin,
        PinFilled,
        Close,
        Plus,
        Sliders,
        Refresh,
        Check,
        Info,
        Alert,
        XCircle
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
            _collapsedPressed = true;
            UpdateLayered();
            BeginDrag();
            return;
        }

        if (_layout.PinRect.Contains(dip))
        {
            _pressedPin = true;
            Capture = true;
            UpdateLayered();
            return;
        }

        if (_layout.CloseRect.Contains(dip))
        {
            _pressedClose = true;
            Capture = true;
            UpdateLayered();
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
            _pressedFooterButton = 0;
            Capture = true;
            UpdateLayered();
            return;
        }

        if (_layout.SettingsRect.Contains(dip))
        {
            _pressedFooterButton = 1;
            Capture = true;
            UpdateLayered();
            return;
        }

        if (_layout.RefreshRect.Contains(dip))
        {
            _pressedFooterButton = 2;
            Capture = true;
            UpdateLayered();
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

            ApplyDragOffsets(dx, dy);
            UpdateLayered();
            return;
        }

        if (!_layout.Expanded)
        {
            if (!_hoverCollapsed)
            {
                _hoverCollapsed = true;
                Cursor = Cursors.Hand;
                UpdateLayered();
            }

            return;
        }

        var dip = ToDip(e.Location);

        var hoverRow = -1;
        for (var i = 0; i < _layout.Rows.Count; i++)
        {
            if (!_layout.Rows[i].Contains(dip)) continue;
            var index = _scroll + i;
            if (index < _accounts.Count) hoverRow = index;
            break;
        }

        var hoverButton = _layout.AddRect.Contains(dip) ? 0
            : _layout.SettingsRect.Contains(dip) ? 1
            : _layout.RefreshRect.Contains(dip) ? 2
            : -1;
        var hoverPin = _layout.PinRect.Contains(dip);
        var hoverClose = _layout.CloseRect.Contains(dip);
        var interactive = hoverRow >= 0 || hoverButton >= 0 || hoverPin || hoverClose;
        var wantedCursor = interactive ? Cursors.Hand : Cursors.Default;

        if (hoverRow != _hoverRow ||
            hoverButton != _hoverButton ||
            hoverPin != _hoverPin ||
            hoverClose != _hoverClose ||
            Cursor != wantedCursor)
        {
            _hoverRow = hoverRow;
            _hoverButton = hoverButton;
            _hoverPin = hoverPin;
            _hoverClose = hoverClose;
            Cursor = wantedCursor;
            UpdateLayered();
        }
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        base.OnMouseUp(e);
        if (e.Button != MouseButtons.Left) return;

        var collapsePressed = _collapsedPressed;
        _collapsedPressed = false;
        if (collapsePressed) UpdateLayered();

        // Boutons de l'en-tête et du footer : l'action part au relâchement, ce qui
        // permet d'afficher l'état d'appui (surface-3 / surface-4) tant que le
        // bouton est maintenu, et d'annuler en relâchant hors de la cible.
        if (_pressedPin || _pressedClose || _pressedFooterButton >= 0)
        {
            var dip = ToDip(e.Location);
            var pressedPin = _pressedPin;
            var pressedClose = _pressedClose;
            var pressedFooter = _pressedFooterButton;
            _pressedPin = false;
            _pressedClose = false;
            _pressedFooterButton = -1;
            Capture = false;
            UpdateLayered();

            if (pressedPin && _layout.PinRect.Contains(dip))
            {
                TogglePin();
            }
            else if (pressedClose && _layout.CloseRect.Contains(dip))
            {
                Collapse();
            }
            else if (pressedFooter == 0 && _layout.AddRect.Contains(dip))
            {
                CaptureCurrent();
            }
            else if (pressedFooter == 1 && _layout.SettingsRect.Contains(dip))
            {
                _openSettings();
                ReloadData(update: true);
            }
            else if (pressedFooter == 2 && _layout.RefreshRect.Contains(dip))
            {
                ReloadData(update: true);
            }

            return;
        }

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

        if (_hoverRow != -1 || _hoverButton != -1 || _hoverPin || _hoverClose ||
            _hoverCollapsed || _pressedPin || _pressedClose || _pressedFooterButton >= 0)
        {
            _hoverRow = -1;
            _hoverButton = -1;
            _hoverPin = false;
            _hoverClose = false;
            _hoverCollapsed = false;
            _pressedPin = false;
            _pressedClose = false;
            _pressedFooterButton = -1;
            Capture = false;
            Cursor = Cursors.Default;
            UpdateLayered();
        }
    }

    private void BeginDrag()
    {
        _dragging = true;
        _dragMoved = false;
        _dragStartCursor = Cursor.Position;
        ClampOffsetsToClientBounds();
        _dragStartRight = _settings.OverlayOffsetRightDip;
        _dragStartTop = _settings.OverlayOffsetTopDip;
        Capture = true;
    }

    /// <summary>
    /// Applique le glisser en gardant l'overlay à l'intérieur de la fenêtre du client :
    /// les offsets sont bornés pour que l'overlay reste à au moins <see cref="EdgeMarginDip"/>
    /// DIP de chaque bord de la fenêtre. Une position mémorisée hors bornes (ancienne version,
    /// fenêtre redimensionnée) est d'abord ramenée dans la zone autorisée : le visuel étant
    /// déjà clampé à l'identique, il ne saute pas.
    /// </summary>
    private void ApplyDragOffsets(int dx, int dy)
    {
        if (!AppNativeMethods.GetWindowRect(_target.Handle, out var client)) return;

        var (minDip, maxRightDip, maxTopDip) = ComputeOffsetBounds(client, _layout.WindowWidthPx, _layout.WindowHeightPx);
        _settings.OverlayOffsetRightDip = Math.Clamp(_dragStartRight - dx / _scale, minDip, maxRightDip);
        _settings.OverlayOffsetTopDip = Math.Clamp(_dragStartTop + dy / _scale, minDip, maxTopDip);
    }

    private void ClampOffsetsToClientBounds()
    {
        if (!AppNativeMethods.GetWindowRect(_target.Handle, out var client)) return;

        var (minDip, maxRightDip, maxTopDip) = ComputeOffsetBounds(client, _layout.WindowWidthPx, _layout.WindowHeightPx);
        _settings.OverlayOffsetRightDip = Math.Clamp(_settings.OverlayOffsetRightDip, minDip, maxRightDip);
        _settings.OverlayOffsetTopDip = Math.Clamp(_settings.OverlayOffsetTopDip, minDip, maxTopDip);
    }

    /// <summary>
    /// Bornes d'offsets (DIP) qui maintiennent l'overlay dans la fenêtre du client, marges comprises.
    /// </summary>
    private (double MinDip, double MaxRightDip, double MaxTopDip) ComputeOffsetBounds(
        AppNativeMethods.RECT client,
        int widthPx,
        int heightPx)
    {
        var margin = EdgeMarginPx();
        var minDip = margin / _scale;
        var maxRightDip = Math.Max(minDip, (client.Width - margin - widthPx) / _scale);
        var maxTopDip = Math.Max(minDip, (client.Height - margin - heightPx) / _scale);
        return (minDip, maxRightDip, maxTopDip);
    }

    /// <summary>
    /// Verrouille ou libère le glisser de l'overlay. Dans les deux cas l'overlay
    /// reste aimanté à la fenêtre Riot et suit ses déplacements : l'épinglage
    /// empêche seulement de le déplacer à la souris par erreur.
    /// </summary>
    private void TogglePin()
    {
        if (!_settings.OverlayPinned)
        {
            _settings.OverlayPinned = true;
            // Champs hérités de l'ancien épinglage écran : plus utilisés pour le placement.
            _settings.OverlayPinnedRightPx = 0;
            _settings.OverlayPinnedTopPx = 0;
        }
        else
        {
            _settings.OverlayPinned = false;
        }

        _settingsStore.Save(_settings);
        SetStatus(
            _settings.OverlayPinned
                ? "Position verrouillée : l'overlay suit la fenêtre mais ne peut plus être déplacé."
                : "Position libre : glisse le bouton pour le déplacer.",
            StatusKind.Info);
    }

    private void Expand()
    {
        _expanded = true;
        _hoverCollapsed = false;
        _collapsedPressed = false;
        _hoverRow = -1;
        _hoverButton = -1;
        _hoverPin = false;
        _hoverClose = false;
        _pressedPin = false;
        _pressedClose = false;
        _pressedFooterButton = -1;
        Cursor = Cursors.Default;
        _outsideTimer.Start();
        UpdateLayered();
    }

    private void Collapse()
    {
        _expanded = false;
        _outsideTimer.Stop();
        _hoverRow = -1;
        _hoverButton = -1;
        _hoverPin = false;
        _hoverClose = false;
        _hoverCollapsed = false;
        _collapsedPressed = false;
        _pressedPin = false;
        _pressedClose = false;
        _pressedFooterButton = -1;
        Cursor = Cursors.Default;

        // Le panneau se ferme : le statut en cours ne doit pas réapparaître à
        // la réouverture. Il sera effacé aussi par sa propre rétention.
        ClearStatus(redraw: false);
        UpdateLayered();
    }

    /// <summary>
    /// Nombre de lignes occupées par le statut (1 ou 2) : la hauteur du panneau
    /// doit être connue avant le dessin, donc on mesure le texte à 96 DPI avec
    /// la police et le rendu du statut (2 lignes maximum).
    /// </summary>
    private static int ComputeStatusLines(string text)
    {
        if (string.IsNullOrWhiteSpace(text)) return 1;

        using var bitmap = new Bitmap(1, 1);
        using var graphics = Graphics.FromImage(bitmap);
        graphics.TextRenderingHint = TextHint;

        using var font = new Font("Segoe UI", 9f, FontStyle.Regular);
        using var format = CreateStatusFormat();

        var singleLineHeight = graphics.MeasureString(
            "A", font, int.MaxValue, format).Height;
        var size = graphics.MeasureString(
            text, font, (int)StatusTextWidthDip, format);

        if (singleLineHeight <= 0f) return 1;

        var lines = (int)Math.Round(size.Height / singleLineHeight);
        return Math.Clamp(lines, 1, 2);
    }

    /// <summary>
    /// Format commun à la mesure et au rendu du statut : retour à la ligne
    /// autorisé, 2 lignes maximum, ellipse si le texte déborde.
    /// </summary>
    private static StringFormat CreateStatusFormat() => new()
    {
        Alignment = StringAlignment.Near,
        LineAlignment = StringAlignment.Near,
        Trimming = StringTrimming.EllipsisCharacter,
        FormatFlags = StringFormatFlags.LineLimit
    };

    /// <summary>
    /// Affiche un message sous le panneau avec une rétention propre à son type :
    /// 5 s pour l'information et le succès, 8 s pour les avertissements et
    /// erreurs, sans expiration pour la progression (remplacée par le résultat).
    /// Un nouveau message remplace toujours le précédent et relance son échéance.
    /// </summary>
    private void SetStatus(string text, StatusKind kind)
    {
        _status = text;
        _statusKind = kind;
        _statusLines = ComputeStatusLines(text);

        var retentionMs = kind switch
        {
            StatusKind.Progress => 0,
            StatusKind.Warning or StatusKind.Error => StatusWarningRetentionMs,
            _ => StatusInfoRetentionMs
        };

        _statusTimer.Stop();

        if (retentionMs <= 0)
        {
            // Pendant un switch, le message reste affiché jusqu'au résultat.
            _statusExpiresUtc = DateTime.MaxValue;
        }
        else
        {
            _statusExpiresUtc = DateTime.UtcNow.AddMilliseconds(retentionMs);
            _statusTimer.Interval = retentionMs;
            _statusTimer.Start();
        }

        UpdateLayered();
    }

    /// <summary>Efface le statut courant et arrête l'échéance de rétention.</summary>
    private void ClearStatus(bool redraw)
    {
        if (_status is null) return;

        _status = null;
        _statusLines = 0;
        _statusExpiresUtc = DateTime.MaxValue;
        _statusTimer.Stop();

        if (redraw) UpdateLayered();
    }

    private void ExpireStatus()
    {
        if (IsDisposed || Disposing) return;

        if (_status is null)
        {
            _statusTimer.Stop();
            return;
        }

        var remaining = _statusExpiresUtc - DateTime.UtcNow;
        if (remaining > TimeSpan.Zero)
        {
            // Échéance repoussée entre-temps : recaler le timer plutôt que l'ignorer.
            _statusTimer.Interval = Math.Max(1, (int)remaining.TotalMilliseconds);
            _statusTimer.Start();
            return;
        }

        _status = null;
        _statusLines = 0;
        _statusExpiresUtc = DateTime.MaxValue;
        _statusTimer.Stop();

        // Le statut ne fait pas partie du rendu replié : rien à redessiner.
        if (_expanded) UpdateLayered();
    }

    private void CheckOutsideClick()
    {
        if (IsDisposed || Disposing || !IsHandleCreated || !_expanded) return;

        // Pendant un glisser, le curseur peut sortir du panneau quand celui-ci est
        // bloqué par le bord de la fenêtre du client : ne pas fermer le panneau.
        if (_dragging) return;

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
            SetStatus("Ce compte est déjà actif.", StatusKind.Info);
            return;
        }

        var guard = new GameGuard().Check();
        if (guard.IsHardBlock)
        {
            SetStatus(guard.Message, StatusKind.Warning);
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
        SetStatus($"Changement vers {account.DisplayName}…", StatusKind.Progress);

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
                                    SetStatus(progress.Message, StatusKind.Progress);
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

        var kind = result.IsSuccess
            ? StatusKind.Success
            : result.Outcome == SwitchOutcome.AlreadyCurrent
                ? StatusKind.Info
                : StatusKind.Error;

        if (result.IsSuccess)
        {
            SetStatus(result.Message, kind);
            ReloadData(update: false);
            if (_layout.Expanded) UpdateLayered();
            return;
        }

        SetStatus(result.Message, kind);

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
                SetStatus("Session Riot introuvable.", StatusKind.Warning);
                return;
            }

            var snapshot = RiotSessionReader.ReadFile(_paths.LiveSessionFile, waitForStable: false);
            if (!snapshot.Info.CanSwitch)
            {
                SetStatus(snapshot.Info.UnsupportedReason ?? "Session non exploitable.", StatusKind.Warning);
                return;
            }

            var account = _vault.Capture(snapshot, label: null, includeProfile: _settings.CaptureElectronProfile);
            SetStatus($"{account.DisplayName} ajouté.", StatusKind.Success);
            ReloadData(update: true);
        }
        catch (Exception ex)
        {
            SetStatus("Ajout impossible : " + ex.Message, StatusKind.Error);
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
        UninstallHooks();

        try
        {
            _positionTimer.Stop();
            _outsideTimer.Stop();
            _statusTimer.Stop();
            _positionTimer.Dispose();
            _outsideTimer.Dispose();
            _statusTimer.Dispose();
        }
        catch
        {
            // La fenêtre peut déjà être détruite par son owner Riot.
        }
    }

    private void UninstallHooks()
    {
        if (_locationHook != IntPtr.Zero)
        {
            AppNativeMethods.UnhookWinEvent(_locationHook);
            _locationHook = IntPtr.Zero;
        }

        if (_foregroundHook != IntPtr.Zero)
        {
            AppNativeMethods.UnhookWinEvent(_foregroundHook);
            _foregroundHook = IntPtr.Zero;
        }
    }

    /// <summary>Nature d'un message de statut, qui détermine sa durée de rétention.</summary>
    private enum StatusKind
    {
        Info,
        Success,
        Warning,
        Error,
        Progress
    }

    private sealed class OverlayLayoutState
    {
        public bool Expanded;
        public Rectangle WindowRectPx;
        public int WindowWidthPx;
        public int WindowHeightPx;
        public float PanelWidth;
        public float PanelHeight;
        public float ListTop;
        public float FooterY;
        public float StatusY;
        public RectangleF PinRect;
        public RectangleF CloseRect;
        public List<RectangleF> Rows = new();
        public RectangleF AddRect;
        public RectangleF SettingsRect;
        public RectangleF RefreshRect;
        public RectangleF ScrollTrackRect;
        public RectangleF ScrollThumbRect;
    }
}
