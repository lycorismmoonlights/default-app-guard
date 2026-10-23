using System.Runtime.Versioning;
using System.Runtime.InteropServices;

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
        string effectiveProgId;
        try
        {
            effectiveProgId = effectiveQuery.QueryEffectiveProgId(normalized);
        }
        catch (COMException exception) when (
            exception.HResult == AssociationSnapshot.NoAssociationHResult)
        {
            // Preserve the COM result; stale UserChoice data is not a substitute.
            return new AssociationSnapshot(
                normalized, string.Empty, null, false, null, null,
                AssociationConstants.PrimaryQueryAlgorithm,
                exception.HResult);
        }
        if (string.IsNullOrWhiteSpace(effectiveProgId))
        {
            throw new InvalidOperationException(
                $"Windows returned an empty effective ProgID for {normalized}.");
        }
        var userChoice = registrySource.ReadUserChoice(normalized);
        var metadata = registrySource.ReadProgIdMetadata(effectiveProgId);

        return new AssociationSnapshot(
            normalized,
            effectiveProgId,
            userChoice.ProgId,
            userChoice.HashPresent,
            metadata.ApplicationName,
            metadata.PackageId,
            AssociationConstants.PrimaryQueryAlgorithm,
            AppUserModelId: metadata.AppUserModelId);
    }

    public IReadOnlyList<AssociationSnapshot> ReadMany(IEnumerable<string> extensions)
    {
        ArgumentNullException.ThrowIfNull(extensions);
        return extensions.Select(Read).ToArray();
    }
}
