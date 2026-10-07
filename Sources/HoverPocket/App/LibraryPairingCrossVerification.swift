import Foundation

// Explicit isolated-test entry point. Stdout is a private protocol for the SSH parent,
// never a diagnostics log; it carries short-lived codes and approval IDs.
@MainActor
enum LibraryPairingCrossVerification {
    struct Configuration: Decodable {
        let root: String
        let source: String
        let helper: String
        let syncthingConfig: String
        let deviceId: String
    }
    static func run() async throws {
        guard let index = CommandLine.arguments.firstIndex(of: "--pairing-config"), index + 1 < CommandLine.arguments.count else { throw failure }
        let configURL = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        try AssetLibraryStore.noLinks(configURL)
        let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: configURL))
        let root = URL(fileURLWithPath: config.root).resolvingSymlinksInPath()
        guard ["/private/tmp/HoverPocket-PairingCross-", "/tmp/HoverPocket-PairingCross-"].contains(where: root.path.hasPrefix), configURL.deletingLastPathComponent().resolvingSymlinksInPath() == root,
              try String(contentsOf: root.appendingPathComponent("isolated-test"), encoding: .utf8) == "HoverPocket pairing verification\n" else { throw failure }
        let syncthingConfig = URL(fileURLWithPath: config.syncthingConfig)
        try AssetLibraryStore.noLinks(syncthingConfig)
        guard syncthingConfig.resolvingSymlinksInPath().path.hasPrefix(root.path + "/syncthing/"),
              let gui = LibrarySyncGUIConfiguration.read(try Data(contentsOf: syncthingConfig)) else { throw failure }
        let client = try LibrarySyncthingClient(endpoint: gui.endpoint, apiKey: gui.key)
        guard try await client.deviceID() == config.deviceId else { throw failure }
        let store = try AssetLibraryStore(root: root.appendingPathComponent("library"), contractRoot: URL(fileURLWithPath: config.source).appendingPathComponent("shared/asset-library"))
        try await store.start()
        let controller = LibraryDevicePairingController(store: { store }, client: { _ in client }, helper: { try LibraryPairingHelperProcess(executable: URL(fileURLWithPath: config.helper), start: $0) }, transport: root.appendingPathComponent("transport"), deviceName: "Mac isolated verifier")
        let pair = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(16))
        let reader = LibraryPairingLineReader(handle: .standardInput, continuation: pair.continuation)
        DispatchQueue.global(qos: .utility).async { reader.read() }
        var finished = false
        let input = Task {
            do {
                for try await line in pair.stream {
                    guard let command = try JSONSerialization.jsonObject(with: line) as? [String: String] else { throw failure }
                    switch command["action"] {
                    case "start":
                        guard ["invite", "join"].contains(command["role"]), !controller.busy else { throw failure }
                        if command["role"] == "join" { guard command["code"] != nil else { throw failure } }
                        controller.start(code: command["role"] == "join" ? command["code"] : nil)
                    case "approve":
                        guard let id = command["approvalId"], id == controller.approvalID else { throw failure }
                        controller.approve()
                    case "cancel": await controller.shutdown(); emit(["event": "cancelled"])
                    case "fixture":
                        guard !controller.busy else { throw failure }
                        let fixture = root.appendingPathComponent("mac-pairing-fixture.txt")
                        if !FileManager.default.fileExists(atPath: fixture.path) {
                            try Data("HoverPocket isolated Mac pairing fixture\n".utf8).write(to: fixture)
                        }
                        let result = try await store.importFile(fixture)
                        emit(["event": "imported", "status": result.status])
                    case "sync":
                        let status = try await store.syncOnce()
                        let page = try await store.query(LibraryQuery())
                        for asset in page.items { _ = try await store.path(asset, verifyHash: true) }
                        if !status.folder.isEmpty {
                            let id = try await client.folderID(for: URL(fileURLWithPath: status.folder))
                            try await client.scan(folderID: id)
                        }
                        emit(["event": "synced", "groupId": try await store.syncMeta("group") ?? "", "enabled": status.enabled, "pending": status.pending,
                              "conflicts": status.conflicts.count, "validOriginals": true,
                              "assets": page.items.map { ["Id": $0.id, "Name": $0.name, "Sha256": $0.sha256, "Favorite": $0.favorite] as [String: Any] }])
                    case "unlink":
                        await controller.refreshDevices()
                        guard let peer = controller.devices.first else { throw failure }
                        await controller.remove(peer)
                        guard controller.issue == nil, controller.devices.isEmpty else { throw failure }
                        emit(["event": "unlinked"])
                    case "exit": finished = true; return
                    default: throw failure
                    }
                }
                finished = true
            } catch { emit(["event": "error", "reason": "verification_input_failed"]); finished = true }
        }
        emit(["event": "ready"])
        var lastCode = "", lastPeer = "", sentComplete = false
        while !finished {
            if controller.busy { sentComplete = false }
            if !controller.code.isEmpty && controller.code != lastCode {
                lastCode = controller.code; emit(["event": "code", "code": lastCode])
            }
            if let peer = controller.peer, let id = controller.approvalID, id != lastPeer {
                lastPeer = id; emit(["event": "peer", "approvalId": id, "verification": controller.verification, "platform": peer.platform])
            }
            if controller.phase == .complete && !sentComplete { emit(["event": "complete"]); sentComplete = true }
            if controller.phase == .failed { emit(["event": "error", "reason": controller.issue ?? "connection_failed"]); finished = true }
            if sentComplete { _ = try await store.syncOnce() }
            try await Task.sleep(for: .milliseconds(100))
        }
        await controller.shutdown(); input.cancel(); pair.continuation.finish()
    }
    static func emit(_ value: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: value, options: .sortedKeys) else { return }
        data.append(10); try? FileHandle.standardOutput.write(contentsOf: data)
    }
    private static var failure: LibraryError { .message("isolated_pairing_verification_failed") }
}
