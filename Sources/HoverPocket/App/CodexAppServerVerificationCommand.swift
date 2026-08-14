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
                requestTimeout: 0.25,
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
    }

    private static func waitUntil(
        _ name: String,
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        for _ in 0..<100 {
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
