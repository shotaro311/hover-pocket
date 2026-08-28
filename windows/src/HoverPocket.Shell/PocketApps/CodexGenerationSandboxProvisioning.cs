namespace HoverPocket.Shell.PocketApps;

internal static class CodexGenerationSandboxSecurityPolicy
{
    internal const string SetupUnavailableCode = "GENERATOR_SANDBOX_SETUP_UNAVAILABLE";

    // Provisioning remains disabled until a signed native helper binds the original user SID,
    // the complete pinned Codex resource closure, and the admin-owned target object identities.
    internal static bool ProvisioningAvailable => false;

    // A legacy setup-v5 directory has no HoverPocket helper attestation and must not enable
    // production generation merely because its path-based marker files are present.
    internal static bool ProductionRuntimeAvailable => false;
}

internal sealed record CodexGenerationSandboxProvisioningState(
    string Status,
    bool Ready,
    bool TrustedExecutableInstalled,
    bool SetupAvailable,
    bool RepairAvailable,
    bool RestartRequired,
    string? ErrorCode,
    int SetupVersion,
    bool RuntimeElevationRequired);

internal interface ICodexGenerationSandboxProvisioner
{
    CodexGenerationSandboxProvisioningState Check();

    CodexGenerationSandboxProvisioningState Refresh();

    Task<CodexGenerationSandboxProvisioningState> ProvisionAsync(
        string sourceExecutable,
        CancellationToken cancellationToken);
}

internal sealed class CodexGenerationSandboxProvisioner : ICodexGenerationSandboxProvisioner
{
    private readonly bool _setupAvailable;
    private string? _lastErrorCode;

    public CodexGenerationSandboxProvisioner(bool setupAvailable = true)
        : this(
            CodexGenerationSandboxLease.DefaultHomePath(),
            CodexPocketAppGenerationAdapter.DefaultExecutablePath(),
            setupAvailable)
    {
    }

    internal CodexGenerationSandboxProvisioner(
        string homePath,
        string executablePath,
        bool setupAvailable)
    {
        _ = Path.GetFullPath(homePath);
        _ = Path.GetFullPath(executablePath);
        _setupAvailable = setupAvailable
            && CodexGenerationSandboxSecurityPolicy.ProvisioningAvailable;
    }

    public CodexGenerationSandboxProvisioningState Check()
    {
        _lastErrorCode ??= CodexGenerationSandboxSecurityPolicy.SetupUnavailableCode;
        return new CodexGenerationSandboxProvisioningState(
            "not_ready",
            Ready: false,
            TrustedExecutableInstalled: false,
            SetupAvailable: _setupAvailable,
            RepairAvailable: false,
            RestartRequired: false,
            ErrorCode: _lastErrorCode,
            SetupVersion: CodexGenerationSandboxLease.SetupVersion,
            RuntimeElevationRequired: false);
    }

    public CodexGenerationSandboxProvisioningState Refresh() => Check();

    public Task<CodexGenerationSandboxProvisioningState> ProvisionAsync(
        string sourceExecutable,
        CancellationToken cancellationToken)
    {
        _ = sourceExecutable;
        cancellationToken.ThrowIfCancellationRequested();
        _lastErrorCode = CodexGenerationSandboxSecurityPolicy.SetupUnavailableCode;
        return Task.FromResult(Check());
    }
}
