import Foundation
import SwiftUI

struct PocketAppGenerationSettingsView: View {
    @ObservedObject var controller: PocketAppGenerationController
    let language: AppLanguage

    @State private var requestText = ""
    @State private var updateTarget: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(localized(
                japanese: "自然言語からPocket App定義を生成します。生成物はHostが再検証し、承認するまで導入されません。",
                english: "Generate Pocket App definition files from natural language. The Host revalidates them and never installs before explicit approval."
            ))
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $requestText)
                .font(.system(size: 11))
                .frame(minHeight: 72, maxHeight: 110)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(.secondary.opacity(0.25), lineWidth: 1)
                )

            HStack(spacing: 8) {
                if let updateTarget {
                    Text(localized(japanese: "更新: \(updateTarget)", english: "Update: \(updateTarget)"))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Button(localized(japanese: "解除", english: "Clear")) {
                        self.updateTarget = nil
                    }
                }
                Spacer()
                if controller.phase == .generating {
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
                            || controller.pendingProposal != nil
                    )
                }
            }

            if !controller.isGeneratorAvailable {
                Text(localized(
                    japanese: "Codex CLIを検出できないため生成は利用できません。既存Pocket Appの管理は継続できます。",
                    english: "Codex CLI is unavailable, so generation is disabled. Existing Pocket Apps can still be managed."
                ))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }

            if let proposal = controller.pendingProposal {
                proposalCard(proposal)
            }

            if let receipt = controller.lastReceipt, receipt.readbackVerified {
                Label(
                    localized(
                        japanese: "readback確認済み: \(receipt.action) \(receipt.packageID) \(receipt.version ?? "-") \(shortDigest(receipt.packageDigest))",
                        english: "Readback verified: \(receipt.action) \(receipt.packageID) \(receipt.version ?? "-") \(shortDigest(receipt.packageDigest))"
                    ),
                    systemImage: "checkmark.seal.fill"
                )
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.green)
            }

            if let errorCode = controller.errorCode {
                Text(errorCode)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.red)
            }

            if !controller.managedPackages.isEmpty {
                Divider()
                Text(localized(japanese: "Host管理中", english: "Host-managed"))
                    .font(.system(size: 11, weight: .bold))
                ForEach(controller.managedPackages, id: \.packageID) { package in
                    packageCard(package)
                }
            }
        }
    }

    @ViewBuilder
    private func proposalCard(_ proposal: PocketAppLifecycleProposal) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(proposal.action.rawValue) · \(proposal.packageID) · v\(proposal.version)")
                    .font(.system(size: 11, weight: .bold))
                Spacer()
                Text(shortDigest(proposal.packageDigest))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
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
            HStack {
                Button(localized(japanese: "拒否", english: "Reject"), role: .cancel) {
                    controller.rejectPending()
                }
                Spacer()
                Button(localized(japanese: "このbytesを承認して導入", english: "Approve exact bytes & install")) {
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
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(package.packageID)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                Spacer()
                Text("\(package.state.rawValue) · v\(package.version ?? "-")")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Text(shortDigest(package.packageDigest))
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.secondary)
            HStack(spacing: 7) {
                Button(localized(japanese: "更新", english: "Update")) {
                    updateTarget = package.packageID
                }
                if package.state == .enabled {
                    Button(localized(japanese: "無効化", english: "Disable")) {
                        controller.disable(packageID: package.packageID)
                    }
                }
                Menu(localized(japanese: "ロールバック", english: "Rollback")) {
                    ForEach(package.installedVersions.filter { $0 != package.version }, id: \.self) { version in
                        Button(version) {
                            controller.prepareRollback(packageID: package.packageID, version: version)
                        }
                    }
                }
                .disabled(package.installedVersions.filter { $0 != package.version }.isEmpty)
                Button(localized(japanese: "削除（データ保持）", english: "Remove, preserve data"), role: .destructive) {
                    controller.removePreservingData(packageID: package.packageID)
                }
            }
            .font(.system(size: 9))
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

    private func localized(japanese: String, english: String) -> String {
        language == .japanese ? japanese : english
    }
}
