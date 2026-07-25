using System.Runtime.Versioning;

namespace DefaultAppGuard.Core;

public sealed record AssociationAuditItem(
    string Extension,
    bool Healthy,
    AssociationSnapshot? Snapshot,
    string? Error);

public sealed record AssociationAuditResult(
    AssociationTarget Target,
    IReadOnlyList<AssociationAuditItem> Items,
    DateTimeOffset AuditedAtUtc)
{
    public bool Healthy => Items.All(item => item.Healthy);

    public int HealthyCount => Items.Count(item => item.Healthy);

    public int DriftCount => Items.Count - HealthyCount;
}

[SupportedOSPlatform("windows")]
public sealed class AssociationAuditService(
    WindowsAssociationReader reader,
    MediaPlayerTargetResolver resolver)
{
    public AssociationAuditService()
        : this(
            new WindowsAssociationReader(),
            new MediaPlayerTargetResolver())
    {
    }

    public AssociationAuditResult Audit(IEnumerable<string> extensions)
    {
        ArgumentNullException.ThrowIfNull(extensions);
        var normalized = extensions
            .Select(ExtensionName.Normalize)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Order(StringComparer.OrdinalIgnoreCase)
            .ToArray();
        var target = resolver.Resolve(normalized);
        var items = normalized.Select(extension =>
        {
            try
            {
                var snapshot = reader.Read(extension);
                var healthy = string.Equals(
                                  snapshot.EffectiveProgId,
                                  target.ProgId,
                                  StringComparison.OrdinalIgnoreCase) &&
                              snapshot.RegistryEvidenceMatches &&
                              snapshot.UserChoiceHashPresent;
                return new AssociationAuditItem(
                    extension,
                    healthy,
                    snapshot,
                    healthy
                        ? null
                        : "Effective handler or UserChoice evidence does not match.");
            }
            catch (Exception exception)
            {
                return new AssociationAuditItem(
                    extension,
                    false,
                    null,
                    $"{exception.GetType().Name}: {exception.Message}");
            }
        }).ToArray();

        return new AssociationAuditResult(
            target,
            items,
            DateTimeOffset.UtcNow);
    }
}
