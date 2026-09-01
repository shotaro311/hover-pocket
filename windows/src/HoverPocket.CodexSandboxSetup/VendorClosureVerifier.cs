using System.Security.Cryptography;
using HoverPocket.CodexSandboxSetup.Contracts;

namespace HoverPocket.CodexSandboxSetup;

internal static class VendorClosureVerifier
{
    internal static void Verify(string packageRoot)
    {
        foreach (var artifact in CodexVendorClosure.Artifacts)
        {
            var path = CodexVendorClosure.ResolveArtifactPath(packageRoot, artifact);
            VerifyRegularFile(path, artifact);
        }
    }

    private static void VerifyRegularFile(string path, CodexVendorArtifact artifact)
    {
        var attributes = File.GetAttributes(path);
        if ((attributes & FileAttributes.ReparsePoint) != 0
            || (attributes & FileAttributes.Directory) != 0)
        {
            throw new InvalidOperationException("HP_CODEX_SANDBOX_CLOSURE_OBJECT_INVALID");
        }

        using var stream = new FileStream(
            path,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read,
            bufferSize: 1024 * 1024,
            FileOptions.SequentialScan);
        if (stream.Length != artifact.Size)
        {
            throw new InvalidOperationException("HP_CODEX_SANDBOX_CLOSURE_SIZE_MISMATCH");
        }

        var hash = Convert.ToHexStringLower(SHA256.HashData(stream));
        if (!string.Equals(hash, artifact.Sha256, StringComparison.Ordinal))
        {
            throw new InvalidOperationException("HP_CODEX_SANDBOX_CLOSURE_HASH_MISMATCH");
        }

        AuthenticodeVerifier.VerifyExpectation(path, artifact.Authenticode);
    }
}
