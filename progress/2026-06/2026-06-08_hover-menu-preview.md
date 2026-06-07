---
project_slug: hover-menu-preview
date: 2026-06-08
updated_by: codex
status: active
---

# 2026-06-08 hover-menu-preview

## 実施内容

- パネルを開いたまま上部の provider アイコンを切り替えたとき、機能表示は切り替わるのにヘッダーのアイコン選択状態が更新されない問題を修正。
- 原因は `HoverPanelShell` が `HoverMenuStore` だけを監視し、ヘッダー内で参照している `ProviderStore.selectedPluginID` の変更を直接監視していなかったこと。
- `ProviderHeaderView` を追加し、ヘッダー部分が `ProviderStore` を `@ObservedObject` として直接監視するように変更。
- これにより、選択中タイトル、アイコンの選択ハイライト、provider 順序表示が `ProviderStore` の変更に合わせて更新される。
- GitHub Actions `Codex PR Router` を追加。PR作成/更新/レビュー時に変更ファイルを分類し、`origin:mac`、`codex-autofix`、`needs-human-merge`、`codex-automerge-safe` を自動付与する。
- docs/progress/Markdown だけの低リスクPRは `codex-automerge-safe` にし、trusted author の場合だけ auto-merge を有効化する。

## 検証

- `swift build`: 成功。
- `git diff --check`: 成功。
- `./script/build_and_run.sh --verify`: 成功、`NotchPokke launched` を確認。
- `github-codex-autofix` helper の `list-targets --worker mac/windows`: 対象PRなしで即終了することを確認。
- GitHub labels: `codex-autofix`、`codex-automerge-safe`、`needs-human-merge`、`origin:mac`、`origin:windows`、`codex-claimed:mac`、`codex-claimed:windows` を作成/更新済み。

## 未完了 / 注意

- 実画面での連続クリック確認はユーザー側の体感確認が必要。
- GitHub Actions の初回実動作は、次回PR作成/更新時に GitHub 側で確認する。
