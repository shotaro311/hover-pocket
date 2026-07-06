---
project_slug: hover-pocket
target: Windows Phase 2 W9 Clipboard provider
created: 2026-07-06
updated_by: codex
status: verified-cli
related:
  - docs/plan/20260706_windows_phase2_plan.md
  - docs/requirement/requirements.md
---

# Windows Phase 2 W9 Clipboard provider

## 実装

- `Providers/Clipboard/` を追加し、`AddClipboardFormatListener` + `WM_CLIPBOARDUPDATE` の event-driven listener、`%APPDATA%\HoverPocket\clipboard\history.json` + 個別 PNG 保存、破損 JSON fallback、text 30 / image 20 上限、PNG 正規化、SHA-256 重複抑制を実装した。
- `ClipboardPrivateMode` を Settings / provider 内ボタンから切り替え、provider visibility OFF または private mode ON では monitor を停止するようにした。
- Clipboard UI を `windows/ui/providers/clipboard/` に追加し、text/image 履歴一覧、クリック再コピー、全消去、private mode 状態表示、C# `DoDragDrop` 起点の外部ドラッグ入口を接続した。
- image drag payload は `Bitmap` + `FileDrop`、text drag payload は `UnicodeText`。外部ドラッグ開始時は bridge から shell へ通知し、panel を一時 hide する。
- Settings に Clipboard private mode toggle と機密性注意書き(ja/en)を追加した。
- 共有ファイルは Clipboard 登録、bridge handler 登録、`--verify clipboard` 分岐、Settings/i18n/app.js の最小追記に限定した。

## 検証

- `node --check windows\ui\js\app.js`: exit code 0
- `node --check windows\ui\settings\settings.js`: exit code 0
- `node --check windows\ui\providers\clipboard\clipboard.js`: exit code 0
- `dotnet build windows\HoverPocket.Windows.sln --nologo -p:NuGetAudit=false`: exit code 0、警告 0、エラー 0
- `dotnet windows\src\HoverPocket.Shell\bin\Debug\net10.0-windows\HoverPocket.Shell.dll --verify clipboard`: exit code 0
- `dotnet windows\src\HoverPocket.Shell\bin\Debug\net10.0-windows\HoverPocket.Shell.dll --verify ui-model`: exit code 0
- `git diff --check`: exit code 0。CRLF 変換 warning のみで whitespace error はなし。

## 既知事項

- 1 回目の plain `dotnet build windows\HoverPocket.Windows.sln --nologo` は実行中の `HoverPocket.Shell (PID 63044)` が exe を lock して失敗した。35 秒待機後の再試行では file lock は解消した。
- plain build / restore では `api.nuget.org` 到達不能により NuGet audit warning `NU1900` が出たため、最終 build は `-p:NuGetAudit=false` で警告 0 を確認した。
- WebView2 実行系の provider 画面操作、実 clipboard listener の長時間常駐、外部アプリへの実 drag/drop はアーキテクト通常 desktop session 実行待ち。
