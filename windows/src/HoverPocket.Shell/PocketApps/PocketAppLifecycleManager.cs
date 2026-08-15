using System.Security.Cryptography;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using HoverPocket.Shell.Capabilities;

namespace HoverPocket.Shell.PocketApps;

internal enum PocketAppLifecycleAction
{
    Install,
    Update,
    Rollback
}

internal enum PocketAppDataDisposition
{
    Preserve,
    Delete
}

internal enum PocketAppLifecycleState
{
    Enabled,
    Disabled,
    Removed
}

internal static class PocketAppHostContract
{
    public const string Version = "1.0.0";
}

internal sealed record PocketAppPermissionDiff(
    IReadOnlyList<string> Added,
    IReadOnlyList<string> Removed);

internal sealed record PocketAppCapabilityGrantDiff(
    IReadOnlyList<string> Added,
    IReadOnlyList<string> Removed);

internal sealed class PocketAppPreviewSurface
{
    private readonly byte[] _canonicalRenderModel;

    public PocketAppPreviewSurface(string id, string renderDigest, ReadOnlySpan<byte> canonicalRenderModel)
    {
        Id = id;
        RenderDigest = renderDigest;
        _canonicalRenderModel = canonicalRenderModel.ToArray();
    }

    public string Id { get; }
    public string RenderDigest { get; }
    public byte[] CanonicalRenderModel => _canonicalRenderModel.ToArray();

    internal byte[] CanonicalRenderModelBytes() => _canonicalRenderModel.ToArray();
}
internal sealed record PocketAppStagingTestResult(string Id, string Expected, string Status);

internal sealed record PocketAppLifecycleProposal(
    string RequestId,
    PocketAppLifecycleAction Action,
    string PackageId,
    string Version,
    string PackageDigest,
    string? CurrentDigest,
    PocketAppLifecycleState? CurrentState,
    string PreviewDigest,
    IReadOnlyList<PocketAppPreviewSurface> Previews,
    PocketAppPermissionDiff PermissionDiff,
    PocketAppCapabilityGrantDiff CapabilityGrantDiff,
    IReadOnlyList<PocketAppStagingTestResult> Tests,
    string BindingDigest,
    DateTimeOffset CreatedAt,
    DateTimeOffset ExpiresAt,
    bool ApprovalRequired,
    string StagingDirectory,
    string StateSchemaDigest,
    IReadOnlySet<string> StatePropertyNames);

internal sealed record PocketAppLifecycleApprovalGrant(string Token);

internal sealed record PocketAppLifecycleReceipt(
    string Action,
    string PackageId,
    string? Version,
    string? PackageDigest,
    PocketAppLifecycleState State,
    bool ReadbackVerified,
    PocketAppDataDisposition? DataDisposition);

internal sealed record PocketAppManagedPackage(
    string PackageId,
    PocketAppLifecycleState State,
    string? Version,
    string? PackageDigest,
    IReadOnlyList<string> InstalledVersions);

internal sealed record PocketAppManagementIssue(
    string PackageId,
    string ErrorCode,
    bool RemovalAllowed);

internal sealed record PocketAppManagementSnapshot(
    IReadOnlyList<PocketAppManagedPackage> Packages,
    IReadOnlyList<PocketAppManagementIssue> Issues);

internal sealed class PocketAppLifecycleException(string code) : Exception(code)
{
    public string Code { get; } = code;
}

internal sealed class PocketAppLifecycleManager : IDisposable
{
    private sealed record ActiveRecord(
        int RecordVersion,
        string PackageId,
        string? Version,
        string? PackageDigest,
        IReadOnlyList<string> Permissions,
        string? StateSchemaDigest,
        IReadOnlyList<string> StatePropertyNames,
        PocketAppLifecycleState State,
        DateTimeOffset UpdatedAt);

    private sealed record PendingApproval(
        string BindingDigest,
        DateTimeOffset ExpiresAt,
        string StagingDirectory,
        bool DisposableStaging);
    private sealed record IssuedApproval(string RequestId, string BindingDigest, DateTimeOffset ExpiresAt);

    private static readonly TimeSpan ApprovalLifetime = TimeSpan.FromMinutes(5);
    private const int MaxPendingStagingSnapshots = 4;
    private readonly string _rootDirectory;
    private readonly string _userDataRoot;
    private readonly PocketAppPackageRuntime _runtime;
    private readonly PocketAppStagingTestRunner _stagingTestRunner;
    private readonly string _hostVersion;
    private readonly Func<string, bool>? _failureInjection;
    private static readonly object LifecycleGate = new();
    private static readonly HashSet<string> LiveStagingDirectories = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, PendingApproval> _pendingApprovals = new(StringComparer.Ordinal);
    private readonly HashSet<string> _decidedRequests = new(StringComparer.Ordinal);
    private readonly Dictionary<string, IssuedApproval> _grants = new(StringComparer.Ordinal);
    private readonly HashSet<string> _consumedGrants = new(StringComparer.Ordinal);
    private bool _disposed;

    public PocketAppLifecycleManager(
        string rootDirectory,
        string userDataRoot,
        PocketAppPackageRuntime? runtime = null,
        Func<string, bool>? failureInjection = null,
        string hostVersion = PocketAppHostContract.Version,
        bool performStartupRecovery = true)
    {
        if (!ValidVersion(hostVersion)) { throw Failure("LIFECYCLE_PACKAGE_INVALID"); }
        _rootDirectory = Path.GetFullPath(rootDirectory);
        _userDataRoot = Path.GetFullPath(userDataRoot);
        _runtime = runtime ?? new PocketAppPackageRuntime();
        _stagingTestRunner = new PocketAppStagingTestRunner();
        _hostVersion = hostVersion;
        _failureInjection = failureInjection;
        try
        {
            lock (LifecycleGate)
            {
                Directory.CreateDirectory(_rootDirectory);
                Directory.CreateDirectory(_userDataRoot);
                if (performStartupRecovery)
                {
                    RecoverInterruptedTransactions();
                }
            }
        }
        catch (PocketAppLifecycleException)
        {
            throw;
        }
        catch
        {
            throw Failure("LIFECYCLE_STORAGE_FAILED");
        }
    }

    ~PocketAppLifecycleManager() => Dispose(disposing: false);

    public void Dispose()
    {
        Dispose(disposing: true);
        GC.SuppressFinalize(this);
    }

    public PocketAppLifecycleProposal Stage(string draftDirectory, DateTimeOffset? now = null) =>
        WithLifecycleLock(() => StageCore(draftDirectory, now));

    private PocketAppLifecycleProposal StageCore(string draftDirectory, DateTimeOffset? now)
    {
        var timestamp = now ?? DateTimeOffset.UtcNow;
        string? cleanupDirectory = null;
        try
        {
            PurgeExpiredApprovals(timestamp);
            if (LiveStagingDirectories.Count(path => IsWithinDirectory(path, StagingRoot)) >= MaxPendingStagingSnapshots)
            {
                throw Failure("LIFECYCLE_PENDING_LIMIT_EXCEEDED");
            }
            var sourceSnapshot = PocketAppFileSnapshot.Capture(draftDirectory);
            var stagingDirectory = Path.Combine(StagingRoot, Guid.NewGuid().ToString("N"), "package");
            cleanupDirectory = Directory.GetParent(stagingDirectory)?.FullName;
            sourceSnapshot.Materialize(stagingDirectory);
            var stagedSnapshot = PocketAppFileSnapshot.Capture(stagingDirectory);
            RequireSnapshotMatches(sourceSnapshot, stagedSnapshot);
            var package = _runtime.Load(stagedSnapshot);
            ValidateHostCompatibility(package);
            var previews = MakePreviews(package);
            var previewDigest = PreviewDigest(previews);
            var tests = _stagingTestRunner.Run(package);
            var current = ReadActiveRecord(package.Manifest.Id);
            ValidateMigration(package, current);
            var action = current is null || current.State == PocketAppLifecycleState.Removed
                ? PocketAppLifecycleAction.Install
                : PocketAppLifecycleAction.Update;
            var currentPackage = VerifiedCurrentPackage(current);
            if (currentPackage is not null
                && CompareSemanticVersions(package.Manifest.Version, currentPackage.Manifest.Version) < 0)
            {
                throw Failure("LIFECYCLE_DOWNGRADE_REQUIRES_ROLLBACK");
            }
            var targetPermissions = Permissions(package);
            var currentEffectivePackage = current?.State == PocketAppLifecycleState.Enabled ? currentPackage : null;
            var currentPermissions = currentEffectivePackage is null
                ? new HashSet<string>(StringComparer.Ordinal)
                : Permissions(currentEffectivePackage);
            var diff = PermissionDiff(currentPermissions, targetPermissions);
            var grantDiff = EffectiveGrantDiff(
                currentEffectivePackage is null
                    ? new HashSet<string>(StringComparer.Ordinal)
                    : CapabilityGrants(currentEffectivePackage),
                CapabilityGrants(package));
            var currentDigest = current is null || current.State == PocketAppLifecycleState.Removed
                ? null
                : current.PackageDigest;
            var binding = ApprovalBindingDigest(
                action,
                package.Manifest.Id,
                package.Manifest.Version,
                package.ManifestDigest,
                currentDigest,
                current?.State,
                previewDigest,
                diff,
                grantDiff);
            var requestId = $"install-approval:{Guid.NewGuid():N}";
            var expires = timestamp.Add(ApprovalLifetime);
            var proposal = new PocketAppLifecycleProposal(
                requestId,
                action,
                package.Manifest.Id,
                package.Manifest.Version,
                package.ManifestDigest,
                currentDigest,
                current?.State,
                previewDigest,
                previews,
                diff,
                grantDiff,
                tests,
                binding,
                timestamp,
                expires,
                true,
                stagingDirectory,
                package.StateSchemaDigest,
                package.StatePropertyNames.ToHashSet(StringComparer.Ordinal));
            _pendingApprovals[requestId] = new PendingApproval(binding, expires, stagingDirectory, true);
            var stagingParent = Directory.GetParent(stagingDirectory)?.FullName;
            if (stagingParent is not null) { LiveStagingDirectories.Add(Path.GetFullPath(stagingParent)); }
            cleanupDirectory = null;
            return proposal;
        }
        catch (PocketAppLifecycleException)
        {
            if (cleanupDirectory is not null) { try { Directory.Delete(cleanupDirectory, true); } catch { } }
            throw;
        }
        catch
        {
            if (cleanupDirectory is not null) { try { Directory.Delete(cleanupDirectory, true); } catch { } }
            throw Failure("LIFECYCLE_PACKAGE_INVALID");
        }
    }

    public PocketAppLifecycleApprovalGrant Approve(
        string requestId,
        string bindingDigest,
        DateTimeOffset? now = null) =>
        WithLifecycleLock(() => ApproveCore(requestId, bindingDigest, now));

    private PocketAppLifecycleApprovalGrant ApproveCore(
        string requestId,
        string bindingDigest,
        DateTimeOffset? now)
    {
        if (_decidedRequests.Contains(requestId)
            || !_pendingApprovals.TryGetValue(requestId, out var pending)
            || !string.Equals(pending.BindingDigest, bindingDigest, StringComparison.Ordinal))
        {
            throw Failure("LIFECYCLE_APPROVAL_INVALID");
        }
        if ((now ?? DateTimeOffset.UtcNow) > pending.ExpiresAt)
        {
            DiscardPendingApproval(requestId, pending);
            throw Failure("LIFECYCLE_APPROVAL_EXPIRED");
        }
        _decidedRequests.Add(requestId);
        var token = $"install-grant:{Guid.NewGuid():N}";
        _grants[token] = new IssuedApproval(requestId, bindingDigest, pending.ExpiresAt);
        return new PocketAppLifecycleApprovalGrant(token);
    }

    public void Reject(string requestId, string bindingDigest)
    {
        WithLifecycleLock(() => RejectCore(requestId, bindingDigest));
    }

    private void RejectCore(string requestId, string bindingDigest)
    {
        if (!_pendingApprovals.TryGetValue(requestId, out var pending) || pending.BindingDigest != bindingDigest)
        {
            throw Failure("LIFECYCLE_APPROVAL_INVALID");
        }
        DiscardPendingApproval(requestId, pending);
    }

    public PocketAppLifecycleReceipt Install(
        PocketAppLifecycleProposal proposal,
        PocketAppLifecycleApprovalGrant? approvalGrant,
        DateTimeOffset? now = null) =>
        ActivateProposal(proposal, approvalGrant, now ?? DateTimeOffset.UtcNow);

    public PocketAppLifecycleProposal PrepareRollback(
        string packageId,
        string version,
        DateTimeOffset? now = null) =>
        WithLifecycleLock(() => PrepareRollbackCore(packageId, version, now));

    private PocketAppLifecycleProposal PrepareRollbackCore(
        string packageId,
        string version,
        DateTimeOffset? now)
    {
        if (!ValidPackageId(packageId) || !ValidVersion(version)) { throw Failure("LIFECYCLE_PACKAGE_INVALID"); }
        var current = ReadActiveRecord(packageId);
        if (current is null || current.State == PocketAppLifecycleState.Removed)
        {
            throw Failure("LIFECYCLE_PACKAGE_INVALID");
        }
        var targetDirectory = UniqueVersionDirectory(packageId, version);
        var targetPackage = VerifiedInstalledPackage(targetDirectory);
        if (targetPackage.Manifest.Id != packageId
            || targetPackage.Manifest.Version != version
            || !string.Equals(
                Path.GetFileName(Directory.GetParent(targetDirectory)?.FullName),
                targetPackage.ManifestDigest["sha256:".Length..],
                StringComparison.Ordinal))
        {
            throw Failure("LIFECYCLE_CORRUPT_VERSION");
        }
        ValidateHostCompatibility(targetPackage);
        var currentPackage = VerifiedCurrentPackage(current);
        if (currentPackage is null
            || CompareSemanticVersions(targetPackage.Manifest.Version, currentPackage.Manifest.Version) >= 0)
        {
            throw Failure("LIFECYCLE_PACKAGE_INVALID");
        }
        ValidateMigration(targetPackage, current);
        var previews = MakePreviews(targetPackage);
        var previewDigest = PreviewDigest(previews);
        var currentEffectivePackage = current.State == PocketAppLifecycleState.Enabled ? currentPackage : null;
        var diff = PermissionDiff(
            currentEffectivePackage is null
                ? new HashSet<string>(StringComparer.Ordinal)
                : Permissions(currentEffectivePackage),
            Permissions(targetPackage));
        var grantDiff = EffectiveGrantDiff(
            currentEffectivePackage is null
                ? new HashSet<string>(StringComparer.Ordinal)
                : CapabilityGrants(currentEffectivePackage),
            CapabilityGrants(targetPackage));
        var binding = ApprovalBindingDigest(
            PocketAppLifecycleAction.Rollback,
            packageId,
            targetPackage.Manifest.Version,
            targetPackage.ManifestDigest,
            current.PackageDigest,
            current.State,
            previewDigest,
            diff,
            grantDiff);
        var timestamp = now ?? DateTimeOffset.UtcNow;
        var requestId = $"rollback-approval:{Guid.NewGuid():N}";
        var expires = timestamp.Add(ApprovalLifetime);
        var proposal = new PocketAppLifecycleProposal(
            requestId,
            PocketAppLifecycleAction.Rollback,
            packageId,
            targetPackage.Manifest.Version,
            targetPackage.ManifestDigest,
            current.PackageDigest,
            current.State,
            previewDigest,
            previews,
            diff,
            grantDiff,
            _stagingTestRunner.Run(targetPackage),
            binding,
            timestamp,
            expires,
            true,
            targetDirectory,
            targetPackage.StateSchemaDigest,
            targetPackage.StatePropertyNames.ToHashSet(StringComparer.Ordinal));
        _pendingApprovals[requestId] = new PendingApproval(binding, expires, targetDirectory, false);
        return proposal;
    }

    public PocketAppLifecycleReceipt Rollback(
        PocketAppLifecycleProposal proposal,
        PocketAppLifecycleApprovalGrant? approvalGrant,
        DateTimeOffset? now = null)
    {
        if (proposal.Action != PocketAppLifecycleAction.Rollback)
        {
            throw Failure("LIFECYCLE_PACKAGE_INVALID");
        }
        return ActivateProposal(proposal, approvalGrant, now ?? DateTimeOffset.UtcNow);
    }

    public PocketAppLifecycleReceipt Disable(string packageId, DateTimeOffset? now = null) =>
        WithLifecycleLock(() => DisableCore(packageId, now));

    private PocketAppLifecycleReceipt DisableCore(string packageId, DateTimeOffset? now)
    {
        var current = ReadActiveRecord(packageId);
        if (current is null || current.State == PocketAppLifecycleState.Removed)
        {
            throw Failure("LIFECYCLE_PACKAGE_INVALID");
        }
        var disabled = current with { State = PocketAppLifecycleState.Disabled, UpdatedAt = now ?? DateTimeOffset.UtcNow };
        WriteAndVerify(disabled);
        return new PocketAppLifecycleReceipt(
            "disable",
            packageId,
            disabled.Version,
            disabled.PackageDigest,
            PocketAppLifecycleState.Disabled,
            true,
            null);
    }

    public PocketAppLifecycleReceipt Enable(string packageId, DateTimeOffset? now = null) =>
        WithLifecycleLock(() => EnableCore(packageId, now));

    private PocketAppLifecycleReceipt EnableCore(string packageId, DateTimeOffset? now)
    {
        var current = ReadActiveRecord(packageId);
        if (current is null
            || current.State != PocketAppLifecycleState.Disabled
            || current.Version is null
            || current.PackageDigest is null)
        {
            throw Failure("LIFECYCLE_PACKAGE_INVALID");
        }
        var package = VerifiedInstalledPackage(
            InstalledPackageDirectory(packageId, current.Version, current.PackageDigest));
        if (package.Manifest.Id != packageId
            || package.Manifest.Version != current.Version
            || package.ManifestDigest != current.PackageDigest
            || !current.Permissions.SequenceEqual(Permissions(package).Order(StringComparer.Ordinal), StringComparer.Ordinal)
            || current.StateSchemaDigest != package.StateSchemaDigest
            || !current.StatePropertyNames.SequenceEqual(package.StatePropertyNames.Order(StringComparer.Ordinal), StringComparer.Ordinal))
        {
            throw Failure("LIFECYCLE_CORRUPT_VERSION");
        }
        ValidateHostCompatibility(package);
        var enabled = current with { State = PocketAppLifecycleState.Enabled, UpdatedAt = now ?? DateTimeOffset.UtcNow };
        try
        {
            WriteAndVerify(enabled);
            if (_failureInjection?.Invoke("enable_readback") == true)
            {
                throw Failure("LIFECYCLE_READBACK_FAILED");
            }
            var observed = ReadActiveRecord(packageId);
            if (observed is null
                || observed.State != PocketAppLifecycleState.Enabled
                || observed.Version != enabled.Version
                || observed.PackageDigest != enabled.PackageDigest)
            {
                throw Failure("LIFECYCLE_READBACK_FAILED");
            }
            _ = _failureInjection?.Invoke("enable_package_readback");
            var observedPackage = ActivePackageCore(packageId);
            if (observedPackage is null
                || observedPackage.Manifest.Id != packageId
                || observedPackage.Manifest.Version != enabled.Version
                || observedPackage.ManifestDigest != enabled.PackageDigest)
            {
                throw Failure("LIFECYCLE_READBACK_FAILED");
            }
        }
        catch
        {
            try
            {
                WriteAndVerify(current);
            }
            catch
            {
                throw Failure("LIFECYCLE_READBACK_FAILED");
            }
            throw;
        }
        return new PocketAppLifecycleReceipt(
            "enable",
            packageId,
            enabled.Version,
            enabled.PackageDigest,
            PocketAppLifecycleState.Enabled,
            true,
            null);
    }

    public PocketAppLifecycleReceipt Remove(
        string packageId,
        PocketAppDataDisposition dataDisposition,
        DateTimeOffset? now = null) =>
        WithLifecycleLock(() => RemoveCore(packageId, dataDisposition, now));

    private PocketAppLifecycleReceipt RemoveCore(
        string packageId,
        PocketAppDataDisposition dataDisposition,
        DateTimeOffset? now)
    {
        if (!ValidPackageId(packageId)) { throw Failure("LIFECYCLE_PACKAGE_INVALID"); }
        if (dataDisposition != PocketAppDataDisposition.Preserve)
        {
            throw Failure("LIFECYCLE_APPROVAL_REQUIRED");
        }
        var previous = ReadActiveRecord(packageId);
        var removed = new ActiveRecord(
            1,
            packageId,
            null,
            null,
            Array.Empty<string>(),
            previous?.StateSchemaDigest,
            previous?.StatePropertyNames ?? Array.Empty<string>(),
            PocketAppLifecycleState.Removed,
            now ?? DateTimeOffset.UtcNow);
        var versions = VersionsRoot(packageId);
        var tombstone = Path.Combine(AppRoot(packageId), $".removed-Versions-{Guid.NewGuid():N}");
        var movedVersions = false;
        try
        {
            if (Directory.Exists(versions))
            {
                if (_failureInjection?.Invoke("remove_stage") == true) { throw Failure("LIFECYCLE_STORAGE_FAILED"); }
                Directory.Move(versions, tombstone);
                movedVersions = true;
            }
            WriteAndVerify(removed);
        }
        catch
        {
            if (movedVersions && Directory.Exists(tombstone) && !Directory.Exists(versions))
            {
                try { Directory.Move(tombstone, versions); } catch { }
            }
            try
            {
                if (Directory.Exists(versions))
                {
                    MakeImmutable(versions);
                    VerifyImmutable(versions);
                }
                Restore(previous, packageId);
            }
            catch { }
            throw Failure("LIFECYCLE_STORAGE_FAILED");
        }
        if (movedVersions)
        {
            try { MakeMutable(tombstone); Directory.Delete(tombstone, true); } catch { }
        }
        if (ReadActiveRecord(packageId)?.State != PocketAppLifecycleState.Removed || Directory.Exists(versions))
        {
            throw Failure("LIFECYCLE_READBACK_FAILED");
        }
        return new PocketAppLifecycleReceipt(
            "remove",
            packageId,
            null,
            null,
            PocketAppLifecycleState.Removed,
            true,
            dataDisposition);
    }

    public IReadOnlyList<PocketAppManagedPackage> ManagedPackages() =>
        WithLifecycleLock(ManagedPackagesCore);

    private IReadOnlyList<PocketAppManagedPackage> ManagedPackagesCore()
    {
        if (!Directory.Exists(AppsRoot)) { return Array.Empty<PocketAppManagedPackage>(); }
        EnsureDirectoryNotReparsePoint(AppsRoot);
        var result = new List<PocketAppManagedPackage>();
        foreach (var appDirectory in Directory.EnumerateDirectories(AppsRoot).Order(StringComparer.Ordinal))
        {
            EnsureDirectoryNotReparsePoint(appDirectory);
            var packageId = Path.GetFileName(appDirectory);
            if (!ValidPackageId(packageId)) { throw Failure("LIFECYCLE_CORRUPT_VERSION"); }
            var package = ManagedPackageCore(packageId);
            if (package is not null) { result.Add(package); }
        }
        return result;
    }

    public PocketAppManagementSnapshot ManagementSnapshot() =>
        WithLifecycleLock(ManagementSnapshotCore);

    private PocketAppManagementSnapshot ManagementSnapshotCore()
    {
        if (!Directory.Exists(AppsRoot))
        {
            return new PocketAppManagementSnapshot(
                Array.Empty<PocketAppManagedPackage>(),
                Array.Empty<PocketAppManagementIssue>());
        }
        EnsureDirectoryNotReparsePoint(AppsRoot);
        var packages = new List<PocketAppManagedPackage>();
        var issues = new List<PocketAppManagementIssue>();
        foreach (var appDirectory in Directory.EnumerateDirectories(AppsRoot).Order(StringComparer.Ordinal))
        {
            var packageId = Path.GetFileName(appDirectory);
            if (!ValidPackageId(packageId)) { throw Failure("LIFECYCLE_CORRUPT_VERSION"); }
            try
            {
                EnsureDirectoryNotReparsePoint(appDirectory);
                var package = ManagedPackageCore(packageId);
                if (package is not null) { packages.Add(package); }
            }
            catch (Exception ex) when (ex is PocketAppLifecycleException or IOException or UnauthorizedAccessException)
            {
                var removalAllowed = false;
                try
                {
                    _ = ReadActiveRecord(packageId);
                    removalAllowed = true;
                }
                catch (Exception readError) when (readError is PocketAppLifecycleException or IOException or UnauthorizedAccessException)
                {
                }
                issues.Add(new PocketAppManagementIssue(
                    packageId,
                    "LIFECYCLE_PACKAGE_CORRUPT",
                    removalAllowed));
            }
        }
        return new PocketAppManagementSnapshot(packages, issues);
    }

    public PocketAppManagedPackage? ManagedPackage(string packageId) =>
        WithLifecycleLock(() => ManagedPackageCore(packageId));

    private PocketAppManagedPackage? ManagedPackageCore(string packageId)
    {
        if (!ValidPackageId(packageId)) { throw Failure("LIFECYCLE_PACKAGE_INVALID"); }
        var record = ReadActiveRecord(packageId);
        if (record is null) { return null; }
        if (record.State == PocketAppLifecycleState.Removed)
        {
            return new PocketAppManagedPackage(
                packageId,
                PocketAppLifecycleState.Removed,
                null,
                null,
                Array.Empty<string>());
        }
        if (record.Version is null || record.PackageDigest is null)
        {
            throw Failure("LIFECYCLE_READBACK_FAILED");
        }
        var package = VerifiedInstalledPackage(InstalledPackageDirectory(packageId, record.Version, record.PackageDigest));
        if (package.Manifest.Id != packageId
            || package.Manifest.Version != record.Version
            || package.ManifestDigest != record.PackageDigest)
        {
            throw Failure("LIFECYCLE_CORRUPT_VERSION");
        }
        return new PocketAppManagedPackage(
            packageId,
            record.State,
            record.Version,
            record.PackageDigest,
            InstalledVersionsCore(packageId));
    }

    private IReadOnlyList<string> InstalledVersionsCore(string packageId)
    {
        var versionsRoot = VersionsRoot(packageId);
        if (!Directory.Exists(versionsRoot)) { return Array.Empty<string>(); }
        EnsureDirectoryNotReparsePoint(versionsRoot);
        var versions = new HashSet<string>(StringComparer.Ordinal);
        foreach (var versionDirectory in Directory.EnumerateDirectories(versionsRoot))
        {
            EnsureDirectoryNotReparsePoint(versionDirectory);
            foreach (var digestDirectory in Directory.EnumerateDirectories(versionDirectory))
            {
                EnsureDirectoryNotReparsePoint(digestDirectory);
                if (Path.GetFileName(digestDirectory).StartsWith(".installing-", StringComparison.Ordinal)) { continue; }
                VerifyImmutable(digestDirectory);
                var package = VerifiedInstalledPackage(Path.Combine(digestDirectory, "package"));
                if (package.Manifest.Id != packageId) { throw Failure("LIFECYCLE_CORRUPT_VERSION"); }
                versions.Add(package.Manifest.Version);
            }
        }
        return versions.Order(Comparer<string>.Create(CompareSemanticVersions)).ToArray();
    }

    public PocketAppPackage? ActivePackage(string packageId) =>
        WithLifecycleLock(() => ActivePackageCore(packageId));

    private PocketAppPackage? ActivePackageCore(string packageId)
    {
        var record = ReadActiveRecord(packageId);
        if (record is null || record.State != PocketAppLifecycleState.Enabled) { return null; }
        if (record.Version is null || record.PackageDigest is null)
        {
            throw Failure("LIFECYCLE_READBACK_FAILED");
        }
        var directory = InstalledPackageDirectory(packageId, record.Version, record.PackageDigest);
        var package = VerifiedInstalledPackage(directory);
        if (package.Manifest.Id != packageId
            || package.Manifest.Version != record.Version
            || package.ManifestDigest != record.PackageDigest)
        {
            throw Failure("LIFECYCLE_CORRUPT_VERSION");
        }
        ValidateHostCompatibility(package);
        return package;
    }

    private PocketAppLifecycleReceipt ActivateProposal(
        PocketAppLifecycleProposal proposal,
        PocketAppLifecycleApprovalGrant? approvalGrant,
        DateTimeOffset now) =>
        WithLifecycleLock(() => ActivateProposalCore(proposal, approvalGrant, now));

    private PocketAppLifecycleReceipt ActivateProposalCore(
        PocketAppLifecycleProposal proposal,
        PocketAppLifecycleApprovalGrant? approvalGrant,
        DateTimeOffset now)
    {
        if (!_pendingApprovals.TryGetValue(proposal.RequestId, out var pending)
            || pending.BindingDigest != proposal.BindingDigest
            || pending.ExpiresAt != proposal.ExpiresAt
            || !string.Equals(pending.StagingDirectory, proposal.StagingDirectory, StringComparison.OrdinalIgnoreCase))
        {
            throw Failure("LIFECYCLE_APPROVAL_INVALID");
        }
        if (now > proposal.ExpiresAt)
        {
            DiscardPendingApproval(proposal.RequestId, pending);
            throw Failure("LIFECYCLE_APPROVAL_EXPIRED");
        }
        var current = ReadActiveRecord(proposal.PackageId);
        var currentDigest = current is null || current.State == PocketAppLifecycleState.Removed
            ? null
            : current.PackageDigest;
        if (!string.Equals(currentDigest, proposal.CurrentDigest, StringComparison.Ordinal)
            || current?.State != proposal.CurrentState)
        {
            throw Failure("LIFECYCLE_ACTIVE_CHANGED");
        }

        var sourceSnapshot = PocketAppFileSnapshot.Capture(proposal.StagingDirectory);
        var package = _runtime.Load(sourceSnapshot);
        if (package.Manifest.Id != proposal.PackageId
            || package.Manifest.Version != proposal.Version
            || package.ManifestDigest != proposal.PackageDigest
            || package.StateSchemaDigest != proposal.StateSchemaDigest
            || !package.StatePropertyNames.SetEquals(proposal.StatePropertyNames))
        {
            throw Failure("LIFECYCLE_PACKAGE_CHANGED");
        }
        ValidateHostCompatibility(package);
        if (PreviewDigest(proposal.Previews) != proposal.PreviewDigest)
        {
            throw Failure("LIFECYCLE_PACKAGE_CHANGED");
        }
        var previews = MakePreviews(package);
        if (PreviewDigest(previews) != proposal.PreviewDigest)
        {
            throw Failure("LIFECYCLE_PACKAGE_CHANGED");
        }
        if (!_stagingTestRunner.Run(package).SequenceEqual(proposal.Tests))
        {
            throw Failure("LIFECYCLE_PACKAGE_CHANGED");
        }
        ValidateMigration(package, current);
        var currentPackage = VerifiedCurrentPackage(current);
        var currentEffectivePackage = current?.State == PocketAppLifecycleState.Enabled ? currentPackage : null;
        var currentPermissions = currentEffectivePackage is null
            ? new HashSet<string>(StringComparer.Ordinal)
            : Permissions(currentEffectivePackage);
        var observedDiff = PermissionDiff(currentPermissions, Permissions(package));
        var observedGrantDiff = EffectiveGrantDiff(
            currentEffectivePackage is null
                ? new HashSet<string>(StringComparer.Ordinal)
                : CapabilityGrants(currentEffectivePackage),
            CapabilityGrants(package));
        if (!PermissionDiffEquals(observedDiff, proposal.PermissionDiff)
            || !CapabilityGrantDiffEquals(observedGrantDiff, proposal.CapabilityGrantDiff)
            || !proposal.ApprovalRequired)
        {
            throw Failure("LIFECYCLE_PERMISSION_CHANGED");
        }
        var observedBinding = ApprovalBindingDigest(
            proposal.Action,
            proposal.PackageId,
            proposal.Version,
            proposal.PackageDigest,
            proposal.CurrentDigest,
            proposal.CurrentState,
            proposal.PreviewDigest,
            observedDiff,
            observedGrantDiff);
        if (observedBinding != proposal.BindingDigest)
        {
            throw Failure("LIFECYCLE_APPROVAL_INVALID");
        }
        if (approvalGrant is null) { throw Failure("LIFECYCLE_APPROVAL_REQUIRED"); }
        Consume(approvalGrant, proposal.RequestId, proposal.BindingDigest, now);

        string targetDirectory;
        if (proposal.Action == PocketAppLifecycleAction.Rollback)
        {
            targetDirectory = proposal.StagingDirectory;
            if (VerifiedInstalledPackage(targetDirectory).ManifestDigest != proposal.PackageDigest)
            {
                throw Failure("LIFECYCLE_CORRUPT_VERSION");
            }
            var snapshotRoot = Directory.GetParent(targetDirectory)?.FullName
                ?? throw Failure("LIFECYCLE_CORRUPT_VERSION");
            MakeImmutable(snapshotRoot);
            VerifyImmutable(snapshotRoot);
            if (VerifiedInstalledPackage(targetDirectory).ManifestDigest != proposal.PackageDigest)
            {
                throw Failure("LIFECYCLE_READBACK_FAILED");
            }
            VerifyImmutable(snapshotRoot);
        }
        else
        {
            targetDirectory = InstallImmutableSnapshot(sourceSnapshot, package);
        }
        if (_failureInjection?.Invoke("before_active_commit") == true)
        {
            throw Failure("LIFECYCLE_STORAGE_FAILED");
        }

        var previous = current;
        var record = new ActiveRecord(
            1,
            proposal.PackageId,
            proposal.Version,
            proposal.PackageDigest,
            Permissions(package).Order(StringComparer.Ordinal).ToArray(),
            package.StateSchemaDigest,
            package.StatePropertyNames.Order(StringComparer.Ordinal).ToArray(),
            PocketAppLifecycleState.Enabled,
            now);
        try
        {
            WriteAndVerify(record);
            var readback = VerifiedInstalledPackage(targetDirectory);
            if (readback.Manifest.Id != record.PackageId
                || readback.Manifest.Version != record.Version
                || readback.ManifestDigest != record.PackageDigest)
            {
                throw Failure("LIFECYCLE_READBACK_FAILED");
            }
        }
        catch
        {
            try { Restore(previous, proposal.PackageId); } catch { }
            throw;
        }

        if (proposal.Action != PocketAppLifecycleAction.Rollback)
        {
            try
            {
                var stagingParent = Directory.GetParent(proposal.StagingDirectory)?.FullName;
                if (stagingParent is not null)
                {
                    LiveStagingDirectories.Remove(Path.GetFullPath(stagingParent));
                    if (Directory.Exists(stagingParent)) { Directory.Delete(stagingParent, true); }
                }
            }
            catch { }
        }
        _pendingApprovals.Remove(proposal.RequestId);
        _decidedRequests.Remove(proposal.RequestId);
        return new PocketAppLifecycleReceipt(
            proposal.Action.ToString().ToLowerInvariant(),
            proposal.PackageId,
            proposal.Version,
            proposal.PackageDigest,
            PocketAppLifecycleState.Enabled,
            true,
            null);
    }

    private string InstallImmutableSnapshot(PocketAppFileSnapshot snapshot, PocketAppPackage package)
    {
        var versionRoot = Path.Combine(VersionsRoot(package.Manifest.Id), VersionStorageKey(package.Manifest.Version));
        Directory.CreateDirectory(versionRoot);
        var digestName = package.ManifestDigest["sha256:".Length..];
        var finalRoot = Path.Combine(versionRoot, digestName);
        var finalPackage = Path.Combine(finalRoot, "package");
        var existing = Directory.EnumerateDirectories(versionRoot)
            .Where(path => !Path.GetFileName(path).StartsWith(".installing-", StringComparison.Ordinal))
            .ToArray();
        if (existing.Length != 0)
        {
            if (existing.Length != 1 || !string.Equals(Path.GetFileName(existing[0]), digestName, StringComparison.Ordinal))
            {
                throw Failure("LIFECYCLE_VERSION_CONFLICT");
            }
            if (VerifiedInstalledPackage(finalPackage).ManifestDigest != package.ManifestDigest)
            {
                throw Failure("LIFECYCLE_CORRUPT_VERSION");
            }
            MakeImmutable(finalRoot);
            VerifyImmutable(finalRoot);
            if (VerifiedInstalledPackage(finalPackage).ManifestDigest != package.ManifestDigest)
            {
                throw Failure("LIFECYCLE_READBACK_FAILED");
            }
            return finalPackage;
        }

        var temporaryRoot = Path.Combine(versionRoot, $".installing-{Guid.NewGuid():N}");
        var temporaryPackage = Path.Combine(temporaryRoot, "package");
        var movedToFinal = false;
        try
        {
            if (_failureInjection?.Invoke("snapshot_write") == true) { throw Failure("LIFECYCLE_STORAGE_FAILED"); }
            snapshot.Materialize(temporaryPackage);
            var installedSnapshot = PocketAppFileSnapshot.Capture(temporaryPackage);
            var installed = _runtime.Load(installedSnapshot);
            if (installed.Manifest.Id != package.Manifest.Id
                || installed.Manifest.Version != package.Manifest.Version
                || installed.ManifestDigest != package.ManifestDigest)
            {
                throw Failure("LIFECYCLE_PACKAGE_CHANGED");
            }
            Directory.Move(temporaryRoot, finalRoot);
            movedToFinal = true;
            MakeImmutable(finalRoot);
            VerifyImmutable(finalRoot);
            if (VerifiedInstalledPackage(finalPackage).ManifestDigest != package.ManifestDigest)
            {
                throw Failure("LIFECYCLE_READBACK_FAILED");
            }
            return finalPackage;
        }
        catch
        {
            try
            {
                var cleanupRoot = movedToFinal ? finalRoot : temporaryRoot;
                if (Directory.Exists(cleanupRoot))
                {
                    MakeMutable(cleanupRoot);
                    Directory.Delete(cleanupRoot, true);
                }
            }
            catch { }
            throw;
        }
    }

    private PocketAppPackage VerifiedInstalledPackage(string directory)
    {
        try
        {
            return _runtime.Load(PocketAppFileSnapshot.Capture(directory));
        }
        catch (PocketAppLifecycleException)
        {
            throw;
        }
        catch
        {
            throw Failure("LIFECYCLE_CORRUPT_VERSION");
        }
    }

    private void ValidateMigration(PocketAppPackage package, ActiveRecord? current)
    {
        if (current is null) { return; }
        var preservedData = Directory.Exists(Path.Combine(_userDataRoot, package.Manifest.Id));
        if (current.State == PocketAppLifecycleState.Removed && !preservedData) { return; }
        if (current.StateSchemaDigest != package.StateSchemaDigest
            || !package.StatePropertyNames.SetEquals(current.StatePropertyNames))
        {
            throw Failure("LIFECYCLE_MIGRATION_REQUIRED");
        }
    }

    private void ValidateHostCompatibility(PocketAppPackage package)
    {
        if (CompareSemanticVersions(package.Manifest.MinimumHostVersion, _hostVersion) > 0)
        {
            throw Failure("LIFECYCLE_HOST_VERSION_UNSUPPORTED");
        }
    }

    private void PurgeExpiredApprovals(DateTimeOffset now)
    {
        foreach (var item in _pendingApprovals.Where(item => now > item.Value.ExpiresAt).ToArray())
        {
            DiscardPendingApproval(item.Key, item.Value);
        }
        foreach (var token in _grants.Where(item => now > item.Value.ExpiresAt).Select(item => item.Key).ToArray())
        {
            _grants.Remove(token);
            _consumedGrants.Remove(token);
        }
    }

    private static bool IsWithinDirectory(string path, string directory)
    {
        var normalizedPath = Path.GetFullPath(path);
        var normalizedDirectory = Path.TrimEndingDirectorySeparator(Path.GetFullPath(directory));
        return normalizedPath.StartsWith(normalizedDirectory + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
    }

    private void DiscardPendingApproval(string requestId, PendingApproval pending)
    {
        if (pending.DisposableStaging)
        {
            try
            {
                var stagingParent = Directory.GetParent(pending.StagingDirectory)?.FullName;
                if (stagingParent is not null)
                {
                    if (Directory.Exists(stagingParent)) { Directory.Delete(stagingParent, true); }
                    LiveStagingDirectories.Remove(Path.GetFullPath(stagingParent));
                }
            }
            catch
            {
                throw Failure("LIFECYCLE_STORAGE_FAILED");
            }
        }
        _pendingApprovals.Remove(requestId);
        _decidedRequests.Remove(requestId);
        foreach (var token in _grants.Where(item => item.Value.RequestId == requestId).Select(item => item.Key).ToArray())
        {
            _grants.Remove(token);
            _consumedGrants.Remove(token);
        }
    }

    private void Consume(
        PocketAppLifecycleApprovalGrant grant,
        string requestId,
        string bindingDigest,
        DateTimeOffset now)
    {
        if (_consumedGrants.Contains(grant.Token)) { throw Failure("LIFECYCLE_APPROVAL_REPLAYED"); }
        if (!_grants.TryGetValue(grant.Token, out var issued)
            || issued.RequestId != requestId
            || issued.BindingDigest != bindingDigest)
        {
            throw Failure("LIFECYCLE_APPROVAL_INVALID");
        }
        _grants.Remove(grant.Token);
        _consumedGrants.Add(grant.Token);
        if (now > issued.ExpiresAt) { throw Failure("LIFECYCLE_APPROVAL_EXPIRED"); }
    }

    private static IReadOnlyList<PocketAppPreviewSurface> MakePreviews(PocketAppPackage package) =>
        package.Surfaces.OrderBy(item => item.Key, StringComparer.Ordinal)
            .Select(item =>
            {
                var data = item.Value.CanonicalRenderModelBytes();
                var repeated = item.Value.CanonicalRenderModelBytes();
                if (!data.AsSpan().SequenceEqual(repeated)) { throw Failure("LIFECYCLE_PACKAGE_CHANGED"); }
                return new PocketAppPreviewSurface(item.Key, Sha256(data), data);
            })
            .ToList()
            .AsReadOnly();

    private static HashSet<string> Permissions(PocketAppPackage package) =>
        package.Manifest.RequestedCapabilities.SelectMany(item => item.Permissions).ToHashSet(StringComparer.Ordinal);

    private static HashSet<string> CapabilityGrants(PocketAppPackage package) =>
        package.Manifest.RequestedCapabilities.Select(request =>
        {
            using var stream = new MemoryStream();
            using (var writer = new Utf8JsonWriter(stream))
            {
                writer.WriteStartObject();
                writer.WriteString("capabilityId", request.Key.Id);
                writer.WriteNumber("capabilityVersion", request.Key.Version);
                writer.WriteString("effect", request.Effect.WireValue());
                writer.WritePropertyName("permissions");
                writer.WriteStartArray();
                foreach (var permission in request.Permissions.Order(StringComparer.Ordinal))
                {
                    writer.WriteStringValue(permission);
                }
                writer.WriteEndArray();
                writer.WritePropertyName("scope");
                if (request.Scope is { } scope)
                {
                    CapabilityCanonicalJson.WriteElement(writer, scope);
                }
                else
                {
                    writer.WriteNullValue();
                }
                writer.WriteEndObject();
            }
            return Encoding.UTF8.GetString(stream.ToArray());
        }).ToHashSet(StringComparer.Ordinal);

    private static PocketAppPermissionDiff PermissionDiff(IReadOnlySet<string> current, IReadOnlySet<string> target) =>
        new(
            target.Except(current, StringComparer.Ordinal).Order(StringComparer.Ordinal).ToArray(),
            current.Except(target, StringComparer.Ordinal).Order(StringComparer.Ordinal).ToArray());

    private static PocketAppCapabilityGrantDiff EffectiveGrantDiff(
        IReadOnlySet<string> current,
        IReadOnlySet<string> target) =>
        new(
            target.Except(current, StringComparer.Ordinal).Order(StringComparer.Ordinal).ToArray(),
            current.Except(target, StringComparer.Ordinal).Order(StringComparer.Ordinal).ToArray());

    private static bool PermissionDiffEquals(PocketAppPermissionDiff left, PocketAppPermissionDiff right) =>
        left.Added.SequenceEqual(right.Added, StringComparer.Ordinal)
        && left.Removed.SequenceEqual(right.Removed, StringComparer.Ordinal);

    private static bool CapabilityGrantDiffEquals(PocketAppCapabilityGrantDiff left, PocketAppCapabilityGrantDiff right) =>
        left.Added.SequenceEqual(right.Added, StringComparer.Ordinal)
        && left.Removed.SequenceEqual(right.Removed, StringComparer.Ordinal);

    private PocketAppPackage? VerifiedCurrentPackage(ActiveRecord? record)
    {
        if (record is null || record.State == PocketAppLifecycleState.Removed) { return null; }
        if (record.Version is null || record.PackageDigest is null)
        {
            throw Failure("LIFECYCLE_READBACK_FAILED");
        }
        var package = VerifiedInstalledPackage(InstalledPackageDirectory(record.PackageId, record.Version, record.PackageDigest));
        if (package.Manifest.Id != record.PackageId
            || package.Manifest.Version != record.Version
            || package.ManifestDigest != record.PackageDigest)
        {
            throw Failure("LIFECYCLE_CORRUPT_VERSION");
        }
        return package;
    }

    private static void RequireSnapshotMatches(PocketAppFileSnapshot source, PocketAppFileSnapshot staged)
    {
        if (source.Files.Count != staged.Files.Count)
        {
            throw Failure("LIFECYCLE_PACKAGE_CHANGED");
        }
        foreach (var item in source.Files)
        {
            if (!staged.Files.TryGetValue(item.Key, out var observed)
                || !item.Value.AsSpan().SequenceEqual(observed))
            {
                throw Failure("LIFECYCLE_PACKAGE_CHANGED");
            }
        }
    }

    private void WriteAndVerify(ActiveRecord record)
    {
        Write(record);
        if (!ActiveRecordEquals(ReadActiveRecord(record.PackageId), record))
        {
            throw Failure("LIFECYCLE_READBACK_FAILED");
        }
    }


    private static bool ActiveRecordEquals(ActiveRecord? left, ActiveRecord right) =>
        left is not null
        && left.RecordVersion == right.RecordVersion
        && left.PackageId == right.PackageId
        && left.Version == right.Version
        && left.PackageDigest == right.PackageDigest
        && left.State == right.State
        && left.StateSchemaDigest == right.StateSchemaDigest
        && left.Permissions.SequenceEqual(right.Permissions, StringComparer.Ordinal)
        && left.StatePropertyNames.SequenceEqual(right.StatePropertyNames, StringComparer.Ordinal);

    private void Write(ActiveRecord record)
    {
        if (_failureInjection?.Invoke("active_write") == true) { throw Failure("LIFECYCLE_STORAGE_FAILED"); }
        var directory = AppRoot(record.PackageId);
        Directory.CreateDirectory(directory);
        var target = ActiveRecordPath(record.PackageId);
        var temporary = Path.Combine(directory, $".active-{Guid.NewGuid():N}.tmp");
        try
        {
            var data = JsonSerializer.SerializeToUtf8Bytes(record);
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                stream.Write(data);
                stream.Flush(true);
            }
            if (!MoveFileEx(
                    temporary,
                    target,
                    MoveFileFlags.ReplaceExisting | MoveFileFlags.WriteThrough))
            {
                throw new IOException($"MoveFileEx failed: {Marshal.GetLastWin32Error()}");
            }
        }
        catch
        {
            try { File.Delete(temporary); } catch { }
            throw Failure("LIFECYCLE_STORAGE_FAILED");
        }
    }

    private void Restore(ActiveRecord? record, string packageId)
    {
        if (record is not null)
        {
            Write(record);
            return;
        }
        var path = ActiveRecordPath(packageId);
        if (File.Exists(path)) { File.Delete(path); }
    }

    private ActiveRecord? ReadActiveRecord(string packageId)
    {
        if (!ValidPackageId(packageId)) { throw Failure("LIFECYCLE_PACKAGE_INVALID"); }
        var path = ActiveRecordPath(packageId);
        if (!File.Exists(path)) { return null; }
        try
        {
            var data = PocketAppFileSnapshot.ReadFileNoFollow(
                _rootDirectory,
                $"Apps/{packageId}/active.json",
                64 * 1024);
            var record = JsonSerializer.Deserialize<ActiveRecord>(data);
            var activeShapeValid = record is not null && (record.State == PocketAppLifecycleState.Removed
                ? record.Version is null && record.PackageDigest is null && record.Permissions.Count == 0
                : record.Version is not null && ValidVersion(record.Version)
                    && record.PackageDigest is not null && ValidDigest(record.PackageDigest)
                    && record.StateSchemaDigest is not null && ValidDigest(record.StateSchemaDigest));
            if (record is null
                || record.RecordVersion != 1
                || record.PackageId != packageId
                || !activeShapeValid
                || !record.Permissions.SequenceEqual(record.Permissions.Order(StringComparer.Ordinal), StringComparer.Ordinal)
                || record.Permissions.Distinct(StringComparer.Ordinal).Count() != record.Permissions.Count
                || record.Permissions.Any(permission => !ValidPermission(permission))
                || (record.StateSchemaDigest is not null && !ValidDigest(record.StateSchemaDigest))
                || !record.StatePropertyNames.SequenceEqual(record.StatePropertyNames.Order(StringComparer.Ordinal), StringComparer.Ordinal)
                || record.StatePropertyNames.Distinct(StringComparer.Ordinal).Count() != record.StatePropertyNames.Count
                || record.StatePropertyNames.Any(property => !ValidStateProperty(property)))
            {
                throw Failure("LIFECYCLE_READBACK_FAILED");
            }
            return record;
        }
        catch (PocketAppLifecycleException)
        {
            throw;
        }
        catch
        {
            throw Failure("LIFECYCLE_READBACK_FAILED");
        }
    }

    private string UniqueVersionDirectory(string packageId, string version)
    {
        var versionRoot = Path.Combine(VersionsRoot(packageId), VersionStorageKey(version));
        if (!Directory.Exists(versionRoot)) { throw Failure("LIFECYCLE_CORRUPT_VERSION"); }
        var candidates = Directory.EnumerateDirectories(versionRoot)
            .Where(path => !Path.GetFileName(path).StartsWith(".installing-", StringComparison.Ordinal))
            .ToArray();
        if (candidates.Length != 1) { throw Failure("LIFECYCLE_CORRUPT_VERSION"); }
        return Path.Combine(candidates[0], "package");
    }

    private void RecoverInterruptedTransactions()
    {
        if (Directory.Exists(StagingRoot))
        {
            EnsureTreeHasNoReparsePoints(StagingRoot);
            foreach (var stagingDirectory in Directory.EnumerateDirectories(StagingRoot).ToArray())
            {
                var normalized = Path.GetFullPath(stagingDirectory);
                if (LiveStagingDirectories.Contains(normalized)) { continue; }
                Directory.Delete(stagingDirectory, true);
            }
        }
        Directory.CreateDirectory(StagingRoot);
        if (!Directory.Exists(AppsRoot)) { return; }
        EnsureDirectoryNotReparsePoint(AppsRoot);
        foreach (var appDirectory in Directory.EnumerateDirectories(AppsRoot))
        {
            EnsureDirectoryNotReparsePoint(appDirectory);
            var tombstones = Directory.EnumerateDirectories(appDirectory)
                .Where(path => Path.GetFileName(path).StartsWith(".removed-Versions-", StringComparison.Ordinal))
                .ToArray();
            if (tombstones.Length != 0)
            {
                var packageId = Path.GetFileName(appDirectory);
                if (!ValidPackageId(packageId)) { throw Failure("LIFECYCLE_CORRUPT_VERSION"); }
                var active = ReadActiveRecord(packageId);
                var versionsPath = Path.Combine(appDirectory, "Versions");
                foreach (var tombstone in tombstones)
                {
                    EnsureDirectoryNotReparsePoint(tombstone);
                    if (active?.State == PocketAppLifecycleState.Removed)
                    {
                        MakeMutable(tombstone);
                        Directory.Delete(tombstone, true);
                    }
                    else if (tombstones.Length == 1 && !Directory.Exists(versionsPath))
                    {
                        Directory.Move(tombstone, versionsPath);
                        MakeImmutable(versionsPath);
                        VerifyImmutable(versionsPath);
                    }
                    else
                    {
                        throw Failure("LIFECYCLE_CORRUPT_VERSION");
                    }
                }
            }
            var versions = Path.Combine(appDirectory, "Versions");
            if (!Directory.Exists(versions)) { continue; }
            EnsureDirectoryNotReparsePoint(versions);
            foreach (var versionDirectory in Directory.EnumerateDirectories(versions))
            {
                EnsureDirectoryNotReparsePoint(versionDirectory);
                foreach (var candidate in Directory.EnumerateDirectories(versionDirectory).ToArray())
                {
                    EnsureDirectoryNotReparsePoint(candidate);
                    if (Path.GetFileName(candidate).StartsWith(".installing-", StringComparison.Ordinal))
                    {
                        MakeMutable(candidate);
                        Directory.Delete(candidate, true);
                    }
                    else
                    {
                        MakeImmutable(candidate);
                        VerifyImmutable(candidate);
                    }
                }
            }
        }
    }

    private static void MakeImmutable(string directory)
    {
        EnsureTreeHasNoReparsePoints(directory);
        foreach (var file in Directory.EnumerateFiles(directory, "*", SearchOption.AllDirectories))
        {
            File.SetAttributes(file, File.GetAttributes(file) | FileAttributes.ReadOnly);
        }
    }

    private static void MakeMutable(string directory)
    {
        if (!Directory.Exists(directory)) { return; }
        EnsureTreeHasNoReparsePoints(directory);
        foreach (var file in Directory.EnumerateFiles(directory, "*", SearchOption.AllDirectories))
        {
            File.SetAttributes(file, File.GetAttributes(file) & ~FileAttributes.ReadOnly);
        }
    }

    private static void VerifyImmutable(string directory)
    {
        if (!Directory.Exists(directory)) { throw Failure("LIFECYCLE_READBACK_FAILED"); }
        EnsureTreeHasNoReparsePoints(directory);
        foreach (var file in Directory.EnumerateFiles(directory, "*", SearchOption.AllDirectories))
        {
            if (!File.GetAttributes(file).HasFlag(FileAttributes.ReadOnly))
            {
                throw Failure("LIFECYCLE_READBACK_FAILED");
            }
        }
    }

    private static void EnsureTreeHasNoReparsePoints(string directory)
    {
        EnsureDirectoryNotReparsePoint(directory);
        foreach (var entry in Directory.EnumerateFileSystemEntries(directory))
        {
            var attributes = File.GetAttributes(entry);
            if (attributes.HasFlag(FileAttributes.ReparsePoint))
            {
                throw Failure("LIFECYCLE_CORRUPT_VERSION");
            }
            if (attributes.HasFlag(FileAttributes.Directory))
            {
                EnsureTreeHasNoReparsePoints(entry);
            }
        }
    }

    private static void EnsureDirectoryNotReparsePoint(string directory)
    {
        if (File.GetAttributes(directory).HasFlag(FileAttributes.ReparsePoint))
        {
            throw Failure("LIFECYCLE_CORRUPT_VERSION");
        }
    }

    private T WithLifecycleLock<T>(Func<T> operation)
    {
        lock (LifecycleGate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            return operation();
        }
    }

    private void WithLifecycleLock(Action operation)
    {
        lock (LifecycleGate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            operation();
        }
    }

    private void Dispose(bool disposing)
    {
        lock (LifecycleGate)
        {
            if (_disposed) { return; }
            foreach (var pending in _pendingApprovals.Values.Where(item => item.DisposableStaging))
            {
                try
                {
                    var stagingParent = Directory.GetParent(pending.StagingDirectory)?.FullName;
                    if (stagingParent is null) { continue; }
                    LiveStagingDirectories.Remove(Path.GetFullPath(stagingParent));
                    if (Directory.Exists(stagingParent)) { Directory.Delete(stagingParent, true); }
                }
                catch { }
            }
            _pendingApprovals.Clear();
            _decidedRequests.Clear();
            _grants.Clear();
            _consumedGrants.Clear();
            _disposed = true;
        }
    }

    [Flags]
    private enum MoveFileFlags : uint
    {
        ReplaceExisting = 0x1,
        WriteThrough = 0x8
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool MoveFileEx(
        string existingFileName,
        string newFileName,
        MoveFileFlags flags);

    private string StagingRoot => Path.Combine(_rootDirectory, "Staging");
    private string AppsRoot => Path.Combine(_rootDirectory, "Apps");
    private string AppRoot(string packageId) => Path.Combine(AppsRoot, packageId);
    private string VersionsRoot(string packageId) => Path.Combine(AppRoot(packageId), "Versions");
    private string ActiveRecordPath(string packageId) => Path.Combine(AppRoot(packageId), "active.json");
    private string InstalledPackageDirectory(string packageId, string version, string digest) =>
        Path.Combine(VersionsRoot(packageId), VersionStorageKey(version), digest["sha256:".Length..], "package");

    private static string VersionStorageKey(string version) =>
        "v-" + Convert.ToHexString(Encoding.UTF8.GetBytes(version)).ToLowerInvariant();

    private static string ApprovalBindingDigest(
        PocketAppLifecycleAction action,
        string packageId,
        string version,
        string packageDigest,
        string? currentDigest,
        PocketAppLifecycleState? currentState,
        string previewDigest,
        PocketAppPermissionDiff permissionDiff,
        PocketAppCapabilityGrantDiff capabilityGrantDiff)
    {
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        void Field(string value)
        {
            hash.AppendData(Encoding.UTF8.GetBytes(value));
            hash.AppendData([0]);
        }
        Field("hoverpocket.lifecycle-approval/v2");
        Field(action.ToString().ToLowerInvariant());
        Field(packageId);
        Field(version);
        Field(packageDigest);
        Field(currentDigest ?? "none");
        Field(currentState?.ToString().ToLowerInvariant() ?? "none");
        Field(previewDigest);
        foreach (var item in permissionDiff.Added.Order(StringComparer.Ordinal)) { Field($"+{item}"); }
        foreach (var item in permissionDiff.Removed.Order(StringComparer.Ordinal)) { Field($"-{item}"); }
        foreach (var item in capabilityGrantDiff.Added.Order(StringComparer.Ordinal)) { Field($"grant+:{item}"); }
        foreach (var item in capabilityGrantDiff.Removed.Order(StringComparer.Ordinal)) { Field($"grant-:{item}"); }
        return "sha256:" + Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant();
    }

    private static string PreviewDigest(IReadOnlyList<PocketAppPreviewSurface> previews)
    {
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        hash.AppendData(Encoding.UTF8.GetBytes("hoverpocket.preview/v1\0"));
        foreach (var preview in previews.OrderBy(item => item.Id, StringComparer.Ordinal))
        {
            var renderModel = preview.CanonicalRenderModelBytes();
            if (!string.Equals(Sha256(renderModel), preview.RenderDigest, StringComparison.Ordinal))
            {
                throw Failure("LIFECYCLE_PACKAGE_CHANGED");
            }
            hash.AppendData(Encoding.UTF8.GetBytes(preview.Id));
            hash.AppendData([0]);
            hash.AppendData(Encoding.UTF8.GetBytes(preview.RenderDigest));
            hash.AppendData([0]);
        }
        return "sha256:" + Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant();
    }

    private static string Sha256(ReadOnlySpan<byte> data) =>
        "sha256:" + Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant();

    private static bool ValidVersion(string value) =>
        value.Length <= 64
        && System.Text.RegularExpressions.Regex.IsMatch(
            value,
            "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z.-]+)?$",
            System.Text.RegularExpressions.RegexOptions.CultureInvariant);

    internal static int CompareSemanticVersions(string left, string right)
    {
        static (string[] Core, string[]? Prerelease) Parse(string value)
        {
            var pieces = value.Split('-', 2, StringSplitOptions.None);
            var core = pieces[0].Split('.');
            return (core, pieces.Length == 2 ? pieces[1].Split('.') : null);
        }

        static int CompareNumeric(string lhs, string rhs)
        {
            var normalizedLeft = lhs.TrimStart('0');
            var normalizedRight = rhs.TrimStart('0');
            if (normalizedLeft.Length == 0) { normalizedLeft = "0"; }
            if (normalizedRight.Length == 0) { normalizedRight = "0"; }
            if (normalizedLeft.Length != normalizedRight.Length)
            {
                return normalizedLeft.Length.CompareTo(normalizedRight.Length);
            }
            return string.CompareOrdinal(normalizedLeft, normalizedRight);
        }

        var lhs = Parse(left);
        var rhs = Parse(right);
        for (var index = 0; index < 3; index++)
        {
            var result = CompareNumeric(lhs.Core[index], rhs.Core[index]);
            if (result != 0) { return result; }
        }
        if (lhs.Prerelease is null && rhs.Prerelease is null) { return 0; }
        if (lhs.Prerelease is null) { return 1; }
        if (rhs.Prerelease is null) { return -1; }
        for (var index = 0; index < Math.Max(lhs.Prerelease.Length, rhs.Prerelease.Length); index++)
        {
            if (index >= lhs.Prerelease.Length) { return -1; }
            if (index >= rhs.Prerelease.Length) { return 1; }
            var leftPart = lhs.Prerelease[index];
            var rightPart = rhs.Prerelease[index];
            if (leftPart == rightPart) { continue; }
            var leftNumeric = leftPart.All(character => character is >= '0' and <= '9');
            var rightNumeric = rightPart.All(character => character is >= '0' and <= '9');
            if (leftNumeric && rightNumeric) { return CompareNumeric(leftPart, rightPart); }
            if (leftNumeric) { return -1; }
            if (rightNumeric) { return 1; }
            return string.CompareOrdinal(leftPart, rightPart);
        }
        return 0;
    }

    private static bool ValidDigest(string value) =>
        System.Text.RegularExpressions.Regex.IsMatch(
            value,
            "^sha256:[a-f0-9]{64}$",
            System.Text.RegularExpressions.RegexOptions.CultureInvariant);

    private static bool ValidPermission(string value) =>
        value.Length <= 128
        && System.Text.RegularExpressions.Regex.IsMatch(
            value,
            "^[a-z][a-z0-9]*(?:\\.[a-z][a-z0-9_]*)+$",
            System.Text.RegularExpressions.RegexOptions.CultureInvariant);

    private static bool ValidStateProperty(string value) =>
        System.Text.RegularExpressions.Regex.IsMatch(
            value,
            "^[A-Za-z][A-Za-z0-9_]{0,63}$",
            System.Text.RegularExpressions.RegexOptions.CultureInvariant);

    private static bool ValidPackageId(string value) =>
        value.Length <= 160
        && System.Text.RegularExpressions.Regex.IsMatch(
            value,
            "^[a-z][a-z0-9]*(?:\\.[a-z0-9][a-z0-9-]*){2,}$",
            System.Text.RegularExpressions.RegexOptions.CultureInvariant);

    private static PocketAppLifecycleException Failure(string code) => new(code);
}
