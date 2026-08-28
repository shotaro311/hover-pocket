using System.ComponentModel;
using System.Diagnostics;

namespace HoverPocket.Shell.PocketApps;

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
    private readonly string _homePath;
    private readonly string _scriptPath;
    private readonly bool _setupAvailable;
    private bool _restartRequired;
    private string? _lastErrorCode;
    private bool? _trustedExecutableInstalled;

    public CodexGenerationSandboxProvisioner(bool setupAvailable = true)
        : this(
            CodexGenerationSandboxLease.DefaultHomePath(),
            ResolveProvisioningScript(),
            setupAvailable)
    {
    }

    internal CodexGenerationSandboxProvisioner(
        string homePath,
        string scriptPath,
        bool setupAvailable)
    {
        _homePath = Path.GetFullPath(homePath);
        _scriptPath = Path.GetFullPath(scriptPath);
        _setupAvailable = setupAvailable;
    }

    public CodexGenerationSandboxProvisioningState Check()
    {
        var executableInstalled = _trustedExecutableInstalled
            ??= CodexPocketAppGenerationAdapter.ResolveExecutable() is not null;
        var ready = false;
        try
        {
            using var lease = CodexGenerationSandboxLease.Open(_homePath);
            lease.Validate();
            ready = executableInstalled;
        }
        catch (PocketAppGenerationException)
        {
            ready = false;
        }

        if (ready)
        {
            _lastErrorCode = null;
        }
        else if (_lastErrorCode is null)
        {
            _lastErrorCode = executableInstalled
                ? "GENERATOR_SANDBOX_NOT_READY"
                : "GENERATOR_CODEX_NOT_INSTALLED";
        }

        var setupAvailable = _setupAvailable && File.Exists(_scriptPath);
        return new CodexGenerationSandboxProvisioningState(
            ready ? "ready" : "not_ready",
            ready,
            executableInstalled,
            setupAvailable,
            setupAvailable && (executableInstalled || Directory.Exists(_homePath)),
            ready && _restartRequired,
            ready ? null : _lastErrorCode,
            CodexGenerationSandboxLease.SetupVersion,
            RuntimeElevationRequired: false);
    }

    public CodexGenerationSandboxProvisioningState Refresh()
    {
        _trustedExecutableInstalled = null;
        return Check();
    }

    public async Task<CodexGenerationSandboxProvisioningState> ProvisionAsync(
        string sourceExecutable,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!_setupAvailable || !File.Exists(_scriptPath))
        {
            _lastErrorCode = "GENERATOR_SANDBOX_SETUP_UNAVAILABLE";
            return Check();
        }
        if (!await Task.Run(
                () => CodexPocketAppGenerationAdapter.IsTrustedExecutable(sourceExecutable),
                cancellationToken))
        {
            _lastErrorCode = "GENERATOR_CODEX_UNTRUSTED";
            return Check();
        }

        var systemDirectory = Environment.SystemDirectory;
        var powershell = Path.Combine(
            systemDirectory,
            "WindowsPowerShell",
            "v1.0",
            "powershell.exe");
        if (!File.Exists(powershell))
        {
            _lastErrorCode = "GENERATOR_SANDBOX_SETUP_UNAVAILABLE";
            return Check();
        }

        var start = new ProcessStartInfo
        {
            FileName = powershell,
            UseShellExecute = true,
            Verb = "runas",
            WindowStyle = ProcessWindowStyle.Hidden
        };
        foreach (var argument in new[]
        {
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            _scriptPath,
            "-CodexBin",
            Path.GetFullPath(sourceExecutable),
            "-CodexHome",
            _homePath,
            "-Provision"
        })
        {
            start.ArgumentList.Add(argument);
        }

        try
        {
            using var process = Process.Start(start);
            if (process is null)
            {
                _lastErrorCode = "GENERATOR_SANDBOX_SETUP_FAILED";
                return Check();
            }
            using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(3));
            try
            {
                await process.WaitForExitAsync(timeout.Token);
            }
            catch (OperationCanceledException)
            {
                try { process.Kill(entireProcessTree: true); } catch { }
                _lastErrorCode = "GENERATOR_SANDBOX_SETUP_TIMEOUT";
                return Check();
            }
            if (process.ExitCode != 0)
            {
                _lastErrorCode = "GENERATOR_SANDBOX_SETUP_FAILED";
                return Check();
            }
        }
        catch (Win32Exception ex) when (ex.NativeErrorCode == 1223)
        {
            _lastErrorCode = "GENERATOR_SANDBOX_SETUP_CANCELED";
            return Check();
        }
        catch (Exception ex) when (ex is Win32Exception or InvalidOperationException)
        {
            _lastErrorCode = "GENERATOR_SANDBOX_SETUP_FAILED";
            return Check();
        }

        _restartRequired = true;
        _lastErrorCode = null;
        return Refresh();
    }

    private static string ResolveProvisioningScript()
    {
        var packaged = Path.Combine(
            AppContext.BaseDirectory,
            "script",
            "provision_codex_generation_sandbox.ps1");
        if (File.Exists(packaged)) { return packaged; }

        var current = new DirectoryInfo(Directory.GetCurrentDirectory());
        while (current is not null)
        {
            var candidate = Path.Combine(
                current.FullName,
                "windows",
                "script",
                "provision_codex_generation_sandbox.ps1");
            if (File.Exists(candidate)) { return candidate; }
            current = current.Parent;
        }
        return packaged;
    }
}
