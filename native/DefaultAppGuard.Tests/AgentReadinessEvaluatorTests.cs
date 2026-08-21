using DefaultAppGuard.Agent;
using DefaultAppGuard.Core;

namespace DefaultAppGuard.Tests;

public sealed class AgentReadinessEvaluatorTests
{
    private static readonly TimeSpan MaximumAuditAge =
        TimeSpan.FromMinutes(20);

    [Fact]
    public void Evaluate_AcceptsPrimaryEvidenceEvenWhenAssociationsHaveDrift()
    {
        var readiness = Evaluate(CreateStatus(CreateAudit(
            CreateItem(".mp4", healthy: false),
            CreateItem(".pdf", healthy: true))));

        Assert.True(readiness.Ready);
        Assert.Equal("ready", readiness.Code);
        Assert.Equal(2, readiness.ExpectedHandlerCount);
        Assert.Equal(2, readiness.ResolvedHandlerCount);
        Assert.Equal(2, readiness.DistinctTargetCount);
        Assert.Equal(1, readiness.DriftCount);
    }

    [Fact]
    public void Evaluate_RejectsAnAgentBeforeItsFirstAudit()
    {
        var readiness = Evaluate(CreateStatus(audit: null));

        Assert.False(readiness.Ready);
        Assert.Equal("audit-pending", readiness.Code);
    }

    [Theory]
    [InlineData(".pdf", "", null)]
    [InlineData(".mp4", "Media.Player", null)]
    public void Evaluate_RejectsAnUnresolvedTarget(
        string extension,
        string progId,
        string? packageId)
    {
        var item = CreateItem(extension, healthy: true);
        var invalid = item.Expected with
        {
            ProgId = progId,
            PackageId = packageId,
        };
        var audit = new AssociationAuditResult(
            [invalid],
            [item with { Expected = invalid }],
            DateTimeOffset.UtcNow);

        var readiness = Evaluate(CreateStatus(audit));

        Assert.False(readiness.Ready);
        Assert.Equal("target-unresolved", readiness.Code);
    }

    [Fact]
    public void Evaluate_RejectsAnyFailedPrimaryQueryRead()
    {
        var expected = Expected(".mp4");
        var audit = new AssociationAuditResult(
            [expected],
            [new AssociationAuditItem(
                ".mp4",
                expected,
                false,
                null,
                "Primary COM query failed.")],
            DateTimeOffset.UtcNow);

        var readiness = Evaluate(CreateStatus(audit));

        Assert.False(readiness.Ready);
        Assert.Equal("primary-query-read-failed", readiness.Code);
        Assert.Equal(1, readiness.FailedReadCount);
    }

    [Fact]
    public void Evaluate_RejectsMismatchedMultiTargetScope()
    {
        var item = CreateItem(".mp4", healthy: true);
        var audit = new AssociationAuditResult(
            [item.Expected, Expected(".pdf")],
            [item],
            DateTimeOffset.UtcNow);

        var readiness = Evaluate(CreateStatus(audit));

        Assert.False(readiness.Ready);
        Assert.Equal("audit-scope-mismatch", readiness.Code);
    }

    [Fact]
    public void Evaluate_RejectsDuplicateExpectedScopeWithoutThrowing()
    {
        var item = CreateItem(".mp4", healthy: true);
        var audit = new AssociationAuditResult(
            [item.Expected, item.Expected],
            [item, item],
            DateTimeOffset.UtcNow);

        var readiness = Evaluate(CreateStatus(audit));

        Assert.False(readiness.Ready);
        Assert.Equal("audit-scope-mismatch", readiness.Code);
    }

    [Fact]
    public void Evaluate_RejectsEvidenceFromAnotherQueryAlgorithm()
    {
        var item = CreateItem(".pdf", healthy: true) with
        {
            Snapshot = Snapshot(".pdf", "Pdf.Reader", "registry-fallback"),
        };

        var readiness = Evaluate(CreateStatus(CreateAudit(item)));

        Assert.False(readiness.Ready);
        Assert.Equal("non-primary-query-evidence", readiness.Code);
    }

    [Fact]
    public void Evaluate_RejectsARecordedRuntimeError()
    {
        var status = CreateStatus(CreateAudit(
            CreateItem(".mp4", healthy: true))) with
        {
            ServiceState = "degraded",
            LastError = "Target resolution failed.",
        };

        var readiness = Evaluate(status);

        Assert.False(readiness.Ready);
        Assert.Equal("service-not-running", readiness.Code);
    }

    [Fact]
    public void Evaluate_RejectsExpiredPrimaryQueryEvidence()
    {
        var now = DateTimeOffset.Parse("2026-08-01T12:00:00Z");
        var audit = CreateAudit(CreateItem(".mp4", healthy: true)) with
        {
            AuditedAtUtc = now - MaximumAuditAge - TimeSpan.FromSeconds(1),
        };

        var readiness = AgentReadinessEvaluator.Evaluate(
            CreateStatus(audit),
            MaximumAuditAge,
            now);

        Assert.False(readiness.Ready);
        Assert.Equal("audit-stale", readiness.Code);
        Assert.Equal(1201, readiness.AuditAgeSeconds);
    }

    [Fact]
    public void Evaluate_AcceptsEvidenceAtFreshnessBoundary()
    {
        var now = DateTimeOffset.Parse("2026-08-01T12:00:00Z");
        var audit = CreateAudit(CreateItem(".mp4", healthy: true)) with
        {
            AuditedAtUtc = now - MaximumAuditAge,
        };

        var readiness = AgentReadinessEvaluator.Evaluate(
            CreateStatus(audit),
            MaximumAuditAge,
            now);

        Assert.True(readiness.Ready);
        Assert.Equal("ready", readiness.Code);
        Assert.Equal(1200, readiness.AuditAgeSeconds);
    }

    private static AgentReadiness Evaluate(AgentStatus status) =>
        AgentReadinessEvaluator.Evaluate(
            status,
            MaximumAuditAge,
            status.Audit?.AuditedAtUtc ?? DateTimeOffset.UtcNow);

    private static AgentStatus CreateStatus(AssociationAuditResult? audit) =>
        new(
            "running",
            AgentReadinessEvaluator.PrimaryMonitor,
            AgentReadinessEvaluator.PrimaryQuery,
            0,
            audit is null ? "none" : "startup",
            audit,
            null,
            DateTimeOffset.UtcNow);

    private static AssociationAuditResult CreateAudit(
        params AssociationAuditItem[] items) =>
        new(
            items.Select(item => item.Expected).ToArray(),
            items,
            DateTimeOffset.UtcNow);

    private static AssociationAuditItem CreateItem(
        string extension,
        bool healthy)
    {
        var expected = Expected(extension);
        var effectiveProgId = healthy
            ? expected.ProgId
            : "Unexpected.Handler";
        return new AssociationAuditItem(
            extension,
            expected,
            healthy,
            Snapshot(
                extension,
                effectiveProgId,
                AgentReadinessEvaluator.PrimaryQuery),
            healthy ? null : "Association drift detected.");
    }

    private static AssociationExpectedHandler Expected(string extension)
    {
        var video = string.Equals(
            AssociationCatalog.Get(extension).Category,
            AssociationCatalog.VideoCategory,
            StringComparison.Ordinal);
        return new AssociationExpectedHandler(
            extension,
            video
                ? AssociationCatalog.VideoCategory
                : AssociationCatalog.DocumentCategory,
            video
                ? AssociationConstants.MediaPlayerTargetStrategy
                : AssociationConstants.CapturedCurrentTargetStrategy,
            video ? "Media.Player" : "Pdf.Reader",
            video ? "Microsoft.ZuneMusic_1.0_x64__8wekyb3d8bbwe" : null,
            video ? "Media Player" : "PDF Reader");
    }

    private static AssociationSnapshot Snapshot(
        string extension,
        string progId,
        string querySource) =>
        new(
            extension,
            progId,
            progId,
            true,
            "Application",
            null,
            querySource);
}
