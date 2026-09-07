using System.Text;
using System.Text.Json;
using HoverPocket.Shell.Bridge;

namespace HoverPocket.Shell.PocketApps;

internal sealed class PocketAppGenerationController : IDisposable
{
    private readonly IPocketAppGenerationAdapter? _generator;
    private readonly PocketAppLifecycleManager _lifecycle;
    private readonly PocketAppGenerationMaterializer _materializer;
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
    private IReadOnlyList<PocketAppManagedPackage> _managedPackages = Array.Empty<PocketAppManagedPackage>();
    private IReadOnlyList<PocketAppManagementIssue> _managementIssues = Array.Empty<PocketAppManagementIssue>();
    private string? _errorCode;
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
        ValidatePins();
        RefreshManagedPackages();
    }

    public void SetEnabled(bool enabled)
    {
        PocketAppLifecycleProposal? pending = null;
        lock (_stateSync)
        {
            _enabled = enabled;
            if (!enabled)
            {
                _generationCancellation?.Cancel();
                pending = _pendingProposal;
                _pendingProposal = null;
                _pendingAllowsActivation = false;
                _phase = PocketAppGenerationPhase.Idle;
                _errorCode = null;
            }
        }
        if (!enabled && pending is not null)
        {
            try { _lifecycle.Reject(pending.RequestId, pending.BindingDigest); } catch { }
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
        Func<PocketAppLifecycleProposal, bool>? approvalDecision = null)
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
                    || _pendingProposal is not null)
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
            lock (_stateSync) { if (!_enabled) { return FailLocked("GENERATION_DISABLED"); } }
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
            lock (_stateSync) { if (!_enabled) { return FailLocked("GENERATION_DISABLED"); } }
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
            lock (_stateSync) { if (!_enabled) { return FailLocked("GENERATION_DISABLED"); } }
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
                if (_pendingProposal is not null) { return FailLocked("GENERATION_BUSY"); }
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
        lock (_stateSync)
        {
            _managedPackages = observed;
            _managementIssues = snapshot.Issues;
        }
        ValidatePins();
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
        removalAllowed = issue.RemovalAllowed
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
