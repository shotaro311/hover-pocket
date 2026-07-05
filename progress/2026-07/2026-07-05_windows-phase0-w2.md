---
project_slug: hover-pocket
task: windows-phase0-w2
date: 2026-07-05
worker: codex-w2
status: verified-single-monitor
---

# Windows Phase 0 W2 multi-monitor and mixed DPI

## 実施内容

- `--display-placement <main|sub|all>` を追加し、既定を `Main` にした。設定 UI は未実装で、`ShellSettings` に設定値を集約した。
- `DisplayLayoutService` を追加し、モニター列挙、`Main` / `Sub` / `All` の対象解決、access surface / panel / collapsed rect の DIPs と物理ピクセル変換を集約した。
- `All` では対象 display 数ぶんの `AccessSurfaceWindow` を作成し、hover した display の layout で panel を開くようにした。
- `Sub` でサブディスプレイがない場合は primary monitor へ fallback するようにした。
- mixed DPI 対応として、HWND の実配置は `SetWindowPos` の物理ピクセルを正とし、WPF 側 DIPs は同じ layout から同期する構成にした。
- `WM_DISPLAYCHANGE` / `WM_DPICHANGED`、`SystemEvents.DisplaySettingsChanged`、`SystemEvents.PowerModeChanged` の resume で display layout を debounce 後に再同期するようにした。
- `--verify display` を追加し、現在のモニター構成、placement ごとの surface 数、サブなし fallback、各 rect の画面内収まり、DIP/physical round-trip、controller window rect を検査するようにした。
- `--verify shell` を複数 access surface 対応へ更新し、既存の style / second instance / 25 cycle stress 検査を維持した。
- `windows/README.md` に `--display-placement` と `--verify display` を追記した。
- `windows/spikes/` は変更していない。

## 参照した一次情報

- Microsoft Learn: `EnumDisplayMonitors` / `GetMonitorInfo` / `GetDpiForMonitor` / `GetDpiForWindow`
- Microsoft Learn: `WM_DISPLAYCHANGE` / `WM_DPICHANGED`
- Microsoft Learn: WPF `HwndSource.AddHook`
- Microsoft Learn: `SystemEvents.DisplaySettingsChanged` / `SystemEvents.PowerModeChanged`

## 検証結果

- 検証環境の monitor count:
  - command: `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -Command Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.Screen]::AllScreens.Count`
  - exit code: 0
  - result: `1`
- `dotnet build windows\HoverPocket.Windows.sln`
  - exit code: 0
  - warnings: 0
  - errors: 0
- `dotnet run --project windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify shell`
  - exit code: 0
  - result: 成功
  - stdout: なし(WinExe 実行のため)。合否は process exit code で確認。
- `dotnet run --project windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify display`
  - exit code: 0
  - result: 成功
  - stdout: なし(WinExe 実行のため)。合否は process exit code で確認。
- 追加確認: `dotnet run --project windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --display-placement sub --verify display`
  - exit code: 0
  - result: single monitor 環境で `Sub` fallback 経路が成功
- 追加確認: `dotnet run --project windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --display-placement all --verify display`
  - exit code: 0
  - result: `All` CLI 経路が成功
- 補足:
  - `dotnet build` と `dotnet run -- --verify display` を一度並列実行した際、`obj\Debug\net10.0-windows\HoverPocket.Shell.dll` の lock で build が exit code 1 になった。逐次実行へ戻した後の最終 `dotnet build` は exit code 0 / warnings 0。

## 未実施・未検証事項

- 実マルチモニター環境での `Main` / `Sub` / `All` 手動 hover E2E は未実施。
- メイン 100% + サブ 150% などの mixed DPI 実機手動確認は未実施。`--verify display` は現在の single monitor 構成での変換整合検査まで。
- display 接続/切断、解像度変更、DPI 変更を実際に発生させた再同期テストは未実施。hook と再同期処理は実装済み。
- sleep/wake 復帰の実機テストは未実施。`SystemEvents.PowerModeChanged` の resume hook による再同期は実装済み。
- 実マウス操作による hover open/close の手動体感確認は W1 から継続して未実施。
