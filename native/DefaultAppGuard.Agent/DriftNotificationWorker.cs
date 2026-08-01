namespace DefaultAppGuard.Agent;

public sealed class DriftNotificationWorker(
    AgentRuntimeState runtimeState,
    GuardConfigurationStore configurationStore,
    IUserNotificationSink notificationSink,
    ILogger<DriftNotificationWorker> logger) : BackgroundService
{
    private static readonly TimeSpan PollInterval = TimeSpan.FromSeconds(1);
    private static readonly TimeSpan RepeatInterval = TimeSpan.FromMinutes(30);
    private readonly DriftNotificationPolicy policy = new(RepeatInterval);

    protected override async Task ExecuteAsync(
        CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(PollInterval);
        while (await timer.WaitForNextTickAsync(stoppingToken))
        {
            var configuration = configurationStore.Snapshot();
            var channel = notificationSink.Snapshot();
            var notification = policy.Evaluate(
                runtimeState.Snapshot().Audit,
                configuration.NotificationsEnabled,
                channel.Available,
                DateTimeOffset.UtcNow);
            if (notification is null)
            {
                continue;
            }

            if (notificationSink.TryShowAssociationDrift(notification))
            {
                logger.LogInformation(
                    "Queued a system notification for {DriftCount} drifted associations.",
                    notification.DriftCount);
            }
            else
            {
                logger.LogWarning(
                    "The system notification channel became unavailable.");
            }
        }
    }
}
