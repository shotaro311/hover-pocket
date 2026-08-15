using System.Globalization;
using System.Text;
using System.Text.Json;
using HoverPocket.Shell.Configuration;
using HoverPocket.Shell.Providers.Calendar;
using HoverPocket.Shell.Providers.Sticky;
using HoverPocket.Shell.Providers.Timer;

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
            Console.Error.WriteLine("broker_verify=failed");
            foreach (var failure in _failures)
            {
                Console.Error.WriteLine($"failure={failure}");
            }
            return 1;
        }

        Console.WriteLine("broker_verify=ok");
        Console.WriteLine("broker_registry_descriptors=15");
        Console.WriteLine("broker_available_handlers=14");
        Console.WriteLine("broker_calculator_evaluate=ok");
        Console.WriteLine("broker_sticky_lifecycle=ok");
        Console.WriteLine("broker_approval_presentation=ok");
        Console.WriteLine("broker_today_focus=ok");
        Console.WriteLine("broker_concurrent_duplicate=ok");
        Console.WriteLine("broker_negative_cases=12");
        Console.WriteLine($"broker_golden_plan_digest={GoldenPlanDigest}");
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
            var handlers = ProviderCapabilityCompositionRoot.Create(calendar, timerStore, stickyStore);
            var registry = new CapabilityRegistry(handlers);
            var brokerRoot = Path.Combine(root, "broker");
            var audit = new CapabilityBrokerAuditLog(brokerRoot);
            var broker = new CapabilityBroker(
                registry,
                new CapabilityBrokerLedger(brokerRoot),
                audit,
                approvalPresentationResolver: new HostCapabilityApprovalPresentationResolver(stickyStore));

            Require(registry.DescriptorKeys.Count == 15, "registry_descriptor_count");
            Require(registry.AvailableHandlerKeys.Count == 14, "registry_handler_count");
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
            await VerifyStickyLifecycleAsync(broker, stickyStore, now);

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

            await VerifyPartialRollbackAsync(root, now, principal);
            await VerifyCurrentStepRollbackAsync(root, now, principal);
            await VerifyCancellationRollbackAsync(root, now, principal);
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
                await Task.Delay(100, cancellationToken);
            }
            catch (OperationCanceledException)
            {
                Volatile.Write(ref _wasCancelled, 1);
                throw;
            }
            return CapabilityJson.From(new { value = "late" });
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
}
