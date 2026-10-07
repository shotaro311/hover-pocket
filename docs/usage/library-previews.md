# ライブラリへの画像の自動保存とプレビュー

設定の「ライブラリ」から「コピーした画像をライブラリへ自動保存」を切り替えます。初期状態はオフです。オンにした後の画像を、元のクリップボード履歴とは独立して保存します。同じ保存内容の画像と、ライブラリのゴミ箱にある同じ画像は追加しません。オフにしても保存済みの素材は残ります。

Windowsではプライベートモード中の自動保存を停止します。クリップボード機能を非表示にしている場合、画像の自動保存のためにテキストの履歴保存を再開することはありません。

一覧のサムネイルと、ダブルクリックまたはSpaceで開くプレビューを拡張しました。

| 種類 | 主な形式 | 表示 |
|---|---|---|
| 画像 | JPEG、PNG、GIF、BMP、TIFF、WebP、HEIC/HEIF、AVIF、SVG、ICO | 縦横比を保った画像。アニメーション画像は先頭の画像 |
| PDF | PDF | ページ表示とページ切替 |
| テキスト | TXT、Markdown、CSV、JSON、XML、YAML、HTML、各種ソースコード、字幕 | 一覧に本文の抜粋、プレビューに選択・スクロールできる本文 |
| 文書 | DOCX、XLSX、PPTX、RTF、ODT/ODS/ODP、EPUB | 本文、表の値、スライドの文字。元の組版・図表を再現する表示ではありません |
| 動画 | MP4、MOV、WebM、AVI、MKV、WMV、MPEG、MTS/M2TS/TS、3GP、OGV | サムネイル、手動再生、シーク |
| 音声 | MP3、M4A/M4B、AAC、WAV、AIFF、FLAC、Ogg、Opus、WMA、CAF | 手動再生とシーク |

UTF-8、UTF-16、一般的な日本語のShift-JISを扱います。HTMLやソースコードは文字として表示し、実行しません。大きな文書は先頭を表示して案内します。

古いDOC/XLS/PPT、Appleの文書、カメラRAWなどはOSの対応状況によって表示範囲が異なります。Macでは利用できる場合に文書のサムネイルも表示します。対応しない形式、保護・破損したファイルは理由を表示し、「外部アプリで開く」から作業コピーを渡せます。

標準の再生機能で開けない音声・動画には、原本を変更せず、再生用のコピーを用意します。自動再生はしません。互換処理は入力2 GiB、処理120秒、生成ファイル512 MiB、生成キャッシュ2 GiBを上限とし、動画の最大解像度は1920×1080です。処理できない場合も原本は保持します。認識する拡張子は `shared/asset-library/preview-formats.json` を両OSで共有します。TSは動画の形式として扱います。

ポケット内のライブラリもマウスを外すと収納します。保存ダイアログ、画像の編集、ドラッグなどの操作中は必要な間だけ保持し、終わると通常のホバー操作へ戻ります。

## 開発時の検証

`script/create_library_media_fixtures.py --output <folder>` はPillowとフル版FFmpegで43件の検証ファイルを生成します。Macでは `sips -s format heic fixture.png --out fixture.heic` でHEICも追加できます。ライブラリの保存形式・バックアップ・同期の契約は変更しません。

Windowsは `HOVERPOCKET_LIBRARY_MEDIA_FIXTURES=<folder>` と `HOVERPOCKET_LIBRARY_MEDIA_VERIFY_ONLY=1` を指定して `HoverPocket.Shell.exe --verify ui` を実行します。Macは同じfixtures環境変数を指定し、隔離した `--asset-evidence` とソースを指定して `--verify-asset-library`、`--verify-asset-ui` を実行します。原本のhash、本文とサムネイル、設定のオン・オフ、重複、実ブラウザの読み込み・シーク、ホバー収納を検査します。

互換処理のFFmpegはビルド時に固定したSHA256で取得し、アプリへ同梱します。Macはネットワーク処理を無効にしてソースからビルドします。両OSのプレビューもネットワーク経由の入力とプレイリストを許可しません。ライセンス、対応するソース、ビルド手順は同梱のMediaTools内へ保持します。[FFmpegの配布・ライセンス説明](https://ffmpeg.org/legal.html)。
