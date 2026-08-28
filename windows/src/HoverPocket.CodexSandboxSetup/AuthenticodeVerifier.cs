using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using HoverPocket.CodexSandboxSetup.Contracts;

namespace HoverPocket.CodexSandboxSetup;

internal sealed record AuthenticodeReadback(
    bool Trusted,
    string? SignerName,
    string? CertificateSha256);

internal static class AuthenticodeVerifier
{
    private static readonly Guid GenericVerifyV2 = new(
        "00AAC56B-CD44-11D0-8CC2-00C04FC295EE");

    internal static AuthenticodeReadback Read(string path)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException();
        }

        var trusted = VerifyTrust(path);
        if (!trusted)
        {
            return new AuthenticodeReadback(false, null, null);
        }

#pragma warning disable SYSLIB0057
        using var certificate = new X509Certificate2(X509Certificate.CreateFromSignedFile(path));
#pragma warning restore SYSLIB0057
        return new AuthenticodeReadback(
            true,
            certificate.GetNameInfo(X509NameType.SimpleName, forIssuer: false),
            Convert.ToHexStringLower(SHA256.HashData(certificate.RawData)));
    }

    internal static void VerifyExpectation(
        string path,
        AuthenticodeExpectation expectation)
    {
        var authenticode = Read(path);
        switch (expectation)
        {
            case AuthenticodeExpectation.OpenAi
                when !authenticode.Trusted
                    || !string.Equals(
                        authenticode.SignerName,
                        CodexVendorClosure.OpenAiSignerName,
                        StringComparison.Ordinal):
                throw new InvalidOperationException("HP_CODEX_SANDBOX_CLOSURE_SIGNER_MISMATCH");
            case AuthenticodeExpectation.Unsigned when authenticode.Trusted:
                throw new InvalidOperationException("HP_CODEX_SANDBOX_CLOSURE_SIGNATURE_STATE_MISMATCH");
        }
    }

    private static bool VerifyTrust(string path)
    {
        var pathPointer = Marshal.StringToCoTaskMemUni(path);
        var fileInfoPointer = IntPtr.Zero;
        try
        {
            var fileInfo = new WinTrustFileInfo
            {
                StructSize = (uint)Marshal.SizeOf<WinTrustFileInfo>(),
                FilePath = pathPointer,
            };
            fileInfoPointer = Marshal.AllocCoTaskMem(Marshal.SizeOf<WinTrustFileInfo>());
            Marshal.StructureToPtr(fileInfo, fileInfoPointer, false);

            var trustData = new WinTrustData
            {
                StructSize = (uint)Marshal.SizeOf<WinTrustData>(),
                UiChoice = 2,
                RevocationChecks = 0,
                UnionChoice = 1,
                FileInfo = fileInfoPointer,
                StateAction = 0,
                ProviderFlags = 0x00001000,
                UiContext = 0,
            };
            return WinVerifyTrust(new IntPtr(-1), GenericVerifyV2, ref trustData) == 0;
        }
        finally
        {
            if (fileInfoPointer != IntPtr.Zero)
            {
                Marshal.FreeCoTaskMem(fileInfoPointer);
            }
            Marshal.FreeCoTaskMem(pathPointer);
        }
    }

    [DllImport("wintrust.dll", ExactSpelling = true, SetLastError = true)]
    private static extern int WinVerifyTrust(
        IntPtr windowHandle,
        [MarshalAs(UnmanagedType.LPStruct)] Guid actionId,
        ref WinTrustData trustData);

    [StructLayout(LayoutKind.Sequential)]
    private struct WinTrustFileInfo
    {
        internal uint StructSize;
        internal IntPtr FilePath;
        internal IntPtr FileHandle;
        internal IntPtr KnownSubject;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct WinTrustData
    {
        internal uint StructSize;
        internal IntPtr PolicyCallbackData;
        internal IntPtr SipClientData;
        internal uint UiChoice;
        internal uint RevocationChecks;
        internal uint UnionChoice;
        internal IntPtr FileInfo;
        internal uint StateAction;
        internal IntPtr StateData;
        internal IntPtr UrlReference;
        internal uint ProviderFlags;
        internal uint UiContext;
        internal IntPtr SignatureSettings;
    }
}
