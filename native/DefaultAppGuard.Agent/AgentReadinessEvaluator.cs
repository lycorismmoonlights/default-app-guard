using DefaultAppGuard.Core;

namespace DefaultAppGuard.Agent;

public sealed record AgentReadiness(
    bool Ready,
    string Code,
    string ServiceState,
    string Query,
    string Monitor,
    string? TargetProgId,
    string? TargetPackageId,
    int AuditedExtensionCount,
    int PrimarySnapshotCount,
    int FailedReadCount,
    int HealthyCount,
    int DriftCount,
    string? LastError,
    DateTimeOffset UpdatedAtUtc);

public static class AgentReadinessEvaluator
{
    public const string PrimaryQuery =
        "IApplicationAssociationRegistration.QueryCurrentDefault";
    public const string PrimaryMonitor = "RegNotifyChangeKeyValue";

    public static AgentReadiness Evaluate(AgentStatus status)
    {
        ArgumentNullException.ThrowIfNull(status);

        var audit = status.Audit;
        var items = audit?.Items ?? [];
        var primarySnapshotCount = items.Count(item =>
            string.Equals(
                item.Snapshot?.QuerySource,
                PrimaryQuery,
                StringComparison.Ordinal));
        var nonPrimarySnapshotCount = items.Count(item =>
            item.Snapshot is not null &&
            !string.Equals(
                item.Snapshot.QuerySource,
                PrimaryQuery,
                StringComparison.Ordinal));
        var failedReadCount = items.Count(item => item.Snapshot is null);

        var code = GetReadinessCode(
            status,
            audit,
            primarySnapshotCount,
            nonPrimarySnapshotCount,
            failedReadCount);

        return new AgentReadiness(
            code == "ready",
            code,
            status.ServiceState,
            status.QueryAlgorithm,
            status.MonitorAlgorithm,
            audit?.Target.ProgId,
            audit?.Target.PackageId,
            items.Count,
            primarySnapshotCount,
            failedReadCount,
            audit?.HealthyCount ?? 0,
            audit?.DriftCount ?? 0,
            status.LastError,
            status.UpdatedAtUtc);
    }

    private static string GetReadinessCode(
        AgentStatus status,
        AssociationAuditResult? audit,
        int primarySnapshotCount,
        int nonPrimarySnapshotCount,
        int failedReadCount)
    {
        if (!string.Equals(
                status.QueryAlgorithm,
                PrimaryQuery,
                StringComparison.Ordinal))
        {
            return "primary-query-mismatch";
        }

        if (!string.Equals(
                status.MonitorAlgorithm,
                PrimaryMonitor,
                StringComparison.Ordinal))
        {
            return "primary-monitor-mismatch";
        }

        if (!string.Equals(
                status.ServiceState,
                "running",
                StringComparison.Ordinal))
        {
            return "service-not-running";
        }

        if (!string.IsNullOrWhiteSpace(status.LastError))
        {
            return "runtime-error";
        }

        if (audit is null)
        {
            return "audit-pending";
        }

        if (string.IsNullOrWhiteSpace(audit.Target.ProgId) ||
            string.IsNullOrWhiteSpace(audit.Target.PackageId) ||
            audit.Target.SupportedExtensions.Count == 0)
        {
            return "target-unresolved";
        }

        if (audit.Items.Count == 0)
        {
            return "audit-empty";
        }

        if (audit.Target.SupportedExtensions.Count != audit.Items.Count)
        {
            return "audit-scope-mismatch";
        }

        if (nonPrimarySnapshotCount != 0)
        {
            return "non-primary-query-evidence";
        }

        if (failedReadCount != 0)
        {
            return "primary-query-read-failed";
        }

        return primarySnapshotCount == audit.Items.Count
            ? "ready"
            : "primary-query-evidence-incomplete";
    }
}
