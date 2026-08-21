using DefaultAppGuard.Core;

namespace DefaultAppGuard.Agent;

public sealed record AgentReadiness(
    bool Ready,
    string Code,
    string ServiceState,
    string Query,
    string Monitor,
    int ExpectedHandlerCount,
    int ResolvedHandlerCount,
    int DistinctTargetCount,
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
        AssociationConstants.PrimaryQueryAlgorithm;
    public const string PrimaryMonitor =
        AssociationConstants.PrimaryMonitorAlgorithm;

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
            audit?.ExpectedHandlers.Count ?? 0,
            CountResolvedHandlers(audit),
            audit?.ExpectedHandlers
                .Select(handler => handler.ProgId)
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .Count() ?? 0,
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

        if (audit.ExpectedHandlers.Count == 0 ||
            audit.ExpectedHandlers.Any(handler =>
                string.IsNullOrWhiteSpace(handler.ProgId) ||
                !IsValidTarget(handler)))
        {
            return "target-unresolved";
        }

        if (audit.Items.Count == 0)
        {
            return "audit-empty";
        }

        if (!AuditScopesMatch(audit))
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

    private static int CountResolvedHandlers(AssociationAuditResult? audit) =>
        audit?.ExpectedHandlers.Count(handler =>
            !string.IsNullOrWhiteSpace(handler.ProgId) &&
            IsValidTarget(handler)) ?? 0;

    private static bool IsValidTarget(AssociationExpectedHandler handler)
    {
        if (string.Equals(
            handler.TargetStrategy,
            AssociationConstants.MediaPlayerTargetStrategy,
            StringComparison.Ordinal))
        {
            return !string.IsNullOrWhiteSpace(handler.PackageId);
        }

        return string.Equals(
            handler.TargetStrategy,
            AssociationConstants.CapturedCurrentTargetStrategy,
            StringComparison.Ordinal);
    }

    private static bool AuditScopesMatch(AssociationAuditResult audit)
    {
        if (audit.ExpectedHandlers.Count != audit.Items.Count)
        {
            return false;
        }

        var handlers = new Dictionary<string, AssociationExpectedHandler>(
            StringComparer.OrdinalIgnoreCase);
        foreach (var handler in audit.ExpectedHandlers)
        {
            if (!handlers.TryAdd(handler.Extension, handler))
            {
                return false;
            }
        }

        var auditedExtensions = new HashSet<string>(
            StringComparer.OrdinalIgnoreCase);
        return audit.Items.All(item =>
            auditedExtensions.Add(item.Extension) &&
            handlers.TryGetValue(item.Extension, out var handler) &&
            item.Expected == handler);
    }
}
