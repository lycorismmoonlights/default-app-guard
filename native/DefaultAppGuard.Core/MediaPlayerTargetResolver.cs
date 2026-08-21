using System.Runtime.Versioning;

namespace DefaultAppGuard.Core;

[SupportedOSPlatform("windows")]
public sealed class MediaPlayerTargetResolver(IAssociationRegistrySource registrySource)
    : IMediaPlayerTargetResolver
{
    public MediaPlayerTargetResolver()
        : this(new WindowsAssociationRegistrySource())
    {
    }

    public AssociationTarget Resolve(IEnumerable<string> extensions)
    {
        ArgumentNullException.ThrowIfNull(extensions);
        var normalizedExtensions = extensions
            .Select(ExtensionName.Normalize)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Order(StringComparer.OrdinalIgnoreCase)
            .ToArray();

        if (normalizedExtensions.Length == 0)
        {
            throw new ArgumentException("At least one extension is required.", nameof(extensions));
        }

        var candidatesByExtension = normalizedExtensions.ToDictionary(
            extension => extension,
            extension => registrySource.ReadOpenWithProgIds(extension)
                .Select(registrySource.ReadProgIdMetadata)
                .Where(IsMicrosoftMediaPlayer)
                .ToArray(),
            StringComparer.OrdinalIgnoreCase);

        var commonProgIds = candidatesByExtension.Values
            .Select(candidates => candidates.Select(candidate => candidate.ProgId)
                .ToHashSet(StringComparer.OrdinalIgnoreCase))
            .Aggregate((left, right) =>
            {
                left.IntersectWith(right);
                return left;
            });

        if (commonProgIds.Count != 1)
        {
            var details = string.Join(
                "; ",
                candidatesByExtension.Select(pair =>
                    $"{pair.Key}=[{string.Join(',', pair.Value.Select(value => value.ProgId))}]"));
            throw new InvalidOperationException(
                $"Expected exactly one Media Player ProgID common to every extension. {details}");
        }

        var progId = commonProgIds.Single();
        var metadata = registrySource.ReadProgIdMetadata(progId);
        return new AssociationTarget(
            progId,
            metadata.PackageId!,
            metadata.AppUserModelId,
            metadata.ApplicationName,
            normalizedExtensions);
    }

    private static bool IsMicrosoftMediaPlayer(ProgIdMetadata metadata)
    {
        return metadata.PackageId?.StartsWith(
                   $"{AssociationConstants.MediaPlayerPackageName}_",
                   StringComparison.OrdinalIgnoreCase) is true &&
               string.Equals(
                   metadata.ApplicationCompany,
                   "Microsoft Corporation",
                   StringComparison.OrdinalIgnoreCase);
    }
}
