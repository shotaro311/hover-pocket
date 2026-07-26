using System.Reflection;
using HoverPocket.Shell.Verification;

namespace HoverPocket.Shell.Services;

internal sealed class ReleaseConfigVerifier
{
    public int Run()
    {
        var failures = new List<string>();
        var assembly = Assembly.GetExecutingAssembly();
        var configuration = assembly
            .GetCustomAttribute<AssemblyConfigurationAttribute>()
            ?.Configuration;
        var actualVersion = assembly.GetName().Version?.ToString(3);
        var expectedVersion = Environment
            .GetEnvironmentVariable("HOVERPOCKET_RELEASE_EXPECTED_VERSION")
            ?.Trim();
        var expectedClientId = Environment
            .GetEnvironmentVariable("HOVERPOCKET_GOOGLE_CLIENT_ID")
            ?.Trim();
        var expectedClientSecret = Environment
            .GetEnvironmentVariable("HOVERPOCKET_GOOGLE_CLIENT_SECRET")
            ?.Trim();
        var embedded = GoogleOAuthConfiguration.LoadEmbedded();

        if (!string.Equals(configuration, "Release", StringComparison.Ordinal))
        {
            failures.Add("assembly configuration is not Release");
        }

        if (string.IsNullOrWhiteSpace(expectedVersion)
            || !string.Equals(actualVersion, expectedVersion, StringComparison.Ordinal))
        {
            failures.Add("assembly version does not match the expected release version");
        }

        if (string.IsNullOrWhiteSpace(expectedClientId)
            || string.IsNullOrWhiteSpace(expectedClientSecret))
        {
            failures.Add("release verification environment is missing Google OAuth configuration");
        }
        else if (embedded is null
            || !string.Equals(embedded.ClientId, expectedClientId, StringComparison.Ordinal)
            || !string.Equals(embedded.ClientSecret, expectedClientSecret, StringComparison.Ordinal))
        {
            failures.Add("embedded Google OAuth metadata does not match the release configuration");
        }

        if (!string.Equals(UpdaterService.WindowsChannel, "win", StringComparison.Ordinal)
            || !string.Equals(UpdaterService.WindowsFeedFileName, "releases.win.json", StringComparison.Ordinal))
        {
            failures.Add("Windows update channel metadata is not pinned to releases.win.json");
        }

        if (failures.Count > 0)
        {
            VerifyConsole.WriteLine("FAIL release-config verify:");
            foreach (var failure in failures)
            {
                VerifyConsole.WriteLine($"- {failure}");
            }

            return 1;
        }

        VerifyConsole.WriteLine($"release_version={actualVersion}");
        VerifyConsole.WriteLine("release_configuration=Release");
        VerifyConsole.WriteLine("oauth_embedded_metadata=present-and-matched");
        VerifyConsole.WriteLine("windows_update_channel=win");
        VerifyConsole.WriteLine("PASS release-config verify");
        return 0;
    }
}
