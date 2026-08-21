using System.Runtime.InteropServices;
using System.Security;

namespace DefaultAppGuard.Core;

public static class AssociationReadFailure
{
    public static bool IsExpected(Exception exception) => exception is
        InvalidOperationException or
        IOException or
        UnauthorizedAccessException or
        SecurityException or
        COMException;
}
