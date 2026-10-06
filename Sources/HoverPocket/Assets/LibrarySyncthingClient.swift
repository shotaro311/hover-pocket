import Foundation

struct LibraryLinkedDevice: Identifiable {
    let id: String
    let name: String
    let connected: Bool
}

// The local API credential remains inside this native client, never in view state or helper messages.
@MainActor
final class LibrarySyncthingClient {
    private let endpoint: URL
    private let apiKey: String
    private let session: URLSession
    private let redirects = LibrarySyncRedirectPolicy()

    init(endpoint: URL, apiKey: String, configuration: URLSessionConfiguration = .ephemeral) throws {
        guard ["http", "https"].contains(endpoint.scheme),
              ["127.0.0.1", "[::1]", "::1", "localhost"].contains(endpoint.host),
              endpoint.user == nil, endpoint.password == nil, endpoint.query == nil,
              endpoint.fragment == nil, ["", "/"].contains(endpoint.path),
              !apiKey.isEmpty else { throw LibraryError.message("Syncthingの接続先を確認してください。ローカル接続だけを利用できます。") }
        self.endpoint = endpoint
        self.apiKey = apiKey
        let config = configuration
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.connectionProxyDictionary = [:]
        session = URLSession(configuration: config, delegate: redirects, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    static func discover(folder: String?) async throws -> LibrarySyncthingClient {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = ["Library/Application Support/Syncthing-Eagle/config.xml", "Library/Application Support/Syncthing/config.xml", ".local/state/syncthing/config.xml", ".config/syncthing/config.xml"]
        for relative in candidates {
            let file = home.appendingPathComponent(relative)
            guard let data = try? Data(contentsOf: file), data.count < 2_000_000,
                  let config = LibrarySyncGUIConfiguration.read(data),
                  let client = try? LibrarySyncthingClient(endpoint: config.endpoint, apiKey: config.key),
                  (try? await client.deviceID()) != nil else { continue }
            if let folder, !folder.isEmpty {
                guard (try? await client.folderID(for: URL(fileURLWithPath: folder))) != nil else { continue }
            }
            return client
        }
        throw LibraryError.message("Syncthingを起動してから再確認してください。")
    }

    func deviceID() async throws -> String {
        let status = try await object("system/status")
        guard let id = status["myID"] as? String, Self.validDeviceID(id) else { throw invalidResponse }
        return id
    }

    func folderID(for directory: URL) async throws -> String {
        try AssetLibraryStore.noLinks(directory)
        let folders = try await array("config/folders")
        let matches = folders.filter { ($0["path"] as? String).map { Self.normalizedPath($0) == directory.standardizedFileURL.path } == true }
        guard matches.count == 1, matches.first?["type"] as? String == "sendreceive", let id = matches.first?["id"] as? String, Self.validFolderID(id) else {
            throw LibraryError.message("このライブラリの専用共有を確認できませんでした。接続の詳細を確認してください。")
        }
        return id
    }

    func linkedDevices(folderID: String) async throws -> [LibraryLinkedDevice] {
        guard Self.validFolderID(folderID) else { throw invalidResponse }
        let me = try await deviceID()
        let folder = try await object("config/folders/" + folderID)
        let members = Set((folder["devices"] as? [[String: Any]] ?? []).compactMap { $0["deviceID"] as? String })
        let devices = try await array("config/devices")
        let connections = try await object("system/connections")["connections"] as? [String: [String: Any]] ?? [:]
        return devices.compactMap { device in
            guard let id = device["deviceID"] as? String, id != me, members.contains(id) else { return nil }
            let name = (device["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? String(id.prefix(7))
            return LibraryLinkedDevice(id: id, name: name, connected: connections[id]?["connected"] as? Bool ?? false)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    struct ShareChange {
        let folderID: String
        let directory: URL
        let peerID: String
        let addedPeer: Bool
    }

    // Called only after the host receives the authenticated, explicitly approved peer.
    func addPeer(_ peerID: String, name: String, folderID: String, directory: URL) async throws -> ShareChange {
        guard Self.validDeviceID(peerID), Self.validFolderID(folderID) else { throw invalidResponse }
        try AssetLibraryStore.noLinks(directory)
        let me = try await deviceID()
        guard peerID != me else { throw LibraryError.message("同じ端末には接続できません。") }
        let folders = try await array("config/folders")
        let existing = folders.first { $0["id"] as? String == folderID }
        if let existing {
            guard existing["type"] as? String == "sendreceive", let path = existing["path"] as? String, Self.normalizedPath(path) == directory.standardizedFileURL.path else {
                throw LibraryError.message("別の共有と識別子が重なるため、接続を中止しました。")
            }
        } else if folders.contains(where: { ($0["path"] as? String).map { Self.normalizedPath($0) == directory.standardizedFileURL.path } == true }) {
            throw LibraryError.message("このフォルダは別の共有で使用されています。")
        }
        let devices = try await array("config/devices")
        if !devices.contains(where: { $0["deviceID"] as? String == peerID }) {
            var device = try await object("config/defaults/device")
            device["deviceID"] = peerID
            device["name"] = String(name.prefix(80))
            device["addresses"] = ["dynamic"]
            device["introducer"] = false
            device["autoAcceptFolders"] = false
            device["paused"] = false
            try await write("config/devices", method: "POST", value: device)
        }
        var members = existing?["devices"] as? [[String: Any]] ?? [["deviceID": me]]
        let added = !members.contains { $0["deviceID"] as? String == peerID }
        let change = ShareChange(folderID: folderID, directory: directory, peerID: peerID, addedPeer: added)
        if added { members.append(["deviceID": peerID]) }
        var writeAttempted = false
        do {
            if let existing {
                // Detect edits made since preflight before replacing the member array.
                let fresh = try await object("config/folders/" + folderID)
                guard NSDictionary(dictionary: fresh).isEqual(to: existing) else { throw LibraryError.message("共有設定が変更されました。もう一度接続してください。") }
                if added {
                    writeAttempted = true
                    try await write("config/folders/" + folderID, method: "PATCH", value: ["devices": members])
                }
            } else {
                var folder = try await object("config/defaults/folder")
                folder["id"] = folderID
                folder["label"] = "HoverPocket"
                folder["path"] = directory.path
                folder["type"] = "sendreceive"
                folder["devices"] = members
                folder["paused"] = false
                folder["fsWatcherEnabled"] = true
                folder["fsWatcherDelayS"] = 0.5
                folder["rescanIntervalS"] = 60
                writeAttempted = true
                try await write("config/folders", method: "POST", value: folder)
            }
            let readback = try await object("config/folders/" + folderID)
            guard let path = readback["path"] as? String, Self.normalizedPath(path) == directory.standardizedFileURL.path,
                  (readback["devices"] as? [[String: Any]] ?? []).contains(where: { $0["deviceID"] as? String == peerID }) else { throw invalidResponse }
            return change
        } catch {
            if writeAttempted {
                do { try await rollback(change) } catch { throw LibraryPairingFailure(reason: "rollback_failed") }
            }
            throw error
        }
    }

    func rollback(_ change: ShareChange) async throws {
        guard change.addedPeer else { return }
        // Preserve any files and the global device, including its use by Eagle.
        try await removePeer(change.peerID, folderID: change.folderID, directory: change.directory)
    }

    func removePeer(_ peerID: String, folderID: String, directory: URL) async throws {
        guard Self.validDeviceID(peerID), Self.validFolderID(folderID) else { throw invalidResponse }
        guard peerID != (try await deviceID()) else { throw LibraryError.message("この端末は接続一覧から解除できません。") }
        let folder = try await object("config/folders/" + folderID)
        guard let path = folder["path"] as? String, Self.normalizedPath(path) == directory.standardizedFileURL.path,
              var members = folder["devices"] as? [[String: Any]] else { throw invalidResponse }
        members.removeAll { $0["deviceID"] as? String == peerID }
        try await write("config/folders/" + folderID, method: "PATCH", value: ["devices": members])
        let readback = try await object("config/folders/" + folderID)
        guard !(readback["devices"] as? [[String: Any]] ?? []).contains(where: { $0["deviceID"] as? String == peerID }) else { throw invalidResponse }
    }

    func scan(folderID: String) async throws {
        guard Self.validFolderID(folderID) else { throw invalidResponse }
        var components = URLComponents(url: endpoint.appendingPathComponent("rest/db/scan"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "folder", value: folderID)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw invalidResponse }
    }

    static func validDeviceID(_ id: String) -> Bool {
        id.range(of: "^[A-Z2-7]{7}(-[A-Z2-7]{7}){7}$", options: .regularExpression) != nil
    }
    static func validFolderID(_ id: String) -> Bool {
        id.range(of: "^hoverpocket-[a-z0-9-]{1,100}$", options: .regularExpression) != nil
    }
    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }
    private var invalidResponse: LibraryError { .message("Syncthingの設定を確認できませんでした。") }

    private func object(_ path: String) async throws -> [String: Any] {
        guard let value = try await request(path) as? [String: Any] else { throw invalidResponse }
        return value
    }
    private func array(_ path: String) async throws -> [[String: Any]] {
        guard let value = try await request(path) as? [[String: Any]] else { throw invalidResponse }
        return value
    }
    private func write(_ path: String, method: String, value: [String: Any]) async throws {
        _ = try await request(path, method: method, body: JSONSerialization.data(withJSONObject: value))
    }
    private func request(_ path: String, method: String = "GET", body: Data? = nil) async throws -> Any {
        try Task.checkCancellation()
        var request = URLRequest(url: endpoint.appendingPathComponent("rest/" + path))
        request.httpMethod = method
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode), data.count < 8_000_000 else { throw invalidResponse }
        if method != "GET" || data.isEmpty { return [:] as [String: Any] }
        return try JSONSerialization.jsonObject(with: data)
    }
}

private final class LibrarySyncRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

final class LibrarySyncGUIConfiguration: NSObject, XMLParserDelegate {
    private var inGUI = false
    private var current = ""
    private var address = ""
    private var key = ""
    private var useTLS = false
    private var enabled = false
    private var endpoint: URL? {
        URL(string: (useTLS ? "https://" : "http://") + address.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    static func read(_ data: Data) -> (endpoint: URL, key: String)? {
        let delegate = LibrarySyncGUIConfiguration()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.enabled, let endpoint = delegate.endpoint, !delegate.key.isEmpty else { return nil }
        return (endpoint, delegate.key.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "gui" { inGUI = true; enabled = attributeDict["enabled"] != "false"; useTLS = attributeDict["tls"] == "true" }
        current = inGUI ? elementName : ""
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if current == "address" { address += string }
        if current == "apikey" { key += string }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "gui" { inGUI = false }
        current = ""
    }
}
