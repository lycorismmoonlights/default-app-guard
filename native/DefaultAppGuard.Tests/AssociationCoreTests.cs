using DefaultAppGuard.Core;

namespace DefaultAppGuard.Tests;

public sealed class AssociationCoreTests
{
    [Theory]
    [InlineData("MP4", ".mp4")]
    [InlineData(".WebM", ".webm")]
    [InlineData("  .mkv  ", ".mkv")]
    public void Normalize_ReturnsCanonicalExtension(string input, string expected)
    {
        Assert.Equal(expected, ExtensionName.Normalize(input));
    }

    [Theory]
    [InlineData("")]
    [InlineData(".")]
    [InlineData(".mp4\\bad")]
    [InlineData(".mp 4")]
    public void Normalize_RejectsInvalidExtension(string input)
    {
        Assert.ThrowsAny<ArgumentException>(() => ExtensionName.Normalize(input));
    }

    [Fact]
    public void Reader_DoesNotFallbackWhenEffectiveQueryFails()
    {
        var registry = new FakeRegistrySource();
        var reader = new WindowsAssociationReader(
            new ThrowingEffectiveQuery(),
            registry);

        Assert.Throws<InvalidOperationException>(() => reader.Read(".mp4"));
        Assert.Equal(0, registry.UserChoiceReadCount);
    }

    [Fact]
    public void Plan_ReportsEffectiveDriftEvenWhenRegistryEvidenceLooksHealthy()
    {
        var target = new AssociationTarget(
            "Media.Player",
            "Microsoft.ZuneMusic_1.0_x64__8wekyb3d8bbwe",
            null,
            "Media Player",
            [".mp4"]);
        var snapshot = new AssociationSnapshot(
            ".mp4",
            "Quark.Video",
            "Quark.Video",
            true,
            "Quark",
            null,
            "IApplicationAssociationRegistration.QueryCurrentDefault");

        var plan = AssociationPlanEvaluator.Create(target, [snapshot]);

        Assert.False(plan.IsSatisfied);
        Assert.False(plan.Items.Single().IsMatch);
        Assert.True(plan.Items.Single().RegistryEvidenceMatches);
    }

    private sealed class ThrowingEffectiveQuery : IEffectiveAssociationQuery
    {
        public string QueryEffectiveProgId(string extension)
        {
            throw new InvalidOperationException("Primary COM query failed.");
        }
    }

    private sealed class FakeRegistrySource : IAssociationRegistrySource
    {
        public int UserChoiceReadCount { get; private set; }

        public UserChoiceEvidence ReadUserChoice(string extension)
        {
            UserChoiceReadCount++;
            return new UserChoiceEvidence("Media.Player", true);
        }

        public ProgIdMetadata ReadProgIdMetadata(string progId)
        {
            return new ProgIdMetadata(progId, "Media Player", "Microsoft Corporation", null, null);
        }

        public IReadOnlyList<string> ReadOpenWithProgIds(string extension)
        {
            return [];
        }
    }
}
