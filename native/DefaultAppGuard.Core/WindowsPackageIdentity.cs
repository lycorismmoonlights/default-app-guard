using System.Runtime.InteropServices;
using System.Text;

namespace DefaultAppGuard.Core;

internal static class WindowsPackageIdentity
{
    internal static string? FamilyName(string? fullName)
    {
        if (string.IsNullOrWhiteSpace(fullName)) return null;
        uint length = 0;
        if (PackageFamilyNameFromFullName(fullName, ref length, null) != 122 ||
            length is < 2 or > 256)
        {
            return null;
        }
        var buffer = new StringBuilder((int)length);
        return PackageFamilyNameFromFullName(fullName, ref length, buffer) == 0
            ? buffer.ToString()
            : null;
    }

    internal static bool SameApplication(
        string? expectedPackage,
        string? expectedAppId,
        string? actualPackage,
        string? actualAppId)
    {
        var expectedFamily = FamilyName(expectedPackage);
        var actualFamily = FamilyName(actualPackage);
        return expectedFamily is not null &&
            string.Equals(expectedFamily, actualFamily, StringComparison.OrdinalIgnoreCase) &&
            expectedAppId?.StartsWith(expectedFamily + "!", StringComparison.OrdinalIgnoreCase) is true &&
            string.Equals(expectedAppId, actualAppId, StringComparison.OrdinalIgnoreCase);
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern int PackageFamilyNameFromFullName(
        string packageFullName,
        ref uint packageFamilyNameLength,
        StringBuilder? packageFamilyName);
}
