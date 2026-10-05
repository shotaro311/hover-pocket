import AppKit
import SwiftUI

@MainActor
final class AssetLibrarySyncController: ObservableObject {
    static let shared = AssetLibrarySyncController()
    @Published private(set) var status = LibrarySyncStatus()
    @Published private(set) var message = "同期はオフです"
    @Published private(set) var busy = false
    private var loop: Task<Void, Never>?
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }
    func refresh() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            let store = try await AssetLibraryRuntime.shared.store()
            status = try await store.syncOnce()
            message = !status.enabled ? "同期はオフです" : !status.conflicts.isEmpty ? "同じ素材に異なる変更があります" : status.pending > 0 ? "素材や変更記録の到着を待っています" : "届いた変更を反映しました"
            if status.applied > 0 { AssetLibraryRuntime.shared.notifyChange() }
        } catch { message = error.localizedDescription }
    }
    func chooseFolder(create: Bool) {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = create
        panel.message = create ? "Syncthingで共有する、空のHoverPocket専用フォルダを選択してください。" : "もう一方の端末とSyncthingで接続した、HoverPocket専用フォルダを選択してください。"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        action { try await $0.configureSync(folder: folder, create: create) }
    }
    func toggle() {
        guard status.enabled else { action { try await $0.resumeSync() }; start(); return }
        loop?.cancel(); loop = nil
        Task {
            do {
                let store = try await AssetLibraryRuntime.shared.store()
                try await store.pauseSync(); status = try await store.syncStatus(); message = "同期はオフです"
            } catch { message = error.localizedDescription }
        }
    }
    func resolve(_ conflict: LibrarySyncConflict, remote: Bool) {
        action { try await $0.resolveSync(revision: conflict.id, useRemote: remote) }
    }
    private func action(_ body: @escaping (AssetLibraryStore) async throws -> Void) {
        guard !busy else { return }; busy = true
        Task {
            do {
                let store = try await AssetLibraryRuntime.shared.store(); try await body(store)
                status = try await store.syncStatus(); AssetLibraryRuntime.shared.notifyChange()
                busy = false; await refresh(); start()
            } catch { message = error.localizedDescription; busy = false }
        }
    }
}

struct AssetLibrarySyncSettings: View {
    @ObservedObject private var sync = AssetLibrarySyncController.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("素材ライブラリの同期").font(.headline)
            Text("Syncthingで接続した専用フォルダを使い、MacとWindowsの素材・分類・ゴミ箱を同期します。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("新しい同期を作る…") { sync.chooseFolder(create: true) }
                Button("既存の同期に参加…") { sync.chooseFolder(create: false) }
            }.disabled(sync.busy)
            if !sync.status.folder.isEmpty {
                Text(sync.status.folder).font(.caption).textSelection(.enabled)
                HStack {
                    Button(sync.status.enabled ? "同期を停止" : "同期を再開") { sync.toggle() }.disabled(sync.busy && !sync.status.enabled)
                    Button("今すぐ確認") { Task { await sync.refresh() } }.disabled(sync.busy)
                    Button("同期フォルダを開く") { NSWorkspace.shared.open(URL(fileURLWithPath: sync.status.folder)) }
                }
            }
            Label(sync.message, systemImage: sync.status.conflicts.isEmpty ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle")
                .font(.caption).textSelection(.enabled)
            Text("相手がオフラインの間は変更を保持し、接続後に反映します。ここでの状態は届いた変更の処理状況です。転送状況はSyncthingで確認できます。")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(sync.status.conflicts) { conflict in
                VStack(alignment: .leading, spacing: 6) {
                    Text(conflict.reason).font(.caption).foregroundStyle(.secondary)
                    HStack(alignment: .top, spacing: 20) {
                        VStack(alignment: .leading) { Text("この端末: " + conflict.name); Text(conflict.localDetail).foregroundStyle(.secondary) }
                        VStack(alignment: .leading) { Text("受信した版: " + conflict.remoteName); Text(conflict.remoteDetail).foregroundStyle(.secondary) }
                    }.font(.caption).textSelection(.enabled)
                    HStack {
                        Button("この端末の内容を使う") { sync.resolve(conflict, remote: false) }
                        Button("受信した内容を使う") { sync.resolve(conflict, remote: true) }
                    }.disabled(sync.busy)
                }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .task { sync.start() }
    }
}
