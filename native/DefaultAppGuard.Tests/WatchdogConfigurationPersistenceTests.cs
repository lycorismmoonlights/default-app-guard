using System.Text.Json;
using DefaultAppGuard.Setup;

namespace DefaultAppGuard.Tests;

public sealed class WatchdogConfigurationPersistenceTests
{
    [Theory]
    [InlineData("none", false, null)]
    [InlineData("backup-restored", true, "2026-08-01T12:00:00Z")]
    [InlineData("defaults-restored", true, "2026-08-01T12:00:00Z")]
    public void TryMatchConfigurationPersistence_AcceptsSupportedState(
        string recoveryCode,
        bool recovered,
        string? recoveredAtUtc)
    {
        using var document = CreateHealth(
            recoveryCode,
            recovered,
            backupAvailable: true,
            recoveredAtUtc);

        Assert.True(WatchdogRunner.TryMatchConfigurationPersistence(
            document.RootElement));
    }

    [Theory]
    [InlineData("none", true, true, "2026-08-01T12:00:00Z")]
    [InlineData("backup-restored", false, true, null)]
    [InlineData("backup-restored", true, false, "2026-08-01T12:00:00Z")]
    [InlineData("backup-restored", true, true, "not-a-timestamp")]
    [InlineData("unknown", true, true, "2026-08-01T12:00:00Z")]
    public void TryMatchConfigurationPersistence_RejectsInvalidState(
        string recoveryCode,
        bool recovered,
        bool backupAvailable,
        string? recoveredAtUtc)
    {
        using var document = CreateHealth(
            recoveryCode,
            recovered,
            backupAvailable,
            recoveredAtUtc);

        Assert.False(WatchdogRunner.TryMatchConfigurationPersistence(
            document.RootElement));
    }

    private static JsonDocument CreateHealth(
        string recoveryCode,
        bool recovered,
        bool backupAvailable,
        string? recoveredAtUtc)
    {
        return JsonDocument.Parse(JsonSerializer.Serialize(new
        {
            configurationStorage = "runtime/guard-configuration.json",
            configurationBackupStorage =
                "runtime/guard-configuration.json.bak",
            configurationBackupAvailable = backupAvailable,
            configurationRecovered = recovered,
            configurationRecoveryCode = recoveryCode,
            configurationRecoveredAtUtc = recoveredAtUtc,
        }));
    }
}
