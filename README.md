# ホバーポケット (HoverPocket)

ホバーポケットは、画面上部のノッチ付近へマウスを重ねるだけで、ミラー、ディスプレイ/音量/メディア操作、Google Calendar、クリップボード履歴、付箋メモを素早く開ける macOS アプリです。

画面上部に小さな黒いハンドルを置き、そこへホバーすると暗いユーティリティパネルが表示されます。通常のメニューバーアプリよりも、必要なものをポケットからパッと取り出す体験を重視しています。

## 名前と配布状態

- 表示名: `ホバーポケット`
- 実行ファイル / SwiftPM product / release asset 名: `HoverPocket`
- Bundle ID: `local.codex.hover-pocket`
- GitHub repository: `shotaro311/hover-pocket`
- 最新の公開版は GitHub Releases の `Latest` です。
- 公開 ZIP は Developer ID 署名、Apple notarization、staple 済みです。
- Sparkle の appcast は GitHub Releases の latest download として公開しています。

## ダウンロードとインストール

一般ユーザーは、GitHub Release の Assets から `HoverPocket-macOS-app.zip` をダウンロードしてください。

```text
https://github.com/shotaro311/hover-pocket/releases/latest/download/HoverPocket-macOS-app.zip
```

解凍すると `HoverPocket.app` だけが出ます。この `HoverPocket.app` を `アプリケーション` フォルダへ移動して起動します。

GitHub が自動で表示する `Source code (zip)` / `Source code (tar.gz)` は開発者向けのソースコード一式です。アプリ本体ではないため、通常のインストールでは使いません。

## 現在できること

現在は組み込みの `Mirror`、`Controls`、`Calendar`、`Clipboard`、`Sticky Notes`、`Timer` プロバイダーを搭載しています。パネル下部には AI command lane があり、Calendar 操作の一部を自然文から実行できます。

### ミラー

- ノッチハンドルへホバーすると、MacBook のカメラを使った鏡表示を開けます。
- カメラ映像は左右反転し、実際の鏡のように表示します。
- カメラはミラーパネルが有効な間だけ起動し、閉じると停止します。
- 初回利用時は macOS のカメラ権限ダイアログが表示されます。
- 設定から、ミラー下部にコンパクトなマイクチェック UI を表示できます。
- マイクチェック UI 表示中は音声レベルメーターを確認でき、一時録音、停止、再生もできます。
- 録音データはメモリ上だけで扱い、音声ファイルとして保存しません。

### Google Calendar

- Google アカウントで接続し、カレンダー予定を表示できます。
- 日付へホバーすると、その日の予定をプレビューできます。
- 日付をクリックすると、その日の予定詳細を固定表示できます。
- 書き込み可能なカレンダーでは、予定の追加、編集、削除ができます。
- 編集では、タイトル、開始/終了時刻、終日、場所、メモを変更できます。
- 日時入力は手入力に加えて、インラインの調整バー、スクロール、ドラッグで微調整できます。
- 日付セルのダブルクリックから、新規予定作成を起動できます。

### クリップボード

- テキストのコピー履歴を左側に表示します。
- 画像のコピー履歴を右側に表示します。
- 履歴項目をクリックすると、再びクリップボードへコピーできます。
- テキストや画像を他のアプリへドラッグできます。
- 画像履歴はローカルの Application Support 配下に保存します。

### Sticky Notes

- 付箋メモをボードグリッドで表示できます。
- 付箋はタイトルと本文を持ちます。タイトルは空欄でもよく、その場合は本文の先頭が一覧上の見出しになります。
- 付箋クリックで、そのカードがふわっと拡大する inline editor に切り替わります。
- 編集中の内容は、別の付箋や付箋外をクリックしたタイミングでも保存されます。
- `Control + Enter` で編集を確定できます。
- タイトルと本文が空欄の新規付箋は保存せずに破棄します。
- 色スウォッチのダブルクリックで、その色の新規付箋を作れます。
- 付箋グリッドサイズは `S / M / L` で切り替えられます。
- 付箋のドラッグ並び替えに対応しています。
- 付箋を外部へドラッグすると、他のメモアプリやテキスト入力欄へ本文を渡せます。
- 付箋ドラッグ中は下部にゴミ箱エリアが表示され、そこへドロップするとアーカイブできます。
- 右クリックメニューから、編集、色変更、アーカイブ、削除ができます。
- アーカイブ / 削除後の Undo toast は Settings から表示/非表示を切り替えられます。
- データは `Application Support/HoverPocket/StickyNotes/notes.json` に JSON として保存します。

### Controls

- ディスプレイごとの明るさをバーで表示し、対応しているディスプレイではドラッグで調整できます。
- 明るさバー右側の月 / 太陽アイコンで、最小輝度と最大輝度をトグルできます。
- 外部ディスプレイなど OS 側の明るさ API が使えない画面は `非対応` と表示し、操作を無効化します。
- 音量は CoreAudio 経由で取得、調整できます。
- 音量バー右側のアイコンでミュートを切り替えられます。
- 再生中メディアがある場合は、アートワークをサムネイルとして表示し、再生位置バー、10秒戻し、再生/一時停止、10秒送り、倍速調整を操作できます。
- 再生/一時停止と倍速は操作直後に UI へ即時反映し、その後の読み戻しで実際の状態に補正します。
- Now Playing 情報や一部の再生制御は macOS の MediaRemote bridge が使える場合だけ有効です。取得できない場合は空状態として表示します。

### Timer

- 「タイマー」と「ポモドーロタイマー」の2つの入力カードから開始できます。各カードにタイトル（任意）、色（4色）、音あり/なしを設定できます。
- 時間は直接入力に加えて、Calendar 編集と同じインラインの調整バー（ドラッグ/スクロール）で微調整できます。
- ポモドーロタイマーは作業時間と休憩時間を設定でき、フェーズが自動で交互に切り替わります。
- 開始したタイマーは上部の「実行中」にカウントダウン表示されます。2つまで同時に実行でき、それぞれ色分けして表示します。
- 実行中タイマーの右上のピン留めマークを押すと、その設定をピン留めとして固定し、繰り返し使えます。ピン留めは4つまでストックできます。
- 実行中タイマーは一時停止、再開、停止ができます。残り時間は終了時刻ベースで計算するため、スリープ復帰後も狂いません。
- タイマーが終了すると、ノッチ横のバーが上端から下へぴょこぴょこ顔を出すようにバウンスして通知します。
- 終了時はホバーウィンドウが自動的に開いてタイマー画面を表示し、そこでアラームを停止できます。
- 音ありの場合はシステムサウンドを停止まで繰り返し再生します。
- Reduce Motion 有効時はアニメーションを省略し、静的なハイライトのみ表示します。
- 入力カード・ピン留め・実行中タイマーは `Application Support/HoverPocket/Timer/` に JSON として保存します。

### AI command lane

- パネル下部の入力欄から、短い自然文で Calendar 操作を呼び出せます。
- 例: `今日の予定`、`明日14時 打ち合わせ`、`金曜 デザイン納期`
- Apple Foundation Models が使える環境では structured output を優先します。
- SDK / OS が未対応の環境では deterministic fallback で候補を生成します。
- Calendar 書き込みなどの変更操作は、Approval Gate の確認を通してから実行します。
- 実行内容はローカルの audit log に記録する設計です。

## 設定

- 表示先ディスプレイ: `Main / Sub / All`
- パネルサイズ: `Small / Medium / Large`
- 表示するプロバイダーの ON / OFF
- プロバイダーの表示順
- 前回開いたプロバイダーを優先するか、固定のデフォルトパネルを使うか
- プロバイダーアイコンの切り替え方式: `Click / Hover`
- ノッチ横の小さな handle area の表示 / 非表示
- handle icon: `B / C / None`
- Mirror の microphone check row 表示 / 非表示
- Sticky Notes の Undo toast 表示 / 非表示
- Sparkle による手動アップデート確認

## 動かし方

```bash
./script/build_and_run.sh
```

ビルド、起動、プロセス存在確認まで行う場合は次のコマンドを使います。

```bash
./script/build_and_run.sh --verify
```

成功すると `HoverPocket launched` と表示されます。

`build_and_run.sh` は `dist/HoverPocket.app` を生成し、利用できる `Apple Development` 署名があれば app bundle を署名します。配布用 ZIP では Developer ID Application 署名と hardened runtime を使います。

## Google Calendar の設定

Calendar プロバイダーは、Google の iOS OAuth client、custom URL scheme、PKCE を使うネイティブ認証フローを優先します。iOS OAuth client が未設定の場合だけ、既存の Desktop OAuth + loopback redirect + PKCE にフォールバックできます。Google の認証画面はどちらのフローでも OS 既定ブラウザで開きます。

Google token は Keychain に保存します。OAuth client secret や token 類はソース管理に含めません。配布版のユーザーは、Calendar パネルまたは Settings から Google のログイン画面を開き、Google アカウントで許可すれば使えます。

まず `.env.example` を参考に、ローカル用の `.env.local` を作成します。

```bash
BUNDLE_IDENTIFIER="local.codex.hover-pocket"
GOOGLE_SIGN_IN_CLIENT_ID="YOUR_IOS_OAUTH_CLIENT_ID.apps.googleusercontent.com"
GOOGLE_SIGN_IN_REVERSED_CLIENT_ID="com.googleusercontent.apps.YOUR_IOS_OAUTH_CLIENT_ID_PREFIX"
```

有効な `gcloud` project で OAuth client を作る場合は、補助スクリプトを使えます。

```bash
./script/open_google_oauth_console.sh
```

Google Auth Platform で application type を `iOS` にして client を作成し、bundle ID には `BUNDLE_IDENTIFIER` と同じ値を入れてください。発行された client ID と iOS URL scheme を `.env.local` に入れます。アプリの redirect URI は `GOOGLE_SIGN_IN_REVERSED_CLIENT_ID:/oauth2redirect/google` の形式で使います。

既存の Desktop OAuth を開発用フォールバックとして使う場合だけ、次の値も設定します。iOS OAuth client が設定されている場合、このフォールバックは明示的に有効化しない限り app bundle へ埋め込みません。

```bash
GOOGLE_OAUTH_ENABLE_LEGACY_FALLBACK="1"
GOOGLE_CLIENT_ID="YOUR_DESKTOP_OAUTH_CLIENT_ID.apps.googleusercontent.com"
GOOGLE_CLIENT_SECRET="YOUR_DESKTOP_OAUTH_CLIENT_SECRET"
```

設定後は次の順で確認します。

```bash
./script/check_google_calendar_setup.sh
./script/build_and_run.sh --verify
./script/verify_google_calendar.sh
```

## ZIP アプリと公開リリース

ローカル配布確認用の ZIP は次のコマンドで作成できます。

```bash
./script/package_zip.sh
```

成果物は `dist/releases/` に出力されます。Developer ID Application 証明書が見つかる場合は hardened runtime 付きで署名し、Sparkle 用の `appcast.xml` も生成します。一般配布に使う ZIP は、必ず Apple notarization と staple まで通します。

最初に Apple ID / Team ID / app-specific password を Keychain profile として保存します。

```bash
xcrun notarytool store-credentials hover-pocket --apple-id <apple-id> --team-id <team-id>
```

保存後、次のコマンドで ZIP 作成、notarytool 送信、staple、再 ZIP、SHA256 / appcast 再生成、`spctl` 検証まで実行します。

```bash
NOTARYTOOL_PROFILE=hover-pocket ./script/notarize_release.sh
```

CI などで App Store Connect API key を使う場合は、`NOTARYTOOL_KEY`、`NOTARYTOOL_KEY_ID`、必要に応じて `NOTARYTOOL_ISSUER` を環境変数で渡します。秘密情報は `.env` や Git 管理ファイルへ書き込まないでください。

GitHub Releases へ ZIP、SHA256、appcast をアップロードする場合は次のコマンドを使います。

```bash
NOTARYTOOL_PROFILE=hover-pocket ./script/publish_github_release.sh
```

`publish_github_release.sh` は既定で `script/notarize_release.sh` を実行し、notarized / stapled 済みの ZIP だけを公開します。既に作成済みの成果物だけを確認する dry run は次のように実行します。notarized でない ZIP はここで拒否されます。

```bash
PUBLISH_DRY_RUN=1 ./script/publish_github_release.sh
```

内部検証用に notarization 要求を外す場合だけ、次のように実行できます。

```bash
PUBLISH_DRY_RUN=1 PUBLISH_REQUIRE_NOTARIZED=0 ./script/publish_github_release.sh
```

通常の一般配布では `PUBLISH_REQUIRE_NOTARIZED=0` は使わないでください。

## 自動アップデート

自動アップデートは Sparkle 2 を使います。ローカル開発ビルドでは、未公開の更新フィードを見に行かないよう `SPARKLE_FEED_URL` を明示した場合だけ Settings の `Check for Updates` が有効になります。

配布 ZIP を作る `./script/package_zip.sh` と `./script/notarize_release.sh` では、既定で次の appcast を見に行く設定をアプリに入れます。

```text
https://github.com/shotaro311/hover-pocket/releases/latest/download/appcast.xml
```

Sparkle の公開鍵は `SUPublicEDKey` として `Info.plist` に入ります。秘密鍵は macOS Keychain の `hover-pocket` アカウントに保存され、Git には含めません。

公開時は GitHub Release に `HoverPocket-<version>-<build>.zip`、`.sha256`、`HoverPocket-macOS-app.zip`、`appcast.xml` をアップロードし、remote appcast の `sparkle:version`、ZIP の SHA256、Sparkle EdDSA signature、展開後 app の `codesign` / `stapler validate` / `spctl` を確認します。

## 表示先ディスプレイ

表示先は設定画面から選べます。

- `Main`: macOS のメインディスプレイを常に使います。
- `Sub`: サブディスプレイがあれば使い、なければメインディスプレイへ戻します。
- `All`: 各ディスプレイの上部に起点を表示します。

実ノッチが検出できる画面では、ノッチに接続したレイアウトを使います。ノッチがない画面では、画面上部中央の控えめなミニバーとして表示します。ミニバーの縦ヒット領域は上端 8pt で、近づくと 5pt 下へ広がる表示だけを残しています。

## 実装メモ

SwiftUI の `MenuBarExtra` はクリック操作が中心で、標準の右上メニューバー領域に寄っています。このアプリでは、AppKit の `NSPanel` と SwiftUI の hover handler を組み合わせ、画面上部中央のノッチ周辺にトリガーを置いています。

現在の構成は、hover shell と provider-hosted content に分かれています。新しい機能は `PocketProvider` として追加し、`ProviderRegistry` に登録して `PluginHostView` から表示する方針です。

```text
Sources/HoverPocket/
  App/         アプリ delegate と起動処理
  Windowing/   NSPanel 作成、ノッチ位置計算、hover close、animation timing
  State/       パネル表示状態、provider 選択、settings、store
  Models/      provider ID、action、permission、calendar、clipboard、sticky note model
  Providers/   PocketProvider protocol と ProviderRegistry
  Views/       pill、panel shell、provider UI、settings、AI command lane
  Services/    OAuth、Calendar API、system controls、AI model provider、approval、audit、updater
  Support/     再利用 shape と小さな helper
```

`Windowing` は AppKit window、画面/ノッチ計測、open/close animation を担当します。各 provider は `NSPanel`、`NSApp`、画面座標を直接触らない方針です。

## ノッチサイズのメモ

macOS の画面レイアウト値は物理ピクセルではなく point です。現在の内蔵 Retina ディスプレイでは、ノッチ周辺の計測値は次の通りでした。

```text
safeAreaInsets.top = 32pt
backingScaleFactor = 2.0
1px = 0.5pt
```

厳密な 1px 補正は `safeAreaInsets.top + 0.5pt` ですが、このアプリでは `33pt` が見た目として自然でした。つまり、現在は `safeAreaInsets.top + 1pt`、2x Retina では物理 +2px の補正を使っています。

この値は見た目合わせの補正であり、すべての Mac で使える普遍的なノッチルールではありません。将来的に複数モデルへ対応する場合は、`NSScreen.safeAreaInsets.top`、`backingScaleFactor`、`auxiliaryTopLeftArea`、`auxiliaryTopRightArea` から計算する方針です。

現在の実機では、`auxiliaryTopLeftArea` と `auxiliaryTopRightArea` から次のノッチ幅を取得しています。

```text
notch x = 663pt ... 848pt
notch width = 185pt
left handle width = 54pt
pill frame = x: 609pt, width: 239pt
```

これにより、左側のハンドル右端がノッチ左端に揃い、黒いベースがノッチ裏まで続く見た目になります。Settings でノッチ横 handle area を非表示にした場合、または handle icon を `なし` にした場合は、ノッチ横の黒い背景も描画しません。preview center はノッチ中心を維持します。

## License

MIT License です。詳細は [LICENSE](LICENSE) を確認してください。

このライセンスはソースコードに対する利用許諾です。`ホバーポケット` / `HoverPocket` の名称、ロゴ、ブランド表示の商標的な利用許諾とは別です。

## License

MIT License です。詳細は [LICENSE](LICENSE) を確認してください。

このライセンスはソースコードに対する利用許諾です。アプリ名、ロゴ、ブランド表示の商標的な利用許諾とは別です。

## 注意

- `.env.local`、OAuth 設定値、token 類は Git に含めないでください。
- Clipboard 履歴は機密テキストも拾える可能性があります。今後、除外ルール、保存期間設定、private mode を追加する余地があります。
- Google OAuth consent screen が Testing の場合、登録済み test user だけがログインできます。一般公開には Google OAuth app verification が必要になる可能性があります。
- Apple Foundation Models provider は SDK / OS が未対応の場合、deterministic fallback で候補生成します。モデル本体の実行確認は対応 OS で別途必要です。
- Developer ID 署名、notarization、Sparkle 更新は整備済みです。自動起動、正式 installer、quarantine 付きダウンロード後の初回起動 UX は今後の確認対象です。
