using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using RiotSwitcher.Core.Infrastructure;
using RiotSwitcher.Core.Riot;

namespace RiotSwitcher.Core.Vault;

public sealed class VaultBundle
{
    public required AccountRecord Account { get; init; }
    public required BundleContents Contents { get; init; }
    public required RiotSessionSnapshot Session { get; init; }
}

public sealed class BackupEntry
{
    public required string FileName { get; init; }
    public required string FullPath { get; init; }
    public required DateTimeOffset CreatedUtc { get; init; }
}

public sealed class BackupBundle
{
    public required string FileName { get; init; }
    public required BundleContents Contents { get; init; }
    public required RiotSessionSnapshot Session { get; init; }
}

/// <summary>
/// Coffre local : accounts.json en clair (métadonnées), bundles DPAPI pour les sessions.
/// Toutes les écritures sont sérialisées par un mutex inter-processus.
/// </summary>
public sealed class SessionVault
{
    public const int MaxBackups = 5;
    private readonly RiotPaths _paths;
    private readonly IAppLogger _logger;
    private readonly object _gate = new();
    private readonly string _lockName;

    public SessionVault(RiotPaths paths, IAppLogger? logger = null)
    {
        _paths = paths ?? throw new ArgumentNullException(nameof(paths));
        _logger = logger ?? NullLogger.Instance;
        _paths.EnsureVaultDirectories();
        _lockName = AppInfo.VaultMutexName + "." + ShortHash(_paths.VaultRoot);
    }

    public RiotPaths Paths => _paths;

    // Lecture / comptes --------------------------------------------------------
    public IReadOnlyList<AccountRecord> ListAccounts()
    {
        lock (_gate)
        {
            return ReadAccountsUnlocked().Accounts.ToList();
        }
    }

    public AccountsDocument ReadAccounts()
    {
        lock (_gate)
        {
            return ReadAccountsUnlocked();
        }
    }

    public AccountRecord? GetAccount(string accountId)
    {
        if (string.IsNullOrWhiteSpace(accountId)) return null;
        lock (_gate)
        {
            return ReadAccountsUnlocked().Accounts.FirstOrDefault(
                a => string.Equals(a.Id, accountId.Trim(), StringComparison.Ordinal));
        }
    }

    public AccountRecord? ResolveAccount(string idOrLabelOrRiotId)
    {
        if (string.IsNullOrWhiteSpace(idOrLabelOrRiotId)) return null;
        var query = idOrLabelOrRiotId.Trim();

        lock (_gate)
        {
            var accounts = ReadAccountsUnlocked().Accounts;

            var exact = accounts.FirstOrDefault(a => string.Equals(a.Id, query, StringComparison.Ordinal));
            if (exact is not null) return exact;

            var byLabel = accounts
                .Where(a => string.Equals(a.Label, query, StringComparison.OrdinalIgnoreCase))
                .ToList();
            if (byLabel.Count == 1) return byLabel[0];
            if (byLabel.Count > 1)
                throw new VaultException($"Plusieurs comptes portent le libellé « {query} ».");

            var byRiotId = accounts
                .Where(a => string.Equals(a.RiotId, query, StringComparison.OrdinalIgnoreCase))
                .ToList();
            if (byRiotId.Count == 1) return byRiotId[0];
            if (byRiotId.Count > 1)
                throw new VaultException($"Plusieurs comptes portent le Riot ID « {query} ».");

            return null;
        }
    }

    public AccountRecord? FindByPuuid(string? puuid)
    {
        if (string.IsNullOrWhiteSpace(puuid)) return null;
        lock (_gate)
        {
            return ReadAccountsUnlocked().Accounts.FirstOrDefault(
                a => string.Equals(a.Id, puuid, StringComparison.Ordinal) ||
                     string.Equals(a.Puuid, puuid, StringComparison.Ordinal));
        }
    }

    // Capture ------------------------------------------------------------------
    public AccountRecord Capture(
        RiotSessionSnapshot snapshot,
        string? label = null,
        bool includeProfile = false,
        string? accountIdOverride = null,
        string? autoLaunchProduct = null)
    {
        ArgumentNullException.ThrowIfNull(snapshot);

        if (!snapshot.Info.HasSession)
            throw new VaultException("Aucune session Riot à capturer.");
        if (!snapshot.Info.CanSwitch)
            throw new VaultException(
                $"Capture refusée : {snapshot.Info.UnsupportedReason ?? "session inutilisable pour un switch."}");

        var id = snapshot.Info.Puuid;
        if (string.IsNullOrWhiteSpace(id)) id = accountIdOverride?.Trim();
        if (string.IsNullOrWhiteSpace(id)) id = "legacy-" + Guid.NewGuid().ToString("N");
        id = id.Trim();

        var profileFiles = includeProfile
            ? ElectronProfileCollector.Capture(_paths)
                .ToDictionary(p => p.RelativePath, p => p.Bytes, StringComparer.OrdinalIgnoreCase)
            : new Dictionary<string, byte[]>(StringComparer.OrdinalIgnoreCase);

        var now = DateTimeOffset.UtcNow;
        var manifest = new BundleManifest
        {
            SchemaVersion = 1,
            AccountId = id,
            RiotId = snapshot.Info.RiotId,
            Puuid = snapshot.Info.Puuid,
            Format = FormatToString(snapshot.Info.Format),
            CapturedAtUtc = now,
            SourcePath = snapshot.SourcePath,
            YamlSha256 = snapshot.Sha256,
            YamlLength = snapshot.Length,
            IncludesProfile = profileFiles.Count > 0
        };

        var encrypted = DpapiBundle.CreateEncryptedBundle(manifest, snapshot.YamlBytes, profileFiles);
        var bundlePath = GetBundlePath(id);

        return WithWriteLock(() =>
        {
            var document = ReadAccountsUnlocked();

            if (File.Exists(bundlePath))
            {
                TryBackupFile(bundlePath, "replace-" + SafeFileName(id));
            }

            AtomicFile.WriteAllBytes(bundlePath, encrypted);

            var record = document.Accounts.FirstOrDefault(a => string.Equals(a.Id, id, StringComparison.Ordinal));
            var isNew = record is null;
            if (record is null)
            {
                record = new AccountRecord
                {
                    Id = id,
                    CreatedUtc = now
                };
                document.Accounts.Add(record);
            }

            if (!string.IsNullOrWhiteSpace(label))
                record.Label = NormalizeLabel(label);

            if (string.IsNullOrWhiteSpace(record.Label))
                record.Label = DefaultLabel(snapshot.Info, id);

            record.RiotId = snapshot.Info.RiotId ?? record.RiotId;
            record.Puuid = snapshot.Info.Puuid ?? record.Puuid;
            record.Locale = snapshot.Info.Locale ?? record.Locale;
            record.Country = snapshot.Info.Country ?? record.Country;
            record.HasProfile = manifest.IncludesProfile;
            record.Legacy = snapshot.Info.Format == RiotSessionFormat.LegacyCookies;
            record.LastUsedUtc = now;
            record.LastError = null;
            if (!string.IsNullOrWhiteSpace(autoLaunchProduct))
                record.AutoLaunchProduct = NormalizeProduct(autoLaunchProduct);

            SaveAccountsUnlocked(document);
            _logger.Info($"Session capturée pour le compte {record.DisplayName} ({id[..Math.Min(6, id.Length)]}…).");

            if (isNew)
                _logger.Info($"Nouveau compte ajouté au coffre : {record.DisplayName}.");
            return record;
        });
    }

    // Bundle / session ---------------------------------------------------------
    public VaultBundle GetBundle(string accountId)
    {
        var account = GetAccount(accountId)
            ?? throw new VaultException($"Compte introuvable dans le coffre : {accountId}");

        var contents = ReadBundleFile(GetBundlePath(account.Id));
        if (!string.Equals(contents.Manifest.AccountId, account.Id, StringComparison.Ordinal))
            throw new VaultException("Le bundle ne correspond pas au compte demandé (manifest incohérent).");

        var yamlHash = RiotSessionReader.Sha256Hex(contents.YamlBytes);
        if (!string.Equals(contents.Manifest.YamlSha256, yamlHash, StringComparison.OrdinalIgnoreCase))
            throw new VaultException("Le bundle est corrompu (empreinte YAML non conforme).");

        var session = RiotSessionReader.Snapshot(contents.YamlBytes, GetBundlePath(account.Id));
        return new VaultBundle
        {
            Account = account,
            Contents = contents,
            Session = session
        };
    }

    public RiotSessionSnapshot GetSession(string accountId) => GetBundle(accountId).Session;

    public string GetBundlePath(string accountId)
    {
        var safe = SafeFileName(accountId);
        return Path.Combine(_paths.SessionsVaultDir, safe + ".rsw");
    }

    // Métadonnées --------------------------------------------------------------
    public bool MarkUsed(string accountId, DateTimeOffset when)
    {
        return WithWriteLock(() =>
        {
            var document = ReadAccountsUnlocked();
            var record = document.Accounts.FirstOrDefault(a => string.Equals(a.Id, accountId, StringComparison.Ordinal));
            if (record is null) return false;

            record.LastUsedUtc = when;
            record.LastError = null;
            SaveAccountsUnlocked(document);
            return true;
        });
    }

    public bool MarkSwitched(string accountId, DateTimeOffset when)
    {
        return WithWriteLock(() =>
        {
            var document = ReadAccountsUnlocked();
            var record = document.Accounts.FirstOrDefault(a => string.Equals(a.Id, accountId, StringComparison.Ordinal));
            if (record is null) return false;

            record.LastSwitchUtc = when;
            record.LastUsedUtc = when;
            record.LastError = null;
            SaveAccountsUnlocked(document);
            return true;
        });
    }

    public bool SetLastError(string accountId, string? error)
    {
        return WithWriteLock(() =>
        {
            var document = ReadAccountsUnlocked();
            var record = document.Accounts.FirstOrDefault(a => string.Equals(a.Id, accountId, StringComparison.Ordinal));
            if (record is null) return false;

            record.LastError = string.IsNullOrWhiteSpace(error) ? null : error.Trim();
            SaveAccountsUnlocked(document);
            return true;
        });
    }

    public bool Rename(string accountId, string label)
    {
        var normalized = NormalizeLabel(label);
        return WithWriteLock(() =>
        {
            var document = ReadAccountsUnlocked();
            var record = document.Accounts.FirstOrDefault(a => string.Equals(a.Id, accountId, StringComparison.Ordinal));
            if (record is null) return false;

            record.Label = normalized;
            SaveAccountsUnlocked(document);
            return true;
        });
    }

    /// <summary>Déplace un compte dans l'ordre d'affichage (delta négatif = vers le haut).</summary>
    public bool MoveAccount(string accountId, int delta)
    {
        if (delta == 0 || string.IsNullOrWhiteSpace(accountId)) return false;

        return WithWriteLock(() =>
        {
            var document = ReadAccountsUnlocked();
            var index = document.Accounts.FindIndex(
                a => string.Equals(a.Id, accountId.Trim(), StringComparison.Ordinal));
            if (index < 0) return false;

            var target = Math.Clamp(index + delta, 0, document.Accounts.Count - 1);
            if (target == index) return false;

            var record = document.Accounts[index];
            document.Accounts.RemoveAt(index);
            document.Accounts.Insert(target, record);
            SaveAccountsUnlocked(document);
            _logger.Info($"Ordre des comptes : {record.DisplayName} déplacé en position {target + 1}.");
            return true;
        });
    }

    /// <summary>Trie les comptes par nom affiché, puis Riot ID, puis identifiant.</summary>
    public bool SortAccountsAlphabetically()
    {
        return WithWriteLock(() =>
        {
            var document = ReadAccountsUnlocked();
            if (document.Accounts.Count < 2) return false;

            var sorted = document.Accounts
                .OrderBy(a => a.DisplayName, StringComparer.CurrentCultureIgnoreCase)
                .ThenBy(a => a.RiotId ?? string.Empty, StringComparer.CurrentCultureIgnoreCase)
                .ThenBy(a => a.Id, StringComparer.Ordinal)
                .ToList();

            if (sorted.Select(a => a.Id).SequenceEqual(document.Accounts.Select(a => a.Id), StringComparer.Ordinal))
                return false;

            document.Accounts = sorted;
            SaveAccountsUnlocked(document);
            _logger.Info("Ordre des comptes : tri alphabétique appliqué.");
            return true;
        });
    }

    public bool DeleteAccount(string accountId)
    {
        return WithWriteLock(() =>
        {
            var document = ReadAccountsUnlocked();
            var record = document.Accounts.FirstOrDefault(a => string.Equals(a.Id, accountId, StringComparison.Ordinal));
            if (record is null) return false;

            var bundlePath = GetBundlePath(record.Id);
            if (File.Exists(bundlePath))
            {
                TryBackupFile(bundlePath, "delete-" + SafeFileName(record.Id));
                AtomicFile.TryDelete(bundlePath);
            }

            document.Accounts.Remove(record);
            SaveAccountsUnlocked(document);
            _logger.Info($"Compte supprimé du coffre : {record.DisplayName}.");
            return true;
        });
    }

    // Sauvegardes --------------------------------------------------------------
    public BackupEntry CreateBackup(RiotSessionSnapshot snapshot, string tag)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        if (!snapshot.Info.HasSession)
            throw new VaultException("Aucune session à sauvegarder.");

        var now = DateTimeOffset.UtcNow;
        var manifest = new BundleManifest
        {
            SchemaVersion = 1,
            AccountId = snapshot.Info.Puuid ?? "unknown",
            RiotId = snapshot.Info.RiotId,
            Puuid = snapshot.Info.Puuid,
            Format = FormatToString(snapshot.Info.Format),
            CapturedAtUtc = now,
            SourcePath = snapshot.SourcePath,
            YamlSha256 = snapshot.Sha256,
            YamlLength = snapshot.Length,
            IncludesProfile = false
        };

        var encrypted = DpapiBundle.CreateEncryptedBundle(manifest, snapshot.YamlBytes);
        return WithWriteLock(() =>
        {
            var fileName = $"{now:yyyyMMdd-HHmmss}-{SafeFileName(tag)}-{Guid.NewGuid():N}.rsw";
            if (fileName.Length > 120) fileName = fileName[..116] + ".rsw";
            var path = Path.Combine(_paths.BackupsDir, fileName);
            AtomicFile.WriteAllBytes(path, encrypted);
            PruneBackupsUnlocked();
            _logger.Info($"Sauvegarde de session créée : {fileName}.");
            return new BackupEntry
            {
                FileName = fileName,
                FullPath = path,
                CreatedUtc = now
            };
        });
    }

    public IReadOnlyList<BackupEntry> ListBackups()
    {
        lock (_gate)
        {
            if (!Directory.Exists(_paths.BackupsDir)) return Array.Empty<BackupEntry>();

            return Directory.EnumerateFiles(_paths.BackupsDir, "*.rsw")
                .Select(path => new FileInfo(path))
                .Select(info => new BackupEntry
                {
                    FileName = info.Name,
                    FullPath = info.FullName,
                    CreatedUtc = info.LastWriteTimeUtc
                })
                .OrderByDescending(b => b.CreatedUtc)
                .ToList();
        }
    }

    public BackupBundle OpenBackup(string fileName)
    {
        var name = Path.GetFileName(fileName.Trim());
        if (string.IsNullOrWhiteSpace(name) || !name.EndsWith(".rsw", StringComparison.OrdinalIgnoreCase))
            throw new VaultException("Nom de sauvegarde invalide.");

        var path = Path.Combine(_paths.BackupsDir, name);
        if (!File.Exists(path))
            throw new VaultException($"Sauvegarde introuvable : {name}");

        var contents = ReadBundleFile(path);
        var session = RiotSessionReader.Snapshot(contents.YamlBytes, path);
        return new BackupBundle
        {
            FileName = name,
            Contents = contents,
            Session = session
        };
    }

    // Interne ------------------------------------------------------------------
    private T WithWriteLock<T>(Func<T> action)
    {
        using var guard = MutexGuard.TryAcquire(_lockName, TimeSpan.FromSeconds(10));
        if (guard is null)
            throw new VaultBusyException("Le coffre RiotSwitch est utilisé par une autre instance.");

        lock (_gate)
        {
            return action();
        }
    }

    private AccountsDocument ReadAccountsUnlocked()
    {
        if (!File.Exists(_paths.AccountsFile))
            return new AccountsDocument();

        try
        {
            var text = AtomicFile.ReadAllText(_paths.AccountsFile);
            var document = JsonSerializer.Deserialize<AccountsDocument>(text, JsonDefaults.Options)
                ?? new AccountsDocument();
            document.Accounts ??= new List<AccountRecord>();
            NormalizeAccounts(document);
            return document;
        }
        catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException)
        {
            var backup = _paths.AccountsFile + ".bak";
            if (File.Exists(backup))
            {
                try
                {
                    var text = AtomicFile.ReadAllText(backup);
                    var document = JsonSerializer.Deserialize<AccountsDocument>(text, JsonDefaults.Options)
                        ?? new AccountsDocument();
                    document.Accounts ??= new List<AccountRecord>();
                    NormalizeAccounts(document);
                    _logger.Warn("accounts.json illisible : chargement de accounts.json.bak.");
                    return document;
                }
                catch
                {
                    // Le backup est aussi illisible.
                }
            }

            throw new VaultException("accounts.json est illisible et aucune sauvegarde valide n'est disponible.", ex);
        }
    }

    private void SaveAccountsUnlocked(AccountsDocument document)
    {
        document.SchemaVersion = 1;
        NormalizeAccounts(document);

        var json = JsonSerializer.Serialize(document, JsonDefaults.Options);

        if (File.Exists(_paths.AccountsFile))
        {
            try
            {
                File.Copy(_paths.AccountsFile, _paths.AccountsFile + ".bak", overwrite: true);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                _logger.Warn($"Copie de sauvegarde de accounts.json impossible : {ex.Message}");
            }
        }

        AtomicFile.WriteAllText(_paths.AccountsFile, json);
    }

    private BundleContents ReadBundleFile(string path)
    {
        if (!File.Exists(path))
            throw new VaultException($"Bundle de session introuvable : {Path.GetFileName(path)}");
        try
        {
            var bytes = AtomicFile.ReadAllBytes(path);
            return DpapiBundle.OpenBundle(bytes);
        }
        catch (InvalidDataException ex)
        {
            throw new VaultException("Le bundle de session est corrompu ou protégé par un autre compte Windows.", ex);
        }
    }

    private void TryBackupFile(string sourcePath, string tag)
    {
        try
        {
            if (!File.Exists(sourcePath)) return;
            var now = DateTimeOffset.UtcNow;
            var fileName = $"{now:yyyyMMdd-HHmmss}-{SafeFileName(tag)}-{Guid.NewGuid():N}.rsw";
            if (fileName.Length > 120) fileName = fileName[..116] + ".rsw";
            File.Copy(sourcePath, Path.Combine(_paths.BackupsDir, fileName), overwrite: true);
            PruneBackupsUnlocked();
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            _logger.Warn($"Sauvegarde de bundle impossible : {ex.Message}");
        }
    }

    private void PruneBackupsUnlocked()
    {
        try
        {
            if (!Directory.Exists(_paths.BackupsDir)) return;
            var files = Directory.EnumerateFiles(_paths.BackupsDir, "*.rsw")
                .Select(path => new FileInfo(path))
                .OrderByDescending(info => info.LastWriteTimeUtc)
                .ToList();

            for (var i = MaxBackups; i < files.Count; i++)
            {
                try { files[i].Delete(); } catch { }
            }
        }
        catch
        {
            // Best-effort.
        }
    }

    private static void NormalizeAccounts(AccountsDocument document)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var cleaned = new List<AccountRecord>();
        foreach (var account in document.Accounts)
        {
            if (account is null) continue;
            account.Id = account.Id?.Trim() ?? string.Empty;
            if (string.IsNullOrWhiteSpace(account.Id)) continue;
            if (!seen.Add(account.Id)) continue;

            account.Label = account.Label?.Trim() ?? string.Empty;
            account.RiotId = string.IsNullOrWhiteSpace(account.RiotId) ? null : account.RiotId.Trim();
            account.Puuid = string.IsNullOrWhiteSpace(account.Puuid) ? null : account.Puuid.Trim();
            account.Locale = string.IsNullOrWhiteSpace(account.Locale) ? null : account.Locale.Trim();
            account.Country = string.IsNullOrWhiteSpace(account.Country) ? null : account.Country.Trim();
            account.AutoLaunchProduct = string.IsNullOrWhiteSpace(account.AutoLaunchProduct)
                ? null
                : NormalizeProduct(account.AutoLaunchProduct);
            account.LastError = string.IsNullOrWhiteSpace(account.LastError) ? null : account.LastError.Trim();
            if (account.Label.Length > 60) account.Label = account.Label[..60];
            cleaned.Add(account);
        }

        document.Accounts = cleaned;
    }

    private static string DefaultLabel(RiotSessionInfo info, string id)
    {
        if (!string.IsNullOrWhiteSpace(info.RiotId)) return info.RiotId!;
        var shortId = id.Length <= 6 ? id : id[..6];
        return $"Compte {shortId}";
    }

    private static string NormalizeLabel(string label)
    {
        var normalized = (label ?? string.Empty).Trim();
        if (normalized.Length == 0) throw new VaultException("Le libellé ne peut pas être vide.");
        if (normalized.Length > 60) normalized = normalized[..60];
        return normalized;
    }

    private static string NormalizeProduct(string product)
    {
        var value = product.Trim().ToLowerInvariant();
        return value switch
        {
            "league" or "lol" or "league_of_legends" => "league_of_legends",
            "valorant" or "val" => "valorant",
            "none" or "aucun" or "client" => "none",
            _ => value
        };
    }

    private static string FormatToString(RiotSessionFormat format) => format switch
    {
        RiotSessionFormat.PslV1 => "psl-v1",
        RiotSessionFormat.LegacyCookies => "legacy",
        _ => "unknown"
    };

    private static string SafeFileName(string value)
    {
        var trimmed = (value ?? string.Empty).Trim();
        var builder = new StringBuilder(trimmed.Length);
        foreach (var c in trimmed)
        {
            if (char.IsLetterOrDigit(c) || c is '-' or '_') builder.Append(c);
        }

        if (builder.Length == 0) builder.Append("account");
        if (builder.Length > 64)
        {
            var hash = ShortHash(trimmed);
            builder.Length = 48;
            builder.Append('-').Append(hash);
        }

        return builder.ToString();
    }

    private static string ShortHash(string value)
    {
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(value ?? string.Empty));
        return Convert.ToHexString(hash)[..12].ToLowerInvariant();
    }
}
