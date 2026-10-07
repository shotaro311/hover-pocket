import AppKit
import SwiftUI

@MainActor
final class AssetDropOverlay: ObservableObject {
    static let shared = AssetDropOverlay()
    @Published var expanded = false
    @Published var folders: [LibraryCategory] = []
    @Published var status = "ライブラリへ保存"
    private var window: NSPanel?
    var isPresented: Bool { window?.isVisible == true }
    private var screen: NSScreen?
    private var loading = false
    private var busy = false
    private var resultUntil: Date?
    private let importer = AssetPaneModel()

    func track(board: NSPasteboard, dragging: Bool, allowed: Bool) {
        if busy || (resultUntil.map { $0 > Date() } ?? false) { return }
        guard dragging, allowed, AssetIncomingDrop.accepts(board) else { window?.orderOut(nil); expanded = false; return }
        let target = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let target else { return }
        if window == nil {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .popUpMenu; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; panel.hidesOnDeactivate = false
            panel.contentView = NSHostingView(rootView: AssetDropOverlayView(model: self))
            window = panel
        }
        screen = target
        if !window!.isVisible { expanded = false; status = "ライブラリへ保存"; loadFolders() }
        if window!.frame.insetBy(dx: -24, dy: -16).contains(NSEvent.mouseLocation) { expanded = true }
        position(); window?.orderFrontRegardless()
    }
    private func position() {
        guard let screen else { return }
        let width: CGFloat = expanded ? 380 : 180, height: CGFloat = expanded ? 260 : 42
        let frame = screen.visibleFrame
        window?.setFrame(NSRect(x: frame.midX-width/2, y: frame.maxY-height-12, width: width, height: height), display: true)
    }
    private func loadFolders() {
        guard !loading else { return }; loading = true
        Task {
            defer { loading = false }
            do { let store = try await AssetLibraryRuntime.shared.store(); folders = try await store.query(LibraryQuery()).folders }
            catch { status = error.localizedDescription }
        }
    }
    func receive(_ board: NSPasteboard, folder: String?) -> Bool {
        guard !busy else { return false }
        busy = true; status = "取り込み中…"
        let accepted = AssetIncomingDrop.receive(board) { [weak self] urls, error in
            guard let self else { return }
            if urls.isEmpty { self.finish(error ?? "取り込めるファイルがありません。"); return }
            self.importer.importURLs(urls, folderId: folder) { [weak self] message in self?.finish(error ?? message) }
        }
        if !accepted { finish("このドラッグ内容は取り込めません。") }
        return accepted
    }
    func showError(_ message: String) { finish(message) }
    private func finish(_ message: String) {
        busy = false; status = message; resultUntil = Date().addingTimeInterval(5)
    }
}

private struct AssetDropOverlayView: View {
    @ObservedObject var model: AssetDropOverlay
    var body: some View {
        VStack(spacing: 8) {
            Label(model.status, systemImage: "tray.and.arrow.down").font(.system(size: 13, weight: .semibold)).lineLimit(2)
            if model.expanded {
                Text("保存先へドロップ").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(spacing: 5) {
                        dropRow("未分類", folder: nil)
                        ForEach(model.folders, id: \.id) { folder in dropRow(folder.name, folder: folder.id) }
                    }
                }
            }
        }
        .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.09, green: 0.1, blue: 0.13), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.2)))
        .foregroundStyle(.white).environment(\.colorScheme, .dark)
    }
    private func dropRow(_ title: String, folder: String?) -> some View {
        AssetOverlayDropRow(title: title) { model.receive($0, folder: folder) }.frame(height: 36)
    }
}

private struct AssetOverlayDropRow: NSViewRepresentable {
    let title: String
    let receive: (NSPasteboard) -> Bool
    func makeNSView(context: Context) -> Row { Row(title: title, receive: receive) }
    func updateNSView(_ view: Row, context: Context) { view.label.stringValue = title; view.receive = receive }
    final class Row: NSView {
        let label = NSTextField(labelWithString: "")
        var receive: (NSPasteboard) -> Bool
        init(title: String, receive: @escaping (NSPasteboard) -> Bool) {
            self.receive = receive; super.init(frame: .zero)
            wantsLayer = true; layer?.cornerRadius = 7
            label.stringValue = title; label.textColor = .white; label.font = .systemFont(ofSize: 13)
            label.translatesAutoresizingMaskIntoConstraints = false; addSubview(label)
            NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), label.centerYAnchor.constraint(equalTo: centerYAnchor), label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12)])
            registerForDraggedTypes(AssetIncomingDrop.types); highlight(false)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        private func highlight(_ value: Bool) { layer?.backgroundColor = NSColor.white.withAlphaComponent(value ? 0.24 : 0.07).cgColor }
        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { guard AssetIncomingDrop.accepts(sender.draggingPasteboard) else { return [] }; highlight(true); return .copy }
        override func draggingExited(_ sender: (any NSDraggingInfo)?) { highlight(false) }
        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool { highlight(false); return receive(sender.draggingPasteboard) }
    }
}
