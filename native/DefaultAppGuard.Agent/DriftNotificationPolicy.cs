using DefaultAppGuard.Core;

namespace DefaultAppGuard.Agent;

public sealed record DriftNotification(
    int DriftCount,
    IReadOnlyList<string> Extensions);

public sealed class DriftNotificationPolicy
{
    private readonly TimeSpan repeatInterval;
    private string? lastFingerprint;
    private DateTimeOffset? lastNotificationAtUtc;

    public DriftNotificationPolicy(TimeSpan repeatInterval)
    {
        if (repeatInterval <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(nameof(repeatInterval));
        }

        this.repeatInterval = repeatInterval;
    }

    public DriftNotification? Evaluate(
        AssociationAuditResult? audit,
        bool notificationsEnabled,
        bool channelAvailable,
        DateTimeOffset nowUtc)
    {
        if (!notificationsEnabled || audit is null || audit.Healthy)
        {
            Reset();
            return null;
        }

        if (!channelAvailable)
        {
            return null;
        }

        var extensions = audit.Items
            .Where(item => !item.Healthy)
            .Select(item => item.Extension)
            .Order(StringComparer.OrdinalIgnoreCase)
            .ToArray();
        var fingerprint = string.Join("|", extensions);
        var changed = !string.Equals(
            fingerprint,
            lastFingerprint,
            StringComparison.OrdinalIgnoreCase);
        var repeatDue = lastNotificationAtUtc is null ||
                        nowUtc - lastNotificationAtUtc >= repeatInterval;
        if (!changed && !repeatDue)
        {
            return null;
        }

        lastFingerprint = fingerprint;
        lastNotificationAtUtc = nowUtc;
        return new DriftNotification(extensions.Length, extensions);
    }

    private void Reset()
    {
        lastFingerprint = null;
        lastNotificationAtUtc = null;
    }
}
