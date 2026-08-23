using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace HoverPocket.Shell.PocketApps;

internal sealed class PocketAppWorkspaceBackupException(string code) : Exception(code)
{
    public string Code { get; } = code;
}

internal sealed record PocketAppWorkspaceInstalledVersion(string Version, string PackageDigest);

internal sealed record PocketAppWorkspaceBackupApp(
    string AppId,
    string ActiveVersion,
    string ActivePackageDigest,
    string StateSchemaDigest,
    PocketAppLifecycleState LifecycleState,
    IReadOnlyList<string> EffectivePermissions,
    IReadOnlyList<PocketAppWorkspaceInstalledVersion> InstalledVersions,
    int DataVersion,
    string DataDigest);

internal sealed record PocketAppWorkspaceBackupFile(
    string Path,
    int Size,
    string Sha256,
    byte[] Bytes);

internal sealed record PocketAppWorkspaceBackupArchive(
    DateTimeOffset CreatedAt,
    string SourcePlatform,
    string HostVersion,
    IReadOnlyList<PocketAppWorkspaceBackupApp> Apps,
    IReadOnlyList<PocketAppWorkspaceBackupFile> Files)
{
    public const string Schema = "hoverpocket.pocket-app-workspace-backup/v1";
}

internal sealed record PocketAppWorkspaceRestoreChange(
    string AppId,
    string Action,
    string? FromVersion,
    string ToVersion,
    string? FromLifecycleState,
    string ToLifecycleState,
    IReadOnlyList<string> AddedPermissions,
    IReadOnlyList<string> RemovedPermissions,
    bool DataChanged);

internal sealed record PocketAppWorkspaceRestoreProposal(
    string RequestId,
    string BackupDigest,
    string BindingDigest,
    IReadOnlyList<PocketAppWorkspaceRestoreChange> Changes,
    DateTimeOffset CreatedAt,
    DateTimeOffset ExpiresAt);

internal sealed record PocketAppWorkspaceRestoreGrant(string Token);

internal sealed record PocketAppWorkspaceRestoreAppReadback(
    string AppId,
    string Version,
    string PackageDigest,
    PocketAppLifecycleState LifecycleState,
    IReadOnlyList<string> EffectivePermissions,
    bool RuntimeReadbackVerified,
    int DataVersion,
    string DataDigest);

internal sealed record PocketAppWorkspaceRestoreReceipt(
    string BackupDigest,
    IReadOnlyList<PocketAppWorkspaceRestoreAppReadback> RestoredApps,
    bool ReadbackVerified,
    bool RollbackPerformed);

internal sealed class PocketAppWorkspaceBackupManager
{
    public const int MaximumBackupFileBytes = 96 * 1024 * 1024;
    public const int MaximumDecodedBytes = 64 * 1024 * 1024;
    public const int MaximumFiles = 2_048;
    public const int MaximumApps = 64;
    public static readonly TimeSpan ApprovalLifetime = TimeSpan.FromMinutes(5);

    private sealed record PackagePayload(
        string Version,
        string Digest,
        IReadOnlyDictionary<string, byte[]> Files);

    private sealed record ValidatedArchive(
        PocketAppWorkspaceBackupArchive Archive,
        IReadOnlyDictionary<string, IReadOnlyList<PackagePayload>> Packages,
        IReadOnlyDictionary<string, byte[]> UserData,
        byte[] EncodedBytes);

    private sealed record PendingRestore(
        PocketAppWorkspaceRestoreProposal Proposal,
        ValidatedArchive Validated);

    private sealed record IssuedGrant(string RequestId, string BindingDigest, DateTimeOffset ExpiresAt);

    private readonly string _definitionRoot;
    private readonly string _userDataRoot;
    private readonly string _transactionRoot;
    private readonly PocketAppLifecycleManager _lifecycle;
    private readonly PocketAppPackageRuntime _runtime = new();
    private readonly Func<PocketAppLifecycleReceipt, PocketAppRuntimeReadback>? _runtimeReadback;
    private readonly Func<string, bool>? _failureInjection;
    private readonly Dictionary<string, PendingRestore> _pending = new(StringComparer.Ordinal);
    private readonly Dictionary<string, IssuedGrant> _grants = new(StringComparer.Ordinal);

    public PocketAppWorkspaceBackupManager(
        string definitionRoot,
        string userDataRoot,
        string transactionRoot,
        PocketAppLifecycleManager lifecycle,
        Func<PocketAppLifecycleReceipt, PocketAppRuntimeReadback>? runtimeReadback = null,
        Func<string, bool>? failureInjection = null)
    {
        _definitionRoot = Path.GetFullPath(definitionRoot);
        _userDataRoot = Path.GetFullPath(userDataRoot);
        _transactionRoot = Path.GetFullPath(transactionRoot);
        _lifecycle = lifecycle;
        _runtimeReadback = runtimeReadback;
        _failureInjection = failureInjection;
        Directory.CreateDirectory(_transactionRoot);
        RequireDirectory(_definitionRoot, "BACKUP_DEFINITION_ROOT_INVALID");
        RequireDirectory(_userDataRoot, "BACKUP_DATA_ROOT_INVALID");
        RequireDirectory(_transactionRoot, "BACKUP_TRANSACTION_ROOT_INVALID");
    }

    public byte[] ExportBytes(DateTimeOffset? now = null) =>
        Encode(CaptureArchive(now ?? DateTimeOffset.UtcNow));

    public string Export(string destination, DateTimeOffset? now = null)
    {
        var data = ExportBytes(now);
        if (data.Length > MaximumBackupFileBytes) { throw Failure("BACKUP_SIZE_EXCEEDED"); }
        var target = Path.GetFullPath(destination);
        var parent = Path.GetDirectoryName(target) ?? throw Failure("BACKUP_DESTINATION_INVALID");
        RequireDirectory(parent, "BACKUP_DESTINATION_INVALID");
        if (File.Exists(target) && File.GetAttributes(target).HasFlag(FileAttributes.ReparsePoint))
        {
            throw Failure("BACKUP_DESTINATION_INVALID");
        }
        var temporary = Path.Combine(parent, $".hoverpocket-backup-{Guid.NewGuid():N}.tmp");
        try
        {
            using (var stream = new FileStream(
                temporary,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None,
                8192,
                FileOptions.WriteThrough))
            {
                stream.Write(data);
                stream.Flush(true);
            }
            File.Move(temporary, target, overwrite: true);
            var observed = File.ReadAllBytes(target);
            if (!observed.AsSpan().SequenceEqual(data)) { throw Failure("BACKUP_WRITE_READBACK_FAILED"); }
            return Sha256(data);
        }
        catch (PocketAppWorkspaceBackupException)
        {
            try { File.Delete(temporary); } catch { }
            throw;
        }
        catch
        {
            try { File.Delete(temporary); } catch { }
            throw Failure("BACKUP_WRITE_FAILED");
        }
    }

    public PocketAppWorkspaceRestoreProposal PrepareRestore(byte[] data, DateTimeOffset? now = null)
    {
        var observedNow = now ?? DateTimeOffset.UtcNow;
        if (data.Length > MaximumBackupFileBytes) { throw Failure("RESTORE_BACKUP_SIZE_EXCEEDED"); }
        PurgeExpired(observedNow);
        var validated = DecodeAndValidate(data);
        var changes = RestoreChanges(validated);
        var backupDigest = Sha256(data);
        var previewBytes = CanonicalPreview(changes);
        var bindingDigest = Sha256(Encoding.UTF8.GetBytes(backupDigest + "\n").Concat(previewBytes).ToArray());
        var requestId = $"workspace-restore-approval:{Guid.NewGuid():N}";
        var proposal = new PocketAppWorkspaceRestoreProposal(
            requestId,
            backupDigest,
            bindingDigest,
            changes,
            observedNow,
            observedNow.Add(ApprovalLifetime));
        _pending[requestId] = new PendingRestore(proposal, validated);
        return proposal;
    }

    public PocketAppWorkspaceRestoreProposal PrepareRestore(string source, DateTimeOffset? now = null)
    {
        var path = Path.GetFullPath(source);
        if (!File.Exists(path)
            || File.GetAttributes(path).HasFlag(FileAttributes.ReparsePoint)
            || new FileInfo(path).Length > MaximumBackupFileBytes)
        {
            throw Failure("RESTORE_SOURCE_INVALID");
        }
        return PrepareRestore(ReadBoundedFile(path), now);
    }

    public PocketAppWorkspaceRestoreGrant Approve(
        string requestId,
        string bindingDigest,
        DateTimeOffset? now = null)
    {
        var observedNow = now ?? DateTimeOffset.UtcNow;
        PurgeExpired(observedNow);
        if (!_pending.TryGetValue(requestId, out var item)
            || !string.Equals(item.Proposal.BindingDigest, bindingDigest, StringComparison.Ordinal)
            || observedNow > item.Proposal.ExpiresAt)
        {
            throw Failure("RESTORE_APPROVAL_INVALID");
        }
        var token = $"workspace-restore-grant:{Guid.NewGuid():N}";
        _grants[token] = new IssuedGrant(requestId, bindingDigest, item.Proposal.ExpiresAt);
        return new PocketAppWorkspaceRestoreGrant(token);
    }

    public void Reject(string requestId, string bindingDigest)
    {
        if (!_pending.TryGetValue(requestId, out var item)
            || !string.Equals(item.Proposal.BindingDigest, bindingDigest, StringComparison.Ordinal))
        {
            throw Failure("RESTORE_APPROVAL_INVALID");
        }
        _pending.Remove(requestId);
        foreach (var token in _grants.Where(entry => entry.Value.RequestId == requestId).Select(entry => entry.Key).ToArray())
        {
            _grants.Remove(token);
        }
    }

    public PocketAppWorkspaceRestoreReceipt Restore(
        PocketAppWorkspaceRestoreProposal proposal,
        PocketAppWorkspaceRestoreGrant? grant,
        DateTimeOffset? now = null)
    {
        var observedNow = now ?? DateTimeOffset.UtcNow;
        PurgeExpired(observedNow);
        if (!_pending.TryGetValue(proposal.RequestId, out var item) || item.Proposal != proposal)
        {
            throw Failure("RESTORE_PROPOSAL_CHANGED");
        }
        if (grant is null) { throw Failure("RESTORE_APPROVAL_REQUIRED"); }
        var currentPreview = CanonicalPreview(RestoreChanges(item.Validated));
        var approvedPreview = CanonicalPreview(proposal.Changes);
        if (!currentPreview.AsSpan().SequenceEqual(approvedPreview))
        {
            throw Failure("RESTORE_PROPOSAL_CHANGED");
        }
        Consume(grant, proposal, observedNow);
        var affectedIds = item.Validated.Archive.Apps.Select(app => app.AppId).ToHashSet(StringComparer.Ordinal);
        var previous = CaptureArchive(observedNow, affectedIds);
        var previousIds = previous.Apps.Select(app => app.AppId).ToHashSet(StringComparer.Ordinal);
        try
        {
            Apply(item.Validated, observedNow, verifyRuntime: true, allowFailureInjection: true);
            var readbacks = Readback(item.Validated);
            if (readbacks.Count != item.Validated.Archive.Apps.Count || readbacks.Any(item => !item.RuntimeReadbackVerified))
            {
                throw Failure("RESTORE_READBACK_MISMATCH");
            }
            _pending.Remove(proposal.RequestId);
            foreach (var token in _grants
                .Where(entry => entry.Value.RequestId == proposal.RequestId)
                .Select(entry => entry.Key)
                .ToArray())
            {
                _grants.Remove(token);
            }
            return new PocketAppWorkspaceRestoreReceipt(
                proposal.BackupDigest,
                readbacks,
                ReadbackVerified: true,
                RollbackPerformed: false);
        }
        catch
        {
            var rollbackFailed = false;
            try
            {
                RemoveApps(affectedIds, observedNow);
                var previousValidated = DecodeAndValidate(Encode(previous));
                Apply(previousValidated, observedNow, verifyRuntime: true, allowFailureInjection: false);
                foreach (var appId in affectedIds.Except(previousIds, StringComparer.Ordinal))
                {
                    RemoveResidualApp(appId);
                }
            }
            catch
            {
                rollbackFailed = true;
            }
            _pending.Remove(proposal.RequestId);
            foreach (var token in _grants
                .Where(entry => entry.Value.RequestId == proposal.RequestId)
                .Select(entry => entry.Key)
                .ToArray())
            {
                _grants.Remove(token);
            }
            if (rollbackFailed) { throw Failure("RESTORE_ROLLBACK_FAILED"); }
            throw Failure("RESTORE_COMMIT_FAILED_ROLLED_BACK");
        }
    }

    private PocketAppWorkspaceBackupArchive CaptureArchive(
        DateTimeOffset now,
        IReadOnlySet<string>? appIds = null)
    {
        var snapshot = _lifecycle.ManagementSnapshot();
        if (snapshot.Issues.Count != 0) { throw Failure("BACKUP_WORKSPACE_UNHEALTHY"); }
        var managed = snapshot.Packages
            .Where(package => package.State != PocketAppLifecycleState.Removed
                && (appIds is null || appIds.Contains(package.PackageId)))
            .OrderBy(package => package.PackageId, StringComparer.Ordinal)
            .ToArray();
        if (managed.Length > MaximumApps) { throw Failure("BACKUP_APP_LIMIT_EXCEEDED"); }

        var apps = new List<PocketAppWorkspaceBackupApp>();
        var files = new List<PocketAppWorkspaceBackupFile>();
        var decodedTotal = 0;
        foreach (var managedPackage in managed)
        {
            if (managedPackage.Version is null || managedPackage.PackageDigest is null)
            {
                throw Failure("BACKUP_LIFECYCLE_INVALID");
            }
            var packages = InstalledPackages(managedPackage.PackageId);
            var activePayload = packages.SingleOrDefault(payload =>
                payload.Version == managedPackage.Version && payload.Digest == managedPackage.PackageDigest)
                ?? throw Failure("BACKUP_ACTIVE_PACKAGE_MISSING");
            var loadedActive = LoadPackage(activePayload);
            var permissions = loadedActive.Manifest.RequestedCapabilities
                .SelectMany(request => request.Permissions)
                .Distinct(StringComparer.Ordinal)
                .Order(StringComparer.Ordinal)
                .ToArray();
            var stateBytes = ValidatedStateBytes(
                managedPackage.PackageId,
                loadedActive.StateProperties,
                _userDataRoot,
                Encoding.UTF8.GetBytes("{}"));
            var dataDigest = Sha256(stateBytes);
            files.Add(new PocketAppWorkspaceBackupFile(
                $"data/{managedPackage.PackageId}/state.json",
                stateBytes.Length,
                dataDigest,
                stateBytes));
            decodedTotal = checked(decodedTotal + stateBytes.Length);

            foreach (var package in packages)
            {
                foreach (var file in package.Files.OrderBy(entry => entry.Key, StringComparer.Ordinal))
                {
                    var archivePath = $"apps/{managedPackage.PackageId}/versions/{package.Version}/{DigestHex(package.Digest)}/package/{file.Key}";
                    files.Add(new PocketAppWorkspaceBackupFile(
                        archivePath,
                        file.Value.Length,
                        Sha256(file.Value),
                        file.Value));
                    decodedTotal = checked(decodedTotal + file.Value.Length);
                }
            }
            if (decodedTotal > MaximumDecodedBytes) { throw Failure("BACKUP_SIZE_EXCEEDED"); }
            apps.Add(new PocketAppWorkspaceBackupApp(
                managedPackage.PackageId,
                managedPackage.Version,
                managedPackage.PackageDigest,
                loadedActive.StateSchemaDigest,
                managedPackage.State,
                permissions,
                packages.Select(payload => new PocketAppWorkspaceInstalledVersion(payload.Version, payload.Digest)).ToArray(),
                1,
                dataDigest));
        }
        if (files.Count > MaximumFiles) { throw Failure("BACKUP_FILE_LIMIT_EXCEEDED"); }
        files = files.OrderBy(file => file.Path, StringComparer.Ordinal).ToList();
        if (files.Select(file => file.Path).Distinct(StringComparer.OrdinalIgnoreCase).Count() != files.Count)
        {
            throw Failure("BACKUP_CASE_COLLISION");
        }
        return new PocketAppWorkspaceBackupArchive(
            now,
            "windows",
            PocketAppHostContract.Version,
            apps,
            files);
    }

    private ValidatedArchive DecodeAndValidate(byte[] data)
    {
        if (data.Length > MaximumBackupFileBytes) { throw Failure("RESTORE_BACKUP_SIZE_EXCEEDED"); }
        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(data, new JsonDocumentOptions
            {
                AllowTrailingCommas = false,
                CommentHandling = JsonCommentHandling.Disallow,
                MaxDepth = 64
            });
        }
        catch
        {
            throw Failure("RESTORE_DOCUMENT_INVALID");
        }
        using (document)
        {
            var root = document.RootElement;
            RequireObjectKeys(root, ["schema", "createdAt", "sourcePlatform", "hostVersion", "apps", "files"], "RESTORE_DOCUMENT_INVALID");
            if (root.GetProperty("schema").GetString() != PocketAppWorkspaceBackupArchive.Schema
                || !DateTimeOffset.TryParseExact(
                    root.GetProperty("createdAt").GetString(),
                    ["yyyy-MM-dd'T'HH:mm:ss.FFF'Z'", "yyyy-MM-dd'T'HH:mm:ss'Z'"],
                    CultureInfo.InvariantCulture,
                    DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal,
                    out var createdAt)
                || root.GetProperty("sourcePlatform").GetString() is not ("macos" or "windows")
                || root.GetProperty("hostVersion").GetString() is not { } hostVersion
                || !ValidVersion(hostVersion)
                || root.GetProperty("apps").ValueKind != JsonValueKind.Array
                || root.GetProperty("files").ValueKind != JsonValueKind.Array
                || root.GetProperty("apps").GetArrayLength() > MaximumApps
                || root.GetProperty("files").GetArrayLength() > MaximumFiles)
            {
                throw Failure("RESTORE_DOCUMENT_INVALID");
            }

            var files = new List<PocketAppWorkspaceBackupFile>();
            var filePaths = new HashSet<string>(StringComparer.Ordinal);
            var foldedPaths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var decodedTotal = 0;
            foreach (var element in root.GetProperty("files").EnumerateArray())
            {
                RequireObjectKeys(element, ["path", "size", "sha256", "contentBase64"], "RESTORE_FILE_INVALID");
                try
                {
                    var path = element.GetProperty("path").GetString() ?? throw Failure("RESTORE_FILE_INVALID");
                    var size = element.GetProperty("size").GetInt32();
                    var digest = element.GetProperty("sha256").GetString() ?? throw Failure("RESTORE_FILE_INVALID");
                    var encoded = element.GetProperty("contentBase64").GetString() ?? throw Failure("RESTORE_FILE_INVALID");
                    var bytes = Convert.FromBase64String(encoded);
                    if (!SafeArchivePath(path)
                        || Convert.ToBase64String(bytes) != encoded
                        || !ValidDigest(digest)
                        || size != bytes.Length
                        || bytes.Length > PocketAppPackageRuntime.MaximumFileBytes
                        || Sha256(bytes) != digest
                        || !filePaths.Add(path)
                        || !foldedPaths.Add(path))
                    {
                        throw Failure("RESTORE_FILE_INVALID");
                    }
                    decodedTotal = checked(decodedTotal + bytes.Length);
                    if (decodedTotal > MaximumDecodedBytes) { throw Failure("RESTORE_BACKUP_SIZE_EXCEEDED"); }
                    files.Add(new PocketAppWorkspaceBackupFile(path, bytes.Length, digest, bytes));
                }
                catch (PocketAppWorkspaceBackupException)
                {
                    throw;
                }
                catch
                {
                    throw Failure("RESTORE_FILE_INVALID");
                }
            }
            if (!files.Select(file => file.Path).SequenceEqual(
                    files.Select(file => file.Path).Order(StringComparer.Ordinal),
                    StringComparer.Ordinal))
            {
                throw Failure("RESTORE_FILE_ORDER_INVALID");
            }

            var apps = new List<PocketAppWorkspaceBackupApp>();
            var appIds = new HashSet<string>(StringComparer.Ordinal);
            foreach (var element in root.GetProperty("apps").EnumerateArray())
            {
                RequireObjectKeys(
                    element,
                    [
                        "appId", "activeVersion", "activePackageDigest", "stateSchemaDigest",
                        "lifecycleState", "effectivePermissions", "installedVersions", "dataVersion", "dataDigest"
                    ],
                    "RESTORE_APP_INVALID");
                try
                {
                    var appId = element.GetProperty("appId").GetString() ?? throw Failure("RESTORE_APP_INVALID");
                    var activeVersion = element.GetProperty("activeVersion").GetString() ?? throw Failure("RESTORE_APP_INVALID");
                    var activeDigest = element.GetProperty("activePackageDigest").GetString() ?? throw Failure("RESTORE_APP_INVALID");
                    var stateSchemaDigest = element.GetProperty("stateSchemaDigest").GetString() ?? throw Failure("RESTORE_APP_INVALID");
                    var stateText = element.GetProperty("lifecycleState").GetString();
                    var state = stateText switch
                    {
                        "enabled" => PocketAppLifecycleState.Enabled,
                        "disabled" => PocketAppLifecycleState.Disabled,
                        _ => throw Failure("RESTORE_APP_INVALID")
                    };
                    var dataVersion = element.GetProperty("dataVersion").GetInt32();
                    var dataDigest = element.GetProperty("dataDigest").GetString() ?? throw Failure("RESTORE_APP_INVALID");
                    if (!ValidAppId(appId)
                        || !appIds.Add(appId)
                        || !ValidVersion(activeVersion)
                        || !ValidDigest(activeDigest)
                        || !ValidDigest(stateSchemaDigest)
                        || dataVersion != 1
                        || !ValidDigest(dataDigest))
                    {
                        throw Failure("RESTORE_APP_INVALID");
                    }
                    var permissions = element.GetProperty("effectivePermissions").EnumerateArray()
                        .Select(value => value.GetString() ?? throw Failure("RESTORE_PERMISSION_INVALID"))
                        .ToArray();
                    if (permissions.Any(permission => !ValidPermission(permission))
                        || !permissions.SequenceEqual(permissions.Order(StringComparer.Ordinal), StringComparer.Ordinal)
                        || permissions.Distinct(StringComparer.Ordinal).Count() != permissions.Length)
                    {
                        throw Failure("RESTORE_PERMISSION_INVALID");
                    }
                    var versions = new List<PocketAppWorkspaceInstalledVersion>();
                    var versionNames = new HashSet<string>(StringComparer.Ordinal);
                    foreach (var versionElement in element.GetProperty("installedVersions").EnumerateArray())
                    {
                        RequireObjectKeys(versionElement, ["version", "packageDigest"], "RESTORE_VERSION_INVALID");
                        var version = versionElement.GetProperty("version").GetString() ?? throw Failure("RESTORE_VERSION_INVALID");
                        var digest = versionElement.GetProperty("packageDigest").GetString() ?? throw Failure("RESTORE_VERSION_INVALID");
                        if (!ValidVersion(version) || !versionNames.Add(version) || !ValidDigest(digest))
                        {
                            throw Failure("RESTORE_VERSION_INVALID");
                        }
                        versions.Add(new PocketAppWorkspaceInstalledVersion(version, digest));
                    }
                    if (versions.Count == 0
                        || !versions.SequenceEqual(versions.OrderBy(item => item.Version, SemanticVersionComparer.Instance))
                        || !versions.Any(item => item.Version == activeVersion && item.PackageDigest == activeDigest))
                    {
                        throw Failure("RESTORE_VERSION_INVALID");
                    }
                    apps.Add(new PocketAppWorkspaceBackupApp(
                        appId,
                        activeVersion,
                        activeDigest,
                        stateSchemaDigest,
                        state,
                        permissions,
                        versions,
                        dataVersion,
                        dataDigest));
                }
                catch (PocketAppWorkspaceBackupException)
                {
                    throw;
                }
                catch
                {
                    throw Failure("RESTORE_APP_INVALID");
                }
            }
            if (!apps.Select(app => app.AppId).SequenceEqual(
                    apps.Select(app => app.AppId).Order(StringComparer.Ordinal),
                    StringComparer.Ordinal))
            {
                throw Failure("RESTORE_APP_ORDER_INVALID");
            }

            var fileByPath = files.ToDictionary(file => file.Path, StringComparer.Ordinal);
            var expectedPaths = new HashSet<string>(StringComparer.Ordinal);
            var packages = new Dictionary<string, IReadOnlyList<PackagePayload>>(StringComparer.Ordinal);
            var userData = new Dictionary<string, byte[]>(StringComparer.Ordinal);
            foreach (var app in apps)
            {
                var payloads = new List<PackagePayload>();
                foreach (var installed in app.InstalledVersions)
                {
                    var prefix = $"apps/{app.AppId}/versions/{installed.Version}/{DigestHex(installed.PackageDigest)}/package/";
                    var matching = files.Where(file => file.Path.StartsWith(prefix, StringComparison.Ordinal)).ToArray();
                    if (matching.Length == 0) { throw Failure("RESTORE_PACKAGE_MISSING"); }
                    var relativeFiles = matching.ToDictionary(
                        file => file.Path[prefix.Length..],
                        file => file.Bytes,
                        StringComparer.Ordinal);
                    var payload = new PackagePayload(installed.Version, installed.PackageDigest, relativeFiles);
                    var loaded = LoadPackage(payload);
                    if (loaded.Manifest.Id != app.AppId
                        || loaded.Manifest.Version != installed.Version
                        || loaded.ManifestDigest != installed.PackageDigest)
                    {
                        throw Failure("RESTORE_PACKAGE_INVALID");
                    }
                    payloads.Add(payload);
                    expectedPaths.UnionWith(matching.Select(file => file.Path));
                }
                var active = payloads.SingleOrDefault(payload =>
                    payload.Version == app.ActiveVersion && payload.Digest == app.ActivePackageDigest)
                    ?? throw Failure("RESTORE_ACTIVE_PACKAGE_MISSING");
                var loadedActive = LoadPackage(active);
                var observedPermissions = loadedActive.Manifest.RequestedCapabilities
                    .SelectMany(request => request.Permissions)
                    .Distinct(StringComparer.Ordinal)
                    .Order(StringComparer.Ordinal)
                    .ToArray();
                if (loadedActive.StateSchemaDigest != app.StateSchemaDigest
                    || !observedPermissions.SequenceEqual(app.EffectivePermissions, StringComparer.Ordinal))
                {
                    throw Failure("RESTORE_APP_BINDING_MISMATCH");
                }
                var dataPath = $"data/{app.AppId}/state.json";
                if (!fileByPath.TryGetValue(dataPath, out var stateFile) || stateFile.Sha256 != app.DataDigest)
                {
                    throw Failure("RESTORE_DATA_MISSING");
                }
                _ = ValidatedStateBytes(app.AppId, loadedActive.StateProperties, stateFile.Bytes);
                expectedPaths.Add(dataPath);
                packages[app.AppId] = payloads;
                userData[app.AppId] = stateFile.Bytes;
            }
            if (!expectedPaths.SetEquals(filePaths)) { throw Failure("RESTORE_UNREFERENCED_FILE"); }
            return new ValidatedArchive(
                new PocketAppWorkspaceBackupArchive(createdAt, root.GetProperty("sourcePlatform").GetString()!, hostVersion, apps, files),
                packages,
                userData,
                data.ToArray());
        }
    }

    private IReadOnlyList<PocketAppWorkspaceRestoreChange> RestoreChanges(ValidatedArchive validated)
    {
        var changes = new List<PocketAppWorkspaceRestoreChange>();
        foreach (var app in validated.Archive.Apps)
        {
            var current = _lifecycle.ManagedPackage(app.AppId);
            IReadOnlyList<string> currentPermissions = [];
            if (current?.Version is { } version && current.PackageDigest is { } digest)
            {
                var payload = InstalledPackages(app.AppId).SingleOrDefault(item => item.Version == version && item.Digest == digest);
                if (payload is not null)
                {
                    currentPermissions = LoadPackage(payload).Manifest.RequestedCapabilities
                        .SelectMany(request => request.Permissions)
                        .Distinct(StringComparer.Ordinal)
                        .Order(StringComparer.Ordinal)
                        .ToArray();
                }
            }
            byte[]? currentData = null;
            try { currentData = CurrentStateBytes(app.AppId); } catch { }
            var targetData = validated.UserData[app.AppId];
            changes.Add(new PocketAppWorkspaceRestoreChange(
                app.AppId,
                current is null || current.State == PocketAppLifecycleState.Removed ? "add" : "replace",
                current?.Version,
                app.ActiveVersion,
                current?.State.ToString().ToLowerInvariant(),
                app.LifecycleState.ToString().ToLowerInvariant(),
                app.EffectivePermissions.Except(currentPermissions, StringComparer.Ordinal).ToArray(),
                currentPermissions.Except(app.EffectivePermissions, StringComparer.Ordinal).ToArray(),
                currentData is null || !currentData.AsSpan().SequenceEqual(targetData)));
        }
        return changes.OrderBy(change => change.AppId, StringComparer.Ordinal).ToArray();
    }

    private void Apply(ValidatedArchive validated, DateTimeOffset now, bool verifyRuntime, bool allowFailureInjection)
    {
        var appIds = validated.Archive.Apps.Select(app => app.AppId).ToHashSet(StringComparer.Ordinal);
        RemoveApps(appIds, now);
        foreach (var app in validated.Archive.Apps)
        {
            if (!validated.Packages.TryGetValue(app.AppId, out var payloads)
                || !validated.UserData.TryGetValue(app.AppId, out var stateBytes))
            {
                throw Failure("RESTORE_PACKAGE_MISSING");
            }
            foreach (var payload in payloads)
            {
                var draft = Path.Combine(_transactionRoot, $"draft-{Guid.NewGuid():N}");
                try
                {
                    new PocketAppFileSnapshot(
                        draft,
                        payload.Files,
                        new Dictionary<string, PocketAppFileIdentity>(StringComparer.Ordinal)).Materialize(draft);
                    var proposal = _lifecycle.Stage(draft, now);
                    if (proposal.PackageId != app.AppId
                        || proposal.Version != payload.Version
                        || proposal.PackageDigest != payload.Digest)
                    {
                        throw Failure("RESTORE_PACKAGE_CHANGED");
                    }
                    var grant = _lifecycle.Approve(proposal.RequestId, proposal.BindingDigest, now);
                    _ = _lifecycle.Install(proposal, grant, now);
                }
                finally
                {
                    try { if (Directory.Exists(draft)) { Directory.Delete(draft, true); } } catch { }
                }
            }
            var current = _lifecycle.ManagedPackage(app.AppId);
            if (current?.Version != app.ActiveVersion || current.PackageDigest != app.ActivePackageDigest)
            {
                var rollback = _lifecycle.PrepareRollback(app.AppId, app.ActiveVersion, now);
                if (rollback.PackageDigest != app.ActivePackageDigest)
                {
                    throw Failure("RESTORE_ACTIVE_PACKAGE_MISMATCH");
                }
                var grant = _lifecycle.Approve(rollback.RequestId, rollback.BindingDigest, now);
                _ = _lifecycle.Rollback(rollback, grant, now);
            }
            ReplaceState(app.AppId, stateBytes);
            if (app.LifecycleState == PocketAppLifecycleState.Disabled)
            {
                _ = _lifecycle.Disable(app.AppId, now);
            }
            if (allowFailureInjection && _failureInjection?.Invoke("after_app_commit") == true)
            {
                throw Failure("RESTORE_INJECTED_FAILURE");
            }
            if (verifyRuntime) { VerifyFinalRuntime(app); }
        }
    }

    private IReadOnlyList<PocketAppWorkspaceRestoreAppReadback> Readback(ValidatedArchive validated)
    {
        var result = new List<PocketAppWorkspaceRestoreAppReadback>();
        foreach (var app in validated.Archive.Apps)
        {
            var current = _lifecycle.ManagedPackage(app.AppId);
            if (current?.Version != app.ActiveVersion
                || current.PackageDigest != app.ActivePackageDigest
                || current.State != app.LifecycleState)
            {
                throw Failure("RESTORE_LIFECYCLE_READBACK_MISMATCH");
            }
            var stateBytes = CurrentStateBytes(app.AppId);
            if (Sha256(stateBytes) != app.DataDigest) { throw Failure("RESTORE_DATA_READBACK_MISMATCH"); }
            VerifyFinalRuntime(app);
            result.Add(new PocketAppWorkspaceRestoreAppReadback(
                app.AppId,
                app.ActiveVersion,
                app.ActivePackageDigest,
                app.LifecycleState,
                app.EffectivePermissions,
                RuntimeReadbackVerified: true,
                app.DataVersion,
                app.DataDigest));
        }
        return result;
    }

    private void VerifyFinalRuntime(PocketAppWorkspaceBackupApp app)
    {
        if (_runtimeReadback is null) { return; }
        var effective = app.LifecycleState == PocketAppLifecycleState.Enabled
            ? app.EffectivePermissions
            : Array.Empty<string>();
        var receipt = new PocketAppLifecycleReceipt(
            "workspace_restore",
            app.AppId,
            app.ActiveVersion,
            app.ActivePackageDigest,
            effective,
            app.LifecycleState,
            ReadbackVerified: true,
            DataDisposition: null);
        var observed = _runtimeReadback(receipt);
        if (!observed.Matches(receipt) || _failureInjection?.Invoke("runtime_readback") == true)
        {
            throw Failure("RESTORE_RUNTIME_READBACK_MISMATCH");
        }
    }

    private void RemoveApps(IReadOnlySet<string> appIds, DateTimeOffset now)
    {
        foreach (var appId in appIds.Order(StringComparer.Ordinal))
        {
            var current = _lifecycle.ManagedPackage(appId);
            if (current is not null && current.State != PocketAppLifecycleState.Removed)
            {
                _ = _lifecycle.Remove(appId, PocketAppDataDisposition.Preserve, now);
            }
        }
    }

    private void RemoveResidualApp(string appId)
    {
        foreach (var path in [Path.Combine(_definitionRoot, "Apps", appId), Path.Combine(_userDataRoot, appId)])
        {
            if (!Directory.Exists(path)) { continue; }
            if (File.GetAttributes(path).HasFlag(FileAttributes.ReparsePoint))
            {
                throw Failure("RESTORE_ROLLBACK_FAILED");
            }
            Directory.Delete(path, true);
        }
    }

    private IReadOnlyList<PackagePayload> InstalledPackages(string appId)
    {
        if (!ValidAppId(appId)) { throw Failure("BACKUP_APP_INVALID"); }
        var versionsRoot = Path.Combine(_definitionRoot, "Apps", appId, "Versions");
        if (!Directory.Exists(versionsRoot)) { return Array.Empty<PackagePayload>(); }
        RequireDirectory(versionsRoot, "BACKUP_VERSION_ROOT_INVALID");
        var result = new List<PackagePayload>();
        foreach (var versionDirectory in ChildDirectories(versionsRoot))
        {
            foreach (var digestDirectory in ChildDirectories(versionDirectory)
                .Where(path => !Path.GetFileName(path).StartsWith(".installing-", StringComparison.Ordinal)))
            {
                var packageDirectory = Path.Combine(digestDirectory, "package");
                var snapshot = PocketAppFileSnapshot.Capture(packageDirectory);
                var package = _runtime.Load(snapshot);
                if (package.Manifest.Id != appId || Path.GetFileName(digestDirectory) != DigestHex(package.ManifestDigest))
                {
                    throw Failure("BACKUP_PACKAGE_INVALID");
                }
                result.Add(new PackagePayload(package.Manifest.Version, package.ManifestDigest, snapshot.Files));
            }
        }
        result = result.OrderBy(payload => payload.Version, SemanticVersionComparer.Instance).ToList();
        if (result.Select(payload => payload.Version).Distinct(StringComparer.Ordinal).Count() != result.Count)
        {
            throw Failure("BACKUP_VERSION_CONFLICT");
        }
        return result;
    }

    private PocketAppPackage LoadPackage(PackagePayload payload)
    {
        try
        {
            return _runtime.Load(new PocketAppFileSnapshot(
                _transactionRoot,
                payload.Files,
                new Dictionary<string, PocketAppFileIdentity>(StringComparer.Ordinal)));
        }
        catch
        {
            throw Failure("RESTORE_PACKAGE_INVALID");
        }
    }

    private byte[] ValidatedStateBytes(
        string appId,
        IReadOnlyDictionary<string, PocketAppStatePropertySchema> stateProperties,
        string sourceRoot,
        byte[] defaultIfMissing)
    {
        var path = Path.Combine(sourceRoot, appId, "state.json");
        var bytes = File.Exists(path)
            ? PocketAppFileSnapshot.ReadFileNoFollow(sourceRoot, $"{appId}/state.json", PocketAppUserStateStore.MaximumDocumentBytes)
            : defaultIfMissing;
        return ValidatedStateBytes(appId, stateProperties, bytes);
    }

    private byte[] ValidatedStateBytes(
        string appId,
        IReadOnlyDictionary<string, PocketAppStatePropertySchema> stateProperties,
        byte[] bytes)
    {
        if (bytes.Length > PocketAppUserStateStore.MaximumDocumentBytes) { throw Failure("RESTORE_DATA_INVALID"); }
        var root = Path.Combine(_transactionRoot, $"validate-{Guid.NewGuid():N}");
        var appRoot = Path.Combine(root, appId);
        try
        {
            Directory.CreateDirectory(appRoot);
            File.WriteAllBytes(Path.Combine(appRoot, "state.json"), bytes);
            using var store = new PocketAppUserStateStore(appId, stateProperties, root);
            var observed = PocketAppFileSnapshot.ReadFileNoFollow(
                root,
                $"{appId}/state.json",
                PocketAppUserStateStore.MaximumDocumentBytes);
            if (!observed.AsSpan().SequenceEqual(bytes)) { throw Failure("RESTORE_DATA_SCHEMA_INVALID"); }
            return bytes;
        }
        finally
        {
            try { if (Directory.Exists(root)) { Directory.Delete(root, true); } } catch { }
        }
    }

    private void ReplaceState(string appId, byte[] bytes)
    {
        var directory = Path.Combine(_userDataRoot, appId);
        Directory.CreateDirectory(directory);
        RequireDirectory(directory, "RESTORE_DATA_ROOT_INVALID");
        var target = Path.Combine(directory, "state.json");
        var temporary = Path.Combine(directory, $".state-{Guid.NewGuid():N}.tmp");
        try
        {
            using (var stream = new FileStream(
                temporary,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None,
                8192,
                FileOptions.WriteThrough))
            {
                stream.Write(bytes);
                stream.Flush(true);
            }
            File.Move(temporary, target, overwrite: true);
            if (!CurrentStateBytes(appId).AsSpan().SequenceEqual(bytes))
            {
                throw Failure("RESTORE_DATA_READBACK_MISMATCH");
            }
        }
        catch (PocketAppWorkspaceBackupException)
        {
            try { File.Delete(temporary); } catch { }
            throw;
        }
        catch
        {
            try { File.Delete(temporary); } catch { }
            throw Failure("RESTORE_DATA_WRITE_FAILED");
        }
    }

    private byte[] CurrentStateBytes(string appId)
    {
        var path = Path.Combine(_userDataRoot, appId, "state.json");
        return File.Exists(path)
            ? PocketAppFileSnapshot.ReadFileNoFollow(
                _userDataRoot,
                $"{appId}/state.json",
                PocketAppUserStateStore.MaximumDocumentBytes)
            : Encoding.UTF8.GetBytes("{}");
    }

    private static byte[] Encode(PocketAppWorkspaceBackupArchive archive)
    {
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream))
        {
            writer.WriteStartObject();
            writer.WritePropertyName("apps");
            writer.WriteStartArray();
            foreach (var app in archive.Apps)
            {
                writer.WriteStartObject();
                writer.WriteString("activePackageDigest", app.ActivePackageDigest);
                writer.WriteString("activeVersion", app.ActiveVersion);
                writer.WriteString("appId", app.AppId);
                writer.WriteString("dataDigest", app.DataDigest);
                writer.WriteNumber("dataVersion", app.DataVersion);
                writer.WritePropertyName("effectivePermissions");
                writer.WriteStartArray();
                foreach (var permission in app.EffectivePermissions) { writer.WriteStringValue(permission); }
                writer.WriteEndArray();
                writer.WritePropertyName("installedVersions");
                writer.WriteStartArray();
                foreach (var installed in app.InstalledVersions)
                {
                    writer.WriteStartObject();
                    writer.WriteString("packageDigest", installed.PackageDigest);
                    writer.WriteString("version", installed.Version);
                    writer.WriteEndObject();
                }
                writer.WriteEndArray();
                writer.WriteString("lifecycleState", LifecycleWireValue(app.LifecycleState));
                writer.WriteString("stateSchemaDigest", app.StateSchemaDigest);
                writer.WriteEndObject();
            }
            writer.WriteEndArray();
            writer.WriteString("createdAt", archive.CreatedAt.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture));
            writer.WritePropertyName("files");
            writer.WriteStartArray();
            foreach (var file in archive.Files)
            {
                writer.WriteStartObject();
                writer.WriteString("contentBase64", Convert.ToBase64String(file.Bytes));
                writer.WriteString("path", file.Path);
                writer.WriteString("sha256", file.Sha256);
                writer.WriteNumber("size", file.Size);
                writer.WriteEndObject();
            }
            writer.WriteEndArray();
            writer.WriteString("hostVersion", archive.HostVersion);
            writer.WriteString("schema", PocketAppWorkspaceBackupArchive.Schema);
            writer.WriteString("sourcePlatform", archive.SourcePlatform);
            writer.WriteEndObject();
        }
        var data = stream.ToArray();
        if (data.Length > MaximumBackupFileBytes) { throw Failure("BACKUP_SIZE_EXCEEDED"); }
        return data;
    }

    private static byte[] CanonicalPreview(IReadOnlyList<PocketAppWorkspaceRestoreChange> changes)
    {
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream))
        {
            writer.WriteStartArray();
            foreach (var change in changes)
            {
                writer.WriteStartObject();
                writer.WriteString("action", change.Action);
                writer.WritePropertyName("addedPermissions");
                writer.WriteStartArray();
                foreach (var permission in change.AddedPermissions) { writer.WriteStringValue(permission); }
                writer.WriteEndArray();
                writer.WriteString("appId", change.AppId);
                writer.WriteBoolean("dataChanged", change.DataChanged);
                if (change.FromLifecycleState is null) { writer.WriteNull("fromLifecycleState"); }
                else { writer.WriteString("fromLifecycleState", change.FromLifecycleState); }
                if (change.FromVersion is null) { writer.WriteNull("fromVersion"); }
                else { writer.WriteString("fromVersion", change.FromVersion); }
                writer.WritePropertyName("removedPermissions");
                writer.WriteStartArray();
                foreach (var permission in change.RemovedPermissions) { writer.WriteStringValue(permission); }
                writer.WriteEndArray();
                writer.WriteString("toLifecycleState", change.ToLifecycleState);
                writer.WriteString("toVersion", change.ToVersion);
                writer.WriteEndObject();
            }
            writer.WriteEndArray();
        }
        return stream.ToArray();
    }

    private void Consume(PocketAppWorkspaceRestoreGrant grant, PocketAppWorkspaceRestoreProposal proposal, DateTimeOffset now)
    {
        if (!_grants.Remove(grant.Token, out var issued)
            || issued.RequestId != proposal.RequestId
            || issued.BindingDigest != proposal.BindingDigest
            || now > issued.ExpiresAt)
        {
            throw Failure("RESTORE_APPROVAL_INVALID");
        }
    }

    private void PurgeExpired(DateTimeOffset now)
    {
        foreach (var requestId in _pending.Values
            .Where(item => now > item.Proposal.ExpiresAt)
            .Select(item => item.Proposal.RequestId)
            .ToArray())
        {
            _pending.Remove(requestId);
            foreach (var token in _grants.Where(item => item.Value.RequestId == requestId).Select(item => item.Key).ToArray())
            {
                _grants.Remove(token);
            }
        }
    }

    private static void RequireDirectory(string path, string code)
    {
        if (!Directory.Exists(path) || File.GetAttributes(path).HasFlag(FileAttributes.ReparsePoint))
        {
            throw Failure(code);
        }
    }

    private static IReadOnlyList<string> ChildDirectories(string root)
    {
        var result = new List<string>();
        foreach (var path in Directory.EnumerateDirectories(root).Order(StringComparer.Ordinal))
        {
            if (File.GetAttributes(path).HasFlag(FileAttributes.ReparsePoint))
            {
                throw Failure("BACKUP_TREE_INVALID");
            }
            result.Add(path);
        }
        return result;
    }

    private static void RequireObjectKeys(JsonElement element, IReadOnlySet<string> expected, string code)
    {
        if (element.ValueKind != JsonValueKind.Object) { throw Failure(code); }
        var observed = new HashSet<string>(StringComparer.Ordinal);
        foreach (var property in element.EnumerateObject())
        {
            if (!observed.Add(property.Name)) { throw Failure(code); }
        }
        if (!observed.SetEquals(expected)) { throw Failure(code); }
    }

    private static bool SafeArchivePath(string value)
    {
        if (string.IsNullOrEmpty(value)
            || value.Length > 1024
            || !value.IsNormalized(NormalizationForm.FormC)
            || value.StartsWith('/', StringComparison.Ordinal)
            || value.Contains('\\')
            || value.Contains(':')
            || value.Contains('\0'))
        {
            return false;
        }
        var components = value.Split('/', StringSplitOptions.None);
        if (components.Any(component => component.Length == 0 || component is "." or "..")) { return false; }
        if (components[0] == "data")
        {
            return components.Length == 3 && ValidAppId(components[1]) && components[2] == "state.json";
        }
        return components.Length >= 7
            && components[0] == "apps"
            && ValidAppId(components[1])
            && components[2] == "versions"
            && ValidVersion(components[3])
            && Regex.IsMatch(components[4], "^[0-9a-f]{64}$", RegexOptions.CultureInvariant)
            && components[5] == "package"
            && components.Skip(6).All(component =>
                Regex.IsMatch(component, "^[A-Za-z0-9][A-Za-z0-9._-]*$", RegexOptions.CultureInvariant));
    }

    private static bool ValidAppId(string value) =>
        value.Length <= 160
        && Regex.IsMatch(value, "^[a-z][a-z0-9]*(?:\\.[a-z0-9][a-z0-9-]*){2,}$", RegexOptions.CultureInvariant);

    private static bool ValidVersion(string value) =>
        value.Length <= 64
        && Regex.IsMatch(
            value,
            "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z.-]+)?$",
            RegexOptions.CultureInvariant);

    private static bool ValidDigest(string value) =>
        Regex.IsMatch(value, "^sha256:[0-9a-f]{64}$", RegexOptions.CultureInvariant);

    private static bool ValidPermission(string value) =>
        value.Length <= 128
        && Regex.IsMatch(value, "^[a-z][a-z0-9]*(?:\\.[a-z0-9][a-z0-9-]*)+$", RegexOptions.CultureInvariant);

    private static string LifecycleWireValue(PocketAppLifecycleState state) => state switch
    {
        PocketAppLifecycleState.Enabled => "enabled",
        PocketAppLifecycleState.Disabled => "disabled",
        _ => throw Failure("BACKUP_LIFECYCLE_INVALID")
    };

    private static string Sha256(ReadOnlySpan<byte> data) =>
        "sha256:" + Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant();

    private static string DigestHex(string digest) => digest["sha256:".Length..];

    private static byte[] ReadBoundedFile(string path)
    {
        using var stream = new FileStream(
            path,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read,
            64 * 1_024,
            FileOptions.SequentialScan);
        if (stream.Length > MaximumBackupFileBytes) { throw Failure("RESTORE_BACKUP_SIZE_EXCEEDED"); }
        using var result = new MemoryStream((int)stream.Length);
        var buffer = new byte[64 * 1_024];
        while (true)
        {
            var read = stream.Read(buffer, 0, buffer.Length);
            if (read == 0) { break; }
            if (result.Length > MaximumBackupFileBytes - read)
            {
                throw Failure("RESTORE_BACKUP_SIZE_EXCEEDED");
            }
            result.Write(buffer, 0, read);
        }
        return result.ToArray();
    }

    private static PocketAppWorkspaceBackupException Failure(string code) => new(code);

    private sealed class SemanticVersionComparer : IComparer<string>
    {
        public static SemanticVersionComparer Instance { get; } = new();

        public int Compare(string? left, string? right)
        {
            if (ReferenceEquals(left, right)) { return 0; }
            if (left is null) { return -1; }
            if (right is null) { return 1; }
            return PocketAppLifecycleManager.CompareSemanticVersions(left, right);
        }
    }
}
