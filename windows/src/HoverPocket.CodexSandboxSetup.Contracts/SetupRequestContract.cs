using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace HoverPocket.CodexSandboxSetup.Contracts;

public sealed record SetupArtifactHandle(
    string RelativePath,
    long HandleValue,
    long Size,
    string Sha256,
    AuthenticodeExpectation Authenticode);

public sealed record SetupRequest(
    int SchemaVersion,
    string Nonce,
    int HostProcessId,
    string OriginalUserSid,
    string OriginalUserName,
    DateTimeOffset IssuedAtUtc,
    DateTimeOffset ExpiresAtUtc,
    IReadOnlyList<SetupArtifactHandle> Artifacts);

public sealed record EncodedSetupRequest(
    string Base64Json,
    string Sha256,
    string Nonce);

public static partial class SetupRequestContract
{
    public const int SchemaVersion = 1;
    public const int MaximumJsonBytes = 16 * 1024;
    public static readonly TimeSpan MaximumLifetime = TimeSpan.FromMinutes(5);

    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
    };

    [GeneratedRegex("^[0-9a-f]{64}$", RegexOptions.CultureInvariant)]
    private static partial Regex LowerHexSha256Regex();

    [GeneratedRegex("^S-1-[0-9]+(?:-[0-9]+)+$", RegexOptions.CultureInvariant)]
    private static partial Regex SidRegex();

    public static EncodedSetupRequest Encode(SetupRequest request)
    {
        Validate(request, request.IssuedAtUtc);
        var json = JsonSerializer.SerializeToUtf8Bytes(request, SerializerOptions);
        if (json.Length > MaximumJsonBytes)
        {
            throw new InvalidOperationException("HP_CODEX_SANDBOX_REQUEST_TOO_LARGE");
        }

        return new EncodedSetupRequest(
            Convert.ToBase64String(json),
            Convert.ToHexStringLower(SHA256.HashData(json)),
            request.Nonce);
    }

    public static SetupRequest DecodeAndValidate(
        string base64Json,
        string expectedSha256,
        string expectedNonce,
        DateTimeOffset now)
    {
        if (!LowerHexSha256Regex().IsMatch(expectedSha256)
            || !LowerHexSha256Regex().IsMatch(expectedNonce))
        {
            throw new InvalidOperationException("HP_CODEX_SANDBOX_REQUEST_ARGUMENT_INVALID");
        }

        byte[] json;
        try
        {
            json = Convert.FromBase64String(base64Json);
        }
        catch (FormatException)
        {
            throw new InvalidOperationException("HP_CODEX_SANDBOX_REQUEST_ENCODING_INVALID");
        }

        if (json.Length == 0 || json.Length > MaximumJsonBytes)
        {
            throw new InvalidOperationException("HP_CODEX_SANDBOX_REQUEST_TOO_LARGE");
        }

        var actualHash = Convert.ToHexStringLower(SHA256.HashData(json));
        if (!CryptographicOperations.FixedTimeEquals(
            Encoding.ASCII.GetBytes(actualHash),
            Encoding.ASCII.GetBytes(expectedSha256)))
        {
            throw new InvalidOperationException("HP_CODEX_SANDBOX_REQUEST_HASH_MISMATCH");
        }

        SetupRequest request;
        try
        {
            request = JsonSerializer.Deserialize<SetupRequest>(json, SerializerOptions)
                ?? throw new JsonException();
        }
        catch (JsonException)
        {
            throw new InvalidOperationException("HP_CODEX_SANDBOX_REQUEST_SCHEMA_INVALID");
        }

        if (!CryptographicOperations.FixedTimeEquals(
            Encoding.ASCII.GetBytes(request.Nonce),
            Encoding.ASCII.GetBytes(expectedNonce)))
        {
            throw new InvalidOperationException("HP_CODEX_SANDBOX_REQUEST_NONCE_MISMATCH");
        }

        Validate(request, now);
        return request;
    }

    public static void Validate(SetupRequest request, DateTimeOffset now)
    {
        if (request.SchemaVersion != SchemaVersion
            || !LowerHexSha256Regex().IsMatch(request.Nonce)
            || request.HostProcessId <= 0
            || !SidRegex().IsMatch(request.OriginalUserSid)
            || string.IsNullOrWhiteSpace(request.OriginalUserName)
            || request.OriginalUserName.Length > 256
            || !request.OriginalUserName.Contains('\\')
            || request.OriginalUserName.Any(char.IsControl))
        {
            throw new InvalidOperationException("HP_CODEX_SANDBOX_REQUEST_IDENTITY_INVALID");
        }

        var issuedAt = request.IssuedAtUtc.ToUniversalTime();
        var expiresAt = request.ExpiresAtUtc.ToUniversalTime();
        var normalizedNow = now.ToUniversalTime();
        if (expiresAt <= issuedAt
            || expiresAt - issuedAt > MaximumLifetime
            || normalizedNow < issuedAt - TimeSpan.FromMinutes(1)
            || normalizedNow > expiresAt)
        {
            throw new InvalidOperationException("HP_CODEX_SANDBOX_REQUEST_EXPIRED");
        }

        if (request.Artifacts.Count != CodexVendorClosure.Artifacts.Count)
        {
            throw new InvalidOperationException("HP_CODEX_SANDBOX_REQUEST_CLOSURE_INCOMPLETE");
        }

        var handles = new HashSet<long>();
        for (var index = 0; index < CodexVendorClosure.Artifacts.Count; index += 1)
        {
            var expected = CodexVendorClosure.Artifacts[index];
            var actual = request.Artifacts[index];
            if (!string.Equals(actual.RelativePath, expected.RelativePath, StringComparison.Ordinal)
                || actual.Size != expected.Size
                || !string.Equals(actual.Sha256, expected.Sha256, StringComparison.Ordinal)
                || actual.Authenticode != expected.Authenticode
                || actual.HandleValue <= 0
                || !handles.Add(actual.HandleValue))
            {
                throw new InvalidOperationException("HP_CODEX_SANDBOX_REQUEST_CLOSURE_INVALID");
            }
        }
    }
}
