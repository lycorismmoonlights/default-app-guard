namespace DefaultAppGuard.Core;

public sealed class AssociationRuleFactory(
    IAssociationSnapshotReader reader)
{
    public AssociationRuleFactory()
        : this(new WindowsAssociationReader())
    {
    }

    public ProtectedAssociationRule CreateDefault(string extension)
    {
        var entry = AssociationCatalog.Get(extension);
        if (!string.Equals(
            entry.Category,
            AssociationCatalog.VideoCategory,
            StringComparison.Ordinal))
        {
            throw new ArgumentException(
                "Only video formats have a predefined target.",
                nameof(extension));
        }

        return new ProtectedAssociationRule(
            entry.Extension,
            entry.Category,
            AssociationConstants.MediaPlayerTargetStrategy,
            null,
            null,
            "Microsoft Media Player",
            null);
    }

    public ProtectedAssociationRule CaptureCurrent(string extension)
    {
        var entry = AssociationCatalog.Get(extension);
        if (string.Equals(
            entry.Category,
            AssociationCatalog.VideoCategory,
            StringComparison.Ordinal))
        {
            return CreateDefault(entry.Extension);
        }

        var snapshot = reader.Read(entry.Extension);
        if (!string.Equals(
            snapshot.Extension,
            entry.Extension,
            StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException(
                $"Windows returned association data for {snapshot.Extension} " +
                $"while capturing {entry.Extension}.");
        }
        if (string.IsNullOrWhiteSpace(snapshot.EffectiveProgId))
        {
            throw new InvalidOperationException(
                $"Windows did not report a current handler for {entry.Extension}.");
        }
        if (!string.Equals(
            snapshot.QuerySource,
            AssociationConstants.PrimaryQueryAlgorithm,
            StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                $"The current handler for {entry.Extension} was not read by the primary COM query.");
        }

        return new ProtectedAssociationRule(
            entry.Extension,
            entry.Category,
            AssociationConstants.CapturedCurrentTargetStrategy,
            snapshot.EffectiveProgId,
            snapshot.PackageId,
            snapshot.ApplicationName,
            DateTimeOffset.UtcNow);
    }
}
