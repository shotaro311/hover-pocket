---
project_slug: hover-menu-preview
date: 2026-06-21
updated_by: codex
status: active
---

# 2026-06-21 hover-menu-preview

## 実施内容

- Settings / Calendar 追加・編集 UI を日本語前提の文言へ最適化し、Settings の `言語` から `日本語` / `English` を切り替えられるようにした。
- `AppLocalization.swift` を追加し、`AppSettings.appLanguage` を `UserDefaults` に永続化する構成にした。既定言語は日本語。
- Settings、Google Calendar、status bar menu、provider header、empty provider view、Calendar 日時入力ヘルプを `AppText` 経由の表示に変更。
- Mirror、Clipboard、Sticky Notes、AI command lane の固定表示文言も主要箇所を `AppLanguage` に接続し、言語切り替え時に表層 UI が追従するようにした。
- Provider header の機能切り替えアイコンを drag & drop で並べ替えできるようにした。drag 中は対象アイコンを薄く表示し、drop target には subtle ring を出す。順序は既存の provider order 設定へ保存する。
- 既存の左右移動 context menu と Settings の provider toggle は維持し、ノッチ形状や top pill geometry は変更していない。

## 成果物

- Release: `https://github.com/shotaro311/hover-pocket/releases/tag/v0.1.0-59`
- Latest install ZIP: `https://github.com/shotaro311/hover-pocket/releases/latest/download/HoverPocket-macOS-app.zip`
- Latest appcast: `https://github.com/shotaro311/hover-pocket/releases/latest/download/appcast.xml`
- ZIP: `dist/releases/HoverPocket-0.1.0-59.zip`
- ZIP SHA256: `46c65fa9d120df68fe76e237d3bd0951f024242e64477a9a32ccffecab85f652`
- Notary submission ID: `34f55cc8-e245-4b1e-aacb-9248526ad47a`
- Notary status: `Accepted`

## 検証

- `swift build`: 成功。
- `git diff --check`: 成功。
- `./script/build_and_run.sh --verify`: 成功。Apple Development 署名で `dist/HoverPocket.app` を起動確認。
- `APP_VERSION=0.1.0 NOTARYTOOL_PROFILE=hover-pocket ./script/publish_github_release.sh`: build `59` の notarization / staple / GitHub Release 公開まで成功。
- `gh release view v0.1.0-59 --json assets,body,url,name,tagName`: `HoverPocket-macOS-app.zip`、`HoverPocket-0.1.0-59.zip`、SHA256、`appcast.xml` の4 asset を確認。
- 公開URL `https://github.com/shotaro311/hover-pocket/releases/latest/download/appcast.xml`: `sparkle:version` が `59`、enclosure が `v0.1.0-59/HoverPocket-0.1.0-59.zip` であることを確認。
- `zipinfo -1 dist/releases/HoverPocket-0.1.0-59.zip`: top-level が `HoverPocket.app` のみであることを確認。
- `shasum -a 256 dist/releases/HoverPocket-0.1.0-59.zip`: SHA256 が `.sha256` と一致。
- `codesign --verify --deep --strict --verbose=2 dist/HoverPocket.app`、`stapler validate dist/HoverPocket.app`、`spctl --assess --type execute --verbose=4 dist/HoverPocket.app`: 成功、`source=Notarized Developer ID`。
- `codesign -d --entitlements :- dist/HoverPocket.app`: camera / audio-input entitlements 入りを確認。

## 残り

- 実機操作で Settings の言語切り替え後、Settings / Calendar / Mirror / Clipboard / Sticky Notes / AI lane の表層文言が意図通り即時反映されるかを見る。
- Provider header の drag & drop reorder を、trackpad / mouse の両方で手動確認する。
