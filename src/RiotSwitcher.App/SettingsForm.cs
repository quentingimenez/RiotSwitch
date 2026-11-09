using System.Diagnostics;
using System.Drawing;
using System.Text;
using System.Windows.Forms;
using RiotSwitcher.App.Updates;
using RiotSwitcher.Core;
using RiotSwitcher.Core.Infrastructure;
using RiotSwitcher.Core.Riot;
using RiotSwitcher.Core.Settings;
using RiotSwitcher.Core.Switching;
using RiotSwitcher.Core.Updates;
using RiotSwitcher.Core.Vault;

namespace RiotSwitcher.App;

/// <summary>Paramètres : mode, overlay, comptes, sauvegardes et diagnostic.</summary>
internal sealed class SettingsForm : Form
{
    private readonly RiotPaths _paths;
    private readonly SessionVault _vault;
    private readonly SettingsStore _settingsStore;
    private readonly AppSettings _settings;
    private readonly IAppLogger _logger;

    private readonly RadioButton _watchMode;
    private readonly RadioButton _launcherMode;
    private readonly CheckBox _autostart;
    private readonly ComboBox _product;
    private readonly CheckBox _captureProfile;
    private readonly ListBox _accountList;
    private readonly GroupBox _accountsGroup;
    private readonly Label _accountsCountLabel;
    private readonly Button _moveUp;
    private readonly Button _moveDown;
    private readonly Button _sortAlphabetical;
    private readonly CheckBox _autoUpdate;
    private readonly Label _updateStatus;
    private readonly Button _checkUpdates;
    private readonly Button _installUpdate;
    private bool _checkingUpdates;

    private IReadOnlyList<AccountRecord> _accounts = Array.Empty<AccountRecord>();

    public SettingsForm(
        RiotPaths paths,
        SessionVault vault,
        SettingsStore settingsStore,
        AppSettings settings,
        IAppLogger logger)
    {
        _paths = paths;
        _vault = vault;
        _settingsStore = settingsStore;
        _settings = settings;
        _logger = logger;

        Text = AppInfo.SettingsTitle;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        StartPosition = FormStartPosition.CenterScreen;
        MinimizeBox = false;
        MaximizeBox = false;
        ShowInTaskbar = true;
        ClientSize = new Size(620, 760);
        Font = new Font("Segoe UI", 9F);
        AutoScaleMode = AutoScaleMode.Dpi;
        BackColor = Color.FromArgb(250, 250, 252);
        Icon = AppIcon.Get();

        var title = new Label
        {
            Text = "Paramètres de RiotSwitch",
            Font = new Font("Segoe UI", 15F, FontStyle.Bold),
            ForeColor = Color.FromArgb(32, 32, 40),
            AutoSize = false,
            Location = new Point(20, 14),
            Size = new Size(400, 32)
        };

        // Compte et mode ------------------------------------------------------
        var modeGroup = new GroupBox
        {
            Text = "Mode de fonctionnement",
            Location = new Point(20, 50),
            Size = new Size(580, 148)
        };

        _watchMode = new RadioButton
        {
            Text = "Veilleur en arrière-plan (léger)",
            Checked = settings.BackgroundMode == BackgroundMode.Watch,
            Location = new Point(16, 24),
            Size = new Size(300, 22)
        };

        _launcherMode = new RadioButton
        {
            Text = "Zéro fond (lancé depuis le raccourci Riot Client (Switch))",
            Checked = settings.BackgroundMode == BackgroundMode.Launcher,
            Location = new Point(16, 48),
            Size = new Size(540, 22)
        };

        _autostart = new CheckBox
        {
            Text = "Démarrer le veilleur avec Windows",
            Checked = settings.Autostart,
            Enabled = settings.BackgroundMode == BackgroundMode.Watch,
            Location = new Point(34, 74),
            Size = new Size(360, 22)
        };

        var productLabel = new Label
        {
            Text = "Produit à lancer après un switch :",
            AutoSize = false,
            Location = new Point(16, 106),
            Size = new Size(200, 20)
        };

        _product = new ComboBox
        {
            DropDownStyle = ComboBoxStyle.DropDownList,
            Location = new Point(218, 102),
            Size = new Size(190, 24)
        };

        _product.Items.Add(new ProductChoice("Aucun (ouvrir le client seulement)", "none"));
        _product.Items.Add(new ProductChoice("League of Legends", "league_of_legends"));
        _product.Items.Add(new ProductChoice("VALORANT", "valorant"));

        var product = SettingsStore.NormalizeProduct(settings.DefaultLaunchProduct);
        _product.SelectedIndex = product switch
        {
            "league_of_legends" => 1,
            "valorant" => 2,
            _ => 0
        };

        modeGroup.Controls.AddRange(new Control[]
        {
            _watchMode, _launcherMode, _autostart, productLabel, _product
        });

        // Overlay -------------------------------------------------------------
        var overlayGroup = new GroupBox
        {
            Text = "Overlay",
            Location = new Point(20, 208),
            Size = new Size(580, 84)
        };

        _captureProfile = new CheckBox
        {
            Text = "Capturer aussi le profil Electron en secours (utile si le switch YAML seul échoue)",
            Checked = settings.CaptureElectronProfile,
            Location = new Point(16, 22),
            Size = new Size(540, 22)
        };

        var resetOverlay = new Button
        {
            Text = "Réinitialiser la position de l'overlay",
            Location = new Point(16, 48),
            Size = new Size(240, 26)
        };
        resetOverlay.Click += (_, _) => ResetOverlayPosition();

        overlayGroup.Controls.AddRange(new Control[] { _captureProfile, resetOverlay });

        // Comptes -------------------------------------------------------------
        var accountsGroup = new GroupBox
        {
            Text = "Comptes enregistrés",
            Location = new Point(20, 302),
            Size = new Size(580, 132)
        };
        _accountsGroup = accountsGroup;

        _accountsCountLabel = new Label
        {
            AutoSize = true,
            Font = accountsGroup.Font,
            ForeColor = Color.FromArgb(128, 128, 140),
            BackColor = BackColor,
            Text = "0 compte"
        };

        _accountList = new ListBox
        {
            Location = new Point(16, 24),
            Size = new Size(348, 64),
            IntegralHeight = false
        };
        _accountList.SelectedIndexChanged += (_, _) => UpdateAccountButtons();

        var add = new Button
        {
            Text = "Ajouter le compte actuel",
            Location = new Point(378, 22),
            Size = new Size(186, 26)
        };
        add.Click += (_, _) => CaptureCurrentAccount();

        var rename = new Button
        {
            Text = "Renommer",
            Location = new Point(378, 54),
            Size = new Size(186, 26)
        };
        rename.Click += (_, _) => RenameSelectedAccount();

        var delete = new Button
        {
            Text = "Supprimer",
            Location = new Point(378, 86),
            Size = new Size(186, 26)
        };
        delete.Click += (_, _) => DeleteSelectedAccount();

        _moveUp = new Button
        {
            Text = "▲ Monter",
            Location = new Point(16, 94),
            Size = new Size(82, 24)
        };
        _moveUp.Click += (_, _) => MoveSelectedAccount(-1);

        _moveDown = new Button
        {
            Text = "▼ Descendre",
            Location = new Point(104, 94),
            Size = new Size(94, 24)
        };
        _moveDown.Click += (_, _) => MoveSelectedAccount(1);

        _sortAlphabetical = new Button
        {
            Text = "Trier A → Z",
            Location = new Point(204, 94),
            Size = new Size(154, 24)
        };
        _sortAlphabetical.Click += (_, _) => SortAccountsAlphabetically();

        accountsGroup.Controls.AddRange(new Control[]
        {
            _accountList, add, rename, delete, _moveUp, _moveDown, _sortAlphabetical
        });

        // Maintenance ---------------------------------------------------------
        var maintenanceGroup = new GroupBox
        {
            Text = "Maintenance et diagnostic",
            Location = new Point(20, 454),
            Size = new Size(580, 96)
        };

        var backups = new Button
        {
            Text = "Ouvrir les sauvegardes",
            Location = new Point(16, 22),
            Size = new Size(176, 26)
        };
        backups.Click += (_, _) => OpenFolder(_paths.BackupsDir);

        var logs = new Button
        {
            Text = "Ouvrir les logs",
            Location = new Point(202, 22),
            Size = new Size(176, 26)
        };
        logs.Click += (_, _) => OpenFolder(_paths.VaultLogsDir);

        var diagnostic = new Button
        {
            Text = "Diagnostic",
            Location = new Point(388, 22),
            Size = new Size(176, 26)
        };
        diagnostic.Click += (_, _) => ShowDiagnostic();

        var shortcuts = new Button
        {
            Text = "Créer les raccourcis Bureau",
            Location = new Point(16, 54),
            Size = new Size(269, 26)
        };
        shortcuts.Click += (_, _) => CreateShortcuts();

        var quit = new Button
        {
            Text = "Quitter le veilleur",
            Location = new Point(295, 54),
            Size = new Size(269, 26)
        };
        quit.Click += (_, _) => QuitWatcher();

        maintenanceGroup.Controls.AddRange(new Control[]
        {
            backups, logs, diagnostic, shortcuts, quit
        });

        // Mises à jour --------------------------------------------------------
        var updatesGroup = new GroupBox
        {
            Text = "Mises à jour",
            Location = new Point(20, 560),
            Size = new Size(580, 96)
        };

        _autoUpdate = new CheckBox
        {
            Text = "Vérifier automatiquement les mises à jour",
            Checked = settings.AutoCheckUpdates,
            Location = new Point(16, 22),
            Size = new Size(340, 22)
        };

        _updateStatus = new Label
        {
            AutoSize = false,
            Location = new Point(16, 50),
            Size = new Size(340, 36),
            ForeColor = Color.FromArgb(105, 105, 115),
            Text = $"Version actuelle : v{AppInfo.Version}."
        };

        _checkUpdates = new Button
        {
            Text = "Vérifier maintenant",
            Location = new Point(378, 20),
            Size = new Size(186, 26)
        };
        _checkUpdates.Click += async (_, _) => await CheckForUpdatesAsync(manual: true);

        _installUpdate = new Button
        {
            Text = "Installer la mise à jour",
            Location = new Point(378, 50),
            Size = new Size(186, 26),
            Visible = false,
            Enabled = false
        };
        _installUpdate.Click += async (_, _) => await InstallUpdateAsync();

        _autoUpdate.CheckedChanged += (_, _) => UpdateUpdateStatus();

        updatesGroup.Controls.AddRange(new Control[]
        {
            _autoUpdate, _updateStatus, _checkUpdates, _installUpdate
        });

        var disclaimer = new Label
        {
            Text =
                "Aucun mot de passe n'est stocké. Les sessions sont chiffrées par DPAPI, liées au compte Windows. " +
                "RiotSwitch n'est pas un outil officiel Riot Games ; utilise-le uniquement avec tes propres comptes.",
            ForeColor = Color.FromArgb(105, 105, 115),
            AutoSize = false,
            Location = new Point(20, 670),
            Size = new Size(580, 34)
        };

        var ok = new Button
        {
            Text = "Enregistrer",
            DialogResult = DialogResult.OK,
            Location = new Point(424, 708),
            Size = new Size(88, 28)
        };
        ok.Click += (_, _) => SaveSettings();

        var cancel = new Button
        {
            Text = "Annuler",
            DialogResult = DialogResult.Cancel,
            Location = new Point(518, 708),
            Size = new Size(82, 28)
        };

        Controls.AddRange(new Control[]
        {
            title, modeGroup, overlayGroup, accountsGroup, _accountsCountLabel, maintenanceGroup,
            updatesGroup, disclaimer, ok, cancel
        });

        var accountsTitleWidth = TextRenderer.MeasureText(accountsGroup.Text, accountsGroup.Font).Width;
        _accountsCountLabel.Location = new Point(
            accountsGroup.Left + 8 + accountsTitleWidth + 6,
            accountsGroup.Top);
        _accountsCountLabel.BringToFront();

        AcceptButton = ok;
        CancelButton = cancel;

        _watchMode.CheckedChanged += (_, _) => _autostart.Enabled = _watchMode.Checked;
        _launcherMode.CheckedChanged += (_, _) => _autostart.Enabled = _watchMode.Checked;

        LoadAccounts();
        UpdateUpdateStatus();

        Shown += (_, _) =>
        {
            if (_settings.AutoCheckUpdates)
            {
                _ = CheckForUpdatesAsync(manual: false);
            }
        };
    }

    private void LoadAccounts(string? selectAccountId = null)
    {
        var previouslySelected = selectAccountId ?? SelectedAccount?.Id;

        try
        {
            // L'ordre du coffre est l'ordre choisi par l'utilisateur ; il est partagé avec l'overlay.
            _accounts = _vault.ListAccounts().ToList();
        }
        catch (Exception ex)
        {
            _accounts = Array.Empty<AccountRecord>();
            _logger.Warn("Lecture du coffre impossible : " + ex.Message);
        }

        _accountList.BeginUpdate();
        _accountList.Items.Clear();
        foreach (var account in _accounts)
        {
            _accountList.Items.Add(new AccountItem(account));
        }

        _accountList.EndUpdate();

        if (_accountList.Items.Count > 0)
        {
            _accountList.SelectedIndex = 0;
            if (!string.IsNullOrEmpty(previouslySelected))
            {
                var index = _accounts
                    .Select((account, i) => (account, i))
                    .FirstOrDefault(pair => string.Equals(pair.account.Id, previouslySelected, StringComparison.Ordinal))
                    .i;
                if (index >= 0 && index < _accountList.Items.Count) _accountList.SelectedIndex = index;
            }
        }

        UpdateAccountButtons();
    }

    private void UpdateAccountButtons()
    {
        var has = _accountList.SelectedItem is AccountItem;
        var index = _accountList.SelectedIndex;

        _moveUp.Enabled = has && index > 0;
        _moveDown.Enabled = has && index >= 0 && index < _accounts.Count - 1;
        _sortAlphabetical.Enabled = _accounts.Count > 1;

        var countText = _accounts.Count == 0
            ? "Aucun compte"
            : $"{_accounts.Count} compte{(_accounts.Count > 1 ? "s" : string.Empty)}";
        _accountsCountLabel.Text = countText;
    }

    private void MoveSelectedAccount(int delta)
    {
        var account = SelectedAccount;
        if (account is null) return;

        try
        {
            if (!_vault.MoveAccount(account.Id, delta)) return;
            LoadAccounts(account.Id);
            _accountList.Focus();
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                this,
                "Impossible de déplacer le compte :\n" + ex.Message,
                AppInfo.DisplayName,
                MessageBoxButtons.OK,
                MessageBoxIcon.Warning);
        }
    }

    private void SortAccountsAlphabetically()
    {
        var selected = SelectedAccount?.Id;

        try
        {
            if (!_vault.SortAccountsAlphabetically()) return;
            LoadAccounts(selected);
            _accountList.Focus();
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                this,
                "Impossible de trier les comptes :\n" + ex.Message,
                AppInfo.DisplayName,
                MessageBoxButtons.OK,
                MessageBoxIcon.Warning);
        }
    }

    private AccountRecord? SelectedAccount =>
        (_accountList.SelectedItem as AccountItem)?.Account;

    private void CaptureCurrentAccount()
    {
        try
        {
            if (!File.Exists(_paths.LiveSessionFile))
            {
                MessageBox.Show(
                    this,
                    "Aucune session Riot locale. Connecte-toi d'abord dans Riot Client.",
                    AppInfo.DisplayName,
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Information);
                return;
            }

            var snapshot = RiotSessionReader.ReadFile(_paths.LiveSessionFile, waitForStable: false);
            if (!snapshot.Info.CanSwitch)
            {
                MessageBox.Show(
                    this,
                    snapshot.Info.UnsupportedReason ?? "Cette session n'est pas exploitable.",
                    AppInfo.DisplayName,
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Warning);
                return;
            }

            var account = _vault.Capture(
                snapshot,
                label: null,
                includeProfile: _captureProfile.Checked);

            LoadAccounts(account.Id);
            MessageBox.Show(
                this,
                $"{account.DisplayName} a été ajouté au coffre.",
                AppInfo.DisplayName,
                MessageBoxButtons.OK,
                MessageBoxIcon.Information);
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                this,
                "Ajout impossible :\n" + ex.Message,
                AppInfo.DisplayName,
                MessageBoxButtons.OK,
                MessageBoxIcon.Warning);
        }
    }

    private void RenameSelectedAccount()
    {
        var account = SelectedAccount;
        if (account is null) return;

        using var prompt = new PromptForm(
            "Renommer le compte",
            "Nom affiché dans l'overlay :",
            account.DisplayName);

        if (prompt.ShowDialog(this) != DialogResult.OK) return;

        try
        {
            if (_vault.Rename(account.Id, prompt.Value))
            {
                LoadAccounts(account.Id);
            }
            else
            {
                MessageBox.Show(this, "Compte introuvable.", AppInfo.DisplayName, MessageBoxButtons.OK,
                    MessageBoxIcon.Warning);
            }
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, "Renommage impossible :\n" + ex.Message, AppInfo.DisplayName,
                MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
    }

    private void DeleteSelectedAccount()
    {
        var account = SelectedAccount;
        if (account is null) return;

        var answer = MessageBox.Show(
            this,
            $"Supprimer « {account.DisplayName} » du coffre ?\n\nLa session Riot de ce compte ne sera plus " +
            "disponible (l'overlay ne pourra plus basculer dessus).",
            AppInfo.DisplayName,
            MessageBoxButtons.YesNo,
            MessageBoxIcon.Question,
            MessageBoxDefaultButton.Button2);

        if (answer != DialogResult.Yes) return;

        try
        {
            _vault.DeleteAccount(account.Id);
            LoadAccounts();
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, "Suppression impossible :\n" + ex.Message, AppInfo.DisplayName,
                MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
    }

    private void ResetOverlayPosition()
    {
        _settings.OverlayOffsetRightDip = 12;
        _settings.OverlayOffsetTopDip = 12;
        _settings.OverlayPositionSet = false;
        _settings.OverlayPinned = false;
        _settings.OverlayPinnedRightPx = 0;
        _settings.OverlayPinnedTopPx = 0;
        _settingsStore.Save(_settings);
        MessageBox.Show(this, "Position de l'overlay réinitialisée.", AppInfo.DisplayName,
            MessageBoxButtons.OK, MessageBoxIcon.Information);
    }

    private void SaveSettings()
    {
        _settings.BackgroundMode = _watchMode.Checked ? BackgroundMode.Watch : BackgroundMode.Launcher;
        _settings.Autostart = _watchMode.Checked && _autostart.Checked;
        _settings.CaptureElectronProfile = _captureProfile.Checked;
        _settings.AutoCheckUpdates = _autoUpdate.Checked;
        _settings.DefaultLaunchProduct =
            (_product.SelectedItem as ProductChoice)?.Value ?? "none";
        _settings.FirstRunCompleted = true;

        _settingsStore.Save(_settings);

        var warning = ShortcutService.Apply(_settings);
        if (warning is not null)
        {
            MessageBox.Show(this, "Raccourci de démarrage non mis à jour :\n" + warning,
                AppInfo.DisplayName, MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
    }

    private void CreateShortcuts()
    {
        var warning = ShortcutService.CreateDesktopShortcuts();
        MessageBox.Show(
            this,
            warning is null
                ? "Raccourcis créés sur le Bureau."
                : "Création impossible :\n" + warning,
            AppInfo.DisplayName,
            MessageBoxButtons.OK,
            warning is null ? MessageBoxIcon.Information : MessageBoxIcon.Warning);
    }

    private void OpenFolder(string path)
    {
        try
        {
            Directory.CreateDirectory(path);
            Process.Start(new ProcessStartInfo("explorer.exe", $"\"{path}\"")
            {
                UseShellExecute = true
            });
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, "Ouverture du dossier impossible :\n" + ex.Message, AppInfo.DisplayName,
                MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
    }

    private void QuitWatcher()
    {
        WatchMessageWindow.NotifyExisting(WatchMessageWindow.QuitMessage);
        MessageBox.Show(
            this,
            "Si le veilleur est en cours, il va s'arrêter. Tu peux le relancer avec le raccourci RiotSwitch.",
            AppInfo.DisplayName,
            MessageBoxButtons.OK,
            MessageBoxIcon.Information);
        Close();
    }

    private void UpdateUpdateStatus()
    {
        var pending = UpdateState.Pending;
        if (pending is not null)
        {
            _installUpdate.Visible = true;
            _installUpdate.Enabled = !_checkingUpdates;
            SetUpdateStatus($"Mise à jour disponible : v{pending.Version} (actuelle v{AppInfo.Version}).");
            return;
        }

        _installUpdate.Visible = false;
        _installUpdate.Enabled = false;
        SetUpdateStatus(_settings.AutoCheckUpdates
            ? $"Version actuelle : v{AppInfo.Version}."
            : $"Vérification automatique désactivée. Version actuelle : v{AppInfo.Version}.");
    }

    private void SetUpdateStatus(string text, bool warning = false)
    {
        _updateStatus.Text = text;
        _updateStatus.ForeColor = warning
            ? Color.FromArgb(180, 60, 60)
            : Color.FromArgb(105, 105, 115);
    }

    private async Task CheckForUpdatesAsync(bool manual)
    {
        if (_checkingUpdates) return;

        if (!manual && !_settings.AutoCheckUpdates)
        {
            UpdateUpdateStatus();
            return;
        }

        if (!manual && UpdateState.Pending is not null)
        {
            UpdateUpdateStatus();
            return;
        }

        if (!manual &&
            _settings.LastUpdateCheckUtc is { } last &&
            DateTimeOffset.UtcNow - last < TimeSpan.FromHours(24))
        {
            SetUpdateStatus($"Dernière vérification : {last.ToLocalTime():dd/MM/yyyy HH:mm}.");
            return;
        }

        _checkingUpdates = true;
        _checkUpdates.Enabled = false;
        _installUpdate.Enabled = false;
        SetUpdateStatus("Vérification des mises à jour…");

        try
        {
            var result = await UpdateState.CheckAsync(_paths, _settings, _settingsStore, _logger);
            if (result.UpdateAvailable)
            {
                UpdateUpdateStatus();
            }
            else if (result.Success)
            {
                _installUpdate.Visible = false;
                SetUpdateStatus($"À jour (v{AppInfo.Version}).");
            }
            else
            {
                SetUpdateStatus(
                    "Vérification impossible : " + (result.Error ?? "erreur inconnue"),
                    warning: true);
            }
        }
        catch (Exception ex)
        {
            _logger.Warn("Vérification des mises à jour impossible : " + ex.Message);
            SetUpdateStatus("Vérification impossible : " + ex.Message, warning: true);
        }
        finally
        {
            _checkingUpdates = false;
            _checkUpdates.Enabled = true;
            _installUpdate.Enabled = _installUpdate.Visible;
        }
    }

    private async Task InstallUpdateAsync()
    {
        var update = UpdateState.Pending;
        if (update is null)
        {
            SetUpdateStatus("Aucune mise à jour disponible.", warning: true);
            return;
        }

        if (!UpdateApplier.CanApply(AppContext.BaseDirectory, out var reason))
        {
            MessageBox.Show(this, reason, AppInfo.DisplayName,
                MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }

        if (SwitchSignal.IsActive())
        {
            MessageBox.Show(
                this,
                "Un changement de compte est en cours. Réessaie quand il sera terminé.",
                AppInfo.DisplayName,
                MessageBoxButtons.OK,
                MessageBoxIcon.Information);
            return;
        }

        var answer = MessageBox.Show(
            this,
            $"Installer RiotSwitch v{update.Version} ?\n\n" +
            "Le veilleur va se fermer, remplacer les fichiers puis redémarrer automatiquement.",
            AppInfo.DisplayName,
            MessageBoxButtons.YesNo,
            MessageBoxIcon.Question,
            MessageBoxDefaultButton.Button2);

        if (answer != DialogResult.Yes) return;

        _checkingUpdates = true;
        _checkUpdates.Enabled = false;
        _installUpdate.Enabled = false;
        SetUpdateStatus("Téléchargement de la mise à jour…");

        var progress = new Progress<double>(value =>
            SetUpdateStatus($"Téléchargement… {value:P0}"));

        try
        {
            var staging = await UpdateState.DownloadAndPrepareAsync(
                _paths, update, progress, _logger);

            if (!UpdateApplier.Launch(
                    AppContext.BaseDirectory,
                    staging,
                    Environment.ProcessId,
                    "--watch",
                    _logger))
            {
                SetUpdateStatus("Impossible de lancer l'installation.", warning: true);
                return;
            }

            SetUpdateStatus("Mise à jour prête ; RiotSwitch redémarre…");
            Application.Exit();
        }
        catch (Exception ex)
        {
            _logger.Warn("Installation de la mise à jour impossible : " + ex.Message);
            SetUpdateStatus("Installation impossible : " + ex.Message, warning: true);
        }
        finally
        {
            _checkingUpdates = false;
            _checkUpdates.Enabled = true;
            _installUpdate.Enabled = _installUpdate.Visible;
        }
    }

    private void ShowDiagnostic()
    {
        var builder = new StringBuilder();
        builder.AppendLine("RiotSwitch " + AppInfo.Version);
        builder.AppendLine("Windows : " + Environment.OSVersion.VersionString);
        builder.AppendLine();
        builder.AppendLine("Installation : " + _paths.InstallRoot);
        builder.AppendLine("  service : " + (_paths.InstallExists ? "présent" : "absent"));
        builder.AppendLine("  UI : " + (_paths.ClientExists ? "présente" : "absente"));
        builder.AppendLine("Session live : " + _paths.LiveSessionFile);
        builder.AppendLine("  présente : " + (_paths.LiveSessionExists ? "oui" : "non"));

        try
        {
            if (_paths.LiveSessionExists)
            {
                var session = RiotSessionReader.ReadFile(_paths.LiveSessionFile, waitForStable: false);
                builder.AppendLine("  format : " + session.Info.Format);
                builder.AppendLine("  compte : " + (session.Info.RiotId ?? "(inconnu)"));
                builder.AppendLine("  PUUID : " + (session.Info.Puuid ?? "(inconnu)"));
                builder.AppendLine("  switchable : " + (session.Info.CanSwitch ? "oui" : "non"));
                if (!session.Info.CanSwitch)
                    builder.AppendLine("  raison : " + session.Info.UnsupportedReason);
            }
        }
        catch (Exception ex)
        {
            builder.AppendLine("  erreur de lecture : " + ex.Message);
        }

        builder.AppendLine();
        builder.AppendLine("Coffre : " + _paths.VaultRoot);
        builder.AppendLine("  comptes : " + _vault.ListAccounts().Count);
        builder.AppendLine("  sauvegardes : " + _vault.ListBackups().Count);

        var guard = new GameGuard().Check();
        builder.AppendLine();
        builder.AppendLine("Garde-fou : " + guard.Message);

        var window = RiotClientWindow.Find();
        builder.AppendLine("Fenêtre Riot : " + (window is null
            ? "non détectée"
            : $"détectée ({window.Width}×{window.Height})"));

        MessageBox.Show(this, builder.ToString(), "Diagnostic RiotSwitch",
            MessageBoxButtons.OK, MessageBoxIcon.Information);
    }

    private sealed class AccountItem
    {
        public AccountItem(AccountRecord account) => Account = account;

        public AccountRecord Account { get; }

        public override string ToString()
        {
            var riotId = string.IsNullOrWhiteSpace(Account.RiotId) ? Account.ShortId : Account.RiotId;
            return $"{Account.DisplayName}  —  {riotId}";
        }
    }

    private sealed class ProductChoice
    {
        public ProductChoice(string label, string value)
        {
            Label = label;
            Value = value;
        }

        public string Label { get; }
        public string Value { get; }

        public override string ToString() => Label;
    }
}
