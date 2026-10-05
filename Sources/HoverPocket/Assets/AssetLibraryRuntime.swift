import AppKit
import Combine
import SwiftUI

@MainActor
final class AssetLibraryRuntime: ObservableObject {
    static let shared = AssetLibraryRuntime()
    @Published var panelSize: CGSize?
    @Published var fullscreen = false
    @Published var editing: AssetEditorSession?
    @Published var holdCount = 0
    var editorSessions: [AssetEditorSession] = []
    var pendingDropURLs: [URL] = []
    var textInput = false
    var onLayout: (() -> Void)?
    var baselineSize: (() -> CGSize)?
    var closePanel: (() -> Void)?
    var openPanel: (() -> Void)?
    var openForDrop: (() -> Void)?
    var canAcceptDrop: (() -> Bool)?
    var incomingDrag = false
    var dropReceived = false
    private var organizer: NSWindow?
    private var storeTask: Task<AssetLibraryStore, Error>?
    var verificationStore: AssetLibraryStore?
    static let changed = Notification.Name("HoverPocket.assets.changed")
    static let closed = Notification.Name("HoverPocket.assets.closed")
    static let opened = Notification.Name("HoverPocket.assets.opened")
    static var libraryRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HoverPocket/AssetLibrary")
    }

    func store() async throws -> AssetLibraryStore {
        if CommandLine.arguments.contains("--verify-asset-ui"), let verificationStore { return verificationStore }
        if let storeTask { return try await storeTask.value }
        let contract = Bundle.main.resourceURL!.appendingPathComponent("AssetLibrary")
        let root = Self.libraryRoot
        let task = Task.detached(priority: .userInitiated) {
            let store = try AssetLibraryStore(root: root, contractRoot: contract)
            try await store.start(); return store
        }
        storeTask = task
        do { return try await task.value } catch { storeTask = nil; throw error }
    }
    func notifyChange() { NotificationCenter.default.post(name: Self.changed, object: nil) }
    func recoverDatabase() async throws {
        let panel = NSOpenPanel(); panel.directoryURL = Self.libraryRoot.appendingPathComponent("snapshots")
        panel.message = "DBスナップショットを選択。現在のDBと原本は退避・保持します。"
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        let root = Self.libraryRoot
        try await Task.detached { try AssetLibraryStore.recoverBrokenDatabase(root: root, snapshot: source) }.value
        storeTask = nil; _ = try await store(); notifyChange()
    }
    func receiveDrop(_ urls: [URL]) {
        dropReceived = true
        pendingDropURLs += urls
        NotificationCenter.default.post(name: Notification.Name("HoverPocket.assets.drop"), object: nil)
    }
    var holdsPanel: Bool { holdCount > 0 || editing != nil || textInput || incomingDrag }
    func endPreview() {
        panelSize = nil; fullscreen = false; textInput = false
        NotificationCenter.default.post(name: Self.closed, object: nil)
    }
    func setLayout(media: CGSize, fullscreen: Bool, screen: NSScreen, baseline: CGSize) {
        self.fullscreen = fullscreen
        if fullscreen { panelSize = screen.frame.size }
        else {
            let maximum = CGSize(width: screen.visibleFrame.width * 0.9, height: screen.visibleFrame.height * 0.85)
            let desired = CGSize(width: max(baseline.width, media.width / screen.backingScaleFactor + 32),
                height: max(baseline.height, media.height / screen.backingScaleFactor + 154))
            let scale = min(1, maximum.width / desired.width, maximum.height / desired.height)
            panelSize = CGSize(width: min(maximum.width, max(baseline.width, desired.width * scale)),
                height: min(maximum.height, max(baseline.height, desired.height * scale)))
        }
        onLayout?()
    }
    func showOrganizer() {
        if organizer == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "素材ライブラリ"; window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 680, height: 440)
            window.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 1)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = NSHostingView(rootView: AssetLibraryView(active: true, language: .japanese, organizer: true))
            window.center(); organizer = window
        }
        organizer?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
}

struct AssetLibraryView: View {
    let active: Bool
    let language: AppLanguage
    var organizer = false
    @StateObject private var pane = AssetPaneModel()
    @State private var storageError: String?
    var body: some View {
        ZStack {
            AssetWebView(pane: pane, language: language, organizer: organizer)
            if let editor = pane.editor { AssetAnnotationEditor(session: editor) }
            if let storageError {
                VStack(spacing: 12) {
                    Text("素材ライブラリを開けません").font(.headline)
                    Text(storageError).font(.caption)
                    Button("DBスナップショットから復旧…") {
                        Task { do { try await AssetLibraryRuntime.shared.recoverDatabase(); _ = try await AssetLibraryRuntime.shared.store(); self.storageError = nil } catch { self.storageError = error.localizedDescription } }
                    }
                }.padding(24).background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .onChange(of: active) { _, value in pane.setActive(value) }
        .onDisappear { pane.setActive(false) }
        .task { do { _ = try await AssetLibraryRuntime.shared.store() } catch { storageError = error.localizedDescription } }
    }
}
