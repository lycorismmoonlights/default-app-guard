using DefaultAppGuard.Core;

namespace DefaultAppGuard.Tests;

[Trait("Category", "MainAlgorithmIntegration")]
public sealed class AssociationAuditServiceIntegrationTests
{
    [Fact]
    public void RealAudit_ReportsEveryDeclaredVideoAssociationIndividually()
    {
        Assert.True(OperatingSystem.IsWindows(), "Windows integration test.");

        var result = new AssociationAuditService().AuditMediaPlayer(
            AssociationConstants.VideoExtensions);

        Assert.Equal(AssociationConstants.VideoExtensions.Count, result.Items.Count);
        Assert.Equal(result.Items.Count, result.HealthyCount);
        Assert.Equal(0, result.DriftCount);
        Assert.True(result.Healthy);
        Assert.All(result.Items, item =>
        {
            Assert.True(item.Healthy);
            Assert.NotNull(item.Snapshot);
            Assert.Null(item.Error);
            Assert.Equal(
                "IApplicationAssociationRegistration.QueryCurrentDefault",
                item.Snapshot.QuerySource);
        });
    }

    [Fact]
    public void RealAudit_CapturesAndVerifiesNonVideoAssociationsThroughCom()
    {
        Assert.True(OperatingSystem.IsWindows(), "Windows integration test.");
        string[] requested = [".pdf", ".txt", ".jpg", ".png", ".mp3", ".zip"];
        var factory = new AssociationRuleFactory();
        var rules = requested.Select(factory.CaptureCurrent).ToArray();

        var result = new AssociationAuditService().Audit(rules);

        Assert.Equal(requested.Order(), result.Items.Select(
            item => item.Extension));
        Assert.All(result.Items, item =>
        {
            Assert.True(item.Healthy);
            Assert.NotNull(item.Snapshot);
            Assert.Equal(
                AssociationConstants.PrimaryQueryAlgorithm,
                item.Snapshot.QuerySource);
            Assert.Equal(
                AssociationConstants.CapturedCurrentTargetStrategy,
                item.Expected.TargetStrategy);
        });
        Assert.True(
            result.ExpectedHandlers
                .Select(handler => handler.ProgId)
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .Count() >= 3,
            "The real test set should exercise multiple default handlers.");
    }
}
