using DefaultAppGuard.Core;

namespace DefaultAppGuard.Tests;

[Trait("Category", "MainAlgorithmIntegration")]
public sealed class WindowsAssociationIntegrationTests
{
    private static readonly string[] ProbeExtensions =
        [".mp4", ".mkv", ".avi", ".mov", ".wmv", ".webm", ".mpeg", ".ts"];

    [Fact]
    public void PrimaryComQuery_ReturnsEffectiveProgIdForEveryProbeExtension()
    {
        SkipUnlessWindows();
        var reader = new WindowsAssociationReader();

        var snapshots = reader.ReadMany(ProbeExtensions);

        Assert.All(snapshots, snapshot =>
        {
            Assert.False(string.IsNullOrWhiteSpace(snapshot.EffectiveProgId));
            Assert.Equal(
                "IApplicationAssociationRegistration.QueryCurrentDefault",
                snapshot.QuerySource);
            Assert.True(snapshot.RegistryEvidenceMatches);
            Assert.True(snapshot.UserChoiceHashPresent);
        });
    }

    [Fact]
    public void MediaPlayerResolver_FindsOneRealProgIdCommonToEveryProbeExtension()
    {
        SkipUnlessWindows();
        var target = new MediaPlayerTargetResolver().Resolve(ProbeExtensions);

        Assert.StartsWith("AppX", target.ProgId, StringComparison.OrdinalIgnoreCase);
        Assert.StartsWith(
            $"{AssociationConstants.MediaPlayerPackageName}_",
            target.PackageId,
            StringComparison.OrdinalIgnoreCase);
        var applicationName = Assert.IsType<string>(target.ApplicationName);
        Assert.False(string.IsNullOrWhiteSpace(applicationName));
        Assert.False(applicationName.StartsWith('@'));
        Assert.DoesNotContain(
            "ms-resource:",
            applicationName,
            StringComparison.OrdinalIgnoreCase);
        Assert.Equal(
            ProbeExtensions.Order(StringComparer.OrdinalIgnoreCase),
            target.SupportedExtensions);
    }

    [Fact]
    public void RealEffectivePlan_IsCurrentlySatisfiedByMediaPlayer()
    {
        SkipUnlessWindows();
        var reader = new WindowsAssociationReader();
        var target = new MediaPlayerTargetResolver().Resolve(ProbeExtensions);

        var plan = AssociationPlanEvaluator.Create(
            target,
            reader.ReadMany(ProbeExtensions));

        Assert.True(plan.IsSatisfied);
        Assert.All(plan.Items, item =>
        {
            Assert.True(item.IsMatch);
            Assert.True(item.RegistryEvidenceMatches);
        });
    }

    private static void SkipUnlessWindows()
    {
        Assert.True(OperatingSystem.IsWindows(), "Windows integration test.");
    }
}
