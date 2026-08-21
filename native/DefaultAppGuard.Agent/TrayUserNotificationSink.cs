using System.Diagnostics;
using System.Drawing;
using System.Windows.Forms;

namespace DefaultAppGuard.Agent;

public sealed record UserNotificationStatus(
    string Channel,
    bool Available,
    string? LastError,
    string? LastQueuedKind,
    DateTimeOffset? LastQueuedAtUtc,
    string? ConfigurationRecoveryLastQueuedKind,
    DateTimeOffset? ConfigurationRecoveryLastQueuedAtUtc);

public static class UserNotificationKinds
{
    public const string AssociationDrift = "association-drift";
    public const string ConfigurationBackupRestored =
        "configuration-backup-restored";
    public const string ConfigurationDefaultsRestored =
        "configuration-defaults-restored";
}

public interface IUserNotificationSink
{
    UserNotificationStatus Snapshot();

    bool TryShowAssociationDrift(DriftNotification notification);

    bool TryShowConfigurationRecovery(
        ConfigurationRecoveryNotification notification);
}

public sealed class TrayUserNotificationSink(
    AgentOptions options,
    ILogger<TrayUserNotificationSink> logger) :
    IUserNotificationSink,
    IHostedService,
    IDisposable
{
    public const string ChannelName = "WindowsForms.NotifyIcon";
    private static readonly TimeSpan StartupTimeout = TimeSpan.FromSeconds(5);
    private static readonly TimeSpan ShutdownTimeout = TimeSpan.FromSeconds(5);

    private readonly object gate = new();
    private readonly ManualResetEventSlim initialized = new(false);
    private UserNotificationStatus status = new(
        ChannelName,
        false,
        "Notification channel has not started.",
        null,
        null,
        null,
        null);
    private Thread? messageLoopThread;
    private SynchronizationContext? messageLoopContext;
    private NotifyIcon? notifyIcon;
    private bool stopping;
    private bool disposed;

    public Task StartAsync(CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        try
        {
            messageLoopThread = new Thread(RunMessageLoop)
            {
                IsBackground = true,
                Name = "DefaultAppGuard notification loop",
            };
            messageLoopThread.SetApartmentState(ApartmentState.STA);
            messageLoopThread.Start();
        }
        catch (Exception exception)
        {
            SetUnavailable(
                $"{exception.GetType().Name}: {exception.Message}");
            initialized.Set();
            logger.LogWarning(
                exception,
                "The system notification thread could not start.");
            return Task.CompletedTask;
        }

        if (!initialized.Wait(StartupTimeout, cancellationToken))
        {
            SetUnavailable("Notification channel startup timed out.");
        }

        return Task.CompletedTask;
    }

    public Task StopAsync(CancellationToken cancellationToken)
    {
        Thread? thread;
        SynchronizationContext? context;
        lock (gate)
        {
            stopping = true;
            thread = messageLoopThread;
            context = messageLoopContext;
        }

        try
        {
            context?.Post(_ => Application.ExitThread(), null);
        }
        catch (InvalidOperationException exception)
        {
            logger.LogDebug(
                exception,
                "The notification message loop had already stopped.");
        }
        if (thread is not null &&
            thread.IsAlive &&
            !thread.Join(ShutdownTimeout))
        {
            logger.LogWarning(
                "The notification message loop did not stop within the deadline.");
        }

        return Task.CompletedTask;
    }

    public UserNotificationStatus Snapshot()
    {
        lock (gate)
        {
            return status;
        }
    }

    public bool TryShowAssociationDrift(DriftNotification notification)
    {
        ArgumentNullException.ThrowIfNull(notification);
        return TryQueueBalloon(
            UserNotificationKinds.AssociationDrift,
            icon => ShowDriftBalloon(icon, notification));
    }

    public bool TryShowConfigurationRecovery(
        ConfigurationRecoveryNotification notification)
    {
        ArgumentNullException.ThrowIfNull(notification);
        return TryQueueBalloon(
            notification.Kind,
            icon => ShowConfigurationRecoveryBalloon(icon, notification));
    }

    private bool TryQueueBalloon(
        string kind,
        Action<NotifyIcon> showBalloon)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(kind);
        ArgumentNullException.ThrowIfNull(showBalloon);
        SynchronizationContext? context;
        NotifyIcon? icon;
        lock (gate)
        {
            if (!status.Available || stopping)
            {
                return false;
            }

            context = messageLoopContext;
            icon = notifyIcon;
        }

        if (context is null || icon is null)
        {
            return false;
        }

        try
        {
            context.Post(_ => showBalloon(icon), null);
            lock (gate)
            {
                var queuedAtUtc = DateTimeOffset.UtcNow;
                var next = status with
                {
                    LastQueuedKind = kind,
                    LastQueuedAtUtc = queuedAtUtc,
                };
                if (kind is
                    UserNotificationKinds.ConfigurationBackupRestored or
                    UserNotificationKinds.ConfigurationDefaultsRestored)
                {
                    next = next with
                    {
                        ConfigurationRecoveryLastQueuedKind = kind,
                        ConfigurationRecoveryLastQueuedAtUtc = queuedAtUtc,
                    };
                }

                status = next;
            }
            return true;
        }
        catch (InvalidOperationException exception)
        {
            SetUnavailable(
                $"{exception.GetType().Name}: {exception.Message}");
            logger.LogWarning(
                exception,
                "The system notification channel stopped before delivery.");
            return false;
        }
    }

    private void RunMessageLoop()
    {
        try
        {
            SynchronizationContext.SetSynchronizationContext(
                new WindowsFormsSynchronizationContext());
            var context = SynchronizationContext.Current ??
                throw new InvalidOperationException(
                    "Windows Forms synchronization context is unavailable.");
            using var menu = new ContextMenuStrip();
            var openItem = menu.Items.Add("打开 / Open");
            openItem.Click += (_, _) => OpenUi();
            using var icon = new NotifyIcon
            {
                ContextMenuStrip = menu,
                Icon = SystemIcons.Shield,
                Text = "DefaultAppGuard",
                Visible = true,
            };
            icon.DoubleClick += (_, _) => OpenUi();
            icon.BalloonTipClicked += (_, _) => OpenUi();

            lock (gate)
            {
                messageLoopContext = context;
                notifyIcon = icon;
                status = new UserNotificationStatus(
                    ChannelName,
                    true,
                    null,
                    null,
                    null,
                    null,
                    null);
            }

            initialized.Set();
            Application.Run();
            icon.Visible = false;
        }
        catch (Exception exception)
        {
            SetUnavailable(
                $"{exception.GetType().Name}: {exception.Message}");
            logger.LogWarning(
                exception,
                "The system notification channel could not start.");
        }
        finally
        {
            lock (gate)
            {
                messageLoopContext = null;
                notifyIcon = null;
                if (status.Available)
                {
                    status = new UserNotificationStatus(
                        ChannelName,
                        false,
                        stopping
                            ? "Notification channel stopped."
                            : "Notification message loop stopped unexpectedly.",
                        status.LastQueuedKind,
                        status.LastQueuedAtUtc,
                        status.ConfigurationRecoveryLastQueuedKind,
                        status.ConfigurationRecoveryLastQueuedAtUtc);
                }
            }

            initialized.Set();
        }
    }

    private void ShowDriftBalloon(
        NotifyIcon icon,
        DriftNotification notification)
    {
        try
        {
            var preview = string.Join(", ", notification.Extensions.Take(4));
            var remainder = notification.DriftCount > 4
                ? $" +{notification.DriftCount - 4}"
                : string.Empty;
            icon.BalloonTipIcon = ToolTipIcon.Warning;
            icon.BalloonTipTitle =
                "默认应用被更改 / Default app changed";
            icon.BalloonTipText =
                $"{notification.DriftCount} 个文件格式已偏离保护目标 / " +
                $"{notification.DriftCount} protected associations drifted\n" +
                $"{preview}{remainder}";
            icon.ShowBalloonTip(10_000);
        }
        catch (Exception exception)
        {
            SetUnavailable(
                $"{exception.GetType().Name}: {exception.Message}");
            logger.LogWarning(
                exception,
                "The system notification could not be displayed.");
        }
    }

    private void ShowConfigurationRecoveryBalloon(
        NotifyIcon icon,
        ConfigurationRecoveryNotification notification)
    {
        try
        {
            var defaultsRestored = string.Equals(
                notification.RecoveryCode,
                GuardConfigurationStore.DefaultsRestoredCode,
                StringComparison.Ordinal);
            icon.BalloonTipIcon = defaultsRestored
                ? ToolTipIcon.Warning
                : ToolTipIcon.Info;
            icon.BalloonTipTitle = defaultsRestored
                ? "保护设置已重置 / Settings reset"
                : "保护设置已恢复 / Settings restored";
            icon.BalloonTipText = defaultsRestored
                ? "主配置和备份均不可用，已启用全部安全默认保护。请打开应用检查设置。 / " +
                  "Both configuration copies were unusable. Safe defaults are active; open the app to review."
                : "已从最近一次有效备份恢复保护设置。请打开应用检查。 / " +
                  "Protection settings were restored from the last valid backup; open the app to review.";
            icon.ShowBalloonTip(10_000);
        }
        catch (Exception exception)
        {
            SetUnavailable(
                $"{exception.GetType().Name}: {exception.Message}");
            logger.LogWarning(
                exception,
                "The configuration recovery notification could not be displayed.");
        }
    }

    private void OpenUi()
    {
        try
        {
            using var process = Process.Start(
                new ProcessStartInfo(options.Url)
                {
                    UseShellExecute = true,
                });
            if (process is null)
            {
                throw new InvalidOperationException(
                    "Windows did not start the default browser.");
            }
        }
        catch (Exception exception)
        {
            logger.LogWarning(
                exception,
                "The Agent UI could not be opened from the tray icon.");
        }
    }

    private void SetUnavailable(string error)
    {
        lock (gate)
        {
            status = status with
            {
                Available = false,
                LastError = error,
            };
        }
    }

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }

        disposed = true;
        if (messageLoopThread is null || !messageLoopThread.IsAlive)
        {
            initialized.Dispose();
        }
    }
}
