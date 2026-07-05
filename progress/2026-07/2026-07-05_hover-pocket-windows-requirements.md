---
project_slug: hover-pocket
date: 2026-07-05
updated_by: codex
status: draft-integrated
---

# 2026-07-05 Windows 版要件定義

## 実施内容

- `docs/requirement/requirements.md` を作成し、Windows 版で再現すべき体験、機能、操作感、Windows 固有制約、受け入れ条件を整理。
- サブエージェント 3 体で、既存 macOS 版の本質抽出、Windows API 代替調査、受け入れテスト/失敗モード整理を分担。
- 既存リポジトリの `README.md`、`progress/progress.md`、`Package.swift`、`Sources/HoverPocket/**` を読み、Provider、Settings、Windowing、Store、OAuth、Updater、AI lane の要件へ反映。
- Windows App SDK / WinUI 3、Tauri v2、WebView2 hybrid は候補として整理し、要件段階では最終技術スタックを固定しない方針にした。

## 要件化した主要範囲

- 画面上端ミニバーから hover で開閉する常駐 tray app。
- Access surface と preview panel surface の責務分離。
- Main / Sub / All のマルチディスプレイ対応と mixed DPI 対応。
- Provider: Mirror、Controls、Calendar、Clipboard、Sticky Notes、Timer、Calculator、AI command lane。
- Settings: 言語、表示先、サイズ、文字サイズ、provider 切替/順序/表示、handle icon、mirror mic、sticky undo、Windows 起動時実行、Clipboard private mode、fullscreen 抑制、data folder、privacy settings 導線。
- データ保存、Credential Manager/DPAPI、Clipboard privacy、audit log、配布署名、更新、Windows 固有失敗モード。
- Phase 0 から Phase 4 までの段階的リリースと、shell/provider/non-functional の受け入れテスト。

## 参照した一次情報

- Microsoft Learn: Windows App SDK、notification area、SetWindowPos、clipboard listener、Core Audio EndpointVolume、Monitor Configuration、GlobalSystemMediaTransportControlsSessionManager、Windows Graphics Capture、Credential Locker、MSIX。
- Google Developers: OAuth 2.0 for native apps。
- Microsoft Edge WebView2 docs: distribution / developer guide。
- Tauri v2 docs: system tray / deep linking。

## 検証

- 要件書の章構成を `rg -n "^(#|##|###) "` で確認。
- `git diff --check`: 成功。

## 未実施

- Windows 版の実装は未着手。
- Windows の実 API spike は未実施。
- `swift build` は Windows 環境に `swift` toolchain がないため未実行。
- `AGENTS.md` と `PROJECT.md` の作成/整理は未実施。運用ルール上、次の整理対象として残す。
