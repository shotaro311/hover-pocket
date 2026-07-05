using HoverPocket.Shell.Interop;

namespace HoverPocket.Shell.Verification;

internal static class VerifyConsole
{
    public static void AttachParent()
    {
        NativeMethods.AttachParentConsole();
    }

    public static void WriteLine(string message)
    {
        Console.WriteLine(message);
    }
}
