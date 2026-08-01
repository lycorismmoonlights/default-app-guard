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
    bool AuditFresh,
    long AuditAgeSeconds,
    long MaximumAuditAgeSeconds,
    DateTimeOffset? AuditedAtUtc,
    string? LastError,
    DateTimeOffset UpdatedAtUtc);

public static class AgentReadinessEvaluator
{
    public const string PrimaryQuery =
        "IApplicationAssociationRegistration.QueryCurrentDefault";
    public const string PrimaryMonitor = "RegNotifyChangeKeyValue";

    public static AgentReadiness Evaluate(
        AgentStatus status,
        TimeSpan maximumAuditAge,
        DateTimeOffset? now = null)
    {
        ArgumentNullException.ThrowIfNull(status);
        if (maximumAuditAge <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(
                nameof(maximumAuditAge),
                "Maximum audit age must be positive.");
        }

        var audit = status.Audit;
        var items = audit?.Items ?? [];
        var evaluatedAtUtc = now ?? DateTimeOffset.UtcNow;
        var auditAge = audit is null
            ? TimeSpan.MaxValue
            : evaluatedAtUtc - audit.AuditedAtUtc;
        if (auditAge < TimeSpan.Zero)
        {
            auditAge = TimeSpan.Zero;
        }
        var auditFresh = audit is not null && auditAge <= maximumAuditAge;
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
            failedReadCount,
            auditFresh);

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
            auditFresh,
            audit is null
                ? -1
                : (long)Math.Ceiling(auditAge.TotalSeconds),
            (long)Math.Ceiling(maximumAuditAge.TotalSeconds),
            audit?.AuditedAtUtc,
            status.LastError,
            status.UpdatedAtUtc);
    }

    private static string GetReadinessCode(
        AgentStatus status,
        AssociationAuditResult? audit,
        int primarySnapshotCount,
        int nonPrimarySnapshotCount,
        int failedReadCount,
        bool auditFresh)
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

        if (!auditFresh)
        {
            return "audit-stale";
        }

        return primarySnapshotCount == audit.Items.Count
            ? "ready"
            : "primary-query-evidence-incomplete";
    }
}
