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
    }

    @MainActor
    private static func verifyRuntimeHost() async throws {
        let model = VoiceLaneViewModel()
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
                        requestTimeout: 2,
                        clientVersion: "verify",
                        experimentalAPI: true
                    )
                )
            }
        )

        try require(host.snapshot.availability == .disabled, "runtime_default_off")
        try require(model.availability == .disabled, "runtime_model_default_off")

        await host.setEnabled(true)
        try require(host.snapshot.availability == .ready, "runtime_ready")
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

        let answer = try await host.startWebRTC(
            sdpOffer: "v=0\r\ns=fake-offer\r\n"
        )
        try require(answer.rootThreadID == "root-thread", "runtime_root_thread")
        try require(answer.sdp == "v=0\r\ns=fake-answer\r\n", "runtime_sdp_answer")
        host.markTransportAttached()
        try require(host.snapshot.transportAttached, "runtime_transport_attached")
        try require(host.snapshot.sessionStatus == .connected, "runtime_connected")
        host.setMuted(true)
        try require(host.snapshot.sessionStatus == .muted, "runtime_muted")
        await host.stopRealtime()
        try require(host.snapshot.sessionStatus == .closed, "runtime_stopped")

        await host.setEnabled(false)
        try require(host.snapshot.availability == .disabled, "runtime_disabled")
        try require(model.availability == .disabled, "runtime_model_disabled")
        try await waitUntil("runtime_process_cleanup") {
            Darwin.kill(processID, 0) != 0
        }

        await host.dispose()
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
        print(json.dumps({"id": request_id, "result": {"thread": {"id": "root-thread"}}}), flush=True)
    elif method == "thread/realtime/start":
        params = message.get("params") or {}
        transport = params.get("transport") or {}
        if params.get("threadId") != "root-thread" or params.get("outputModality") != "audio" or transport.get("type") != "webrtc" or not transport.get("sdp", "").startswith("v=0"):
            print(json.dumps({"id": request_id, "error": {"code": -32602, "message": "invalid realtime params"}}), flush=True)
            continue
        print(json.dumps({"id": request_id, "result": {}}), flush=True)
        print(json.dumps({"method": "thread/realtime/started", "params": {"threadId": "root-thread", "realtimeSessionId": "fake-realtime", "version": "v1"}}), flush=True)
        print(json.dumps({"method": "thread/realtime/sdp", "params": {"threadId": "root-thread", "sdp": "v=0\r\ns=fake-answer\r\n"}}), flush=True)
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

private struct CodexAppServerVerificationFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
