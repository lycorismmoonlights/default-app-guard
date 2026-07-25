using DefaultAppGuard.Core;

namespace DefaultAppGuard.Tests;

[Trait("Category", "MainAlgorithmIntegration")]
public sealed class AssociationAuditServiceIntegrationTests
{
    [Fact]
    public void RealAudit_ReportsEveryDeclaredVideoAssociationIndividually()
    {
        Assert.True(OperatingSystem.IsWindows(), "Windows integration test.");

        var result = new AssociationAuditService().Audit(
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
}
