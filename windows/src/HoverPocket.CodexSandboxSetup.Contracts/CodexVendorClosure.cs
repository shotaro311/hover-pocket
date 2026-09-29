using System.Security.Cryptography;

namespace HoverPocket.CodexSandboxSetup.Contracts;

public enum AuthenticodeExpectation
{
    OpenAi,
    Unsigned,
}

public sealed record CodexVendorArtifact(
    string RelativePath,
    long Size,
    string Sha256,
    AuthenticodeExpectation Authenticode);

public static class CodexVendorClosure
{
    public const string CodexVersion = "0.145.0";
    public const string OpenAiSignerName = "OpenAI OpCo, LLC";

    public static IReadOnlyList<CodexVendorArtifact> Artifacts { get; } =
    [
        new(
            "bin/codex.exe",
            359245096,
            "83751f15cb6a0a7b97df67752c001e3fe1c20e18ffbfec3ff63567296205eb6c",
            AuthenticodeExpectation.OpenAi),
        new(
            "bin/codex-code-mode-host.exe",
            53605168,
            "de58d3bd9fb88c44555de1104d06fba78e207bce7115d92691b42f6b0f87f3b7",
            AuthenticodeExpectation.OpenAi),
        new(
            "codex-resources/codex-command-runner.exe",
            1271088,
            "09531442d178aefb4c849745e95a000f52d5910a13944638269d9991cb08319b",
            AuthenticodeExpectation.OpenAi),
        new(
            "codex-resources/codex-windows-sandbox-setup.exe",
            8807728,
            "c981b438d0959e33f90f6b8b1a9656c4f803a1b82ebdd97e2150d2b8543a0c31",
            AuthenticodeExpectation.OpenAi),
        new(
            "codex-path/rg.exe",
            4218880,
            "14231169855ec5205cf5a1b6f1db358ff4aed4247c86b69ce8aae647c77f6680",
            AuthenticodeExpectation.Unsigned),
        new(
            "codex-package.json",
            215,
            "d15dd152401ec63697fb4888d3dec75a849ac85c11aa69256bccc0355e0b7ddd",
            AuthenticodeExpectation.Unsigned),
    ];

    public static string ComputeClosureDigest()
    {
        var canonical = string.Join(
            "\n",
            Artifacts.Select(artifact =>
                $"{artifact.RelativePath}|{artifact.Size}|{artifact.Sha256}|{artifact.Authenticode}"));
        return Convert.ToHexStringLower(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(canonical)));
    }

    public static string ResolveArtifactPath(string packageRoot, CodexVendorArtifact artifact)
    {
        var root = Path.GetFullPath(packageRoot);
        var combined = Path.GetFullPath(
            Path.Combine(root, artifact.RelativePath.Replace('/', Path.DirectorySeparatorChar)));
        var prefix = root.EndsWith(Path.DirectorySeparatorChar)
            ? root
            : root + Path.DirectorySeparatorChar;
        if (!combined.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException("HP_CODEX_SANDBOX_CLOSURE_PATH_INVALID");
        }

        return combined;
    }
}
