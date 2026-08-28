using HoverPocket.CodexSandboxSetup.Contracts;

namespace HoverPocket.CodexSandboxSetup;

internal static class ContractSelfTest
{
    internal static void Run()
    {
        var paths = CodexVendorClosure.Artifacts
            .Select(artifact => artifact.RelativePath)
            .ToArray();
        if (paths.Length != 6
            || paths.Distinct(StringComparer.Ordinal).Count() != paths.Length
            || paths.Any(path =>
                string.IsNullOrWhiteSpace(path)
                || Path.IsPathRooted(path)
                || path.Contains("..", StringComparison.Ordinal)
                || path.Contains('\\')))
        {
            throw new InvalidOperationException("HP_CODEX_SANDBOX_CONTRACT_PATH_INVALID");
        }

        if (!paths.Contains("bin/codex.exe", StringComparer.Ordinal)
            || !paths.Contains(
                "codex-resources/codex-windows-sandbox-setup.exe",
                StringComparer.Ordinal)
            || !paths.Contains(
                "codex-resources/codex-command-runner.exe",
                StringComparer.Ordinal))
        {
            throw new InvalidOperationException("HP_CODEX_SANDBOX_CONTRACT_CLOSURE_INCOMPLETE");
        }

        var digest = CodexVendorClosure.ComputeClosureDigest();
        if (digest.Length != 64 || digest.Any(character => !Uri.IsHexDigit(character)))
        {
            throw new InvalidOperationException("HP_CODEX_SANDBOX_CONTRACT_DIGEST_INVALID");
        }

        VerifyRequestRoundTrip();
    }

    private static void VerifyRequestRoundTrip()
    {
        var now = new DateTimeOffset(2026, 8, 28, 0, 0, 0, TimeSpan.Zero);
        var request = new SetupRequest(
            SetupRequestContract.SchemaVersion,
            new string('a', 64),
            4242,
            "S-1-5-21-100-200-300-400",
            "WORKSTATION\\alice",
            now,
            now.AddMinutes(2),
            CodexVendorClosure.Artifacts
                .Select((artifact, index) => new SetupArtifactHandle(
                    artifact.RelativePath,
                    index + 100,
                    artifact.Size,
                    artifact.Sha256,
                    artifact.Authenticode))
                .ToArray());
        var encoded = SetupRequestContract.Encode(request);
        var decoded = SetupRequestContract.DecodeAndValidate(
            encoded.Base64Json,
            encoded.Sha256,
            encoded.Nonce,
            now.AddSeconds(30));
        if (decoded.SchemaVersion != request.SchemaVersion
            || !string.Equals(decoded.Nonce, request.Nonce, StringComparison.Ordinal)
            || decoded.HostProcessId != request.HostProcessId
            || !string.Equals(decoded.OriginalUserSid, request.OriginalUserSid, StringComparison.Ordinal)
            || !string.Equals(decoded.OriginalUserName, request.OriginalUserName, StringComparison.Ordinal)
            || decoded.IssuedAtUtc != request.IssuedAtUtc
            || decoded.ExpiresAtUtc != request.ExpiresAtUtc
            || !decoded.Artifacts.SequenceEqual(request.Artifacts))
        {
            throw new InvalidOperationException("HP_CODEX_SANDBOX_CONTRACT_ROUNDTRIP_FAILED");
        }

        ExpectFailure(
            () => SetupRequestContract.DecodeAndValidate(
                encoded.Base64Json,
                encoded.Sha256,
                new string('b', 64),
                now.AddSeconds(30)),
            "HP_CODEX_SANDBOX_REQUEST_NONCE_MISMATCH");
        ExpectFailure(
            () => SetupRequestContract.DecodeAndValidate(
                encoded.Base64Json,
                new string('0', 64),
                encoded.Nonce,
                now.AddSeconds(30)),
            "HP_CODEX_SANDBOX_REQUEST_HASH_MISMATCH");
        ExpectFailure(
            () => SetupRequestContract.DecodeAndValidate(
                encoded.Base64Json,
                encoded.Sha256,
                encoded.Nonce,
                now.AddMinutes(6)),
            "HP_CODEX_SANDBOX_REQUEST_EXPIRED");

        var duplicateHandleRequest = request with
        {
            Artifacts = request.Artifacts
                .Select(artifact => artifact with { HandleValue = 100 })
                .ToArray(),
        };
        ExpectFailure(
            () => SetupRequestContract.Encode(duplicateHandleRequest),
            "HP_CODEX_SANDBOX_REQUEST_CLOSURE_INVALID");
    }

    private static void ExpectFailure(Action action, string expectedCode)
    {
        try
        {
            action();
        }
        catch (InvalidOperationException exception)
            when (string.Equals(exception.Message, expectedCode, StringComparison.Ordinal))
        {
            return;
        }

        throw new InvalidOperationException("HP_CODEX_SANDBOX_CONTRACT_NEGATIVE_CASE_FAILED");
    }
}
