# HoverPocket for Windows

WPF の常駐シェルと WebView2 のパネルで構成する Windows 版です。画面上端の access surface、非アクティブ表示のパネル、タスクトレイ、設定画面を提供します。

Windows 版の provider は Controls、Calendar、Clipboard、Sticky Notes、Timer、Calculator です。Mirror provider は Windows 版の対象外です。Codex Voice Laneはproviderではなく全パネル共通のHost-owned最下段として別管理し、製品版では既定オフです。AN3のWindows隔離E2Eでは、明示クリックからWebView2 microphone / WebRTC / remote audioへ接続します。

Controlsでは再生速度を「− / ＋」で0.25倍刻みに変更し、Windowsメディアセッションの読み戻し値を表示します。再生サムネイルを押すと、一意に特定できた再生元ウィンドウだけを前面へ表示してパネルを閉じます。Timerはストップウォッチ、タイマー、ポモドーロの3種類を横並びの追加カードから登録できます。実行中項目は1列のコンパクトなリストへ表示し、ストップウォッチとカウントダウンを各4件まで独立して扱います。ストップウォッチは100分の1秒表示で、providerを切り替えたりパネルを閉じたりしてもアプリ稼働中は計測を続けます。

## Build

```powershell
dotnet build .\windows\HoverPocket.Windows.sln
```

## Run

```powershell
dotnet run --project .\windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj
```

起動すると通常ウィンドウやタスクバー項目は出さず、タスクトレイに `HoverPocket` を表示します。トレイからパネル、設定、更新確認を開けます。

表示先は設定画面で `Main` / `Sub` / `All` を選べます。確認用にコマンドラインで一時上書きすることもできます。

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

WebView2 は通常、GPU 描画を有効にして開閉とリサイズのカクつきを抑えます。GPUドライバーとの相性問題を切り分ける場合だけ、`HOVERPOCKET_WEBVIEW_DISABLE_GPU=1` を設定して起動します。

## Verify

```powershell
dotnet run --project .\windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify shell
dotnet run --project .\windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify display
dotnet run --project .\windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify controls
dotnet run --project .\windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify ui
dotnet run --project .\windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify settings
dotnet run --project .\windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify capabilities
dotnet run --project .\windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify broker
dotnet run --project .\windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify voice-lane-layout
dotnet run --project .\windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify codex-app-server-protocol
dotnet run --project .\windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify codex-voice-coordinator
dotnet run --project .\windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify voice-e2e-isolation
```

`--verify shell` は access surface と panel の `WS_EX_NOACTIVATE`、`WS_EX_TOOLWINDOW`、`WS_EX_TOPMOST`、2 回目起動、120ms pollingだけによるopen、hidden / 位置ずれ / style欠落の自己修復、window再生成、3段階recovery、ポインター移動、open/close 25回、描画フレーム数と最大フレーム間隔を検査します。

`--verify display` は現在のモニター構成を列挙し、`Main` / `Sub` / `All` の対象 display 数、`Sub` のサブなし fallback、access surface / panel / collapsed rect の画面内収まり、DIPs と物理ピクセルの round-trip を検査して exit code で返します。WinExe のため標準出力が空になる場合があります。

`--verify controls` は音量・ミュート・輝度・メディア操作・再生元ウィンドウ解決の決定的テストと、実機の読み取り専用 probe を実行します。外部ディスプレイの輝度は DDC/CI 非対応や応答遅延を許容し、パネル全体を停止させずに非対応表示へフォールバックします。

`--verify ui` はWebView2とbridgeに加え、Controlsの実描画・領域内収まり・サムネイル/倍速操作、Timerの3種類の追加カード・複数ストップウォッチ・領域内収まり、Clipboardの同一provider再描画抑止、通常/お気に入りタブ、中央split view、全体プレビュー、個別削除UI、Calculator履歴サイドバーを検査します。

`--verify updater` は Velopack のローカルフォルダーフィードを一時生成し、更新なし / 更新ありの dry-run を確認します。実ダウンロードと適用は行いません。

`--verify release-config` は、配布成果物がRelease構成・期待バージョン・Windows更新channel・Google OAuth AssemblyMetadataを持ち、ビルド時の設定と一致することを値を表示せず確認します。

`--verify calendar-live` は、既存のWindows Credential Manager資格情報を使って当月のCalendarを読み取り、予定内容を表示せずcalendar数とevent数だけを出力します。予定の作成・更新・削除は行いません。

`--verify capabilities` はCalendar / Timer / Sticky NotesのProvider Capability handlerを検証します。`--verify broker` はRegistry、権限、承認の改変・期限切れ・再利用拒否、永続idempotency、実行後readback、監査ログの本文非保存、Today Focus、部分失敗時のTimer補償、timeout、macOSと共通のplan digestを検証します。

`--verify voice-lane-layout` はVoice Laneの既定オフ、Compact / Expanded、既存Provider高さ不変、下方向拡張、短い画面でのCompact縮退、設定永続化を検証します。`--verify ui`ではCompactの視覚タイトルなし・会話幅優先、明示toggle、Expandedのtranscript / root-scoped session 2列、fullscreenなしもWebView2実描画で確認します。

`--verify voice-e2e-isolation` は、Debug限定のfresh temp root、Release override無効、製品版と異なるmutex / open-request event、全保存先、Updater / OAuth無効化、安全な初期設定、sanitized receiptのallowlist・atomic更新・playback成功/失敗・safe close・feature-off無副作用を決定的に検証します。マイクや手動GUIは起動しません。

## Isolated Windows Voice E2E

次のスクリプトだけを入口にします。`Run`はDebug build後にsystem temp配下へfresh rootを作り、製品版とは別のsingle-instance名で検証exeを起動します。インストール版、既存製品process、`%APPDATA%\HoverPocket`、既存OAuth credential、Updater / installerは使用しません。Windowsのマイク許可は起動だけでは要求されず、ユーザーがアプリ内Voiceボタンを明示クリックした後にだけ開始します。

```powershell
.\windows\script\voice_e2e_windows.ps1 -Action Build
.\windows\script\voice_e2e_windows.ps1 -Action Run
.\windows\script\voice_e2e_windows.ps1 -Action Readback -Root <Runが返したvoice_e2e_root>
.\windows\script\voice_e2e_windows.ps1 -Action Stop -Root <Runが返したvoice_e2e_root>
```

`Readback`は`voice-e2e-receipt.json`の固定allowlistだけを表示します。receiptにはtranscript本文、音声、SDP、token、path、Provider data、PIDを保存しません。`Stop`は同じDebug exe path、`--voice-e2e`、指定rootがすべて一致する隔離processだけへ専用safe-stop eventを送り、WebRTC / microphone / app-server cleanupのreceiptを確認します。rootは検証根拠として残します。

## Windows updates and release packaging

Windows 版の更新確認は Velopack と GitHub Releases (`shotaro311/hover-pocket`) を使います。トレイと Settings の `Check for Updates` は Windows channel `win` の feed (`releases.win.json`) へ接続し、更新が見つかった場合はダウンロード前と適用/再起動前に確認します。起動時の自動チェックは既定オンで、失敗しても起動を止めません。
更新後の通常起動では、実インストールのrootと既存ARP entryの`InstallLocation`が一致する場合だけ、HKCUの`HoverPocketWin` entryにある`DisplayVersion`を現在versionへ補正します。portable、verify、second-instance probe、path不一致、keyなしでは変更しません。

Windows は macOS Sparkle の `https://github.com/shotaro311/hover-pocket/releases/download/macos-latest/appcast.xml` を使いません。Windows release は `win-v0.2.7` のような Windows 専用 tag / asset を使い、GitHub Release を作る場合は `--latest=false` を付けてmacOSのLatest / appcastを動かさないでください。

### 署名方針

- Windows 0.2.xは、コード署名証明書を取得するまでAuthenticode未署名の公開ベータとして配布します。
- Setup.exeの初回実行時にMicrosoft Defender SmartScreenの警告が出る可能性があることを、ダウンロード導線とRelease notesに明記します。
- 1.0またはmacOS版と同等の正式版では、タイムスタンプ付きAuthenticode署名と公開成果物の署名readbackを必須gateにします。
- 署名証明書やsigning credentialsはGit、ログ、README、progressに記録しません。

Release assetはmacOS Sparkle資産と衝突しない`HoverPocketWin-*`系です。`publish_release.ps1`は、OAuth環境変数が未設定の場合に停止し、Release成果物内のmetadata一致を確認してからVelopack package、`release-manifest.win.json`、`SHA256SUMS-win.txt`を生成します。GitHub Releaseの作成・アップロードはこのスクリプトでは実行しません。

```powershell
.\windows\script\publish_release.ps1
```

NuGet TLS 問題がある環境では、一時ローカル NuGet ソースと `-NuGetSource` / `-VpkPath` を指定して実行します。workspace に nupkg を残さないでください。

スクリプトの出力する GitHub 手順は、Windows release 作成時に `--latest=false` を含みます。アップロード後は次を readback し、Windows feed と asset だけが読めること、macOS `macos-latest/appcast.xml` が変わっていないことを別々に確認します。

```powershell
gh release view win-v0.2.7 --repo shotaro311/hover-pocket --json tagName,assets,url
Invoke-WebRequest -UseBasicParsing -Uri https://github.com/shotaro311/hover-pocket/releases/download/win-v0.2.7/releases.win.json
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
- display 再同期は WPF の `HwndSource.AddHook` で `WM_DISPLAYCHANGE` / `WM_DPICHANGED` を受け、加えて `SystemEvents.DisplaySettingsChanged`、`SystemEvents.PowerModeChanged`、`SystemEvents.SessionSwitch`から段階的に再計算します。
- 120ms pointer pollingとは別に約2秒ごとのshell health checkを行い、access surface / panelのHWND、native visibility、WPF visibility、必須extended styles、期待frameを照合します。修復可能な異常は同じwindowへ再適用し、HWNDが無効なwindowだけを再生成します。panel再生成時もprovider stateを持つ`PanelBridgeController`は維持します。
- display / DPI change、Power Resume、`SystemEvents.SessionSwitch`のunlock / console connect / remote connectでは、polling timerを再始動し、即時・0.45秒後・1.4秒後の3段階でdisplay再同期とhealth checkを実行します。
