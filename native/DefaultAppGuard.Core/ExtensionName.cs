namespace DefaultAppGuard.Core;

public static class ExtensionName
{
    public static string Normalize(string value)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(value);

        var normalized = value.Trim();
        if (!normalized.StartsWith('.'))
        {
            normalized = $".{normalized}";
        }

        if (normalized.Length < 2 ||
            normalized.Any(character =>
                !(char.IsAsciiLetterOrDigit(character) || character is '.' or '_' or '-')))
        {
            throw new ArgumentException($"Invalid file extension: {value}", nameof(value));
        }

        return normalized.ToLowerInvariant();
    }
}
