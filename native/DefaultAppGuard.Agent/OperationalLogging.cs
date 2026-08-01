using Serilog;
using Serilog.Core;
using Serilog.Debugging;
using Serilog.Events;
using Serilog.Formatting.Compact;

namespace DefaultAppGuard.Agent;

public sealed record OperationalLogStatus(
    string Channel,
    bool Available,
    string Format,
    long FileSizeLimitBytes,
    int RetainedFileCountLimit,
    string Storage,
    string? LastErrorCode,
    DateTimeOffset? LastErrorAtUtc);

public sealed class OperationalLogHealth
{
    public const string ChannelName = "Serilog.Sinks.File";
    public const string FormatName = "CLEF";
    public const string StorageName = "runtime/logs";
    public const long FileSizeLimitBytes = 2 * 1024 * 1024;
    public const int RetainedFileCountLimit = 7;

    private readonly object gate = new();
    private OperationalLogStatus status = new(
        ChannelName,
        false,
        FormatName,
        FileSizeLimitBytes,
        RetainedFileCountLimit,
        StorageName,
        "not-started",
        null);

    public OperationalLogStatus Snapshot()
    {
        lock (gate)
        {
            return status;
        }
    }

    internal void SetAvailable()
    {
        lock (gate)
        {
            status = status with
            {
                Available = true,
                LastErrorCode = null,
                LastErrorAtUtc = null,
            };
        }
    }

    internal void SetUnavailable(string errorCode)
    {
        lock (gate)
        {
            status = status with
            {
                Available = false,
                LastErrorCode = errorCode,
                LastErrorAtUtc = DateTimeOffset.UtcNow,
            };
        }
    }
}

public sealed class OperationalLoggingSession : IDisposable
{
    private const string LogFilePattern = "agent-.clef";
    private bool disposed;

    private OperationalLoggingSession(
        Logger logger,
        OperationalLogHealth health)
    {
        Logger = logger;
        Health = health;
    }

    public Logger Logger { get; }

    public OperationalLogHealth Health { get; }

    public static OperationalLoggingSession Start(AgentOptions options)
    {
        var health = new OperationalLogHealth();
        health.SetAvailable();
        SelfLog.Enable(_ => health.SetUnavailable("sink-write-failed"));

        try
        {
            Directory.CreateDirectory(options.OperationalLogDirectory);
            var logger = new LoggerConfiguration()
                .MinimumLevel.Information()
                .MinimumLevel.Override("Microsoft", LogEventLevel.Warning)
                .MinimumLevel.Override("System", LogEventLevel.Warning)
                .Enrich.WithProperty(
                    "Application",
                    "DefaultAppGuard.Agent")
                .WriteTo.File(
                    new CompactJsonFormatter(),
                    Path.Combine(
                        options.OperationalLogDirectory,
                        LogFilePattern),
                    restrictedToMinimumLevel: LogEventLevel.Information,
                    fileSizeLimitBytes:
                        OperationalLogHealth.FileSizeLimitBytes,
                    buffered: false,
                    rollingInterval: RollingInterval.Day,
                    rollOnFileSizeLimit: true,
                    retainedFileCountLimit:
                        OperationalLogHealth.RetainedFileCountLimit,
                    shared: false)
                .CreateLogger();
            logger.Information(
                "Operational logging initialized with {Format} format, " +
                "{FileSizeLimitBytes} byte roll threshold, and " +
                "{RetainedFileCountLimit} retained files.",
                OperationalLogHealth.FormatName,
                OperationalLogHealth.FileSizeLimitBytes,
                OperationalLogHealth.RetainedFileCountLimit);
            return new OperationalLoggingSession(logger, health);
        }
        catch (Exception exception)
        {
            health.SetUnavailable(ClassifyStartupFailure(exception));
            return new OperationalLoggingSession(
                new LoggerConfiguration().CreateLogger(),
                health);
        }
    }

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }

        disposed = true;
        SelfLog.Disable();
        Logger.Dispose();
        GC.SuppressFinalize(this);
    }

    private static string ClassifyStartupFailure(Exception exception) =>
        exception switch
        {
            UnauthorizedAccessException => "access-denied",
            IOException => "io-error",
            ArgumentException or NotSupportedException => "invalid-path",
            _ => "initialization-failed",
        };
}
