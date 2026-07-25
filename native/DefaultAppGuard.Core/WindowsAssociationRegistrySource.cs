using Microsoft.Win32;
using System.Runtime.Versioning;

namespace DefaultAppGuard.Core;

[SupportedOSPlatform("windows")]
public sealed class WindowsAssociationRegistrySource : IAssociationRegistrySource
{
    private const string FileExtsPath =
        @"Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts";

    public UserChoiceEvidence ReadUserChoice(string extension)
    {
        var normalized = ExtensionName.Normalize(extension);
        using var key = Registry.CurrentUser.OpenSubKey(
            $@"{FileExtsPath}\{normalized}\UserChoice",
            writable: false);

        return new UserChoiceEvidence(
            key?.GetValue("ProgId") as string,
            key?.GetValue("Hash") is string hash && !string.IsNullOrWhiteSpace(hash));
    }

    public ProgIdMetadata ReadProgIdMetadata(string progId)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(progId);

        using var applicationKey = Registry.ClassesRoot.OpenSubKey(
            $@"{progId}\Application",
            writable: false);
        using var openKey = Registry.ClassesRoot.OpenSubKey(
            $@"{progId}\Shell\open",
            writable: false);

        return new ProgIdMetadata(
            progId,
            applicationKey?.GetValue("ApplicationName") as string,
            applicationKey?.GetValue("ApplicationCompany") as string,
            openKey?.GetValue("PackageId") as string,
            applicationKey?.GetValue("AppUserModelID") as string);
    }

    public IReadOnlyList<string> ReadOpenWithProgIds(string extension)
    {
        var normalized = ExtensionName.Normalize(extension);
        using var key = Registry.ClassesRoot.OpenSubKey(
            $@"{normalized}\OpenWithProgids",
            writable: false);

        return key?.GetValueNames()
                   .Where(value => !string.IsNullOrWhiteSpace(value))
                   .Order(StringComparer.OrdinalIgnoreCase)
                   .ToArray()
            ?? [];
    }
}
