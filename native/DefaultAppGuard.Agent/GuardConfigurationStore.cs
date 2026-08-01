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

public sealed class GuardConfigurationStore
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        WriteIndented = true,
    };

    private readonly SemaphoreSlim gate = new(1, 1);
    private readonly string path;
    private GuardConfiguration current;

    public GuardConfigurationStore(AgentOptions options)
    {
        path = options.ConfigurationPath;
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
            await WriteAtomicallyAsync(next, cancellationToken);
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
        if (!File.Exists(path))
        {
            var initial = Create(
                AssociationConstants.VideoExtensions,
                notificationsEnabled: true);
            WriteAtomically(initial);
            return initial;
        }

        var parsed = JsonSerializer.Deserialize<GuardConfiguration>(
            File.ReadAllText(path),
            JsonOptions)
            ?? throw new InvalidDataException(
                $"Configuration file is empty: {path}");
        if (parsed.SchemaVersion is not (1 or 2) ||
            !string.Equals(
                parsed.ProtectionMode,
                "monitor",
                StringComparison.Ordinal))
        {
            throw new InvalidDataException(
                $"Unsupported guard configuration schema: {path}");
        }

        var migrated = Create(
            parsed.ProtectedVideoExtensions,
            parsed.SchemaVersion == 1 || parsed.NotificationsEnabled);
        if (parsed.SchemaVersion == 1)
        {
            WriteAtomically(migrated);
        }

        return migrated;
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

    private void WriteAtomically(GuardConfiguration configuration)
    {
        var directory = Path.GetDirectoryName(path)
            ?? throw new InvalidOperationException(
                $"Configuration path has no directory: {path}");
        Directory.CreateDirectory(directory);
        var temporaryPath = $"{path}.{Guid.NewGuid():N}.tmp";
        try
        {
            File.WriteAllText(
                temporaryPath,
                JsonSerializer.Serialize(configuration, JsonOptions));
            File.Move(temporaryPath, path, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
        }
    }

    private async Task WriteAtomicallyAsync(
        GuardConfiguration configuration,
        CancellationToken cancellationToken)
    {
        var directory = Path.GetDirectoryName(path)
            ?? throw new InvalidOperationException(
                $"Configuration path has no directory: {path}");
        Directory.CreateDirectory(directory);
        var temporaryPath = $"{path}.{Guid.NewGuid():N}.tmp";

        try
        {
            await using (var stream = new FileStream(
                             temporaryPath,
                             FileMode.CreateNew,
                             FileAccess.Write,
                             FileShare.None,
                             16 * 1024,
                             FileOptions.Asynchronous |
                             FileOptions.WriteThrough))
            {
                await JsonSerializer.SerializeAsync(
                    stream,
                    configuration,
                    JsonOptions,
                    cancellationToken);
                await stream.FlushAsync(cancellationToken);
            }

            File.Move(temporaryPath, path, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
        }
    }
}
