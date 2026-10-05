import AppKit
import SwiftUI

struct AssetLibrarySyncSettings: View {
    let language: AppLanguage
    @ObservedObject private var sync = AssetLibrarySyncController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard {
                HStack {
                    Label(localized("ライブラリ同期", "Library sync"), systemImage: "arrow.triangle.2.circlepath")
                        .font(.headline)
                    Spacer()
                    Label(statusTitle, systemImage: sync.status.enabled ? "checkmark.circle.fill" : "pause.circle")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(sync.status.enabled ? Color.green : Color.secondary)
                }
                Text(localized("素材・フォルダ・タグ・ゴミ箱を共有します。", "Share assets, folders, tags, and trash."))
                    .font(.callout).foregroundStyle(.secondary)
                if !sync.status.folder.isEmpty {
                    HStack {
                        Button(localized(sync.status.enabled ? "同期を一時停止" : "同期を再開", sync.status.enabled ? "Pause sync" : "Resume sync")) { sync.toggle() }
                        Button(localized("今すぐ確認", "Check now")) { Task { await sync.refresh() } }
                        if sync.busy { ProgressView().controlSize(.small) }
                    }.disabled(sync.busy)
                    if sync.status.pending > 0 {
                        Label(localized("到着待ち：\(sync.status.pending)件", "Waiting for \(sync.status.pending) items"), systemImage: "clock")
                            .font(.callout)
                    }
                }
                if let issue = sync.issue {
                    Label(issue, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).font(.callout).textSelection(.enabled)
                }
            }

            if !sync.status.conflicts.isEmpty {
                SettingsCard {
                    Label(localized("内容を選んでください", "Choose which version to keep"), systemImage: "exclamationmark.triangle.fill")
                        .font(.headline).foregroundStyle(.orange)
                    ForEach(sync.status.conflicts) { conflict in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(conflict.reason).font(.callout).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 8) {
                                Text(localized("この端末：", "This device: ") + conflict.name).bold()
                                Text(conflict.localDetail).foregroundStyle(.secondary)
                                Text(localized("受信した版：", "Received: ") + conflict.remoteName).bold()
                                Text(conflict.remoteDetail).foregroundStyle(.secondary)
                            }.font(.callout).textSelection(.enabled)
                            ViewThatFits(in: .horizontal) {
                                HStack { conflictButtons(conflict) }
                                VStack(alignment: .leading) { conflictButtons(conflict) }
                            }.disabled(sync.busy)
                        }
                        if conflict.id != sync.status.conflicts.last?.id { Divider() }
                    }
                }
            }

            SettingsCard {
                SettingsDetails(title: localized("接続の詳細", "Connection details")) {
                    if !sync.status.folder.isEmpty {
                        Text(sync.status.folder).font(.callout).foregroundStyle(.secondary)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Button(localized("同期フォルダを開く", "Open sync folder")) {
                            NSWorkspace.shared.open(URL(fileURLWithPath: sync.status.folder))
                        }
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack { folderButtons }
                        VStack(alignment: .leading) { folderButtons }
                    }.disabled(sync.busy)
                    Text(localized("Syncthingで共有した専用フォルダを指定します。転送状況はSyncthingで確認できます。", "Choose a dedicated folder shared with Syncthing. Check transfer progress in Syncthing."))
                        .font(.callout).foregroundStyle(.secondary)
                    Text(localized("オフライン中の変更は保持され、再接続後に反映されます。同期オンの表示は、相手への転送完了を意味しません。", "Offline changes are kept and applied after reconnection. Sync being on does not mean transfer to the other device is complete."))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .task { if HoverPocketRuntimeEnvironment.shared.externalIntegrationsEnabled { sync.start() } }
    }

    private var statusTitle: String {
        if sync.issue != nil { return localized("要確認", "Needs attention") }
        if !sync.status.conflicts.isEmpty { return localized("変更の重複", "Conflicting changes") }
        return localized(sync.status.enabled ? "同期オン" : "オフ", sync.status.enabled ? "Sync on" : "Off")
    }

    @ViewBuilder
    private var folderButtons: some View {
        Button(localized("新しい同期を作る…", "Create sync…")) { sync.chooseFolder(create: true) }
        Button(localized("既存の同期に参加…", "Join existing sync…")) { sync.chooseFolder(create: false) }
    }

    @ViewBuilder
    private func conflictButtons(_ conflict: LibrarySyncConflict) -> some View {
        Button(localized("この端末の内容を使う", "Keep this device’s version")) { sync.resolve(conflict, remote: false) }
        Button(localized("受信した内容を使う", "Keep received version")) { sync.resolve(conflict, remote: true) }
    }

    private func localized(_ japanese: String, _ english: String) -> String {
        language == .japanese ? japanese : english
    }
}
