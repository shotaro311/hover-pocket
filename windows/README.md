# HoverPocket for Windows

WPF の常駐シェルと WebView2 のパネルで構成する Windows 版です。画面上端の access surface、非アクティブ表示のパネル、タスクトレイ、設定画面を提供します。

Windows 版の provider は Controls、Calendar、Clipboard、Sticky Notes、Assets（素材）、Timer、Calculator です。Mirror と Microphone は Windows 版の対象外で、macOS 版の実装には影響しません。

素材はEagle・アカウント・APIキーを必要としないローカルライブラリです。ファイル／フォルダの選択、上端へのドロップ、コピーした画像・ファイルの貼り付けで独立した原本を保存します。フォルダ・タグ・お気に入り、検索条件の保存、アプリ内のゴミ箱と復元、完全バックアップを扱います。素材の通常ウィンドウはトレイの「素材ライブラリを開く」から開き、ポケット内の素材機能を非表示にしていても使えます。

開発版`0.2.10-local.8`では、`Ctrl+Alt+S`で表示した撮影画面上をホバーすると、アプリのウィンドウが枠で強調されます。デスクトップ上ではそのモニター全体を選びます。クリックまたはEnterで対象を確定し、ドラッグでも範囲を指定できます。選択後は同じ場所でペン・文字・四角・丸・矢印を描き、枠のそばの✓、Enter、画像のダブルクリックでPNGを保存します。×またはEscはキャンセルです。色・太さ、消しゴム、選択と移動、Undo/Redo、元画像の追加保存は同じツールバーから操作します。保存に失敗した場合も編集内容を保持します。

素材一覧のフォルダ取り込みボタンは省き、検索欄の下に形式・並び順とサイズバーを表示します。画像・動画・PDFなどの種類、ライブラリにある個別の拡張子で絞り込めます。取り込み日・名前・ファイルサイズと昇順／降順を選び、サイズバーでサムネイルを調整できます。サイズは次回も引き継ぎます。一覧で選択した素材はDeleteキーでごみ箱へ移せます。複数選択にも対応し、Ctrl+Zで戻せます。検索や名前の編集中は文字を削除します。日付の絞り込みは隣の調整アイコンから開きます。画像にマウスを重ねると右上に星が表示され、クリックでお気に入りを切り替えます。お気に入りの星は常時表示します。プレビュー・分類・名前変更・コピー・保存先・ごみ箱・元に戻すは素材の右クリックメニューから操作します。選択済みの素材を右クリックすると複数選択を保ちます。件数と選択数は最下部に表示します。

スクショを保存すると、画面右下に画像付き通知を表示します。通知をドラッグして他のアプリへPNGを渡せます。トレイの「撮影・収録の設定…」にある「スクショ通知の表示時間」で0〜30秒に変更し、「設定を保存」を押してください。既定は5秒、0秒は通知オフです。通知にマウスを置いたりドラッグしたりしている間は消えず、ドロップ後に閉じます。受け渡すのはライブラリ原本と別のコピーです。形式・並び順メニューの選択肢も暗い配色に統一しました。

スクリーンショットは別の編集ウィンドウを開かず、範囲選択から装飾・保存まで同じ画面で完了します。以前の「撮影後に編集画面を開く」の設定は、この操作へ統一しました。素材のサムネイルをダブルクリックして「画像を編集」を押すと、同じウィンドウのまま編集モードへ移り、原本を残して編集済みPNGを追加できます。編集中も上部の素材名・サイズ切替・機能アイコンを残します。取消は元のプレビューへ戻り、保存失敗時は編集内容を残して再試行できます。プレビュー中は検索・取り込み行を隠し、画像・動画をダブルクリックすると一覧へ戻ります。ファイル名のダブルクリックは名前変更です。フォルダとタグは引き継ぎます。保存後の注釈は画素に統合されます。

素材をドラッグすると下部にゴミ箱が現れ、そこへドロップした項目をアプリ内のゴミ箱へ移します。Ctrl+Zまたはゴミ箱から復元できます。画像・動画などの外部アプリへのドラッグは従来どおり作業コピーを渡します。Space長押しによるプレビューの連続開閉を抑止し、拡大中の描画面の再作成を減らしています。

`local.13`では、プレビューの切り替え前から表示を保ち、文字や画像を固定した大きさで見せながら外枠を動かすようにしました。拡大途中の横ずれと細かい文字のちらつきを抑えています。[修正と検証記録](../docs/report/20261003-windows-preview-smooth-recording-shortcut.md)。収録の上下反転は`local.12`で修正済みです。既存の収録ファイルは保持し、新しい収録から正しい向きで保存します。`local.14`では、素材一覧の再描画でサムネイルが一瞬消える問題と、切替の終わりに保持画像を本体の再表示より先に外す順序を修正しました（検証は[作業記録](../progress/2026-10/2026-10-04_hover-pocket-claude-flicker.md)を参照）。`local.15`では、プレビューを開く際にウィンドウを到着寸法へ移す瞬間、古い切り抜き範囲が残って小さい枠の横に黒い面が出る問題を修正しました。[修正と検証記録](../progress/2026-10/2026-10-04_hover-pocket-claude-opening.md)。

`local.9`では範囲選択後のクラッシュを修正しました。`local.10`では原本欠損時の保存判定、絞り込み後の複数選択、撮影フォルダの引き継ぎ、壊れた保存待ちによる後続停止を修正し、機能切り替えの不要な描画とフェード時間を減らしました。[修正・計測・検証記録](../docs/report/20261003-windows-review-fixes-response.md)。

`Ctrl+Alt+R`は画面収録の開始・停止です。ショートカットでは設定画面を開かず、Windowsの画面/ウィンドウ選択だけを表示します。音声と保存先は、トレイの「撮影・収録の設定…」で変更して「設定を保存」を押してください。PCの再生音とマイクを個別にオン/オフできます。停止するとMP4を確定し、保存した設定のフォルダへ登録します。収録中に設定画面を閉じても収録は続き、トレイのメニューとツールチップに収録中と表示します。縦横比を保持して最大1920×1080・30fps、音声はAACです。既定のモノラル/ステレオの音声デバイスを使い、マイクの利用にはWindowsの許可が必要です。対象のサイズ変更や終了、空き容量512MiB未満では収録を終了して保存します。

素材一覧のカメラアイコンから範囲スクリーンショット、ビデオアイコンから画面収録の開始・停止を直接行えます。選択中のフォルダ1件へ保存し、ルートや複数フォルダのときは未分類へ保存します。この操作は保存済みの撮影設定を変更しません。トレイの「撮影・収録の設定…」から、既定の保存先とショートカットを変更できます。他アプリとのキー競合を表示し、撮影/収録のボタンでも操作できます。設定は既存の設定と同じ領域の`capture-settings.json`へ保存し、既存の`settings.json`を変更しません。確定済みの保存失敗は「保存待ちを再試行」から再登録できます。強制終了で未確定のMP4は自動登録せず、「保存待ちフォルダを開く」で残ったファイルを確認できます。

収録はWindows標準の画面取得・動画エンコーダーと、同梱した[NAudio 3.1.0](https://www.nuget.org/packages/NAudio.Wasapi/3.1.0)を使います。MITのライセンス通知を`ThirdParty/NAudio-LICENSE.txt`へ同梱し、追加のFFmpegやアカウントは不要です。[撮影・収録の実装と検証記録](../progress/2026-10/2026-10-03_hover-pocket-capture.md)。

画像の拡大、MP4/H.264動画の再生・シーク、PDFのページ移動をポケット内で操作できます。プレビューは上端パネル自体を素材の寸法に合わせて拡大し、F11または全画面ボタンで現在のモニターへ広げます。Escは全画面からの復帰、次にプレビュー終了です。画像はEXIF方向とPNG透明度を反映し、PDFは選択したページだけを生成します。対応外の形式も原本保存・取り出しが可能です。48MPのJPEGは縮小デコードし、32MPを超える他の画像形式はメモリ予算を守るためプレビューを制限します。動画の形式対応はWindowsとWebView2のメディア機能に依存します。アプリへのFFmpeg導入は不要です。

PDF描画は同梱実行ファイルの読み取り専用子プロセスで行い、30秒の未使用後に終了、次のページ要求で再開します。これはWindows標準PDF/DXGIの終了時例外を本体から分離するためで、追加ソフトの導入は不要です。結果を返した後の子プロセス終了はOSによる資源解放を使い、本体の通常の終了手順は維持します。

保存先は`%LOCALAPPDATA%\HoverPocket\AssetLibrary`です。DBとUUID名の原本を正本とし、サムネイルは再生成できます。ドラッグ・クリップボード・OSで開く操作では、管理原本から独立した作業コピーを渡します。「外部コピーを整理…」で使用済みコピーをWindowsのゴミ箱へ移せます。復元前に版・ハッシュ・分類参照を検証し、既存ライブラリを置き換える場合は現在のDBと原本を日時付きフォルダへ退避します。DBのみのスナップショットは完全バックアップとは別です。[共通契約](../shared/asset-library/README.md)と[実装・検証記録](../progress/2026-10/2026-10-03_hover-pocket-asset-library.md)を参照してください。

Calendarには今日と7日先までの天気を表示します。設定で世界の都市を検索するか、47都道府県から選択し、温度を自動・摂氏・華氏へ切り替えられます。Windowsの位置情報許可は「現在地を使用」を押したときだけ要求します。予報は地点・座標・温度単位ごとに保存し、通信できない場合は保存済み予報であることを明示します。位置情報を使用できない場合も都市・都道府県を選択できます。天気情報は[Open-Meteo](https://open-meteo.com/)から取得します。

パネルと文字サイズは小・中・大・特大の4段階です。特大パネルは780×560 DIPsで、Voiceの展開領域にも対応します。

設定の「上端とのつながり」で「細い入口を残す」「上端まで覆う」を選べます。入口とパネルは同じ輪郭を使って液体のように開閉し、途中で戻っても位置と速度を引き継ぎます。「ノッチがない画面では自動で上端まで覆う」は既定オフで、オンにしても保存済みの手動選択を保持します。「動きを減らす」またはWindowsのアニメーション無効時は即時に切り替えます。

Windows実機の検証範囲と再実行手順は[液体アニメーションの記録](../progress/2026-10/2026-10-02_hover-pocket-windows-liquid.md)を参照してください。

初回表示とホバー判定の処理削減、計測の条件と結果は[表示応答の改善記録](../progress/2026-10/2026-10-02_hover-pocket-response-refactor.md)を参照してください。

同じ設定欄の「上部の入口を自動で隠す」をオンにすると、上部の黒い入口を普段は隠せます。上部の入口付近へマウスを近づけると入口だけが現れ、入口にホバーするとパネルが開きます。入口へ一気に移動しても、入口の表示アニメーションを待たずに開きます。反応する領域は初版の縦横2倍です。パネルを閉じて離れると入口も隠れます。既定はオフで、設定を保存します。[二段階表示の検証記録](../progress/2026-10/2026-10-02_hover-pocket-top-entry-peek.md)。

Controlsでは再生速度を「− / ＋」で0.25倍刻みに変更し、Windowsメディアセッションの読み戻し値を表示します。再生サムネイルを押すと、一意に特定できた再生元ウィンドウだけを前面へ表示してパネルを閉じます。Timerはストップウォッチ、タイマー、ポモドーロの3種類を横並びの追加カードから登録できます。実行中項目は1列のコンパクトなリストへ表示し、ストップウォッチとカウントダウンを各4件まで独立して扱います。ストップウォッチは100分の1秒表示で、providerを切り替えたりパネルを閉じたりしてもアプリ稼働中は計測を続けます。

## ライブラリ同期（開発候補）

設定の「ライブラリの同期」で、Syncthingで共有したHoverPocket専用フォルダを選びます。最初の端末は「新規グループを作成」、2台目以降は「既存グループに参加」を押します。Eagleの共有フォルダやライブラリ保存先は選ばないでください。初期状態はオフで、原本・分類・名前・お気に入り・ゴミ箱を3秒ごとに処理します。実際の端末間転送はSyncthingが行います。

同時変更は上書きせず、設定画面に両方の内容を表示します。同名フォルダは名前を変更してから再試行できます。同期の一時停止中も素材は編集でき、再開時に送信します。ゴミ箱を空にする操作は原本の送信後に行えます。相手端末の原本を物理削除することはありません。

DBのみを復元する場合は同期を一時停止してください。復元後も現在の同期履歴と一時停止状態を保持します。同期済みライブラリの完全置換は、別の空ライブラリへバックアップを復元してから行ってください。同期用の転送フォルダは完全バックアップの代わりにはなりません。

[検証と実Syncthing往復の記録](../progress/2026-10/2026-10-05_hover-pocket-windows-sync.md)。再検証は powershell -File windows/script/verify_asset_sync.ps1 -IncludeUi。

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

パネル下部から直接チャットを入力できます。Enterで送信、Shift+Enterで改行、Escまたは収納ボタンで下書きと会話を保持したまま閉じます。返信と履歴は同じパネル内で開き、入力中と返答中はホバーを外しても自動収納しません。送信ボタンは返答中に停止へ切り替わります。音声をOFFにしていてもテキストは使えます。音声を有効にした場合は波形から会話を開始・終了できます。文字起こし専用の音声入力は現在のChatGPTログインでは未対応で、理由を無効な音声入力ボタンに表示します。

チャットの通信・履歴・停止・権限境界は `HOVERPOCKET_CHAT_VERIFY_ONLY=1` と `--verify voice`、実パネルの入力・IME・小/特大サイズ・手動収納・履歴・停止は `HOVERPOCKET_CHAT_PANEL_VERIFY_ONLY=1` と `--verify ui` で検査できます。`HOVERPOCKET_INLINE_CHAT_LIVE_VERIFY_ONLY=1` と `--verify ui` は、既存のアプリ専用ログインを使って日本語の確認文を実Codexに送り、パネル内の返信を確認します。実接続検査は既存のログインが必要で、資格情報を複製せず、検査用の素材庫と履歴を使います。複数の検査用環境変数を同時に指定せず、GUI検査は一つずつ実行してください。

開発版の素材ライブラリでは、選択した素材をサイドバーのフォルダ・お気に入り・未分類・ゴミ箱へドラッグできます。フォルダから別フォルダへ移した場合は元の所属だけを外し、それ以外の分類を残します。Ctrl+Zで直前の整理を戻せます。原本を複製せず、外部アプリへドラッグしたときだけ作業コピーを渡します。

外部ファイルを上端の入口へドラッグすると保存先パネルを表示します。ローカルファイル、画像データ、Windowsの仮想ファイル、画像・動画・音声の直接URLに対応し、元ファイルを保持します。URLと仮想ファイルは1ファイル128MiBまでです。Webページや配信サービスの再生ページは直接メディアとして取得しません。

ライブラリの「カメラ撮影・録音」からカメラ写真・カメラ動画・音声録音を選び、デバイスと保存先を指定して明示的に開始します。収録中は画面を閉じても継続し、上端に経過時間と停止ボタンを表示します。確定済みの保存待ちは「保存待ちを再試行」で取り込めます。音声はM4Aで保存し、素材の分類は既存の `other` を使います。

拡張機能の隔離検査は `HOVERPOCKET_LIBRARY_EXTENSIONS_VERIFY_ONLY=1` と `--verify ui` で実行します。生成したAACのパスを `HOVERPOCKET_ASSET_AUDIO_FIXTURE` に指定すると再生・シーク・保存待ち復旧も検証します。検査用のネイティブドラッグはポインターを動かします。実カメラ撮影は自動実行しません。

```powershell
dotnet run --project .\windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify shell
dotnet run --project .\windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify display
dotnet run --project .\windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify controls
dotnet run --project .\windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify ui
dotnet run --project .\windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify settings
dotnet run --project .\windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify weather
dotnet run --project .\windows\tests\Weather.Core\Weather.Core.csproj --configuration Release
dotnet run --project .\windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify pocket-surface
dotnet run --project .\windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify capabilities
dotnet run --project .\windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify broker
```

`--verify shell` は access surface と panel の `WS_EX_NOACTIVATE`、`WS_EX_TOOLWINDOW`、`WS_EX_TOPMOST`、2 回目起動、120ms pollingだけによるopen、hidden / 位置ずれ / style欠落の自己修復、window再生成、3段階recovery、ポインター移動、open/close 25回、描画フレーム数と最大フレーム間隔を検査します。

`--verify display` は現在のモニター構成を列挙し、`Main` / `Sub` / `All` の対象 display 数、`Sub` のサブなし fallback、access surface / panel / collapsed rect の画面内収まり、DIPs と物理ピクセルの round-trip を検査して exit code で返します。WinExe のため標準出力が空になる場合があります。

`--verify weather` と `Weather.Core` は同じ実装を使い、47都道府県、温度単位、8日間の予報、世界の都市検索、キャッシュの分離・破損・通信失敗、取消、不正データ拒否、特大サイズを検証します。テストは通信をfixtureへ置き換え、実際の位置情報許可を要求しません。`--verify settings` は地点・単位・特大サイズの保存後読み戻し、設定画面以外からの天気設定変更拒否、不正単位の拒否、既定値への復元も確認します。

`--verify controls` は音量・ミュート・輝度・メディア操作・再生元ウィンドウ解決の決定的テストと、実機の読み取り専用 probe を実行します。外部ディスプレイの輝度は DDC/CI 非対応や応答遅延を許容し、パネル全体を停止させずに非対応表示へフォールバックします。

`--verify ui` はWebView2とbridgeに加え、Controlsの実描画・領域内収まり・サムネイル/倍速操作、Timerの3種類の追加カード・複数ストップウォッチ・領域内収まり、Clipboardの同一provider再描画抑止、通常/お気に入りタブ、中央split view、全体プレビュー、個別削除UI、Calculator履歴サイドバーを検査します。

`--verify pocket-surface` はPocket App DSLのToday Focus fixtureを厳格に読み込み、未知のcomponent・query・workflow、host境界違反、asset path traversal、深さ・node数・文字数・文書サイズ超過をfail-closedで拒否し、同じ入力から同じ描画モデルが得られることを検査します。Capability実行やProvider Storeへの書き込みは行いません。

`--verify updater` は Velopack のローカルフォルダーフィードを一時生成し、更新なし / 更新ありの dry-run を確認します。実ダウンロードと適用は行いません。

`--verify ui` はバックグラウンドから送ったイベントがWebView2へ届くことと、一時データで開始した無音タイマーが、非表示パネルを満了時に再表示することも確認します。実際の通知音やWindowsのスリープはこの検証に含みません。

`0.2.9-local.2` はWindows公開版 `win-v0.2.8` を基準にしたローカル安定化候補です。タイマー等からWebView2への送信をUIスレッドへ移し、終了済みパネルへの遅延送信を無視します。タイマー満了イベントは接続中の各画面へ送信し、設定画面の開閉でパネルへの通知を失わないようにしています。公開releaseは作成していません。

`--verify release-config` は、配布成果物がRelease構成・期待バージョン・Windows更新channel・Google OAuth AssemblyMetadataを持ち、ビルド時の設定と一致することを値を表示せず確認します。

`--verify calendar-live` は、既存のWindows Credential Manager資格情報を使って当月のCalendarを読み取り、予定内容を表示せずcalendar数とevent数だけを出力します。予定の作成・更新・削除は行いません。

`--verify capabilities` はCalendar / Timer / Sticky NotesのProvider Capability handlerを検証します。`--verify broker` はRegistry、権限、承認の改変・期限切れ・再利用拒否、永続idempotency、実行後readback、監査ログの本文非保存、Today Focus、部分失敗時のTimer補償、timeout、macOSと共通のplan digestを検証します。

## Codex Pocket App生成用Windows sandbox

Windowsのsetup / repairは現在、`GENERATOR_SANDBOX_SETUP_UNAVAILABLE`でproduction fail-closedです。Settingsは状態を表示しますが、実行ボタンを無効化し、forged bridge requestでもpicker、copy、UAC、filesystem変更へ進みません。管理者PowerShellのcheck / `-Provision`もpath検査やdirectory作成より前に`HP_CODEX_SANDBOX_SETUP_UNAVAILABLE`で停止します。

公式Codex 0.145.0のWindows配布物は`codex.exe`だけでは完結せず、少なくとも`codex-resources\codex-windows-sandbox-setup.exe`と`codex-command-runner.exe`を別ファイルとして持ちます。現行のpath-based setupは、固定Codex Homeのwhole-home / nested reparseをUAC中に同一objectへ束縛できず、resource不在時にはbare helper名へfallbackします。このため、旧setup-v5 markerや固定`codex.exe`が残っていてもproduction generatorを構成しません。

再有効化には、署名済みnative helper、元ユーザーSID binding、admin-controlled root、全path componentのreparse / identity検査、公式resource closureのexact size・SHA・署名検証、絶対path起動、single-flight、child process所有、実行後readbackが必要です。通常の生成時にUACを出さず、workspace、virtual User Home、Tempを毎回破棄する設計は維持します。

恒久helperの最初の境界として`HoverPocket.CodexSandboxSetup`を追加しています。現段階ではproduction dispatchを常に`HP_CODEX_SANDBOX_HELPER_NOT_ACTIVATED`で拒否し、公式0.145.0配布物の6ファイルclosure、exact size、SHA-256、Authenticode状態と署名者を決定的に検証するモードだけを提供します。CIはnpm archive自体のSHA-512に続けて、このnative verifierで展開後のclosureをreadbackします。Shellとhelperの間には元プロセスID、Windows SID、完全修飾account、nonce、複製対象handleの期限付きcontractと、同一publisher署名を要求する読み取り専用admissionまで実装済みです。helper内部にはProgramData配下の固定root、管理者ACL、同一handleからのcopy、nonceごとのsingle-use Home、`--user` / `--codex-home`による固定環境setup、Job Object、元SIDだけが読めるattestation readbackも実装しています。helper側のproduction switchは引き続きOFFです。

Shell側にはSettings専用のdormant launch boundaryがあります。helper originは64-bit Program Files known folder配下の`HoverPocket\CodexSandboxSetup\HoverPocket.CodexSandboxSetup.exe`だけで、Shell成果物へapp-local helperをcopy / publishしません。固定pathの全directory componentとhelper本体をregular / non-reparse objectとしてhandleでpinし、Shell build metadataに設定したpublisher certificate SHA-256と有効なAuthenticode signerが一致した場合だけlaunch requestを構成します。WinVerifyTrustはrootを除くcertificate chain全体の失効確認を必須にし、cache-onlyへfallbackせず、失効状態を確認できない場合もUAC前に拒否します。既存のnative既定No確認がYesになった後に限り、同じpinned helperへ`runas`を1回だけdispatchし、`--setup-request` / `--request-sha256` / `--nonce`の固定順argumentを渡します。UAC取消、start失敗、timeout、nonzero exit、process image / object identity readback失敗はpathやhashなどを含まない固定codeへ丸めます。

helperの固定originは、専用のper-machine MSIが`%ProgramFiles%\HoverPocket\CodexSandboxSetup`へself-containedな`win-x64` publish一式を配置する契約です。MSIは埋め込みcabinet、固定UpgradeCode、64-bit component、major upgradeとuninstallを持ち、CustomAction、service、registry、environment、shortcutを追加しません。CIはMSI databaseを別経路で読み、`ALLUSERS=1`、配置先のdirectory ancestry、helperが1本だけ含まれること、禁止tableが空であることを検証します。`ProvisioningAvailable`、`ProductionRuntimeAvailable`、helperのproduction activation、generated-app activationは引き続きOFFなので、未署名betaやforged Settings bridge request、generation、Voice、startup、background task、canaryからUACへ到達しません。`--verify settings`は署名binaryや実elevationを使わないinjectable seamで固定origin、publisher、object identity、exact arguments、1回だけの`runas`、取消・timeout・nonzero・readback failureを検証します。

```powershell
dotnet run --project .\windows\src\HoverPocket.CodexSandboxSetup\HoverPocket.CodexSandboxSetup.csproj -- --contract-self-test
dotnet run --project .\windows\src\HoverPocket.CodexSandboxSetup\HoverPocket.CodexSandboxSetup.csproj -- --verify-vendor-closure <公式package root>
```

installerはWiX SDK 5.0.2で決定論的にbuildします。formal releaseでは`publish_release.ps1`がShellとhelperの双方へ同じ公開publisher certificate SHA-256 referenceを`HoverPocketPublisherCertificateSha256` MSBuild propertyで渡し、helper EXEをtimestamp付きで署名してからWiX harvestし、MSI build後に同じ証明書でMSI自体もtimestamp付き署名します。未設定・不正形式・signing tool不在・署名/timestamp/publisher不一致はmanifest確定前にfail closedです。Settings側のregular / non-reparse file、固定Program Files origin、publisher、object identityの再検証は維持します。

```powershell
dotnet publish `
  .\windows\src\HoverPocket.CodexSandboxSetup\HoverPocket.CodexSandboxSetup.csproj `
  --configuration Release --runtime win-x64 --self-contained true `
  -p:PublishSingleFile=false -p:DebugSymbols=false -p:DebugType=None `
  --output <空のhelper-publish-directory>

dotnet build `
  .\windows\installer\HoverPocket.CodexSandboxSetup.Installer\HoverPocket.CodexSandboxSetup.Installer.wixproj `
  --configuration Release --output <空のinstaller-output-directory> `
  -p:ProductVersion=0.2.7 -p:HelperPublishDir=<helper-publish-directory>

.\windows\script\verify_codex_sandbox_installer.ps1 `
  -MsiPath <HoverPocket.CodexSandboxSetup.msi> `
  -ExpectedProductVersion "0.2.7" `
  -ExpectedUpgradeCode "{9E28ABD6-A496-472E-98AB-AE8D70C27B48}"
```

positive confinement canaryは上記helper完成後に準備済みhomeを明示し、生成中にUACを要求しないこと、固定Codex Homeと`.sandbox-secrets`をmodel toolが読めないことを含めて確認します。現在は実行対象外です。

```powershell
.\windows\script\verify_codex_generation_confinement.ps1 `
  -CodexBin <固定したcodex.exe> `
  -SandboxImplementation elevated `
  -ProvisionedCodexHome "$env:LOCALAPPDATA\HoverPocket\CodexGenerationSandbox\codex-home"
```

production resolverは、固定先のexact binaryと準備済みcontrol-planeが揃った次回起動だけで生成adapterを構成します。生成物のactivationは引き続きOFFです。no-UAC positive canary、credential delivery、実モデル生成readbackが揃う前に有効化しません。

## Windows updates and release packaging

`0.2.10`は、素材の複数選択・名前変更・右クリック操作、プレビュー内編集、クリップボードの読み込み改善、スクショのその場での装飾と画像付き通知からのドラッグを含みます。通知の表示時間は撮影・収録の設定から変更できます。[配信記録](../progress/2026-10/2026-10-04_hover-pocket-windows-0210-release.md)。

`0.2.9`は、実機で確認済みのlocal.15を配布版へ反映したものです。素材管理、撮影・収録、注釈編集、プレビューの表示改善を含みます。[配信記録](../progress/2026-10/2026-10-04_hover-pocket-windows-029-release.md)。

Windows 版の更新確認は Velopack と GitHub Releases (`shotaro311/hover-pocket`) を使います。トレイと Settings の `Check for Updates` は Windows channel `win` の feed (`releases.win.json`) へ接続し、更新が見つかった場合はダウンロード前と適用/再起動前に確認します。起動時の自動チェックは既定オンで、失敗しても起動を止めません。
更新後の通常起動では、実インストールのrootと既存ARP entryの`InstallLocation`が一致する場合だけ、HKCUの`HoverPocketWin` entryにある`DisplayVersion`を現在versionへ補正します。portable、verify、second-instance probe、path不一致、keyなしでは変更しません。

Windows は macOS Sparkle の `https://github.com/shotaro311/hover-pocket/releases/download/macos-latest/appcast.xml` を使いません。Windows release は `win-v0.2.8` のような Windows 専用 tag / asset を使い、GitHub Release を作る場合は `--latest=false` を付けてmacOSのLatest / appcastを動かさないでください。

### 署名方針

- Windows 0.2.xは、コード署名証明書を取得するまでAuthenticode未署名の公開ベータとして配布します。
- Setup.exeの初回実行時にMicrosoft Defender SmartScreenの警告が出る可能性があることを、ダウンロード導線とRelease notesに明記します。
- 1.0またはmacOS版と同等の正式版では、タイムスタンプ付きAuthenticode署名と公開成果物の署名readbackを必須gateにします。
- 正式版のworkflow実行前に、正規コード署名証明書raw byteのSHA-256 fingerprintをGitHub Actions repository variable `WINDOWS_SIGNER_CERT_SHA256`へ64文字の16進数で設定します。値が未設定・不正、またはSetup / Portable内Shell / full package内Shell / helper MSI / embedded helperの署名証明書と不一致ならformal gateはfail closedにします。証明書更新時は公開前レビューでこのvariableも明示更新します。
- 署名証明書やsigning credentialsはGit、ログ、README、progressに記録しません。

Release assetはmacOS Sparkle資産と衝突しない`HoverPocketWin-*`系です。`publish_release.ps1`は、OAuth環境変数が未設定の場合に停止し、Release成果物内のmetadata一致を確認してからVelopack package、`release-manifest.win.json`、`SHA256SUMS-win.txt`を生成します。GitHub Releaseの作成・アップロードはこのスクリプトでは実行しません。manifest schema 2は`codexSandboxSetup`を追加し、formalだけがversion固定名の専用MSI、実測size/SHA-256、MSI/helperのtimestamped Authenticode、同一publisher agreementを記録します。一方、既定の`beta` gateは未署名成果物だけを生成し、専用helper MSIをpublishせず、`trustedProductionSetupBoundary`、`productionSetupAvailable`、`productionGenerationAvailable`、`productionActivationAvailable`をすべてfalseに固定します。署名引数をbetaへ混在させると停止します。publish / release出力は毎回空の通常directoryである必要があり、既存payload、file、reparse pointを検出した場合は削除や上書きを行わず停止します。再実行時は新しい`-OutputRoot`を指定します。

```powershell
.\windows\script\publish_release.ps1
```

正式版は、パスワードやPFXをコマンドラインへ渡さず、Windows証明書ストアに導入済みのコード署名証明書をSHA-1 thumbprintで選びます。RFC 3161 timestamp URL、readback用のpublisher証明書SHA-256、必要な場合だけmachine store指定を明示します。formalではまずShellへpublisher SHA-256 metadataを埋め込み、helperをself-contained publishして直接署名し、その署名済みhelperを専用per-machine MSIへharvestしてからMSIを署名します。その後Velopackへ`/fd sha256 /td sha256 /tr`を渡し、生成したSetup、Portable内アプリ、full package内アプリ、helper、MSIの5点について署名の有効性、timestamp、同一publisher一致をローカルで再検証できた場合だけmanifestを`signed-timestamped-verified`にします。値はログへ出力しません。

```powershell
.\windows\script\publish_release.ps1 `
  -WindowsSigningGate formal `
  -SigningCertificateSha1 $env:HOVERPOCKET_SIGNING_CERT_SHA1 `
  -ExpectedSignerCertificateSha256 $env:HOVERPOCKET_SIGNER_CERT_SHA256 `
  -TimestampServer $env:HOVERPOCKET_TIMESTAMP_SERVER `
  -SignToolPath $env:HOVERPOCKET_SIGNTOOL_PATH
```

証明書をLocalMachine storeへ導入した運用だけ`-SigningCertificateInMachineStore`を追加します。どのformal引数も空、不正形式、HTTP timestamp、credential入りURL、署名不一致の場合は成果物manifestを確定せず停止します。秘密値をGit、README、progress、GitHub repository variableへ保存しません。`WINDOWS_SIGNER_CERT_SHA256`は秘密値ではなく公開後readback用fingerprintですが、設定値そのものはログへ出しません。

NuGet TLS 問題がある環境では、一時ローカル NuGet ソースと `-NuGetSource` / `-VpkPath` を指定して実行します。workspace に nupkg を残さないでください。

スクリプトの出力する GitHub 手順は、Windows release 作成時に `--latest=false` を含みます。アップロード後は次を readback し、Windows feed と asset だけが読めること、macOS `macos-latest/appcast.xml` が変わっていないことを別々に確認します。

```powershell
gh release view win-v0.2.8 --repo shotaro311/hover-pocket --json tagName,assets,url
Invoke-WebRequest -UseBasicParsing -Uri https://github.com/shotaro311/hover-pocket/releases/download/win-v0.2.8/releases.win.json
Invoke-WebRequest -UseBasicParsing -Uri https://github.com/shotaro311/hover-pocket/releases/download/macos-latest/appcast.xml
```

MacまたはCIからは、Windows releaseだけでなくmacOS appcastが変わっていないことも同時に機械検証できます。`auto`はdraft / prereleaseを除外した公開済み`win-v...`タグの最大semantic versionを選びます。公開された全Windows assetを再取得し、実測hashをfeed、checksum、GitHub metadataと照合します。GitHubの汎用Latestはrelease選択には使わず、期待するmacOS versioned releaseのままであることの確認にだけ使います。

```bash
python3 script/verify_release_readback.py --windows-tag auto --windows-signing-gate beta
```

1.0正式版では`Verify Published Release Readback` workflowを`formal`で手動実行します。`release-manifest.win.json`の`authenticode=signed-timestamped-verified`だけを信用せず、immutable asset snapshotから全assetを再downloadしてhashを取り直し、Windows上で公開Setup、Portable内`HoverPocket.Shell.exe`、Velopack full update package内`HoverPocket.Shell.exe`、専用MSI、MSI administrative imageから取り出した`HoverPocket.CodexSandboxSetup.exe`の実Authenticode署名とtimestampを検証します。さらに公開MSIを`verify_codex_sandbox_installer.ps1`で再読込し、MSI/helperの実測size/SHA-256がmanifestと一致し、5成果物がrepository variableへ固定した同一publisher certificate SHA-256へ収束する場合だけformal readbackを合格にします。Setupのpackage同一性は、Velopack 1.2.0のbundle headerに埋め込まれたoffset / lengthを使い、署名時に末尾へ追加されるPE証明書表をpackage byteとして扱わずに検証します。

公開済み2version間の実installer / updater遷移は`Verify Release Install and Rollback Transitions` workflowで確認します。既存Velopack遷移はGitHub hosted Windows runnerの一時install rootに旧Setupをsilent installし、新full package適用、旧full packageへの明示rollback、再upgrade、uninstall、reinstall、user data保持までをreadbackします。自動更新はdowngradeしないため、rollbackは`Update.exe apply --package`で旧packageを明示します。未署名0.2.x betaを実行する場合は、`execute_windows_release_code`とunsigned beta許可を手動workflowで明示する必要があり、formal Velopack遷移の既存fail-closed拒否は維持します。

専用helper MSIには別の`execute_codex_sandbox_installer_transition` gateを追加します。このgateはschema 2 formal manifest、公開snapshot、MSI hash、timestamped Authenticode、期待publisherを再検証した後だけ、disposable Windows runnerの固定Program Files先へ旧MSI install → 新MSI major upgrade → 新MSI uninstall + 旧MSI reinstallによる明示rollback → uninstallを実行し、各段階でinstalled helperのhashと署名をreadbackします。このgateはsetup/generation/activationを有効化せず、helper自体を起動しません。開始時と合格直前のrelease asset snapshot一致も必須です。

残る物理gateは別です。通常ユーザーのWindows実機で、署名済みShell + signed per-machine MSIを使ったSettingsの明示操作からだけUAC secure desktopへ1回到達すること、固定Program Files helper/object identity/publisher readback、UAC取消・tamper時の副作用0、setup完了後のno-UAC positive confinement canary、Host-owned credential delivery、実モデル生成readbackを確認する必要があります。これらのphysical UAC / signed-host canaryが完了するまではproduction setup/generation/activation flagsをfalseのまま維持し、完了したとは扱いません。

## Local privacy notes

通常起動の診断記録は `%APPDATA%\HoverPocket\diagnostics\session-*.jsonl` に保存します。起動・準備完了・トレイからの終了・Windowsセッション終了・未処理例外・WebViewプロセス障害を記録し、時刻・PID・バージョン・例外型・エラー番号・コードのメソッド名に限定します。例外本文、画像やファイル名、入力内容、認証情報は保存しません。強制終了など、OSが終了イベントを渡さない場合の理由は記録だけでは断定できません。


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

### 端末コード連携と設定画面

設定は「一般・表示・素材と同期・撮影・AI・詳細」の6カテゴリと検索で操作します。通常の端末連携は「端末を追加」→別端末でコード入力→元端末で相手を確認して許可、の順です。既存の共有先は保持し、新規参加時はアプリが転送用フォルダを用意します。手動フォルダ設定は復旧用の「接続の詳細」にあります。

両端末でSyncthingを起動してください。短いコードの交換にはTLS仲介サービスとSPAKE2を使います。メディアは仲介サービスへ送りません。コードは5分・1回限りで、承認後に専用共有を登録します。解除はそのライブラリの共有だけを停止し、受信済みのコピーは残します。Eagleの共有や既存端末設定は変更しません。

WindowsビルドにはCargo/Rust 1.92以降が必要です。MSBuildが `shared/pairing-helper` の固定依存をビルドし、単独EXEとライセンスを同梱します。共通プロトコルは同ディレクトリのREADMEを参照してください。

検証: `dotnet run --project windows/tests/Pairing`（隔離API/パス検査）、`cargo test --locked --manifest-path shared/pairing-helper/Cargo.toml`、`windows/script/verify_asset_sync.ps1 -IncludeUi`。公開仲介への隔離接続試験は、架空の端末IDだけを使って `python shared/pairing-helper/verify_pairing.py <helper.exe>` を実行できます。
