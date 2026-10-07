import Foundation

@MainActor
enum LibraryPairingVerification {
    static func run() async throws {
        var checks = 0
        func check(_ value: Bool, _ name: String) throws {
            guard value else { throw LibraryError.message("pairing_check_" + name) }
            checks += 1
        }
        for address in ["http://example.com", "http://0.0.0.0:8384", "https://127.0.0.1@evil.test", "file:///tmp/test", "http://127.0.0.1/proxy", "http://127.0.0.1/?key=secret"] {
            try check((try? LibrarySyncthingClient(endpoint: URL(string: address)!, apiKey: "fictional")) == nil, "nonlocal_endpoint")
        }
        let gui = LibrarySyncGUIConfiguration.read(Data("<configuration><gui enabled='true' tls='false'><address>127.0.0.1:8384</address><apikey>fictional</apikey></gui></configuration>".utf8))
        try check(gui?.endpoint.absoluteString == "http://127.0.0.1:8384" && gui?.key == "fictional", "local_xml")
        try check(LibrarySyncGUIConfiguration.read(Data("<gui enabled='false'><address>127.0.0.1:8384</address><apikey>fictional</apikey></gui>".utf8)) == nil, "disabled_gui")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PairingVerificationProtocol.self]
        let client = try LibrarySyncthingClient(endpoint: URL(string: "http://127.0.0.1:8384")!, apiKey: "fictional", configuration: config)
        let state = PairingVerificationProtocol.state
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("HoverPocket-PairingVerify-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        state.reset(directory: root.path)
        let peer = PairingVerificationState.peer
        let original = state.snapshot()
        try check(try await client.folderID(for: root) == "hoverpocket-test", "discover_exact_existing_path")
        let add = try await client.addPeer(peer, name: "Renaming must not happen", folderID: "hoverpocket-test", directory: root)
        let shared = state.snapshot()
        try check(shared.devices == original.devices, "existing_global_devices_unchanged")
        try check(shared.eagle == original.eagle, "eagle_share_unchanged")
        try check(shared.folder["customField"] as? String == "preserve" && shared.folder["versioning"] != nil, "unknown_folder_fields_preserved")
        try check((shared.folder["devices"] as? [[String: Any]])?.count == 2, "peer_added_once")
        let devices = try await client.linkedDevices(folderID: "hoverpocket-test")
        try check(devices.count == 1 && devices[0].name == "Existing peer" && devices[0].connected, "device_list_from_readback")
        let noChange = try await client.addPeer(peer, name: "Ignored", folderID: "hoverpocket-test", directory: root)
        try check(!noChange.addedPeer, "idempotent_existing_membership")
        try await client.rollback(noChange)
        try check((state.snapshot().folder["devices"] as? [[String: Any]])?.count == 2, "rollback_preserves_preexisting_peer")
        try await client.rollback(add)
        try check(state.snapshot().folder == original.folder, "rollback_only_added_membership")
        try check(state.snapshot().devices == original.devices && state.snapshot().eagle == original.eagle, "rollback_preserves_global_and_eagle")
        let wrong = root.appendingPathComponent("wrong")
        var rejected = false
        do { _ = try await client.addPeer(peer, name: "Wrong", folderID: "hoverpocket-test", directory: wrong) }
        catch { rejected = true }
        try check(rejected && state.snapshot().folder == original.folder, "foreign_path_unchanged")
        state.dropWrites = true
        rejected = false
        do { _ = try await client.addPeer(peer, name: "Write ignored", folderID: "hoverpocket-test", directory: root) }
        catch { rejected = true }
        try check(rejected && state.snapshot().folder == original.folder, "ignored_write_detected")
        state.dropWrites = false
        state.changeOnFolderRead = true
        rejected = false
        do { _ = try await client.addPeer(peer, name: "Concurrent edit", folderID: "hoverpocket-test", directory: root) }
        catch { rejected = true }
        try check(rejected && (state.snapshot().folder["devices"] as? [[String: Any]])?.count == 2, "concurrent_membership_is_not_rolled_back")
        state.reset(directory: root.path)
        let newPeer = Array(repeating: "CCCCCCC", count: 8).joined(separator: "-")
        _ = try await client.addPeer(newPeer, name: "New peer", folderID: "hoverpocket-new-test", directory: root.appendingPathComponent("new"))
        let created = state.snapshot()
        let newDevice = created.devices[newPeer] as? [String: Any]
        try check(newDevice?["introducer"] as? Bool == false && newDevice?["autoAcceptFolders"] as? Bool == false, "no_automatic_trust_or_sharing")
        try check(created.eagle == original.eagle, "new_share_preserves_eagle")
        try check(state.authenticatedRequestsOnly, "local_api_header")
        try await LibraryPairingSessionVerification.run()
        print("library_pairing_verification=ok checks=\(checks) (mock local API; real configuration untouched)")
    }
}

final class PairingVerificationState: @unchecked Sendable {
    static let me = Array(repeating: "AAAAAAA", count: 8).joined(separator: "-")
    static let peer = Array(repeating: "BBBBBBB", count: 8).joined(separator: "-")
    private let lock = NSLock()
    private var folders: [String: [String: Any]] = [:]
    private var devices: [String: [String: Any]] = [:]
    private var ignoreWrites = false
    private var authenticated = true
    private var editOnRead = false
    var changeOnFolderRead: Bool { get { lock.withLock { editOnRead } } set { lock.withLock { editOnRead = newValue } } }
    var dropWrites: Bool { get { lock.withLock { ignoreWrites } } set { lock.withLock { ignoreWrites = newValue } } }
    var authenticatedRequestsOnly: Bool { lock.withLock { authenticated } }
    func reset(directory: String) {
        lock.withLock {
            folders = ["hoverpocket-test": ["id": "hoverpocket-test", "type": "sendreceive", "path": directory, "devices": [["deviceID": Self.me, "encryptionPassword": ""]], "customField": "preserve", "versioning": ["type": "simple"]],
                       "eagle": ["id": "eagle", "path": "/fictional/eagle", "devices": [["deviceID": Self.me], ["deviceID": Self.peer]]]]
            devices = [Self.me: ["deviceID": Self.me, "name": "This Mac"], Self.peer: ["deviceID": Self.peer, "name": "Existing peer", "unknown": "keep"]]
        }
    }
    func snapshot() -> (folder: NSDictionary, eagle: NSDictionary, devices: NSDictionary) {
        lock.withLock { (NSDictionary(dictionary: folders["hoverpocket-test"]!), NSDictionary(dictionary: folders["eagle"]!), NSDictionary(dictionary: devices)) }
    }
    func response(_ request: URLRequest) -> (Data, Int) {
        lock.withLock {
            authenticated = authenticated && request.value(forHTTPHeaderField: "X-API-Key") == "fictional"
            let route = request.url!.path.replacingOccurrences(of: "/rest/", with: "")
            let method = request.httpMethod ?? "GET"
            var body = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; body.append(buffer, count: count) }
            }
            let value = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            var result: Any = [:]
            if method == "GET" {
                switch route {
                case "system/status": result = ["myID": Self.me]
                case "system/connections": result = ["connections": [Self.peer: ["connected": true]]]
                case "config/folders": result = Array(folders.values)
                case "config/devices": result = Array(devices.values)
                case "config/defaults/device", "config/defaults/folder": result = ["unknownDefault": "preserve"]
                default:
                    if route.hasPrefix("config/folders/"), var folder = folders[String(route.dropFirst("config/folders/".count))] {
                        if editOnRead {
                            editOnRead = false
                            var members = folder["devices"] as? [[String: Any]] ?? []
                            members.append(["deviceID": Self.peer]); folder["devices"] = members
                            folders[String(route.dropFirst("config/folders/".count))] = folder
                        }
                        result = folder
                    }
                    else { return (Data(), 404) }
                }
            } else if !ignoreWrites {
                if route == "config/devices", let id = value["deviceID"] as? String { devices[id] = value }
                else if route == "config/folders", let id = value["id"] as? String { folders[id] = value }
                else if route.hasPrefix("config/folders/") {
                    let id = String(route.dropFirst("config/folders/".count))
                    for (key, item) in value { folders[id]?[key] = item }
                }
            }
            return ((try? JSONSerialization.data(withJSONObject: result)) ?? Data(), 200)
        }
    }
}

final class PairingVerificationProtocol: URLProtocol, @unchecked Sendable {
    static let state = PairingVerificationState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (data, status) = Self.state.response(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: [:])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
