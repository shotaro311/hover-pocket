---
project_slug: hover-menu-preview
date: 2026-06-10
updated_by: codex
status: active
---

# 2026-06-10 HoverPocket progress

## 実装

- `feature/ai-native-phase1` で AI native Phase 1 MVP を実装。
- `AIModelProvider` と能力宣言型を追加し、Apple Foundation Models provider を追加。
- `PocketAction`、`ToolResult`、`IntentPlan`、`ApprovalGate`、`AuditLog` の基盤型を追加。
- Calendar read / Calendar write tool を追加。write action は `ApprovalGate` 承認後だけ実行し、tool 側でも未承認実行を拒否する。
- 承認 UI は `PocketAction.approvalFields` から生成し、モデル生成文を表示しない構成にした。
- Hover panel 下部に独立した command palette lane を追加。既存 provider の hover 表示経路では AI 処理を走らせない。
- 意図が曖昧な入力では `IntentPlan.candidates` をボタン表示し、ユーザーが解釈候補を選べる fallback UI を追加。
- Review fix: ApprovalCard で全 `approvalFields` を表示するよう修正。`PocketAction.requiresApproval` を `kind` 由来の computed property に変更し、Calendar write は常に承認必須にした。

## 検証

- `swift build` 成功。
- Review fix 後の `swift build` 成功。

## 残課題

- Apple Foundation Models の実機可用性は macOS 26 / Apple Intelligence 環境で追加確認が必要。
- Calendar write は既存どおり Google Calendar の write scope 再接続が必要。
- Phase 1 の対象外として、Ollama、Codex harness、Clipboard Tool、マルチステップ自律実行、チャット履歴は未実装。
