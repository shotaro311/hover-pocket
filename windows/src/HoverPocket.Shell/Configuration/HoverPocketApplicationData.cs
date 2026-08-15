namespace HoverPocket.Shell.Configuration;

internal sealed class HoverPocketApplicationData
{
    public const string VoiceE2EFlag = "--voice-e2e";
    public const string VoiceE2ERootFlag = "--voice-e2e-root";
    public const string VoiceE2ERootPrefix = "HoverPocketVoiceE2E-";
    public const string ReceiptFileName = "voice-e2e-receipt.json";

    private HoverPocketApplicationData(
        string rootDirectory,
        bool isIsolatedVoiceE2E,
        bool externalIntegrationsEnabled)
    {
        RootDirectory = Path.GetFullPath(rootDirectory);
        IsIsolatedVoiceE2E = isIsolatedVoiceE2E;
        ExternalIntegrationsEnabled = externalIntegrationsEnabled;
    }

    public string RootDirectory { get; }

    public bool IsIsolatedVoiceE2E { get; }

    public bool ExternalIntegrationsEnabled { get; }

    public string SettingsPath => Path.Combine(RootDirectory, "settings.json");

    public string AiLaneRootDirectory => RootDirectory;

    public string StickyDirectory => Path.Combine(RootDirectory, "sticky");

    public string TimerDirectory => Path.Combine(RootDirectory, "timer");

    public string ClipboardDirectory => Path.Combine(RootDirectory, "clipboard");

    public string CapabilityBrokerDirectory => Path.Combine(RootDirectory, "CapabilityBroker");

    public string VoiceWorkspaceDirectory => Path.Combine(RootDirectory, "VoiceWorkspace");

    public string PanelWebViewDataDirectory => Path.Combine(RootDirectory, "WebView2");

    public string SettingsWebViewDataDirectory => Path.Combine(RootDirectory, "SettingsWebView2");

    public string DiagnosticsDirectory => Path.Combine(RootDirectory, "diagnostics");

    public string VoiceE2EReceiptPath => Path.Combine(RootDirectory, ReceiptFileName);

    public IReadOnlyList<string> PersistentDirectories =>
    [
        RootDirectory,
        StickyDirectory,
        TimerDirectory,
        ClipboardDirectory,
        CapabilityBrokerDirectory,
        VoiceWorkspaceDirectory,
        PanelWebViewDataDirectory,
        SettingsWebViewDataDirectory,
        DiagnosticsDirectory
    ];

    public static HoverPocketApplicationData Resolve(StartupOptions options)
    {
#if DEBUG
        return ResolveForBuild(options, debugBuild: true);
#else
        return ResolveForBuild(options, debugBuild: false);
#endif
    }

    internal static HoverPocketApplicationData ResolveForBuild(
        StartupOptions options,
        bool debugBuild)
    {
        if (!debugBuild)
        {
            if (options.VoiceE2ERequested || options.VoiceE2ERoot is not null)
            {
                throw new VoiceE2EConfigurationException(
                    "Voice E2E flags are not accepted by Release builds.");
            }

            return Production();
        }

        if (!options.VoiceE2ERequested)
        {
            if (options.VoiceE2ERoot is not null)
            {
                throw new VoiceE2EConfigurationException(
                    "The isolated data root requires the explicit --voice-e2e flag.");
            }

            return Production();
        }

        if (string.IsNullOrWhiteSpace(options.VoiceE2ERoot))
        {
            throw new VoiceE2EConfigurationException(
                "Debug Voice E2E mode requires a fresh --voice-e2e-root.");
        }

        return new HoverPocketApplicationData(
            ValidateFreshTemporaryRoot(options.VoiceE2ERoot),
            isIsolatedVoiceE2E: true,
            externalIntegrationsEnabled: false);
    }

    internal static HoverPocketApplicationData CreateTemporaryVerifier(string name)
    {
        var safeName = string.Concat(name.Where(char.IsLetterOrDigit));
        if (safeName.Length == 0)
        {
            safeName = "Verify";
        }

        var root = Path.Combine(
            Path.GetTempPath(),
            "HoverPocket",
            safeName,
            Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        return new HoverPocketApplicationData(
            root,
            isIsolatedVoiceE2E: false,
            externalIntegrationsEnabled: false);
    }

    internal static HoverPocketApplicationData ProductionDefault()
    {
        return Production();
    }

    internal static HoverPocketApplicationData ForRoot(
        string rootDirectory,
        bool isolatedVoiceE2E = false,
        bool externalIntegrationsEnabled = false)
    {
        return new HoverPocketApplicationData(
            rootDirectory,
            isolatedVoiceE2E,
            externalIntegrationsEnabled);
    }

    public string? ResolveHoverTracePath(string? requestedPath)
    {
        if (!IsIsolatedVoiceE2E)
        {
            return string.IsNullOrWhiteSpace(requestedPath)
                ? null
                : Path.GetFullPath(requestedPath);
        }

        return string.IsNullOrWhiteSpace(requestedPath)
            ? null
            : Path.Combine(DiagnosticsDirectory, "hover-trace.log");
    }

    private static HoverPocketApplicationData Production()
    {
        return new HoverPocketApplicationData(
            Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "HoverPocket"),
            isIsolatedVoiceE2E: false,
            externalIntegrationsEnabled: true);
    }

    private static string ValidateFreshTemporaryRoot(string configuredRoot)
    {
        string root;
        try
        {
            root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(configuredRoot));
        }
        catch (Exception exception) when (exception is ArgumentException or NotSupportedException)
        {
            throw new VoiceE2EConfigurationException("The isolated data root is invalid.");
        }

        var temporaryRoot = Path.TrimEndingDirectorySeparator(Path.GetFullPath(Path.GetTempPath()));
        var allowedPrefix = temporaryRoot + Path.DirectorySeparatorChar;
        if (!root.StartsWith(allowedPrefix, StringComparison.OrdinalIgnoreCase)
            || string.Equals(root, temporaryRoot, StringComparison.OrdinalIgnoreCase)
            || !Path.GetFileName(root).StartsWith(VoiceE2ERootPrefix, StringComparison.Ordinal))
        {
            throw new VoiceE2EConfigurationException(
                "The isolated data root must be a dedicated HoverPocketVoiceE2E directory under the system temp directory.");
        }

        if (!Directory.Exists(root))
        {
            throw new VoiceE2EConfigurationException(
                "The isolated data root must already exist and be fresh.");
        }

        FileAttributes attributes;
        try
        {
            attributes = File.GetAttributes(root);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            throw new VoiceE2EConfigurationException(
                "The isolated data root cannot be inspected safely.");
        }

        if ((attributes & FileAttributes.ReparsePoint) != 0)
        {
            throw new VoiceE2EConfigurationException(
                "The isolated data root cannot be a reparse point.");
        }

        try
        {
            if (Directory.EnumerateFileSystemEntries(root).Any())
            {
                throw new VoiceE2EConfigurationException(
                    "The isolated data root must be empty before launch.");
            }
        }
        catch (UnauthorizedAccessException)
        {
            throw new VoiceE2EConfigurationException(
                "The isolated data root cannot be inspected safely.");
        }
        catch (IOException)
        {
            throw new VoiceE2EConfigurationException(
                "The isolated data root cannot be inspected safely.");
        }

        return root;
    }
}

internal sealed class VoiceE2EConfigurationException(string message) : Exception(message);
