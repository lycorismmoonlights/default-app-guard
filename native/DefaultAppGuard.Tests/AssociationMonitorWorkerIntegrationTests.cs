using DefaultAppGuard.Agent;
using DefaultAppGuard.Core;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Win32;
using System.Diagnostics;

namespace DefaultAppGuard.Tests;

[Trait("Category", "MainAlgorithmIntegration")]
public sealed class AssociationMonitorWorkerIntegrationTests
{
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task RealWorker_AuditsAfterFileExtsNotificationAndRearms(bool separateProcess)
    {
        var temporaryRoot = Path.GetFullPath(Path.GetTempPath());
        var directoryName = "DefaultAppGuard-worker-" + Guid.NewGuid().ToString("N");
        var directory = Path.Combine(temporaryRoot, directoryName);
        var probePath = @"Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.defaultappguard-worker-" + Guid.NewGuid().ToString("N");
        var options = new AgentOptions(
            "http://127.0.0.1:51873",
            Path.Combine(directory, "status.json"),
            Path.Combine(directory, "config.json"),
            Path.Combine(directory, "logs"),
            TimeSpan.FromMinutes(15),
            false,
            []);
        var state = new AgentRuntimeState();
        var reader = new WindowsAssociationReader();
        var store = new GuardConfigurationStore(options, new AssociationRuleFactory(reader), NullLogger<GuardConfigurationStore>.Instance);
        var coordinator = new AssociationAuditCoordinator(
            new AssociationAuditService(reader, new MediaPlayerTargetResolver()),
            state, options, store, NullLogger<AssociationAuditCoordinator>.Instance);
        using var worker = new AssociationMonitorWorker(coordinator, options, NullLogger<AssociationMonitorWorker>.Instance);
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(12));
        try
        {
            await worker.StartAsync(timeout.Token);
            while (state.Snapshot().Audit is null) await Task.Delay(50, timeout.Token);
            WriteProbe(probePath, separateProcess);
            while (state.Snapshot().RegistryEventCount < 1) await Task.Delay(50, timeout.Token);
            WriteProbe(probePath, separateProcess);
            while (state.Snapshot().RegistryEventCount < 2) await Task.Delay(50, timeout.Token);
            var status = state.Snapshot();
            Assert.Equal("registry-notification", status.LastAuditReason);
            Assert.True(AgentReadinessEvaluator.Evaluate(status, options.MaximumAuditAge).Ready);
        }
        finally
        {
            await worker.StopAsync(CancellationToken.None);
            Registry.CurrentUser.DeleteSubKeyTree(probePath, throwOnMissingSubKey: false);
            var cleanup = new DirectoryInfo(Path.GetFullPath(directory));
            if (!string.Equals(cleanup.Name, directoryName, StringComparison.Ordinal) ||
                !string.Equals(cleanup.Parent?.FullName,
                    Path.TrimEndingDirectorySeparator(temporaryRoot), StringComparison.OrdinalIgnoreCase) ||
                cleanup.LinkTarget is not null)
            {
                throw new InvalidOperationException("Refusing to remove an unexpected test directory.");
            }
            if (cleanup.Exists) cleanup.Delete(recursive: true);
        }
    }

    private static void WriteProbe(string path, bool separateProcess)
    {
        if (!separateProcess)
        {
            using var key = Registry.CurrentUser.CreateSubKey(path);
            key.SetValue("RearmProbe", Guid.NewGuid().ToString("N"));
            return;
        }

        var start = new ProcessStartInfo(Path.Combine(
            Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe"))
        {
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        start.ArgumentList.Add("-NoProfile");
        start.ArgumentList.Add("-NonInteractive");
        start.ArgumentList.Add("-Command");
        start.ArgumentList.Add($"$k=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('{path}'); $k.SetValue('RearmProbe','{Guid.NewGuid():N}'); $k.Dispose()");
        using var process = Process.Start(start)!;
        Assert.True(process.WaitForExit(5000));
        Assert.Equal(0, process.ExitCode);
    }
}
