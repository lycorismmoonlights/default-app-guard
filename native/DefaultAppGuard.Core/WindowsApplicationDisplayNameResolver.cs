using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Text;

namespace DefaultAppGuard.Core;

[SupportedOSPlatform("windows")]
public sealed class WindowsApplicationDisplayNameResolver
    : IApplicationDisplayNameResolver
{
    private const int OutputBufferLength = 4096;

    public string? Resolve(string? value)
    {
        var normalized = value?.Trim();
        if (string.IsNullOrWhiteSpace(normalized))
        {
            return null;
        }

        if (!normalized.StartsWith('@'))
        {
            return ContainsResourceReference(normalized) ? null : normalized;
        }

        var output = new StringBuilder(OutputBufferLength);
        var result = SHLoadIndirectString(
            normalized,
            output,
            (uint)output.Capacity,
            nint.Zero);
        if (result < 0)
        {
            return null;
        }

        var resolved = output.ToString().Trim();
        return string.IsNullOrWhiteSpace(resolved) ||
               resolved.StartsWith('@') ||
               ContainsResourceReference(resolved)
            ? null
            : resolved;
    }

    private static bool ContainsResourceReference(string value) =>
        value.Contains("ms-resource:", StringComparison.OrdinalIgnoreCase);

    [DllImport("shlwapi.dll", CharSet = CharSet.Unicode)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    private static extern int SHLoadIndirectString(
        string source,
        StringBuilder output,
        uint outputLength,
        nint reserved);
}
