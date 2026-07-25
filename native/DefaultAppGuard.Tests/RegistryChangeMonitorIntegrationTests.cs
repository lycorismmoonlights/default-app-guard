using DefaultAppGuard.Core;
using Microsoft.Win32;

namespace DefaultAppGuard.Tests;

[Trait("Category", "MainAlgorithmIntegration")]
public sealed class RegistryChangeMonitorIntegrationTests
{
    [Fact]
    public async Task MainMonitorAlgorithm_ReceivesRealKernelChangeNotification()
    {
        Assert.True(OperatingSystem.IsWindows(), "Windows integration test.");
        var testPath =
            $@"Software\DefaultAppGuard\Tests\Monitor\{Guid.NewGuid():N}";
        Registry.CurrentUser.CreateSubKey(testPath)?.Dispose();

        try
        {
            using var monitor = new RegistryChangeMonitor(
                RegistryHive.CurrentUser,
                testPath);
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(3));
            var pendingSignal = monitor.WaitForChangeAsync(timeout.Token);

            await Task.Delay(250, timeout.Token);
            Assert.False(
                pendingSignal.IsCompleted,
                "The monitor must not synthesize a change when its calling thread yields.");
            using (var key = Registry.CurrentUser.OpenSubKey(testPath, writable: true))
            {
                Assert.NotNull(key);
                key.SetValue("Probe", Guid.NewGuid().ToString("N"));
            }

            var signal = await pendingSignal;
            Assert.Equal(RegistryHive.CurrentUser, signal.Hive);
            Assert.Equal(testPath, signal.SubKeyPath);

            var secondSignal = monitor.WaitForChangeAsync(timeout.Token);
            await Task.Delay(100, timeout.Token);
            Assert.False(
                secondSignal.IsCompleted,
                "Re-arming must wait for a second real registry change.");
            using (var key = Registry.CurrentUser.OpenSubKey(testPath, writable: true))
            {
                Assert.NotNull(key);
                key.SetValue("SecondProbe", Guid.NewGuid().ToString("N"));
            }

            var second = await secondSignal;
            Assert.True(second.ObservedAtUtc >= signal.ObservedAtUtc);
        }
        finally
        {
            Registry.CurrentUser.DeleteSubKeyTree(
                testPath,
                throwOnMissingSubKey: false);
        }
    }

    [Fact]
    public async Task WaitForChange_RejectsPreCanceledRequestWithoutSyntheticSuccess()
    {
        Assert.True(OperatingSystem.IsWindows(), "Windows integration test.");
        var testPath =
            $@"Software\DefaultAppGuard\Tests\Monitor\{Guid.NewGuid():N}";
        Registry.CurrentUser.CreateSubKey(testPath)?.Dispose();

        try
        {
            using var monitor = new RegistryChangeMonitor(
                RegistryHive.CurrentUser,
                testPath);
            using var cancellation = new CancellationTokenSource();
            cancellation.Cancel();

            await Assert.ThrowsAnyAsync<OperationCanceledException>(
                () => monitor.WaitForChangeAsync(cancellation.Token));
        }
        finally
        {
            Registry.CurrentUser.DeleteSubKeyTree(
                testPath,
                throwOnMissingSubKey: false);
        }
    }
}
