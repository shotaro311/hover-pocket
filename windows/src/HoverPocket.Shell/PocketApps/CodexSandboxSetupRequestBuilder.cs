using System.Diagnostics;
using System.Security.Cryptography;
using System.Security.Principal;
using HoverPocket.CodexSandboxSetup.Contracts;

namespace HoverPocket.Shell.PocketApps;

internal sealed class PinnedCodexSandboxSetupRequest : IDisposable
{
    private readonly IReadOnlyList<FileStream> _sourceHandles;

    internal PinnedCodexSandboxSetupRequest(
        EncodedSetupRequest encoded,
        IReadOnlyList<FileStream> sourceHandles)
    {
        Encoded = encoded;
        _sourceHandles = sourceHandles;
    }

    internal EncodedSetupRequest Encoded { get; }

    public void Dispose()
    {
        foreach (var sourceHandle in _sourceHandles)
        {
            sourceHandle.Dispose();
        }
    }
}

internal static class CodexSandboxSetupRequestBuilder
{
    internal static PinnedCodexSandboxSetupRequest Create(
        string selectedCodexExecutable,
        DateTimeOffset now)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException();
        }

        var packageRoot = ResolvePackageRoot(selectedCodexExecutable);
        RejectReparseDirectories(packageRoot);

        var sourceHandles = new List<FileStream>();
        try
        {
            var artifacts = new List<SetupArtifactHandle>();
            foreach (var artifact in CodexVendorClosure.Artifacts)
            {
                var path = CodexVendorClosure.ResolveArtifactPath(packageRoot, artifact);
                var attributes = File.GetAttributes(path);
                if ((attributes & (FileAttributes.ReparsePoint | FileAttributes.Directory)) != 0)
                {
                    throw new InvalidOperationException("HP_CODEX_SANDBOX_SOURCE_OBJECT_INVALID");
                }

                var stream = new FileStream(
                    path,
                    FileMode.Open,
                    FileAccess.Read,
                    FileShare.Read,
                    bufferSize: 1024 * 1024,
                    FileOptions.SequentialScan);
                sourceHandles.Add(stream);
                if (stream.Length != artifact.Size)
                {
                    throw new InvalidOperationException("HP_CODEX_SANDBOX_SOURCE_SIZE_MISMATCH");
                }

                var hash = Convert.ToHexStringLower(SHA256.HashData(stream));
                stream.Position = 0;
                if (!string.Equals(hash, artifact.Sha256, StringComparison.Ordinal))
                {
                    throw new InvalidOperationException("HP_CODEX_SANDBOX_SOURCE_HASH_MISMATCH");
                }

                artifacts.Add(new SetupArtifactHandle(
                    artifact.RelativePath,
                    stream.SafeFileHandle.DangerousGetHandle().ToInt64(),
                    artifact.Size,
                    artifact.Sha256,
                    artifact.Authenticode));
            }

            using var identity = WindowsIdentity.GetCurrent(TokenAccessLevels.Query);
            var sid = identity.User?.Value
                ?? throw new InvalidOperationException("HP_CODEX_SANDBOX_ORIGINAL_SID_UNAVAILABLE");
            var accountName = identity.Name;
            if (string.IsNullOrWhiteSpace(accountName))
            {
                throw new InvalidOperationException("HP_CODEX_SANDBOX_ORIGINAL_ACCOUNT_UNAVAILABLE");
            }

            var nonce = Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(32));
            var request = new SetupRequest(
                SetupRequestContract.SchemaVersion,
                nonce,
                Process.GetCurrentProcess().Id,
                sid,
                accountName,
                now.ToUniversalTime(),
                now.ToUniversalTime().AddMinutes(2),
                artifacts);
            return new PinnedCodexSandboxSetupRequest(
                SetupRequestContract.Encode(request),
                sourceHandles.ToArray());
        }
        catch
        {
            foreach (var sourceHandle in sourceHandles)
            {
                sourceHandle.Dispose();
            }
            throw;
        }
    }

    private static string ResolvePackageRoot(string selectedCodexExecutable)
    {
        var executable = Path.GetFullPath(selectedCodexExecutable);
        if (!string.Equals(Path.GetFileName(executable), "codex.exe", StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException("HP_CODEX_SANDBOX_SOURCE_LAYOUT_INVALID");
        }

        var binDirectory = Directory.GetParent(executable);
        if (binDirectory is null
            || !string.Equals(binDirectory.Name, "bin", StringComparison.OrdinalIgnoreCase)
            || binDirectory.Parent is null)
        {
            throw new InvalidOperationException("HP_CODEX_SANDBOX_SOURCE_LAYOUT_INVALID");
        }

        return binDirectory.Parent.FullName;
    }

    private static void RejectReparseDirectories(string packageRoot)
    {
        var root = Path.GetPathRoot(packageRoot)
            ?? throw new InvalidOperationException("HP_CODEX_SANDBOX_SOURCE_LAYOUT_INVALID");
        var relative = Path.GetRelativePath(root, packageRoot);
        var current = root;
        foreach (var segment in relative.Split(
            Path.DirectorySeparatorChar,
            StringSplitOptions.RemoveEmptyEntries))
        {
            current = Path.Combine(current, segment);
            var attributes = File.GetAttributes(current);
            if ((attributes & FileAttributes.ReparsePoint) != 0
                || (attributes & FileAttributes.Directory) == 0)
            {
                throw new InvalidOperationException("HP_CODEX_SANDBOX_SOURCE_DIRECTORY_INVALID");
            }
        }
    }
}
