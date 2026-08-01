using DefaultAppGuard.Setup;

namespace DefaultAppGuard.Tests;

public sealed class WatchdogTelemetryTests
{
    [Fact]
    public void NextRecoveryFailure_UsesBoundedExponentialBackoff()
    {
        var now = DateTimeOffset.Parse("2026-08-01T00:00:00Z");
        WatchdogStatus? previous = null;
        var expectedMinutes = new[] { 5, 10, 20, 40, 60, 60 };

        for (var index = 0; index < expectedMinutes.Length; index++)
        {
            var failure = WatchdogTelemetry.NextRecoveryFailure(previous, now);
            Assert.Equal(index + 1, failure.FailureCount);
            Assert.Equal(
                now.AddMinutes(expectedMinutes[index]),
                failure.NextAllowedAtUtc);
            previous = CreateStatus(
                now,
                failure.FailureCount,
                failure.NextAllowedAtUtc);
        }
    }

    [Fact]
    public void ShouldDeferRecovery_AcceptsCurrentBoundedFailure()
    {
        var now = DateTimeOffset.Parse("2026-08-01T00:05:00Z");
        var previous = CreateStatus(
            now.AddMinutes(-1),
            failureCount: 2,
            nextAllowedAtUtc: now.AddMinutes(9));

        Assert.True(WatchdogTelemetry.ShouldDeferRecovery(previous, now));
    }

    [Fact]
    public void ShouldDeferRecovery_RejectsStaleOrUnboundedInput()
    {
        var now = DateTimeOffset.Parse("2026-08-01T02:00:00Z");
        var stale = CreateStatus(
            now.AddHours(-3),
            failureCount: 3,
            nextAllowedAtUtc: now.AddMinutes(5));
        var excessive = CreateStatus(
            now.AddMinutes(-1),
            failureCount: 3,
            nextAllowedAtUtc: now.AddHours(2));

        Assert.False(WatchdogTelemetry.ShouldDeferRecovery(stale, now));
        Assert.False(WatchdogTelemetry.ShouldDeferRecovery(excessive, now));
    }

    [Fact]
    public void GetLastHealthyProcessId_UsesOnlySuccessfulStatus()
    {
        var now = DateTimeOffset.Parse("2026-08-01T02:00:00Z");
        var successful = new WatchdogStatus(
            WatchdogTelemetry.SchemaVersion,
            WatchdogTelemetry.HealthyOutcome,
            now,
            now,
            0,
            true,
            true,
            false,
            null,
            456,
            0,
            null,
            null);
        var failed = successful with
        {
            Outcome = WatchdogTelemetry.FailedOutcome,
            ExitCode = 24,
        };

        Assert.Equal(456, WatchdogTelemetry.GetLastHealthyProcessId(successful));
        Assert.Null(WatchdogTelemetry.GetLastHealthyProcessId(failed));
    }

    [Fact]
    public void SerializeAndDeserialize_RoundTripsRedactedStatus()
    {
        var now = DateTimeOffset.Parse("2026-08-01T03:00:00Z");
        var status = new WatchdogStatus(
            WatchdogTelemetry.SchemaVersion,
            WatchdogTelemetry.RecoveredOutcome,
            now,
            now.AddSeconds(1),
            0,
            true,
            false,
            true,
            123,
            456,
            0,
            null,
            null);

        var content = WatchdogTelemetry.Serialize(status);

        Assert.Equal(status, WatchdogTelemetry.TryDeserialize(content));
        Assert.DoesNotContain("exception", content, StringComparison.OrdinalIgnoreCase);
        Assert.Equal(
            @"Software\DefaultAppGuard\Watchdog",
            WatchdogTelemetry.RegistrySubKeyPath);
        Assert.Equal("StatusJson", WatchdogTelemetry.RegistryValueName);
    }

    [Fact]
    public void TryDeserialize_ReturnsNullForMalformedStatus()
    {
        Assert.Null(WatchdogTelemetry.TryDeserialize("{not-json"));
    }

    private static WatchdogStatus CreateStatus(
        DateTimeOffset completedAtUtc,
        int failureCount,
        DateTimeOffset nextAllowedAtUtc)
    {
        return new WatchdogStatus(
            WatchdogTelemetry.SchemaVersion,
            WatchdogTelemetry.FailedOutcome,
            completedAtUtc.AddSeconds(-1),
            completedAtUtc,
            24,
            true,
            false,
            true,
            123,
            null,
            failureCount,
            nextAllowedAtUtc,
            "recovery-health-check");
    }
}
