# HoverPocket Windows

Windows 11 x64向けのHoverPocketネイティブシェルです。画面上端の入口、WPF / WebView2パネル、各provider、Google Calendar、Velopack更新を提供します。

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

WebView2 の DevTools と既定 context menu は、Debug ビルドまたは明示的に
`--devtools` を付けた起動時だけ有効です。配布用 Release ビルドの通常起動では無効です。

```powershell
dotnet run --project .\windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --devtools
```

## Verify

```powershell
dotnet run --project .\windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify shell
dotnet run --project .\windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify display
```

`--verify shell` は access surface と panel の `WS_EX_NOACTIVATE`、`WS_EX_TOOLWINDOW`、`WS_EX_TOPMOST` を検査し、2 回目起動が既存インスタンスへ通知して exit 0 で終了することを確認し、open/close を 25 回実行してプロセス内 top-level window 数が増えないことを exit code で返します。

`--verify display` は現在のモニター構成を列挙し、`Main` / `Sub` / `All` の対象 display 数、`Sub` のサブなし fallback、access surface / panel / collapsed rect の画面内収まり、DIPs と物理ピクセルの round-trip を検査して exit code で返します。WinExe のため標準出力が空になる場合があります。

`--verify updater` は Velopack のローカルフォルダーフィードを一時生成し、更新なし / 更新ありの dry-run を確認します。実ダウンロードと適用は行いません。

`--verify release-config` は、配布成果物がRelease構成・期待バージョン・Windows更新channel・Google OAuth AssemblyMetadataを持ち、ビルド時の設定と一致することを値を表示せず確認します。

## Windows updates and release packaging

Windows 版の更新確認は Velopack と GitHub Releases (`shotaro311/hover-pocket`) を使います。トレイと Settings の `Check for Updates` は Windows channel `win` の feed (`releases.win.json`) へ接続し、更新が見つかった場合はダウンロード前と適用/再起動前に確認します。起動時の自動チェックは既定オンで、失敗しても起動を止めません。

Windows は macOS Sparkle の `https://github.com/shotaro311/hover-pocket/releases/download/macos-latest/appcast.xml` を使いません。Windows release は `win-v0.2.2` のような Windows 専用 tag / asset を使い、GitHub Release を作る場合は `--latest=false` を付けてmacOSのLatest / appcastを動かさないでください。

### 署名方針

- Windows 0.2.xは、コード署名証明書を取得するまでAuthenticode未署名の公開版として配布します。
- Setup.exeの初回実行時にMicrosoft Defender SmartScreenの警告が出る可能性があることを、ダウンロード導線とRelease notesに明記します。
- 1.0正式版では、タイムスタンプ付きAuthenticode署名と公開成果物の署名readbackを必須gateにします。
- 署名証明書やsigning credentialsはGit、ログ、README、progressに記録しません。

Release assetはmacOS Sparkle資産と衝突しない`HoverPocketWin-*`系です。`publish_release.ps1`は、OAuth環境変数が未設定の場合に停止し、Release成果物内のmetadata一致を確認してからVelopack package、`release-manifest.win.json`、`SHA256SUMS-win.txt`を生成します。GitHub Releaseの作成・アップロードはこのスクリプトでは実行しません。

```powershell
.\windows\script\publish_release.ps1
```

NuGet TLS 問題がある環境では、一時ローカル NuGet ソースと `-NuGetSource` / `-VpkPath` を指定して実行します。workspace に nupkg を残さないでください。

スクリプトの出力する GitHub 手順は、Windows release 作成時に `--latest=false` を含みます。アップロード後は次を readback し、Windows feed と asset だけが読めること、macOS `macos-latest/appcast.xml` が変わっていないことを別々に確認します。

```powershell
gh release view win-v0.2.2 --repo shotaro311/hover-pocket --json tagName,assets,url
Invoke-WebRequest -UseBasicParsing -Uri https://github.com/shotaro311/hover-pocket/releases/download/win-v0.2.2/releases.win.json
Invoke-WebRequest -UseBasicParsing -Uri https://github.com/shotaro311/hover-pocket/releases/download/macos-latest/appcast.xml
```

## Local privacy notes

AI command lane の audit log は `%APPDATA%\HoverPocket\auditlog\ailane-YYYYMMDD.jsonl` に保存します。
保存する内容は `timestamp`、`action`、`actionType`、`result`、`eventId`、`calendarId` の最小メタデータだけです。
予定タイトル、場所、メモ、ユーザー入力本文、承認カード本文、失敗詳細本文は保存しません。
書き込み時に 90 日より古い日次ファイルを削除します。

## Implementation Notes

- WPF Window の HWND 取得は Microsoft Learn の `WindowInteropHelper.Handle` に沿い、`GetWindowLongPtrW` / `SetWindowLongPtrW` で `GWL_EXSTYLE` に `WS_EX_NOACTIVATE` と `WS_EX_TOOLWINDOW` を追加しています。topmost は WPF `Topmost=true` に加え、`SetWindowPos(..., HWND_TOPMOST, ..., SWP_NOACTIVATE)` で補強しています。
- トレイは `System.Windows.Forms.NotifyIcon` を使います。Microsoft の通知領域ドキュメントと WinForms `NotifyIcon` はこの用途の first-party API で、WPF には同等の標準トレイコンポーネントがないためです。`Shell_NotifyIcon` の直接 P/Invoke は制御範囲が広い一方、今回の W1 では保守コストに見合わないため採用しません。
- DPI awareness は manifest で `PerMonitorV2` を宣言しています。Microsoft の High DPI guidance は manifest で既定 DPI awareness を指定することを推奨しているため、API 呼び出しではなく manifest を正本にしています。WinForms を tray 用に併用すると SDK は `ApplicationHighDpiMode` を推奨する警告を出しますが、W1 の manifest 要件を優先し、プロジェクト側にも `ApplicationHighDpiMode=PerMonitorV2` を併記したうえで該当警告だけ抑制しています。
- モニター列挙と座標は `EnumDisplayMonitors` / `GetMonitorInfo` / `GetDpiForMonitor` を使い、DIPs と物理ピクセルの変換は `DisplayLayoutService` に集約しています。実際の HWND 位置とサイズは `SetWindowPos` の物理ピクセルを正とし、WPF 側の DIPs は同じ layout から同期します。
- display 再同期は WPF の `HwndSource.AddHook` で `WM_DISPLAYCHANGE` / `WM_DPICHANGED` を受け、加えて `SystemEvents.DisplaySettingsChanged` と `SystemEvents.PowerModeChanged` の resume で debounce 後に再計算します。
