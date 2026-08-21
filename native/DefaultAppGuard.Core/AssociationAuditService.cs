using System.Runtime.Versioning;

namespace DefaultAppGuard.Core;

public sealed record AssociationAuditItem(
    string Extension,
    AssociationExpectedHandler Expected,
    bool Healthy,
    AssociationSnapshot? Snapshot,
    string? Error);

public sealed record AssociationAuditResult(
    IReadOnlyList<AssociationExpectedHandler> ExpectedHandlers,
    IReadOnlyList<AssociationAuditItem> Items,
    DateTimeOffset AuditedAtUtc)
{
    public bool Healthy => Items.All(item => item.Healthy);

    public int HealthyCount => Items.Count(item => item.Healthy);

    public int DriftCount => Items.Count - HealthyCount;
}

[SupportedOSPlatform("windows")]
public sealed class AssociationAuditService(
    IAssociationSnapshotReader reader,
    IMediaPlayerTargetResolver resolver)
{
    public AssociationAuditService()
        : this(
            new WindowsAssociationReader(),
            new MediaPlayerTargetResolver())
    {
    }

    public AssociationAuditResult Audit(
        IEnumerable<ProtectedAssociationRule> rules)
    {
        ArgumentNullException.ThrowIfNull(rules);
        var normalizedRules = rules
            .Select(NormalizeRule)
            .OrderBy(rule => rule.Extension, StringComparer.OrdinalIgnoreCase)
            .ToArray();
        if (normalizedRules.Length == 0)
        {
            throw new ArgumentException(
                "At least one protected association is required.",
                nameof(rules));
        }

        var duplicate = normalizedRules
            .GroupBy(rule => rule.Extension, StringComparer.OrdinalIgnoreCase)
            .FirstOrDefault(group => group.Count() > 1);
        if (duplicate is not null)
        {
            throw new ArgumentException(
                $"Duplicate protected association: {duplicate.Key}",
                nameof(rules));
        }

        var mediaRules = normalizedRules.Where(rule => string.Equals(
            rule.TargetStrategy,
            AssociationConstants.MediaPlayerTargetStrategy,
            StringComparison.Ordinal)).ToArray();
        var mediaTarget = mediaRules.Length == 0
            ? null
            : resolver.Resolve(mediaRules.Select(rule => rule.Extension));
        var expectedHandlers = normalizedRules.Select(rule =>
        {
            if (string.Equals(
                rule.TargetStrategy,
                AssociationConstants.MediaPlayerTargetStrategy,
                StringComparison.Ordinal))
            {
                return new AssociationExpectedHandler(
                    rule.Extension,
                    rule.Category,
                    rule.TargetStrategy,
                    mediaTarget!.ProgId,
                    mediaTarget.PackageId,
                    mediaTarget.ApplicationName);
            }

            if (!string.Equals(
                    rule.TargetStrategy,
                    AssociationConstants.CapturedCurrentTargetStrategy,
                    StringComparison.Ordinal) ||
                string.IsNullOrWhiteSpace(rule.ExpectedProgId))
            {
                throw new InvalidDataException(
                    $"Protected association target is invalid: {rule.Extension}");
            }

            return new AssociationExpectedHandler(
                rule.Extension,
                rule.Category,
                rule.TargetStrategy,
                rule.ExpectedProgId,
                rule.ExpectedPackageId,
                rule.ExpectedApplicationName);
        }).ToArray();

        var items = expectedHandlers.Select(expected =>
        {
            try
            {
                var snapshot = reader.Read(expected.Extension);
                if (!string.Equals(
                    snapshot.Extension,
                    expected.Extension,
                    StringComparison.OrdinalIgnoreCase))
                {
                    throw new InvalidOperationException(
                        $"Windows returned association data for {snapshot.Extension} " +
                        $"while auditing {expected.Extension}.");
                }
                if (!string.Equals(
                    snapshot.QuerySource,
                    AssociationConstants.PrimaryQueryAlgorithm,
                    StringComparison.Ordinal))
                {
                    throw new InvalidOperationException(
                        $"The handler for {expected.Extension} was not read by " +
                        "the primary COM query.");
                }

                var healthy = string.Equals(
                                  snapshot.EffectiveProgId,
                                  expected.ProgId,
                                  StringComparison.OrdinalIgnoreCase);
                return new AssociationAuditItem(
                    expected.Extension,
                    expected,
                    healthy,
                    snapshot,
                    healthy
                        ? null
                        : "The effective handler does not match the protected baseline.");
            }
            catch (Exception exception) when (
                AssociationReadFailure.IsExpected(exception))
            {
                return new AssociationAuditItem(
                    expected.Extension,
                    expected,
                    false,
                    null,
                    $"{exception.GetType().Name}: {exception.Message}");
            }
        }).ToArray();

        return new AssociationAuditResult(
            expectedHandlers,
            items,
            DateTimeOffset.UtcNow);
    }

    public AssociationAuditResult AuditMediaPlayer(
        IEnumerable<string> extensions) =>
        Audit(extensions.Select(extension =>
            new AssociationRuleFactory().CreateDefault(extension)));

    private static ProtectedAssociationRule NormalizeRule(
        ProtectedAssociationRule rule)
    {
        ArgumentNullException.ThrowIfNull(rule);
        var entry = AssociationCatalog.Get(rule.Extension);
        if (!string.Equals(
            entry.Category,
            rule.Category,
            StringComparison.Ordinal))
        {
            throw new InvalidDataException(
                $"Protected association category is invalid: {entry.Extension}");
        }

        var isVideo = string.Equals(
            entry.Category,
            AssociationCatalog.VideoCategory,
            StringComparison.Ordinal);
        var expectedStrategy = isVideo
            ? AssociationConstants.MediaPlayerTargetStrategy
            : AssociationConstants.CapturedCurrentTargetStrategy;
        if (!string.Equals(
            rule.TargetStrategy,
            expectedStrategy,
            StringComparison.Ordinal))
        {
            throw new InvalidDataException(
                $"Protected association target strategy is invalid: {entry.Extension}");
        }

        if (!isVideo &&
            (string.IsNullOrWhiteSpace(rule.ExpectedProgId) ||
             rule.CapturedAtUtc is null))
        {
            throw new InvalidDataException(
                $"Protected association baseline is incomplete: {entry.Extension}");
        }

        return rule with { Extension = entry.Extension };
    }
}
