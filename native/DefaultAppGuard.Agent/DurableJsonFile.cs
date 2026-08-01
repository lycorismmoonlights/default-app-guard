using System.Text.Json;

namespace DefaultAppGuard.Agent;

internal static class DurableJsonFile
{
    private const int CommitAttemptCount = 5;
    private static readonly TimeSpan InitialRetryDelay =
        TimeSpan.FromMilliseconds(25);

    internal static void Write<T>(
        string path,
        T value,
        JsonSerializerOptions options,
        string? backupPath = null)
    {
        var temporaryPath = CreateTemporaryPath(path);
        try
        {
            using (var stream = new FileStream(
                       temporaryPath,
                       FileMode.CreateNew,
                       FileAccess.Write,
                       FileShare.None,
                       16 * 1024,
                       FileOptions.WriteThrough))
            {
                JsonSerializer.Serialize(stream, value, options);
                stream.Flush(flushToDisk: true);
            }

            CommitWithRetry(temporaryPath, path, backupPath);
        }
        finally
        {
            TryDelete(temporaryPath);
        }
    }

    internal static async Task WriteAsync<T>(
        string path,
        T value,
        JsonSerializerOptions options,
        CancellationToken cancellationToken,
        string? backupPath = null)
    {
        var temporaryPath = CreateTemporaryPath(path);
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
                    value,
                    options,
                    cancellationToken);
                await stream.FlushAsync(cancellationToken);
                stream.Flush(flushToDisk: true);
            }

            await CommitWithRetryAsync(
                temporaryPath,
                path,
                backupPath,
                cancellationToken);
        }
        finally
        {
            TryDelete(temporaryPath);
        }
    }

    private static string CreateTemporaryPath(string path)
    {
        var directory = Path.GetDirectoryName(path)
            ?? throw new InvalidOperationException(
                $"JSON file path has no directory: {path}");
        Directory.CreateDirectory(directory);
        return $"{path}.{Guid.NewGuid():N}.tmp";
    }

    private static void CommitWithRetry(
        string temporaryPath,
        string path,
        string? backupPath)
    {
        var delay = InitialRetryDelay;
        for (var attempt = 1; attempt <= CommitAttemptCount; attempt++)
        {
            try
            {
                Commit(temporaryPath, path, backupPath);
                return;
            }
            catch (IOException exception) when (
                IsTransientSharingFailure(exception) &&
                attempt < CommitAttemptCount)
            {
                Thread.Sleep(delay);
                delay += delay;
            }
        }
    }

    private static async Task CommitWithRetryAsync(
        string temporaryPath,
        string path,
        string? backupPath,
        CancellationToken cancellationToken)
    {
        var delay = InitialRetryDelay;
        for (var attempt = 1; attempt <= CommitAttemptCount; attempt++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                Commit(temporaryPath, path, backupPath);
                return;
            }
            catch (IOException exception) when (
                IsTransientSharingFailure(exception) &&
                attempt < CommitAttemptCount)
            {
                await Task.Delay(delay, cancellationToken);
                delay += delay;
            }
        }
    }

    private static void Commit(
        string temporaryPath,
        string path,
        string? backupPath)
    {
        if (!File.Exists(path))
        {
            File.Move(temporaryPath, path);
            return;
        }

        if (backupPath is null)
        {
            File.Move(temporaryPath, path, overwrite: true);
            return;
        }

        File.Replace(
            temporaryPath,
            path,
            backupPath,
            ignoreMetadataErrors: true);
    }

    private static bool IsTransientSharingFailure(IOException exception)
    {
        var errorCode = exception.HResult & 0xFFFF;
        return errorCode is 32 or 33;
    }

    private static void TryDelete(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch (IOException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }
    }
}
