using DefaultAppGuard.Core;

namespace DefaultAppGuard.Agent;

public sealed record AgentStatus(
    string ServiceState,
    string MonitorAlgorithm,
    string QueryAlgorithm,
    long RegistryEventCount,
    string LastAuditReason,
    AssociationAuditResult? Audit,
    string? LastError,
    DateTimeOffset UpdatedAtUtc);

public sealed class AgentRuntimeState
{
    private readonly object gate = new();
    private AgentStatus current = new(
        "starting",
        "RegNotifyChangeKeyValue",
        "IApplicationAssociationRegistration.QueryCurrentDefault",
        0,
        "none",
        null,
        null,
        DateTimeOffset.UtcNow);

    public AgentStatus Snapshot()
    {
        lock (gate)
        {
            return current;
        }
    }

    public AgentStatus SetAudit(
        AssociationAuditResult audit,
        string reason,
        bool registryEvent)
    {
        lock (gate)
        {
            current = current with
            {
                ServiceState = "running",
                RegistryEventCount = current.RegistryEventCount +
                                     (registryEvent ? 1 : 0),
                LastAuditReason = reason,
                Audit = audit,
                LastError = null,
                UpdatedAtUtc = DateTimeOffset.UtcNow,
            };
            return current;
        }
    }

    public AgentStatus SetError(string error)
    {
        lock (gate)
        {
            current = current with
            {
                ServiceState = "degraded",
                LastError = error,
                UpdatedAtUtc = DateTimeOffset.UtcNow,
            };
            return current;
        }
    }
}
