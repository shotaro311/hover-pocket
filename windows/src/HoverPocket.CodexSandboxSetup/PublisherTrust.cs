using System.Reflection;
using System.Text.RegularExpressions;

namespace HoverPocket.CodexSandboxSetup;

internal static partial class PublisherTrust
{
    private const string CertificateMetadataKey = "HoverPocketPublisherCertificateSha256";

    [GeneratedRegex("^[0-9A-Fa-f]{64}$", RegexOptions.CultureInvariant)]
    private static partial Regex CertificateSha256Regex();

    internal static void VerifyHostAndHelper(string hostPath)
    {
        var expectedCertificateSha256 = Assembly.GetExecutingAssembly()
            .GetCustomAttributes<AssemblyMetadataAttribute>()
            .SingleOrDefault(attribute =>
                string.Equals(attribute.Key, CertificateMetadataKey, StringComparison.Ordinal))
            ?.Value;
        if (expectedCertificateSha256 is null
            || !CertificateSha256Regex().IsMatch(expectedCertificateSha256))
        {
            throw new InvalidOperationException("HP_CODEX_SANDBOX_HELPER_PUBLISHER_UNCONFIGURED");
        }

        expectedCertificateSha256 = expectedCertificateSha256.ToLowerInvariant();
        var helperPath = Environment.ProcessPath
            ?? throw new InvalidOperationException("HP_CODEX_SANDBOX_HELPER_PATH_UNAVAILABLE");
        var helperTrust = AuthenticodeVerifier.Read(helperPath);
        var hostTrust = AuthenticodeVerifier.Read(hostPath);
        if (!helperTrust.Trusted
            || !hostTrust.Trusted
            || !string.Equals(
                helperTrust.CertificateSha256,
                expectedCertificateSha256,
                StringComparison.Ordinal)
            || !string.Equals(
                hostTrust.CertificateSha256,
                expectedCertificateSha256,
                StringComparison.Ordinal))
        {
            throw new InvalidOperationException("HP_CODEX_SANDBOX_HOST_PUBLISHER_MISMATCH");
        }
    }
}
