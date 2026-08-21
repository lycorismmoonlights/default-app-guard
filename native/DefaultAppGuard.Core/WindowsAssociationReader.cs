using System.Runtime.Versioning;

namespace DefaultAppGuard.Core;

[SupportedOSPlatform("windows")]
public sealed class WindowsAssociationReader(
    IEffectiveAssociationQuery effectiveQuery,
    IAssociationRegistrySource registrySource) : IAssociationSnapshotReader
{
    public WindowsAssociationReader()
        : this(
            new ApplicationAssociationRegistrationQuery(),
            new WindowsAssociationRegistrySource())
    {
    }

    public AssociationSnapshot Read(string extension)
    {
        var normalized = ExtensionName.Normalize(extension);

        // QueryCurrentDefault is the primary result. Registry values are evidence only.
        var effectiveProgId = effectiveQuery.QueryEffectiveProgId(normalized);
        var userChoice = registrySource.ReadUserChoice(normalized);
        var metadata = registrySource.ReadProgIdMetadata(effectiveProgId);

        return new AssociationSnapshot(
            normalized,
            effectiveProgId,
            userChoice.ProgId,
            userChoice.HashPresent,
            metadata.ApplicationName,
            metadata.PackageId,
            AssociationConstants.PrimaryQueryAlgorithm);
    }

    public IReadOnlyList<AssociationSnapshot> ReadMany(IEnumerable<string> extensions)
    {
        ArgumentNullException.ThrowIfNull(extensions);
        return extensions.Select(Read).ToArray();
    }
}
