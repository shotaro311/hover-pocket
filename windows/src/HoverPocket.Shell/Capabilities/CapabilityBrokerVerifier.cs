using System.Globalization;
using System.Text;
using System.Text.Json;
using HoverPocket.Shell.Configuration;
using HoverPocket.Shell.Providers.Sticky;
using HoverPocket.Shell.Providers.Timer;

namespace HoverPocket.Shell.Capabilities;

internal sealed class CapabilityBrokerVerifier
{
    private const string GoldenPlanDigest = "sha256:d098ea1b5f9f70e91486fd53229e7ddb68f73a9952ab94f17eed27cdeeb6413f";
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
        Console.WriteLine("broker_registry_descriptors=11");
        Console.WriteLine("broker_available_handlers=10");
        Console.WriteLine("broker_today_focus=ok");
        Console.WriteLine("broker_concurrent_duplicate=ok");
        Console.WriteLine("broker_negative_cases=10");
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
                audit);

            Require(registry.DescriptorKeys.Count == 11, "registry_descriptor_count");
            Require(registry.AvailableHandlerKeys.Count == 10, "registry_handler_count");
            Require(!new UserSettings().AiNativeEnabled, "feature_default_off");
            VerifyGoldenDigest(now);

            try
            {
                _ = registry.Resolve(CapabilityIds.NativeAuthority);
                _failures.Add("native_authority_resolved");
            }
            catch (CapabilityBrokerException ex) when (ex.Code == "CAPABILITY_RUNTIME_PROHIBITED")
            {
            }

            var principal = new CapabilityPrincipal("user-broker-fixture");
            var allPermissions = Permissions(principal, "calendar.events.read", "sticky.write", "timer.write");
            var adapter = new TodayFocusTextAdapter(broker);
            var events = await adapter.ListTodayAsync("UTC", principal, allPermissions, now);
            Require(events.Count == 1, "calendar_read");
            Require(events[0].EventRef == "primary:sensitive-event-ref", "calendar_event_ref");

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
                principal.UserId
            })
            {
                Require(!auditText.Contains(forbidden, StringComparison.Ordinal), $"audit_redaction_{forbidden}");
            }
            Require(auditText.Contains("principal:sha256:", StringComparison.Ordinal), "audit_principal_digest");
            Require(auditText.Contains("\"idempotencyReplay\":true", StringComparison.Ordinal), "audit_replay");

            await VerifyPartialRollbackAsync(root, now, principal);
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
        var handlers = new PocketCapabilityHandlerSet([new BrokerSlowReadHandler(key)]);
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
        public PocketCapabilityKey Key { get; } = key;

        public async Task<JsonElement> HandleAsync(
            JsonElement arguments,
            CapabilityHandlerContext context,
            CancellationToken cancellationToken = default)
        {
            _ = arguments;
            _ = context;
            await Task.Delay(100, cancellationToken);
            return CapabilityJson.From(new { value = "late" });
        }
    }
}
