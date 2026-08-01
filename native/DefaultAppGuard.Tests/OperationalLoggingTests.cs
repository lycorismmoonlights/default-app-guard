using DefaultAppGuard.Agent;

namespace DefaultAppGuard.Tests;

public sealed class OperationalLoggingTests : IDisposable
{
    private readonly string testDirectory = Path.Combine(
        Path.GetTempPath(),
        $"DefaultAppGuard-OperationalLogging-{Guid.NewGuid():N}");

    [Fact]
    public void Start_WritesBoundedCompactEventStream()
    {
        var options = AgentOptions.Parse(
        [
            "--state",
            Path.Combine(testDirectory, "runtime", "agent-status.json"),
            "--config",
            Path.Combine(
                testDirectory,
                "runtime",
                "guard-configuration.json"),
        ]);

        using (var session = OperationalLoggingSession.Start(options))
        {
            session.Logger.Information(
                "Operational logging test event {EventNumber}.",
                1);

            var status = session.Health.Snapshot();
            Assert.True(status.Available);
            Assert.Equal("Serilog.Sinks.File", status.Channel);
            Assert.Equal("CLEF", status.Format);
            Assert.Equal(2 * 1024 * 1024, status.FileSizeLimitBytes);
            Assert.Equal(7, status.RetainedFileCountLimit);
            Assert.Null(status.LastErrorCode);
        }

        var files = Directory.GetFiles(
            Path.Combine(testDirectory, "runtime", "logs"),
            "agent-*.clef");
        var file = Assert.Single(files);
        var lines = File.ReadAllLines(file);
        Assert.True(lines.Length >= 2);
        Assert.All(lines, line => Assert.StartsWith("{", line));
        Assert.Contains(lines, line => line.Contains(
            "Operational logging test event",
            StringComparison.Ordinal));
    }

    [Fact]
    public void Start_WhenLogDirectoryCannotBeCreated_DegradesWithoutThrowing()
    {
        var runtimeDirectory = Path.Combine(testDirectory, "runtime");
        Directory.CreateDirectory(runtimeDirectory);
        File.WriteAllText(Path.Combine(runtimeDirectory, "logs"), "occupied");
        var options = AgentOptions.Parse(
        [
            "--state",
            Path.Combine(runtimeDirectory, "agent-status.json"),
            "--config",
            Path.Combine(runtimeDirectory, "guard-configuration.json"),
        ]);

        using var session = OperationalLoggingSession.Start(options);

        var status = session.Health.Snapshot();
        Assert.False(status.Available);
        Assert.Equal("io-error", status.LastErrorCode);
        session.Logger.Information(
            "A disabled log sink must not throw into the main algorithm.");
    }

    public void Dispose()
    {
        if (Directory.Exists(testDirectory))
        {
            Directory.Delete(testDirectory, recursive: true);
        }
    }
}
