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

        Assert.Equal(1, result.SchemaVersion);
        Assert.Equal("monitor", result.ProtectionMode);
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
            [".MP4", "mkv", ".mp4"],
            CancellationToken.None);
        var reloaded = CreateStore().Snapshot();

        Assert.Equal([".mkv", ".mp4"], result.ProtectedVideoExtensions);
        Assert.Equal(result.SchemaVersion, reloaded.SchemaVersion);
        Assert.Equal(result.ProtectionMode, reloaded.ProtectionMode);
        Assert.Equal(
            result.ProtectedVideoExtensions,
            reloaded.ProtectedVideoExtensions);
    }

    [Fact]
    public async Task UpdateAsync_RejectsEmptySelection()
    {
        var store = CreateStore();

        var exception = await Assert.ThrowsAsync<ArgumentException>(
            () => store.UpdateAsync([], CancellationToken.None));

        Assert.Contains("At least one", exception.Message);
    }

    [Fact]
    public async Task UpdateAsync_RejectsUnsupportedExtension()
    {
        var store = CreateStore();

        var exception = await Assert.ThrowsAsync<ArgumentException>(
            () => store.UpdateAsync([".not-video"], CancellationToken.None));

        Assert.Contains(".not-video", exception.Message);
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
            Path.Combine(temporaryDirectory, "config.json"),
            TimeSpan.FromMinutes(15),
            false,
            []);
        return new GuardConfigurationStore(options);
    }
}
