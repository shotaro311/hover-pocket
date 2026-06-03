---
project_slug: hover-menu-preview
updated: 2026-06-03
updated_by: codex
status: active
---

# Project Progress: hover-menu-preview

## 概要

- macOS 画面上部の黒い pill にホバーすると、Codex/Claude session 風の黒い preview panel が出る prototype app。
- `/Users/shotaro/Documents/Codex/.../outputs/hover-menu-preview` で作成した prototype を、開発継続用に `/Users/shotaro/code/share/hover-menu-preview` へ移行済み。

## 最新の検証済み状態

- 移行元 prototype は `./script/build_and_run.sh --verify` 成功済み。
- 移行先 `/Users/shotaro/code/share/hover-menu-preview` で `./script/build_and_run.sh --verify` 成功済み。
- 2026-06-03: 上部 pill の 5pt top inset を削除し、`CGWindowListCopyWindowInfo` で `Y = 0` を確認済み。
- 2026-06-03: preview panel の opening animation を追加し、`optionOnScreenOnly` の frame sampling で `h=199 -> 267 -> 297 -> 308 -> 312` への拡大を確認済み。
- 2026-06-03: pill を top corners square / bottom corners rounded の top-docked shape に変更し、window 切り出しで確認済み。
- 2026-06-03: pill height を 33pt に伸ばし、下端の細い隙間を抑えたことを切り出し画像と window frame で確認済み。
- 2026-06-03: notch sizing と `33pt = safeAreaInsets.top + 1pt` の設計メモを `README.md` に記録済み。
- 2026-06-03: 二段階の `neck / elastic overshoot` animation はもっさり見えたため撤回し、直前の `source -> final` のシンプルなノッチ中央 morphing に戻したことを確認済み。
- 2026-06-03: preview close animation を open と同じ `0.32s` にし、timing curve も open の逆カーブにして、開く動きの逆再生として閉じることを frame sampling で確認済み。
- 2026-06-03: top pill の text / session count 表示を消し、ノッチ左側の小さい `arrow.right` handle だけを表示する状態に変更済み。
- 2026-06-03: `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` から実ノッチ幅を取り、left handle 右端をノッチ左端へ揃えて、ノッチ裏まで黒い UI base を敷くように変更済み。
- 2026-06-03: top pill の shadow を無効化し、上端 `3pt` を黒で overfill して、上部の細いスリット状の抜けを埋めたことをピクセル検査で確認済み。
- 2026-06-03: 左上 handle のラウンド形状変更は意図と違ったため撤回し、元の連続した黒ベース形状へ戻したことを確認済み。
- 2026-06-03: `main.swift` の単一ファイル構成を App / Windowing / State / Models / Providers / Views / Support に分割し、今後の追加機能を `NotchProvider` として差し込む土台へ変更。デモ用 sessions / usage 表示は削除済み。
- 2026-06-03: Display placement 設定を追加。`Auto / Main / Sub` で表示先を選べるようにし、ノッチなし画面では fake notch ではなく top-center handle に切り替えるよう変更済み。

## 進行中

- Codex: ノッチ shell と provider-hosted content の分離、display placement 設定を実装済み。次は実データ provider の要件定義。

## 次アクション

- `./script/build_and_run.sh --verify` で移行先の build / launch を確認する。
- アプリ化の要件を決める: app name、最初に実装する provider、終了/自動起動、データ取得元。

## Blocker / Risk

- 現時点はローカル prototype。署名、notarization、LaunchAgent、自動起動は未実装。
- 機密情報や token は含めていない。

## 引き継ぎ

- Project root: `/Users/shotaro/code/share/hover-menu-preview`
- Run: `./script/build_and_run.sh --verify`
- UI source: `Sources/HoverMenuPreview/Views/`
- Windowing source: `Sources/HoverMenuPreview/Windowing/`
- Provider source: `Sources/HoverMenuPreview/Providers/`

## 重要パス

- Project root: `.`

## 詳細ログ

- [2026-06-03](2026-06/2026-06-03_hover-menu-preview.md)
- [2026-06-02](2026-06/2026-06-02_hover-menu-preview.md)

## 旧進捗ソース

- 一時成果物: `/Users/shotaro/Documents/Codex/2026-06-02/files-mentioned-by-the-user-2026/outputs/hover-menu-preview`

## 移行検証後の削除候補

- [cleanup-candidates.md](cleanup-candidates.md)

## 最近の更新

- 2026-06-03: 二段階の neck / overshoot animation を撤回し、直前の軽い morphing に戻した。
- 2026-06-03: preview close animation を open animation の逆再生に調整。
- 2026-06-03: top pill を文字なしの左側 arrow handle 表示へ変更。
- 2026-06-03: top pill の黒ベースを実ノッチ幅に合わせ、ノッチ裏の隙間を解消。
- 2026-06-03: top pill 上端のスリット状の抜けを黒 overfill で解消。
- 2026-06-03: 左上 handle のラウンド形状変更を撤回し、元の形へ復帰。
- 2026-06-03: Provider/Registry/Store の基盤を追加し、デモ用 sessions / usage 表示を削除。
- 2026-06-03: 設定ウィンドウを追加し、表示先を `Auto / Main / Sub` から選べるように変更。
- 2026-06-03: preview morphing を上部ノッチ中央から出て、上部ノッチ中央へ戻る動きに調整。
- 2026-06-03: notch sizing / point-pixel compensation の設計メモを README に追記。
- 2026-06-03: pill の下端の隙間を抑えるため、pill height を 33pt に調整。
- 2026-06-03: pill の上左右を丸めず、画面上面に接する top-docked design に調整。
- 2026-06-03: preview panel が pill 下端に接した小さいカプセルから液体的に広がる opening animation を追加。
- 2026-06-03: 上部 pill の位置を画面上端へ合わせ、余白 0pt に調整。
- 2026-06-02: Prototype app を `/Users/shotaro/code/share/hover-menu-preview` に移行し、開発用 Git repository と `.gitignore` を用意。
- 2026-06-02: 共通進捗管理を初期化。
