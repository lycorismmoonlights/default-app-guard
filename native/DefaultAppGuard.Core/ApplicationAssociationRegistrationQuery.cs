using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace DefaultAppGuard.Core;

[SupportedOSPlatform("windows")]
public sealed class ApplicationAssociationRegistrationQuery : IEffectiveAssociationQuery
{
    private static readonly Guid RegistrationClassId =
        new("591209C7-767B-42B2-9FBA-44EE4615F2C7");

    public string QueryEffectiveProgId(string extension)
    {
        var normalized = ExtensionName.Normalize(extension);
        var registrationType = Type.GetTypeFromCLSID(RegistrationClassId, throwOnError: true)
            ?? throw new InvalidOperationException(
                "Windows ApplicationAssociationRegistration COM class is unavailable.");
        var instance = Activator.CreateInstance(registrationType)
            ?? throw new InvalidOperationException(
                "Windows ApplicationAssociationRegistration COM class could not be created.");
        var registration = (IApplicationAssociationRegistration)instance;

        try
        {
            var result = registration.QueryCurrentDefault(
                normalized,
                AssociationType.FileExtension,
                AssociationLevel.Effective,
                out var progId);
            Marshal.ThrowExceptionForHR(result);

            if (string.IsNullOrWhiteSpace(progId))
            {
                throw new InvalidOperationException(
                    $"Windows returned no effective ProgID for {normalized}.");
            }

            return progId;
        }
        finally
        {
            if (Marshal.IsComObject(registration))
            {
                Marshal.FinalReleaseComObject(registration);
            }
        }
    }

    private enum AssociationType
    {
        FileExtension = 0,
        UrlProtocol = 1,
        StartMenuClient = 2,
        MimeType = 3,
    }

    private enum AssociationLevel
    {
        Machine = 0,
        Effective = 1,
        User = 2,
    }

    [ComImport]
    [Guid("4E530B0A-E611-4C77-A3AC-9031D022281B")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IApplicationAssociationRegistration
    {
        [PreserveSig]
        int QueryCurrentDefault(
            [MarshalAs(UnmanagedType.LPWStr)] string query,
            AssociationType queryType,
            AssociationLevel queryLevel,
            [MarshalAs(UnmanagedType.LPWStr)] out string association);
    }
}
