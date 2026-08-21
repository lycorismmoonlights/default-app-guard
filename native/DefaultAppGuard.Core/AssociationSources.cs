namespace DefaultAppGuard.Core;

public interface IEffectiveAssociationQuery
{
    string QueryEffectiveProgId(string extension);
}

public interface IAssociationSnapshotReader
{
    AssociationSnapshot Read(string extension);

    IReadOnlyList<AssociationSnapshot> ReadMany(
        IEnumerable<string> extensions);
}

public interface IMediaPlayerTargetResolver
{
    AssociationTarget Resolve(IEnumerable<string> extensions);
}

public interface IAssociationRegistrySource
{
    UserChoiceEvidence ReadUserChoice(string extension);

    ProgIdMetadata ReadProgIdMetadata(string progId);

    IReadOnlyList<string> ReadOpenWithProgIds(string extension);
}

public interface IApplicationDisplayNameResolver
{
    string? Resolve(string? value);
}

public sealed record UserChoiceEvidence(string? ProgId, bool HashPresent);

public sealed record ProgIdMetadata(
    string ProgId,
    string? ApplicationName,
    string? ApplicationCompany,
    string? PackageId,
    string? AppUserModelId);
