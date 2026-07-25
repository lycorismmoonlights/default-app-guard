using DefaultAppGuard.Core;
using Microsoft.Win32;

namespace DefaultAppGuard.Agent;

public sealed class AssociationMonitorWorker(
    AssociationAuditCoordinator coordinator,
    AgentOptions options,
    ILogger<AssociationMonitorWorker> logger) : BackgroundService
{
    private const string FileExtsPath =
        @"Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts";
    private static readonly TimeSpan QuietPeriod =
        TimeSpan.FromMilliseconds(250);
    private static readonly TimeSpan RetryDelay =
        TimeSpan.FromSeconds(2);

    protected override async Task ExecuteAsync(
        CancellationToken stoppingToken)
    {
        var firstSubscription = true;

        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                using var monitor = new RegistryChangeMonitor(
                    RegistryHive.CurrentUser,
                    FileExtsPath,
                    watchSubtree: true);
                var pendingChange =
                    monitor.WaitForChangeAsync(stoppingToken);
                await AuditSafelyAsync(
                    firstSubscription ? "startup" : "monitor-recovery",
                    registryEvent: false,
                    stoppingToken);
                firstSubscription = false;

                while (!stoppingToken.IsCancellationRequested)
                {
                    using var periodicCancellation =
                        CancellationTokenSource.CreateLinkedTokenSource(
                            stoppingToken);
                    var periodicAudit = Task.Delay(
                        options.PeriodicAuditInterval,
                        periodicCancellation.Token);
                    var completed = await Task.WhenAny(
                        pendingChange,
                        periodicAudit);
                    if (completed == periodicAudit)
                    {
                        await periodicAudit;
                        await AuditSafelyAsync(
                            "periodic-readback",
                            registryEvent: false,
                            stoppingToken);
                        continue;
                    }

                    periodicCancellation.Cancel();
                    await ObserveCancellationAsync(periodicAudit);
                    await pendingChange;
                    pendingChange = await RearmAfterQuietPeriodAsync(
                        monitor,
                        stoppingToken);
                    await AuditSafelyAsync(
                        "registry-notification",
                        registryEvent: true,
                        stoppingToken);
                }
            }
            catch (OperationCanceledException) when (
                stoppingToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception exception)
            {
                var error =
                    $"{exception.GetType().Name}: {exception.Message}";
                await coordinator.RecordErrorAsync(error, stoppingToken);
                logger.LogError(
                    exception,
                    "Association monitor loop failed; retrying.");
                await Task.Delay(RetryDelay, stoppingToken);
            }
        }
    }

    private static async Task ObserveCancellationAsync(Task task)
    {
        try
        {
            await task;
        }
        catch (OperationCanceledException)
        {
        }
    }

    private static async Task<Task<RegistryChangeSignal>>
        RearmAfterQuietPeriodAsync(
            RegistryChangeMonitor monitor,
            CancellationToken cancellationToken)
    {
        while (true)
        {
            var pendingChange =
                monitor.WaitForChangeAsync(cancellationToken);
            var quietPeriod = Task.Delay(QuietPeriod, cancellationToken);
            var completed = await Task.WhenAny(
                pendingChange,
                quietPeriod);
            if (completed == quietPeriod)
            {
                await quietPeriod;
                return pendingChange;
            }

            await pendingChange;
        }
    }

    private async Task AuditSafelyAsync(
        string reason,
        bool registryEvent,
        CancellationToken cancellationToken)
    {
        try
        {
            await coordinator.AuditNowAsync(
                reason,
                cancellationToken,
                registryEvent);
        }
        catch (Exception exception) when (
            exception is not OperationCanceledException)
        {
            logger.LogError(exception, "Association audit failed.");
        }
    }
}
