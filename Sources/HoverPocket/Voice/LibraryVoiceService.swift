import AppKit
import Foundation

@MainActor
final class LibraryVoiceService {
    static let shared = LibraryVoiceService()
    let capture: AssetCaptureController
    let targets: VoiceCaptureTargets
    private let storeProvider: () async throws -> AssetLibraryStore
    private let showLibrary: (String?) async throws -> Void

    init(capture: AssetCaptureController = .shared, targets: VoiceCaptureTargets = VoiceCaptureTargets(),
         store: @escaping () async throws -> AssetLibraryStore = { try await AssetLibraryRuntime.shared.store() },
         showLibrary: @escaping (String?) async throws -> Void = { try await AssetLibraryRuntime.shared.openForVoice(assetID: $0) }) {
        self.capture = capture; self.targets = targets; self.storeProvider = store; self.showLibrary = showLibrary
    }
    func prepare(_ operation: LibraryVoiceOperation, _ arguments: CapabilityObject) async throws
        -> (CapabilityObject, VoiceNativeApprovalRequest?) {
        try operation.validate(arguments, prepared: false)
        try Task.checkCancellation()
        var bound = arguments
        var detail: String?
        if [.screenshot, .recordStart].contains(operation) {
            guard !capture.busy, !capture.recording else { throw LibraryVoiceError.failed("capture_busy") }
            let target = try await targets.resolve(target: arguments.text("target") ?? "current_window",
                windowID: arguments.text("windowId"), windowTitle: arguments.text("windowTitle"))
            let folder = try await folder(arguments.text("folderId"))
            bound["targetToken"] = .string(target.id)
            detail = "対象: \(target.title)\n保存先: \(folder?.name ?? "ライブラリ（未分類）")\n名前: \(arguments.text("name") ?? "日時を使って自動作成")"
            if operation == .recordStart {
                let systemAudio = arguments.flag("systemAudio", fallback: capture.preferences.systemAudio)
                let microphone = arguments.flag("microphone")
                bound["systemAudio"] = .bool(systemAudio); bound["microphone"] = .bool(microphone)
                detail! += "\nMac全体の音声（AIの返答を含む）: \(systemAudio ? "含める" : "含めない")\nマイク: \(microphone ? "含める" : "含めない")\n停止するとライブラリへ保存します。"
            }
        } else if operation == .recordStop {
            guard capture.recording, let id = capture.recordingID else { throw LibraryVoiceError.failed("no_recording") }
            bound["recordingId"] = .string(id)
        } else if [.rename, .favorite, .classify].contains(operation) {
            let before = try await asset(arguments.text("assetId")!)
            switch operation {
            case .rename: detail = before.name + "\n新しい名前: " + arguments.text("name")!
            case .favorite: detail = before.name + (arguments.flag("favorite") ? "\nお気に入りに追加" : "\nお気に入りを解除")
            default: detail = before.name + "\n追加先: " + (try await folder(arguments.text("folderId")))!.name
            }
        } else if operation == .folder { detail = arguments.text("name") }
        if let name = arguments.text("name"), operation != .folder,
           name.contains("/") || name.contains(":") { throw CapabilityHandlerError.invalidArgument("name") }
        let title = operation == .screenshot ? "スクリーンショットを保存" : operation == .recordStart ? "画面収録を開始"
            : operation == .folder ? "ライブラリにフォルダを作成" : "ライブラリを更新"
        return (bound, detail.map { .init(kind: .personalEdit, title: title, detail: $0) })
    }
    private func folder(_ id: String?) async throws -> LibraryCategory? {
        guard let id else { return nil }
        let store = try await storeProvider()
        guard let value = try await store.query(LibraryQuery()).folders.first(where: { $0.id == id }) else {
            throw LibraryVoiceError.failed("folder_not_found")
        }
        return value
    }
    private func asset(_ id: String) async throws -> LibraryAsset {
        let store = try await storeProvider()
        guard let asset = try await store.get(id), !asset.trashed else { throw LibraryVoiceError.failed("asset_not_found") }
        return asset
    }
    private func metadata(_ asset: LibraryAsset) -> CapabilityValue {
        .object(["id": .string(asset.id), "name": .string(asset.name), "kind": .string(asset.kind),
            "extension": .string(asset.extension), "createdAt": .string(asset.createdAt), "sizeBytes": .integer(Int(asset.sizeBytes)),
            "favorite": .bool(asset.favorite), "folderIds": .array(asset.folderIds.map(CapabilityValue.string))])
    }
    private func metadata(_ folder: LibraryCategory) -> CapabilityValue {
        .object(["id": .string(folder.id), "name": .string(folder.name), "parentId": folder.parentId.map(CapabilityValue.string) ?? .null])
    }
    private func saved(_ value: LibraryAsset) async throws -> CapabilityValue {
        let store = try await storeProvider()
        let asset = try await asset(value.id)
        _ = try await store.path(asset, verifyHash: true)
        guard asset.sizeBytes > 0 else { throw CapabilityHandlerError.readbackMismatch("saved_asset") }
        return metadata(asset)
    }
    func execute(_ operation: LibraryVoiceOperation, _ arguments: CapabilityObject) async throws -> CapabilityObject {
        try operation.validate(arguments, prepared: true)
        try Task.checkCancellation()
        switch operation {
        case .windows:
            let windows = try await targets.list(query: arguments.text("query") ?? "")
            return ["ok": .bool(true), "windows": .array(windows.map { .object(["windowId": .string($0.id), "title": .string($0.title)]) })]
        case .recordStatus:
            return ["ok": .bool(true), "state": .object(["recording": .bool(capture.recording), "busy": .bool(capture.busy),
                "recordingId": capture.recordingID.map(CapabilityValue.string) ?? .null,
                "savedAssetIds": .array(capture.lastRecordingAsset.map { [.string($0.id)] } ?? []),
                "error": capture.lastRecordingError.map(CapabilityValue.string) ?? .null])]
        case .screenshot, .recordStart:
            _ = try await folder(arguments.text("folderId"))
            let filter = try await targets.filter(arguments.text("targetToken")!)
            if operation == .screenshot {
                let value = try await capture.screenshotForVoice(filter: filter, folder: arguments.text("folderId"), name: arguments.text("name"))
                return try await ["ok": .bool(true), "asset": saved(value)]
            }
            let id = try await capture.startRecordingForVoice(filter: filter, folder: arguments.text("folderId"), name: arguments.text("name"),
                systemAudio: arguments.flag("systemAudio"), microphone: arguments.flag("microphone"))
            return ["ok": .bool(true), "recordingId": .string(id), "recording": .bool(true),
                "systemAudio": .bool(arguments.flag("systemAudio")), "microphone": .bool(arguments.flag("microphone"))]
        case .recordStop:
            let value = try await capture.stopRecordingForVoice(id: arguments.text("recordingId")!)
            return try await ["ok": .bool(true), "recording": .bool(false), "assets": .array([saved(value)])]
        case .search:
            _ = try await folder(arguments.text("folderId"))
            let store = try await storeProvider()
            var query = LibraryQuery(); query.text = arguments.text("text") ?? ""; query.kind = arguments.text("kind")
            query.folderId = arguments.text("folderId"); query.view = arguments.flag("favorites") ? "favorites" : "recent"
            if case .integer(let limit)? = arguments["limit"] { query.limit = limit } else { query.limit = 20 }
            if case .integer(let offset)? = arguments["offset"] { query.offset = offset }
            let page = try await store.query(query)
            return ["ok": .bool(true), "assets": .array(page.items.map(metadata)), "total": .integer(page.total),
                "folders": .array(page.folders.prefix(100).map(metadata)), "foldersTruncated": .bool(page.folders.count > 100)]
        case .open:
            if let id = arguments.text("assetId") { _ = try await asset(id) }
            try await showLibrary(arguments.text("assetId"))
            return ["ok": .bool(true), "opened": .bool(true), "assetId": arguments["assetId"] ?? .null]
        case .folder:
            let store = try await storeProvider()
            let id = try await store.category(type: "folder", name: arguments.text("name")!)
            let value = try await folder(id)!
            AssetLibraryRuntime.shared.notifyChange()
            return ["ok": .bool(true), "folder": metadata(value)]
        case .rename, .favorite, .classify:
            let before = try await asset(arguments.text("assetId")!), store = try await storeProvider()
            let value = operation == .rename ? arguments.text("name") : operation == .favorite ? (arguments.flag("favorite") ? "true" : "false") : arguments.text("folderId")
            if operation == .classify { _ = try await folder(value) }
            try Task.checkCancellation()
            try await store.update(ids: [before.id], operation: operation == .rename ? "rename" : operation == .favorite ? "favoriteSet" : "classify", value: value)
            let after = try await asset(before.id)
            let expectedName = value.map { name in
                let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
                return before.extension.isEmpty || clean.lowercased().hasSuffix("." + before.extension) ? clean : clean + "." + before.extension
            }
            guard operation != .rename || after.name == expectedName,
                  operation != .favorite || after.favorite == arguments.flag("favorite"),
                  operation != .classify || after.folderIds.contains(value!) else { throw CapabilityHandlerError.readbackMismatch("asset_update") }
            AssetLibraryRuntime.shared.notifyChange()
            return ["ok": .bool(true), "asset": metadata(after)]
        }
    }
}

extension Dictionary where Key == String, Value == CapabilityValue {
    func text(_ key: String) -> String? { if case .string(let value)? = self[key] { return value }; return nil }
    func flag(_ key: String, fallback: Bool = false) -> Bool { if case .bool(let value)? = self[key] { return value }; return fallback }
}

extension OpenAIRealtimeMacOSCapabilityRuntime {
    func executeLibrary(_ operation: LibraryVoiceOperation, correlation: String, sessionID: String,
                        arguments: CapabilityObject) async throws -> String {
        guard context.registry.availableHandlerKeys.contains(operation.key) else { throw LibraryVoiceError.failed("unavailable") }
        let (bound, approval) = try await library.prepare(operation, arguments)
        let output = try await executeCapability(correlation: correlation, sessionID: sessionID,
            planIDPrefix: "voice." + operation.rawValue, stepID: "library", capability: operation.key,
            arguments: bound, permission: operation.permission, approval: approval)
        return String(decoding: try CapabilityCanonicalJSON.data(.object([
            "status": .string("succeeded"), "readback": .string("verified"),
            "result": .object(output), "contentIsUntrusted": .bool(true)
        ])), as: UTF8.self)
    }
}
