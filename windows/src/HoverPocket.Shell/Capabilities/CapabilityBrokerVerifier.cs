using System.Globalization;
using System.Text;
using System.Text.Json;
using HoverPocket.Shell.Bridge;
using HoverPocket.Shell.Configuration;
using HoverPocket.Shell.PocketApps;
using HoverPocket.Shell.Providers.Calendar;
using HoverPocket.Shell.Providers.Sticky;
using HoverPocket.Shell.Providers.Timer;
using HoverPocket.Shell.Verification;

namespace HoverPocket.Shell.Capabilities;

internal sealed class CapabilityBrokerVerifier
{
    private const string GoldenPlanDigest = "sha256:d098ea1b5f9f70e91486fd53229e7ddb68f73a9952ab94f17eed27cdeeb6413f";
    private static readonly string PrivatePresentationTitle = "  Private\n\u202e title " + new string('x', 90);
    private readonly List<string> _failures = [];

    public int Run()
    {
        try
        {
            Task.Run(VerifyAsync).GetAwaiter().GetResult();
        }
        catch (Exception ex)
        {
            _failures.Add($"unexpected:{ex.GetType().Name}:{ex.Message}");
        }

        if (_failures.Count > 0)
        {
            VerifyConsole.WriteLine("broker_verify=failed");
            foreach (var failure in _failures)
            {
                VerifyConsole.WriteLine($"failure={failure}");
            }
            return 1;
        }

        VerifyConsole.WriteLine("broker_verify=ok");
        VerifyConsole.WriteLine("broker_registry_descriptors=21");
        VerifyConsole.WriteLine("broker_available_handlers=20");
        VerifyConsole.WriteLine("broker_calculator_evaluate=ok");
        VerifyConsole.WriteLine("broker_controls_os_readback=ok");
        VerifyConsole.WriteLine("broker_sticky_lifecycle=ok");
        VerifyConsole.WriteLine("broker_approval_presentation=ok");
        VerifyConsole.WriteLine("broker_today_focus=ok");
        VerifyConsole.WriteLine("broker_pocket_app=ok");
        VerifyConsole.WriteLine("broker_pocket_app_declared_tests=4");
        VerifyConsole.WriteLine("broker_concurrent_duplicate=ok");
        VerifyConsole.WriteLine("broker_retention_governance=ok");
        VerifyConsole.WriteLine("broker_negative_cases=12");
        VerifyConsole.WriteLine($"broker_golden_plan_digest={GoldenPlanDigest}");
        return 0;
    }

    private async Task VerifyAsync()
    {
        var root = Path.Combine(Path.GetTempPath(), "HoverPocketBrokerVerify", Guid.NewGuid().ToString("N"));
        try
        {
            var now = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);
            var clock = new ManualTimerClock(now);
            using var timerStore = new TimerStore(
                Path.Combine(root, "timer"),
                clock,
                new NullTimerAlertSound(),
                enableScheduler: false);
            var stickyStore = new StickyNotesStore(Path.Combine(root, "sticky"));
            var calendar = new BrokerFakeCalendarDataSource(now);
            var handlers = ProviderCapabilityCompositionRoot.Create(
                calendar,
                timerStore,
                stickyStore,
                new FakeControlsCapabilityDataSource());
            var registry = new CapabilityRegistry(handlers);
            var brokerRoot = Path.Combine(root, "broker");
            var audit = new CapabilityBrokerAuditLog(brokerRoot);
            var broker = new CapabilityBroker(
                registry,
                new CapabilityBrokerLedger(brokerRoot),
                audit,
                approvalPresentationResolver: new HostCapabilityApprovalPresentationResolver(stickyStore));

            Require(registry.DescriptorKeys.Count == 21, "registry_descriptor_count");
            Require(registry.AvailableHandlerKeys.Count == 20, "registry_handler_count");
            Require(
                PocketCapabilityDescriptors.BuiltIn.Single(item => item.Key == CapabilityIds.StickyDelete).ApprovalPolicy
                    == CapabilityApprovalPolicy.StrongPerCall,
                "sticky_delete_strong_approval");
            VerifyStrongPerCallIsolation(broker, now);
            VerifyStrongApprovalPresentationRequired(registry, root, now);
            try
            {
                PocketCapabilityDescriptors.BuiltIn.Single(item => item.Key == CapabilityIds.StickyArchive).ValidateOutput(
                    CapabilityJson.From(new
                    {
                        noteId = Guid.NewGuid(),
                        state = "active",
                        updatedAt = now.ToString("O", CultureInfo.InvariantCulture)
                    }));
                _failures.Add("sticky_archive_wrong_postcondition_accepted");
            }
            catch (CapabilityBrokerException ex) when (ex.Code == "CAPABILITY_ARGUMENT_INVALID")
            {
            }
            Require(!new UserSettings().AiNativeEnabled, "feature_default_off");
            VerifyGoldenDigest(now);
            VerifyCalendarIdempotencyEquivalence(now);

            try
            {
                _ = registry.Resolve(CapabilityIds.NativeAuthority);
                _failures.Add("native_authority_resolved");
            }
            catch (CapabilityBrokerException ex) when (ex.Code == "CAPABILITY_RUNTIME_PROHIBITED")
            {
            }

            await VerifyCalculatorAsync(broker, now);
            await VerifyControlsAsync(broker, now);
            await VerifyStickyLifecycleAsync(broker, stickyStore, now);
            await VerifyPocketAppAsync(root);

            var principal = new CapabilityPrincipal("user-broker-fixture");
            var allPermissions = Permissions(principal, "calendar.events.read", "sticky.write", "timer.write");
            var adapter = new TodayFocusTextAdapter(broker);
            var events = await adapter.ListTodayAsync("UTC", principal, allPermissions, now);
            Require(events.Count == 1, "calendar_read");
            Require(events[0].EventRef == "primary:sensitive-event-ref", "calendar_event_ref");
            var ledgerPath = Path.Combine(brokerRoot, "capability-broker-ledger.json");
            if (File.Exists(ledgerPath))
            {
                var ledgerText = File.ReadAllText(ledgerPath);
                Require(!ledgerText.Contains("Sensitive Calendar Title", StringComparison.Ordinal), "private_read_ledger_title");
                Require(!ledgerText.Contains("sensitive-event-ref", StringComparison.Ordinal), "private_read_ledger_ref");
            }
            var tokyo = TimeZoneInfo.CreateCustomTimeZone("JST-verify", TimeSpan.FromHours(9), "JST", "JST");
            var localDateDraft = adapter.PrepareFocus(
                events[0],
                1_500,
                "local-date-purpose",
                principal,
                allPermissions,
                new DateTimeOffset(2026, 8, 14, 16, 0, 0, TimeSpan.Zero),
                tokyo);
            Require(
                localDateDraft.Plan.Steps[1].Arguments.GetProperty("stableKey").GetString() == "today-focus:2026-08-15",
                "today_focus_local_date_key");
            Require(
                TodayFocusApprovalText.Sanitize("会議\n承認済み\u202E偽装") == "会議 承認済み 偽装",
                "approval_text_sanitized");
            var canonicalDraft = adapter.PrepareFocus(
                events[0],
                1_500,
                "会議\n承認済み\u202E偽装",
                principal,
                allPermissions,
                now);
            Require(canonicalDraft.ApprovalText == "会議 承認済み 偽装", "approval_text_draft");
            Require(
                canonicalDraft.Plan.Steps[0].Arguments.GetProperty("title").GetString() == canonicalDraft.ApprovalText,
                "approval_timer_exact");
            Require(
                canonicalDraft.Plan.Steps[1].Arguments.GetProperty("body").GetString() == canonicalDraft.ApprovalText,
                "approval_sticky_exact");
            var longApprovalDraft = adapter.PrepareFocus(
                events[0],
                1_500,
                new string('長', 100),
                principal,
                allPermissions,
                now);
            Require(longApprovalDraft.ApprovalText.EnumerateRunes().Count() == 80, "approval_text_bounded");
            Require(
                longApprovalDraft.Plan.Steps[0].Arguments.GetProperty("title").GetString() == longApprovalDraft.ApprovalText,
                "approval_timer_long_exact");
            Require(
                longApprovalDraft.Plan.Steps[1].Arguments.GetProperty("body").GetString() == longApprovalDraft.ApprovalText,
                "approval_sticky_long_exact");

            const string invalidAuditMarker = "private-invalid-plan-marker";
            var invalidAuditPlan = localDateDraft.Plan with { Id = new string('x', 256) + invalidAuditMarker };
            try
            {
                _ = broker.Prepare(invalidAuditPlan, allPermissions, now);
                _failures.Add("oversized_plan_accepted");
            }
            catch (CapabilityBrokerException ex) when (ex.Code == "CAPABILITY_PLAN_INVALID")
            {
            }
            const string invalidVersionMarker = "private-version-marker";
            const string appId = "com.hoverpocket.fixture";
            var appPrincipal = new CapabilityPrincipal(principal.UserId, appId);
            var invalidVersionPlan = localDateDraft.Plan with
            {
                Id = "invalid-version-plan",
                Origin = CapabilityOrigin.PocketSurface,
                Principal = appPrincipal,
                AppContext = new CapabilityAppContext(
                    appId,
                    $"1.0.0-{new string('a', 80)}{invalidVersionMarker}",
                    $"sha256:{new string('a', 64)}")
            };
            try
            {
                _ = broker.Prepare(
                    invalidVersionPlan,
                    new CapabilityPermissionSet(appPrincipal, allPermissions.Permissions),
                    now);
                _failures.Add("oversized_app_version_accepted");
            }
            catch (CapabilityBrokerException ex) when (ex.Code == "CAPABILITY_PLAN_INVALID")
            {
            }
            var nullIdentityPlan = invalidVersionPlan with
            {
                Id = "invalid-null-identity-plan",
                Principal = new CapabilityPrincipal(null!, appId),
                AppContext = new CapabilityAppContext(null!, null!, null!)
            };
            try
            {
                _ = broker.Prepare(
                    nullIdentityPlan,
                    new CapabilityPermissionSet(nullIdentityPlan.Principal, allPermissions.Permissions),
                    now);
                _failures.Add("null_identity_accepted");
            }
            catch (CapabilityBrokerException ex) when (ex.Code == "CAPABILITY_PLAN_INVALID")
            {
            }

            try
            {
                _ = adapter.PrepareFocus(
                    events[0],
                    1_500,
                    "secret-purpose-denied",
                    principal,
                    Permissions(principal, "timer.write"),
                    now);
                _failures.Add("permission_missing_accepted");
            }
            catch (CapabilityBrokerException ex) when (ex.Code == "CAPABILITY_PERMISSION_DENIED")
            {
            }
            Require(timerStore.RunningTimers.Count == 0 && stickyStore.Notes.Count == 0, "permission_no_write");

            var rejected = adapter.PrepareFocus(events[0], 1_500, "secret-purpose-rejected", principal, allPermissions, now);
            Require(rejected.Preparation.ApprovalRequest is not null, "reject_approval_request");
            try
            {
                _ = broker.DecideApproval(
                    rejected.Preparation.ApprovalRequest!.Id,
                    rejected.Preparation.PlanDigest,
                    CapabilityApprovalDecision.Reject,
                    now);
                _failures.Add("approval_reject_accepted");
            }
            catch (CapabilityBrokerException ex) when (ex.Code == "CAPABILITY_APPROVAL_REJECTED")
            {
            }
            Require(timerStore.RunningTimers.Count == 0 && stickyStore.Notes.Count == 0, "reject_no_write");

            var expired = adapter.PrepareFocus(events[0], 1_500, "secret-purpose-expired", principal, allPermissions, now);
            try
            {
                _ = broker.DecideApproval(
                    expired.Preparation.ApprovalRequest!.Id,
                    expired.Preparation.PlanDigest,
                    CapabilityApprovalDecision.Approve,
                    now.AddSeconds(301));
                _failures.Add("expired_approval_accepted");
            }
            catch (CapabilityBrokerException ex) when (ex.Code == "CAPABILITY_APPROVAL_EXPIRED")
            {
            }

            var tamper = adapter.PrepareFocus(events[0], 1_500, "secret-purpose-original", principal, allPermissions, now);
            var tamperGrant = broker.DecideApproval(
                tamper.Preparation.ApprovalRequest!.Id,
                tamper.Preparation.PlanDigest,
                CapabilityApprovalDecision.Approve,
                now);
            try
            {
                _ = await broker.ExecuteAsync(ReplacePurpose(tamper.Plan, "secret-purpose-tampered"), allPermissions, tamperGrant, now);
                _failures.Add("approved_plan_tamper_accepted");
            }
            catch (CapabilityBrokerException ex) when (ex.Code == "CAPABILITY_APPROVAL_INVALID")
            {
            }
            Require(timerStore.RunningTimers.Count == 0 && stickyStore.Notes.Count == 0, "tamper_no_write");

            var approved = adapter.PrepareFocus(events[0], 1_500, "secret-purpose-approved", principal, allPermissions, now);
            Require(approved.Preparation.ApprovalRequest?.Effects.Count == 2, "approval_effect_count");
            var grant = broker.DecideApproval(
                approved.Preparation.ApprovalRequest!.Id,
                approved.Preparation.PlanDigest,
                CapabilityApprovalDecision.Approve,
                now);
            var receipt = await broker.ExecuteAsync(approved.Plan, allPermissions, grant, now);
            Require(receipt.Status == CapabilityReceiptStatus.Succeeded, "today_focus_status");
            Require(receipt.Steps.Count == 2, "today_focus_receipts");
            Require(receipt.Steps.All(step => step.Readback.Status == CapabilityReadbackStatus.Verified), "today_focus_readback");
            Require(timerStore.RunningTimers.Count == 1, "today_focus_timer_effect");
            Require(stickyStore.Notes.Count == 1, "today_focus_sticky_effect");
            Require(stickyStore.Notes[0].Body == "secret-purpose-approved", "today_focus_sticky_body");

            var replayBroker = new CapabilityBroker(
                registry,
                new CapabilityBrokerLedger(brokerRoot),
                new CapabilityBrokerAuditLog(brokerRoot));
            var replay = await replayBroker.ExecuteAsync(approved.Plan, allPermissions, null, now.AddSeconds(1));
            Require(replay.Replayed, "workflow_replay_flag");
            Require(replay.PlanDigest == receipt.PlanDigest, "workflow_replay_digest");
            Require(timerStore.RunningTimers.Count == 1 && stickyStore.Notes.Count == 1, "workflow_replay_single_effect");

            try
            {
                _ = await replayBroker.ExecuteAsync(ReplacePurpose(approved.Plan, "secret-purpose-conflict"), allPermissions, null, now.AddSeconds(2));
                _failures.Add("workflow_idempotency_conflict_accepted");
            }
            catch (CapabilityBrokerException ex) when (ex.Code == "CAPABILITY_IDEMPOTENCY_CONFLICT")
            {
            }

            var next = adapter.PrepareFocus(events[0], 600, "secret-purpose-next", principal, allPermissions, now);
            try
            {
                _ = await broker.ExecuteAsync(next.Plan, allPermissions, grant, now);
                _failures.Add("approval_replay_accepted");
            }
            catch (CapabilityBrokerException ex) when (ex.Code == "CAPABILITY_APPROVAL_REPLAYED")
            {
            }

            var timerCountBeforeConcurrent = timerStore.RunningTimers.Count;
            var concurrent = adapter.PrepareFocus(
                events[0],
                300,
                "secret-purpose-concurrent",
                principal,
                allPermissions,
                now.AddSeconds(3));
            var concurrentGrant = broker.DecideApproval(
                concurrent.Preparation.ApprovalRequest!.Id,
                concurrent.Preparation.PlanDigest,
                CapabilityApprovalDecision.Approve,
                now.AddSeconds(3));
            var concurrentReceipts = await Task.WhenAll(
                broker.ExecuteAsync(concurrent.Plan, allPermissions, concurrentGrant, now.AddSeconds(3)),
                broker.ExecuteAsync(concurrent.Plan, allPermissions, concurrentGrant, now.AddSeconds(3)));
            Require(concurrentReceipts.Count(item => item.Replayed) == 1, "concurrent_replay_count");
            Require(timerStore.RunningTimers.Count == timerCountBeforeConcurrent + 1, "concurrent_single_timer_effect");

            var auditText = Encoding.UTF8.GetString(audit.CombinedData());
            foreach (var forbidden in new[]
            {
                "Sensitive Calendar Title",
                "sensitive-event-ref",
                "secret-purpose-approved",
                "secret-purpose-rejected",
                "secret-purpose-concurrent",
                principal.UserId,
                PrivatePresentationTitle,
                "44444444-4444-4444-8444-444444444444"
            })
            {
                Require(!auditText.Contains(forbidden, StringComparison.Ordinal), $"audit_redaction_{forbidden}");
            }
            Require(auditText.Contains("principal:sha256:", StringComparison.Ordinal), "audit_principal_digest");
            Require(auditText.Contains("\"idempotencyReplay\":true", StringComparison.Ordinal), "audit_replay");
            Require(auditText.Contains("\"eventType\":\"authorization_decision\"", StringComparison.Ordinal), "authorization_audit");
            Require(auditText.Contains("CAPABILITY_APPROVAL_REJECTED", StringComparison.Ordinal), "authorization_reject_audit");
            Require(auditText.Contains("\"planDigest\":\"unavailable\"", StringComparison.Ordinal), "invalid_plan_digest_audit");
            Require(auditText.Contains("\"planId\":\"invalid\"", StringComparison.Ordinal), "invalid_plan_id_audit");
            Require(!auditText.Contains(invalidAuditMarker, StringComparison.Ordinal), "invalid_plan_audit_redaction");
            Require(!auditText.Contains(invalidVersionMarker, StringComparison.Ordinal), "invalid_version_audit_redaction");
            var durableLedgerText = File.ReadAllText(ledgerPath);
            foreach (var forbidden in new[]
            {
                "secret-purpose-approved",
                "secret-purpose-concurrent",
                "Sensitive Calendar Title",
                PrivatePresentationTitle,
                "44444444-4444-4444-8444-444444444444"
            })
            {
                Require(!durableLedgerText.Contains(forbidden, StringComparison.Ordinal), $"ledger_redaction_{forbidden}");
            }

            VerifyCapabilityDataGovernance(brokerRoot, approved.Plan, now);

            await VerifyPartialRollbackAsync(root, now, principal);
            await VerifyCurrentStepRollbackAsync(root, now, principal);
            await VerifyCancellationRollbackAsync(root, now, principal);
            await VerifyCancellationAfterSuccessfulStepAsync(root, now, principal);
            await VerifyTimeoutAsync(root, now, principal);
        }
        finally
        {
            if (Directory.Exists(root))
            {
                Directory.Delete(root, recursive: true);
            }
        }
    }

    private void VerifyCapabilityDataGovernance(
        string brokerRoot,
        CapabilityExecutionPlan approvedPlan,
        DateTimeOffset now)
    {
        var ledger = new CapabilityBrokerLedger(brokerRoot);
        var audit = new CapabilityBrokerAuditLog(brokerRoot);
        var governance = new CapabilityDataGovernanceController(ledger, audit);
        var before = governance.Snapshot();
        Require(before.AuditFileCount > 0, "retention_audit_before");
        Require(before.StoredReceiptCount > 0, "retention_receipts_before");

        var afterRetention = governance.ApplyRetention(
            CapabilityDataRetentionPeriod.SevenDays,
            now.AddDays(8));
        Require(afterRetention.AuditFileCount == 0, "retention_audit_removed");
        Require(afterRetention.StoredReceiptCount == 0, "retention_receipts_redacted");
        Require(afterRetention.RedactedTombstoneCount > 0, "retention_tombstones_preserved");
        var lookup = ledger.LookupWorkflow(approvedPlan.Id, CapabilityCanonicalJson.PlanDigest(approvedPlan));
        Require(lookup.Kind == CapabilityLedgerStartKind.Unknown, "retention_tombstone_reexecution_allowed");

        var auditDirectory = Path.Combine(brokerRoot, "audit");
        File.WriteAllText(Path.Combine(auditDirectory, "capability-20990101.jsonl"), "{}\n");
        var afterClear = governance.ClearHistory(now);
        Require(afterClear.AuditFileCount == 0, "retention_explicit_clear");
        Require(afterClear.RedactedTombstoneCount > 0, "retention_clear_tombstones_preserved");

        var invalidEntry = Path.Combine(auditDirectory, "capability-20990102.jsonl");
        Directory.CreateDirectory(invalidEntry);
        try
        {
            _ = governance.Snapshot();
            _failures.Add("retention_non_file_accepted");
        }
        catch (CapabilityBrokerException ex) when (ex.Code == "CAPABILITY_AUDIT_UNAVAILABLE")
        {
        }
        Directory.Delete(invalidEntry);

        var migrationRoot = Path.Combine(brokerRoot, "v1-migration");
        Directory.CreateDirectory(migrationRoot);
        var migrationPath = Path.Combine(migrationRoot, "capability-broker-ledger.json");
        File.WriteAllText(migrationPath, "{\"invocations\":{},\"version\":1,\"workflows\":{}}");
        _ = new CapabilityBrokerLedger(migrationRoot);
        Require(
            File.ReadAllText(migrationPath).Contains("\"version\":2", StringComparison.Ordinal),
            "retention_v1_migrated");
    }

    private async Task VerifyCalculatorAsync(CapabilityBroker broker, DateTimeOffset now)
    {
        var principal = new CapabilityPrincipal("user-calculator-fixture");
        var plan = new CapabilityExecutionPlan(
            "calculator-pure-plan",
            now,
            CapabilityOrigin.Text,
            principal,
            null,
            [new CapabilityPlanStep(
                "evaluate",
                CapabilityIds.CalculatorEvaluate,
                CapabilityJson.From(new { expression = "8 / 4 + 1" }),
                "calculator-pure-key-0001",
                [])],
            new HashSet<string>(StringComparer.Ordinal));
        var permissions = Permissions(principal);
        var preparation = broker.Prepare(plan, permissions, now);
        Require(preparation.ApprovalRequest is null, "calculator_approval_not_required");
        var receipt = await broker.ExecuteAsync(plan, permissions, null, now);
        Require(receipt.Status == CapabilityReceiptStatus.Succeeded, "calculator_receipt_status");
        Require(receipt.Steps.Count == 1, "calculator_receipt_count");
        var output = receipt.Steps[0].Output;
        Require(output is not null, "calculator_receipt_output");
        if (output is { } value)
        {
            Require(value.GetProperty("normalizedExpression").GetString() == "8 / 4 + 1", "calculator_normalized");
            Require(value.GetProperty("result").GetString() == "3", "calculator_result");
        }
        Require(receipt.Steps[0].Readback.Status == CapabilityReadbackStatus.Verified, "calculator_readback");
        Require(receipt.Steps[0].Readback.Strategy == CapabilityReadbackStrategy.None, "calculator_readback_strategy");
        Require(receipt.Steps[0].Readback.Observed is not null, "calculator_observed");
    }

    private async Task VerifyControlsAsync(CapabilityBroker broker, DateTimeOffset now)
    {
        var principal = new CapabilityPrincipal("controls-broker-user");
        var permissions = Permissions(principal, "controls.write");
        var plan = new CapabilityExecutionPlan(
            "controls-volume-plan",
            now,
            CapabilityOrigin.Text,
            principal,
            null,
            [new CapabilityPlanStep(
                "setVolume",
                CapabilityIds.ControlsVolumeSet,
                CapabilityJson.From(new { level = 0.75 }),
                "controls-broker-volume-key-0001",
                [])],
            new HashSet<string>(["controls.write"], StringComparer.Ordinal));
        var preparation = broker.Prepare(plan, permissions, now);
        Require(preparation.ApprovalRequest is not null, "controls_approval_missing");
        if (preparation.ApprovalRequest is null)
        {
            return;
        }
        var grant = broker.DecideApproval(
            preparation.ApprovalRequest.Id,
            preparation.PlanDigest,
            CapabilityApprovalDecision.Approve,
            now);
        var receipt = await broker.ExecuteAsync(plan, permissions, grant, now);
        Require(receipt.Status == CapabilityReceiptStatus.Succeeded, "controls_receipt_status");
        Require(receipt.Steps[0].Readback.Status == CapabilityReadbackStatus.Verified, "controls_readback_verified");
        Require(
            Math.Abs((receipt.Steps[0].Output?.GetProperty("level").GetDouble() ?? 0) - 0.75) < 0.001,
            "controls_readback_level");
    }

    private async Task VerifyPocketAppAsync(string root)
    {
        var now = new DateTimeOffset(2026, 8, 14, 16, 0, 0, TimeSpan.Zero);
        using var timerStore = new TimerStore(
            Path.Combine(root, "pocket-app-timer"),
            new ManualTimerClock(now),
            new NullTimerAlertSound(),
            enableScheduler: false);
        var stickyStore = new StickyNotesStore(Path.Combine(root, "pocket-app-sticky"));
        var calendar = new BrokerFakeCalendarDataSource(now);
        var handlers = ProviderCapabilityCompositionRoot.Create(calendar, timerStore, stickyStore);
        var brokerRoot = Path.Combine(root, "pocket-app-broker");
        var broker = new CapabilityBroker(
            new CapabilityRegistry(handlers),
            new CapabilityBrokerLedger(brokerRoot),
            new CapabilityBrokerAuditLog(brokerRoot));
        var package = new PocketAppPackageRuntime().Load(Path.Combine(
            AppContext.BaseDirectory,
            "PocketApps",
            "local.example.today-focus"));
        var timeZone = TimeZoneInfo.FindSystemTimeZoneById("Tokyo Standard Time");
        Require(
            PocketAppExecutionRuntime.ContractTimeZoneId(timeZone) == "Asia/Tokyo",
            "pocket_app_windows_timezone_contract");
        var stateRoot = Path.Combine(root, "pocket-app-user-state");
        using var userStateStore = new PocketAppUserStateStore(
            package.Manifest.Id,
            package.StateProperties,
            stateRoot);
        var runtime = new PocketAppExecutionRuntime(
            package,
            broker,
            "user-pocket-app-fixture",
            new HashSet<string>(
                ["calendar.events.read", "sticky.read", "sticky.write", "timer.read", "timer.write"],
                StringComparer.Ordinal),
            timeZone,
            userStateStore);
        var hostController = new PocketAppHostController(
            runtime,
            () => new UserSettings { AiNativeEnabled = true },
            () => now);
        var surfaceState = JsonSerializer.SerializeToElement(hostController.BuildSurfaceState());
        Require(
            surfaceState.GetProperty("workflowInputs")
                .GetProperty("startFocus")
                .EnumerateArray()
                .Select(item => item.GetString() ?? string.Empty)
                .SequenceEqual(["durationSeconds", "purpose", "selectedEventRef"], StringComparer.Ordinal),
            "pocket_app_surface_workflow_inputs");
        var managerState = JsonSerializer.SerializeToElement(hostController.BuildManagerState());
        Require(managerState.GetProperty("appId").GetString() == package.Manifest.Id, "pocket_app_manager_id");
        Require(managerState.GetProperty("version").GetString() == package.Manifest.Version, "pocket_app_manager_version");
        Require(managerState.GetProperty("testsCount").GetInt32() == 4, "pocket_app_manager_tests");
        Require(
            managerState.GetProperty("storageBoundary").GetString() == "separate_definition_data_receipts",
            "pocket_app_manager_storage_boundary");
        Require(
            !managerState.GetRawText().Contains(package.RootDirectory, StringComparison.OrdinalIgnoreCase),
            "pocket_app_manager_path_redaction");

        var dispatcher = new BridgeDispatcher();
        hostController.Attach(dispatcher);
        var loadResponse = await dispatcher.ProcessRawMessageAsync(
            JsonSerializer.Serialize(new
            {
                id = "load",
                method = "pocketApp.load",
                @params = new { appId = package.Manifest.Id, surfaceId = "main" }
            }));
        Require(loadResponse is not null, "pocket_app_host_load_response");
        using (var loadDocument = JsonDocument.Parse(loadResponse!))
        {
            if (loadDocument.RootElement.GetProperty("error").ValueKind != JsonValueKind.Null)
            {
                _failures.Add("pocket_app_host_load");
                return;
            }
            var firstQuery = loadDocument.RootElement.GetProperty("result")
                .GetProperty("queryResults")[0];
            Require(
                firstQuery.GetProperty("query").GetString() == "calendar.events.list@1"
                    && firstQuery.GetProperty("arguments").ValueKind == JsonValueKind.Object,
                "pocket_app_host_query_binding_identity");
        }
        var updateResponse = await dispatcher.ProcessRawMessageAsync(
            JsonSerializer.Serialize(new
            {
                id = "state",
                method = "pocketApp.updateState",
                @params = new
                {
                    appId = package.Manifest.Id,
                    key = "selectedEventRef",
                    value = "primary:sensitive-event-ref"
                }
            }));
        using (var updateDocument = JsonDocument.Parse(updateResponse!))
        {
            Require(updateDocument.RootElement.GetProperty("error").ValueKind == JsonValueKind.Null, "pocket_app_state_update");
        }
        using var reloadedStateStore = new PocketAppUserStateStore(
            package.Manifest.Id,
            package.StateProperties,
            stateRoot);
        var reloadedState = reloadedStateStore.Snapshot();
        Require(
            reloadedState.TryGetValue("selectedEventRef", out var reloadedEventRef)
            && reloadedEventRef.ValueKind == JsonValueKind.String
            && reloadedEventRef.GetString() == "primary:sensitive-event-ref",
            "pocket_app_state_persistence");
        using var typedStateStore = new PocketAppUserStateStore(
            "local.example.typed-state",
            new HashSet<string>(["enabled", "label", "ratio"], StringComparer.Ordinal),
            stateRoot);
        typedStateStore.SetValue("enabled", CapabilityJson.From(true));
        typedStateStore.SetValue("label", CapabilityJson.From("Saved"));
        typedStateStore.SetValue("ratio", CapabilityJson.From(1.5));
        using var typedStateReadbackStore = new PocketAppUserStateStore(
            "local.example.typed-state",
            new HashSet<string>(["enabled", "label", "ratio"], StringComparer.Ordinal),
            stateRoot);
        var typedStateReadback = typedStateReadbackStore.Snapshot();
        Require(
            typedStateReadback["enabled"].ValueKind == JsonValueKind.True
            && typedStateReadback["label"].GetString() == "Saved"
            && typedStateReadback["ratio"].GetDouble() == 1.5,
            "pocket_app_typed_state_persistence");
        var migratedStateTypes = new Dictionary<string, IReadOnlySet<string>>(StringComparer.Ordinal)
        {
            ["enabled"] = new HashSet<string>(["string"], StringComparer.Ordinal),
            ["label"] = new HashSet<string>(["string"], StringComparer.Ordinal),
            ["ratio"] = new HashSet<string>(["integer"], StringComparer.Ordinal)
        };
        using var migratedStateStore = new PocketAppUserStateStore(
            "local.example.typed-state",
            migratedStateTypes,
            stateRoot);
        var migratedState = migratedStateStore.Snapshot();
        Require(
            migratedState.Count == 1
                && migratedState["label"].GetString() == "Saved",
            "pocket_app_state_schema_migration");
        using var migratedStateReadbackStore = new PocketAppUserStateStore(
            "local.example.typed-state",
            migratedStateTypes,
            stateRoot);
        var migratedStateReadback = migratedStateReadbackStore.Snapshot();
        Require(
            migratedStateReadback.Count == 1
                && migratedStateReadback["label"].GetString() == "Saved",
            "pocket_app_state_schema_migration_persisted");
        try
        {
            migratedStateStore.SetValue("label", CapabilityJson.From(true));
            _failures.Add("pocket_app_state_schema_write_accepted");
        }
        catch (PocketAppUserStateStoreException)
        {
        }
        var constrainedStateProperties = new Dictionary<string, PocketAppStatePropertySchema>(StringComparer.Ordinal)
        {
            ["focusDate"] = new PocketAppStatePropertySchema(
                new HashSet<string>(["string"], StringComparer.Ordinal),
                true,
                "date",
                10)
        };
        using var constrainedStateStore = new PocketAppUserStateStore(
            "local.example.constrained-state",
            constrainedStateProperties,
            stateRoot);
        constrainedStateStore.SetValue("focusDate", CapabilityJson.From("2026-08-20"));
        try
        {
            constrainedStateStore.SetValue("focusDate", CapabilityJson.From("2026-02-30"));
            _failures.Add("pocket_app_state_date_constraint_accepted");
        }
        catch (PocketAppUserStateStoreException)
        {
        }
        try
        {
            constrainedStateStore.SetValue("focusDate", CapabilityJson.From("2026-08-200"));
            _failures.Add("pocket_app_state_max_length_constraint_accepted");
        }
        catch (PocketAppUserStateStoreException)
        {
        }
        try
        {
            constrainedStateStore.SetValue("focusDate", null);
            _failures.Add("pocket_app_state_required_removal_accepted");
        }
        catch (PocketAppUserStateStoreException)
        {
        }
        using (var optionalRequiredLoadStore = new PocketAppUserStateStore(
            "local.example.required-load-state",
            new Dictionary<string, IReadOnlySet<string>>(StringComparer.Ordinal)
            {
                ["focusDate"] = new HashSet<string>(["string"], StringComparer.Ordinal)
            },
            stateRoot))
        {
            optionalRequiredLoadStore.SetValue("focusDate", CapabilityJson.From("not-a-date"));
        }
        using var repairedRequiredStateStore = new PocketAppUserStateStore(
            "local.example.required-load-state",
            constrainedStateProperties,
            stateRoot);
        Require(
            repairedRequiredStateStore.Snapshot().Count == 0,
            "pocket_app_state_invalid_required_value_repaired");
        using var repairedRequiredStateReadbackStore = new PocketAppUserStateStore(
            "local.example.required-load-state",
            constrainedStateProperties,
            stateRoot);
        Require(
            repairedRequiredStateReadbackStore.Snapshot().Count == 0,
            "pocket_app_state_invalid_required_value_repair_persisted");
        using var isolatedStateStore = new PocketAppUserStateStore(
            "local.example.state-isolated-a",
            new HashSet<string>(["label"], StringComparer.Ordinal),
            stateRoot);
        using var otherStateStore = new PocketAppUserStateStore(
            "local.example.state-isolated-b",
            new HashSet<string>(["label"], StringComparer.Ordinal),
            stateRoot);
        otherStateStore.SetString("label", "other-app");
        var isolatedDirectory = Path.Combine(stateRoot, "local.example.state-isolated-a");
        var isolatedBackup = Path.Combine(stateRoot, "local.example.state-isolated-a-backup");
        var directorySwapBlocked = false;
        try
        {
            Directory.Move(isolatedDirectory, isolatedBackup);
            Directory.CreateDirectory(isolatedDirectory);
            try
            {
                isolatedStateStore.SetString("label", "must-not-write");
            }
            catch (PocketAppUserStateStoreException)
            {
                directorySwapBlocked = true;
            }
            finally
            {
                Directory.Delete(isolatedDirectory, recursive: true);
                Directory.Move(isolatedBackup, isolatedDirectory);
            }
        }
        catch (IOException)
        {
            directorySwapBlocked = true;
        }
        Require(directorySwapBlocked, "pocket_app_state_directory_swap_blocked");
        using var otherStateReadbackStore = new PocketAppUserStateStore(
            "local.example.state-isolated-b",
            new HashSet<string>(["label"], StringComparer.Ordinal),
            stateRoot);
        Require(
            otherStateReadbackStore.Snapshot()["label"].GetString() == "other-app",
            "pocket_app_state_directory_swap_isolated");
        var forgedStateResponse = await dispatcher.ProcessRawMessageAsync(
            JsonSerializer.Serialize(new
            {
                id = "forged",
                method = "pocketApp.updateState",
                @params = new
                {
                    appId = package.Manifest.Id,
                    key = "selectedEventRef",
                    value = "primary:forged"
                }
            }));
        using (var forgedDocument = JsonDocument.Parse(forgedStateResponse!))
        {
            Require(forgedDocument.RootElement.GetProperty("error").ValueKind == JsonValueKind.Object, "pocket_app_forged_state_ref");
        }

        var queryOutput = await runtime.QueryAsync(
            "calendar.events.list@1",
            CapabilityJson.From(new { range = "today", timezone = "$context.timezone" }),
            now);
        Require(queryOutput.GetProperty("events").GetArrayLength() == 1, "pocket_app_calendar_query");

        var inputs = new Dictionary<string, JsonElement>(StringComparer.Ordinal)
        {
            ["selectedEventRef"] = CapabilityJson.From("primary:sensitive-event-ref"),
            ["durationSeconds"] = CapabilityJson.From(1_500),
            ["purpose"] = CapabilityJson.From("Pocket Focus")
        };
        var presentationInputs = new Dictionary<string, JsonElement>(inputs, StringComparer.Ordinal)
        {
            ["purpose"] = CapabilityJson.From("表示\n偽装\u202E確認")
        };
        var presentationDraft = runtime.Prepare("startFocus", presentationInputs, now);
        const string canonicalPurpose = "表示 偽装 確認";
        Require(
            !PocketAppExecutionRuntime.SupportsWorkflowPresentation(CapabilityIds.CalendarList),
            "pocket_app_unpresentable_workflow_rejected");
        Require(
            presentationDraft.Plan.Steps[0].Arguments.GetProperty("title").GetString() == canonicalPurpose,
            "pocket_app_approval_timer_exact");
        Require(
            presentationDraft.Plan.Steps[1].Arguments.GetProperty("body").GetString() == canonicalPurpose,
            "pocket_app_approval_sticky_exact");
        Require(
            PocketAppHostController.ApprovalSummary(presentationDraft, english: false).Contains(canonicalPurpose, StringComparison.Ordinal),
            "pocket_app_approval_presentation_exact");
        runtime.Reject(presentationDraft, now);
        var draft = runtime.Prepare("startFocus", inputs, now);
        Require(draft.Plan.Origin == CapabilityOrigin.PocketSurface, "pocket_app_origin");
        Require(draft.Plan.Principal.PocketAppId == package.Manifest.Id, "pocket_app_principal");
        Require(draft.Plan.AppContext?.Id == package.Manifest.Id, "pocket_app_context_id");
        Require(draft.Plan.AppContext?.Version == package.Manifest.Version, "pocket_app_context_version");
        Require(draft.Plan.AppContext?.ManifestDigest == package.ManifestDigest, "pocket_app_context_digest");
        Require(
            draft.Plan.Steps[1].Arguments.GetProperty("stableKey").GetString() == "today-focus:2026-08-15",
            "pocket_app_local_date_key");
        Require(
            draft.Plan.Steps[0].Arguments.GetProperty("title").GetString() == "Pocket Focus",
            "pocket_app_timer_title");
        Require(
            draft.Plan.Steps[1].Arguments.GetProperty("body").GetString() == "Pocket Focus",
            "pocket_app_sticky_body");
        Require(draft.Preparation.ApprovalRequest?.Effects.Count == 2, "pocket_app_approval_effects");

        var receipt = await runtime.ApproveAndExecuteAsync(draft, now);
        Require(receipt.Status == CapabilityReceiptStatus.Succeeded, "pocket_app_receipt_status");
        Require(receipt.Steps.Count == 2, "pocket_app_receipt_steps");
        Require(
            receipt.Steps.All(step => step.Readback.Status == CapabilityReadbackStatus.Verified),
            "pocket_app_readback");
        Require(
            PocketAppHostController.ReceiptSummary(receipt, english: false) == "Timer、Sticky Notesへ反映しました（2件確認済み）",
            "pocket_app_receipt_summary");
        Require(timerStore.RunningTimers.Count == 1, "pocket_app_timer_effect");
        Require(stickyStore.Notes.Count == 1, "pocket_app_sticky_effect");
        var replay = await broker.ExecuteAsync(
            draft.Plan,
            new CapabilityPermissionSet(
                draft.Plan.Principal,
                new HashSet<string>(
                    ["calendar.events.read", "sticky.read", "sticky.write", "timer.read", "timer.write"],
                    StringComparer.Ordinal)),
            null,
            now.AddSeconds(1));
        Require(replay.Replayed, "pocket_app_replay");
        Require(
            timerStore.RunningTimers.Count == 1 && stickyStore.Notes.Count == 1,
            "pocket_app_replay_effect");

        try
        {
            _ = await runtime.QueryAsync(
                "timer.countdown.start@1",
                CapabilityJson.From(new
                {
                    durationSeconds = 60,
                    sourceRef = "pocket:query",
                    title = "not allowed"
                }),
                now);
            _failures.Add("pocket_app_write_query_accepted");
        }
        catch (CapabilityBrokerException ex) when (ex.Code == "CAPABILITY_PLAN_INVALID")
        {
        }

        var rejected = runtime.Prepare("startFocus", inputs, now.AddSeconds(1));
        runtime.Reject(rejected, now.AddSeconds(1));
        Require(timerStore.RunningTimers.Count == 1 && stickyStore.Notes.Count == 1, "pocket_app_reject_no_write");

        var blockingTimer = new BrokerBlockingTimerStartHandler();
        var countingSticky = new BrokerCountingStickyUpsertHandler();
        var revocationRoot = Path.Combine(root, "pocket-app-revocation-broker");
        var revocationBroker = new CapabilityBroker(
            new CapabilityRegistry(new PocketCapabilityHandlerSet([blockingTimer, countingSticky])),
            new CapabilityBrokerLedger(revocationRoot),
            new CapabilityBrokerAuditLog(revocationRoot));
        var revocationLease = new PocketAppActivationLease();
        var revocationRuntime = new PocketAppExecutionRuntime(
            package,
            revocationBroker,
            "user-pocket-app-revocation-fixture",
            new HashSet<string>(
                ["calendar.events.read", "sticky.read", "sticky.write", "timer.read", "timer.write"],
                StringComparer.Ordinal),
            timeZone,
            activationLease: revocationLease);
        var revocationDraft = revocationRuntime.Prepare("startFocus", inputs, now.AddSeconds(2));
        var inFlight = revocationRuntime.ApproveAndExecuteAsync(revocationDraft, now.AddSeconds(2));
        Require(
            await blockingTimer.Entered.Task.WaitAsync(TimeSpan.FromSeconds(5)),
            "pocket_app_revocation_entered_handler");
        revocationLease.Invalidate();
        try
        {
            _ = await inFlight;
            _failures.Add("pocket_app_revocation_execution_survived");
        }
        catch (OperationCanceledException)
        {
        }
        catch (PocketAppRuntimeActivationException ex) when (ex.Code == "RUNTIME_ACTIVATION_UNAVAILABLE")
        {
        }
        Require(blockingTimer.WasCancelled, "pocket_app_revocation_cancelled_handler");
        Require(countingSticky.InvocationCount == 0, "pocket_app_revocation_blocks_later_write");
    }

    private void VerifyStrongPerCallIsolation(CapabilityBroker broker, DateTimeOffset now)
    {
        var principal = new CapabilityPrincipal("user-strong-approval-fixture");
        var noteId = Guid.Parse("44444444-4444-4444-8444-444444444444");
        var plan = new CapabilityExecutionPlan(
            "strong-approval-batch-plan",
            now,
            CapabilityOrigin.Text,
            principal,
            null,
            [
                new CapabilityPlanStep(
                    "readNote",
                    CapabilityIds.StickyStatus,
                    CapabilityJson.From(new { noteId }),
                    "strong-approval-read-key-0001",
                    []),
                new CapabilityPlanStep(
                    "deleteNote",
                    CapabilityIds.StickyDelete,
                    CapabilityJson.From(new { noteId }),
                    "strong-approval-delete-key-0001",
                    ["readNote"])
            ],
            new HashSet<string>(["sticky.delete", "sticky.read"], StringComparer.Ordinal));
        try
        {
            _ = broker.Prepare(
                plan,
                Permissions(principal, "sticky.delete", "sticky.read"),
                now);
            _failures.Add("strong_per_call_batch_accepted");
        }
        catch (CapabilityBrokerException ex) when (
            ex.Code == "CAPABILITY_PLAN_INVALID" && ex.Message.Contains("strong_per_call", StringComparison.Ordinal))
        {
        }
    }

    private void VerifyStrongApprovalPresentationRequired(
        CapabilityRegistry registry,
        string root,
        DateTimeOffset now)
    {
        var brokerRoot = Path.Combine(root, "missing-presentation-broker");
        var broker = new CapabilityBroker(
            registry,
            new CapabilityBrokerLedger(brokerRoot),
            new CapabilityBrokerAuditLog(brokerRoot));
        var principal = new CapabilityPrincipal("user-missing-presentation-fixture");
        var plan = new CapabilityExecutionPlan(
            "missing-presentation-plan",
            now,
            CapabilityOrigin.Text,
            principal,
            null,
            [new CapabilityPlanStep(
                "deleteNote",
                CapabilityIds.StickyDelete,
                CapabilityJson.From(new { noteId = Guid.Parse("44444444-4444-4444-8444-444444444444") }),
                "missing-presentation-key-0001",
                [])],
            new HashSet<string>(["sticky.delete"], StringComparer.Ordinal));
        try
        {
            _ = broker.Prepare(plan, Permissions(principal, "sticky.delete"), now);
            _failures.Add("missing_strong_presentation_accepted");
        }
        catch (CapabilityBrokerException ex) when (
            ex.Code == "CAPABILITY_PLAN_INVALID"
            && ex.Message.Contains("approval_presentation", StringComparison.Ordinal))
        {
        }
    }

    private async Task VerifyStickyLifecycleAsync(
        CapabilityBroker broker,
        StickyNotesStore store,
        DateTimeOffset now)
    {
        var note = store.UpsertNote(
            "broker-lifecycle-fixture",
            PrivatePresentationTitle,
            "Private body",
            StickyNoteColor.Yellow);
        var principal = new CapabilityPrincipal("user-sticky-lifecycle-fixture");
        var archivePermissions = Permissions(principal, "sticky.write");
        var archivePlan = new CapabilityExecutionPlan(
            "sticky-archive-plan",
            now,
            CapabilityOrigin.Text,
            principal,
            null,
            [new CapabilityPlanStep(
                "archiveNote",
                CapabilityIds.StickyArchive,
                CapabilityJson.From(new { noteId = note.Id }),
                "sticky-broker-archive-key-0001",
                [])],
            new HashSet<string>(["sticky.write"], StringComparer.Ordinal));
        var archivePreparation = broker.Prepare(archivePlan, archivePermissions, now);
        Require(archivePreparation.ApprovalRequest is not null, "sticky_archive_approval_missing");
        var archiveGrant = broker.DecideApproval(
            archivePreparation.ApprovalRequest!.Id,
            archivePreparation.PlanDigest,
            CapabilityApprovalDecision.Approve,
            now);
        var archiveReceipt = await broker.ExecuteAsync(archivePlan, archivePermissions, archiveGrant, now);
        Require(archiveReceipt.Status == CapabilityReceiptStatus.Succeeded, "sticky_archive_receipt");
        Require(
            archiveReceipt.Steps[0].Output?.GetProperty("state").GetString() == "archived",
            "sticky_archive_output");
        Require(archiveReceipt.Steps[0].Readback.Status == CapabilityReadbackStatus.Verified, "sticky_archive_readback");
        Require(store.GetNote(note.Id)?.ArchivedAt == now, "sticky_archive_effect");

        var deleteNow = now.AddSeconds(1);
        var deletePermissions = Permissions(principal, "sticky.delete");
        var deletePlan = new CapabilityExecutionPlan(
            "sticky-delete-plan",
            deleteNow,
            CapabilityOrigin.Text,
            principal,
            null,
            [new CapabilityPlanStep(
                "deleteNote",
                CapabilityIds.StickyDelete,
                CapabilityJson.From(new { noteId = note.Id }),
                "sticky-broker-delete-key-0001",
                [])],
            new HashSet<string>(["sticky.delete"], StringComparer.Ordinal));
        var deletePreparation = broker.Prepare(deletePlan, deletePermissions, deleteNow);
        Require(deletePreparation.ApprovalRequest is not null, "sticky_delete_approval_missing");
        Require(deletePreparation.ApprovalPresentations.Count == 1, "sticky_delete_presentation_missing");
        var presentation = deletePreparation.ApprovalPresentations.Single();
        var effect = deletePreparation.ApprovalRequest!.Effects.Single();
        Require(presentation.RequestId == deletePreparation.ApprovalRequest.Id, "sticky_presentation_request_binding");
        Require(presentation.PlanDigest == deletePreparation.PlanDigest, "sticky_presentation_plan_binding");
        Require(presentation.StepId == "deleteNote", "sticky_presentation_step_binding");
        Require(presentation.ArgumentDigest == effect.ArgumentDigest, "sticky_presentation_argument_binding");
        Require(presentation.TargetKind == "sticky_note", "sticky_presentation_target_kind");
        Require(presentation.TargetState == CapabilityApprovalTargetState.Present, "sticky_presentation_target_state");
        Require(presentation.Destructive, "sticky_presentation_destructive");
        Require(presentation.TargetDisplayLabel?.StartsWith("Private title ", StringComparison.Ordinal) == true, "sticky_presentation_label");
        Require((presentation.TargetDisplayLabel?.EnumerateRunes().Count() ?? 0) <= 80, "sticky_presentation_label_limit");
        Require(presentation.TargetDisplayLabel?.Contains('\n') == false, "sticky_presentation_label_newline");
        Require(presentation.TargetDisplayLabel?.Contains('\u202e') == false, "sticky_presentation_label_bidi");
        var encodedRequest = JsonSerializer.Serialize(deletePreparation.ApprovalRequest);
        Require(!encodedRequest.Contains(PrivatePresentationTitle, StringComparison.Ordinal), "sticky_presentation_not_in_request");
        Require(!encodedRequest.Contains(note.Id.ToString("D"), StringComparison.OrdinalIgnoreCase), "sticky_target_id_not_in_request");
        var deleteGrant = broker.DecideApproval(
            deletePreparation.ApprovalRequest!.Id,
            deletePreparation.PlanDigest,
            CapabilityApprovalDecision.Approve,
            deleteNow);
        var deleteReceipt = await broker.ExecuteAsync(deletePlan, deletePermissions, deleteGrant, deleteNow);
        Require(deleteReceipt.Status == CapabilityReceiptStatus.Succeeded, "sticky_delete_receipt");
        Require(
            deleteReceipt.Steps[0].Output?.GetProperty("state").GetString() == "missing",
            "sticky_delete_output");
        Require(deleteReceipt.Steps[0].Readback.Status == CapabilityReadbackStatus.Verified, "sticky_delete_readback");
        Require(store.GetNote(note.Id) is null, "sticky_delete_effect");

        var missingPlan = new CapabilityExecutionPlan(
            "sticky-delete-missing-plan",
            deleteNow.AddSeconds(1),
            CapabilityOrigin.Text,
            principal,
            null,
            [new CapabilityPlanStep(
                "deleteMissingNote",
                CapabilityIds.StickyDelete,
                CapabilityJson.From(new { noteId = note.Id }),
                "sticky-broker-delete-missing-key-0001",
                [])],
            new HashSet<string>(["sticky.delete"], StringComparer.Ordinal));
        var missingPreparation = broker.Prepare(missingPlan, deletePermissions, deleteNow.AddSeconds(1));
        Require(
            missingPreparation.ApprovalPresentations.Single().TargetState == CapabilityApprovalTargetState.Missing,
            "sticky_missing_presentation_state");
        Require(
            missingPreparation.ApprovalPresentations.Single().TargetDisplayLabel is null,
            "sticky_missing_presentation_label");

        var bodyOnlyNote = store.UpsertNote(
            "broker-body-only-presentation-fixture",
            " \n ",
            "Body fallback\n details",
            StickyNoteColor.Blue);
        var bodyOnlyNow = deleteNow.AddSeconds(2);
        var bodyOnlyPlan = new CapabilityExecutionPlan(
            "sticky-delete-body-only-plan",
            bodyOnlyNow,
            CapabilityOrigin.Text,
            principal,
            null,
            [new CapabilityPlanStep(
                "deleteBodyOnlyNote",
                CapabilityIds.StickyDelete,
                CapabilityJson.From(new { noteId = bodyOnlyNote.Id }),
                "sticky-broker-delete-body-only-key-0001",
                [])],
            new HashSet<string>(["sticky.delete"], StringComparer.Ordinal));
        var bodyOnlyPreparation = broker.Prepare(bodyOnlyPlan, deletePermissions, bodyOnlyNow);
        Require(
            bodyOnlyPreparation.ApprovalPresentations.Single().TargetDisplayLabel == "Body fallback details",
            "sticky_body_fallback_presentation_label");
        try
        {
            _ = broker.DecideApproval(
                bodyOnlyPreparation.ApprovalRequest!.Id,
                bodyOnlyPreparation.PlanDigest,
                CapabilityApprovalDecision.Reject,
                bodyOnlyNow);
            _failures.Add("sticky_body_fallback_reject_accepted");
        }
        catch (CapabilityBrokerException ex) when (ex.Code == "CAPABILITY_APPROVAL_REJECTED")
        {
        }
        Require(store.DeleteNoteAtomically(bodyOnlyNote.Id), "sticky_body_fallback_cleanup");
    }

    private void VerifyGoldenDigest(DateTimeOffset now)
    {
        var principal = new CapabilityPrincipal("user-broker-fixture");
        var plan = new CapabilityExecutionPlan(
            "digest-fixture-plan",
            now,
            CapabilityOrigin.Text,
            principal,
            null,
            [new CapabilityPlanStep(
                "startTimer",
                CapabilityIds.TimerStart,
                CapabilityJson.From(new { durationSeconds = 1_500, sourceRef = "primary:event", title = "Focus" }),
                "digest-fixture-timer-0001",
                [])],
            new HashSet<string>(["timer.write"], StringComparer.Ordinal));
        Require(CapabilityCanonicalJson.PlanDigest(plan) == GoldenPlanDigest, "golden_plan_digest");
    }

    private void VerifyCalendarIdempotencyEquivalence(DateTimeOffset now)
    {
        var fractionalStart = now.AddTicks(9_876_543);
        var draft = new CalendarEventDraft(
            "primary",
            null,
            " Verify event ",
            " Room A ",
            " Approved notes ",
            fractionalStart,
            fractionalStart.AddHours(1),
            false).Normalized();
        var observed = new CalendarEventOccurrence(
            "primary:event",
            "event",
            "primary",
            "Primary",
            null,
            true,
            draft.Title,
            draft.Location,
            draft.Notes,
            DateTimeOffset.FromUnixTimeSeconds(draft.Start.ToUnixTimeSeconds()),
            DateTimeOffset.FromUnixTimeSeconds(draft.End.ToUnixTimeSeconds()),
            draft.IsAllDay,
            null);
        Require(CalendarStore.CapabilityEventMatches(observed, draft), "calendar_idempotency_match");
        Require(
            !CalendarStore.CapabilityEventMatches(observed with { Location = "Room B" }, draft),
            "calendar_idempotency_location_mismatch");
        Require(
            !CalendarStore.CapabilityEventMatches(observed with { Notes = "Different notes" }, draft),
            "calendar_idempotency_notes_mismatch");
        Require(
            !CalendarStore.CapabilityEventMatches(observed with { Start = observed.Start.AddSeconds(1) }, draft),
            "calendar_idempotency_second_mismatch");

        var allDayDraft = new CalendarEventDraft(
            "primary",
            null,
            "All day",
            null,
            null,
            new DateTimeOffset(2026, 8, 15, 0, 0, 0, TimeSpan.FromHours(9)),
            new DateTimeOffset(2026, 8, 16, 0, 0, 0, TimeSpan.FromHours(9)),
            true).Normalized();
        var allDayObserved = new CalendarEventOccurrence(
            "primary:all-day",
            "all-day",
            "primary",
            "Primary",
            null,
            true,
            allDayDraft.Title,
            allDayDraft.Location,
            allDayDraft.Notes,
            new DateTimeOffset(2026, 8, 15, 0, 0, 0, TimeSpan.Zero),
            new DateTimeOffset(2026, 8, 16, 0, 0, 0, TimeSpan.Zero),
            true,
            null,
            new DateOnly(2026, 8, 15),
            new DateOnly(2026, 8, 16));
        Require(
            CalendarStore.CapabilityEventMatches(allDayObserved, allDayDraft),
            "calendar_idempotency_all_day_match");
    }

    private async Task VerifyPartialRollbackAsync(string root, DateTimeOffset now, CapabilityPrincipal principal)
    {
        using var timerStore = new TimerStore(
            Path.Combine(root, "partial-timer"),
            new ManualTimerClock(now),
            new NullTimerAlertSound(),
            enableScheduler: false);
        var handlers = new PocketCapabilityHandlerSet([
            new TimerCapabilityHandler(TimerCapabilityOperation.Start, timerStore),
            new TimerCapabilityHandler(TimerCapabilityOperation.Get, timerStore),
            new TimerCapabilityHandler(TimerCapabilityOperation.Stop, timerStore),
            new BrokerFailingStickyHandler()
        ]);
        var brokerRoot = Path.Combine(root, "partial-broker");
        var broker = new CapabilityBroker(
            new CapabilityRegistry(handlers),
            new CapabilityBrokerLedger(brokerRoot),
            new CapabilityBrokerAuditLog(brokerRoot));
        var permissions = Permissions(principal, "sticky.write", "timer.write");
        var adapter = new TodayFocusTextAdapter(broker);
        var draft = adapter.PrepareFocus(
            new TodayFocusCalendarEvent("event:partial", "Partial", now, now.AddMinutes(10)),
            600,
            "partial-secret",
            principal,
            permissions,
            now);
        var grant = broker.DecideApproval(
            draft.Preparation.ApprovalRequest!.Id,
            draft.Preparation.PlanDigest,
            CapabilityApprovalDecision.Approve,
            now);
        var receipt = await broker.ExecuteAsync(draft.Plan, permissions, grant, now);
        Require(receipt.Status == CapabilityReceiptStatus.Failed, "partial_compensated_status");
        Require(receipt.Steps.FirstOrDefault()?.RollbackStatus == "succeeded", "partial_timer_rollback");
        Require(timerStore.RunningTimers.Count == 0, "partial_timer_removed");
    }

    private async Task VerifyTimeoutAsync(string root, DateTimeOffset now, CapabilityPrincipal principal)
    {
        var key = new PocketCapabilityKey("verify.slow.read", 1);
        var descriptor = new PocketCapabilityDescriptor(
            key,
            "capability.verify.slow.read",
            CapabilityEffect.PrivateRead,
            ["verify.read"],
            CapabilityApprovalPolicy.PermissionGrant,
            CapabilityIdempotencyPolicy.Optional,
            new CapabilityLimits(10, 128, 10),
            new CapabilityReadbackPolicy(CapabilityReadbackStrategy.SameStoreSnapshot, null, ["value"]),
            false,
            value => CapabilitySchemaValidation.ExactKeys(value, []),
            value =>
            {
                CapabilitySchemaValidation.ExactKeys(value, ["value"]);
                _ = CapabilitySchemaValidation.String(value, "value", 0, 16);
            });
        var slowHandler = new BrokerSlowReadHandler(key);
        var handlers = new PocketCapabilityHandlerSet([slowHandler]);
        var brokerRoot = Path.Combine(root, "timeout-broker");
        var broker = new CapabilityBroker(
            new CapabilityRegistry(handlers, [descriptor]),
            new CapabilityBrokerLedger(brokerRoot),
            new CapabilityBrokerAuditLog(brokerRoot));
        var plan = new CapabilityExecutionPlan(
            "timeout-plan",
            now,
            CapabilityOrigin.Text,
            principal,
            null,
            [new CapabilityPlanStep("slowRead", key, CapabilityJson.From(new { }), "timeout-read-key-0001", [])],
            new HashSet<string>(["verify.read"], StringComparer.Ordinal));
        var receipt = await broker.ExecuteAsync(plan, Permissions(principal, "verify.read"), null, now);
        Require(receipt.Status == CapabilityReceiptStatus.Unknown, "timeout_status");
        Require(receipt.Steps.FirstOrDefault()?.SafeError?.Code == "CAPABILITY_TIMEOUT", "timeout_safe_error");
        Require(slowHandler.WasCancelled, "timeout_handler_cancelled");
    }

    private async Task VerifyCurrentStepRollbackAsync(
        string root,
        DateTimeOffset now,
        CapabilityPrincipal principal)
    {
        using var timerStore = new TimerStore(
            Path.Combine(root, "current-step-timer"),
            new ManualTimerClock(now),
            new NullTimerAlertSound(),
            enableScheduler: false);
        var handlers = new PocketCapabilityHandlerSet([
            new TimerCapabilityHandler(TimerCapabilityOperation.Start, timerStore),
            new BrokerMismatchedTimerReadHandler(timerStore),
            new TimerCapabilityHandler(TimerCapabilityOperation.Stop, timerStore)
        ]);
        var brokerRoot = Path.Combine(root, "current-step-broker");
        var broker = new CapabilityBroker(
            new CapabilityRegistry(handlers),
            new CapabilityBrokerLedger(brokerRoot),
            new CapabilityBrokerAuditLog(brokerRoot));
        var plan = new CapabilityExecutionPlan(
            "current-step-rollback-plan",
            now,
            CapabilityOrigin.Text,
            principal,
            null,
            [new CapabilityPlanStep(
                "startTimer",
                CapabilityIds.TimerStart,
                CapabilityJson.From(new { durationSeconds = 600, sourceRef = "event:current-step", title = "Current step" }),
                "current-step-timer-key-0001",
                [])],
            new HashSet<string>(["timer.write"], StringComparer.Ordinal));
        var permissions = Permissions(principal, "timer.write");
        var preparation = broker.Prepare(plan, permissions, now);
        var grant = broker.DecideApproval(
            preparation.ApprovalRequest!.Id,
            preparation.PlanDigest,
            CapabilityApprovalDecision.Approve,
            now);
        var receipt = await broker.ExecuteAsync(plan, permissions, grant, now);
        Require(receipt.Status == CapabilityReceiptStatus.Failed, "current_step_status");
        Require(receipt.Steps.FirstOrDefault()?.RollbackStatus == "succeeded", "current_step_rollback");
        Require(timerStore.RunningTimers.Count == 0, "current_step_timer_removed");
    }

    private async Task VerifyCancellationRollbackAsync(
        string root,
        DateTimeOffset now,
        CapabilityPrincipal principal)
    {
        using var timerStore = new TimerStore(
            Path.Combine(root, "cancel-rollback-timer"),
            new ManualTimerClock(now),
            new NullTimerAlertSound(),
            enableScheduler: false);
        using var cancellation = new CancellationTokenSource();
        var handlers = new PocketCapabilityHandlerSet([
            new TimerCapabilityHandler(TimerCapabilityOperation.Start, timerStore),
            new BrokerCancellingTimerReadHandler(timerStore, cancellation),
            new TimerCapabilityHandler(TimerCapabilityOperation.Stop, timerStore)
        ]);
        var brokerRoot = Path.Combine(root, "cancel-rollback-broker");
        var broker = new CapabilityBroker(
            new CapabilityRegistry(handlers),
            new CapabilityBrokerLedger(brokerRoot),
            new CapabilityBrokerAuditLog(brokerRoot));
        var plan = new CapabilityExecutionPlan(
            "cancel-rollback-plan",
            now,
            CapabilityOrigin.Text,
            principal,
            null,
            [new CapabilityPlanStep(
                "startTimer",
                CapabilityIds.TimerStart,
                CapabilityJson.From(new { durationSeconds = 600, sourceRef = "event:cancel", title = "Cancel rollback" }),
                "cancel-rollback-key-0001",
                [])],
            new HashSet<string>(["timer.write"], StringComparer.Ordinal));
        var permissions = Permissions(principal, "timer.write");
        var preparation = broker.Prepare(plan, permissions, now);
        var grant = broker.DecideApproval(
            preparation.ApprovalRequest!.Id,
            preparation.PlanDigest,
            CapabilityApprovalDecision.Approve,
            now);
        var receipt = await broker.ExecuteAsync(plan, permissions, grant, now, cancellation.Token);
        Require(receipt.Status == CapabilityReceiptStatus.Unknown, "cancel_rollback_status");
        Require(receipt.Steps.FirstOrDefault()?.RollbackStatus == "succeeded", "cancel_rollback_succeeded");
        Require(timerStore.RunningTimers.Count == 0, "cancel_rollback_timer_removed");
    }

    private async Task VerifyCancellationAfterSuccessfulStepAsync(
        string root,
        DateTimeOffset now,
        CapabilityPrincipal principal)
    {
        using var timerStore = new TimerStore(
            Path.Combine(root, "cancel-after-step-timer"),
            new ManualTimerClock(now),
            new NullTimerAlertSound(),
            enableScheduler: false);
        using var cancellation = new CancellationTokenSource();
        var sticky = new BrokerCountingStickyUpsertHandler();
        var handlers = new PocketCapabilityHandlerSet([
            new TimerCapabilityHandler(TimerCapabilityOperation.Start, timerStore),
            new BrokerPostReadCancellationTimerReadHandler(timerStore, cancellation),
            new TimerCapabilityHandler(TimerCapabilityOperation.Stop, timerStore),
            sticky
        ]);
        var brokerRoot = Path.Combine(root, "cancel-after-step-broker");
        var broker = new CapabilityBroker(
            new CapabilityRegistry(handlers),
            new CapabilityBrokerLedger(brokerRoot),
            new CapabilityBrokerAuditLog(brokerRoot));
        var permissions = Permissions(principal, "sticky.write", "timer.write");
        var adapter = new TodayFocusTextAdapter(broker);
        var draft = adapter.PrepareFocus(
            new TodayFocusCalendarEvent("event:cancel-after-step", "Cancel after step", now, now.AddMinutes(10)),
            600,
            "cancel-after-step",
            principal,
            permissions,
            now);
        var grant = broker.DecideApproval(
            draft.Preparation.ApprovalRequest!.Id,
            draft.Preparation.PlanDigest,
            CapabilityApprovalDecision.Approve,
            now);
        var receipt = await broker.ExecuteAsync(draft.Plan, permissions, grant, now, cancellation.Token);
        Require(receipt.Status == CapabilityReceiptStatus.Failed, "cancel_after_step_status");
        if (receipt.Steps.Count != 2)
        {
            var statuses = string.Join(",", receipt.Steps.Select(step =>
                $"{step.Capability.Id}:{step.Status}:{step.Readback.Status}:{step.SafeError?.Code ?? "none"}"));
            _failures.Add($"cancel_after_step_receipts:{receipt.Steps.Count}:{statuses}");
            return;
        }
        Require(receipt.Steps[0].Status == CapabilityReceiptStatus.Succeeded, "cancel_after_step_first_succeeded");
        Require(receipt.Steps[0].RollbackStatus == "succeeded", "cancel_after_step_rollback_succeeded");
        Require(receipt.Steps[1].Status == CapabilityReceiptStatus.Failed, "cancel_after_step_second_failed");
        Require(receipt.Steps[1].SafeError?.Code == "CAPABILITY_CANCELLED", "cancel_after_step_safe_error");
        Require(sticky.InvocationCount == 0, "cancel_after_step_no_sticky_write");
        Require(timerStore.RunningTimers.Count == 0, "cancel_after_step_timer_removed");

        var replay = await broker.ExecuteAsync(draft.Plan, permissions, null, now.AddSeconds(1));
        Require(replay.Replayed && replay.Status == CapabilityReceiptStatus.Failed, "cancel_after_step_durable_replay");
    }

    private static CapabilityPermissionSet Permissions(CapabilityPrincipal principal, params string[] permissions) =>
        new(principal, new HashSet<string>(permissions, StringComparer.Ordinal));

    private static CapabilityExecutionPlan ReplacePurpose(CapabilityExecutionPlan plan, string purpose)
    {
        var steps = plan.Steps.Select(step => step.Capability == CapabilityIds.StickyUpsert
            ? step with
            {
                Arguments = CapabilityJson.From(new
                {
                    stableKey = step.Arguments.GetProperty("stableKey").GetString(),
                    title = step.Arguments.GetProperty("title").GetString(),
                    body = purpose,
                    color = step.Arguments.GetProperty("color").GetString()
                })
            }
            : step).ToArray();
        return plan with { Steps = steps };
    }

    private void Require(bool condition, string label)
    {
        if (!condition)
        {
            _failures.Add(label);
        }
    }

    private sealed class BrokerFakeCalendarDataSource(DateTimeOffset now) : ICalendarCapabilityDataSource
    {
        private readonly CalendarCapabilityEvent _event = new(
            "primary:sensitive-event-ref",
            "sensitive-event-id",
            "Sensitive Calendar Title",
            now.AddMinutes(10),
            now.AddHours(1));

        public Task<IReadOnlyList<CalendarCapabilityEvent>> ListEventsAsync(
            DateTimeOffset start,
            DateTimeOffset end,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            IReadOnlyList<CalendarCapabilityEvent> result = _event.Start < end && _event.End > start ? [_event] : [];
            return Task.FromResult(result);
        }

        public Task<CalendarCapabilityEvent?> GetEventAsync(string eventRef, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return Task.FromResult(eventRef == _event.EventRef ? _event : null);
        }

        public Task<CalendarCapabilityEvent> CreateEventAsync(
            CalendarCapabilityCreateRequest request,
            string idempotencyKey,
            CancellationToken cancellationToken)
        {
            _ = request;
            _ = idempotencyKey;
            cancellationToken.ThrowIfCancellationRequested();
            return Task.FromResult(_event);
        }
    }

    private sealed class BrokerFailingStickyHandler : IPocketCapabilityHandler
    {
        public PocketCapabilityKey Key => CapabilityIds.StickyUpsert;

        public Task<JsonElement> HandleAsync(
            JsonElement arguments,
            CapabilityHandlerContext context,
            CancellationToken cancellationToken = default)
        {
            _ = arguments;
            _ = context.RequireIdempotencyKey();
            cancellationToken.ThrowIfCancellationRequested();
            throw new CapabilityHandlerException("CAPABILITY_UNAVAILABLE", "sticky_storage");
        }
    }

    private sealed class BrokerSlowReadHandler(PocketCapabilityKey key) : IPocketCapabilityHandler
    {
        private int _wasCancelled;

        public PocketCapabilityKey Key { get; } = key;

        public bool WasCancelled => Volatile.Read(ref _wasCancelled) == 1;

        public async Task<JsonElement> HandleAsync(
            JsonElement arguments,
            CapabilityHandlerContext context,
            CancellationToken cancellationToken = default)
        {
            _ = arguments;
            _ = context;
            try
            {
                await Task.Delay(TimeSpan.FromSeconds(30), cancellationToken);
            }
            catch (OperationCanceledException)
            {
                Volatile.Write(ref _wasCancelled, 1);
                throw;
            }
            return CapabilityJson.From(new { value = "late" });
        }
    }

    private sealed class BrokerBlockingTimerStartHandler : IPocketCapabilityHandler
    {
        private int _wasCancelled;

        public PocketCapabilityKey Key => CapabilityIds.TimerStart;

        public TaskCompletionSource<bool> Entered { get; } = new(
            TaskCreationOptions.RunContinuationsAsynchronously);

        public bool WasCancelled => Volatile.Read(ref _wasCancelled) == 1;

        public async Task<JsonElement> HandleAsync(
            JsonElement arguments,
            CapabilityHandlerContext context,
            CancellationToken cancellationToken = default)
        {
            _ = arguments;
            _ = context.RequireIdempotencyKey();
            Entered.TrySetResult(true);
            try
            {
                await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
            }
            catch (OperationCanceledException)
            {
                Volatile.Write(ref _wasCancelled, 1);
                throw;
            }
            throw new InvalidOperationException("unreachable");
        }
    }

    private sealed class BrokerCountingStickyUpsertHandler : IPocketCapabilityHandler
    {
        private int _invocationCount;

        public PocketCapabilityKey Key => CapabilityIds.StickyUpsert;

        public int InvocationCount => Volatile.Read(ref _invocationCount);

        public Task<JsonElement> HandleAsync(
            JsonElement arguments,
            CapabilityHandlerContext context,
            CancellationToken cancellationToken = default)
        {
            _ = arguments;
            _ = context.RequireIdempotencyKey();
            cancellationToken.ThrowIfCancellationRequested();
            Interlocked.Increment(ref _invocationCount);
            return Task.FromResult(CapabilityJson.From(new
            {
                noteId = Guid.Empty,
                state = "active",
                updatedAt = DateTimeOffset.UnixEpoch.ToString("O", CultureInfo.InvariantCulture)
            }));
        }
    }

    private sealed class BrokerMismatchedTimerReadHandler(TimerStore store) : IPocketCapabilityHandler
    {
        public PocketCapabilityKey Key => CapabilityIds.TimerGet;

        public Task<JsonElement> HandleAsync(
            JsonElement arguments,
            CapabilityHandlerContext context,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var rawId = CapabilityJson.RequiredString(arguments, "timerId", 36);
            if (!Guid.TryParse(rawId, out var id))
            {
                throw new CapabilityHandlerException("CAPABILITY_ARGUMENT_INVALID", "timerId");
            }
            return Task.FromResult(store.GetRunningTimer(id) is null
                ? CapabilityJson.From(new { timerId = rawId.ToLowerInvariant(), state = "stopped", endAt = (string?)null })
                : CapabilityJson.From(new
                {
                    timerId = rawId.ToLowerInvariant(),
                    state = "running",
                    endAt = CapabilityCanonicalJson.Date(context.Now.AddSeconds(999))
                }));
        }
    }

    private sealed class BrokerCancellingTimerReadHandler(
        TimerStore store,
        CancellationTokenSource callerCancellation) : IPocketCapabilityHandler
    {
        public PocketCapabilityKey Key => CapabilityIds.TimerGet;

        public Task<JsonElement> HandleAsync(
            JsonElement arguments,
            CapabilityHandlerContext context,
            CancellationToken cancellationToken = default)
        {
            callerCancellation.Cancel();
            cancellationToken.ThrowIfCancellationRequested();
            var rawId = CapabilityJson.RequiredString(arguments, "timerId", 36);
            if (!Guid.TryParse(rawId, out var id))
            {
                throw new CapabilityHandlerException("CAPABILITY_ARGUMENT_INVALID", "timerId");
            }
            return Task.FromResult(store.GetRunningTimer(id) is null
                ? CapabilityJson.From(new { timerId = rawId.ToLowerInvariant(), state = "stopped", endAt = (string?)null })
                : CapabilityJson.From(new
                {
                    timerId = rawId.ToLowerInvariant(),
                    state = "running",
                    endAt = CapabilityCanonicalJson.Date(context.Now.AddMinutes(10))
                }));
        }
    }

    private sealed class BrokerPostReadCancellationTimerReadHandler(
        TimerStore store,
        CancellationTokenSource callerCancellation) : IPocketCapabilityHandler
    {
        public PocketCapabilityKey Key => CapabilityIds.TimerGet;

        public Task<JsonElement> HandleAsync(
            JsonElement arguments,
            CapabilityHandlerContext context,
            CancellationToken cancellationToken = default)
        {
            _ = cancellationToken;
            var rawId = CapabilityJson.RequiredString(arguments, "timerId", 36);
            if (!Guid.TryParse(rawId, out var id))
            {
                throw new CapabilityHandlerException("CAPABILITY_ARGUMENT_INVALID", "timerId");
            }
            var timer = store.GetRunningTimer(id);
            callerCancellation.Cancel();
            return Task.FromResult(timer is null
                ? CapabilityJson.From(new { timerId = rawId.ToLowerInvariant(), state = "stopped", endAt = (string?)null })
                : CapabilityJson.From(new
                {
                    timerId = rawId.ToLowerInvariant(),
                    state = "running",
                    endAt = timer.EndAtUtc.ToString("O", CultureInfo.InvariantCulture)
                }));
        }
    }
}
