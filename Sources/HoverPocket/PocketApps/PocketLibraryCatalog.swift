import Foundation

/// Bundled modules only. Package dependencies are derived from the existing manifest,
/// so library management never changes a tool's records or package format.
struct PocketLibraryDescriptor: Equatable, Identifiable, Sendable {
    let id: String
    let version: Int
    let name: String
    let purpose: String
    var platforms: Set<String> = ["macOS"]
    var dependencies: Set<String> = []
    var capabilityKeys: Set<PocketCapabilityKey> = []
    var generationKeys: Set<PocketCapabilityKey> = []
    var surfaceKinds: Set<String> = []
    var providesCollections = false
    var hostRequired = false
}

enum PocketLibraryError: Error, Equatable {
    case invalidCatalog
    case unavailable(String)
    case inUse([String])
}

struct PocketLibraryCatalog: Equatable, Sendable {
    let libraries: [PocketLibraryDescriptor]
    let disabled: Set<String>
    let platform: String

    init(libraries: [PocketLibraryDescriptor] = Self.bundled, disabled: Set<String> = [],
         platform: String = "macOS") throws {
        let ids = Set(libraries.map(\.id))
        guard ids.count == libraries.count,
              libraries.allSatisfy({ !$0.id.isEmpty && $0.version > 0 && $0.dependencies.isSubset(of: ids)
                  && $0.generationKeys.isSubset(of: $0.capabilityKeys) }) else {
            throw PocketLibraryError.invalidCatalog
        }
        var owners: Set<PocketCapabilityKey> = []
        var surfaces: Set<String> = []
        for library in libraries {
            guard owners.isDisjoint(with: library.capabilityKeys), surfaces.isDisjoint(with: library.surfaceKinds) else {
                throw PocketLibraryError.invalidCatalog
            }
            owners.formUnion(library.capabilityKeys)
            surfaces.formUnion(library.surfaceKinds)
        }
        guard libraries.filter(\.providesCollections).count <= 1 else { throw PocketLibraryError.invalidCatalog }
        self.libraries = libraries.sorted { $0.id < $1.id }
        self.disabled = disabled
        self.platform = platform
        for id in ids { _ = try closure([id], visiting: []) }
    }

    static let bundled: [PocketLibraryDescriptor] = {
        func native(_ id: String, _ name: String, _ purpose: String, _ prefix: String,
                    _ generated: Set<PocketCapabilityKey>) -> PocketLibraryDescriptor {
            PocketLibraryDescriptor(id: id, version: 1, name: name, purpose: purpose,
                capabilityKeys: Set(PocketCapabilityDescriptors.builtIn.map(\.key).filter { $0.id.hasPrefix(prefix) }),
                generationKeys: generated)
        }
        return [
            .init(id: "pocket.ai-text", version: 1, name: "AI文章処理", purpose: "確認した文章をOpenAIへ送り、要約・整理・書き換えの結果を受け取る", dependencies: ["pocket.codex"], capabilityKeys: [PocketAITextService.key], generationKeys: [PocketAITextService.key]),
            .init(id: "pocket.collections", version: 1, name: "記録と一覧", purpose: "ツール専用の記録・検索・入力フォーム", surfaceKinds: ["collection"], providesCollections: true),
            .init(id: "pocket.html", version: 1, name: "カスタム画面", purpose: "隔離されたHTML画面と操作" , surfaceKinds: ["html"]),
            .init(id: "pocket.declarative", version: 1, name: "標準画面", purpose: "本体の部品を使った画面", surfaceKinds: ["declarative"]),
            native("pocket.calendar", "カレンダー", "今日の予定を読む", "calendar.", [.calendarList]),
            native("pocket.sticky", "付箋", "ツール専用の付箋を読む・保存する", "sticky.", [.stickyGet, .stickyUpsert]),
            native("pocket.timer", "タイマー", "タイマーの状態取得と開始", "timer.", [.timerGet, .timerStart]),
            native("pocket.calculator", "計算", "既存ツールの計算を実行する", "calculator.", []),
            native("pocket.controls", "端末操作", "既存ツールの音量などを操作する", "controls.", []),
            .init(id: "pocket.codex", version: 1, name: "Codex連携", purpose: "ツール生成と音声操作の接続。AI文章処理ライブラリの接続も担当。", hostRequired: true)
        ]
    }()

    func isAvailable(_ id: String) -> Bool {
        guard let dependencies = try? closure([id], visiting: []) else { return false }
        return dependencies.allSatisfy { dependency in
            libraries.contains { $0.id == dependency && $0.platforms.contains(platform) && !disabled.contains(dependency) }
        }
    }

    func dependencies(of package: PocketAppPackage) throws -> Set<String> {
        var ids: Set<String> = []
        for kind in Set(package.manifest.surfaceKinds.values) {
            guard let owner = libraries.first(where: { $0.surfaceKinds.contains(kind) }) else {
                throw PocketLibraryError.unavailable(kind)
            }
            ids.insert(owner.id)
        }
        if !package.collections.isEmpty {
            guard let owner = libraries.first(where: \.providesCollections) else { throw PocketLibraryError.unavailable("collections") }
            ids.insert(owner.id)
        }
        for capability in package.manifest.requestedCapabilities {
            guard let owner = libraries.first(where: { $0.capabilityKeys.contains(capability.key) }) else {
                throw PocketLibraryError.unavailable(capability.key.id)
            }
            ids.insert(owner.id)
        }
        return try closure(ids, visiting: [])
    }

    func validate(_ package: PocketAppPackage) throws {
        for id in try dependencies(of: package).sorted() where !isAvailable(id) {
            throw PocketLibraryError.unavailable(id)
        }
    }

    func settingEnabled(_ enabled: Bool, id: String, consumers: [String: Set<String>]) throws -> Self {
        guard libraries.contains(where: { $0.id == id }) else { throw PocketLibraryError.unavailable(id) }
        if !enabled {
            var blockers = try consumers.keys.sorted().filter { try closure(consumers[$0] ?? [], visiting: []).contains(id) }
            for library in libraries where library.hostRequired {
                if try closure([library.id], visiting: []).contains(id) { blockers.append("HoverPocket") }
            }
            guard blockers.isEmpty else { throw PocketLibraryError.inUse(blockers.sorted()) }
        }
        var next = disabled
        if enabled { next.remove(id) } else { next.insert(id) }
        let result = try Self(libraries: libraries, disabled: next, platform: platform)
        if enabled, !result.isAvailable(id) { throw PocketLibraryError.unavailable(id) }
        return result
    }

    func generationCapabilities(namespace: String) -> [PocketAppGenerationCapability] {
        let allowed = libraries.filter { isAvailable($0.id) }.reduce(into: Set<PocketCapabilityKey>()) { $0.formUnion($1.generationKeys) }
        return PocketCapabilityDescriptors.builtIn.filter { allowed.contains($0.key) }.map { descriptor in
            let scope: [String: String]
            switch descriptor.key {
            case PocketCapabilityKeys.calendarList: scope = ["range": "today"]
            case PocketCapabilityKeys.stickyGet, PocketCapabilityKeys.stickyUpsert: scope = ["namespace": namespace]
            default: scope = [:]
            }
            return PocketAppGenerationCapability(id: descriptor.key.id, version: descriptor.key.version,
                effect: descriptor.effect.rawValue,
                permissions: descriptor.permissions.sorted(), scope: scope)
        }.sorted { $0.id < $1.id }
    }

    func promptJSON(namespace: String, allowedCapabilities: [PocketAppGenerationCapability]? = nil) throws -> String {
        let operations = generationCapabilities(namespace: namespace).filter { allowedCapabilities?.contains($0) ?? true }
        let rows: [[String: Any]] = libraries.filter { isAvailable($0.id) }.map { library in
            ["id": library.id, "version": library.version, "purpose": library.purpose,
             "platforms": library.platforms.sorted(), "dependencies": library.dependencies.sorted(),
             "hostOnly": library.hostRequired, "surfaceKinds": library.surfaceKinds.sorted(),
             "collections": library.providesCollections,
             "operations": operations.filter { library.generationKeys.contains(.init(id: $0.id, version: $0.version)) }.map {
                 ["id": $0.id, "version": $0.version, "permissions": $0.permissions, "scope": $0.scope] as [String: Any]
             }]
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]), as: UTF8.self)
    }

    private func closure(_ ids: Set<String>, visiting: Set<String>) throws -> Set<String> {
        var result = ids
        for id in ids {
            guard !visiting.contains(id), let library = libraries.first(where: { $0.id == id }) else {
                throw PocketLibraryError.invalidCatalog
            }
            result.formUnion(try closure(library.dependencies, visiting: visiting.union([id])))
        }
        return result
    }
}

private extension PocketCapabilityKey {
    static let calendarList = PocketCapabilityKeys.calendarList
    static let stickyGet = PocketCapabilityKeys.stickyGet
    static let stickyUpsert = PocketCapabilityKeys.stickyUpsert
    static let timerGet = PocketCapabilityKeys.timerGet
    static let timerStart = PocketCapabilityKeys.timerStart
}
