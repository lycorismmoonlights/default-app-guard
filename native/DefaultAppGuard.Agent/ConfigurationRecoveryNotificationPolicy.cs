namespace DefaultAppGuard.Agent;

public sealed record ConfigurationRecoveryNotification(
    string EventId,
    string Kind,
    string RecoveryCode,
    DateTimeOffset RecoveredAtUtc);

public sealed class ConfigurationRecoveryNotificationPolicy
{
    private string? lastQueuedEventId;

    public ConfigurationRecoveryNotification? Evaluate(
        GuardConfigurationPersistenceStatus persistence,
        bool notificationsEnabled,
        bool channelAvailable)
    {
        ArgumentNullException.ThrowIfNull(persistence);
        if (!notificationsEnabled ||
            !channelAvailable ||
            !persistence.Recovered ||
            persistence.RecoveredAtUtc is null)
        {
            return null;
        }

        var kind = persistence.RecoveryCode switch
        {
            GuardConfigurationStore.BackupRestoredCode =>
                UserNotificationKinds.ConfigurationBackupRestored,
            GuardConfigurationStore.DefaultsRestoredCode =>
                UserNotificationKinds.ConfigurationDefaultsRestored,
            _ => null,
        };
        if (kind is null)
        {
            return null;
        }

        var eventId = $"{persistence.RecoveryCode}:" +
            persistence.RecoveredAtUtc.Value.UtcTicks;
        if (string.Equals(
            eventId,
            lastQueuedEventId,
            StringComparison.Ordinal))
        {
            return null;
        }

        return new ConfigurationRecoveryNotification(
            eventId,
            kind,
            persistence.RecoveryCode,
            persistence.RecoveredAtUtc.Value);
    }

    public void MarkQueued(ConfigurationRecoveryNotification notification)
    {
        ArgumentNullException.ThrowIfNull(notification);
        lastQueuedEventId = notification.EventId;
    }
}
