namespace HoverPocket.Shell.PocketApps;

internal static class CodexGenerationSandboxSecurityPolicy
{
    internal const string SetupUnavailableCode = "GENERATOR_SANDBOX_SETUP_UNAVAILABLE";

    // Provisioning remains disabled until the physical signing/UAC canary independently proves
    // the fixed installed helper boundary and the existing helper production switch is enabled.
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
    internal const string SetupRequiredCode = "GENERATOR_SANDBOX_SETUP_REQUIRED";
    internal const string RequestRejectedCode = "GENERATOR_SANDBOX_SETUP_REQUEST_REJECTED";
    internal const string HelperRejectedCode = "GENERATOR_SANDBOX_HELPER_NOT_TRUSTED";

    private readonly bool _setupAvailable;
    private readonly ICodexSandboxSetupHelperResolver _helperResolver;
    private readonly ICodexSandboxSetupProcessLauncher _processLauncher;
    private readonly Func<string, DateTimeOffset, PinnedCodexSandboxSetupRequest> _requestFactory;
    private string? _lastErrorCode;
    private bool _restartRequired;

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
        : this(
            homePath,
            executablePath,
            setupAvailable,
            new CodexSandboxSetupHelperResolver(),
            new CodexSandboxSetupProcessLauncher(),
            CodexSandboxSetupRequestBuilder.Create)
    {
    }

    internal CodexGenerationSandboxProvisioner(
        string homePath,
        string executablePath,
        bool setupAvailable,
        ICodexSandboxSetupHelperResolver helperResolver,
        ICodexSandboxSetupProcessLauncher processLauncher,
        Func<string, DateTimeOffset, PinnedCodexSandboxSetupRequest> requestFactory)
    {
        _ = Path.GetFullPath(homePath);
        _ = Path.GetFullPath(executablePath);
        _helperResolver = helperResolver;
        _processLauncher = processLauncher;
        _requestFactory = requestFactory;
        _setupAvailable = setupAvailable
            && CodexGenerationSandboxSecurityPolicy.ProvisioningAvailable;
    }

    public CodexGenerationSandboxProvisioningState Check()
    {
        if (_restartRequired)
        {
            return new CodexGenerationSandboxProvisioningState(
                "restart_required",
                Ready: false,
                TrustedExecutableInstalled: true,
                SetupAvailable: _setupAvailable,
                RepairAvailable: _setupAvailable,
                RestartRequired: true,
                ErrorCode: null,
                SetupVersion: CodexGenerationSandboxLease.SetupVersion,
                RuntimeElevationRequired: false);
        }

        var errorCode = _setupAvailable
            ? _lastErrorCode ?? SetupRequiredCode
            : CodexGenerationSandboxSecurityPolicy.SetupUnavailableCode;
        return new CodexGenerationSandboxProvisioningState(
            "not_ready",
            Ready: false,
            TrustedExecutableInstalled: false,
            SetupAvailable: _setupAvailable,
            RepairAvailable: false,
            RestartRequired: false,
            ErrorCode: errorCode,
            SetupVersion: CodexGenerationSandboxLease.SetupVersion,
            RuntimeElevationRequired: false);
    }

    public CodexGenerationSandboxProvisioningState Refresh() => Check();

    public async Task<CodexGenerationSandboxProvisioningState> ProvisionAsync(
        string sourceExecutable,
        CancellationToken cancellationToken)
    {
        if (!_setupAvailable)
        {
            _lastErrorCode = CodexGenerationSandboxSecurityPolicy.SetupUnavailableCode;
            return Check();
        }
        if (cancellationToken.IsCancellationRequested)
        {
            _lastErrorCode = CodexSandboxSetupProcessLauncher.CancelledCode;
            return Check();
        }

        PinnedCodexSandboxSetupRequest? request = null;
        try
        {
            request = _requestFactory(sourceExecutable, DateTimeOffset.UtcNow);
        }
        catch (OperationCanceledException)
        {
            _lastErrorCode = CodexSandboxSetupProcessLauncher.CancelledCode;
            return Check();
        }
        catch
        {
            _lastErrorCode = RequestRejectedCode;
            return Check();
        }

        using (request)
        {
            ICodexSandboxSetupHelperLease? helper = null;
            try
            {
                helper = _helperResolver.Resolve();
            }
            catch
            {
                _lastErrorCode = HelperRejectedCode;
                return Check();
            }

            using (helper)
            {
                CodexSandboxSetupLaunchResult launch;
                try
                {
                    launch = await _processLauncher.LaunchAsync(
                        helper,
                        request,
                        cancellationToken).ConfigureAwait(false);
                }
                catch
                {
                    _lastErrorCode = CodexSandboxSetupProcessLauncher.StartFailedCode;
                    return Check();
                }

                if (!launch.Succeeded)
                {
                    _lastErrorCode = launch.ErrorCode
                        ?? CodexSandboxSetupProcessLauncher.StartFailedCode;
                    return Check();
                }
            }
        }

        _lastErrorCode = null;
        _restartRequired = true;
        return Check();
    }
}
