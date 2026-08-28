using System.ComponentModel;
using System.Diagnostics;
using System.Security.Cryptography;

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
    private readonly string _executablePath;
    private readonly bool _setupAvailable;
    private bool _restartRequired;
    private string? _lastErrorCode;
    private bool? _trustedExecutableInstalled;

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
        _homePath = Path.GetFullPath(homePath);
        _executablePath = Path.GetFullPath(executablePath);
        _setupAvailable = setupAvailable;
    }

    public CodexGenerationSandboxProvisioningState Check()
    {
        var executableInstalled = _trustedExecutableInstalled
            ??= CodexPocketAppGenerationAdapter.IsTrustedExecutable(_executablePath);
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

        var setupAvailable = _setupAvailable;
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
        if (!_setupAvailable)
        {
            _lastErrorCode = "GENERATOR_SANDBOX_SETUP_UNAVAILABLE";
            return Check();
        }
        if (!await Task.Run(
                () => InstallTrustedExecutable(sourceExecutable),
                cancellationToken))
        {
            _lastErrorCode = "GENERATOR_CODEX_UNTRUSTED";
            return Check();
        }

        var start = CreateElevatedSetupStartInfo(_executablePath, _homePath);

        try
        {
            using var executableDirectory = new PocketAppPinnedDirectory(
                Path.GetDirectoryName(_executablePath)
                    ?? throw new PocketAppGenerationException("GENERATOR_CODEX_UNTRUSTED"),
                allowReplacement: false,
                createMissing: false);
            using var executableHandle = executableDirectory.OpenFileForRead(
                Path.GetFileName(_executablePath))
                ?? throw new PocketAppGenerationException("GENERATOR_CODEX_UNTRUSTED");
            executableDirectory.Validate();
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

    internal static ProcessStartInfo CreateElevatedSetupStartInfo(
        string executablePath,
        string homePath)
    {
        var start = new ProcessStartInfo
        {
            FileName = Path.GetFullPath(executablePath),
            UseShellExecute = true,
            Verb = "runas",
            WindowStyle = ProcessWindowStyle.Hidden
        };
        foreach (var argument in new[]
        {
            "sandbox",
            "setup",
            "--elevated",
            "--current-user",
            "--codex-home",
            Path.GetFullPath(homePath)
        })
        {
            start.ArgumentList.Add(argument);
        }
        return start;
    }

    private bool InstallTrustedExecutable(string sourceExecutable)
    {
        if (string.IsNullOrWhiteSpace(sourceExecutable)) { return false; }
        var sourcePath = Path.GetFullPath(sourceExecutable);
        var sourceDirectoryPath = Path.GetDirectoryName(sourcePath);
        var destinationDirectoryPath = Path.GetDirectoryName(_executablePath);
        if (string.IsNullOrWhiteSpace(sourceDirectoryPath)
            || string.IsNullOrWhiteSpace(destinationDirectoryPath))
        {
            return false;
        }

        try
        {
            using var sourceDirectory = new PocketAppPinnedDirectory(
                sourceDirectoryPath,
                allowReplacement: false,
                createMissing: false);
            using var sourceHandle = sourceDirectory.OpenFileForRead(Path.GetFileName(sourcePath));
            if (sourceHandle is null) { return false; }
            using var source = new FileStream(sourceHandle, FileAccess.Read, 1024 * 1024, isAsync: false);
            if (source.Length != CodexPocketAppGenerationAdapter.TrustedExecutableLength)
            {
                return false;
            }
            var sourceDigest = Convert.ToHexString(SHA256.HashData(source)).ToLowerInvariant();
            if (!string.Equals(
                    sourceDigest,
                    CodexPocketAppGenerationAdapter.TrustedExecutableSha256,
                    StringComparison.Ordinal))
            {
                return false;
            }
            source.Position = 0;
            using var destinationDirectory = new PocketAppPinnedDirectory(
                destinationDirectoryPath,
                allowReplacement: false);
            if (CodexPocketAppGenerationAdapter.IsTrustedExecutable(_executablePath))
            {
                destinationDirectory.Validate();
                return true;
            }
            var temporaryPath = Path.Combine(
                destinationDirectory.FullPath,
                $"codex.{Guid.NewGuid():N}.tmp");
            try
            {
                using (var temporary = new FileStream(
                    temporaryPath,
                    FileMode.CreateNew,
                    FileAccess.Write,
                    FileShare.None,
                    1024 * 1024,
                    FileOptions.SequentialScan | FileOptions.WriteThrough))
                {
                    source.CopyTo(temporary, 1024 * 1024);
                    temporary.Flush(flushToDisk: true);
                }
                sourceDirectory.Validate();
                destinationDirectory.Validate();
                File.Move(temporaryPath, _executablePath, overwrite: true);
                destinationDirectory.Validate();
                return CodexPocketAppGenerationAdapter.IsTrustedExecutable(_executablePath);
            }
            finally
            {
                if (File.Exists(temporaryPath))
                {
                    File.Delete(temporaryPath);
                }
            }
        }
        catch (Exception ex) when (ex is IOException
            or UnauthorizedAccessException
            or ArgumentException
            or NotSupportedException
            or PocketAppGenerationException)
        {
            return false;
        }
    }
}
