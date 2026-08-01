using DefaultAppGuard.Core;
using System.Text.Json;

namespace DefaultAppGuard.Agent;

public sealed record GuardConfiguration(
    int SchemaVersion,
    IReadOnlyList<string> ProtectedVideoExtensions,
    string ProtectionMode,
    bool NotificationsEnabled);

public sealed record GuardConfigurationUpdate(
    IReadOnlyList<string>? ProtectedVideoExtensions,
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
    private readonly ILogger<GuardConfigurationStore> logger;
    private GuardConfiguration current;
    private GuardConfigurationPersistenceStatus persistenceStatus;

    public GuardConfigurationStore(
        AgentOptions options,
        ILogger<GuardConfigurationStore> logger)
    {
        path = options.ConfigurationPath;
        backupPath = options.ConfigurationPath + ".bak";
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
            ProtectedVideoExtensions =
                snapshot.ProtectedVideoExtensions.ToArray(),
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
            var next = Create(
                update.ProtectedVideoExtensions ??
                    existing.ProtectedVideoExtensions,
                update.NotificationsEnabled ??
                    existing.NotificationsEnabled);
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

        var initial = Create(
            AssociationConstants.VideoExtensions,
            notificationsEnabled: true);
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
            var parsed = JsonSerializer.Deserialize<GuardConfiguration>(
                File.ReadAllText(sourcePath),
                JsonOptions)
            ?? throw new InvalidDataException(
                "Configuration file is empty.");
            if (parsed.SchemaVersion is not (1 or 2) ||
                !string.Equals(
                    parsed.ProtectionMode,
                    "monitor",
                    StringComparison.Ordinal))
            {
                throw new InvalidDataException(
                    "Unsupported guard configuration schema or mode.");
            }

            migrated = parsed.SchemaVersion == 1;
            configuration = Create(
                parsed.ProtectedVideoExtensions,
                migrated || parsed.NotificationsEnabled);
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
        var defaults = Create(
            AssociationConstants.VideoExtensions,
            notificationsEnabled: true);
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

    private static GuardConfiguration Create(
        IEnumerable<string>? extensions,
        bool notificationsEnabled)
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
                "At least one protected video extension is required.",
                nameof(extensions));
        }

        var supported = AssociationConstants.VideoExtensions.ToHashSet(
            StringComparer.OrdinalIgnoreCase);
        var unsupported = normalized
            .Where(extension => !supported.Contains(extension))
            .ToArray();
        if (unsupported.Length > 0)
        {
            throw new ArgumentException(
                $"Unsupported video extension(s): {string.Join(", ", unsupported)}",
                nameof(extensions));
        }

        return new GuardConfiguration(
            2,
            normalized,
            "monitor",
            notificationsEnabled);
    }

}
