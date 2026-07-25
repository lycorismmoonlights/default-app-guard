namespace DefaultAppGuard.Core;

public static class AssociationPlanEvaluator
{
    public static AssociationPlan Create(
        AssociationTarget target,
        IEnumerable<AssociationSnapshot> snapshots)
    {
        ArgumentNullException.ThrowIfNull(target);
        ArgumentNullException.ThrowIfNull(snapshots);

        var snapshotByExtension = snapshots.ToDictionary(
            snapshot => ExtensionName.Normalize(snapshot.Extension),
            StringComparer.OrdinalIgnoreCase);
        var items = target.SupportedExtensions
            .Select(extension =>
            {
                if (!snapshotByExtension.TryGetValue(extension, out var snapshot))
                {
                    throw new InvalidOperationException(
                        $"No effective association snapshot was supplied for {extension}.");
                }

                return new AssociationPlanItem(
                    extension,
                    snapshot.EffectiveProgId,
                    target.ProgId,
                    string.Equals(
                        snapshot.EffectiveProgId,
                        target.ProgId,
                        StringComparison.OrdinalIgnoreCase),
                    snapshot.RegistryEvidenceMatches);
            })
            .ToArray();

        return new AssociationPlan(target, items);
    }
}
