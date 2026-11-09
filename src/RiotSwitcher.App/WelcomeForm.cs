using System.Drawing;
using System.Windows.Forms;
using RiotSwitcher.Core.Settings;

namespace RiotSwitcher.App;

/// <summary>Écran de premier lancement : explique le fonctionnement et les deux modes.</summary>
internal sealed class WelcomeForm : Form
{
    private readonly SettingsStore _settingsStore;
    private readonly AppSettings _settings;
    private readonly RadioButton _watchMode;
    private readonly RadioButton _launcherMode;
    private readonly CheckBox _autostart;
    private readonly CheckBox _desktopShortcuts;

    public WelcomeForm(SettingsStore settingsStore, AppSettings settings)
    {
        _settingsStore = settingsStore;
        _settings = settings;

        Text = "Bienvenue dans RiotSwitch";
        FormBorderStyle = FormBorderStyle.FixedDialog;
        StartPosition = FormStartPosition.CenterScreen;
        MinimizeBox = false;
        MaximizeBox = false;
        ShowInTaskbar = false;
        ClientSize = new Size(560, 470);
        Font = new Font("Segoe UI", 9F);
        AutoScaleMode = AutoScaleMode.Dpi;
        BackColor = Color.FromArgb(250, 250, 252);
        Icon = AppIcon.Get();

        var title = new Label
        {
            Text = "Bienvenue dans RiotSwitch",
            Font = new Font("Segoe UI", 15F, FontStyle.Bold),
            ForeColor = Color.FromArgb(32, 32, 40),
            AutoSize = false,
            Location = new Point(24, 20),
            Size = new Size(500, 34)
        };

        var intro = new Label
        {
            Text =
                "RiotSwitch garde tes comptes Riot dans un coffre local chiffré et les reconnecte " +
                "sans que tu aies à te déconnecter manuellement. L'overlay n'apparaît que quand la " +
                "fenêtre du Riot Client est ouverte. Par défaut, le mode zéro fond ne laisse aucun " +
                "processus RiotSwitch quand Riot est fermé.",
            AutoSize = false,
            Location = new Point(24, 62),
            Size = new Size(510, 62)
        };

        var steps = new Label
        {
            Text =
                "Pour commencer :\n" +
                "  1. Connecte-toi normalement à un compte dans Riot Client.\n" +
                "  2. Clique sur le bouton ⇄ affiché à l'écran (overlay replié), puis sur « + Ajouter ».\n" +
                "  3. Déconnecte-toi, connecte-toi au compte suivant, ajoute-le aussi.\n" +
                "  4. Ensuite, un clic sur un compte suffit pour basculer.",
            AutoSize = false,
            Location = new Point(24, 132),
            Size = new Size(510, 92)
        };

        var modeLabel = new Label
        {
            Text = "Mode de fonctionnement",
            Font = new Font("Segoe UI", 9.5F, FontStyle.Bold),
            AutoSize = false,
            Location = new Point(24, 232),
            Size = new Size(300, 20)
        };

        _launcherMode = new RadioButton
        {
            Text = "Zéro fond (par défaut) : je lance RiotSwitch depuis le raccourci Riot Client (Switch)",
            Checked = settings.BackgroundMode == BackgroundMode.Launcher,
            Location = new Point(28, 256),
            Size = new Size(520, 22)
        };

        _watchMode = new RadioButton
        {
            Text = "Veilleur en arrière-plan (persistant, démarre avec Windows)",
            Checked = settings.BackgroundMode == BackgroundMode.Watch,
            Location = new Point(28, 280),
            Size = new Size(500, 22)
        };

        _autostart = new CheckBox
        {
            Text = "Démarrer le veilleur avec Windows",
            Checked = settings.Autostart && settings.BackgroundMode == BackgroundMode.Watch,
            Location = new Point(28, 310),
            Size = new Size(400, 22),
            Enabled = settings.BackgroundMode == BackgroundMode.Watch
        };

        _desktopShortcuts = new CheckBox
        {
            Text = "Créer les raccourcis sur le Bureau (Riot Client (Switch) et Paramètres)",
            Checked = true,
            Location = new Point(28, 334),
            Size = new Size(500, 22)
        };

        var note = new Label
        {
            Text =
                "Aucun mot de passe n'est demandé ni stocké. Les sessions sont protégées par DPAPI " +
                "(compte Windows). RiotSwitch n'est pas un outil officiel Riot Games : utilise-le " +
                "uniquement avec tes propres comptes.",
            ForeColor = Color.FromArgb(100, 100, 110),
            AutoSize = false,
            Location = new Point(24, 366),
            Size = new Size(510, 48)
        };

        var start = new Button
        {
            Text = "Commencer",
            DialogResult = DialogResult.OK,
            Location = new Point(356, 424),
            Size = new Size(95, 28)
        };

        var later = new Button
        {
            Text = "Plus tard",
            DialogResult = DialogResult.Cancel,
            Location = new Point(457, 424),
            Size = new Size(80, 28)
        };

        Controls.AddRange(new Control[]
        {
            title, intro, steps, modeLabel, _watchMode, _launcherMode,
            _autostart, _desktopShortcuts, note, start, later
        });

        AcceptButton = start;
        CancelButton = later;

        _watchMode.CheckedChanged += (_, _) => _autostart.Enabled = _watchMode.Checked;
        _launcherMode.CheckedChanged += (_, _) =>
        {
            if (_launcherMode.Checked) _autostart.Checked = false;
        };
        start.Click += (_, _) => SaveAndApply();
    }

    private void SaveAndApply()
    {
        _settings.BackgroundMode = _watchMode.Checked ? BackgroundMode.Watch : BackgroundMode.Launcher;
        _settings.Autostart = _watchMode.Checked && _autostart.Checked;
        _settings.FirstRunCompleted = true;

        _settingsStore.Save(_settings);

        var warning = ShortcutService.Apply(_settings);
        if (_desktopShortcuts.Checked) warning ??= ShortcutService.CreateDesktopShortcuts();

        if (warning is not null)
        {
            MessageBox.Show(
                this,
                "Les raccourcis n'ont pas pu être créés :\n" + warning,
                "RiotSwitch",
                MessageBoxButtons.OK,
                MessageBoxIcon.Warning);
        }
    }
}
