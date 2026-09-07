import AppKit
import Foundation
import SwiftUI

struct PocketAppGenerationSettingsView: View {
    @ObservedObject var controller: PocketAppGenerationController
    @ObservedObject var settings: AppSettings
    let language: AppLanguage
    var onOpenTool: ((String) -> Void)? = nil

    @State private var requestText = ""
    @State private var updateTarget: String?
    @State private var showRestoreConfirmation = false
    @State private var showsPreview = false
    @State private var removalTarget: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(localized(
                japanese: "欲しいツールを言葉で伝えてください。試しながら修正し、使える形になったら追加できます。",
                english: "Describe a tool you want. Try it, refine it, then add it to your panel."
            ))
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            workspaceBackupControls

            HStack {
                Text("GPT-6 Astra")
                Picker("推論の強さ", selection: $settings.pocketToolReasoningEffort) {
                    if !controller.supportedReasoningEfforts.contains(settings.pocketToolReasoningEffort) {
                        Text(settings.pocketToolReasoningEffort.capitalized + "（利用状況を確認中）").tag(settings.pocketToolReasoningEffort)
                    }
                    ForEach(controller.supportedReasoningEfforts, id: \.self) { effort in
                        Text(effort.capitalized).tag(effort)
                    }
                }
                Button { Task { await controller.refreshGeneratorModels() } } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("利用可能な推論設定を確認")
            }
            Text("既定はMediumです。変更は次の生成から反映します。")
                .font(.caption).foregroundStyle(.secondary)
            if let status = controller.generatorStatus { Text(status).font(.caption).foregroundStyle(.orange) }

            TextEditor(text: $requestText)
                .font(.system(size: 11))
                .frame(minHeight: 72, maxHeight: 110)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(.secondary.opacity(0.25), lineWidth: 1)
                )

            HStack(spacing: 8) {
                if controller.draftCheckpoint != nil {
                    Text("作成中: " + (controller.draftCheckpoint?.name ?? ""))
                        .font(.caption)
                    Button("別のツールを作る") { controller.startNewDraft(); updateTarget = nil }
                }
                if let updateTarget {
                    Text(localized(japanese: "更新: \(controller.packageTitle(updateTarget))", english: "Update: \(updateTarget)"))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Button(localized(japanese: "解除", english: "Clear")) {
                        self.updateTarget = nil
                    }
                }
                Spacer()
                if controller.phase == .generating {
                    ProgressView().controlSize(.small)
                    Text("ツールを作成しています…").font(.caption).accessibilityAddTraits(.updatesFrequently)
                    Button(localized(japanese: "キャンセル", english: "Cancel")) {
                        controller.cancelGeneration()
                    }
                } else {
                    Button(localized(japanese: "生成して検証", english: "Generate & Validate")) {
                        let text = requestText
                        let target = updateTarget
                        Task {
                            await controller.generate(userRequest: text, updating: target)
                            if controller.phase == .awaitingApproval {
                                updateTarget = nil
                            }
                        }
                    }
                    .disabled(
                        requestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || !controller.isGeneratorAvailable
                            || (controller.pendingProposal != nil && controller.draftCheckpoint == nil)
                            || controller.pendingWorkspaceRestore != nil
                    )
                }
            }

            if !controller.isGeneratorAvailable {
                Text(localized(
                    japanese: "Codexの生成接続を準備できませんでした。Codexのインストールとログインを確認してください。",
                    english: "The Codex connection could not be prepared. Check the installation and sign-in."
                ))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }

            if let proposal = controller.pendingProposal {
                proposalCard(proposal)
            }

            if let issue = controller.historyIssue { Text(issue).font(.caption).foregroundStyle(.orange) }
            if !controller.history.isEmpty {
                DisclosureGroup("変更履歴（ツールごとに20件・100 MiBまで）") {
                    ForEach(controller.history.prefix(60)) { checkpoint in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(checkpoint.name + (checkpoint.kind == "installed" ? " · 導入済み" : checkpoint.kind == "restored" ? " · 履歴を復元" : " · 作成途中"))
                                    .font(.caption.bold())
                                Text(checkpoint.summary).font(.caption).lineLimit(2)
                                Text(checkpoint.createdAt, format: .dateTime.month().day().hour().minute())
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("ここへ戻す") { controller.restoreCheckpoint(checkpoint) }
                                .disabled(controller.phase == .generating || controller.phase == .installing)
                        }.padding(.vertical, 4)
                    }
                    Text("復元で戻るのはツールの画面と動作です。記録したデータは保持します。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if let receipt = controller.lastReceipt, receipt.readbackVerified {
                Label(controller.packageTitle(receipt.packageID) + "の変更を確認しました。", systemImage: "checkmark.seal.fill")
                    .font(.caption).foregroundStyle(.green)
            }

            if let message = controller.errorMessage {
                Text(message).font(.caption).foregroundStyle(.red)
            }

            if let message = controller.removalMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }

            if !controller.uninstalledPackages.isEmpty {
                DisclosureGroup("アンインストール済み（記録を保持）") {
                    ForEach(controller.uninstalledPackages, id: \.packageID) { package in
                        HStack {
                            Text(controller.packageTitle(package.packageID))
                            Spacer()
                            if let checkpoint = controller.history.first(where: { $0.packageID == package.packageID }) {
                                Button("復元して確認") { controller.restoreCheckpoint(checkpoint) }
                            }
                            Button("記録も削除…", role: .destructive) { removalTarget = package.packageID }
                        }.padding(.vertical, 4)
                    }
                }.disabled(controller.managementIsBusy)
            }

            if !controller.managedPackages.isEmpty {
                Divider()
                Text(localized(japanese: "追加したツール", english: "Your tools"))
                    .font(.system(size: 11, weight: .bold))
                ForEach(controller.managedPackages, id: \.packageID) { package in
                    packageCard(package)
                }
            }

            if !controller.managementIssues.isEmpty {
                Divider()
                Text(localized(japanese: "要修復", english: "Needs repair"))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.orange)
                ForEach(controller.managementIssues, id: \.packageID) { issue in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(issue.packageID)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            Text(issue.errorCode)
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(.orange)
                        }
                        Spacer()
                        if issue.migrationAvailable, let targetVersion = issue.suggestedVersion {
                            Button(localized(japanese: "互換更新を準備", english: "Prepare compatibility update")) {
                                controller.prepareCapabilityMigration(
                                    packageID: issue.packageID,
                                    targetVersion: targetVersion
                                )
                            }
                            .font(.system(size: 9))
                            .disabled(controller.pendingWorkspaceRestore != nil)
                        }
                        Button(
                            localized(japanese: "削除…", english: "Remove…"),
                            role: .destructive
                        ) {
                            removalTarget = issue.packageID
                        }
                        .font(.system(size: 9))
                        .disabled(!issue.removalAllowed || controller.managementIsBusy)
                    }
                    .padding(9)
                    .background(.orange.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }
        }
        .confirmationDialog("「\(removalTarget.map(controller.packageTitle) ?? "ツール")」を削除", isPresented: Binding(
            get: { removalTarget != nil }, set: { if !$0 { removalTarget = nil } }
        ), titleVisibility: .visible) {
            if let packageID = removalTarget {
                if controller.managedPackages.contains(where: { $0.packageID == packageID }) {
                    Button("アンインストール（記録を残す）") {
                        if updateTarget == packageID { updateTarget = nil; requestText = "" }
                        controller.removeTool(packageID: packageID, includingData: false)
                    }
                }
                Button("記録・作成履歴も削除", role: .destructive) {
                    if updateTarget == packageID { updateTarget = nil; requestText = "" }
                    controller.removeTool(packageID: packageID, includingData: true)
                }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("記録を残すと、履歴からツールを戻せます。記録も削除すると、ツールの定義・保存した記録・作成履歴・アプリ内の移行前バックアップをゴミ箱へ移します。標準機能、作成した付箋・タイマー・予定、書き出したバックアップには影響しません。")
        }
        .task { await controller.refreshGeneratorModels() }
        .sheet(isPresented: $showsPreview) {
            VStack(spacing: 8) {
                HStack {
                    Text("ツールを試す").font(.headline)
                    Spacer()
                    Button("閉じる") { showsPreview = false }
                }.padding()
                Text("試し入力は導入後に引き継がれません。外部サービスへの操作は導入後に利用できます。")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                if let model = controller.previewModel {
                    PocketSurfaceHostView(model: model).id(model.runtimeIdentity)
                        .environment(\.panelTextSize, settings.panelTextSize)
                        .frame(width: PanelLayout.previewSize(for: settings.panelSize).width,
                               height: PanelLayout.previewSize(for: settings.panelSize).height - 60)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding([.horizontal, .bottom])
                }
            }.fixedSize(horizontal: true, vertical: true)
        }
        .alert(
            localized(japanese: "Pocket App workspaceを復元", english: "Restore Pocket App workspace"),
            isPresented: $showRestoreConfirmation,
            presenting: controller.pendingWorkspaceRestore
        ) { _ in
            Button(localized(japanese: "キャンセル", english: "Cancel"), role: .cancel) {}
                .keyboardShortcut(.defaultAction)
            Button(localized(japanese: "復元", english: "Restore"), role: .destructive) {
                controller.approveWorkspaceRestore()
            }
        } message: { proposal in
            Text(localized(
                japanese: "検証済みの\(proposal.changes.count)件を置き換えます。失敗時は事前snapshotへ戻します。",
                english: "Replace \(proposal.changes.count) validated app(s). Failure restores the pre-restore snapshot."
            ))
        }
    }

    @ViewBuilder
    private var workspaceBackupControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Button(localized(japanese: "ツールと記録をバックアップ", english: "Back up tools and records")) {
                    let panel = NSSavePanel()
                    panel.canCreateDirectories = true
                    panel.nameFieldStringValue = "HoverPocket-PocketApps.hoverpocket-backup.json"
                    if panel.runModal() == .OK, let url = panel.url {
                        controller.exportWorkspace(to: url)
                    }
                }
                Button(localized(japanese: "バックアップから復元", english: "Restore from backup")) {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        controller.prepareWorkspaceRestore(from: url)
                    }
                }
            }

            if let proposal = controller.pendingWorkspaceRestore {
                VStack(alignment: .leading, spacing: 5) {
                    Text(localized(japanese: "復元preview", english: "Restore preview"))
                        .font(.system(size: 10, weight: .bold))
                    ForEach(proposal.changes, id: \.appID) { change in
                        Text(
                            "\(change.action) · \(change.appID) · \(change.fromVersion ?? "-") → \(change.toVersion) · state \(change.fromLifecycleState ?? "-") → \(change.toLifecycleState) · permissions +\(change.addedPermissions.count)/-\(change.removedPermissions.count) · data \(change.dataChanged ? "changed" : "same")"
                        )
                        .font(.system(size: 8, design: .monospaced))
                        .textSelection(.enabled)
                    }
                    HStack {
                        Button(localized(japanese: "取消", english: "Cancel"), role: .cancel) {
                            controller.rejectWorkspaceRestore()
                        }
                        Spacer()
                        Button(localized(japanese: "復元内容を確認", english: "Review restore")) {
                            showRestoreConfirmation = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(8)
                .background(.blue.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }

            if let receipt = controller.lastWorkspaceRestoreReceipt, receipt.readbackVerified {
                Label(
                    localized(
                        japanese: "復元後readback確認済み: \(receipt.restoredApps.count)件",
                        english: "Post-restore readback verified: \(receipt.restoredApps.count) app(s)"
                    ),
                    systemImage: "checkmark.shield.fill"
                )
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.green)
            } else if let digest = controller.lastWorkspaceBackupDigest {
                Text(localized(
                    japanese: "backup readback確認済み: \(shortDigest(digest))",
                    english: "Backup readback verified: \(shortDigest(digest))"
                ))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
            }

            if let error = controller.workspaceBackupErrorCode {
                Text(error)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.red)
            }

            Text(localized(
                japanese: "ツールと保存した記録をまとめて保存します。ログイン情報は含みません。",
                english: "Save your tools and records together. Sign-in information is not included."
            ))
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.quaternary.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    @ViewBuilder
    private func proposalCard(_ proposal: PocketAppLifecycleProposal) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let migration = proposal.dataMigration {
                Text("保存項目の変更を確認してください").font(.headline)
                ForEach(migration.summary, id: \.self) { Text($0).font(.callout) }
                Text("導入時に元のデータをバックアップします。確認後に記録が更新された場合は、再確認が必要になります。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text(controller.draftCheckpoint?.name ?? controller.packageTitle(proposal.packageID))
                    .font(.system(size: 11, weight: .bold))
                Spacer()
            }
            if controller.previewModel != nil {
                Button("プレビューで試す", systemImage: "play.rectangle") { showsPreview = true }
                    .buttonStyle(.borderedProminent)
                Text("修正したい点を上に入力すると、作成中のツールを続けて変更できます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(controller.previewValidationSummary)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("検証と権限の詳細") {
            Text(shortDigest(proposal.packageDigest)).font(.caption.monospaced())
            Text(PocketAppGenerationApprovalPresentation.text(
                proposal,
                source: controller.pendingAllowsActivation ? "host-verified-package" : "codex-preview-only"
            ))
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            ForEach(proposal.previews, id: \.id) { preview in
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(preview.id) · \(shortDigest(preview.renderDigest))")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(previewText(preview))
                        .font(.system(size: 8, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(14)
                }
                .padding(6)
                .background(.quaternary.opacity(0.18))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            Text("tests \(proposal.tests.filter { $0.status == $0.expected }.count)/\(proposal.tests.count)")
                .font(.system(size: 9, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(localized(japanese: "導入を取り消す", english: "Cancel installation"), role: .cancel) {
                    controller.rejectPending()
                }
                Spacer()
                Button(localized(japanese: "このツールを追加・更新", english: "Add or update this tool")) {
                    controller.approveAndInstall(
                        requestID: proposal.requestID,
                        bindingDigest: proposal.bindingDigest
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(!controller.pendingAllowsActivation)
            }
            if !controller.pendingAllowsActivation {
                Text(localized(
                    japanese: "実Codexの生成物は保存先境界の追加検証が完了するまでpreviewのみです。",
                    english: "Real Codex output is preview-only until the storage boundary gate is complete."
                ))
                .font(.system(size: 9))
                .foregroundStyle(.orange)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.28))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private func packageCard(_ package: PocketAppManagedPackage) -> some View {
        let rollbackVersions = PocketAppGenerationController.rollbackVersions(
            installedVersions: package.installedVersions,
            currentVersion: package.version
        )
        let health = controller.appHealth.first { $0.packageID == package.packageID }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(controller.packageTitle(package.packageID))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(package.state == .enabled ? "利用中" : "停止中")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if let health {
                HStack(spacing: 5) {
                    Image(systemName: health.status == .attention ? "exclamationmark.triangle.fill" : "heart.text.square")
                    Text(healthText(health))
                }
                .font(.system(size: 9, weight: health.disableSuggested ? .semibold : .regular))
                .foregroundStyle(health.disableSuggested || health.status == .attention ? .orange : .secondary)
            }
            HStack(spacing: 7) {
                if package.state == .enabled, let onOpenTool {
                    Button("パネルで開く") { onOpenTool(package.packageID) }
                }
                Button(localized(japanese: "会話で修正", english: "Refine")) {
                    updateTarget = package.packageID
                }
                if package.state == .enabled {
                    Button(localized(japanese: "無効化", english: "Disable")) {
                        controller.disable(packageID: package.packageID)
                    }
                } else if package.state == .disabled {
                    Button(localized(japanese: "有効化", english: "Enable")) {
                        controller.enable(packageID: package.packageID)
                    }
                }
                Menu(localized(japanese: "ロールバック", english: "Rollback")) {
                    ForEach(rollbackVersions, id: \.self) { version in
                        Button(version) {
                            controller.prepareRollback(packageID: package.packageID, version: version)
                        }
                    }
                }
                .disabled(rollbackVersions.isEmpty)
                Button(localized(japanese: "削除…", english: "Remove…"), role: .destructive) {
                    removalTarget = package.packageID
                }
            }
            .font(.system(size: 9))
            .disabled(controller.managementIsBusy)
        }
        .padding(9)
        .background(.quaternary.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func previewText(_ preview: PocketAppPreviewSurface) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: preview.canonicalRenderModel),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return localized(japanese: "previewを表示できません", english: "Preview unavailable")
        }
        let bounded = text.unicodeScalars.count > 3_000 ? text.prefixingUnicodeScalars(3_000) + "…" : text
        return PocketSurfaceHostModel.sanitizeVisibleText(bounded)
    }

    private func shortDigest(_ digest: String?) -> String {
        guard let digest else { return "-" }
        return digest.count > 22 ? String(digest.prefix(22)) + "…" : digest
    }

    private func healthText(_ health: PocketAppHealthSnapshot) -> String {
        switch health.status {
        case .healthy:
            return localized(japanese: "正常", english: "Healthy")
        case .disabled:
            return localized(japanese: "無効化済み", english: "Disabled")
        case .unused:
            return localized(
                japanese: "30日以上未使用です。必要なければ無効化できます。",
                english: "Unused for 30+ days. You can disable it if no longer needed."
            )
        case .attention:
            return localized(
                japanese: "要確認: \(health.reasonCode)",
                english: "Needs attention: \(health.reasonCode)"
            )
        }
    }

    private func localized(japanese: String, english: String) -> String {
        language == .japanese ? japanese : english
    }
}
