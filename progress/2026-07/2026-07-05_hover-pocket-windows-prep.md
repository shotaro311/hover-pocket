---
project_slug: hover-pocket
date: 2026-07-05
updated_by: codex
status: active
---

# 2026-07-05 Windows 作業準備

## 実施内容

- GitHub の public repository `shotaro311/hover-pocket` を Windows の `C:\Users\shotaro\code\shared\hover-pocket` へ clone。
- `origin` が `https://github.com/shotaro311/hover-pocket.git` を指していることを確認。
- HEAD が `0cd6ec1 build 98 の配信結果を記録` で、`main...origin/main` に差分がないことを確認。
- GitHub latest release が `v0.1.0-98` / `HoverPocket 0.1.0 (98)` であることを確認。
- Serena project を `hover-pocket` として有効化し、`core` / `tech_stack` / `suggested_commands` / `conventions` / `task_completion` メモリを登録。
- Serena のローカルメタデータ `.serena/` は Git に混ざらないよう `.git/info/exclude` へ local exclude として追加。

## 検証

- `git diff --check`: 成功。
- `git status -sb`: `## main...origin/main`。
- `bash --version`: GNU bash 5.3.9 を確認。
- `swift --version`: Windows の PATH 上に `swift` がなく失敗。

## Windows 対応の初期所見

- 現行 `Package.swift` は `swift-tools-version: 6.0`、platform `.macOS(.v14)` の SwiftPM executable。
- 主要依存は Sparkle と `mediaremote-adapter`。どちらも現在のアプリの macOS 配布・メディア操作文脈に強く結びついている。
- ソースは AppKit / SwiftUI / AVFoundation / CoreAudio / ScreenCaptureKit / IOKit / Sparkle / FoundationModels など macOS API 依存が広い。
- Windows 対応は、まず Calendar/Clipboard/Timer/Calculator/Sticky Notes などの再利用可能な domain/state と、AppKit/NSPanel/ScreenCapture/System controls/Sparkle などの OS integration を分ける設計整理から始めるのが安全。

## 未実施

- Windows での Swift build は未実施。理由は `swift` toolchain が未インストールのため。
- macOS 実機での `./script/build_and_run.sh --verify` は今回の Windows クローン準備範囲では未実施。
- `AGENTS.md` と `PROJECT.md` は repository root に未存在。運用ルール上、勝手に新設せず次の整理対象として残した。
