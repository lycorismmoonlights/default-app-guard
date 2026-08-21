using DefaultAppGuard.Agent;
using DefaultAppGuard.Core;
using Microsoft.Extensions.Logging.Abstractions;

namespace DefaultAppGuard.Tests;

public sealed class GuardConfigurationStoreTests : IDisposable
{
    private readonly string temporaryDirectory = Path.Combine(
        Path.GetTempPath(),
        $"DefaultAppGuard.Tests.{Guid.NewGuid():N}");
    private readonly FakeSnapshotReader reader = new();

    [Fact]
    public void NewStore_DefaultsToEveryDeclaredVideoExtension()
    {
        var result = CreateStore().Snapshot();

        Assert.Equal(3, result.SchemaVersion);
        Assert.Equal("monitor", result.ProtectionMode);
        Assert.True(result.NotificationsEnabled);
        Assert.Equal(
            AssociationConstants.VideoExtensions.Order(
                StringComparer.OrdinalIgnoreCase),
            Extensions(result));
        Assert.All(result.ProtectedAssociations, rule =>
        {
            Assert.Equal(AssociationCatalog.VideoCategory, rule.Category);
            Assert.Equal(
                AssociationConstants.MediaPlayerTargetStrategy,
                rule.TargetStrategy);
            Assert.Null(rule.ExpectedProgId);
        });
    }

    [Fact]
    public async Task UpdateAsync_NormalizesSortsAndPersistsVideoSelection()
    {
        var store = CreateStore();

        var result = await store.UpdateAsync(
            new GuardConfigurationUpdate(
                [".MP4", "mkv", ".mp4"],
                null,
                null),
            CancellationToken.None);
        var reloaded = CreateStore().Snapshot();

        Assert.Equal([".mkv", ".mp4"], Extensions(result));
        Assert.Equal(result.ProtectedAssociations, reloaded.ProtectedAssociations);
        Assert.True(File.Exists(BackupPath));
        Assert.Empty(Directory.GetFiles(temporaryDirectory, "*.tmp"));
    }

    [Fact]
    public async Task UpdateAsync_CapturesAndRetainsANonVideoBaseline()
    {
        reader.Set(".pdf", "Acme.Reader", "Acme Reader");
        var store = CreateStore();

        var captured = await store.UpdateAsync(
            new GuardConfigurationUpdate(
                [".mp4", ".pdf"],
                [".pdf"],
                false),
            CancellationToken.None);
        reader.Set(".pdf", "Hijacker.Reader", "Hijacker");
        var retained = await store.UpdateAsync(
            new GuardConfigurationUpdate(
                [".pdf", ".mp4"],
                null,
                null),
            CancellationToken.None);

        var rule = Assert.Single(
            retained.ProtectedAssociations,
            item => item.Extension == ".pdf");
        Assert.Equal("Acme.Reader", rule.ExpectedProgId);
        Assert.Equal(AssociationCatalog.DocumentCategory, rule.Category);
        Assert.Equal(
            AssociationConstants.CapturedCurrentTargetStrategy,
            rule.TargetStrategy);
        Assert.NotNull(rule.CapturedAtUtc);
        Assert.False(captured.NotificationsEnabled);
        Assert.False(retained.NotificationsEnabled);
    }

    [Fact]
    public async Task UpdateAsync_RecapturesOnlyWhenExplicitlyRequested()
    {
        reader.Set(".pdf", "First.Reader", "First");
        var store = CreateStore();
        _ = await store.UpdateAsync(
            new GuardConfigurationUpdate(
                [".mp4", ".pdf"],
                [".pdf"],
                null),
            CancellationToken.None);
        reader.Set(".pdf", "Second.Reader", "Second");

        var result = await store.UpdateAsync(
            new GuardConfigurationUpdate(
                [".mp4", ".pdf"],
                [".pdf"],
                null),
            CancellationToken.None);

        Assert.Equal(
            "Second.Reader",
            result.ProtectedAssociations.Single(
                rule => rule.Extension == ".pdf").ExpectedProgId);
    }

    [Fact]
    public async Task UpdateAsync_RejectsANewNonVideoRuleWithoutCapture()
    {
        var exception = await Assert.ThrowsAsync<ArgumentException>(
            () => CreateStore().UpdateAsync(
                new GuardConfigurationUpdate(
                    [".mp4", ".pdf"],
                    null,
                    null),
                CancellationToken.None));

        Assert.Contains("captured", exception.Message);
    }

    [Fact]
    public async Task UpdateAsync_RejectsCaptureOutsideSelection()
    {
        var exception = await Assert.ThrowsAsync<ArgumentException>(
            () => CreateStore().UpdateAsync(
                new GuardConfigurationUpdate(
                    [".mp4"],
                    [".pdf"],
                    null),
                CancellationToken.None));

        Assert.Contains("selected", exception.Message);
    }

    [Theory]
    [InlineData(null)]
    [InlineData(".not-supported")]
    public async Task UpdateAsync_RejectsInvalidSelection(string? extension)
    {
        var extensions = extension is null ? [] : new[] { extension };
        await Assert.ThrowsAsync<ArgumentException>(
            () => CreateStore().UpdateAsync(
                new GuardConfigurationUpdate(extensions, null, null),
                CancellationToken.None));
    }

    [Fact]
    public async Task UpdateAsync_PreservesAssociationsWhenOnlyNotificationsChange()
    {
        var store = CreateStore();
        _ = await store.UpdateAsync(
            new GuardConfigurationUpdate([".mp4"], null, null),
            CancellationToken.None);

        var result = await store.UpdateAsync(
            new GuardConfigurationUpdate(null, null, false),
            CancellationToken.None);

        Assert.Equal([".mp4"], Extensions(result));
        Assert.False(result.NotificationsEnabled);
        Assert.False(CreateStore().Snapshot().NotificationsEnabled);
    }

    [Theory]
    [InlineData(1, true)]
    [InlineData(2, false)]
    public void LegacyConfiguration_IsMigratedWithoutLosingSelection(
        int schemaVersion,
        bool expectedNotifications)
    {
        Directory.CreateDirectory(temporaryDirectory);
        File.WriteAllText(
            ConfigurationPath,
            $$"""
            {
              "schemaVersion": {{schemaVersion}},
              "protectedVideoExtensions": [".mkv", ".mp4"],
              "protectionMode": "monitor",
              "notificationsEnabled": false
            }
            """);

        var result = CreateStore().Snapshot();
        var persisted = File.ReadAllText(ConfigurationPath);

        Assert.Equal(3, result.SchemaVersion);
        Assert.Equal([".mkv", ".mp4"], Extensions(result));
        Assert.Equal(expectedNotifications, result.NotificationsEnabled);
        Assert.Contains("\"SchemaVersion\": 3", persisted);
        Assert.Contains("\"ProtectedAssociations\"", persisted);
    }

    [Fact]
    public async Task InvalidPrimaryConfiguration_RestoresLastKnownGoodBackup()
    {
        var store = CreateStore();
        _ = await store.UpdateAsync(
            new GuardConfigurationUpdate([".mp4"], null, false),
            CancellationToken.None);
        _ = await store.UpdateAsync(
            new GuardConfigurationUpdate([".mkv"], null, true),
            CancellationToken.None);
        File.WriteAllText(ConfigurationPath, "{ invalid json");

        var recoveredStore = CreateStore();
        var recovered = recoveredStore.Snapshot();
        var persistence = recoveredStore.SnapshotPersistenceStatus();

        Assert.Equal([".mp4"], Extensions(recovered));
        Assert.False(recovered.NotificationsEnabled);
        Assert.True(persistence.BackupAvailable);
        Assert.True(persistence.Recovered);
        Assert.Equal(
            GuardConfigurationStore.BackupRestoredCode,
            persistence.RecoveryCode);
        Assert.NotNull(persistence.RecoveredAtUtc);
    }

    [Fact]
    public void InvalidSchemaThreeCapturedRule_RestoresSafeDefaults()
    {
        Directory.CreateDirectory(temporaryDirectory);
        File.WriteAllText(
            ConfigurationPath,
            """
            {
              "schemaVersion": 3,
              "protectedAssociations": [{
                "extension": ".pdf",
                "category": "document",
                "targetStrategy": "captured-current",
                "expectedProgId": "",
                "capturedAtUtc": null
              }],
              "protectionMode": "monitor",
              "notificationsEnabled": true
            }
            """);

        var store = CreateStore();
        var result = store.Snapshot();
        var persistence = store.SnapshotPersistenceStatus();

        Assert.Equal(
            AssociationConstants.VideoExtensions.Order(
                StringComparer.OrdinalIgnoreCase),
            Extensions(result));
        Assert.Equal(
            GuardConfigurationStore.DefaultsRestoredCode,
            persistence.RecoveryCode);
    }

    [Fact]
    public void InvalidPrimaryAndBackup_RestoreSafeDefaults()
    {
        _ = CreateStore();
        File.WriteAllText(ConfigurationPath, "{ invalid primary");
        File.WriteAllText(BackupPath, "{ invalid backup");

        var recoveredStore = CreateStore();
        var recovered = recoveredStore.Snapshot();
        var persistence = recoveredStore.SnapshotPersistenceStatus();

        Assert.Equal(
            AssociationConstants.VideoExtensions.Order(
                StringComparer.OrdinalIgnoreCase),
            Extensions(recovered));
        Assert.True(recovered.NotificationsEnabled);
        Assert.True(persistence.Recovered);
        Assert.Equal(
            GuardConfigurationStore.DefaultsRestoredCode,
            persistence.RecoveryCode);
    }

    [Fact]
    public void UnreadablePrimary_DoesNotSilentlyResetConfiguration()
    {
        _ = CreateStore();
        File.WriteAllText(ConfigurationPath, "{ invalid primary");

        using (File.Open(
                   ConfigurationPath,
                   FileMode.Open,
                   FileAccess.ReadWrite,
                   FileShare.None))
        {
            Assert.Throws<IOException>(() => CreateStore());
        }

        Assert.Equal("{ invalid primary", File.ReadAllText(ConfigurationPath));
    }

    public void Dispose()
    {
        if (Directory.Exists(temporaryDirectory))
        {
            Directory.Delete(temporaryDirectory, recursive: true);
        }
    }

    private GuardConfigurationStore CreateStore()
    {
        Directory.CreateDirectory(temporaryDirectory);
        var options = new AgentOptions(
            "http://127.0.0.1:51873",
            Path.Combine(temporaryDirectory, "state.json"),
            ConfigurationPath,
            Path.Combine(temporaryDirectory, "logs"),
            TimeSpan.FromMinutes(15),
            false,
            []);
        return new GuardConfigurationStore(
            options,
            new AssociationRuleFactory(reader),
            NullLogger<GuardConfigurationStore>.Instance);
    }

    private static string[] Extensions(GuardConfiguration configuration) =>
        configuration.ProtectedAssociations
            .Select(rule => rule.Extension)
            .ToArray();

    private string ConfigurationPath =>
        Path.Combine(temporaryDirectory, "config.json");

    private string BackupPath => ConfigurationPath + ".bak";

    private sealed class FakeSnapshotReader : IAssociationSnapshotReader
    {
        private readonly Dictionary<string, AssociationSnapshot> snapshots =
            new(StringComparer.OrdinalIgnoreCase);

        public void Set(string extension, string progId, string appName)
        {
            var normalized = ExtensionName.Normalize(extension);
            snapshots[normalized] = new AssociationSnapshot(
                normalized,
                progId,
                progId,
                true,
                appName,
                null,
                AssociationConstants.PrimaryQueryAlgorithm);
        }

        public AssociationSnapshot Read(string extension)
        {
            var normalized = ExtensionName.Normalize(extension);
            if (snapshots.TryGetValue(normalized, out var snapshot))
            {
                return snapshot;
            }

            return new AssociationSnapshot(
                normalized,
                $"Default.Handler.{normalized.TrimStart('.')}",
                null,
                false,
                "Default Handler",
                null,
                AssociationConstants.PrimaryQueryAlgorithm);
        }

        public IReadOnlyList<AssociationSnapshot> ReadMany(
            IEnumerable<string> extensions) =>
            extensions.Select(Read).ToArray();
    }
}
