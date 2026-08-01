using DefaultAppGuard.Agent;
using DefaultAppGuard.Core;

namespace DefaultAppGuard.Tests;

public sealed class AgentReadinessEvaluatorTests
{
    private static readonly TimeSpan MaximumAuditAge =
        TimeSpan.FromMinutes(20);

    [Fact]
    public void Evaluate_AcceptsPrimaryEvidenceWhenAssociationsHaveDrift()
    {
        var status = CreateStatus(
            CreateAudit(
                CreateItem(
                    healthy: false,
                    querySource: AgentReadinessEvaluator.PrimaryQuery)));

        var readiness = Evaluate(status);

        Assert.True(readiness.Ready);
        Assert.Equal("ready", readiness.Code);
        Assert.Equal(1, readiness.PrimarySnapshotCount);
        Assert.Equal(1, readiness.DriftCount);
        Assert.True(readiness.AuditFresh);
    }

    [Fact]
    public void Evaluate_RejectsAnAgentBeforeItsFirstAudit()
    {
        var status = CreateStatus(audit: null);

        var readiness = Evaluate(status);

        Assert.False(readiness.Ready);
        Assert.Equal("audit-pending", readiness.Code);
    }

    [Fact]
    public void Evaluate_RejectsAnUnresolvedMediaPlayerTarget()
    {
        var audit = CreateAudit(
            CreateItem(true, AgentReadinessEvaluator.PrimaryQuery)) with
        {
            Target = new AssociationTarget("", "", null, null, []),
        };

        var readiness = Evaluate(CreateStatus(audit));

        Assert.False(readiness.Ready);
        Assert.Equal("target-unresolved", readiness.Code);
    }

    [Fact]
    public void Evaluate_RejectsAnyFailedPrimaryQueryRead()
    {
        var audit = CreateAudit(
            new AssociationAuditItem(
                ".mp4",
                false,
                null,
                "Primary COM query failed."));

        var readiness = Evaluate(CreateStatus(audit));

        Assert.False(readiness.Ready);
        Assert.Equal("primary-query-read-failed", readiness.Code);
        Assert.Equal(1, readiness.FailedReadCount);
    }

    [Fact]
    public void Evaluate_RejectsPartialPrimaryQueryCoverage()
    {
        var successful = CreateItem(
            true,
            AgentReadinessEvaluator.PrimaryQuery);
        var failed = new AssociationAuditItem(
            ".mkv",
            false,
            null,
            "Primary COM query failed.");
        var audit = CreateAudit(successful, failed) with
        {
            Target = new AssociationTarget(
                "Media.Player",
                "Microsoft.ZuneMusic_1.0_x64__8wekyb3d8bbwe",
                "Microsoft.ZuneMusic!App",
                "Media Player",
                [".mp4", ".mkv"]),
        };

        var readiness = Evaluate(CreateStatus(audit));

        Assert.False(readiness.Ready);
        Assert.Equal("primary-query-read-failed", readiness.Code);
        Assert.Equal(1, readiness.PrimarySnapshotCount);
        Assert.Equal(1, readiness.FailedReadCount);
    }

    [Fact]
    public void Evaluate_RejectsEvidenceFromAnotherQueryAlgorithm()
    {
        var audit = CreateAudit(CreateItem(true, "registry-fallback"));

        var readiness = Evaluate(CreateStatus(audit));

        Assert.False(readiness.Ready);
        Assert.Equal("non-primary-query-evidence", readiness.Code);
    }

    [Fact]
    public void Evaluate_RejectsARecordedRuntimeError()
    {
        var status = CreateStatus(
            CreateAudit(CreateItem(true, AgentReadinessEvaluator.PrimaryQuery)))
            with
        {
            ServiceState = "degraded",
            LastError = "Media Player package is unavailable.",
        };

        var readiness = Evaluate(status);

        Assert.False(readiness.Ready);
        Assert.Equal("service-not-running", readiness.Code);
    }

    [Fact]
    public void Evaluate_RejectsExpiredPrimaryQueryEvidence()
    {
        var now = DateTimeOffset.Parse("2026-08-01T12:00:00Z");
        var audit = CreateAudit(
            CreateItem(true, AgentReadinessEvaluator.PrimaryQuery)) with
        {
            AuditedAtUtc = now - MaximumAuditAge - TimeSpan.FromSeconds(1),
        };

        var readiness = AgentReadinessEvaluator.Evaluate(
            CreateStatus(audit),
            MaximumAuditAge,
            now);

        Assert.False(readiness.Ready);
        Assert.False(readiness.AuditFresh);
        Assert.Equal("audit-stale", readiness.Code);
        Assert.Equal(1201, readiness.AuditAgeSeconds);
        Assert.Equal(1200, readiness.MaximumAuditAgeSeconds);
    }

    [Fact]
    public void Evaluate_AcceptsEvidenceAtFreshnessBoundary()
    {
        var now = DateTimeOffset.Parse("2026-08-01T12:00:00Z");
        var audit = CreateAudit(
            CreateItem(true, AgentReadinessEvaluator.PrimaryQuery)) with
        {
            AuditedAtUtc = now - MaximumAuditAge,
        };

        var readiness = AgentReadinessEvaluator.Evaluate(
            CreateStatus(audit),
            MaximumAuditAge,
            now);

        Assert.True(readiness.Ready);
        Assert.True(readiness.AuditFresh);
        Assert.Equal("ready", readiness.Code);
        Assert.Equal(1200, readiness.AuditAgeSeconds);
    }

    private static AgentReadiness Evaluate(AgentStatus status)
    {
        return AgentReadinessEvaluator.Evaluate(
            status,
            MaximumAuditAge,
            status.Audit?.AuditedAtUtc ?? DateTimeOffset.UtcNow);
    }

    private static AgentStatus CreateStatus(AssociationAuditResult? audit)
    {
        return new AgentStatus(
            "running",
            AgentReadinessEvaluator.PrimaryMonitor,
            AgentReadinessEvaluator.PrimaryQuery,
            0,
            audit is null ? "none" : "startup",
            audit,
            null,
            DateTimeOffset.UtcNow);
    }

    private static AssociationAuditResult CreateAudit(
        params AssociationAuditItem[] items)
    {
        return new AssociationAuditResult(
            new AssociationTarget(
                "Media.Player",
                "Microsoft.ZuneMusic_1.0_x64__8wekyb3d8bbwe",
                "Microsoft.ZuneMusic!App",
                "Media Player",
                [".mp4"]),
            items,
            DateTimeOffset.UtcNow);
    }

    private static AssociationAuditItem CreateItem(
        bool healthy,
        string querySource)
    {
        return new AssociationAuditItem(
            ".mp4",
            healthy,
            new AssociationSnapshot(
                ".mp4",
                healthy ? "Media.Player" : "Another.Player",
                healthy ? "Media.Player" : "Another.Player",
                true,
                healthy ? "Media Player" : "Another Player",
                null,
                querySource),
            healthy ? null : "Association drift detected.");
    }
}
