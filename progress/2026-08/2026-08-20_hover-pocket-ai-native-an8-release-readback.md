---
project_slug: hover-menu-preview
date: 2026-08-20
status: implemented; local-verified; public-beta-readback-passed; formal-signing-pending
updated_by: codex
---

# AI-native AN8-A Public Release Readback

## 目的

AN8のうち、macOS / Windows別の公開release、feed、署名、assetを公開先から別経路で読み直し、配布完了の誤判定を防ぐ。GitHubの汎用Latestは使わず、macOSは`macos-latest`、Windowsは`win-v...`専用channelを検証する。

## 実装

- `script/verify_release_readback.py`
  - macOS stable appcastとversioned appcastのbyte一致、version / build / asset identityを検査する。
  - versioned ZIPと手動install ZIPを公開URLから再取得し、実測size / SHA-256、GitHub digest、checksum、appcast lengthを照合する。
  - repository既定の公開鍵で、公開ZIPの実byteに対するSparkle Ed25519署名をOpenSSLで検証する。
  - Windowsの最大semantic `win-v...` releaseをpagination付きで発見し、全公開assetを再取得する。
  - 全assetの実測size / SHA-256をGitHub digestと`SHA256SUMS-win.txt`へ照合し、Velopack full packageはfeed内SHA-1も照合する。
  - asset名、download元、redirect先、response sizeを制限し、一時directoryだけへ保存する。
- `windows/script/verify_published_authenticode.ps1`
  - formal releaseの公開SetupとPortable ZIPをWindows上で再取得する。
  - checksum確認後、SetupとPortable内`HoverPocket.Shell.exe`のAuthenticode status、timestamp、署名者一致を確認する。
  - ZIP path traversalと過大展開を拒否し、実行ファイルは起動しない。
- `.github/workflows/release-readback-verify.yml`
  - PR / pushでは外部公開状態に依存しないPython unitとPowerShell parseを実行する。
  - 毎週月曜はbeta public readbackを実行し、JSON receiptを30日保存する。
  - formalはworkflow_dispatchだけで実行し、共通readbackとWindows実Authenticode gateを別jobで通す。

## ローカル検証

- `python3 -m unittest script/tests/test_verify_release_readback.py -v`: 10件成功。
- `python3 -m py_compile script/verify_release_readback.py`: 成功。
- workflow YAML parse: 成功。
- `git diff --check`: 成功。
- 公開beta readback:
  - macOS `v0.1.0-168` / build `168`: versioned ZIPとmanual ZIPの実測hash一致、Sparkle Ed25519署名検証成功。
  - Windows `win-v0.2.7`: 8 assetを再取得し、全size / SHA-256、checksum、full package SHA-1が一致。
  - OS別tag分離: 成功。
- formal negative readback:
  - 現行Windows `0.2.7`は`authenticode=unsigned`のためexit 1。
  - errorは`windows.authenticode_formal`で、正式版を誤って通さない。

## Git分離

- base: `origin/main` `a35b0ea8c224809ad4ff1bf1dc466882fc70169b`
- worktree: `/Users/shotaro/code/share/hover-menu-preview-ai-native-an8-readback`
- branch: `codex/ai-native-an8-release-readback-main`
- source commit: `03c726c`（progress更新前）
- main worktreeは`origin/main`と同一、cleanをreadbackした。

## AN8で残るgate

- GitHub Actions上のWindows PowerShell parseとweekly public readback。
- Windows正式署名済みreleaseでSetup / app本体のtimestamped Authenticodeを実測する。
- macOS Gatekeeper / notarization / Sparkle updateとWindows Velopack updateを、clean install / upgrade / downgrade / uninstall / reinstallの実機matrixで確認する。
- Host、Pocket App、user dataのversion整合を含むrollback E2E。
- old workspace migration、backup / export / restore、offline、corrupt audit、sleep-wake、長時間soak。
- retention設定、audit / receipt削除、schema / capability deprecation windowとmigration tool。

このログの完了はAN8-Aのreadback基盤に限定する。AN8全体またはCore GAの完了とは扱わない。
