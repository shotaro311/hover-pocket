# ノッチポッケ (NotchPokke)

ノッチポッケは、MacBook のノッチ付近にマウスを重ねるだけで、ミラー、Google Calendar、クリップボード履歴を素早く開ける macOS プロトタイプアプリです。

画面上部に小さな黒いハンドルを置き、そこへホバーすると暗いユーティリティパネルが表示されます。通常のメニューバーアプリよりも、ノッチ周辺からパッと取り出す体験を重視しています。

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
- パネル上部のプロバイダーアイコンを Control クリックすると、表示順を移動できます。
- ミラー下部のマイクチェック UI を表示するか選べます。

## 動かし方

```bash
./script/build_and_run.sh
```

ビルド、起動、プロセス存在確認まで行う場合は次のコマンドを使います。

```bash
./script/build_and_run.sh --verify
```

成功すると `NotchPokke launched` と表示されます。

## Google Calendar の設定

Calendar プロバイダーは、Google のインストール型アプリ向け OAuth フロー、loopback redirect、PKCE を使っています。Google token や client secret はソース管理に保存しません。

まず `.env.example` を参考に、ローカル用の `.env.local` を作成します。

```bash
GOOGLE_CLIENT_ID="YOUR_DESKTOP_OAUTH_CLIENT_ID.apps.googleusercontent.com"
GOOGLE_CLIENT_SECRET="YOUR_DESKTOP_OAUTH_CLIENT_SECRET"
GOOGLE_OAUTH_CHROME_PROFILE="Default"
```

有効な `gcloud` project で OAuth client を作る場合は、補助スクリプトを使えます。

```bash
./script/open_google_oauth_console.sh
```

Google Auth Platform で application type を `Desktop app` にして client を作成し、発行された client ID / client secret を `.env.local` に入れてください。

設定後は次の順で確認します。

```bash
./script/check_google_calendar_setup.sh
./script/build_and_run.sh --verify
./script/verify_google_calendar.sh
```

`script/build_and_run.sh` は `.env.local` の OAuth 値を、生成される app bundle の `Info.plist` に注入します。`GOOGLE_CLIENT_ID` が未設定でもアプリ自体は起動し、Calendar パネルには設定不足の状態が表示されます。

## 表示先ディスプレイ

表示先は設定画面から選べます。

- `Auto`: ポインターがあるディスプレイを使い、パネルが開いている間はそのディスプレイに固定します。
- `Main`: macOS のメインディスプレイを常に使います。
- `Sub`: サブディスプレイがあれば使い、なければメインディスプレイへ戻します。

実ノッチが検出できる画面では、ノッチに接続したレイアウトを使います。ノッチがない画面では、画面上部中央の小さなハンドルとして表示します。

## 実装メモ

SwiftUI の `MenuBarExtra` はクリック操作が中心で、標準の右上メニューバー領域に寄っています。このプロトタイプでは、AppKit の `NSPanel` と SwiftUI の hover handler を組み合わせ、画面上部中央のノッチ周辺にトリガーを置いています。

現在の構成は、ノッチ shell と provider-hosted content に分かれています。新しい機能は `NotchProvider` として追加し、`ProviderRegistry` に登録して `PluginHostView` から表示する方針です。

```text
Sources/HoverMenuPreview/
  App/         アプリ delegate と起動処理
  Windowing/   NSPanel 作成、ノッチ位置計算、hover close、animation timing
  State/       パネル表示状態、provider 選択、loading state
  Models/      plugin ID、manifest、permission、snapshot、preview content
  Providers/   NotchProvider protocol と ProviderRegistry
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

## 注意

- 現時点ではローカルプロトタイプです。署名、notarization、自動起動、配布用 installer は未整備です。
- `.env.local`、OAuth client secret、token 類は Git に含めないでください。
- Clipboard 履歴は機密テキストも拾える可能性があります。今後、除外ルールや private mode を追加する余地があります。
