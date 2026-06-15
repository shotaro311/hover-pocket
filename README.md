# ホバーポケット (HoverPocket)

ホバーポケットは、画面上部へマウスを重ねるだけで、ミラー、Google Calendar、クリップボード履歴を素早く開ける macOS プロトタイプアプリです。

画面上部に小さな黒いハンドルを置き、そこへホバーすると暗いユーティリティパネルが表示されます。通常のメニューバーアプリよりも、必要なものをポケットからパッと取り出す体験を重視しています。

## 現在できること

現在は組み込みの `Mirror`、`Calendar`、`Clipboard` プロバイダーを搭載しています。

### ミラー

- ノッチハンドルへホバーすると、MacBook のカメラを使った鏡表示を開けます。
- カメラ映像は左右反転し、実際の鏡のように表示します。
- カメラはミラーパネルが有効な間だけ起動し、閉じると停止します。
- 初回利用時は macOS のカメラ権限ダイアログが表示されます。
- 設定から、ミラー下部にコンパクトなマイクチェック UI を表示できます。
- マイクチェック UI 表示中は、音声レベルメーターが自動で動きます。
- 一時録音、停止、再生ができます。録音データはメモリ上だけで扱い、音声ファイルとして保存しません。

### Google Calendar

- Google アカウントで接続し、カレンダー予定を表示できます。
- 日付へホバーすると、その日の予定をプレビューできます。
- 日付をクリックすると、その日の予定詳細を固定表示できます。
- 書き込み可能なカレンダーでは、予定の追加、編集、削除ができます。
- 編集では、タイトル、開始/終了時刻、終日、場所、メモを変更できます。

### クリップボード

- テキストのコピー履歴を左側に表示します。
- 画像のコピー履歴を右側に表示します。
- 履歴項目をクリックすると、再びクリップボードへコピーできます。
- テキストや画像を他のアプリへドラッグできます。
- 画像履歴はローカルの Application Support 配下に保存します。

### パネル設定

- 表示するプロバイダーを設定画面で切り替えられます。
- 最後に開いたパネルを次回も優先表示するか選べます。
- プロバイダーアイコンの切り替え方式を、クリック式またはホバー式から選べます。
- パネル上部のプロバイダーアイコンを Control クリックすると、表示順を移動できます。
- パネル表示領域を小、中、大の 3 段階で切り替えられます。
- ミラー下部のマイクチェック UI を表示するか選べます。

## 動かし方

```bash
./script/build_and_run.sh
```

ビルド、起動、プロセス存在確認まで行う場合は次のコマンドを使います。

```bash
./script/build_and_run.sh --verify
```

成功すると `HoverPocket launched` と表示されます。

## Google Calendar の設定

Calendar プロバイダーは、Google の iOS OAuth client、custom URL scheme、PKCE、ASWebAuthenticationSession を使うネイティブ認証フローを優先します。iOS OAuth client が未設定の場合だけ、既存の Desktop OAuth + loopback redirect + PKCE にフォールバックします。Google token は Keychain に保存し、OAuth client secret や token 類はソース管理に含めません。配布版のユーザーは、Calendar パネルまたは Settings から Google のログイン画面を開き、Google アカウントで許可すれば使えます。

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

`script/build_and_run.sh` は `.env.local` の iOS OAuth client ID / URL scheme を、生成される app bundle の `Info.plist` に注入します。Desktop OAuth フォールバックは `GOOGLE_OAUTH_ENABLE_LEGACY_FALLBACK=1` のときだけ注入します。iOS OAuth client ID と Desktop OAuth client ID のどちらも未設定でもアプリ自体は起動し、Calendar パネルには設定不足の状態が表示されます。Desktop OAuth の client secret はユーザーのGoogleパスワードやrefresh tokenではありませんが、Gitや公開ドキュメントには含めないでください。

通常は OS 既定ブラウザで Google ログインを開きます。開発検証で特定の Chrome profile を使う場合だけ、次の値を `.env.local` に追加します。配布版には入れないでください。

```bash
GOOGLE_OAUTH_ENABLE_CHROME_OVERRIDE=1
GOOGLE_OAUTH_CHROME_PROFILE="Default"
```

## ZIP アプリの作成

ローカル配布用の ZIP は次のコマンドで作成できます。

```bash
./script/package_zip.sh
```

成果物は `dist/releases/` に出力されます。Developer ID Application 証明書が見つかる場合は hardened runtime 付きで署名し、Sparkle 用の `appcast.xml` も生成します。一般配布では、この ZIP をさらに Apple notarization に通してください。

## 自動アップデート

自動アップデートは Sparkle 2 を使います。アプリ内の Settings から `Check for Updates` を押すと、次の appcast を見に行きます。

```text
https://github.com/shotaro311/hover-pocket/releases/latest/download/appcast.xml
```

Sparkle の公開鍵は `SUPublicEDKey` として `Info.plist` に入ります。秘密鍵は macOS Keychain の `hover-pocket` アカウントに保存され、Git には含めません。

GitHub Releases へ ZIP、SHA256、appcast をアップロードする場合は次のコマンドを使います。

```bash
./script/publish_github_release.sh
```

実際に公開せず、作成されるタグと成果物だけ確認する場合は次のように実行します。

```bash
PUBLISH_DRY_RUN=1 ./script/publish_github_release.sh
```

## 表示先ディスプレイ

表示先は設定画面から選べます。

- `Auto`: ポインターがあるディスプレイを使い、パネルが開いている間はそのディスプレイに固定します。
- `Main`: macOS のメインディスプレイを常に使います。
- `Sub`: サブディスプレイがあれば使い、なければメインディスプレイへ戻します。

実ノッチが検出できる画面では、ノッチに接続したレイアウトを使います。ノッチがない画面では、画面上部中央の小さなハンドルとして表示します。

## 実装メモ

SwiftUI の `MenuBarExtra` はクリック操作が中心で、標準の右上メニューバー領域に寄っています。このプロトタイプでは、AppKit の `NSPanel` と SwiftUI の hover handler を組み合わせ、画面上部中央のノッチ周辺にトリガーを置いています。

現在の構成は、hover shell と provider-hosted content に分かれています。新しい機能は `PocketProvider` として追加し、`ProviderRegistry` に登録して `PluginHostView` から表示する方針です。

```text
Sources/HoverPocket/
  App/         アプリ delegate と起動処理
  Windowing/   NSPanel 作成、ノッチ位置計算、hover close、animation timing
  State/       パネル表示状態、provider 選択、loading state
  Models/      plugin ID、manifest、permission、snapshot、preview content
  Providers/   PocketProvider protocol と ProviderRegistry
  Views/       pill、panel shell、plugin host、共通 UI
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

厳密な 1px 補正は `safeAreaInsets.top + 0.5pt` ですが、このプロトタイプでは `33pt` が見た目として自然でした。つまり、現在は `safeAreaInsets.top + 1pt`、2x Retina では物理 +2px の補正を使っています。

この値は見た目合わせの補正であり、すべての Mac で使える普遍的なノッチルールではありません。将来的に複数モデルへ対応する場合は、`NSScreen.safeAreaInsets.top`、`backingScaleFactor`、`auxiliaryTopLeftArea`、`auxiliaryTopRightArea` から計算する方針です。

現在の実機では、`auxiliaryTopLeftArea` と `auxiliaryTopRightArea` から次のノッチ幅を取得しています。

```text
notch x = 663pt ... 848pt
notch width = 185pt
left handle width = 54pt
pill frame = x: 609pt, width: 239pt
```

これにより、左側のハンドル右端がノッチ左端に揃い、黒いベースがノッチ裏まで続く見た目になります。

## License

MIT License です。詳細は [LICENSE](LICENSE) を確認してください。

このライセンスはソースコードに対する利用許諾です。`ホバーポケット` / `HoverPocket` の名称、ロゴ、ブランド表示の商標的な利用許諾とは別です。

## 注意

- 現時点ではローカルプロトタイプです。開発用のコード署名は起動スクリプトで行いますが、notarization、自動起動、配布用 installer は未整備です。
- `.env.local`、OAuth 設定値、token 類は Git に含めないでください。
- Clipboard 履歴は機密テキストも拾える可能性があります。今後、除外ルールや private mode を追加する余地があります。
