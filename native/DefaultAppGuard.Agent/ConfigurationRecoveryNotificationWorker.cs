namespace DefaultAppGuard.Agent;

public sealed class ConfigurationRecoveryNotificationWorker(
    GuardConfigurationStore configurationStore,
    IUserNotificationSink notificationSink,
    ILogger<ConfigurationRecoveryNotificationWorker> logger) :
    BackgroundService
{
    private static readonly TimeSpan PollInterval = TimeSpan.FromSeconds(1);
    private readonly ConfigurationRecoveryNotificationPolicy policy = new();

    protected override async Task ExecuteAsync(
        CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(PollInterval);
        while (await timer.WaitForNextTickAsync(stoppingToken))
        {
            var channel = notificationSink.Snapshot();
            var notification = policy.Evaluate(
                configurationStore.SnapshotPersistenceStatus(),
                configurationStore.Snapshot().NotificationsEnabled,
                channel.Available);
            if (notification is null)
            {
                continue;
            }

            if (notificationSink.TryShowConfigurationRecovery(notification))
            {
                policy.MarkQueued(notification);
                logger.LogInformation(
                    "Queued a {NotificationKind} system notification.",
                    notification.Kind);
            }
            else
            {
                logger.LogWarning(
                    "The configuration recovery notification was not queued.");
            }
        }
    }
}
