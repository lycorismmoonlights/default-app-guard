using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Security.AccessControl;

namespace DefaultAppGuard.Core;

public sealed record RegistryChangeSignal(
    RegistryHive Hive,
    string SubKeyPath,
    DateTimeOffset ObservedAtUtc);

[SupportedOSPlatform("windows")]
public sealed class RegistryChangeMonitor : IDisposable
{
    private readonly RegistryHive hive;
    private readonly string subKeyPath;
    private readonly RegistryKey key;
    private readonly AutoResetEvent changedEvent = new(initialState: false);
    private bool disposed;

    public RegistryChangeMonitor(
        RegistryHive hive,
        string subKeyPath,
        bool watchSubtree = true)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(subKeyPath);
        this.hive = hive;
        this.subKeyPath = subKeyPath;
        WatchSubtree = watchSubtree;

        using var baseKey = RegistryKey.OpenBaseKey(hive, RegistryView.Default);
        key = baseKey.OpenSubKey(
                  subKeyPath,
                  RegistryKeyPermissionCheck.ReadSubTree,
                  RegistryRights.Notify | RegistryRights.ReadKey)
              ?? throw new InvalidOperationException(
                  $"Registry key does not exist: {hive}\\{subKeyPath}");
    }

    public bool WatchSubtree { get; }

    public async Task<RegistryChangeSignal> WaitForChangeAsync(
        CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        cancellationToken.ThrowIfCancellationRequested();
        changedEvent.Reset();

        var error = RegNotifyChangeKeyValue(
            key.Handle,
            WatchSubtree,
            RegistryNotifyFilter.Name |
            RegistryNotifyFilter.LastSet |
            RegistryNotifyFilter.Security |
            RegistryNotifyFilter.ThreadAgnostic,
            changedEvent.SafeWaitHandle,
            asynchronous: true);
        if (error != 0)
        {
            throw new Win32Exception(
                error,
                $"RegNotifyChangeKeyValue failed for {hive}\\{subKeyPath}.");
        }

        var signaled = await Task.Run(
            () => WaitHandle.WaitAny(
                [changedEvent, cancellationToken.WaitHandle]),
            CancellationToken.None);
        if (signaled == 1)
        {
            throw new OperationCanceledException(cancellationToken);
        }

        return new RegistryChangeSignal(
            hive,
            subKeyPath,
            DateTimeOffset.UtcNow);
    }

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }

        disposed = true;
        key.Dispose();
        changedEvent.Dispose();
    }

    [Flags]
    private enum RegistryNotifyFilter : uint
    {
        Name = 0x00000001,
        LastSet = 0x00000004,
        Security = 0x00000008,
        ThreadAgnostic = 0x10000000,
    }

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern int RegNotifyChangeKeyValue(
        SafeRegistryHandle key,
        [MarshalAs(UnmanagedType.Bool)] bool watchSubtree,
        RegistryNotifyFilter notifyFilter,
        SafeWaitHandle eventHandle,
        [MarshalAs(UnmanagedType.Bool)] bool asynchronous);
}
