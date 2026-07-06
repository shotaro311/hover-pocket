# HoverPocket Windows Shell Spike

Phase 0 の Windows ネイティブシェル検証です。WebView2 はこの spike では使いません。

## Build

```powershell
dotnet build .\windows\HoverPocket.Windows.sln
```

## Run

```powershell
dotnet run --project .\windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj
```

起動すると通常ウィンドウやタスクバー項目は出さず、タスクトレイに `HoverPocket` を表示します。トレイメニューは `Open Panel`、無効状態の `Settings` / `Check for Updates`、`Quit` です。

表示先は Phase 0 では設定 UI を持たず、コマンドラインで指定します。既定は `main` です。

```powershell
dotnet run --project .\windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --display-placement main
dotnet run --project .\windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --display-placement sub
dotnet run --project .\windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --display-placement all
```

## Verify

```powershell
dotnet run --project .\windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify shell
dotnet run --project .\windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify display
```

`--verify shell` は access surface と panel の `WS_EX_NOACTIVATE`、`WS_EX_TOOLWINDOW`、`WS_EX_TOPMOST` を検査し、2 回目起動が既存インスタンスへ通知して exit 0 で終了することを確認し、open/close を 25 回実行してプロセス内 top-level window 数が増えないことを exit code で返します。

`--verify display` は現在のモニター構成を列挙し、`Main` / `Sub` / `All` の対象 display 数、`Sub` のサブなし fallback、access surface / panel / collapsed rect の画面内収まり、DIPs と物理ピクセルの round-trip を検査して exit code で返します。WinExe のため標準出力が空になる場合があります。

`--verify updater` は Velopack のローカルフォルダーフィードを一時生成し、更新なし / 更新ありの dry-run を確認します。実ダウンロードと適用は行いません。

## Windows updates and release packaging

Windows 版の更新確認は Velopack と GitHub Releases (`shotaro311/hover-pocket`) を使います。トレイと Settings の `Check for Updates` は実フィードへ接続し、更新が見つかった場合はダウンロード前と適用/再起動前に確認します。起動時の自動チェックは既定オンで、失敗しても起動を止めません。

Phase 2 では Windows 配布物に Authenticode 署名を付けません。そのため、Setup.exe の初回実行時に Microsoft Defender SmartScreen の警告が出る可能性があります。署名証明書や signing credentials は Git、ログ、README、progress に記録しません。

Release asset は macOS Sparkle 資産と衝突しない `HoverPocketWin-*` 系です。ローカルで publish と Velopack pack だけを行うには次を実行します。GitHub Release の作成・アップロードはこのスクリプトでは実行しません。

```powershell
.\windows\script\publish_release.ps1
```

NuGet TLS 問題がある環境では、一時ローカル NuGet ソースと `-NuGetSource` / `-VpkPath` を指定して実行します。workspace に nupkg を残さないでください。

## Implementation Notes

- WPF Window の HWND 取得は Microsoft Learn の `WindowInteropHelper.Handle` に沿い、`GetWindowLongPtrW` / `SetWindowLongPtrW` で `GWL_EXSTYLE` に `WS_EX_NOACTIVATE` と `WS_EX_TOOLWINDOW` を追加しています。topmost は WPF `Topmost=true` に加え、`SetWindowPos(..., HWND_TOPMOST, ..., SWP_NOACTIVATE)` で補強しています。
- トレイは `System.Windows.Forms.NotifyIcon` を使います。Microsoft の通知領域ドキュメントと WinForms `NotifyIcon` はこの用途の first-party API で、WPF には同等の標準トレイコンポーネントがないためです。`Shell_NotifyIcon` の直接 P/Invoke は制御範囲が広い一方、今回の W1 では保守コストに見合わないため採用しません。
- DPI awareness は manifest で `PerMonitorV2` を宣言しています。Microsoft の High DPI guidance は manifest で既定 DPI awareness を指定することを推奨しているため、API 呼び出しではなく manifest を正本にしています。WinForms を tray 用に併用すると SDK は `ApplicationHighDpiMode` を推奨する警告を出しますが、W1 の manifest 要件を優先し、プロジェクト側にも `ApplicationHighDpiMode=PerMonitorV2` を併記したうえで該当警告だけ抑制しています。
- モニター列挙と座標は `EnumDisplayMonitors` / `GetMonitorInfo` / `GetDpiForMonitor` を使い、DIPs と物理ピクセルの変換は `DisplayLayoutService` に集約しています。実際の HWND 位置とサイズは `SetWindowPos` の物理ピクセルを正とし、WPF 側の DIPs は同じ layout から同期します。
- display 再同期は WPF の `HwndSource.AddHook` で `WM_DISPLAYCHANGE` / `WM_DPICHANGED` を受け、加えて `SystemEvents.DisplaySettingsChanged` と `SystemEvents.PowerModeChanged` の resume で debounce 後に再計算します。
