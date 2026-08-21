using DefaultAppGuard.Core;
using System.Text.Json;

namespace DefaultAppGuard.Agent;

public sealed record GuardConfiguration(
    int SchemaVersion,
    IReadOnlyList<ProtectedAssociationRule> ProtectedAssociations,
    string ProtectionMode,
    bool NotificationsEnabled);

public sealed record GuardConfigurationUpdate(
    IReadOnlyList<string>? ProtectedExtensions,
    IReadOnlyList<string>? CaptureCurrentExtensions,
    bool? NotificationsEnabled);

public sealed record GuardConfigurationPersistenceStatus(
    string Storage,
    string BackupStorage,
    bool BackupAvailable,
    bool Recovered,
    string RecoveryCode,
    DateTimeOffset? RecoveredAtUtc);

public sealed class GuardConfigurationStore
{
    public const int CurrentSchemaVersion = 3;
    public const string StorageName = "runtime/guard-configuration.json";
    public const string BackupStorageName =
        "runtime/guard-configuration.json.bak";
    public const string NoRecoveryCode = "none";
    public const string BackupRestoredCode = "backup-restored";
    public const string DefaultsRestoredCode = "defaults-restored";

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        WriteIndented = true,
    };

    private readonly SemaphoreSlim gate = new(1, 1);
    private readonly string path;
    private readonly string backupPath;
    private readonly AssociationRuleFactory ruleFactory;
    private readonly ILogger<GuardConfigurationStore> logger;
    private GuardConfiguration current;
    private GuardConfigurationPersistenceStatus persistenceStatus;

    public GuardConfigurationStore(
        AgentOptions options,
        AssociationRuleFactory ruleFactory,
        ILogger<GuardConfigurationStore> logger)
    {
        path = options.ConfigurationPath;
        backupPath = options.ConfigurationPath + ".bak";
        this.ruleFactory = ruleFactory;
        this.logger = logger;
        persistenceStatus = new GuardConfigurationPersistenceStatus(
            StorageName,
            BackupStorageName,
            false,
            false,
            NoRecoveryCode,
            null);
        current = LoadOrCreate();
    }

    public GuardConfiguration Snapshot()
    {
        var snapshot = Volatile.Read(ref current);
        return snapshot with
        {
            ProtectedAssociations =
                snapshot.ProtectedAssociations.ToArray(),
        };
    }

    public GuardConfigurationPersistenceStatus SnapshotPersistenceStatus()
    {
        var snapshot = Volatile.Read(ref persistenceStatus);
        return snapshot with
        {
            BackupAvailable = File.Exists(backupPath),
        };
    }

    public async Task<GuardConfiguration> UpdateAsync(
        GuardConfigurationUpdate update,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(update);
        await gate.WaitAsync(cancellationToken);
        try
        {
            var existing = Volatile.Read(ref current);
            var next = update.ProtectedExtensions is null
                ? existing with
                {
                    NotificationsEnabled = update.NotificationsEnabled ??
                        existing.NotificationsEnabled,
                }
                : CreateUpdatedConfiguration(existing, update);
            await DurableJsonFile.WriteAsync(
                path,
                next,
                JsonOptions,
                cancellationToken,
                backupPath);
            Volatile.Write(ref current, next);
            return Snapshot();
        }
        finally
        {
            gate.Release();
        }
    }

    private GuardConfiguration CreateUpdatedConfiguration(
        GuardConfiguration existing,
        GuardConfigurationUpdate update)
    {
        var selected = NormalizeAndValidateExtensions(
            update.ProtectedExtensions!);
        var capture = (update.CaptureCurrentExtensions ?? [])
            .Select(ExtensionName.Normalize)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        var selectedSet = selected.ToHashSet(StringComparer.OrdinalIgnoreCase);
        var unselectedCapture = capture
            .Where(extension => !selectedSet.Contains(extension))
            .ToArray();
        if (unselectedCapture.Length > 0)
        {
            throw new ArgumentException(
                "A captured association must also be selected for protection.",
                nameof(update));
        }

        var existingRules = existing.ProtectedAssociations.ToDictionary(
            rule => rule.Extension,
            StringComparer.OrdinalIgnoreCase);
        var rules = selected.Select(extension =>
        {
            var entry = AssociationCatalog.Get(extension);
            if (string.Equals(
                entry.Category,
                AssociationCatalog.VideoCategory,
                StringComparison.Ordinal))
            {
                return ruleFactory.CreateDefault(extension);
            }

            if (capture.Contains(extension))
            {
                return ruleFactory.CaptureCurrent(extension);
            }

            if (existingRules.TryGetValue(extension, out var existingRule))
            {
                return existingRule;
            }

            throw new ArgumentException(
                $"A current default must be captured before protecting {extension}.",
                nameof(update));
        }).ToArray();

        return Create(
            rules,
            update.NotificationsEnabled ?? existing.NotificationsEnabled);
    }

    private GuardConfiguration LoadOrCreate()
    {
        var directory = Path.GetDirectoryName(path)
            ?? throw new InvalidOperationException(
                $"Configuration path has no directory: {path}");
        Directory.CreateDirectory(directory);

        if (File.Exists(path))
        {
            if (TryReadValidated(path, out var configuration, out var migrated))
            {
                if (migrated)
                {
                    DurableJsonFile.Write(
                        path,
                        configuration,
                        JsonOptions,
                        backupPath);
                }

                EnsureValidBackup(configuration);
                SetPersistenceStatus(NoRecoveryCode);
                return configuration;
            }

            return RecoverInvalidPrimary();
        }

        if (File.Exists(backupPath))
        {
            if (TryReadValidated(backupPath, out var backup, out _))
            {
                return RestoreFromBackup(backup);
            }

            return RestoreSafeDefaults();
        }

        var initial = CreateSafeDefaults();
        WritePrimaryAndBackup(initial);
        SetPersistenceStatus(NoRecoveryCode);
        return initial;
    }

    private bool TryReadValidated(
        string sourcePath,
        out GuardConfiguration configuration,
        out bool migrated)
    {
        try
        {
            var parsed = JsonSerializer.Deserialize<PersistedConfiguration>(
                File.ReadAllText(sourcePath),
                JsonOptions)
            ?? throw new InvalidDataException(
                "Configuration file is empty.");
            if (parsed.SchemaVersion is < 1 or > CurrentSchemaVersion ||
                !string.Equals(
                    parsed.ProtectionMode,
                    "monitor",
                    StringComparison.Ordinal))
            {
                throw new InvalidDataException(
                    "Unsupported guard configuration schema or mode.");
            }

            migrated = parsed.SchemaVersion < CurrentSchemaVersion;
            if (parsed.SchemaVersion is 1 or 2)
            {
                var extensions = NormalizeAndValidateLegacyVideoExtensions(
                    parsed.ProtectedVideoExtensions);
                configuration = Create(
                    extensions.Select(ruleFactory.CreateDefault),
                    parsed.SchemaVersion == 1 || parsed.NotificationsEnabled);
                return true;
            }

            configuration = Create(
                parsed.ProtectedAssociations ??
                    throw new InvalidDataException(
                        "Protected associations are missing."),
                parsed.NotificationsEnabled);
            return true;
        }
        catch (Exception exception) when (
            exception is JsonException or
            InvalidDataException or
            ArgumentException or
            NotSupportedException)
        {
            logger.LogWarning(
                "A guard configuration copy failed validation: {ErrorType}.",
                exception.GetType().Name);
            configuration = null!;
            migrated = false;
            return false;
        }
    }

    private GuardConfiguration RecoverInvalidPrimary()
    {
        if (File.Exists(backupPath) &&
            TryReadValidated(backupPath, out var backup, out _))
        {
            return RestoreFromBackup(backup);
        }

        return RestoreSafeDefaults();
    }

    private GuardConfiguration RestoreSafeDefaults()
    {
        var defaults = CreateSafeDefaults();
        WritePrimaryAndBackup(defaults);
        SetPersistenceStatus(DefaultsRestoredCode);
        logger.LogWarning(
            "Guard configuration was restored to safe defaults because " +
            "no valid primary or backup copy was available.");
        return defaults;
    }

    private GuardConfiguration RestoreFromBackup(
        GuardConfiguration configuration)
    {
        DurableJsonFile.Write(path, configuration, JsonOptions);
        EnsureValidBackup(configuration);
        SetPersistenceStatus(BackupRestoredCode);
        logger.LogWarning(
            "Guard configuration was restored from the last-known-good backup.");
        return configuration;
    }

    private void EnsureValidBackup(GuardConfiguration configuration)
    {
        if (File.Exists(backupPath) &&
            TryReadValidated(backupPath, out _, out _))
        {
            return;
        }

        DurableJsonFile.Write(backupPath, configuration, JsonOptions);
    }

    private void WritePrimaryAndBackup(GuardConfiguration configuration)
    {
        DurableJsonFile.Write(path, configuration, JsonOptions);
        DurableJsonFile.Write(backupPath, configuration, JsonOptions);
    }

    private void SetPersistenceStatus(string recoveryCode)
    {
        var recovered = !string.Equals(
            recoveryCode,
            NoRecoveryCode,
            StringComparison.Ordinal);
        Volatile.Write(
            ref persistenceStatus,
            new GuardConfigurationPersistenceStatus(
                StorageName,
                BackupStorageName,
                File.Exists(backupPath),
                recovered,
                recoveryCode,
                recovered ? DateTimeOffset.UtcNow : null));
    }

    private GuardConfiguration CreateSafeDefaults() =>
        Create(
            AssociationConstants.VideoExtensions.Select(
                ruleFactory.CreateDefault),
            notificationsEnabled: true);

    private static GuardConfiguration Create(
        IEnumerable<ProtectedAssociationRule> rules,
        bool notificationsEnabled)
    {
        ArgumentNullException.ThrowIfNull(rules);
        var normalized = rules
            .Select(ValidateAndNormalizeRule)
            .OrderBy(rule => rule.Extension, StringComparer.OrdinalIgnoreCase)
            .ToArray();
        if (normalized.Length == 0)
        {
            throw new ArgumentException(
                "At least one protected file extension is required.",
                nameof(rules));
        }

        var duplicate = normalized
            .GroupBy(rule => rule.Extension, StringComparer.OrdinalIgnoreCase)
            .FirstOrDefault(group => group.Count() > 1);
        if (duplicate is not null)
        {
            throw new ArgumentException(
                $"Duplicate protected extension: {duplicate.Key}",
                nameof(rules));
        }

        return new GuardConfiguration(
            CurrentSchemaVersion,
            normalized,
            "monitor",
            notificationsEnabled);
    }

    private static ProtectedAssociationRule ValidateAndNormalizeRule(
        ProtectedAssociationRule rule)
    {
        ArgumentNullException.ThrowIfNull(rule);
        var entry = AssociationCatalog.Get(rule.Extension);
        if (!string.Equals(
            entry.Category,
            rule.Category,
            StringComparison.Ordinal))
        {
            throw new InvalidDataException(
                $"Association category does not match the catalog: {entry.Extension}");
        }

        if (string.Equals(
            entry.Category,
            AssociationCatalog.VideoCategory,
            StringComparison.Ordinal))
        {
            if (!string.Equals(
                rule.TargetStrategy,
                AssociationConstants.MediaPlayerTargetStrategy,
                StringComparison.Ordinal))
            {
                throw new InvalidDataException(
                    $"Video association target is invalid: {entry.Extension}");
            }

            return rule with
            {
                Extension = entry.Extension,
                Category = entry.Category,
                TargetStrategy = AssociationConstants.MediaPlayerTargetStrategy,
                ExpectedProgId = null,
                ExpectedPackageId = null,
                ExpectedApplicationName = "Microsoft Media Player",
                CapturedAtUtc = null,
            };
        }

        if (!string.Equals(
                rule.TargetStrategy,
                AssociationConstants.CapturedCurrentTargetStrategy,
                StringComparison.Ordinal) ||
            string.IsNullOrWhiteSpace(rule.ExpectedProgId) ||
            rule.CapturedAtUtc is null)
        {
            throw new InvalidDataException(
                $"Captured association target is invalid: {entry.Extension}");
        }

        return rule with
        {
            Extension = entry.Extension,
            Category = entry.Category,
            TargetStrategy = AssociationConstants.CapturedCurrentTargetStrategy,
            ExpectedProgId = rule.ExpectedProgId.Trim(),
            ExpectedPackageId = NormalizeOptional(rule.ExpectedPackageId),
            ExpectedApplicationName = NormalizeOptional(
                rule.ExpectedApplicationName),
        };
    }

    private static string[] NormalizeAndValidateExtensions(
        IEnumerable<string> extensions)
    {
        ArgumentNullException.ThrowIfNull(extensions);
        var normalized = extensions
            .Select(ExtensionName.Normalize)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Order(StringComparer.OrdinalIgnoreCase)
            .ToArray();
        if (normalized.Length == 0)
        {
            throw new ArgumentException(
                "At least one protected file extension is required.",
                nameof(extensions));
        }

        foreach (var extension in normalized)
        {
            _ = AssociationCatalog.Get(extension);
        }

        return normalized;
    }

    private static string[] NormalizeAndValidateLegacyVideoExtensions(
        IEnumerable<string>? extensions)
    {
        var normalized = NormalizeAndValidateExtensions(
            extensions ?? throw new InvalidDataException(
                "Protected video extensions are missing."));
        var videoExtensions = AssociationConstants.VideoExtensions.ToHashSet(
            StringComparer.OrdinalIgnoreCase);
        if (normalized.Any(extension => !videoExtensions.Contains(extension)))
        {
            throw new InvalidDataException(
                "A legacy configuration contains a non-video extension.");
        }

        return normalized;
    }

    private static string? NormalizeOptional(string? value) =>
        string.IsNullOrWhiteSpace(value) ? null : value.Trim();

    private sealed record PersistedConfiguration(
        int SchemaVersion,
        IReadOnlyList<string>? ProtectedVideoExtensions,
        IReadOnlyList<ProtectedAssociationRule>? ProtectedAssociations,
        string? ProtectionMode,
        bool NotificationsEnabled);
}
