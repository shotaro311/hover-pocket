using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Principal;
using HoverPocket.CodexSandboxSetup.Contracts;
using Microsoft.Win32.SafeHandles;

namespace HoverPocket.CodexSandboxSetup;

internal sealed class AdmittedSetupRequest : IDisposable
{
    private readonly SafeProcessHandle _hostProcess;
    private readonly IReadOnlyList<FileStream> _sourceHandles;

    internal AdmittedSetupRequest(
        SetupRequest request,
        SafeProcessHandle hostProcess,
        IReadOnlyList<FileStream> sourceHandles)
    {
        Request = request;
        _hostProcess = hostProcess;
        _sourceHandles = sourceHandles;
    }

    internal SetupRequest Request { get; }
    internal IReadOnlyList<FileStream> SourceHandles => _sourceHandles;

    public void Dispose()
    {
        foreach (var sourceHandle in _sourceHandles)
        {
            sourceHandle.Dispose();
        }
        _hostProcess.Dispose();
    }
}

internal static class SetupRequestAdmission
{
    private const uint ProcessDuplicateHandle = 0x0040;
    private const uint ProcessQueryLimitedInformation = 0x1000;
    private const uint DuplicateSameAccess = 0x00000002;

    internal static AdmittedSetupRequest Admit(
        string base64Json,
        string expectedSha256,
        string expectedNonce,
        DateTimeOffset now)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException();
        }
        if (!new WindowsPrincipal(WindowsIdentity.GetCurrent())
            .IsInRole(WindowsBuiltInRole.Administrator))
        {
            throw new InvalidOperationException("HP_CODEX_SANDBOX_HELPER_NOT_ELEVATED");
        }

        var request = SetupRequestContract.DecodeAndValidate(
            base64Json,
            expectedSha256,
            expectedNonce,
            now);
        var processHandle = OpenProcess(
            ProcessDuplicateHandle | ProcessQueryLimitedInformation,
            inheritHandle: false,
            (uint)request.HostProcessId);
        if (processHandle.IsInvalid)
        {
            throw new InvalidOperationException("HP_CODEX_SANDBOX_HOST_PROCESS_UNAVAILABLE");
        }

        var sourceHandles = new List<FileStream>();
        try
        {
            VerifyOriginalIdentity(processHandle, request);
            PublisherTrust.VerifyHostAndHelper(QueryProcessImagePath(processHandle));
            foreach (var artifact in request.Artifacts)
            {
                if (!DuplicateHandle(
                    processHandle,
                    new IntPtr(artifact.HandleValue),
                    GetCurrentProcess(),
                    out var duplicated,
                    desiredAccess: 0,
                    inheritHandle: false,
                    DuplicateSameAccess))
                {
                    throw new InvalidOperationException("HP_CODEX_SANDBOX_SOURCE_HANDLE_INVALID");
                }

                SafeFileHandle? safeHandle = new(duplicated, ownsHandle: true);
                try
                {
                    var stream = new FileStream(safeHandle, FileAccess.Read);
                    safeHandle = null;
                    VerifyDuplicatedSource(stream, artifact);
                    sourceHandles.Add(stream);
                }
                finally
                {
                    safeHandle?.Dispose();
                }
            }

            return new AdmittedSetupRequest(request, processHandle, sourceHandles.ToArray());
        }
        catch
        {
            processHandle.Dispose();
            foreach (var sourceHandle in sourceHandles)
            {
                sourceHandle.Dispose();
            }
            throw;
        }
    }

    private static void VerifyOriginalIdentity(SafeProcessHandle processHandle, SetupRequest request)
    {
        if (!OpenProcessToken(processHandle, TokenAccessLevels.Query, out var tokenHandle))
        {
            throw new InvalidOperationException("HP_CODEX_SANDBOX_HOST_TOKEN_UNAVAILABLE");
        }

        using (tokenHandle)
        using (var identity = new WindowsIdentity(tokenHandle.DangerousGetHandle()))
        {
            var actualSid = identity.User?.Value;
            if (!string.Equals(actualSid, request.OriginalUserSid, StringComparison.Ordinal))
            {
                throw new InvalidOperationException("HP_CODEX_SANDBOX_HOST_SID_MISMATCH");
            }
        }

        SecurityIdentifier resolvedSid;
        try
        {
            resolvedSid = (SecurityIdentifier)new NTAccount(request.OriginalUserName)
                .Translate(typeof(SecurityIdentifier));
        }
        catch (IdentityNotMappedException)
        {
            throw new InvalidOperationException("HP_CODEX_SANDBOX_ACCOUNT_NOT_RESOLVED");
        }
        if (!string.Equals(
            resolvedSid.Value,
            request.OriginalUserSid,
            StringComparison.Ordinal))
        {
            throw new InvalidOperationException("HP_CODEX_SANDBOX_ACCOUNT_SID_MISMATCH");
        }
    }

    private static void VerifyDuplicatedSource(
        FileStream stream,
        SetupArtifactHandle artifact)
    {
        if (!stream.CanRead || !stream.CanSeek || stream.Length != artifact.Size)
        {
            throw new InvalidOperationException("HP_CODEX_SANDBOX_SOURCE_HANDLE_INVALID");
        }

        stream.Position = 0;
        var hash = Convert.ToHexStringLower(SHA256.HashData(stream));
        stream.Position = 0;
        if (!string.Equals(hash, artifact.Sha256, StringComparison.Ordinal))
        {
            throw new InvalidOperationException("HP_CODEX_SANDBOX_SOURCE_HANDLE_HASH_MISMATCH");
        }
        AuthenticodeVerifier.VerifyExpectation(
            QueryFinalPath(stream.SafeFileHandle),
            artifact.Authenticode);
    }

    private static string QueryFinalPath(SafeFileHandle fileHandle)
    {
        var capacity = 32768;
        var builder = new System.Text.StringBuilder(capacity);
        var length = GetFinalPathNameByHandle(fileHandle, builder, (uint)capacity, flags: 0);
        if (length == 0 || length >= capacity)
        {
            throw new InvalidOperationException("HP_CODEX_SANDBOX_SOURCE_PATH_UNAVAILABLE");
        }
        return builder.ToString();
    }

    private static string QueryProcessImagePath(SafeProcessHandle processHandle)
    {
        var capacity = 32768;
        var builder = new System.Text.StringBuilder(capacity);
        if (!QueryFullProcessImageName(
            processHandle,
            flags: 0,
            builder,
            ref capacity))
        {
            throw new InvalidOperationException("HP_CODEX_SANDBOX_HOST_PATH_UNAVAILABLE");
        }
        return builder.ToString();
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern SafeProcessHandle OpenProcess(
        uint desiredAccess,
        [MarshalAs(UnmanagedType.Bool)] bool inheritHandle,
        uint processId);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DuplicateHandle(
        SafeProcessHandle sourceProcessHandle,
        IntPtr sourceHandle,
        IntPtr targetProcessHandle,
        out IntPtr targetHandle,
        uint desiredAccess,
        [MarshalAs(UnmanagedType.Bool)] bool inheritHandle,
        uint options);

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandle(
        SafeFileHandle fileHandle,
        System.Text.StringBuilder filePath,
        uint filePathLength,
        uint flags);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool QueryFullProcessImageName(
        SafeProcessHandle processHandle,
        uint flags,
        System.Text.StringBuilder executableName,
        ref int size);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool OpenProcessToken(
        SafeProcessHandle processHandle,
        TokenAccessLevels desiredAccess,
        out SafeAccessTokenHandle tokenHandle);
}
