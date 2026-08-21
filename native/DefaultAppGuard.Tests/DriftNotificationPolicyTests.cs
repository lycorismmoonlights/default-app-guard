using DefaultAppGuard.Agent;
using DefaultAppGuard.Core;

namespace DefaultAppGuard.Tests;

public sealed class DriftNotificationPolicyTests
{
    private static readonly DateTimeOffset Now =
        new(2026, 8, 1, 12, 0, 0, TimeSpan.Zero);

    [Fact]
    public void Evaluate_NotifiesImmediatelyForFirstDrift()
    {
        var policy = CreatePolicy();

        var notification = policy.Evaluate(
            CreateAudit(".mp4"),
            notificationsEnabled: true,
            channelAvailable: true,
            Now);

        Assert.NotNull(notification);
        Assert.Equal(1, notification.DriftCount);
        Assert.Equal([".mp4"], notification.Extensions);
    }

    [Fact]
    public void Evaluate_SuppressesSameDriftUntilRepeatInterval()
    {
        var policy = CreatePolicy();
        var audit = CreateAudit(".mp4");
        _ = policy.Evaluate(audit, true, true, Now);

        var early = policy.Evaluate(
            audit,
            true,
            true,
            Now.AddMinutes(29));
        var due = policy.Evaluate(
            audit,
            true,
            true,
            Now.AddMinutes(30));

        Assert.Null(early);
        Assert.NotNull(due);
    }

    [Fact]
    public void Evaluate_NotifiesImmediatelyWhenDriftSetChanges()
    {
        var policy = CreatePolicy();
        _ = policy.Evaluate(CreateAudit(".mp4"), true, true, Now);

        var notification = policy.Evaluate(
            CreateAudit(".mkv", ".mp4"),
            true,
            true,
            Now.AddSeconds(1));

        Assert.NotNull(notification);
        Assert.Equal([".mkv", ".mp4"], notification.Extensions);
    }

    [Fact]
    public void Evaluate_RearmsAfterHealthyOrDisabledState()
    {
        var policy = CreatePolicy();
        var drift = CreateAudit(".mp4");
        _ = policy.Evaluate(drift, true, true, Now);
        _ = policy.Evaluate(CreateAudit(), true, true, Now.AddSeconds(1));
        var afterHealthy = policy.Evaluate(
            drift,
            true,
            true,
            Now.AddSeconds(2));
        _ = policy.Evaluate(drift, false, true, Now.AddSeconds(3));
        var afterReenable = policy.Evaluate(
            drift,
            true,
            true,
            Now.AddSeconds(4));

        Assert.NotNull(afterHealthy);
        Assert.NotNull(afterReenable);
    }

    [Theory]
    [InlineData(false, true)]
    [InlineData(true, false)]
    public void Evaluate_DoesNotNotifyWhenDisabledOrUnavailable(
        bool enabled,
        bool available)
    {
        var notification = CreatePolicy().Evaluate(
            CreateAudit(".mp4"),
            enabled,
            available,
            Now);

        Assert.Null(notification);
    }

    private static DriftNotificationPolicy CreatePolicy() =>
        new(TimeSpan.FromMinutes(30));

    private static AssociationAuditResult CreateAudit(
        params string[] driftExtensions)
    {
        var extensions = driftExtensions.Length == 0
            ? new[] { ".mp4" }
            : driftExtensions;
        var driftSet = driftExtensions.ToHashSet(
            StringComparer.OrdinalIgnoreCase);
        var items = extensions.Select(extension =>
        {
            var healthy = !driftSet.Contains(extension);
            var expected = new AssociationExpectedHandler(
                extension,
                AssociationCatalog.VideoCategory,
                AssociationConstants.MediaPlayerTargetStrategy,
                "Media.Player",
                "Microsoft.ZuneMusic_1.0_x64__8wekyb3d8bbwe",
                "Media Player");
            return new AssociationAuditItem(
                extension,
                expected,
                healthy,
                null,
                healthy ? null : "Association drift detected.");
        }).ToArray();
        return new AssociationAuditResult(
            items.Select(item => item.Expected).ToArray(),
            items,
            Now);
    }
}
