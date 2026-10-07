import Foundation

@MainActor
enum LibraryPairingSessionVerification {
    static func run() async throws {
        let source = CommandLine.arguments.firstIndex(of: "--asset-source-root").map { CommandLine.arguments[$0 + 1] } ?? FileManager.default.currentDirectoryPath
        let contract = URL(fileURLWithPath: source).appendingPathComponent("shared/asset-library")
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("HoverPocket-PairingSession-" + UUID().uuidString)
        var checks = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw LibraryError.message("pairing_session_check_" + label) }; checks += 1
        }
        for mode in ["success", "join", "cancel", "shutdown", "early", "stale", "mismatch", "eof", "timeout", "failure", "existing_paused_failure", "cancel_applied"] {
            let directory = root.appendingPathComponent(mode + "/transport")
            let local = try AssetLibraryStore(root: root.appendingPathComponent(mode + "/library"), contractRoot: contract)
            let group = UUID().uuidString.lowercased()
            try LibraryDevicePairingController.prepareMarker(directory, group: group, write: true)
            try await local.configureSync(folder: directory, create: false)
            try await local.pauseSync()
            let state = PairingVerificationProtocol.state; state.reset(directory: directory.path)
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [PairingVerificationProtocol.self]
            let client = try LibrarySyncthingClient(endpoint: URL(string: "http://127.0.0.1:8384")!, apiKey: "fictional", configuration: config)
            if mode == "existing_paused_failure" {
                _ = try await client.addPeer(PairingVerificationState.peer, name: "Ignored", folderID: "hoverpocket-test", directory: directory)
            }
            let before = state.snapshot()
            let helper = PairingSessionFake(mode: mode)
            let controller = LibraryDevicePairingController(store: { local }, client: { _ in client }, helper: { helper.start($0); return helper }, transport: root.appendingPathComponent("unused"), deviceName: "Test Mac", timeout: .seconds(mode == "timeout" ? 0.15 : 5))
            if mode == "cancel_applied" { helper.onApplied = { [weak controller] in controller?.cancel() } }
            controller.start(code: mode == "join" ? "1-12345678" : nil)
            // An invalid helper must never pass the host's approval gate.
            if ["early", "timeout"].contains(mode) { await controller.waitUntilFinished() }
            else {
                try await wait { controller.peer != nil || !controller.busy }
                let beforeApproval = try await local.syncStatus()
                if mode != "join" { try check(state.snapshot().folder == before.folder && !beforeApproval.enabled, mode + "_no_write_before_approval") }
                if mode == "cancel" { controller.cancel() }
                else if mode == "shutdown" { await controller.shutdown() }
                else if mode != "join" { controller.approve(); controller.approve() }
                await controller.waitUntilFinished()
            }
            let after = state.snapshot(), status = try await local.syncStatus()
            try check(!controller.busy && helper.stopped && controller.code.isEmpty && controller.expiresAt == nil, mode + "_session_cleaned")
            try check(after.eagle == before.eagle && after.devices == before.devices, mode + "_unrelated_settings_preserved")
            if ["success", "join"].contains(mode) {
                try check(controller.phase == .complete && status.enabled, mode + "_complete_after_readback")
                try check((after.folder["devices"] as? [[String: Any]])?.count == 2, mode + "_shared")
                try check(helper.decisions == 1, mode + "_single_decision")
                try await client.removePeer(PairingVerificationState.peer, folderID: "hoverpocket-test", directory: directory)
                try check(state.snapshot().folder == before.folder, mode + "_remove_only_membership")
            } else {
                try check(controller.phase != .complete && !status.enabled, mode + "_failed_restores_paused")
                try check(after.folder == before.folder, mode + "_rollback_membership")
            }
        }
        // Keep stdin open: this catches a pipe reader that waits for 4096 bytes or EOF.
        let echo = try LibraryPairingHelperProcess(executable: URL(fileURLWithPath: "/bin/cat"), start: ["probe": "live"])
        let stopEcho = Task { try? await Task.sleep(for: .seconds(2)); echo.stop() }
        var receivedWhileOpen = false
        for try await line in echo.events {
            receivedWhileOpen = (try JSONSerialization.jsonObject(with: line) as? [String: String])?["probe"] == "live"
            break
        }
        stopEcho.cancel(); echo.stop()
        try check(receivedWhileOpen, "short_pipe_message_arrives_before_eof")
        let foreign = root.appendingPathComponent("foreign")
        try LibraryDevicePairingController.prepareMarker(foreign, group: UUID().uuidString.lowercased(), write: true)
        try check((try? LibraryDevicePairingController.prepareMarker(foreign, group: UUID().uuidString.lowercased(), write: false)) == nil, "foreign_marker_rejected")
        let link = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: foreign)
        try check((try? LibraryDevicePairingController.prepareMarker(link, group: UUID().uuidString.lowercased(), write: false)) == nil, "symlink_rejected")
        print("library_pairing_sessions=ok checks=\(checks) (isolated stores and fake helper; real libraries untouched)")
    }

    static func wait(_ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(6)
        while !condition() {
            guard Date() < deadline else { throw LibraryError.message("pairing_session_wait_timeout") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
private final class PairingSessionFake: LibraryPairingHelper {
    let events: AsyncThrowingStream<Data, Error>
    let continuation: AsyncThrowingStream<Data, Error>.Continuation
    let mode: String
    var onApplied: (() -> Void)?
    var stopped = false
    var decisions = 0
    private var approved: [String: Any] = [:]
    private let approval = String(repeating: "a", count: 64)
    init(mode: String) {
        self.mode = mode
        let pair = AsyncThrowingStream<Data, Error>.makeStream(); events = pair.stream; continuation = pair.continuation
    }
    func start(_ value: [String: String]) {
        if mode == "timeout" { return }
        let peer: [String: Any] = ["version": 1, "role": value["role"] == "invite" ? "join" : "invite", "nonce": UUID().uuidString.lowercased(), "deviceId": PairingVerificationState.peer, "deviceName": "Other PC", "platform": "windows", "groupId": value["groupId"]!, "folderId": value["folderId"]!]
        approved = ["event": "approved", "approvalId": approval, "peer": peer, "groupId": value["groupId"]!, "folderId": value["folderId"]!]
        if mode == "early" { emit(approved); return }
        var event = approved; event["event"] = "peer"; event["verification"] = "ABCDEF01"; emit(event)
    }
    func send(_ value: [String: String]) throws {
        if ["approve", "ready"].contains(value["action"]) {
            decisions += 1
            if mode == "eof" { continuation.finish(); return }
            var event = approved
            if mode == "stale" { event["approvalId"] = String(repeating: "b", count: 64) }
            if mode == "mismatch" { event["groupId"] = UUID().uuidString.lowercased() }
            emit(event)
        } else if value["action"] == "applied" {
            onApplied?()
            if ["failure", "existing_paused_failure"].contains(mode) { emit(["event": "error", "reason": "peer_setup_failed"]) }
            else { emit(["event": "complete", "approvalId": approval]) }
        }
    }
    func stop() { stopped = true; continuation.finish() }
    private func emit(_ value: [String: Any]) { continuation.yield(try! JSONSerialization.data(withJSONObject: value)) }
}
