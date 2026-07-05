---
project_slug: hover-pocket
task: windows-phase0-w1
date: 2026-07-05
worker: codex-w1
status: verified
---

# Windows Phase 0 W1 shell spike

## 実施内容

- `windows/HoverPocket.Windows.sln` を `.sln` 形式で作成し、`windows/src/HoverPocket.Shell/` に WPF `net10.0-windows` project を追加。
- トレイ常駐を `System.Windows.Forms.NotifyIcon` で実装。`Open Panel` / 無効状態の `Settings` / 無効状態の `Check for Updates` / `Quit` を用意。
- プライマリモニター上端中央の access surface と、600x430 DIPs の暗色角丸 panel を WPF window として実装。
- access surface と panel に `WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW` を付与し、`Topmost=true` と `SetWindowPos(HWND_TOPMOST, SWP_NOACTIVATE)` で補強。
- hover open/close を実装。open/close duration は 0.22s、close delay は 0.06s、polling interval は 0.12s、hover tolerance は +4 DIPs。
- named mutex による多重起動防止を実装。2 回目起動は named event で既存 instance に panel 表示を通知し、exit 0 で終了。
- `app.manifest` で Per-Monitor V2 DPI awareness を宣言。WinForms tray 併用に伴う SDK 警告は、W1 の manifest 要件を優先して `ApplicationHighDpiMode=PerMonitorV2` 併記 + `WFO0003` 抑制。
- `--verify shell` を実装。style 検査、2 回目起動 probe、25 回 open/close stress、top-level window count の増殖なしを検査。
- `windows/README.md` に build / run / verify 手順と、WPF HWND / NotifyIcon / DPI の選定理由を記録。

## 検証結果

- `dotnet build .\windows\HoverPocket.Windows.sln`
  - exit code: 0
  - result: 成功
  - warnings: 0
  - errors: 0
- `dotnet run --project .\windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify shell`
  - exit code: 0
  - result: 成功
  - stdout: なし(WinExe 実行のため)。合否は process exit code で確認。

## 未実施・未検証事項

- ~~実マウス操作による hover open/close の手動 E2E は未実施。計画書どおりユーザー確認に回す。~~
  → 2026-07-05 ユーザーが手動 E2E を実施し「問題なく動作」と確認(上端 hover 開閉、トレイ Quit 含む)。記録: アーキテクト(Claude)。
- ~~トレイメニューの実クリック操作は未実施。~~ → 同上のユーザー手動 E2E で確認済み。
- Main/Sub/All、mixed DPI、monitor hotplug、fullscreen suppression は W2 以降の対象のため未実施。
- WebView2 は W3 対象のため未使用。

## 判断メモ

- WPF window の Win32 拡張 style は、Microsoft Learn の `WindowInteropHelper.Handle` / Win32 `GetWindowLongPtrW` / `SetWindowLongPtrW` / `SetWindowPos` に沿って、WPF HWND 取得後に適用した。
- トレイは WinForms `NotifyIcon` を採用。WPF に first-party の tray component がなく、Microsoft が管理 API として提供している `NotifyIcon` が W1 の保守性と実装範囲に合うため。`Shell_NotifyIcon` 直接 P/Invoke は W1 では過剰と判断。
- .NET 10 SDK の `dotnet new sln` 既定は `.slnx` だったが、W1 指定が `windows/HoverPocket.Windows.sln` のため `.sln` 形式に作り直した。
