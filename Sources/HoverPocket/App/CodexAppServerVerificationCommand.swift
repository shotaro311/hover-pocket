import AVFoundation
import Darwin
import Foundation

enum CodexAppServerVerificationCommand {
    static func run() -> Never {
        Task {
            do {
                try await verify()
                print("codex_app_server_verify=ok")
                print("codex_app_server_initialize=ok")
                print("codex_app_server_malformed_isolation=ok")
                print("codex_app_server_server_request_fail_closed=ok")
                print("codex_app_server_timeout_recovery=ok")
                print("codex_app_server_process_cleanup=ok")
                print("codex_voice_runtime_default_off=ok")
                print("codex_voice_runtime_enable_disable=ok")
                print("codex_voice_runtime_view_model_binding=ok")
                print("codex_voice_microphone_policy=ok")
                print("codex_voice_webrtc_negotiation=ok")
                print("codex_voice_webrtc_epoch=ok")
                print("codex_voice_sdp_attempt_isolation=ok")
                print("codex_voice_restart_cancellation=ok")
                print("codex_voice_tool_dispatch=ok")
                print("codex_voice_root_scoped_sessions=ok")
                Darwin.exit(0)
            } catch {
                fputs("codex_app_server_verify=failed\n", stderr)
                fputs("error=\(String(describing: error))\n", stderr)
                Darwin.exit(1)
            }
        }
        RunLoop.main.run()
        Darwin.exit(1)
    }

    private static func verify() async throws {
        try require(
            CodexAppServerClientOptions.defaultLaunchArguments == [
                "-c",
                "features.realtime_conversation=true",
                "app-server",
                "--stdio"
            ],
            "production_realtime_feature_override"
        )
        let recorder = CodexAppServerVerificationRecorder()
        let client = try await CodexAppServerClient.start(
            options: CodexAppServerClientOptions(
                executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                launchArguments: ["-u", "-c", fakeServerScript],
                requestTimeout: 2,
                clientVersion: "verify",
                experimentalAPI: true
            )
        )
        let processID = await client.processIdentifier
        guard let processID, processID > 0 else {
            throw CodexAppServerVerificationFailure("process_id")
        }

        await client.setNotificationHandler { notification in
            Task { await recorder.record(notification) }
        }
        await client.setTransportEndedHandler { reason in
            Task { await recorder.recordTransportEnd(reason) }
        }

        let echo = try await client.sendRequest(
            "verify/echo",
            params: .object(["value": .string("hello")])
        )
        try require(echo.objectValue?["value"]?.stringValue == "hello", "echo_response")
        let metricsAfterEcho = await client.metrics()
        try require(metricsAfterEcho.malformedOutputLines == 1, "malformed_count")
        try require(metricsAfterEcho.unknownResponses == 1, "unknown_response_count")

        _ = try await client.sendRequest("verify/notify")
        try await waitUntil("notification") {
            await recorder.notificationMethods().contains("verify/notification")
        }

        let serverRequest = try await client.sendRequest("verify/server-request")
        try require(
            serverRequest.objectValue?["code"]?.integerValue == -32601,
            "server_request_reply"
        )
        let metricsAfterServerRequest = await client.metrics()
        try require(metricsAfterServerRequest.unhandledServerRequests == 1, "unhandled_request_count")

        do {
            _ = try await client.sendRequest("verify/timeout")
            throw CodexAppServerVerificationFailure("timeout_not_enforced")
        } catch CodexAppServerClientError.requestTimedOut(let method) {
            try require(method == "verify/timeout", "timeout_method")
        }

        let recovered = try await client.sendRequest(
            "verify/echo",
            params: .object(["value": .string("after-timeout")])
        )
        try require(
            recovered.objectValue?["value"]?.stringValue == "after-timeout",
            "timeout_recovery"
        )

        _ = try await client.sendRequest("verify/exit")
        try await waitUntil("transport_end") {
            await recorder.transportEndedCount() == 1
        }
        await client.close()
        try await waitUntil("process_cleanup") {
            Darwin.kill(processID, 0) != 0
        }

        try await verifyRuntimeHost()
        try await verifyStaleSDPIsolation()
        try await verifyRestartCancellation()
    }

    @MainActor
    private static func verifyRuntimeHost() async throws {
        try require(
            CodexVoiceAppServerLaunchPolicy.arguments == [
                "-c",
                "features.realtime_conversation=true",
                "app-server",
                "--stdio"
            ],
            "realtime_feature_process_scoped"
        )
        let model = VoiceLaneViewModel()
        let toolAdapter = CodexVoiceVerificationToolAdapter()
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("HoverPocketVoiceRuntimeVerify-\(UUID().uuidString)")
        let host = CodexVoiceRuntimeHost(
            viewModel: model,
            workspaceDirectory: workspace,
            clientFactory: {
                try await CodexAppServerClient.start(
                    options: CodexAppServerClientOptions(
                        executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                        launchArguments: ["-u", "-c", fakeServerScript],
                        requestTimeout: 5,
                        clientVersion: "verify",
                        experimentalAPI: true
                    )
                )
            },
            toolAdapter: toolAdapter
        )

        try require(host.snapshot.availability == .disabled, "runtime_default_off")
        try require(model.availability == .disabled, "runtime_model_default_off")

        await host.setEnabled(true)
        guard host.snapshot.availability == .ready else {
            throw CodexAppServerVerificationFailure(
                "runtime_ready:\(host.snapshot.availability.rawValue):\(host.snapshot.lastErrorCode ?? "none")"
            )
        }
        try require(host.snapshot.voiceCount == 1, "runtime_voice_count")
        try require(model.availability == .ready, "runtime_model_ready")
        try require(model.statusText == "ready", "runtime_model_status")
        guard let processID = host.snapshot.appServerProcessID, processID > 0 else {
            throw CodexAppServerVerificationFailure("runtime_process_id")
        }

        let now = Date()
        try require(!host.beginMicrophoneRequest(now: now), "microphone_requires_visible_panel")
        host.setPanelVisible(true)
        try require(host.beginMicrophoneRequest(now: now), "microphone_arm")
        try require(host.consumeMicrophonePermission(now: now), "microphone_consume")
        try require(!host.consumeMicrophonePermission(now: now), "microphone_single_use")
        try require(host.beginMicrophoneRequest(now: now), "microphone_rearm")
        try require(
            !host.consumeMicrophonePermission(now: now.addingTimeInterval(6)),
            "microphone_arm_expiry"
        )
        try require(
            CodexVoiceMediaPermissionPolicy.shouldAllow(
                scheme: "hoverpocket-voice",
                host: "local",
                port: 0,
                frameURL: URL(string: "hoverpocket-voice://local/index.html"),
                isMainFrame: true,
                microphoneOnly: true,
                armed: true
            ),
            "microphone_exact_origin"
        )
        try require(
            !CodexVoiceMediaPermissionPolicy.shouldAllow(
                scheme: "hoverpocket-voice",
                host: "other",
                port: 0,
                frameURL: URL(string: "hoverpocket-voice://other/index.html"),
                isMainFrame: true,
                microphoneOnly: true,
                armed: true
            ),
            "microphone_wrong_origin_denied"
        )
        try require(
            !CodexVoiceMediaPermissionPolicy.shouldAllow(
                scheme: "hoverpocket-voice",
                host: "local",
                port: 0,
                frameURL: URL(string: "hoverpocket-voice://local/index.html"),
                isMainFrame: true,
                microphoneOnly: false,
                armed: true
            ),
            "camera_denied"
        )
        try require(
            CodexVoiceSystemMicrophoneAuthorizationPolicy.decision(for: .authorized) == .proceed,
            "system_microphone_authorized"
        )
        try require(
            CodexVoiceSystemMicrophoneAuthorizationPolicy.decision(for: .notDetermined) == .request,
            "system_microphone_request"
        )
        try require(
            CodexVoiceSystemMicrophoneAuthorizationPolicy.decision(for: .denied) == .deny
                && CodexVoiceSystemMicrophoneAuthorizationPolicy.decision(for: .restricted) == .deny,
            "system_microphone_denied"
        )

        let answer = try await host.startWebRTC(
            sdpOffer: "v=0\r\ns=fake-offer\r\n"
        )
        try require(answer.rootThreadID == "root-thread", "runtime_root_thread")
        try require(answer.sdp == "v=0\r\ns=fake-answer\r\n", "runtime_sdp_answer")
        try await waitUntil("runtime_root_scoped_sessions") {
            await MainActor.run {
                model.sessions.count == 5
                    && model.sessions.first(where: { $0.id == "thread:child-a" })?.detail
                        == "実装を進めています"
            }
        }
        try require(
            model.sessions.map(\.id) == [
                "root:root-thread",
                "thread:paged-child",
                "thread:current-root",
                "thread:grandchild-a",
                "thread:child-a"
            ],
            "runtime_session_scope"
        )
        try require(
            !model.sessions.contains(where: {
                [
                    "thread:foreign-child",
                    "thread:orphan",
                    "thread:duplicate",
                    "thread:duplicate-child"
                ].contains($0.id)
            }),
            "runtime_cross_root_session_rejected"
        )
        try require(
            Set(model.sessions.map(\.id)).count == model.sessions.count,
            "runtime_session_ids_unique"
        )
        try require(
            model.sessions.first(where: { $0.id == "thread:child-a" })?.detail
                == "実装を進めています",
            "runtime_session_recent_message"
        )
        try require(
            model.sessions.first(where: { $0.id == "thread:paged-child" })?.detail
                == "2ページ目を取得しました",
            "runtime_session_pagination"
        )
        try require(
            model.sessions.first(where: { $0.id == "thread:grandchild-a" })?.detail == "検証中",
            "runtime_cross_root_readback_rejected"
        )
        try require(
            model.sessions.first(where: { $0.id == "thread:child-a" })?.state == .running
                && model.sessions.first(where: { $0.id == "thread:grandchild-a" })?.state
                    == .completed,
            "runtime_session_state"
        )
        try await waitUntil("runtime_tool_dispatch") {
            await MainActor.run { toolAdapter.callCount == 1 }
        }
        try require(toolAdapter.lastContext?.rootThreadID == "root-thread", "runtime_tool_root")
        try require((toolAdapter.lastContext?.clientGeneration ?? 0) > 0, "runtime_tool_generation")
        host.markTransportAttached()
        try require(host.snapshot.transportAttached, "runtime_transport_attached")
        try require(host.snapshot.sessionStatus == .connected, "runtime_connected")
        host.setMuted(true)
        try require(host.snapshot.sessionStatus == .muted, "runtime_muted")
        await host.stopRealtime()
        try require(host.snapshot.sessionStatus == .closed, "runtime_stopped")
        try require(host.snapshot.lastErrorCode == nil, "runtime_expected_stop_not_error")

        await host.setEnabled(false)
        try require(host.snapshot.availability == .disabled, "runtime_disabled")
        try require(model.availability == .disabled, "runtime_model_disabled")
        try await waitUntil("runtime_process_cleanup") {
            Darwin.kill(processID, 0) != 0
        }

        await host.dispose()
    }

    @MainActor
    private static func verifyStaleSDPIsolation() async throws {
        try require(
            CodexVoiceWebRTCEmbeddedContract.verifyOperationEpoch(),
            "webrtc_operation_epoch_contract"
        )
        let coordinator = CodexVoiceCoordinator(
            featureEnabled: true,
            workspaceDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("HoverPocketVoiceSDPVerify-\(UUID().uuidString)"),
            restartDelaysNanoseconds: [],
            sdpTimeoutNanoseconds: 40_000_000,
            clientFactory: {
                try await CodexAppServerClient.start(
                    options: CodexAppServerClientOptions(
                        executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                        launchArguments: ["-u", "-c", staleSDPServerScript],
                        requestTimeout: 2,
                        clientVersion: "verify",
                        experimentalAPI: true
                    )
                )
            }
        )
        await coordinator.initialize()
        try require(coordinator.snapshot.availability == .ready, "sdp_isolation_ready")

        let oversizedOffer = "v=0\r\n" + String(repeating: "あ", count: 50_000)
        do {
            _ = try await coordinator.startWebRTC(sdpOffer: oversizedOffer)
            throw CodexAppServerVerificationFailure("sdp_utf8_limit_not_enforced")
        } catch CodexVoiceRuntimeError.compatibility(let code) {
            try require(code == "webrtc_offer_invalid", "sdp_utf8_limit_code")
        }

        let firstAttempt = Task { @MainActor in
            try await coordinator.startWebRTC(sdpOffer: "v=0\r\ns=first-offer\r\n")
        }
        try await waitUntil("sdp_first_attempt_pending") {
            await MainActor.run { coordinator.snapshot.sessionStatus == .negotiating }
        }
        do {
            _ = try await coordinator.startWebRTC(sdpOffer: "v=0\r\ns=overlap\r\n")
            throw CodexAppServerVerificationFailure("sdp_overlap_not_rejected")
        } catch CodexVoiceRuntimeError.compatibility(let code) {
            try require(code == "webrtc_negotiation_in_progress", "sdp_overlap_code")
        }
        do {
            _ = try await firstAttempt.value
            throw CodexAppServerVerificationFailure("sdp_timeout_missing")
        } catch CodexVoiceRuntimeError.sdpTimedOut {
        }
        try require(
            coordinator.snapshot.lastErrorCode == "sdp_timed_out",
            "sdp_timeout_error_code"
        )
        try require(coordinator.snapshot.rootThreadID == nil, "sdp_failed_root_invalidated")

        let answer = try await coordinator.startWebRTC(
            sdpOffer: "v=0\r\ns=second-offer\r\n"
        )
        try require(answer.rootThreadID == "root-thread-2", "sdp_new_root")
        try require(answer.sdp.contains("fresh-answer"), "sdp_stale_answer_rejected")
        await coordinator.close()
    }

    @MainActor
    private static func verifyRestartCancellation() async throws {
        let recorder = CodexVoiceClientFactoryRecorder()
        let coordinator = CodexVoiceCoordinator(
            featureEnabled: true,
            restartDelaysNanoseconds: [2_000_000_000],
            clientFactory: {
                await recorder.recordStart()
                return try await CodexAppServerClient.start(
                    options: CodexAppServerClientOptions(
                        executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                        launchArguments: ["-u", "-c", exitAfterInitializationServerScript],
                        requestTimeout: 2,
                        clientVersion: "verify",
                        experimentalAPI: true
                    )
                )
            }
        )
        await coordinator.initialize()
        try await waitUntil("restart_backoff_started") {
            await MainActor.run { coordinator.snapshot.restartAttempt == 1 }
        }
        await coordinator.close()
        try await Task.sleep(nanoseconds: 100_000_000)
        let startCount = await recorder.startCount()
        try require(startCount == 1, "restart_cancelled_before_spawn")
        try require(coordinator.snapshot.availability == .disabled, "restart_close_disabled")
    }

    private static func waitUntil(
        _ name: String,
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        for _ in 0..<250 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw CodexAppServerVerificationFailure(name)
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ name: String) throws {
        guard condition() else { throw CodexAppServerVerificationFailure(name) }
    }

    private static let fakeServerScript = #"""
import json
import sys

pending_server_request = None
child_read_attempts = 0
for raw in sys.stdin:
    try:
        message = json.loads(raw)
    except Exception:
        continue

    method = message.get("method")
    request_id = message.get("id")
    if method == "initialize":
        print(json.dumps({"id": request_id, "result": {"server": "fake"}}), flush=True)
    elif method == "initialized":
        continue
    elif method == "account/read":
        if message.get("params") != {"refreshToken": False}:
            print(json.dumps({"id": request_id, "error": {"code": -32602, "message": "invalid account params"}}), flush=True)
            continue
        print(json.dumps({"id": request_id, "result": {"requiresOpenaiAuth": False, "account": {}}}), flush=True)
    elif method == "thread/realtime/listVoices":
        if message.get("params") != {}:
            print(json.dumps({"id": request_id, "error": {"code": -32602, "message": "invalid voices params"}}), flush=True)
            continue
        print(json.dumps({"id": request_id, "result": {"voices": {"available": ["alloy"], "defaultV1": "alloy"}}}), flush=True)
    elif method == "thread/start":
        params = message.get("params") or {}
        if not params.get("dynamicTools"):
            print(json.dumps({"id": request_id, "error": {"code": -32602, "message": "dynamic tools required"}}), flush=True)
            continue
        print(json.dumps({"id": request_id, "result": {"thread": {"id": "root-thread", "sessionId": "session-a", "createdAt": 1700000000}}}), flush=True)
    elif method == "thread/list":
        params = message.get("params") or {}
        expected_sources = ["appServer", "subAgent", "subAgentReview", "subAgentCompact", "subAgentThreadSpawn", "subAgentOther"]
        cursor = params.get("cursor")
        if params.get("ancestorThreadId") != "root-thread" or params.get("archived") is not False or params.get("limit") != 64 or params.get("sourceKinds") != expected_sources or params.get("sortDirection") != "asc" or params.get("sortKey") != "created_at" or params.get("useStateDbOnly") is not True or cursor not in (None, "page-2"):
            print(json.dumps({"id": request_id, "error": {"code": -32602, "message": "invalid thread list params"}}), flush=True)
            continue
        if cursor is None:
            data = [
                {"id": "child-a", "sessionId": "session-a", "parentThreadId": "root-thread", "name": "Today Focusを作成", "preview": "古い要約", "status": {"type": "active", "activeFlags": []}, "createdAt": 1700000010, "updatedAt": 1700000030},
                {"id": "grandchild-a", "sessionId": "session-a", "parentThreadId": "child-a", "name": "予定を整理", "preview": "検証中", "status": {"type": "idle"}, "createdAt": 1700000020, "updatedAt": 1700000040},
                {"id": "foreign-child", "sessionId": "session-b", "parentThreadId": "root-thread", "name": "別root", "preview": "表示禁止", "status": {"type": "active", "activeFlags": []}, "createdAt": 1700000020, "updatedAt": 1700000050},
                {"id": "orphan", "sessionId": "session-a", "parentThreadId": "other-root", "name": "孤立", "preview": "表示禁止", "status": {"type": "active", "activeFlags": []}, "createdAt": 1700000020, "updatedAt": 1700000060}
            ]
            next_cursor = "page-2"
        else:
            data = [
                {"id": "current-root", "sessionId": "session-a", "parentThreadId": "root-thread", "name": "予約語に似た子", "preview": "衝突なし", "status": {"type": "idle"}, "createdAt": 1700000050, "updatedAt": 1700000070},
                {"id": "paged-child", "sessionId": "session-a", "parentThreadId": "root-thread", "name": "2ページ目", "preview": "取得中", "status": {"type": "active", "activeFlags": []}, "createdAt": 1700000060, "updatedAt": 1700000080},
                {"id": "duplicate", "sessionId": "session-a", "parentThreadId": "root-thread", "name": "重複1", "preview": "表示禁止", "status": {"type": "active", "activeFlags": []}, "createdAt": 1700000060, "updatedAt": 1700000090},
                {"id": "duplicate", "sessionId": "session-a", "parentThreadId": "root-thread", "name": "重複2", "preview": "表示禁止", "status": {"type": "systemError"}, "createdAt": 1700000060, "updatedAt": 1700000100},
                {"id": "duplicate-child", "sessionId": "session-a", "parentThreadId": "duplicate", "name": "重複配下", "preview": "表示禁止", "status": {"type": "idle"}, "createdAt": 1700000070, "updatedAt": 1700000110}
            ]
            next_cursor = None
        print(json.dumps({"id": request_id, "result": {"data": data, "nextCursor": next_cursor}}), flush=True)
    elif method == "thread/read":
        params = message.get("params") or {}
        thread_id = params.get("threadId")
        if params.get("includeTurns") is not True or thread_id not in ("child-a", "grandchild-a", "current-root", "paged-child"):
            print(json.dumps({"id": request_id, "error": {"code": -32602, "message": "invalid thread read params"}}), flush=True)
            continue
        if thread_id == "child-a":
            child_read_attempts += 1
            if child_read_attempts == 1:
                print(json.dumps({"id": request_id, "error": {"code": -32000, "message": "retry child read"}}), flush=True)
                continue
            items = [{"id": "message-1", "type": "agentMessage", "text": "実装を進めています"}]
        elif thread_id == "paged-child":
            items = [{"id": "message-page", "type": "agentMessage", "text": "2ページ目を取得しました"}]
        elif thread_id == "current-root":
            items = []
        else:
            items = [{"id": "message-2", "type": "userMessage", "content": [{"type": "text", "text": "検証が完了しました"}]}]
        parent_id = "child-a" if thread_id == "grandchild-a" else "root-thread"
        read_session_id = "session-b" if thread_id == "grandchild-a" else "session-a"
        print(json.dumps({"id": request_id, "result": {"thread": {"id": thread_id, "sessionId": read_session_id, "parentThreadId": parent_id, "turns": [{"id": "turn-1", "status": "completed", "items": items}]}}}), flush=True)
    elif method == "thread/realtime/start":
        params = message.get("params") or {}
        transport = params.get("transport") or {}
        if params.get("threadId") != "root-thread" or params.get("outputModality") != "audio" or params.get("version") != "v3" or params.get("includeStartupContext") is not False or transport.get("type") != "webrtc" or not transport.get("sdp", "").startswith("v=0"):
            print(json.dumps({"id": request_id, "error": {"code": -32602, "message": "invalid realtime params"}}), flush=True)
            continue
        print(json.dumps({"id": request_id, "result": {}}), flush=True)
        print(json.dumps({"method": "thread/realtime/started", "params": {"threadId": "root-thread", "realtimeSessionId": "fake-realtime", "version": "v3"}}), flush=True)
        print(json.dumps({"method": "thread/realtime/sdp", "params": {"threadId": "root-thread", "sdp": "v=0\r\ns=fake-answer\r\n"}}), flush=True)
        print(json.dumps({"id": "tool-1", "method": "item/tool/call", "params": {"threadId": "root-thread"}}), flush=True)
    elif method == "thread/realtime/stop":
        print(json.dumps({"id": request_id, "result": {}}), flush=True)
        print(json.dumps({"method": "thread/realtime/closed", "params": {"threadId": "root-thread", "reason": None}}), flush=True)
    elif method == "verify/echo":
        print("not-json", flush=True)
        print(json.dumps({"id": 999999, "result": {}}), flush=True)
        print(json.dumps({"id": request_id, "result": message.get("params") or {}}), flush=True)
    elif method == "verify/notify":
        print(json.dumps({"method": "verify/notification", "params": {"ok": True}}), flush=True)
        print(json.dumps({"id": request_id, "result": {}}), flush=True)
    elif method == "verify/server-request":
        pending_server_request = request_id
        print(json.dumps({"id": "server-1", "method": "unsupported/request", "params": {}}), flush=True)
    elif request_id == "server-1" and pending_server_request is not None:
        code = ((message.get("error") or {}).get("code"))
        print(json.dumps({"id": pending_server_request, "result": {"code": code}}), flush=True)
        pending_server_request = None
    elif method == "verify/timeout":
        continue
    elif method == "verify/exit":
        print(json.dumps({"id": request_id, "result": {}}), flush=True)
        break
    elif request_id == "tool-1":
        continue
    elif request_id is not None:
        print(json.dumps({"id": request_id, "error": {"code": -32601, "message": "unsupported"}}), flush=True)
"""#

    private static let staleSDPServerScript = #"""
import json
import sys
import time

thread_count = 0
start_count = 0
for raw in sys.stdin:
    try:
        message = json.loads(raw)
    except Exception:
        continue
    method = message.get("method")
    request_id = message.get("id")
    if method == "initialize":
        print(json.dumps({"id": request_id, "result": {"server": "fake"}}), flush=True)
    elif method == "initialized":
        continue
    elif method == "account/read":
        print(json.dumps({"id": request_id, "result": {"requiresOpenaiAuth": False, "account": {}}}), flush=True)
    elif method == "thread/realtime/listVoices":
        print(json.dumps({"id": request_id, "result": {"voices": {"available": ["alloy"], "defaultV1": "alloy"}}}), flush=True)
    elif method == "thread/start":
        thread_count += 1
        if thread_count == 1:
            time.sleep(0.08)
        print(json.dumps({"id": request_id, "result": {"thread": {"id": f"root-thread-{thread_count}", "sessionId": f"session-{thread_count}", "createdAt": 1700000000 + thread_count}}}), flush=True)
    elif method == "thread/realtime/start":
        start_count += 1
        thread_id = (message.get("params") or {}).get("threadId")
        print(json.dumps({"id": request_id, "result": {}}), flush=True)
        if start_count == 2:
            print(json.dumps({"method": "thread/realtime/sdp", "params": {"threadId": "root-thread-1", "sdp": "v=0\r\ns=stale-answer\r\n"}}), flush=True)
            print(json.dumps({"method": "thread/realtime/sdp", "params": {"threadId": thread_id, "sdp": "v=0\r\ns=fresh-answer\r\n"}}), flush=True)
    elif request_id is not None:
        print(json.dumps({"id": request_id, "error": {"code": -32601, "message": "unsupported"}}), flush=True)
"""#

    private static let exitAfterInitializationServerScript = #"""
import json
import sys
import time

for raw in sys.stdin:
    try:
        message = json.loads(raw)
    except Exception:
        continue
    method = message.get("method")
    request_id = message.get("id")
    if method == "initialize":
        print(json.dumps({"id": request_id, "result": {"server": "fake"}}), flush=True)
    elif method == "initialized":
        continue
    elif method == "account/read":
        print(json.dumps({"id": request_id, "result": {"requiresOpenaiAuth": False, "account": {}}}), flush=True)
    elif method == "thread/realtime/listVoices":
        print(json.dumps({"id": request_id, "result": {"voices": {"available": ["alloy"], "defaultV1": "alloy"}}}), flush=True)
        time.sleep(0.08)
        break
    elif request_id is not None:
        print(json.dumps({"id": request_id, "error": {"code": -32601, "message": "unsupported"}}), flush=True)
"""#
}

private actor CodexAppServerVerificationRecorder {
    private var notifications: [String] = []
    private var transportEnds: [String] = []

    func record(_ notification: CodexAppServerNotification) {
        notifications.append(notification.method)
    }

    func recordTransportEnd(_ reason: String) {
        transportEnds.append(reason)
    }

    func notificationMethods() -> [String] {
        notifications
    }

    func transportEndedCount() -> Int {
        transportEnds.count
    }
}

private actor CodexVoiceClientFactoryRecorder {
    private var count = 0

    func recordStart() {
        count += 1
    }

    func startCount() -> Int {
        count
    }
}

@MainActor
private final class CodexVoiceVerificationToolAdapter: CodexVoiceCapabilityToolAdapterProtocol {
    private(set) var callCount = 0
    private(set) var lastContext: CodexVoiceToolRequestContext?

    let dynamicTools: [CodexJSONValue] = [
        .object([
            "type": .string("function"),
            "name": .string("hoverpocket_verify"),
            "description": .string("Verification tool"),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([:]),
                "required": .array([]),
                "additionalProperties": .bool(false)
            ]),
            "deferLoading": .bool(false)
        ])
    ]

    func handle(
        request: CodexAppServerRequest,
        context: CodexVoiceToolRequestContext
    ) async -> CodexAppServerReply {
        guard request.method == "item/tool/call" else {
            return .failure(code: -32601, message: "unsupported")
        }
        callCount += 1
        lastContext = context
        return .success(.object(["success": .bool(true)]))
    }
}

private struct CodexAppServerVerificationFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
