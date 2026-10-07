import SwiftUI

struct LibraryDevicePairingSettings: View {
    let language: AppLanguage
    @ObservedObject private var pairing = LibraryDevicePairingController.shared
    @State private var removing: LibraryLinkedDevice?

    var body: some View {
        SettingsCard {
            Label(text("端末をつなぐ", "Connect devices"), systemImage: "laptopcomputer.and.arrow.down").font(.headline)
            Text(text("接続すると、ゴミ箱を含むライブラリ全体を相手と共有します。", "Connecting shares your entire library with the other device, including trash."))
                .font(.callout).foregroundStyle(.secondary)
            if pairing.busy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(phaseTitle).font(.callout)
                    Spacer()
                    Button(text("取り消す", "Cancel")) { pairing.cancel() }
                }
                if !pairing.code.isEmpty {
                    Text(pairing.code).font(.system(.title2, design: .monospaced).weight(.semibold)).textSelection(.enabled)
                        .accessibilityLabel(text("接続コード", "Connection code"))
                    Text(text("もう一方の端末で、このコードを入力してください。有効期限は5分です。", "Enter this code on the other device. It expires after 5 minutes."))
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let peer = pairing.peer {
                    Divider()
                    Text(peer.deviceName).font(.headline)
                    Text(peer.platform == "macos" ? "Mac" : "Windows").foregroundStyle(.secondary)
                    Text(text("確認番号：", "Verification: ") + pairing.verification)
                        .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Text(text("両方の端末に同じ確認番号が表示されていることを確認してください。", "Check that both devices show the same verification number."))
                        .font(.callout).foregroundStyle(.secondary)
                    if pairing.inviting && pairing.phase == .review {
                        Button(text("この端末との共有を許可", "Allow sharing with this device")) { pairing.approve() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                Button(text("接続コードを表示", "Show connection code")) { pairing.start() }
                HStack {
                    TextField(text("相手の接続コード", "Code from the other device"), text: $pairing.joinInput)
                        .textFieldStyle(.roundedBorder).onSubmit { join() }
                    Button(text("接続", "Connect")) { join() }.disabled(pairing.joinInput.isEmpty)
                }
                if pairing.phase == .complete {
                    Label(text("端末を接続しました。素材の転送が始まります。", "Device connected. Library transfer will begin."), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.callout)
                } else if pairing.phase == .cancelled {
                    Text(text("接続を取り消しました。", "Connection cancelled.")).font(.callout).foregroundStyle(.secondary)
                }
            }
            if let issue = pairing.issue {
                Label(errorText(issue), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
            }
        }
        SettingsCard {
            HStack {
                Label(text("接続済みの端末", "Linked devices"), systemImage: "desktopcomputer").font(.headline)
                Spacer()
                Button(text("更新", "Refresh")) { Task { await pairing.refreshDevices() } }.disabled(pairing.busy)
            }
            if pairing.deviceIssue {
                Text(text("接続一覧を取得できません。Syncthingが起動しているか確認してください。", "Could not load devices. Check that Syncthing is running."))
                    .font(.callout).foregroundStyle(.secondary)
            } else if pairing.devices.isEmpty {
                Text(text("まだ接続されていません。", "No linked devices yet.")).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(pairing.devices) { device in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(device.name)
                        Text(text(device.connected ? "オンライン" : "オフライン", device.connected ? "Online" : "Offline"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(text("解除…", "Unlink…")) { removing = device }.disabled(pairing.busy)
                }
            }
        }
        .alert(text("この端末との共有を解除しますか？", "Unlink this device?"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button(text("解除", "Unlink"), role: .destructive) {
                if let device = removing { Task { await pairing.remove(device) } }; removing = nil
            }
            Button(text("キャンセル", "Cancel"), role: .cancel) { removing = nil }
        } message: {
            Text(text("このライブラリの共有を停止します。すでに受け取った素材は両方の端末に残ります。", "Stops sharing this library. Copies already received remain on both devices."))
        }
    }

    private func join() { if !pairing.joinInput.isEmpty { pairing.start(code: pairing.joinInput) } }
    private var phaseTitle: String {
        switch pairing.phase {
        case .starting: text("接続を準備しています", "Preparing connection")
        case .review: text("相手の端末を確認してください", "Review the other device")
        case .applying: text("共有を設定しています", "Setting up sharing")
        default: text(pairing.inviting ? "相手の接続を待っています" : "相手の承認を待っています", pairing.inviting ? "Waiting for the other device" : "Waiting for approval")
        }
    }
    private func errorText(_ reason: String) -> String {
        switch reason {
        case "retry_soon": text("3秒ほど待ってから再試行してください。", "Wait a few seconds and try again.")
        case "invalid_code": text("接続コードを確認してください。", "Check the connection code.")
        case "different_library": text("別のライブラリには接続できません。元の接続を確認してください。", "This device belongs to a different library. Check the original connection.")
        case "timeout": text("有効期限が切れました。新しいコードで接続してください。", "The code expired. Connect using a new code.")
        case "peer_declined", "cancelled": text("相手が接続を取り消しました。", "The other device cancelled the connection.")
        case "rollback_failed": text("接続を完了できず、共有設定を戻せませんでした。接続の詳細とSyncthingを確認してください。", "Connection failed and sharing could not be rolled back. Check connection details and Syncthing.")
        case "remove_failed": text("解除できませんでした。Syncthingを確認して再試行してください。", "Could not unlink. Check Syncthing and try again.")
        default: text("接続できませんでした。両端末のSyncthingとネットワークを確認し、新しいコードで再試行してください。", "Could not connect. Check Syncthing and the network on both devices, then try a new code.")
        }
    }
    private func text(_ ja: String, _ en: String) -> String { language == .japanese ? ja : en }
}
