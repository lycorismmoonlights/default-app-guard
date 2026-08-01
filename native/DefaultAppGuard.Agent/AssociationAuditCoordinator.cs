using DefaultAppGuard.Core;
using System.Text.Json;

namespace DefaultAppGuard.Agent;

public sealed class AssociationAuditCoordinator(
    AssociationAuditService auditService,
    AgentRuntimeState state,
    AgentOptions options,
    GuardConfigurationStore configurationStore,
    ILogger<AssociationAuditCoordinator> logger)
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
    };

    private readonly SemaphoreSlim auditGate = new(1, 1);

    public async Task<AgentStatus> AuditNowAsync(
        string reason,
        CancellationToken cancellationToken,
        bool registryEvent = false)
    {
        await auditGate.WaitAsync(cancellationToken);
        try
        {
            var audit = await Task.Run(
                () => auditService.Audit(
                    configurationStore
                        .Snapshot()
                        .ProtectedVideoExtensions),
                cancellationToken);
            var snapshot = state.SetAudit(audit, reason, registryEvent);
            await WriteStateAsync(snapshot, cancellationToken);
            logger.LogInformation(
                "Association audit completed for {AuditReason}: " +
                "healthy={AuditHealthy}, healthyCount={HealthyCount}, " +
                "driftCount={DriftCount}, registryEvent={RegistryEvent}.",
                reason,
                audit.Healthy,
                audit.HealthyCount,
                audit.DriftCount,
                registryEvent);
            return snapshot;
        }
        catch (Exception exception) when (
            exception is not OperationCanceledException)
        {
            var snapshot = state.SetError(
                $"{exception.GetType().Name}: {exception.Message}");
            await WriteStateAsync(snapshot, cancellationToken);
            logger.LogError(
                exception,
                "Association audit failed for {AuditReason}.",
                reason);
            throw;
        }
        finally
        {
            auditGate.Release();
        }
    }

    public async Task<AgentStatus> RecordErrorAsync(
        string error,
        CancellationToken cancellationToken)
    {
        var snapshot = state.SetError(error);
        await WriteStateAsync(snapshot, cancellationToken);
        return snapshot;
    }

    private async Task WriteStateAsync(
        AgentStatus snapshot,
        CancellationToken cancellationToken)
    {
        await DurableJsonFile.WriteAsync(
            options.StatePath,
            snapshot,
            JsonOptions,
            cancellationToken);
    }
}
