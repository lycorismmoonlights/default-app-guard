using DefaultAppGuard.Core;
using System.Runtime.InteropServices;

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
    public void DisplayNameResolver_PreservesPlainApplicationName()
    {
        var resolver = new WindowsApplicationDisplayNameResolver();

        Assert.Equal("PDF Reader", resolver.Resolve("  PDF Reader  "));
    }

    [Fact]
    public void DisplayNameResolver_RejectsBareResourceReference()
    {
        var resolver = new WindowsApplicationDisplayNameResolver();

        Assert.Null(resolver.Resolve("ms-resource:AppName"));
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

    [Fact]
    public void CaptureCurrent_RejectsNonPrimaryEvidence()
    {
        var reader = new FakeSnapshotReader(
            Snapshot(".pdf", "Pdf.Reader", "registry-fallback"));

        var exception = Assert.Throws<InvalidOperationException>(
            () => new AssociationRuleFactory(reader).CaptureCurrent(".pdf"));

        Assert.Contains("primary COM query", exception.Message);
    }

    [Fact]
    public void CaptureCurrent_RejectsSnapshotForAnotherExtension()
    {
        var reader = new FakeSnapshotReader(
            Snapshot(".txt", "Text.Editor", AssociationConstants.PrimaryQueryAlgorithm));

        var exception = Assert.Throws<InvalidOperationException>(
            () => new AssociationRuleFactory(reader).CaptureCurrent(".pdf"));

        Assert.Contains("while capturing .pdf", exception.Message);
    }

    [Theory]
    [InlineData(
        ".mp4",
        AssociationCatalog.VideoCategory,
        AssociationConstants.CapturedCurrentTargetStrategy)]
    [InlineData(
        ".pdf",
        AssociationCatalog.DocumentCategory,
        AssociationConstants.MediaPlayerTargetStrategy)]
    public void Audit_RejectsTargetStrategyOutsideItsCategory(
        string extension,
        string category,
        string targetStrategy)
    {
        var service = new AssociationAuditService(
            new FakeSnapshotReader(),
            new FakeMediaPlayerTargetResolver());
        var rule = new ProtectedAssociationRule(
            extension,
            category,
            targetStrategy,
            "Captured.Handler",
            null,
            "Captured application",
            DateTimeOffset.UtcNow);

        Assert.Throws<InvalidDataException>(() => service.Audit([rule]));
    }

    [Fact]
    public void Audit_RejectsIncompleteCapturedBaseline()
    {
        var service = new AssociationAuditService(
            new FakeSnapshotReader(),
            new FakeMediaPlayerTargetResolver());
        var rule = new ProtectedAssociationRule(
            ".pdf",
            AssociationCatalog.DocumentCategory,
            AssociationConstants.CapturedCurrentTargetStrategy,
            "Pdf.Reader",
            null,
            "PDF Reader",
            null);

        Assert.Throws<InvalidDataException>(() => service.Audit([rule]));
    }

    [Fact]
    public void Audit_EvaluatesEachRuleAgainstItsOwnExpectedHandler()
    {
        var reader = new FakeSnapshotReader(
            Snapshot(
                ".mp4",
                "Media.Player",
                AssociationConstants.PrimaryQueryAlgorithm),
            Snapshot(
                ".pdf",
                "Unexpected.Reader",
                AssociationConstants.PrimaryQueryAlgorithm));
        var service = new AssociationAuditService(
            reader,
            new FakeMediaPlayerTargetResolver());
        ProtectedAssociationRule[] rules =
        [
            new(
                ".mp4",
                AssociationCatalog.VideoCategory,
                AssociationConstants.MediaPlayerTargetStrategy,
                null,
                null,
                "Media Player",
                null),
            new(
                ".pdf",
                AssociationCatalog.DocumentCategory,
                AssociationConstants.CapturedCurrentTargetStrategy,
                "Pdf.Reader",
                null,
                "PDF Reader",
                DateTimeOffset.UtcNow),
        ];

        var result = service.Audit(rules);

        Assert.Equal(2, result.ExpectedHandlers.Count);
        Assert.True(result.Items.Single(item =>
            item.Extension == ".mp4").Healthy);
        Assert.False(result.Items.Single(item =>
            item.Extension == ".pdf").Healthy);
        Assert.Equal(1, result.HealthyCount);
        Assert.Equal(1, result.DriftCount);
    }

    [Fact]
    public void Audit_RecordsAnExpectedPrimaryReadFailurePerExtension()
    {
        var service = new AssociationAuditService(
            new ThrowingSnapshotReader(new InvalidOperationException("COM failed.")),
            new FakeMediaPlayerTargetResolver());

        var result = service.Audit([
            new AssociationRuleFactory().CreateDefault(".mp4"),
        ]);

        var item = Assert.Single(result.Items);
        Assert.False(item.Healthy);
        Assert.Null(item.Snapshot);
        Assert.Contains("InvalidOperationException", item.Error);
    }

    [Fact]
    public void Audit_RejectsNonPrimarySnapshotEvidence()
    {
        var service = new AssociationAuditService(
            new FakeSnapshotReader(Snapshot(
                ".mp4",
                "Media.Player",
                "registry-fallback")),
            new FakeMediaPlayerTargetResolver());

        var result = service.Audit([
            new AssociationRuleFactory().CreateDefault(".mp4"),
        ]);

        var item = Assert.Single(result.Items);
        Assert.False(item.Healthy);
        Assert.Null(item.Snapshot);
        Assert.Contains("primary COM query", item.Error);
    }

    [Fact]
    public void Audit_RejectsSnapshotForAnotherExtension()
    {
        var service = new AssociationAuditService(
            new FakeSnapshotReader(Snapshot(
                ".txt",
                "Media.Player",
                AssociationConstants.PrimaryQueryAlgorithm)),
            new FakeMediaPlayerTargetResolver());

        var result = service.Audit([
            new AssociationRuleFactory().CreateDefault(".mp4"),
        ]);

        var item = Assert.Single(result.Items);
        Assert.False(item.Healthy);
        Assert.Null(item.Snapshot);
        Assert.Contains("while auditing .mp4", item.Error);
    }

    [Fact]
    public void Audit_DoesNotHideUnexpectedImplementationFailure()
    {
        var service = new AssociationAuditService(
            new ThrowingSnapshotReader(new NotSupportedException("Bug.")),
            new FakeMediaPlayerTargetResolver());

        Assert.Throws<NotSupportedException>(() => service.Audit([
            new AssociationRuleFactory().CreateDefault(".mp4"),
        ]));
    }

    [Fact]
    public void Reader_PreservesNoAssociationComResultWithoutReadingRegistry()
    {
        var registry = new FakeRegistrySource();
        var reader = new WindowsAssociationReader(
            new HResultEffectiveQuery(AssociationSnapshot.NoAssociationHResult), registry);

        var snapshot = reader.Read(".mp4");

        Assert.True(snapshot.NoAssociation);
        Assert.True(snapshot.PrimaryQueryCompleted);
        Assert.Equal(AssociationSnapshot.NoAssociationHResult, snapshot.QueryHResult);
        Assert.Empty(snapshot.EffectiveProgId);
        Assert.Null(snapshot.UserChoiceProgId);
        Assert.Equal(0, registry.UserChoiceReadCount);
        Assert.Throws<InvalidOperationException>(() =>
            new AssociationRuleFactory(reader).CaptureCurrent(".pdf"));
    }

    [Theory]
    [InlineData(unchecked((int)0x80070005))]
    [InlineData(unchecked((int)0x80004005))]
    public void Reader_DoesNotTreatOtherComFailuresAsMissingAssociation(int hresult)
    {
        var registry = new FakeRegistrySource();
        var reader = new WindowsAssociationReader(new HResultEffectiveQuery(hresult), registry);

        Assert.Throws<COMException>(() => reader.Read(".mp4"));
        Assert.Equal(0, registry.UserChoiceReadCount);
    }

    [Theory]
    [InlineData("Microsoft.Windows.Photos_2026.11090.22001.0_x64__8wekyb3d8bbwe", "Microsoft.Windows.Photos_8wekyb3d8bbwe!App", true)]
    [InlineData("Microsoft.Windows.Photos_2026.11090.22001.0_x64__8wekyb3d8bbwe", "Microsoft.Windows.Photos_8wekyb3d8bbwe!OtherApp", false)]
    [InlineData("Microsoft.Windows.Photos_2026.11090.22001.0_x64__aaaaaaaaaaaaa", "Microsoft.Windows.Photos_aaaaaaaaaaaaa!App", false)]
    [InlineData(null, null, false)]
    public void Audit_UsesStablePackagedAppIdentityAcrossProgIdChanges(
        string? packageId, string? appId, bool expectedHealthy)
    {
        var snapshot = Snapshot(".png", "Updated.ProgId", AssociationConstants.PrimaryQueryAlgorithm)
            with { PackageId = packageId, AppUserModelId = appId };
        var service = new AssociationAuditService(
            new FakeSnapshotReader(snapshot), new FakeMediaPlayerTargetResolver());
        var rule = new ProtectedAssociationRule(
            ".png", AssociationCatalog.ImageCategory,
            AssociationConstants.CapturedCurrentTargetStrategy,
            "Original.ProgId",
            "Microsoft.Windows.Photos_2026.11060.2004.0_x64__8wekyb3d8bbwe",
            "Photos", DateTimeOffset.UtcNow,
            "Microsoft.Windows.Photos_8wekyb3d8bbwe!App");

        var result = service.Audit([rule]);

        Assert.Equal(expectedHealthy, Assert.Single(result.Items).Healthy);
    }

    [Fact]
    public void Audit_MissingAssociationRemainsVisibleDriftWithPrimaryEvidence()
    {
        var reader = new WindowsAssociationReader(
            new HResultEffectiveQuery(AssociationSnapshot.NoAssociationHResult),
            new FakeRegistrySource());
        var service = new AssociationAuditService(reader, new FakeMediaPlayerTargetResolver());

        var result = service.Audit([new AssociationRuleFactory().CreateDefault(".mp4")]);

        var item = Assert.Single(result.Items);
        Assert.False(item.Healthy);
        Assert.True(item.Snapshot!.NoAssociation);
        Assert.Contains("0x80070483", item.Error);
        Assert.Equal(1, result.DriftCount);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public void Audit_LegacyBaselineUsesOriginalRegistrationOnlyWithinCapturedFamily(bool sameFamily)
    {
        const string photos = "Microsoft.Windows.Photos_2026.11090.22001.0_x64__8wekyb3d8bbwe";
        const string appId = "Microsoft.Windows.Photos_8wekyb3d8bbwe!App";
        var snapshot = Snapshot(".png", "New.Photo.ProgId", AssociationConstants.PrimaryQueryAlgorithm)
            with { PackageId = photos, AppUserModelId = appId };
        var registry = new FakeRegistrySource(new ProgIdMetadata(
            "Old.Photo.ProgId", "Photos", "Microsoft Corporation",
            sameFamily ? photos : "Other.Application_1.0.0.0_x64__8wekyb3d8bbwe",
            appId));
        var rule = new ProtectedAssociationRule(
            ".png", AssociationCatalog.ImageCategory,
            AssociationConstants.CapturedCurrentTargetStrategy,
            "Old.Photo.ProgId",
            "Microsoft.Windows.Photos_2026.11060.2004.0_x64__8wekyb3d8bbwe",
            "Photos", DateTimeOffset.UtcNow);
        var service = new AssociationAuditService(
            new FakeSnapshotReader(snapshot), new FakeMediaPlayerTargetResolver(), registry);

        Assert.Equal(sameFamily, Assert.Single(service.Audit([rule]).Items).Healthy);
    }

    private sealed class HResultEffectiveQuery(int hresult) : IEffectiveAssociationQuery
    {
        public string QueryEffectiveProgId(string extension) =>
            throw new COMException("Primary COM result.", hresult);
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

    private sealed class ThrowingEffectiveQuery : IEffectiveAssociationQuery
    {
        public string QueryEffectiveProgId(string extension)
        {
            throw new InvalidOperationException("Primary COM query failed.");
        }
    }

    private sealed class FakeRegistrySource(ProgIdMetadata? metadata = null) : IAssociationRegistrySource
    {
        public int UserChoiceReadCount { get; private set; }

        public UserChoiceEvidence ReadUserChoice(string extension)
        {
            UserChoiceReadCount++;
            return new UserChoiceEvidence("Media.Player", true);
        }

        public ProgIdMetadata ReadProgIdMetadata(string progId)
        {
            return metadata ?? new ProgIdMetadata(progId, "Media Player", "Microsoft Corporation", null, null);
        }

        public IReadOnlyList<string> ReadOpenWithProgIds(string extension)
        {
            return [];
        }
    }

    private sealed class FakeSnapshotReader(
        params AssociationSnapshot[] values) : IAssociationSnapshotReader
    {
        private readonly IReadOnlyDictionary<string, AssociationSnapshot>
            snapshots = values.ToDictionary(
                value => value.Extension,
                StringComparer.OrdinalIgnoreCase);

        public AssociationSnapshot Read(string extension) => snapshots.Count == 1
            ? snapshots.Values.Single()
            : snapshots[ExtensionName.Normalize(extension)];

        public IReadOnlyList<AssociationSnapshot> ReadMany(
            IEnumerable<string> extensions) =>
            extensions.Select(Read).ToArray();
    }

    private sealed class ThrowingSnapshotReader(Exception exception)
        : IAssociationSnapshotReader
    {
        public AssociationSnapshot Read(string extension) => throw exception;

        public IReadOnlyList<AssociationSnapshot> ReadMany(
            IEnumerable<string> extensions) => throw exception;
    }

    private sealed class FakeMediaPlayerTargetResolver
        : IMediaPlayerTargetResolver
    {
        public AssociationTarget Resolve(IEnumerable<string> extensions) =>
            new(
                "Media.Player",
                "Microsoft.ZuneMusic_1.0_x64__8wekyb3d8bbwe",
                "Microsoft.ZuneMusic!App",
                "Media Player",
                extensions.Select(ExtensionName.Normalize).ToArray());
    }
}
