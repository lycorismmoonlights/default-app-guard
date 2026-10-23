namespace DefaultAppGuard.Core;

public sealed record AssociationSnapshot(
    string Extension,
    string EffectiveProgId,
    string? UserChoiceProgId,
    bool UserChoiceHashPresent,
    string? ApplicationName,
    string? PackageId,
    string QuerySource,
    int QueryHResult = 0,
    string? AppUserModelId = null)
{
    public const int NoAssociationHResult = unchecked((int)0x80070483);

    public bool NoAssociation => QueryHResult == NoAssociationHResult &&
        string.IsNullOrWhiteSpace(EffectiveProgId);

    public bool PrimaryQueryCompleted =>
        QuerySource == AssociationConstants.PrimaryQueryAlgorithm &&
        ((QueryHResult == 0 && !string.IsNullOrWhiteSpace(EffectiveProgId)) ||
         NoAssociation);

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
    DateTimeOffset? CapturedAtUtc,
    string? ExpectedAppUserModelId = null);

public sealed record AssociationExpectedHandler(
    string Extension,
    string Category,
    string TargetStrategy,
    string ProgId,
    string? PackageId,
    string? ApplicationName,
    string? AppUserModelId = null);

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
