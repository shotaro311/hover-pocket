using System.Diagnostics;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text.Json;
using HoverPocket.CodexSandboxSetup.Contracts;
using Microsoft.Win32.SafeHandles;

namespace HoverPocket.CodexSandboxSetup;

internal static class CodexSandboxInstaller
{
    private const int CodexSetupVersion = 5;
    private static readonly TimeSpan SetupTimeout = TimeSpan.FromMinutes(5);
    private static readonly JsonSerializerOptions ReceiptJsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
    };

    internal static void InstallAndSetup(AdmittedSetupRequest admitted)
    {
        var programData = Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);
        if (string.IsNullOrWhiteSpace(programData) || !Path.IsPathFullyQualified(programData))
        {
            throw new InvalidOperationException("HP_CODEX_SANDBOX_PROGRAM_DATA_UNAVAILABLE");
        }

        var originalUserSid = new SecurityIdentifier(admitted.Request.OriginalUserSid);
        var baseRoot = Path.Combine(programData, "HoverPocketCodexSandbox");
        var versionRoot = Path.Combine(baseRoot, "v1");
        using var programDataHandle = SecureDirectoryTree.OpenExisting(programData);
        using var baseRootHandle = SecureDirectoryTree.OpenOrCreate(
            baseRoot,
            DirectoryAccessMode.UsersRead);
        using var versionRootHandle = SecureDirectoryTree.OpenOrCreate(
            versionRoot,
            DirectoryAccessMode.UsersRead);

        var controlRoot = Path.Combine(versionRoot, "control");
        using var controlRootHandle = SecureDirectoryTree.OpenOrCreate(
            controlRoot,
            DirectoryAccessMode.AdminOnly);
        using var setupLock = OpenSetupLock(controlRoot);

        var packageRoot = EnsurePackage(versionRoot, admitted);
        var homeRoot = PrepareCodexHome(
            versionRoot,
            originalUserSid,
            admitted.Request.Nonce);
        RunCodexSetup(
            Path.Combine(packageRoot, "bin", "codex.exe"),
            homeRoot,
            admitted.Request.OriginalUserName,
            versionRoot);
        VerifySetupReadback(homeRoot);
        ApplyUserHomeSecurity(homeRoot, originalUserSid);
        WriteAndReadbackAttestation(
            versionRoot,
            packageRoot,
            homeRoot,
            admitted.Request,
            originalUserSid);
    }

    private static FileStream OpenSetupLock(string controlRoot)
    {
        var lockPath = Path.Combine(controlRoot, "setup.lock");
        var stream = new FileStream(
            lockPath,
            FileMode.OpenOrCreate,
            FileAccess.ReadWrite,
            FileShare.None,
            bufferSize: 1,
            FileOptions.WriteThrough);
        return stream;
    }

    private static string EnsurePackage(
        string versionRoot,
        AdmittedSetupRequest admitted)
    {
        var packagesRoot = Path.Combine(versionRoot, "packages");
        using var packagesRootHandle = SecureDirectoryTree.OpenOrCreate(
            packagesRoot,
            DirectoryAccessMode.UsersRead);
        var closureDigest = CodexVendorClosure.ComputeClosureDigest();
        var finalRoot = Path.Combine(
            packagesRoot,
            $"codex-{CodexVendorClosure.CodexVersion}-{closureDigest}");
        if (Directory.Exists(finalRoot))
        {
            VendorClosureVerifier.Verify(finalRoot);
            ApplyPackageReadSecurity(finalRoot);
            return finalRoot;
        }

        var stagingRoot = Path.Combine(versionRoot, "staging");
        using var stagingRootHandle = SecureDirectoryTree.OpenOrCreate(
            stagingRoot,
            DirectoryAccessMode.AdminOnly);
        var requestStagingRoot = Path.Combine(stagingRoot, admitted.Request.Nonce);
        using (var requestStagingHandle = SecureDirectoryTree.OpenOrCreate(
            requestStagingRoot,
            DirectoryAccessMode.AdminOnly))
        {
            if (Directory.EnumerateFileSystemEntries(requestStagingRoot).Any())
            {
                throw new InvalidOperationException("HP_CODEX_SANDBOX_STAGING_NOT_EMPTY");
            }
            CopyClosureFromPinnedHandles(requestStagingRoot, admitted.SourceHandles);
            VendorClosureVerifier.Verify(requestStagingRoot);
        }

        Directory.Move(requestStagingRoot, finalRoot);
        ApplyPackageReadSecurity(finalRoot);
        VendorClosureVerifier.Verify(finalRoot);
        return finalRoot;
    }

    private static void CopyClosureFromPinnedHandles(
        string destinationRoot,
        IReadOnlyList<FileStream> sourceHandles)
    {
        if (sourceHandles.Count != CodexVendorClosure.Artifacts.Count)
        {
            throw new InvalidOperationException("HP_CODEX_SANDBOX_SOURCE_HANDLE_COUNT_MISMATCH");
        }
        var openedDirectories = new Dictionary<string, SafeFileHandle>(StringComparer.OrdinalIgnoreCase);
        try
        {
            for (var index = 0; index < CodexVendorClosure.Artifacts.Count; index += 1)
            {
                var artifact = CodexVendorClosure.Artifacts[index];
                var destination = CodexVendorClosure.ResolveArtifactPath(destinationRoot, artifact);
                var destinationDirectory = Path.GetDirectoryName(destination)
                    ?? throw new InvalidOperationException("HP_CODEX_SANDBOX_TARGET_PATH_INVALID");
                EnsureAdminOnlyDirectory(destinationRoot, destinationDirectory, openedDirectories);

                var source = sourceHandles[index];
                source.Position = 0;
                using (var output = new FileStream(
                    destination,
                    FileMode.CreateNew,
                    FileAccess.ReadWrite,
                    FileShare.None,
                    bufferSize: 1024 * 1024,
                    FileOptions.SequentialScan | FileOptions.WriteThrough))
                {
                    source.CopyTo(output, bufferSize: 1024 * 1024);
                    output.Flush(flushToDisk: true);
                }
                source.Position = 0;
                SecureDirectoryTree.ApplyFileSecurity(destination, DirectoryAccessMode.AdminOnly);
                VerifyCopiedFile(destination, artifact);
            }
        }
        finally
        {
            foreach (var directoryHandle in openedDirectories.Values)
            {
                directoryHandle.Dispose();
            }
        }
    }

    private static void EnsureAdminOnlyDirectory(
        string destinationRoot,
        string destinationDirectory,
        IDictionary<string, SafeFileHandle> openedDirectories)
    {
        var relative = Path.GetRelativePath(destinationRoot, destinationDirectory);
        var current = destinationRoot;
        foreach (var segment in relative.Split(
            Path.DirectorySeparatorChar,
            StringSplitOptions.RemoveEmptyEntries))
        {
            current = Path.Combine(current, segment);
            if (!openedDirectories.ContainsKey(current))
            {
                openedDirectories[current] = SecureDirectoryTree.OpenOrCreate(
                    current,
                    DirectoryAccessMode.AdminOnly);
            }
        }
    }

    private static void VerifyCopiedFile(string path, CodexVendorArtifact artifact)
    {
        using var stream = new FileStream(
            path,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read,
            bufferSize: 1024 * 1024,
            FileOptions.SequentialScan);
        if (stream.Length != artifact.Size
            || !string.Equals(
                Convert.ToHexStringLower(SHA256.HashData(stream)),
                artifact.Sha256,
                StringComparison.Ordinal))
        {
            throw new InvalidOperationException("HP_CODEX_SANDBOX_TARGET_COPY_MISMATCH");
        }
    }

    private static void ApplyPackageReadSecurity(string packageRoot)
    {
        foreach (var directory in Directory.EnumerateDirectories(
            packageRoot,
            "*",
            SearchOption.AllDirectories))
        {
            SecureDirectoryTree.ApplyDirectorySecurity(
                directory,
                DirectoryAccessMode.UsersRead);
        }
        foreach (var file in Directory.EnumerateFiles(
            packageRoot,
            "*",
            SearchOption.AllDirectories))
        {
            SecureDirectoryTree.ApplyFileSecurity(file, DirectoryAccessMode.UsersRead);
        }
        SecureDirectoryTree.ApplyDirectorySecurity(packageRoot, DirectoryAccessMode.UsersRead);
    }

    private static string PrepareCodexHome(
        string versionRoot,
        SecurityIdentifier originalUserSid,
        string nonce)
    {
        var homesRoot = Path.Combine(versionRoot, "homes");
        using var homesRootHandle = SecureDirectoryTree.OpenOrCreate(
            homesRoot,
            DirectoryAccessMode.UsersRead);
        var userKey = UserKey(originalUserSid);
        var userRoot = Path.Combine(homesRoot, userKey);
        using var userRootHandle = SecureDirectoryTree.OpenOrCreate(
            userRoot,
            DirectoryAccessMode.UsersRead);
        var homeRoot = Path.Combine(userRoot, $"codex-home-{nonce}");
        using var homeRootHandle = SecureDirectoryTree.CreateNew(
            homeRoot,
            DirectoryAccessMode.AdminOnly);
        return homeRoot;
    }

    private static void RunCodexSetup(
        string codexExecutable,
        string codexHome,
        string originalUserName,
        string versionRoot)
    {
        var windowsRoot = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        var tempRoot = Path.Combine(versionRoot, "temp");
        using var tempRootHandle = SecureDirectoryTree.OpenOrCreate(
            tempRoot,
            DirectoryAccessMode.AdminOnly);
        var startInfo = new ProcessStartInfo
        {
            FileName = codexExecutable,
            WorkingDirectory = Path.GetDirectoryName(codexExecutable)!,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        startInfo.ArgumentList.Add("sandbox");
        startInfo.ArgumentList.Add("setup");
        startInfo.ArgumentList.Add("--elevated");
        startInfo.ArgumentList.Add("--user");
        startInfo.ArgumentList.Add(originalUserName);
        startInfo.ArgumentList.Add("--codex-home");
        startInfo.ArgumentList.Add(codexHome);
        startInfo.Environment.Clear();
        startInfo.Environment["SystemRoot"] = windowsRoot;
        startInfo.Environment["WINDIR"] = windowsRoot;
        startInfo.Environment["ComSpec"] = Path.Combine(windowsRoot, "System32", "cmd.exe");
        startInfo.Environment["ProgramData"] =
            Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);
        startInfo.Environment["TEMP"] = tempRoot;
        startInfo.Environment["TMP"] = tempRoot;
        startInfo.Environment["PATH"] = Path.Combine(windowsRoot, "System32");

        using var process = new Process { StartInfo = startInfo };
        if (!process.Start())
        {
            throw new InvalidOperationException("HP_CODEX_SANDBOX_SETUP_PROCESS_START_FAILED");
        }
        using var job = ChildProcessJob.CreateAndAssign(process);
        var stdout = process.StandardOutput.ReadToEndAsync();
        var stderr = process.StandardError.ReadToEndAsync();
        using var timeout = new CancellationTokenSource(SetupTimeout);
        try
        {
            process.WaitForExitAsync(timeout.Token).GetAwaiter().GetResult();
            Task.WhenAll(stdout, stderr).GetAwaiter().GetResult();
        }
        catch (OperationCanceledException)
        {
            throw new InvalidOperationException("HP_CODEX_SANDBOX_SETUP_PROCESS_TIMEOUT");
        }
        if (process.ExitCode != 0)
        {
            throw new InvalidOperationException("HP_CODEX_SANDBOX_SETUP_PROCESS_FAILED");
        }
    }

    private static void VerifySetupReadback(string codexHome) =>
        CodexSetupReadbackVerifier.Verify(codexHome);

    private static void ApplyUserHomeSecurity(
        string homeRoot,
        SecurityIdentifier originalUserSid)
    {
        foreach (var directory in Directory.EnumerateDirectories(
            homeRoot,
            "*",
            SearchOption.AllDirectories))
        {
            SecureDirectoryTree.ApplyDirectorySecurity(
                directory,
                DirectoryAccessMode.SpecificUserModify,
                originalUserSid);
        }
        foreach (var file in Directory.EnumerateFiles(
            homeRoot,
            "*",
            SearchOption.AllDirectories))
        {
            SecureDirectoryTree.ApplyFileSecurity(
                file,
                DirectoryAccessMode.SpecificUserModify,
                originalUserSid);
        }
        SecureDirectoryTree.ApplyDirectorySecurity(
            homeRoot,
            DirectoryAccessMode.SpecificUserModify,
            originalUserSid);
    }

    private static void WriteAndReadbackAttestation(
        string versionRoot,
        string packageRoot,
        string homeRoot,
        SetupRequest request,
        SecurityIdentifier originalUserSid)
    {
        var attestationsRoot = Path.Combine(versionRoot, "attestations");
        using var attestationsRootHandle = SecureDirectoryTree.OpenOrCreate(
            attestationsRoot,
            DirectoryAccessMode.UsersRead);
        var userAttestationsRoot = Path.Combine(
            attestationsRoot,
            UserKey(originalUserSid));
        using var userAttestationsRootHandle = SecureDirectoryTree.OpenOrCreate(
            userAttestationsRoot,
            DirectoryAccessMode.SpecificUserRead,
            originalUserSid);
        var attestationPath = Path.Combine(
            userAttestationsRoot,
            $"{request.Nonce}.json");
        var temporaryPath = Path.Combine(
            userAttestationsRoot,
            $".{request.Nonce}.tmp");
        var receipt = new SandboxSetupAttestation(
            SchemaVersion: 1,
            CodexVersion: CodexVendorClosure.CodexVersion,
            SetupVersion: CodexSetupVersion,
            ClosureDigest: CodexVendorClosure.ComputeClosureDigest(),
            OriginalUserSid: request.OriginalUserSid,
            OriginalUserName: request.OriginalUserName,
            PackageRelativePath: Path.GetRelativePath(versionRoot, packageRoot),
            HomeRelativePath: Path.GetRelativePath(versionRoot, homeRoot),
            CompletedAtUtc: DateTimeOffset.UtcNow);
        var json = JsonSerializer.SerializeToUtf8Bytes(receipt, ReceiptJsonOptions);
        using (var output = new FileStream(
            temporaryPath,
            FileMode.CreateNew,
            FileAccess.ReadWrite,
            FileShare.None,
            bufferSize: 4096,
            FileOptions.WriteThrough))
        {
            output.Write(json);
            output.Flush(flushToDisk: true);
        }
        SecureDirectoryTree.ApplyFileSecurity(
            temporaryPath,
            DirectoryAccessMode.SpecificUserRead,
            originalUserSid);
        File.Move(temporaryPath, attestationPath);
        SecureDirectoryTree.ApplyFileSecurity(
            attestationPath,
            DirectoryAccessMode.SpecificUserRead,
            originalUserSid);
        var readback = JsonSerializer.Deserialize<SandboxSetupAttestation>(
            File.ReadAllBytes(attestationPath),
            ReceiptJsonOptions);
        if (readback != receipt)
        {
            throw new InvalidOperationException("HP_CODEX_SANDBOX_ATTESTATION_READBACK_MISMATCH");
        }
    }

    private static string UserKey(SecurityIdentifier sid) =>
        Convert.ToHexStringLower(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(sid.Value)));

    private sealed record SandboxSetupAttestation(
        int SchemaVersion,
        string CodexVersion,
        int SetupVersion,
        string ClosureDigest,
        string OriginalUserSid,
        string OriginalUserName,
        string PackageRelativePath,
        string HomeRelativePath,
        DateTimeOffset CompletedAtUtc);
}
