---
project_slug: hover-menu-preview
date: 2026-08-06
status: planning-reviewed; implementation-not-started
---

# Codex Voice Lane ブランチ整理・実装前レビュー

## 実施内容

- 古いDraft PR #3 `feat: AI Native化 Phase 1 — AIコマンドパレットとCalendar Tool基盤` は、後続の `main` に内容が取り込まれ、head branchが `main` より先行していないことを確認した。
- PR #3へsupersededの理由をコメントし、未マージのままcloseした。
- 既存 `feature/codex-voice-lane` は、Windows 0.2.5公開後の最新 `main` `bb8f06ab103dba594d62dbef94f3b6a19a60a8fa` を親にして履歴を再構成する。
- 既存の計画書 `docs/plan/20260806-codex-voice-lane-plan.md` を保持した。
- 実装前レビューを `docs/report/20260806-codex-voice-lane-architecture-review.md` に追加した。

## レビュー結論

方向性は妥当。ただし、実装開始前に次の3件を設計へ反映する。

1. Voice session / app-server / thread状態を `PanelWindow` とWebView2の寿命から分離する。
2. UI用 `BridgeDispatcher` をapp-server JSON-RPC clientとして流用せず、専用clientを作る。
3. `AiLaneHeight` の静的定数をやめ、disabled / compact / expandedを含む動的レイアウト状態にする。

## 現在地

- Codex Voice Laneの実装コード: 未着手
- Phase 0の実接続・課金経路・session上限・Desktop可視性・非アクティブWebView microphone: 未実測
- Draft PR: 最新 `main` 向けに作成し、以後の実装レビュー面として使用する

## 実装開始条件

- アーキテクチャレビューのCritical 3件を計画へ反映する。
- Phase 0 / 0.5のprobe結果をreportとして記録する。
- feature off時にapp-server起動、microphone permission、global hotkey登録、panel height増加が発生しない設計を固定する。

## 検証

今回は計画・レビュー文書とGitHub履歴の整理のみ。アプリコード変更、build、verifier、release操作は行っていない。