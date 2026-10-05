import AppKit
import SwiftUI

@MainActor
final class AssetLibrarySyncController: ObservableObject {
    static let shared = AssetLibrarySyncController()
    @Published private(set) var status = LibrarySyncStatus()
    @Published private(set) var message = "同期はオフです"
    @Published private(set) var busy = false
    @Published private(set) var issue: String?
    private var loop: Task<Void, Never>?
    func start() {
        guard HoverPocketRuntimeEnvironment.shared.externalIntegrationsEnabled, loop == nil else { return }
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
            status = try await store.syncOnce(); issue = nil
            message = !status.enabled ? "同期はオフです" : !status.conflicts.isEmpty ? "同じ素材に異なる変更があります" : status.pending > 0 ? "素材や変更記録の到着を待っています" : "届いた変更を反映しました"
            if status.applied > 0 { AssetLibraryRuntime.shared.notifyChange() }
        } catch { issue = error.localizedDescription }
    }
    func chooseFolder(create: Bool) {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = create
        panel.message = create ? "Syncthingで共有する、空のHoverPocket専用フォルダを選択してください。" : "もう一方の端末とSyncthingで接続した、HoverPocket専用フォルダを選択してください。"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        action { try await $0.configureSync(folder: folder, create: create) }
    }
    func toggle() {
        guard !busy else { return }
        guard status.enabled else { action { try await $0.resumeSync() }; start(); return }
        loop?.cancel(); loop = nil; busy = true
        Task {
            defer { busy = false }
            do {
                let store = try await AssetLibraryRuntime.shared.store()
                try await store.pauseSync(); status = try await store.syncStatus(); issue = nil; message = "同期はオフです"
            } catch { issue = error.localizedDescription }
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
            } catch { issue = error.localizedDescription; busy = false }
        }
    }
}
