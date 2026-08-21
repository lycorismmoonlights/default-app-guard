namespace DefaultAppGuard.Core;

public sealed record AssociationCatalogEntry(
    string Extension,
    string Category,
    string Label);

public static class AssociationCatalog
{
    public const string VideoCategory = "video";
    public const string AudioCategory = "audio";
    public const string DocumentCategory = "document";
    public const string ImageCategory = "image";
    public const string ArchiveCategory = "archive";
    public const string WebDataCategory = "web-data";

    public static readonly IReadOnlyList<AssociationCatalogEntry> Entries =
        BuildEntries();

    public static bool TryGet(
        string extension,
        out AssociationCatalogEntry entry)
    {
        var normalized = ExtensionName.Normalize(extension);
        entry = Entries.FirstOrDefault(item => string.Equals(
            item.Extension,
            normalized,
            StringComparison.OrdinalIgnoreCase))!;
        return entry is not null;
    }

    public static AssociationCatalogEntry Get(string extension)
    {
        if (!TryGet(extension, out var entry))
        {
            throw new ArgumentException(
                $"Unsupported file extension: {extension}",
                nameof(extension));
        }

        return entry;
    }

    private static IReadOnlyList<AssociationCatalogEntry> BuildEntries()
    {
        var entries = new List<AssociationCatalogEntry>();
        Add(entries, VideoCategory, AssociationConstants.VideoExtensions);
        Add(entries, AudioCategory,
        [
            ".aac", ".ac3", ".aiff", ".alac", ".amr", ".flac",
            ".m4a", ".mp3", ".oga", ".ogg", ".opus", ".wav", ".wma",
        ]);
        Add(entries, DocumentCategory,
        [
            ".csv", ".doc", ".docm", ".docx", ".dot", ".dotx",
            ".epub", ".md", ".mobi", ".odf", ".odg", ".odp", ".ods",
            ".odt", ".pdf", ".ppt", ".pptm", ".pptx", ".rtf", ".txt",
            ".xls", ".xlsm", ".xlsx",
        ]);
        Add(entries, ImageCategory,
        [
            ".avif", ".bmp", ".gif", ".heic", ".heif", ".ico",
            ".jfif", ".jpeg", ".jpg", ".png", ".svg", ".tif", ".tiff",
            ".webp",
        ]);
        Add(entries, ArchiveCategory,
        [
            ".7z", ".bz2", ".cab", ".gz", ".iso", ".rar", ".tar",
            ".tgz", ".xz", ".zip", ".zst",
        ]);
        Add(entries, WebDataCategory,
        [
            ".htm", ".html", ".json", ".xml",
        ]);
        return entries
            .OrderBy(entry => entry.Category, StringComparer.Ordinal)
            .ThenBy(entry => entry.Extension, StringComparer.OrdinalIgnoreCase)
            .ToArray();
    }

    private static void Add(
        ICollection<AssociationCatalogEntry> entries,
        string category,
        IEnumerable<string> extensions)
    {
        foreach (var extension in extensions)
        {
            var normalized = ExtensionName.Normalize(extension);
            entries.Add(new AssociationCatalogEntry(
                normalized,
                category,
                normalized.TrimStart('.').ToUpperInvariant()));
        }
    }
}
