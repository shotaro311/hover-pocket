using System.Text;
using System.Text.Json;
using HoverPocket.Shell.Bridge;

namespace HoverPocket.Shell.PocketApps;

internal sealed class PocketAppGenerationController : IDisposable
{
    private readonly IPocketAppGenerationAdapter? _generator;
    private readonly PocketAppLifecycleManager _lifecycle;
    private readonly PocketAppGenerationMaterializer _materializer;
    private readonly PocketAppWorkspaceBackupManager _workspaceBackupManager;
    private readonly PocketAppPinnedDirectory[] _pins;
    private readonly Action? _postCommitHook;
    private readonly Action? _postRefreshHook;
    private Func<string, CancellationToken, Task<PocketAppStateTransitionLease>>? _beforeDeactivate;
    private Func<PocketAppStateTransitionLease, Task>? _completeDeactivate;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly object _stateSync = new();
    private PocketAppGenerationPhase _phase = PocketAppGenerationPhase.Idle;
    private PocketAppLifecycleProposal? _pendingProposal;
    private PocketAppLifecycleReceipt? _lastReceipt;
    private PocketAppWorkspaceRestoreProposal? _pendingWorkspaceRestore;
    private PocketAppWorkspaceRestoreReceipt? _lastWorkspaceRestoreReceipt;
    private IReadOnlyList<PocketAppManagedPackage> _managedPackages = Array.Empty<PocketAppManagedPackage>();
    private IReadOnlyList<PocketAppManagementIssue> _managementIssues = Array.Empty<PocketAppManagementIssue>();
    private IReadOnlyList<PocketAppHealthSnapshot> _appHealth = Array.Empty<PocketAppHealthSnapshot>();
    private string? _errorCode;
    private string? _lastWorkspaceBackupDigest;
    private string? _workspaceBackupErrorCode;
    private CancellationTokenSource? _generationCancellation;
    private bool _enabled = true;
    private bool _pendingAllowsActivation;
    private bool _disposed;

    public PocketAppGenerationController(
        string rootDirectory,
        string userDataRoot,
        string generationRoot,
        IPocketAppGenerationAdapter? generator,
        Action? postCommitHook = null,
        Func<PocketAppLifecycleReceipt, PocketAppRuntimeReadback>? runtimeActivationReadback = null,
        Action? postRefreshHook = null)
    {
        var definitionPin = new PocketAppPinnedDirectory(rootDirectory);
        var userDataPin = new PocketAppPinnedDirectory(userDataRoot);
        var generationPin = new PocketAppPinnedDirectory(generationRoot);
        _pins = [definitionPin, userDataPin, generationPin];
        _generator = generator;
        _postCommitHook = postCommitHook;
        _postRefreshHook = postRefreshHook;
        _lifecycle = new PocketAppLifecycleManager(
            definitionPin.FullPath,
            userDataPin.FullPath,
            performStartupRecovery: false,
            activationReadback: runtimeActivationReadback);
        _materializer = new PocketAppGenerationMaterializer(generationPin.FullPath);
        _workspaceBackupManager = new PocketAppWorkspaceBackupManager(
            definitionPin.FullPath,
            userDataPin.FullPath,
            Path.Combine(definitionPin.FullPath, "BackupRestore"),
            _lifecycle,
            runtimeActivationReadback);
        ValidatePins();
        RefreshManagedPackages();
    }

    public void SetEnabled(bool enabled)
    {
        PocketAppLifecycleProposal? pending = null;
        PocketAppWorkspaceRestoreProposal? pendingWorkspaceRestore = null;
        lock (_stateSync)
        {
            _enabled = enabled;
            if (!enabled)
            {
                _generationCancellation?.Cancel();
                pending = _pendingProposal;
                pendingWorkspaceRestore = _pendingWorkspaceRestore;
                _pendingProposal = null;
                _pendingWorkspaceRestore = null;
                _pendingAllowsActivation = false;
                _phase = PocketAppGenerationPhase.Idle;
                _errorCode = null;
            }
        }
        if (!enabled && pending is not null)
        {
            try { _lifecycle.Reject(pending.RequestId, pending.BindingDigest); } catch { }
        }
        if (!enabled && pendingWorkspaceRestore is not null)
        {
            try
            {
                _workspaceBackupManager.Reject(
                    pendingWorkspaceRestore.RequestId,
                    pendingWorkspaceRestore.BindingDigest);
            }
            catch { }
        }
    }

    public void SetBeforeDeactivate(
        Func<string, CancellationToken, Task<PocketAppStateTransitionLease>>? beforeDeactivate,
        Func<PocketAppStateTransitionLease, Task>? completeDeactivate = null)
    {
        _beforeDeactivate = beforeDeactivate;
        _completeDeactivate = completeDeactivate;
    }

    public void AttachSettings(
        BridgeDispatcher dispatcher,
        Func<System.Windows.Window?>? approvalOwner = null,
        Func<PocketAppLifecycleProposal, bool>? approvalDecision = null,
        Func<string?>? workspaceBackupExportTarget = null,
        Func<string?>? workspaceBackupRestoreSource = null,
        Func<PocketAppWorkspaceRestoreProposal, bool>? workspaceRestoreDecision = null)
    {
        dispatcher.Register("pocketApps.generationState", (_, cancellationToken) =>
            Task.FromResult<object?>(BuildState(cancellationToken)));
        dispatcher.Register("pocketApps.generate", GenerateAsync);
        dispatcher.Register("pocketApps.cancelGeneration", CancelGenerationAsync);
        dispatcher.Register(
            "pocketApps.presentApproval",
            (_, cancellationToken) => PresentApprovalAsync(approvalOwner, approvalDecision, cancellationToken));
        dispatcher.Register("pocketApps.reject", RejectAsync);
        dispatcher.Register("pocketApps.disable", DisableAsync);
        dispatcher.Register("pocketApps.enable", EnableAsync);
        dispatcher.Register("pocketApps.removePreservingData", RemovePreservingDataAsync);
        dispatcher.Register("pocketApps.prepareRollback", PrepareRollbackAsync);
        dispatcher.Register("pocketApps.prepareCapabilityMigration", PrepareCapabilityMigrationAsync);
        dispatcher.Register(
            "pocketApps.exportBackup",
            (_, cancellationToken) => ExportWorkspaceAsync(
                approvalOwner,
                workspaceBackupExportTarget,
                cancellationToken));
        dispatcher.Register(
            "pocketApps.prepareRestore",
            (_, cancellationToken) => PrepareWorkspaceRestoreAsync(
                approvalOwner,
                workspaceBackupRestoreSource,
                cancellationToken));
        dispatcher.Register(
            "pocketApps.presentRestoreApproval",
            (_, cancellationToken) => PresentWorkspaceRestoreApprovalAsync(
                approvalOwner,
                workspaceRestoreDecision,
                cancellationToken));
        dispatcher.Register("pocketApps.cancelRestore", CancelWorkspaceRestoreAsync);
        dispatcher.Register("pocketApps.refresh", (_, cancellationToken) =>
            Task.FromResult<object?>(Refresh(cancellationToken)));
    }

    public object BuildState(CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        lock (_stateSync)
        {
            return new
            {
                phase = PhaseWireValue(_phase),
                enabled = _enabled,
                generatorAvailable = _enabled && _generator is not null,
                errorCode = _errorCode,
                proposal = _pendingProposal is null ? null : ProposalState(_pendingProposal),
                receipt = _lastReceipt is null ? null : ReceiptState(_lastReceipt),
                managedApps = _managedPackages.Select(ManagedState).ToArray(),
                managementIssues = _managementIssues.Select(ManagementIssueState).ToArray(),
                appHealth = _appHealth.Select(HealthState).ToArray(),
                workspaceBackup = WorkspaceBackupState(),
                storageBoundary = "separate_definition_data_receipts",
                activation = "explicit_approval_only"
            };
        }
    }

    public void Dispose()
    {
        if (_disposed) { return; }
        _generationCancellation?.Cancel();
        _generationCancellation?.Dispose();
        _lifecycle.Dispose();
        foreach (var pin in _pins) { pin.Dispose(); }
        if (_generator is IDisposable disposable) { disposable.Dispose(); }
        _gate.Dispose();
        _disposed = true;
    }

    private async Task<object?> ExportWorkspaceAsync(
        Func<System.Windows.Window?>? ownerProvider,
        Func<string?>? exportTarget,
        CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            lock (_stateSync)
            {
                if (!_enabled) { return FailWorkspaceLocked("BACKUP_DISABLED"); }
                if (WorkspaceOperationBusyLocked()) { return FailWorkspaceLocked("BACKUP_BUSY"); }
            }
            cancellationToken.ThrowIfCancellationRequested();
            var destination = exportTarget is not null
                ? exportTarget()
                : PresentWorkspaceExportDialog(ownerProvider?.Invoke());
            if (destination is null) { return BuildState(); }
            ValidatePins();
            RefreshManagedPackages();
            var digest = _workspaceBackupManager.Export(destination);
            lock (_stateSync)
            {
                _lastWorkspaceBackupDigest = digest;
                _lastWorkspaceRestoreReceipt = null;
                _workspaceBackupErrorCode = null;
            }
            ValidatePins();
            return BuildState();
        }
        catch (PocketAppWorkspaceBackupException ex)
        {
            return FailWorkspace(ex.Code);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch
        {
            return FailWorkspace("BACKUP_EXPORT_FAILED");
        }
        finally
        {
            _gate.Release();
        }
    }

    private async Task<object?> PrepareWorkspaceRestoreAsync(
        Func<System.Windows.Window?>? ownerProvider,
        Func<string?>? restoreSource,
        CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            lock (_stateSync)
            {
                if (!_enabled) { return FailWorkspaceLocked("RESTORE_DISABLED"); }
                if (WorkspaceOperationBusyLocked()) { return FailWorkspaceLocked("RESTORE_BUSY"); }
            }
            cancellationToken.ThrowIfCancellationRequested();
            var source = restoreSource is not null
                ? restoreSource()
                : PresentWorkspaceRestoreDialog(ownerProvider?.Invoke());
            if (source is null) { return BuildState(); }
            ValidatePins();
            RefreshManagedPackages();
            var proposal = _workspaceBackupManager.PrepareRestore(source);
            lock (_stateSync)
            {
                _pendingWorkspaceRestore = proposal;
                _lastWorkspaceRestoreReceipt = null;
                _workspaceBackupErrorCode = null;
            }
            ValidatePins();
            return BuildState();
        }
        catch (PocketAppWorkspaceBackupException ex)
        {
            return FailWorkspace(ex.Code);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch
        {
            return FailWorkspace("RESTORE_PREVIEW_FAILED");
        }
        finally
        {
            _gate.Release();
        }
    }

    private async Task<object?> PresentWorkspaceRestoreApprovalAsync(
        Func<System.Windows.Window?>? ownerProvider,
        Func<PocketAppWorkspaceRestoreProposal, bool>? restoreDecision,
        CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken);
        var stateTransitions = new List<PocketAppStateTransitionLease>();
        PocketAppWorkspaceRestoreProposal? activeProposal = null;
        try
        {
            PocketAppWorkspaceRestoreProposal proposal;
            lock (_stateSync)
            {
                if (!_enabled) { return FailWorkspaceLocked("RESTORE_DISABLED"); }
                proposal = _pendingWorkspaceRestore
                    ?? throw new PocketAppWorkspaceBackupException("RESTORE_APPROVAL_INVALID");
                activeProposal = proposal;
            }
            cancellationToken.ThrowIfCancellationRequested();
            var approved = restoreDecision is not null
                ? restoreDecision(proposal)
                : PresentWorkspaceRestoreApproval(
                    ownerProvider?.Invoke(),
                    WorkspaceRestoreApprovalText(proposal));
            cancellationToken.ThrowIfCancellationRequested();
            if (!approved)
            {
                _workspaceBackupManager.Reject(proposal.RequestId, proposal.BindingDigest);
                lock (_stateSync)
                {
                    if (ReferenceEquals(_pendingWorkspaceRestore, proposal))
                    {
                        _pendingWorkspaceRestore = null;
                    }
                    _workspaceBackupErrorCode = null;
                }
                return BuildState();
            }
            lock (_stateSync)
            {
                if (!ReferenceEquals(_pendingWorkspaceRestore, proposal))
                {
                    return FailWorkspaceLocked("RESTORE_APPROVAL_INVALID");
                }
            }
            foreach (var appId in proposal.Changes.Select(change => change.AppId).Order(StringComparer.Ordinal))
            {
                var transition = await BeginDeactivateAsync(appId, cancellationToken);
                stateTransitions.Add(transition);
                if (!transition.Saved)
                {
                    return FailWorkspace("RESTORE_STATE_FLUSH_FAILED");
                }
            }
            ValidatePins();
            RefreshManagedPackages();
            var grant = _workspaceBackupManager.Approve(proposal.RequestId, proposal.BindingDigest);
            var receipt = _workspaceBackupManager.Restore(proposal, grant);
            if (!receipt.ReadbackVerified
                || receipt.RestoredApps.Count != proposal.Changes.Count
                || receipt.RestoredApps.Any(app => !app.RuntimeReadbackVerified))
            {
                throw new PocketAppWorkspaceBackupException("RESTORE_READBACK_MISMATCH");
            }
            lock (_stateSync)
            {
                _pendingWorkspaceRestore = null;
                _lastWorkspaceRestoreReceipt = receipt;
                _lastWorkspaceBackupDigest = receipt.BackupDigest;
                _workspaceBackupErrorCode = null;
            }
            _postCommitHook?.Invoke();
            RefreshManagedPackages();
            _postRefreshHook?.Invoke();
            ValidatePins();
            return BuildState();
        }
        catch (PocketAppWorkspaceBackupException ex)
        {
            DiscardWorkspaceRestore(activeProposal);
            lock (_stateSync) { _pendingWorkspaceRestore = null; }
            RefreshManagedPackagesAfterFailure();
            return FailWorkspace(ex.Code);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch
        {
            DiscardWorkspaceRestore(activeProposal);
            lock (_stateSync) { _pendingWorkspaceRestore = null; }
            RefreshManagedPackagesAfterFailure();
            return FailWorkspace("RESTORE_COMMIT_FAILED");
        }
        finally
        {
            foreach (var transition in stateTransitions)
            {
                await CompleteDeactivateAsync(transition);
            }
            _gate.Release();
        }
    }

    private async Task<object?> CancelWorkspaceRestoreAsync(
        JsonElement? parameters,
        CancellationToken cancellationToken)
    {
        _ = parameters;
        await _gate.WaitAsync(cancellationToken);
        try
        {
            PocketAppWorkspaceRestoreProposal? proposal;
            lock (_stateSync) { proposal = _pendingWorkspaceRestore; }
            if (proposal is not null)
            {
                _workspaceBackupManager.Reject(proposal.RequestId, proposal.BindingDigest);
            }
            lock (_stateSync)
            {
                _pendingWorkspaceRestore = null;
                _workspaceBackupErrorCode = null;
            }
            return BuildState();
        }
        catch (PocketAppWorkspaceBackupException ex)
        {
            return FailWorkspace(ex.Code);
        }
        finally
        {
            _gate.Release();
        }
    }

    private bool WorkspaceOperationBusyLocked() =>
        _phase is PocketAppGenerationPhase.Generating or PocketAppGenerationPhase.Installing
        || _pendingProposal is not null
        || _pendingWorkspaceRestore is not null;

    private void DiscardWorkspaceRestore(PocketAppWorkspaceRestoreProposal? proposal)
    {
        if (proposal is null) { return; }
        try { _workspaceBackupManager.Reject(proposal.RequestId, proposal.BindingDigest); } catch { }
    }

    private static string? PresentWorkspaceExportDialog(System.Windows.Window? owner)
    {
        var dialog = new Microsoft.Win32.SaveFileDialog
        {
            AddExtension = true,
            CheckPathExists = true,
            DefaultExt = ".json",
            FileName = "HoverPocket-PocketApps.hoverpocket-backup.json",
            Filter = "HoverPocket backup (*.hoverpocket-backup.json)|*.hoverpocket-backup.json|JSON (*.json)|*.json|All files (*.*)|*.*",
            OverwritePrompt = true,
            Title = "Pocket App workspaceを書き出す"
        };
        var result = owner is null ? dialog.ShowDialog() : dialog.ShowDialog(owner);
        return result == true ? dialog.FileName : null;
    }

    private static string? PresentWorkspaceRestoreDialog(System.Windows.Window? owner)
    {
        var dialog = new Microsoft.Win32.OpenFileDialog
        {
            CheckFileExists = true,
            CheckPathExists = true,
            Filter = "HoverPocket backup (*.hoverpocket-backup.json)|*.hoverpocket-backup.json|JSON (*.json)|*.json|All files (*.*)|*.*",
            Multiselect = false,
            Title = "Pocket App workspaceをbackupから復元"
        };
        var result = owner is null ? dialog.ShowDialog() : dialog.ShowDialog(owner);
        return result == true ? dialog.FileName : null;
    }

    private static bool PresentWorkspaceRestoreApproval(System.Windows.Window? owner, string text)
    {
        var result = owner is null
            ? System.Windows.MessageBox.Show(
                text,
                "Pocket App workspaceを復元",
                System.Windows.MessageBoxButton.YesNo,
                System.Windows.MessageBoxImage.Warning,
                System.Windows.MessageBoxResult.No)
            : System.Windows.MessageBox.Show(
                owner,
                text,
                "Pocket App workspaceを復元",
                System.Windows.MessageBoxButton.YesNo,
                System.Windows.MessageBoxImage.Warning,
                System.Windows.MessageBoxResult.No);
        return result == System.Windows.MessageBoxResult.Yes;
    }

    internal static string WorkspaceRestoreApprovalText(PocketAppWorkspaceRestoreProposal proposal)
    {
        var additions = proposal.Changes.Count(change => change.Action == "add");
        var replacements = proposal.Changes.Count(change => change.Action == "replace");
        var permissionChanges = proposal.Changes.Sum(change =>
            change.AddedPermissions.Count + change.RemovedPermissions.Count);
        var lifecycleChanges = proposal.Changes.Count(change =>
            change.FromLifecycleState != change.ToLifecycleState);
        var dataChanges = proposal.Changes.Count(change => change.DataChanged);
        return string.Join(
            Environment.NewLine,
            [
                "検証済みのPocket App workspace backupを復元します。",
                $"追加: {additions}件 / 置換: {replacements}件",
                $"状態変更: {lifecycleChanges}件 / 権限変更: {permissionChanges}件 / データ変更: {dataChanges}件",
                $"backup: {proposal.BackupDigest}",
                $"binding: {proposal.BindingDigest}",
                "失敗時は復元前snapshotへ戻します。内容が一致する場合だけ「はい」を選択してください。"
            ]);
    }

    private async Task<object?> GenerateAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        var userRequest = RequiredString(parameters, "request", PocketAppGenerationRequest.MaximumUserRequestScalars);
        var updatingAppId = OptionalString(parameters, "updatingAppId", 160);
        await _gate.WaitAsync(cancellationToken);
        try
        {
            if (_generator is null) { return Fail("GENERATOR_UNAVAILABLE"); }
            lock (_stateSync)
            {
                if (!_enabled) { return FailLocked("GENERATION_DISABLED"); }
                if (_phase is PocketAppGenerationPhase.Generating or PocketAppGenerationPhase.Installing
                    || _pendingProposal is not null
                    || _pendingWorkspaceRestore is not null)
                {
                    return FailLocked("GENERATION_BUSY");
                }
            }
            ValidatePins();
            RefreshManagedPackages();
            var request = MakeRequest(userRequest, updatingAppId);
            using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            lock (_stateSync)
            {
                _generationCancellation?.Dispose();
                _generationCancellation = linked;
                _phase = PocketAppGenerationPhase.Generating;
                _errorCode = null;
                _lastReceipt = null;
            }
            PocketAppGenerationEnvelope envelope;
            try
            {
                envelope = await _generator.GenerateAsync(request, linked.Token);
                lock (_stateSync)
                {
                    if (!_enabled) { throw Failure("GENERATION_DISABLED"); }
                }
            }
            finally
            {
                lock (_stateSync)
                {
                    if (ReferenceEquals(_generationCancellation, linked)) { _generationCancellation = null; }
                }
            }
            var materialized = _materializer.Materialize(envelope, request);
            try
            {
                var proposal = _lifecycle.Stage(materialized.Directory);
                if (proposal.PackageId != request.AppId
                    || proposal.Version != request.Version
                    || proposal.PackageDigest != materialized.Package.ManifestDigest
                    || !proposal.ApprovalRequired)
                {
                    try { _lifecycle.Reject(proposal.RequestId, proposal.BindingDigest); } catch { }
                    throw Failure("GENERATION_PACKAGE_INVALID");
                }
                ValidatePins();
                lock (_stateSync)
                {
                    if (!_enabled)
                    {
                        try { _lifecycle.Reject(proposal.RequestId, proposal.BindingDigest); } catch { }
                        throw Failure("GENERATION_DISABLED");
                    }
                    _pendingProposal = proposal;
                    _pendingAllowsActivation = _generator.AllowsActivation;
                    _phase = PocketAppGenerationPhase.AwaitingApproval;
                    _errorCode = null;
                }
            }
            finally
            {
                TryDeleteDraft(materialized.Directory);
            }
            return BuildState();
        }
        catch (PocketAppGenerationException ex)
        {
            return Fail(ex.Code);
        }
        catch (OperationCanceledException)
        {
            return Fail("GENERATOR_CANCELLED");
        }
        catch (Exception ex) when (ex is PocketAppLifecycleException
            or PocketAppPackageRuntimeException
            or PocketSurfaceRuntimeException
            or IOException
            or UnauthorizedAccessException)
        {
            return Fail("GENERATION_PACKAGE_INVALID");
        }
        finally
        {
            _gate.Release();
        }
    }

    private Task<object?> CancelGenerationAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        _ = parameters;
        cancellationToken.ThrowIfCancellationRequested();
        lock (_stateSync) { _generationCancellation?.Cancel(); }
        return Task.FromResult<object?>(BuildState());
    }

    private async Task<object?> PresentApprovalAsync(
        Func<System.Windows.Window?>? approvalOwner,
        Func<PocketAppLifecycleProposal, bool>? approvalDecision,
        CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken);
        PocketAppLifecycleProposal? activationProposal = null;
        PocketAppStateTransitionLease? stateTransition = null;
        try
        {
            PocketAppLifecycleProposal proposal;
            lock (_stateSync)
            {
                if (!_enabled) { return FailLocked("GENERATION_DISABLED"); }
                if (_pendingProposal is null)
                {
                    return FailLocked("GENERATION_APPROVAL_MISMATCH");
                }
                if (!_pendingAllowsActivation)
                {
                    return FailLocked("GENERATION_PREVIEW_ONLY");
                }
                proposal = _pendingProposal;
                activationProposal = proposal;
            }
            cancellationToken.ThrowIfCancellationRequested();
            var approvalText = ApprovalPresentationText(proposal);
            var owner = approvalOwner?.Invoke();
            var approved = approvalDecision is not null
                ? approvalDecision(proposal)
                : owner is null
                    ? System.Windows.MessageBox.Show(
                        approvalText,
                        "Pocket Appを承認",
                        System.Windows.MessageBoxButton.YesNo,
                        System.Windows.MessageBoxImage.Warning,
                        System.Windows.MessageBoxResult.No) == System.Windows.MessageBoxResult.Yes
                    : System.Windows.MessageBox.Show(
                        owner,
                        approvalText,
                        "Pocket Appを承認",
                        System.Windows.MessageBoxButton.YesNo,
                        System.Windows.MessageBoxImage.Warning,
                        System.Windows.MessageBoxResult.No) == System.Windows.MessageBoxResult.Yes;
            cancellationToken.ThrowIfCancellationRequested();
            if (!approved)
            {
                _lifecycle.Reject(proposal.RequestId, proposal.BindingDigest);
                lock (_stateSync)
                {
                    _pendingProposal = null;
                    _pendingAllowsActivation = false;
                    _phase = PocketAppGenerationPhase.Idle;
                    _errorCode = null;
                }
                return BuildState();
            }
            lock (_stateSync)
            {
                if (!ReferenceEquals(_pendingProposal, proposal))
                {
                    return FailLocked("GENERATION_APPROVAL_MISMATCH");
                }
            }
            stateTransition = await BeginDeactivateAsync(proposal.PackageId, cancellationToken);
            if (!stateTransition.Saved)
            {
                await CompleteDeactivateAsync(stateTransition);
                stateTransition = null;
                return Fail("GENERATION_STATE_FLUSH_FAILED");
            }
            lock (_stateSync)
            {
                _phase = PocketAppGenerationPhase.Installing;
                _errorCode = null;
            }
            ValidatePins();
            RefreshManagedPackages();
            var grant = _lifecycle.Approve(proposal.RequestId, proposal.BindingDigest);
            var receipt = proposal.Action == PocketAppLifecycleAction.Rollback
                ? _lifecycle.Rollback(proposal, grant)
                : _lifecycle.Install(proposal, grant);
            if (!receipt.ReadbackVerified
                || receipt.PackageId != proposal.PackageId
                || receipt.Version != proposal.Version
                || receipt.PackageDigest != proposal.PackageDigest)
            {
                throw Failure("GENERATION_PACKAGE_INVALID");
            }
            RecordCommittedReceipt(receipt, PocketAppGenerationPhase.Installed, clearPending: true);
            _postCommitHook?.Invoke();
            RefreshManagedPackagesAfterCommit(receipt);
            _postRefreshHook?.Invoke();
            await CompleteDeactivateAsync(stateTransition);
            stateTransition = null;
            return BuildState();
        }
        catch (PocketAppGenerationException ex)
        {
            await CompleteDeactivateAsync(stateTransition);
            DiscardFailedActivation(activationProposal);
            RefreshManagedPackagesAfterFailure();
            return Fail(ex.Code);
        }
        catch (PocketAppLifecycleException)
        {
            await CompleteDeactivateAsync(stateTransition);
            DiscardFailedActivation(activationProposal);
            RefreshManagedPackagesAfterFailure();
            return Fail("GENERATION_APPROVAL_MISMATCH");
        }
        catch
        {
            await CompleteDeactivateAsync(stateTransition);
            throw;
        }
        finally
        {
            _gate.Release();
        }
    }

    private async Task<object?> RejectAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        var requestId = RequiredString(parameters, "requestId", 128);
        var bindingDigest = RequiredString(parameters, "bindingDigest", 71);
        await _gate.WaitAsync(cancellationToken);
        try
        {
            PocketAppLifecycleProposal proposal;
            lock (_stateSync)
            {
                if (!_enabled) { return FailLocked("GENERATION_DISABLED"); }
                if (_pendingProposal is null
                    || _pendingProposal.RequestId != requestId
                    || _pendingProposal.BindingDigest != bindingDigest)
                {
                    return FailLocked("GENERATION_APPROVAL_MISMATCH");
                }
                proposal = _pendingProposal;
            }
            _lifecycle.Reject(proposal.RequestId, proposal.BindingDigest);
            lock (_stateSync)
            {
                _pendingProposal = null;
                _pendingAllowsActivation = false;
                _phase = PocketAppGenerationPhase.Idle;
                _errorCode = null;
            }
            return BuildState();
        }
        catch (PocketAppLifecycleException)
        {
            return Fail("GENERATION_APPROVAL_MISMATCH");
        }
        finally
        {
            _gate.Release();
        }
    }

    private async Task<object?> DisableAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        var packageId = RequiredString(parameters, "appId", 160);
        await _gate.WaitAsync(cancellationToken);
        PocketAppStateTransitionLease? stateTransition = null;
        try
        {
            lock (_stateSync)
            {
                if (!_enabled) { return FailLocked("GENERATION_DISABLED"); }
                if (_pendingWorkspaceRestore is not null) { return FailLocked("GENERATION_BUSY"); }
            }
            ValidatePins();
            RefreshManagedPackages();
            lock (_stateSync)
            {
                if (_managementIssues.Any(item => item.PackageId == packageId))
                {
                    throw Failure("GENERATION_PACKAGE_INVALID");
                }
            }
            stateTransition = await BeginDeactivateAsync(packageId, cancellationToken);
            if (!stateTransition.Saved)
            {
                await CompleteDeactivateAsync(stateTransition);
                stateTransition = null;
                return Fail("GENERATION_STATE_FLUSH_FAILED");
            }
            var receipt = _lifecycle.Disable(packageId);
            if (!receipt.ReadbackVerified || receipt.State != PocketAppLifecycleState.Disabled)
            {
                throw Failure("GENERATION_PACKAGE_INVALID");
            }
            RecordCommittedReceipt(receipt, PocketAppGenerationPhase.Disabled, clearPending: false);
            _postCommitHook?.Invoke();
            RefreshManagedPackagesAfterCommit(receipt);
            _postRefreshHook?.Invoke();
            await CompleteDeactivateAsync(stateTransition);
            stateTransition = null;
            return BuildState();
        }
        catch (Exception ex) when (ex is PocketAppGenerationException or PocketAppLifecycleException)
        {
            await CompleteDeactivateAsync(stateTransition);
            RefreshManagedPackagesAfterFailure();
            return Fail("GENERATION_PACKAGE_INVALID");
        }
        catch
        {
            await CompleteDeactivateAsync(stateTransition);
            throw;
        }
        finally
        {
            _gate.Release();
        }
    }

    private async Task<object?> EnableAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        var packageId = RequiredString(parameters, "appId", 160);
        await _gate.WaitAsync(cancellationToken);
        try
        {
            lock (_stateSync)
            {
                if (!_enabled) { return FailLocked("GENERATION_DISABLED"); }
                if (_pendingWorkspaceRestore is not null) { return FailLocked("GENERATION_BUSY"); }
            }
            ValidatePins();
            RefreshManagedPackages();
            lock (_stateSync)
            {
                if (_managementIssues.Any(item => item.PackageId == packageId))
                {
                    throw Failure("GENERATION_PACKAGE_INVALID");
                }
            }
            var receipt = _lifecycle.Enable(packageId);
            if (!receipt.ReadbackVerified || receipt.State != PocketAppLifecycleState.Enabled)
            {
                throw Failure("GENERATION_PACKAGE_INVALID");
            }
            RecordCommittedReceipt(receipt, PocketAppGenerationPhase.Installed, clearPending: false);
            _postCommitHook?.Invoke();
            RefreshManagedPackagesAfterCommit(receipt);
            _postRefreshHook?.Invoke();
            return BuildState();
        }
        catch (Exception ex) when (ex is PocketAppGenerationException or PocketAppLifecycleException)
        {
            RefreshManagedPackagesAfterFailure();
            return Fail("GENERATION_PACKAGE_INVALID");
        }
        finally
        {
            _gate.Release();
        }
    }

    private async Task<object?> RemovePreservingDataAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        var packageId = RequiredString(parameters, "appId", 160);
        await _gate.WaitAsync(cancellationToken);
        PocketAppStateTransitionLease? stateTransition = null;
        try
        {
            lock (_stateSync)
            {
                if (!_enabled) { return FailLocked("GENERATION_DISABLED"); }
                if (_pendingWorkspaceRestore is not null) { return FailLocked("GENERATION_BUSY"); }
            }
            ValidatePins();
            RefreshManagedPackages();
            stateTransition = await BeginDeactivateAsync(packageId, cancellationToken);
            if (!stateTransition.Saved)
            {
                await CompleteDeactivateAsync(stateTransition);
                stateTransition = null;
                return Fail("GENERATION_STATE_FLUSH_FAILED");
            }
            RejectPendingProposalIfNeeded(packageId);
            var receipt = _lifecycle.Remove(packageId, PocketAppDataDisposition.Preserve);
            if (!receipt.ReadbackVerified
                || receipt.State != PocketAppLifecycleState.Removed
                || receipt.DataDisposition != PocketAppDataDisposition.Preserve)
            {
                throw Failure("GENERATION_PACKAGE_INVALID");
            }
            RecordCommittedReceipt(receipt, PocketAppGenerationPhase.Removed, clearPending: false);
            _postCommitHook?.Invoke();
            RefreshManagedPackagesAfterCommit(receipt);
            _postRefreshHook?.Invoke();
            await CompleteDeactivateAsync(stateTransition);
            stateTransition = null;
            return BuildState();
        }
        catch (Exception ex) when (ex is PocketAppGenerationException or PocketAppLifecycleException)
        {
            await CompleteDeactivateAsync(stateTransition);
            RefreshManagedPackagesAfterFailure();
            return Fail("GENERATION_PACKAGE_INVALID");
        }
        catch
        {
            await CompleteDeactivateAsync(stateTransition);
            throw;
        }
        finally
        {
            _gate.Release();
        }
    }

    private async Task<object?> PrepareRollbackAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        var packageId = RequiredString(parameters, "appId", 160);
        var version = RequiredString(parameters, "version", 64);
        await _gate.WaitAsync(cancellationToken);
        try
        {
            lock (_stateSync) { if (!_enabled) { return FailLocked("GENERATION_DISABLED"); } }
            lock (_stateSync)
            {
                if (_pendingProposal is not null || _pendingWorkspaceRestore is not null)
                {
                    return FailLocked("GENERATION_BUSY");
                }
            }
            ValidatePins();
            var proposal = _lifecycle.PrepareRollback(packageId, version);
            if (!proposal.ApprovalRequired) { throw Failure("GENERATION_PACKAGE_INVALID"); }
            lock (_stateSync)
            {
                _pendingProposal = proposal;
                _pendingAllowsActivation = true;
                _lastReceipt = null;
                _phase = PocketAppGenerationPhase.AwaitingApproval;
                _errorCode = null;
            }
            ValidatePins();
            return BuildState();
        }
        catch (Exception ex) when (ex is PocketAppGenerationException or PocketAppLifecycleException)
        {
            return Fail("GENERATION_PACKAGE_INVALID");
        }
        finally
        {
            _gate.Release();
        }
    }

    private async Task<object?> PrepareCapabilityMigrationAsync(
        JsonElement? parameters,
        CancellationToken cancellationToken)
    {
        var packageId = RequiredString(parameters, "appId", 160);
        var targetVersion = RequiredString(parameters, "targetVersion", 64);
        await _gate.WaitAsync(cancellationToken);
        try
        {
            lock (_stateSync) { if (!_enabled) { return FailLocked("GENERATION_DISABLED"); } }
            lock (_stateSync)
            {
                if (_pendingProposal is not null || _pendingWorkspaceRestore is not null)
                {
                    return FailLocked("GENERATION_BUSY");
                }
            }
            ValidatePins();
            var proposal = _lifecycle.PrepareCapabilityMigration(packageId, targetVersion);
            if (!proposal.ApprovalRequired) { throw Failure("GENERATION_PACKAGE_INVALID"); }
            lock (_stateSync)
            {
                _pendingProposal = proposal;
                _pendingAllowsActivation = true;
                _lastReceipt = null;
                _phase = PocketAppGenerationPhase.AwaitingApproval;
                _errorCode = null;
            }
            ValidatePins();
            return BuildState();
        }
        catch (Exception ex) when (ex is PocketAppGenerationException or PocketAppLifecycleException)
        {
            return Fail("GENERATION_PACKAGE_INVALID");
        }
        finally
        {
            _gate.Release();
        }
    }

    private object Refresh(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        try
        {
            RefreshManagedPackages();
            return BuildState();
        }
        catch (PocketAppLifecycleException)
        {
            return Fail("GENERATION_PACKAGE_INVALID");
        }
    }

    private PocketAppGenerationRequest MakeRequest(string userRequest, string? updatingAppId)
    {
        var trimmed = userRequest.Trim();
        if (trimmed.Length == 0
            || trimmed.EnumerateRunes().Count() > PocketAppGenerationRequest.MaximumUserRequestScalars
            || trimmed.Contains('\0'))
        {
            throw Failure("GENERATION_REQUEST_INVALID");
        }
        string appId;
        string version;
        var managed = _managedPackages;
        if (!string.IsNullOrEmpty(updatingAppId))
        {
            var existing = managed.FirstOrDefault(item => item.PackageId == updatingAppId && item.Version is not null)
                ?? throw Failure("GENERATION_REQUEST_INVALID");
            appId = existing.PackageId;
            version = NextVersion(existing.InstalledVersions, existing.Version!);
        }
        else
        {
            do { appId = FreshAppId(); }
            while (managed.Any(item => item.PackageId == appId)
                || _managementIssues.Any(item => item.PackageId == appId));
            version = "1.0.0";
        }
        const string @namespace = "today-focus";
        var request = new PocketAppGenerationRequest(
            $"generation:{Guid.NewGuid():N}",
            trimmed,
            appId,
            version,
            @namespace,
            PocketAppGenerationCapability.BoundedCatalog(@namespace));
        request.Validate();
        return request;
    }

    internal static string FreshAppId() =>
        $"local.generated.a{Guid.NewGuid():N}";

    private void DiscardFailedActivation(PocketAppLifecycleProposal? proposal)
    {
        if (proposal is null) { return; }
        try { _lifecycle.Reject(proposal.RequestId, proposal.BindingDigest); } catch { }
        lock (_stateSync)
        {
            if (_pendingProposal?.RequestId == proposal.RequestId)
            {
                _pendingProposal = null;
                _pendingAllowsActivation = false;
            }
        }
    }

    private void RejectPendingProposalIfNeeded(string packageId)
    {
        PocketAppLifecycleProposal? proposal;
        lock (_stateSync) { proposal = _pendingProposal; }
        if (proposal is null || !ShouldRejectPendingProposal(packageId, proposal.PackageId)) { return; }
        _lifecycle.Reject(proposal.RequestId, proposal.BindingDigest);
        lock (_stateSync)
        {
            if (ReferenceEquals(_pendingProposal, proposal))
            {
                _pendingProposal = null;
                _pendingAllowsActivation = false;
            }
        }
    }

    internal static bool ShouldRejectPendingProposal(string removingPackageId, string pendingPackageId) =>
        string.Equals(removingPackageId, pendingPackageId, StringComparison.Ordinal);

    private void RefreshManagedPackages()
    {
        ValidatePins();
        var snapshot = _lifecycle.ManagementSnapshot();
        var observed = snapshot.Packages
            .Where(item => item.State != PocketAppLifecycleState.Removed)
            .ToArray();
        var health = _lifecycle.HealthSnapshots();
        lock (_stateSync)
        {
            _managedPackages = observed;
            _managementIssues = snapshot.Issues;
            _appHealth = health;
        }
        ValidatePins();
    }

    internal void RefreshHealth()
    {
        try
        {
            var observed = _lifecycle.HealthSnapshots();
            lock (_stateSync) { _appHealth = observed; }
        }
        catch
        {
        }
    }

    internal void RecoverAfterSystemTransition()
    {
        try { RefreshManagedPackages(); } catch { RefreshHealth(); }
    }

    private void RecordCommittedReceipt(
        PocketAppLifecycleReceipt receipt,
        PocketAppGenerationPhase committedPhase,
        bool clearPending)
    {
        lock (_stateSync)
        {
            if (clearPending)
            {
                _pendingProposal = null;
                _pendingAllowsActivation = false;
            }
            _lastReceipt = receipt;
            _phase = !clearPending && _pendingProposal is not null
                ? PocketAppGenerationPhase.AwaitingApproval
                : committedPhase;
            _errorCode = null;
            var packages = _managedPackages
                .Where(item => item.PackageId != receipt.PackageId)
                .ToList();
            if (receipt.State != PocketAppLifecycleState.Removed
                && receipt.Version is not null
                && receipt.PackageDigest is not null)
            {
                var existing = _managedPackages.FirstOrDefault(item => item.PackageId == receipt.PackageId);
                var versions = (existing?.InstalledVersions ?? Array.Empty<string>())
                    .Append(receipt.Version)
                    .Distinct(StringComparer.Ordinal)
                    .Order(Comparer<string>.Create(PocketAppLifecycleManager.CompareSemanticVersions))
                    .ToArray();
                packages.Add(new PocketAppManagedPackage(
                    receipt.PackageId,
                    receipt.State,
                    receipt.Version,
                    receipt.PackageDigest,
                    versions));
            }
            _managedPackages = packages.OrderBy(item => item.PackageId, StringComparer.Ordinal).ToArray();
            _managementIssues = _managementIssues
                .Where(item => item.PackageId != receipt.PackageId)
                .ToArray();
        }
    }

    private void RefreshManagedPackagesAfterCommit(PocketAppLifecycleReceipt receipt)
    {
        ValidatePins();
        var target = _lifecycle.ManagedPackage(receipt.PackageId);
        if (target is null
            || target.State != receipt.State
            || target.Version != receipt.Version
            || target.PackageDigest != receipt.PackageDigest)
        {
            throw Failure("GENERATION_PACKAGE_INVALID");
        }
        var snapshot = _lifecycle.ManagementSnapshot();
        var observed = snapshot.Packages
            .Where(item => item.State != PocketAppLifecycleState.Removed)
            .ToArray();
        lock (_stateSync)
        {
            _managedPackages = observed;
            _managementIssues = snapshot.Issues;
        }
        ValidatePins();
    }

    private void RefreshManagedPackagesAfterFailure()
    {
        try
        {
            RefreshManagedPackages();
        }
        catch (Exception ex) when (ex is PocketAppGenerationException
            or PocketAppLifecycleException
            or IOException
            or UnauthorizedAccessException)
        {
        }
        try
        {
            _postRefreshHook?.Invoke();
        }
        catch
        {
        }
    }

    private async Task<PocketAppStateTransitionLease> BeginDeactivateAsync(
        string packageId,
        CancellationToken cancellationToken)
    {
        var begin = _beforeDeactivate;
        if (begin is null) { return PocketAppStateTransitionLease.Noop(packageId); }
        try
        {
            return await begin(packageId, cancellationToken);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch
        {
            return PocketAppStateTransitionLease.Failed(packageId);
        }
    }

    private async Task CompleteDeactivateAsync(PocketAppStateTransitionLease? lease)
    {
        var complete = _completeDeactivate;
        if (lease is null || complete is null) { return; }
        try { await complete(lease); } catch { }
    }

    private void ValidatePins()
    {
        try
        {
            foreach (var pin in _pins) { pin.Validate(); }
        }
        catch (PocketAppGenerationException)
        {
            throw;
        }
        catch
        {
            throw Failure("GENERATION_ROOT_UNSAFE");
        }
    }

    private object Fail(string code)
    {
        lock (_stateSync) { return FailLocked(code); }
    }

    private object FailWorkspace(string code)
    {
        lock (_stateSync) { return FailWorkspaceLocked(code); }
    }

    private object FailWorkspaceLocked(string code)
    {
        _workspaceBackupErrorCode = code;
        return new
        {
            phase = PhaseWireValue(_phase),
            enabled = _enabled,
            generatorAvailable = _enabled && _generator is not null,
            errorCode = _errorCode,
            proposal = _pendingProposal is null ? null : ProposalState(_pendingProposal),
            receipt = _lastReceipt is null ? null : ReceiptState(_lastReceipt),
            managedApps = _managedPackages.Select(ManagedState).ToArray(),
            managementIssues = _managementIssues.Select(ManagementIssueState).ToArray(),
            appHealth = _appHealth.Select(HealthState).ToArray(),
            workspaceBackup = WorkspaceBackupState(),
            storageBoundary = "separate_definition_data_receipts",
            activation = "explicit_approval_only"
        };
    }

    private object FailLocked(string code)
    {
        _errorCode = code;
        _phase = PocketAppGenerationPhase.Failed;
        return new
        {
            phase = PhaseWireValue(_phase),
            enabled = _enabled,
            generatorAvailable = _enabled && _generator is not null,
            errorCode = _errorCode,
            proposal = _pendingProposal is null ? null : ProposalState(_pendingProposal),
            receipt = _lastReceipt is null ? null : ReceiptState(_lastReceipt),
            managedApps = _managedPackages.Select(ManagedState).ToArray(),
            managementIssues = _managementIssues.Select(ManagementIssueState).ToArray(),
            appHealth = _appHealth.Select(HealthState).ToArray(),
            workspaceBackup = WorkspaceBackupState(),
            storageBoundary = "separate_definition_data_receipts",
            activation = "explicit_approval_only"
        };
    }

    private object ProposalState(PocketAppLifecycleProposal proposal)
    {
        return new
        {
            requestId = proposal.RequestId,
            action = proposal.Action.ToString().ToLowerInvariant(),
            appId = proposal.PackageId,
            version = proposal.Version,
            packageDigest = proposal.PackageDigest,
            currentDigest = proposal.CurrentDigest,
            previewDigest = proposal.PreviewDigest,
            bindingDigest = proposal.BindingDigest,
            permissionDiff = new { added = proposal.PermissionDiff.Added, removed = proposal.PermissionDiff.Removed },
            capabilityGrantDiff = new { added = proposal.CapabilityGrantDiff.Added, removed = proposal.CapabilityGrantDiff.Removed },
            tests = proposal.Tests.Select(item => new { id = item.Id, expected = item.Expected, status = item.Status }).ToArray(),
            previews = proposal.Previews.Select(item => new
            {
                id = item.Id,
                renderDigest = item.RenderDigest,
                renderModel = ParseRenderModel(item.CanonicalRenderModelBytes())
            }).ToArray(),
            expiresAt = proposal.ExpiresAt,
            activationAllowed = _pendingAllowsActivation
        };
    }

    private static object ManagedState(PocketAppManagedPackage package) => new
    {
        appId = package.PackageId,
        state = package.State.ToString().ToLowerInvariant(),
        version = package.Version,
        packageDigest = package.PackageDigest,
        installedVersions = package.InstalledVersions,
        rollbackVersions = RollbackVersions(package.InstalledVersions, package.Version)
    };

    private static object ManagementIssueState(PocketAppManagementIssue issue) => new
    {
        appId = issue.PackageId,
        errorCode = issue.ErrorCode,
        removalAllowed = issue.RemovalAllowed,
        migrationAvailable = issue.MigrationAvailable,
        suggestedVersion = issue.SuggestedVersion
    };

    private static object HealthState(PocketAppHealthSnapshot health) => new
    {
        appId = health.PackageId,
        status = health.Status.ToString().ToLowerInvariant(),
        reasonCode = health.ReasonCode,
        lastUsedAt = health.LastUsedAt,
        lastSuccessfulActivationAt = health.LastSuccessfulActivationAt,
        consecutiveActivationFailures = health.ConsecutiveActivationFailures,
        disableSuggested = health.DisableSuggested
    };

    private static object ReceiptState(PocketAppLifecycleReceipt receipt) => new
    {
        action = receipt.Action,
        appId = receipt.PackageId,
        version = receipt.Version,
        packageDigest = receipt.PackageDigest,
        effectivePermissions = receipt.EffectivePermissions,
        state = receipt.State.ToString().ToLowerInvariant(),
        readbackVerified = receipt.ReadbackVerified,
        dataDisposition = receipt.DataDisposition?.ToString().ToLowerInvariant()
    };

    private object WorkspaceBackupState() => new
    {
        pending = _pendingWorkspaceRestore is null ? null : new
        {
            requestId = _pendingWorkspaceRestore.RequestId,
            backupDigest = _pendingWorkspaceRestore.BackupDigest,
            bindingDigest = _pendingWorkspaceRestore.BindingDigest,
            expiresAt = _pendingWorkspaceRestore.ExpiresAt,
            changes = _pendingWorkspaceRestore.Changes.Select(change => new
            {
                appId = change.AppId,
                action = change.Action,
                fromVersion = change.FromVersion,
                toVersion = change.ToVersion,
                fromLifecycleState = change.FromLifecycleState,
                toLifecycleState = change.ToLifecycleState,
                addedPermissions = change.AddedPermissions,
                removedPermissions = change.RemovedPermissions,
                dataChanged = change.DataChanged
            }).ToArray()
        },
        lastBackupDigest = _lastWorkspaceBackupDigest,
        receipt = _lastWorkspaceRestoreReceipt is null ? null : new
        {
            backupDigest = _lastWorkspaceRestoreReceipt.BackupDigest,
            readbackVerified = _lastWorkspaceRestoreReceipt.ReadbackVerified,
            rollbackPerformed = _lastWorkspaceRestoreReceipt.RollbackPerformed,
            restoredApps = _lastWorkspaceRestoreReceipt.RestoredApps.Select(app => new
            {
                appId = app.AppId,
                version = app.Version,
                packageDigest = app.PackageDigest,
                lifecycleState = app.LifecycleState.ToString().ToLowerInvariant(),
                effectivePermissions = app.EffectivePermissions,
                runtimeReadbackVerified = app.RuntimeReadbackVerified,
                dataVersion = app.DataVersion,
                dataDigest = app.DataDigest
            }).ToArray()
        },
        errorCode = _workspaceBackupErrorCode,
        exclusions = new[] { "oauth", "credentials", "audit_logs", "codex_workspace" }
    };

    internal static string ApprovalPresentationText(PocketAppLifecycleProposal proposal)
    {
        static string Safe(string value)
        {
            var builder = new StringBuilder(value.Length);
            var pendingSpace = false;
            foreach (var rune in value.EnumerateRunes())
            {
                var scalar = rune.Value;
                var bidi = scalar is 0x061C or 0x200E or 0x200F
                    or 0x202A or 0x202B or 0x202C or 0x202D or 0x202E
                    or 0x2066 or 0x2067 or 0x2068 or 0x2069;
                if (bidi || Rune.IsControl(rune) || Rune.IsWhiteSpace(rune))
                {
                    pendingSpace = builder.Length > 0;
                    continue;
                }
                if (pendingSpace)
                {
                    builder.Append(' ');
                    pendingSpace = false;
                }
                builder.Append(rune.ToString());
            }
            return builder.ToString().Trim();
        }

        return string.Join(
            Environment.NewLine,
            [
                "次のHost検証済みPocket App bytesを導入します。",
                $"action: {Safe(proposal.Action.ToString().ToLowerInvariant())}",
                $"app: {Safe(proposal.PackageId)}",
                $"version: {Safe(proposal.Version)}",
                "source: host-verified-package",
                $"package: {Safe(proposal.PackageDigest)}",
                $"preview: {Safe(proposal.PreviewDigest)}",
                $"request: {Safe(proposal.RequestId)}",
                $"binding: {Safe(proposal.BindingDigest)}",
                $"permissions +[{Safe(string.Join(", ", proposal.PermissionDiff.Added))}] -[{Safe(string.Join(", ", proposal.PermissionDiff.Removed))}]",
                $"capability grants +[{Safe(string.Join(", ", proposal.CapabilityGrantDiff.Added))}] -[{Safe(string.Join(", ", proposal.CapabilityGrantDiff.Removed))}]",
                "表示内容と実行対象が一致する場合だけ「はい」を選択してください。"
            ]);
    }

    private static JsonElement ParseRenderModel(byte[] bytes)
    {
        using var document = JsonDocument.Parse(bytes);
        return document.RootElement.Clone();
    }

    private static string PhaseWireValue(PocketAppGenerationPhase phase) => phase switch
    {
        PocketAppGenerationPhase.AwaitingApproval => "awaiting_approval",
        _ => phase.ToString().ToLowerInvariant()
    };

    internal static string NextVersion(IReadOnlyList<string> installedVersions, string currentVersion)
    {
        var highest = installedVersions
            .Append(currentVersion)
            .Order(Comparer<string>.Create(PocketAppLifecycleManager.CompareSemanticVersions))
            .Last();
        return NextPatchVersion(highest);
    }

    internal static IReadOnlyList<string> RollbackVersions(
        IReadOnlyList<string> installedVersions,
        string? currentVersion)
    {
        if (currentVersion is null) { return Array.Empty<string>(); }
        return installedVersions
            .Where(version => PocketAppLifecycleManager.CompareSemanticVersions(version, currentVersion) < 0)
            .Order(Comparer<string>.Create(PocketAppLifecycleManager.CompareSemanticVersions))
            .ToArray();
    }

    internal static string NextPatchVersion(string value)
    {
        var core = value.Split('-', 2, StringSplitOptions.None)[0].Split('.');
        if (value.Length > 64
            || core.Length != 3
            || !System.Text.RegularExpressions.Regex.IsMatch(
                value,
                "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z.-]+)?$",
                System.Text.RegularExpressions.RegexOptions.CultureInvariant))
        {
            throw Failure("GENERATION_REQUEST_INVALID");
        }
        var digits = core[2].ToCharArray();
        var carry = true;
        for (var index = digits.Length - 1; index >= 0 && carry; index--)
        {
            if (digits[index] == '9')
            {
                digits[index] = '0';
            }
            else
            {
                digits[index]++;
                carry = false;
            }
        }
        var patch = new string(digits);
        if (carry) { patch = "1" + patch; }
        var result = $"{core[0]}.{core[1]}.{patch}";
        if (result.Length > 64) { throw Failure("GENERATION_REQUEST_INVALID"); }
        return result;
    }

    private static string RequiredString(JsonElement? parameters, string name, int maximumScalars)
    {
        if (parameters is null
            || !parameters.Value.TryGetProperty(name, out var value)
            || value.ValueKind != JsonValueKind.String)
        {
            throw Failure("GENERATION_REQUEST_INVALID");
        }
        var text = value.GetString() ?? string.Empty;
        if (text.EnumerateRunes().Count() > maximumScalars || text.Contains('\0'))
        {
            throw Failure("GENERATION_REQUEST_INVALID");
        }
        return text;
    }

    private static string? OptionalString(JsonElement? parameters, string name, int maximumScalars)
    {
        if (parameters is null || !parameters.Value.TryGetProperty(name, out var value) || value.ValueKind == JsonValueKind.Null)
        {
            return null;
        }
        if (value.ValueKind != JsonValueKind.String) { throw Failure("GENERATION_REQUEST_INVALID"); }
        var text = value.GetString() ?? string.Empty;
        if (text.EnumerateRunes().Count() > maximumScalars || text.Contains('\0'))
        {
            throw Failure("GENERATION_REQUEST_INVALID");
        }
        return text.Length == 0 ? null : text;
    }

    private static void TryDeleteDraft(string directory)
    {
        try { if (Directory.Exists(directory)) { Directory.Delete(directory, true); } } catch { }
    }

    private static PocketAppGenerationException Failure(string code) => new(code);
}
