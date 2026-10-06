import Foundation
import SwiftUI

@MainActor
final class LibraryDevicePairingController: ObservableObject {
    enum Phase { case idle, starting, waiting, review, applying, complete, cancelled, failed }
    static let shared = LibraryDevicePairingController(
        store: { try await AssetLibraryRuntime.shared.store() },
        client: { try await LibrarySyncthingClient.discover(folder: $0) },
        helper: { try LibraryPairingHelperProcess(executable: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/hoverpocket-pairing"), start: $0) },
        transport: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/HoverPocket/SyncTransport"),
        deviceName: Host.current().localizedName ?? "Mac"
    )
    @Published private(set) var phase = Phase.idle
    @Published private(set) var busy = false
    @Published var joinInput = ""
    @Published private(set) var code = ""
    @Published private(set) var peer: LibraryPairingPeer?
    @Published private(set) var verification = ""
    @Published private(set) var expiresAt: Date?
    @Published private(set) var issue: String?
    @Published private(set) var devices: [LibraryLinkedDevice] = []
    @Published private(set) var deviceIssue = false
    @Published private(set) var inviting = false
    private let getStore: () async throws -> AssetLibraryStore
    private let getClient: (String?) async throws -> LibrarySyncthingClient
    private let makeHelper: ([String: String]) throws -> any LibraryPairingHelper
    private let transport: URL
    private let deviceName: String
    private let timeout: Duration
    private var task: Task<Void, Never>?
    private var helper: (any LibraryPairingHelper)?
    private var cancelled = false
    private(set) var approvalID: String?
    private var accepted = false
    private var nextAttempt = Date.distantPast

    init(store: @escaping () async throws -> AssetLibraryStore,
         client: @escaping (String?) async throws -> LibrarySyncthingClient,
         helper: @escaping ([String: String]) throws -> any LibraryPairingHelper,
         transport: URL, deviceName: String, timeout: Duration = .seconds(300)) {
        getStore = store; getClient = client; makeHelper = helper
        self.transport = transport; self.deviceName = deviceName; self.timeout = timeout
    }

    func start(code joinCode: String? = nil) {
        guard !busy else { return }
        guard Date() >= nextAttempt else { issue = "retry_soon"; return }
        let trimmed = joinCode?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, trimmed.range(of: "^[0-9]{1,10}-[0-9]{8}$", options: .regularExpression) == nil {
            issue = "invalid_code"; phase = .failed; return
        }
        joinInput = ""
        busy = true; cancelled = false; accepted = false; approvalID = nil
        inviting = trimmed == nil; code = ""; peer = nil; verification = ""; issue = nil
        expiresAt = Date().addingTimeInterval(300); phase = .starting
        task = Task { await run(joinCode: trimmed) }
    }

    func approve() {
        guard busy, phase == .review, inviting, !cancelled, !accepted,
              let approvalID, let expiresAt, Date() < expiresAt else { return }
        do {
            try helper?.send(["action": "approve", "approvalId": approvalID])
            accepted = true; phase = .waiting
        } catch { cancel() }
    }

    func cancel() {
        joinInput = ""
        guard busy else { return }
        cancelled = true; code = ""; approvalID = nil; expiresAt = nil
        helper?.stop()
        // Do not cancel the Task: its rollback requests must still be allowed to finish.
    }

    func shutdown() async { cancel(); await task?.value }
    func waitUntilFinished() async { await task?.value }

    func refreshDevices() async {
        guard !busy else { return }
        do {
            let store = try await getStore(), status = try await store.syncStatus()
            guard !status.folder.isEmpty else { devices = []; deviceIssue = false; return }
            let client = try await getClient(status.folder)
            let folderID = try await client.folderID(for: URL(fileURLWithPath: status.folder))
            devices = try await client.linkedDevices(folderID: folderID); deviceIssue = false
        } catch { deviceIssue = true }
    }

    func remove(_ device: LibraryLinkedDevice) async {
        guard !busy else { return }; busy = true
        do {
            let store = try await getStore(), status = try await store.syncStatus()
            guard !status.folder.isEmpty else { throw invalidProtocol }
            let directory = URL(fileURLWithPath: status.folder), client = try await getClient(status.folder)
            let folderID = try await client.folderID(for: directory)
            try await client.removePeer(device.id, folderID: folderID, directory: directory)
            issue = nil
        } catch { issue = "remove_failed" }
        busy = false
        await refreshDevices()
    }

    private func run(joinCode: String?) async {
        var store: AssetLibraryStore?
        var client: LibrarySyncthingClient?
        var change: LibrarySyncthingClient.ShareChange?
        var wasEnabled = false
        var configured = false
        var completed = false
        let deadline = Task { [weak self] in
            do { try await Task.sleep(for: self?.timeout ?? .seconds(300)) } catch { return }
            guard let self, self.busy else { return }
            self.issue = "timeout"; self.cancel()
        }
        defer {
            deadline.cancel(); helper?.stop(); helper = nil
            code = ""; approvalID = nil; expiresAt = nil
            busy = false; task = nil; nextAttempt = Date().addingTimeInterval(3)
        }
        do {
            let local = try await getStore(); store = local
            let before = try await local.syncStatus(); wasEnabled = before.enabled
            let api = try await getClient(before.folder.isEmpty ? nil : before.folder); client = api
            let deviceID = try await api.deviceID()
            var group = try await local.syncMeta("group")
            var folderID: String?
            var directory: URL?
            if !before.folder.isEmpty {
                directory = URL(fileURLWithPath: before.folder)
                folderID = try await api.folderID(for: directory!)
                guard let group, LibraryFormat.validID(group) else { throw invalidProtocol }
            } else {
                guard group == nil else { throw invalidProtocol }
                if inviting { group = UUID().uuidString.lowercased(); folderID = "hoverpocket-library-" + group! }
            }
            var start = ["role": inviting ? "invite" : "join", "deviceId": deviceID,
                         "deviceName": String(deviceName.filter { !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }.prefix(80)), "platform": "macos"]
            if start["deviceName"]?.isEmpty != false { start["deviceName"] = "Mac" }
            start["code"] = joinCode; start["groupId"] = group; start["folderId"] = folderID
            try ensureActive()
            let process = try makeHelper(start); helper = process; phase = .waiting
            for try await line in process.events {
                try ensureActive()
                let event = try JSONDecoder().decode(LibraryPairingEvent.self, from: line)
                switch event.event {
                case "code":
                    guard inviting, peer == nil, code.isEmpty, let value = event.code,
                          value.range(of: "^[0-9]{1,10}-[0-9]{8}$", options: .regularExpression) != nil,
                          event.expiresInSeconds == 300 else { throw invalidProtocol }
                    code = value
                case "peer":
                    guard peer == nil, let candidate = event.peer, let id = event.approvalId,
                          id.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                          let check = event.verification, check.range(of: "^[A-F0-9]{8}$", options: .regularExpression) != nil,
                          let agreedGroup = event.groupId, LibraryFormat.validID(agreedGroup),
                          let agreedFolder = event.folderId, LibrarySyncthingClient.validFolderID(agreedFolder),
                          candidate.version == 1, candidate.role == (inviting ? "join" : "invite"),
                          LibraryFormat.validID(candidate.nonce), LibrarySyncthingClient.validDeviceID(candidate.deviceId), candidate.deviceId != deviceID,
                          ["macos", "windows"].contains(candidate.platform), !candidate.deviceName.isEmpty, candidate.deviceName.count <= 80,
                          !candidate.deviceName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                          group == nil || group == agreedGroup, folderID == nil || folderID == agreedFolder,
                          (candidate.groupId == nil && candidate.folderId == nil && inviting) || (candidate.groupId == agreedGroup && candidate.folderId == agreedFolder) else { throw invalidProtocol }
                    group = agreedGroup; folderID = agreedFolder
                    if directory == nil { directory = transport.appendingPathComponent(agreedGroup) }
                    try Self.prepareMarker(directory!, group: agreedGroup, write: false)
                    peer = candidate; verification = check; approvalID = id
                    if inviting { phase = .review }
                    else { try process.send(["action": "ready", "approvalId": id]); accepted = true; phase = .waiting }
                case "approved":
                    guard accepted, !configured, let id = approvalID, event.approvalId == id,
                          event.peer == peer, event.groupId == group, event.folderId == folderID,
                          let peer, let directory, let group, let folderID else { throw invalidProtocol }
                    phase = .applying
                    try Self.prepareMarker(directory, group: group, write: true)
                    change = try await api.addPeer(peer.deviceId, name: peer.deviceName, folderID: folderID, directory: directory)
                    try ensureActive()
                    try await local.configureSync(folder: directory, create: false); configured = true
                    try ensureActive()
                    let readback = try await local.syncStatus()
                    guard readback.enabled, readback.folder == directory.resolvingSymlinksInPath().path else { throw invalidProtocol }
                    try process.send(["action": "applied", "approvalId": id])
                case "complete":
                    guard configured, event.approvalId == approvalID else { throw invalidProtocol }
                    completed = true; phase = .complete
                    return
                case "error": throw LibraryPairingFailure(reason: event.reason ?? "connection_failed")
                default: throw invalidProtocol
                }
            }
            throw LibraryPairingFailure(reason: "connection_closed")
        } catch {
            if !completed {
                var rollbackFailed = false
                // Restore the previous pause even if peer membership already existed.
                if configured && !wasEnabled, let store {
                    do { try await store.pauseSync() } catch { rollbackFailed = true }
                }
                if let change, let client {
                    do { try await client.rollback(change) } catch { rollbackFailed = true }
                }
                if rollbackFailed { issue = "rollback_failed"; phase = .failed }
                else if cancelled { phase = issue == "timeout" ? .failed : .cancelled }
                else { issue = (error as? LibraryPairingFailure)?.reason ?? "connection_failed"; phase = .failed }
            }
        }
    }

    private func ensureActive() throws {
        guard !cancelled else { throw CancellationError() }
        guard let expiresAt, Date() < expiresAt else { throw LibraryPairingFailure(reason: "timeout") }
    }
    private var invalidProtocol: LibraryPairingFailure { .init(reason: "invalid_protocol") }

    static func prepareMarker(_ directory: URL, group: String, write: Bool) throws {
        try AssetLibraryStore.noLinks(directory)
        let marker = directory.appendingPathComponent("hoverpocket-sync.json")
        try AssetLibraryStore.noLinks(marker)
        if FileManager.default.fileExists(atPath: marker.path) {
            guard (try FileManager.default.attributesOfItem(atPath: marker.path)[.size] as? NSNumber)?.intValue ?? Int.max < 4096 else { throw LibraryPairingFailure(reason: "different_library") }
            let value = try JSONDecoder().decode(LibrarySyncMarker.self, from: Data(contentsOf: marker))
            guard value.version == 1, value.groupId == group else { throw LibraryPairingFailure(reason: "different_library") }
        } else {
            if FileManager.default.fileExists(atPath: directory.path) {
                guard try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy({ [".stfolder", ".stignore", ".DS_Store"].contains($0) }) else { throw LibraryPairingFailure(reason: "different_library") }
            }
            if write {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try AssetLibraryStore.writeSyncFile(JSONEncoder().encode(LibrarySyncMarker(version: 1, groupId: group)), to: marker)
            }
        }
    }
}

struct LibraryPairingFailure: Error { let reason: String }
