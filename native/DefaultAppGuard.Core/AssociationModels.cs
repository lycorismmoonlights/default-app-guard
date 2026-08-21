namespace DefaultAppGuard.Core;

public sealed record AssociationSnapshot(
    string Extension,
    string EffectiveProgId,
    string? UserChoiceProgId,
    bool UserChoiceHashPresent,
    string? ApplicationName,
    string? PackageId,
    string QuerySource)
{
    public bool RegistryEvidenceMatches =>
        string.Equals(EffectiveProgId, UserChoiceProgId, StringComparison.OrdinalIgnoreCase);
}

public sealed record AssociationTarget(
    string ProgId,
    string PackageId,
    string? AppUserModelId,
    string? ApplicationName,
    IReadOnlyList<string> SupportedExtensions);

public sealed record ProtectedAssociationRule(
    string Extension,
    string Category,
    string TargetStrategy,
    string? ExpectedProgId,
    string? ExpectedPackageId,
    string? ExpectedApplicationName,
    DateTimeOffset? CapturedAtUtc);

public sealed record AssociationExpectedHandler(
    string Extension,
    string Category,
    string TargetStrategy,
    string ProgId,
    string? PackageId,
    string? ApplicationName);

public sealed record AssociationPlanItem(
    string Extension,
    string EffectiveProgId,
    string DesiredProgId,
    bool IsMatch,
    bool RegistryEvidenceMatches);

public sealed record AssociationPlan(
    AssociationTarget Target,
    IReadOnlyList<AssociationPlanItem> Items)
{
    public bool IsSatisfied => Items.All(item => item.IsMatch);
}
