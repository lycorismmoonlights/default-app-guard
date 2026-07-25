using DefaultAppGuard.Core;
using System.Text.Json;

namespace DefaultAppGuard.Agent;

public sealed record GuardConfiguration(
    int SchemaVersion,
    IReadOnlyList<string> ProtectedVideoExtensions,
    string ProtectionMode);

public sealed record GuardConfigurationUpdate(
    IReadOnlyList<string>? ProtectedVideoExtensions);

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
        return current with
        {
            ProtectedVideoExtensions =
                current.ProtectedVideoExtensions.ToArray(),
        };
    }

    public async Task<GuardConfiguration> UpdateAsync(
        IEnumerable<string>? extensions,
        CancellationToken cancellationToken)
    {
        var next = Create(extensions);
        await gate.WaitAsync(cancellationToken);
        try
        {
            await WriteAtomicallyAsync(next, cancellationToken);
            current = next;
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
            var initial = Create(AssociationConstants.VideoExtensions);
            WriteAtomically(initial);
            return initial;
        }

        var parsed = JsonSerializer.Deserialize<GuardConfiguration>(
            File.ReadAllText(path),
            JsonOptions)
            ?? throw new InvalidDataException(
                $"Configuration file is empty: {path}");
        if (parsed.SchemaVersion != 1 ||
            !string.Equals(
                parsed.ProtectionMode,
                "monitor",
                StringComparison.Ordinal))
        {
            throw new InvalidDataException(
                $"Unsupported guard configuration schema: {path}");
        }

        return Create(parsed.ProtectedVideoExtensions);
    }

    private static GuardConfiguration Create(
        IEnumerable<string>? extensions)
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

        return new GuardConfiguration(1, normalized, "monitor");
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
