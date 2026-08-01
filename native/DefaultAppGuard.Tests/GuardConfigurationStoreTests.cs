using DefaultAppGuard.Agent;
using DefaultAppGuard.Core;
using Microsoft.Extensions.Logging.Abstractions;

namespace DefaultAppGuard.Tests;

public sealed class GuardConfigurationStoreTests : IDisposable
{
    private readonly string temporaryDirectory = Path.Combine(
        Path.GetTempPath(),
        $"DefaultAppGuard.Tests.{Guid.NewGuid():N}");

    [Fact]
    public void NewStore_DefaultsToEveryDeclaredVideoExtension()
    {
        var store = CreateStore();

        var result = store.Snapshot();

        Assert.Equal(2, result.SchemaVersion);
        Assert.Equal("monitor", result.ProtectionMode);
        Assert.True(result.NotificationsEnabled);
        Assert.Equal(
            AssociationConstants.VideoExtensions.Order(
                StringComparer.OrdinalIgnoreCase),
            result.ProtectedVideoExtensions);
    }

    [Fact]
    public async Task UpdateAsync_NormalizesSortsAndPersistsSelection()
    {
        var store = CreateStore();

        var result = await store.UpdateAsync(
            new GuardConfigurationUpdate(
                [".MP4", "mkv", ".mp4"],
                null),
            CancellationToken.None);
        var reloaded = CreateStore().Snapshot();

        Assert.Equal([".mkv", ".mp4"], result.ProtectedVideoExtensions);
        Assert.Equal(result.SchemaVersion, reloaded.SchemaVersion);
        Assert.Equal(result.ProtectionMode, reloaded.ProtectionMode);
        Assert.Equal(
            result.NotificationsEnabled,
            reloaded.NotificationsEnabled);
        Assert.Equal(
            result.ProtectedVideoExtensions,
            reloaded.ProtectedVideoExtensions);
        Assert.True(File.Exists(BackupPath));
        Assert.Empty(Directory.GetFiles(temporaryDirectory, "*.tmp"));
    }

    [Fact]
    public async Task UpdateAsync_RejectsEmptySelection()
    {
        var store = CreateStore();

        var exception = await Assert.ThrowsAsync<ArgumentException>(
            () => store.UpdateAsync(
                new GuardConfigurationUpdate([], null),
                CancellationToken.None));

        Assert.Contains("At least one", exception.Message);
    }

    [Fact]
    public async Task UpdateAsync_RejectsUnsupportedExtension()
    {
        var store = CreateStore();

        var exception = await Assert.ThrowsAsync<ArgumentException>(
            () => store.UpdateAsync(
                new GuardConfigurationUpdate([".not-video"], null),
                CancellationToken.None));

        Assert.Contains(".not-video", exception.Message);
    }

    [Fact]
    public async Task UpdateAsync_PreservesFieldsThatWereNotSupplied()
    {
        var store = CreateStore();
        await store.UpdateAsync(
            new GuardConfigurationUpdate([".mp4"], null),
            CancellationToken.None);

        var result = await store.UpdateAsync(
            new GuardConfigurationUpdate(null, false),
            CancellationToken.None);

        Assert.Equal([".mp4"], result.ProtectedVideoExtensions);
        Assert.False(result.NotificationsEnabled);
        Assert.False(CreateStore().Snapshot().NotificationsEnabled);
    }

    [Fact]
    public void ExistingSchemaOneConfiguration_IsMigratedWithoutLosingSelection()
    {
        Directory.CreateDirectory(temporaryDirectory);
        File.WriteAllText(
            ConfigurationPath,
            """
            {
              "schemaVersion": 1,
              "protectedVideoExtensions": [".mkv", ".mp4"],
              "protectionMode": "monitor"
            }
            """);

        var result = CreateStore().Snapshot();
        var persisted = File.ReadAllText(ConfigurationPath);

        Assert.Equal(2, result.SchemaVersion);
        Assert.Equal([".mkv", ".mp4"], result.ProtectedVideoExtensions);
        Assert.True(result.NotificationsEnabled);
        Assert.Contains("\"SchemaVersion\": 2", persisted);
        Assert.Contains("\"NotificationsEnabled\": true", persisted);
    }

    [Fact]
    public async Task InvalidPrimaryConfiguration_RestoresLastKnownGoodBackup()
    {
        var store = CreateStore();
        await store.UpdateAsync(
            new GuardConfigurationUpdate([".mp4"], false),
            CancellationToken.None);
        await store.UpdateAsync(
            new GuardConfigurationUpdate([".mkv"], true),
            CancellationToken.None);
        File.WriteAllText(ConfigurationPath, "{ invalid json");

        var recoveredStore = CreateStore();
        var recovered = recoveredStore.Snapshot();
        var persistence = recoveredStore.SnapshotPersistenceStatus();

        Assert.Equal([".mp4"], recovered.ProtectedVideoExtensions);
        Assert.False(recovered.NotificationsEnabled);
        Assert.True(persistence.BackupAvailable);
        Assert.True(persistence.Recovered);
        Assert.Equal(
            GuardConfigurationStore.BackupRestoredCode,
            persistence.RecoveryCode);
        Assert.NotNull(persistence.RecoveredAtUtc);
        var persisted = CreateStore().Snapshot();
        Assert.Equal(
            recovered.ProtectedVideoExtensions,
            persisted.ProtectedVideoExtensions);
        Assert.Equal(
            recovered.NotificationsEnabled,
            persisted.NotificationsEnabled);
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
            recovered.ProtectedVideoExtensions);
        Assert.True(recovered.NotificationsEnabled);
        Assert.True(persistence.BackupAvailable);
        Assert.True(persistence.Recovered);
        Assert.Equal(
            GuardConfigurationStore.DefaultsRestoredCode,
            persistence.RecoveryCode);
        Assert.NotNull(persistence.RecoveredAtUtc);
    }

    [Fact]
    public void MissingPrimaryAndInvalidBackup_ReportSafeDefaultsRecovery()
    {
        _ = CreateStore();
        File.Delete(ConfigurationPath);
        File.WriteAllText(BackupPath, "{ invalid backup");

        var recoveredStore = CreateStore();
        var recovered = recoveredStore.Snapshot();
        var persistence = recoveredStore.SnapshotPersistenceStatus();

        Assert.Equal(
            AssociationConstants.VideoExtensions.Order(
                StringComparer.OrdinalIgnoreCase),
            recovered.ProtectedVideoExtensions);
        Assert.True(recovered.NotificationsEnabled);
        Assert.True(persistence.BackupAvailable);
        Assert.True(persistence.Recovered);
        Assert.Equal(
            GuardConfigurationStore.DefaultsRestoredCode,
            persistence.RecoveryCode);
        Assert.NotNull(persistence.RecoveredAtUtc);
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

        Assert.Equal(
            "{ invalid primary",
            File.ReadAllText(ConfigurationPath));
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
            NullLogger<GuardConfigurationStore>.Instance);
    }

    private string ConfigurationPath =>
        Path.Combine(temporaryDirectory, "config.json");

    private string BackupPath => ConfigurationPath + ".bak";
}
