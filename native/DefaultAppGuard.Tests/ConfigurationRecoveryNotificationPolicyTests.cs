using DefaultAppGuard.Agent;

namespace DefaultAppGuard.Tests;

public sealed class ConfigurationRecoveryNotificationPolicyTests
{
    private static readonly DateTimeOffset RecoveredAtUtc =
        new(2026, 8, 1, 12, 0, 0, TimeSpan.Zero);

    [Theory]
    [InlineData(
        GuardConfigurationStore.BackupRestoredCode,
        UserNotificationKinds.ConfigurationBackupRestored)]
    [InlineData(
        GuardConfigurationStore.DefaultsRestoredCode,
        UserNotificationKinds.ConfigurationDefaultsRestored)]
    public void Evaluate_ReturnsSupportedRecovery(
        string recoveryCode,
        string expectedKind)
    {
        var notification = new ConfigurationRecoveryNotificationPolicy()
            .Evaluate(CreateStatus(recoveryCode), true, true);

        Assert.NotNull(notification);
        Assert.Equal(expectedKind, notification.Kind);
        Assert.Equal(recoveryCode, notification.RecoveryCode);
        Assert.Equal(RecoveredAtUtc, notification.RecoveredAtUtc);
    }

    [Theory]
    [InlineData(false, true)]
    [InlineData(true, false)]
    public void Evaluate_SuppressesDisabledOrUnavailableChannel(
        bool notificationsEnabled,
        bool channelAvailable)
    {
        var notification = new ConfigurationRecoveryNotificationPolicy()
            .Evaluate(
                CreateStatus(GuardConfigurationStore.BackupRestoredCode),
                notificationsEnabled,
                channelAvailable);

        Assert.Null(notification);
    }

    [Fact]
    public void Evaluate_SuppressesNormalMalformedOrUnknownStatus()
    {
        var policy = new ConfigurationRecoveryNotificationPolicy();

        Assert.Null(policy.Evaluate(
            new GuardConfigurationPersistenceStatus(
                "primary",
                "backup",
                true,
                false,
                GuardConfigurationStore.NoRecoveryCode,
                null),
            true,
            true));
        Assert.Null(policy.Evaluate(
            new GuardConfigurationPersistenceStatus(
                "primary",
                "backup",
                true,
                true,
                GuardConfigurationStore.BackupRestoredCode,
                null),
            true,
            true));
        Assert.Null(policy.Evaluate(
            CreateStatus("unknown-recovery"),
            true,
            true));
    }

    [Fact]
    public void MarkQueued_DeduplicatesTheSameRecoveryEvent()
    {
        var policy = new ConfigurationRecoveryNotificationPolicy();
        var status = CreateStatus(
            GuardConfigurationStore.BackupRestoredCode);
        var first = policy.Evaluate(status, true, true);

        Assert.NotNull(first);
        policy.MarkQueued(first);

        Assert.Null(policy.Evaluate(status, true, true));
    }

    [Fact]
    public void Evaluate_RetriesUntilQueueSuccessIsMarked()
    {
        var policy = new ConfigurationRecoveryNotificationPolicy();
        var status = CreateStatus(
            GuardConfigurationStore.DefaultsRestoredCode);

        var first = policy.Evaluate(status, true, true);
        var retry = policy.Evaluate(status, true, true);

        Assert.NotNull(first);
        Assert.NotNull(retry);
        Assert.Equal(first.EventId, retry.EventId);
    }

    private static GuardConfigurationPersistenceStatus CreateStatus(
        string recoveryCode) =>
        new(
            "primary",
            "backup",
            true,
            true,
            recoveryCode,
            RecoveredAtUtc);
}
