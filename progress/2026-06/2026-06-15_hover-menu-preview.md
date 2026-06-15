---
project_slug: hover-menu-preview
date: 2026-06-15
updated_by: codex
status: active
---

# 2026-06-15 HoverPocket progress

## 実装

- AI command palette を preview 表示時に自動フォーカスするよう修正。
- Apple Foundation Models 対応環境では `@Generable` 型で structured output を受ける経路を追加し、非対応環境では既存 fallback を維持。
- Calendar write 承認プレビューに、予定名・日時・カレンダーを一瞬で読める summary を追加。構造化フィールド一覧は省略せず維持。
- Calendar event editor の日付/時刻入力を `DatePicker` から手入力可能な数値セグメント UI へ変更。
- 日付/時刻セグメントはフォーカス時に調整バーを表示し、左右ドラッグで値を変更できるようにした。
- Calendar の日付セルをダブルクリックすると、その日の新規予定 editor を直接開くようにした。
- Product Compass レポートを `product-compass-reports/2026-06-15-hoverpocket-ai-pocket.html` に生成し、6/22 の伊勢田さん向け検証方針を整理。
- AI command の deterministic shortcut をモデル実行より優先し、`今日の予定`、`明日14時 打ち合わせ`、`金曜 デザイン納期`、`来週月曜10時 撮影 場所: 天神` の検証入力に寄せて強化。
- Calendar write 承認 summary に場所とメモも表示し、構造化フィールドの順序をタイトル、日時、場所、メモ、カレンダーへ調整。
- 6/22 の観察チェックリストを `progress/2026-06/2026-06-22_calendar-pocket-validation.md` に追加。

## 検証

- `swift build` 成功。
- `git diff --check` 成功。
- `./script/build_and_run.sh --verify` 成功。
- Computer Use / System Events で handle クリックを試したが、この環境では hover panel を開くイベントを再現できず、実画面での崩れ確認は未完了。
- Product Compass レポート追加後、`docs: Product Compassレポートを追加` をコミット済み。
- 一時 Swift 検証で、上記4入力がそれぞれ `2026-06-15 read`、`2026-06-16 14:00 打ち合わせ`、`2026-06-19 all-day デザイン納期`、`2026-06-22 10:00 撮影 / 場所: 天神` に解釈されることを確認。

## 残課題

- 実機操作で、AI command palette の自動フォーカス、Calendar 日付ダブルクリック、日時セグメントの手入力/ドラッグ調整、承認プレビュー表示を確認する。
- Apple Foundation Models の `@Generable` 経路は macOS 26 / Apple Intelligence 対応SDKと実機で追加確認が必要。
