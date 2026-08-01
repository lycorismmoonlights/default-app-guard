using DefaultAppGuard.Agent;
using DefaultAppGuard.Core;

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
        return new GuardConfigurationStore(options);
    }

    private string ConfigurationPath =>
        Path.Combine(temporaryDirectory, "config.json");
}
