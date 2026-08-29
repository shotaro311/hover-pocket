using System.ComponentModel;
using System.Diagnostics;

namespace HoverPocket.Shell.PocketApps;

internal sealed record CodexSandboxSetupLaunchResult(
    bool Succeeded,
    string? ErrorCode)
{
    internal static CodexSandboxSetupLaunchResult Success() => new(true, null);

    internal static CodexSandboxSetupLaunchResult Failure(string code) => new(false, code);
}

internal interface ICodexSandboxSetupProcessLauncher
{
    Task<CodexSandboxSetupLaunchResult> LaunchAsync(
        ICodexSandboxSetupHelperLease helper,
        PinnedCodexSandboxSetupRequest request,
        CancellationToken cancellationToken);
}

internal interface ICodexSandboxSetupProcess : IDisposable
{
    bool HasExited { get; }

    int ExitCode { get; }

    Task WaitForExitAsync(CancellationToken cancellationToken);

    string? ReadImagePath();

    bool TryKill();
}

internal interface ICodexSandboxSetupProcessFactory
{
    ICodexSandboxSetupProcess Start(ProcessStartInfo startInfo);
}

internal sealed class CodexSandboxSetupProcessLauncher : ICodexSandboxSetupProcessLauncher
{
    internal const string UacCancelledCode = "GENERATOR_SANDBOX_UAC_CANCELLED";
    internal const string StartFailedCode = "GENERATOR_SANDBOX_HELPER_START_FAILED";
    internal const string TimeoutCode = "GENERATOR_SANDBOX_HELPER_TIMEOUT";
    internal const string CancelledCode = "GENERATOR_SANDBOX_SETUP_CANCELLED";
    internal const string NonzeroExitCode = "GENERATOR_SANDBOX_HELPER_FAILED";
    internal const string IdentityChangedCode = "GENERATOR_SANDBOX_HELPER_IDENTITY_CHANGED";
    internal const string ReadbackFailedCode = "GENERATOR_SANDBOX_HELPER_READBACK_FAILED";
    internal const string CleanupFailedCode = "GENERATOR_SANDBOX_HELPER_CLEANUP_FAILED";

    private static readonly TimeSpan DefaultTimeout = TimeSpan.FromMinutes(6);
    private static readonly TimeSpan DefaultCleanupTimeout = TimeSpan.FromSeconds(5);

    private readonly ICodexSandboxSetupProcessFactory _processFactory;
    private readonly TimeSpan _timeout;
    private readonly TimeSpan _cleanupTimeout;

    public CodexSandboxSetupProcessLauncher()
        : this(
            new CodexSandboxSetupProcessFactory(),
            DefaultTimeout,
            DefaultCleanupTimeout)
    {
    }

    internal CodexSandboxSetupProcessLauncher(
        ICodexSandboxSetupProcessFactory processFactory,
        TimeSpan timeout,
        TimeSpan cleanupTimeout)
    {
        if (timeout <= TimeSpan.Zero || cleanupTimeout <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(nameof(timeout));
        }
        _processFactory = processFactory;
        _timeout = timeout;
        _cleanupTimeout = cleanupTimeout;
    }

    public async Task<CodexSandboxSetupLaunchResult> LaunchAsync(
        ICodexSandboxSetupHelperLease helper,
        PinnedCodexSandboxSetupRequest request,
        CancellationToken cancellationToken)
    {
        if (cancellationToken.IsCancellationRequested)
        {
            return CodexSandboxSetupLaunchResult.Failure(CancelledCode);
        }
        try
        {
            helper.ValidateIdentity();
        }
        catch
        {
            return CodexSandboxSetupLaunchResult.Failure(IdentityChangedCode);
        }

        var workingDirectory = Path.GetDirectoryName(helper.FullPath);
        if (string.IsNullOrWhiteSpace(workingDirectory))
        {
            return CodexSandboxSetupLaunchResult.Failure(IdentityChangedCode);
        }
        var startInfo = new ProcessStartInfo
        {
            FileName = helper.FullPath,
            WorkingDirectory = workingDirectory,
            Verb = "runas",
            UseShellExecute = true,
        };
        foreach (var argument in request.HelperArguments)
        {
            startInfo.ArgumentList.Add(argument);
        }
        if (cancellationToken.IsCancellationRequested)
        {
            return CodexSandboxSetupLaunchResult.Failure(CancelledCode);
        }

        ICodexSandboxSetupProcess process;
        try
        {
            process = _processFactory.Start(startInfo);
        }
        catch (Win32Exception exception) when (exception.NativeErrorCode == 1223)
        {
            return CodexSandboxSetupLaunchResult.Failure(UacCancelledCode);
        }
        catch
        {
            return CodexSandboxSetupLaunchResult.Failure(StartFailedCode);
        }

        using (process)
        {
            try
            {
                helper.ValidateIdentity();
            }
            catch
            {
                return await FailAfterStartAsync(
                    process,
                    IdentityChangedCode).ConfigureAwait(false);
            }

            string? processImagePath;
            try
            {
                processImagePath = process.ReadImagePath();
            }
            catch
            {
                processImagePath = null;
            }
            if (string.IsNullOrWhiteSpace(processImagePath))
            {
                return await FailAfterStartAsync(
                    process,
                    ReadbackFailedCode).ConfigureAwait(false);
            }
            try
            {
                helper.ValidateProcessImage(processImagePath);
            }
            catch
            {
                return await FailAfterStartAsync(
                    process,
                    IdentityChangedCode).ConfigureAwait(false);
            }

            using var timeout = new CancellationTokenSource(_timeout);
            using var combined = CancellationTokenSource.CreateLinkedTokenSource(
                cancellationToken,
                timeout.Token);
            try
            {
                await process.WaitForExitAsync(combined.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                return await FailAfterStartAsync(
                    process,
                    CancelledCode).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return await FailAfterStartAsync(
                    process,
                    TimeoutCode).ConfigureAwait(false);
            }
            catch
            {
                return await FailAfterStartAsync(
                    process,
                    ReadbackFailedCode).ConfigureAwait(false);
            }

            if (process.ExitCode != 0)
            {
                return CodexSandboxSetupLaunchResult.Failure(NonzeroExitCode);
            }
            try
            {
                helper.ValidateIdentity();
            }
            catch
            {
                return CodexSandboxSetupLaunchResult.Failure(IdentityChangedCode);
            }
            return CodexSandboxSetupLaunchResult.Success();
        }
    }

    private async Task<CodexSandboxSetupLaunchResult> FailAfterStartAsync(
        ICodexSandboxSetupProcess process,
        string code)
    {
        if (!await StopProcessAsync(process).ConfigureAwait(false))
        {
            return CodexSandboxSetupLaunchResult.Failure(CleanupFailedCode);
        }
        return CodexSandboxSetupLaunchResult.Failure(code);
    }

    private async Task<bool> StopProcessAsync(ICodexSandboxSetupProcess process)
    {
        try
        {
            if (process.HasExited)
            {
                return true;
            }
        }
        catch
        {
            return false;
        }
        if (!process.TryKill())
        {
            return false;
        }

        using var cleanupTimeout = new CancellationTokenSource(_cleanupTimeout);
        try
        {
            await process.WaitForExitAsync(cleanupTimeout.Token).ConfigureAwait(false);
            return process.HasExited;
        }
        catch
        {
            return false;
        }
    }

}

internal sealed class CodexSandboxSetupProcessFactory : ICodexSandboxSetupProcessFactory
{
    public ICodexSandboxSetupProcess Start(ProcessStartInfo startInfo)
    {
        var process = Process.Start(startInfo)
            ?? throw new InvalidOperationException(
                CodexSandboxSetupProcessLauncher.StartFailedCode);
        return new CodexSandboxSetupProcess(process);
    }
}

internal sealed class CodexSandboxSetupProcess : ICodexSandboxSetupProcess
{
    private readonly Process _process;

    internal CodexSandboxSetupProcess(Process process)
    {
        _process = process;
    }

    public bool HasExited => _process.HasExited;

    public int ExitCode => _process.ExitCode;

    public Task WaitForExitAsync(CancellationToken cancellationToken) =>
        _process.WaitForExitAsync(cancellationToken);

    public string? ReadImagePath()
    {
        var capacity = 32768;
        var builder = new System.Text.StringBuilder(capacity);
        return QueryFullProcessImageName(
            _process.SafeHandle,
            flags: 0,
            builder,
            ref capacity)
            ? builder.ToString()
            : null;
    }

    public bool TryKill()
    {
        try
        {
            if (!_process.HasExited)
            {
                _process.Kill(entireProcessTree: true);
            }
            return true;
        }
        catch (Exception exception) when (exception is InvalidOperationException
            or Win32Exception
            or NotSupportedException)
        {
            return false;
        }
    }

    public void Dispose() => _process.Dispose();

    [System.Runtime.InteropServices.DllImport(
        "kernel32.dll",
        CharSet = System.Runtime.InteropServices.CharSet.Unicode,
        SetLastError = true)]
    [return: System.Runtime.InteropServices.MarshalAs(
        System.Runtime.InteropServices.UnmanagedType.Bool)]
    private static extern bool QueryFullProcessImageName(
        Microsoft.Win32.SafeHandles.SafeProcessHandle processHandle,
        uint flags,
        System.Text.StringBuilder executableName,
        ref int size);
}
