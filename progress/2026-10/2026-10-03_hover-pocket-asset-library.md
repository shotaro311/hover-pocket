# 2026-10-03 Windows素材ライブラリの実装と受入状況

ユーザーの「では実装をお願いします」を受け、Windows開発版`0.2.9-local.7`へ実装。要件は[asset-library-v1.md](../../docs/requirement/asset-library-v1.md)。Windowsで動くローカル開発版の実装・検証であり、両OSの配布完了ではない。

作業先は`C:\Users\shotaro\Downloads\hover-pocket-windows-liquid-20261002`、ブランチは`codex/windows-liquid-mac661`、開始HEADは`f40cc2b1bcb32edd4ddfcbc55e7d5dccfbebb20e`。元の`C:\Users\shotaro\code\shared\hover-pocket`のdirty checkoutを保持。先行の表示応答改善のpush承認と、新機能の公開配布を区別し、この作業では公開Release/feed変更を行っていない。

## 実装

- 素材Providerと通常の整理ウィンドウ。トレイから整理画面を開ける。既存のProvider表示・並び順の契約に接続した。
- 任意形式のファイル、フォルダ階層と空フォルダ、画像/ファイルのクリップボード、履歴画像の明示保存。リンク・アプリパッケージ・システムファイルは除外理由を表示。大量取り込みの確認、取消、保存済み件数、重複とゴミ箱復元の案内を扱う。
- SQLiteとUUID原本、生成キャッシュを分離。保存先は`%LOCALAPPDATA%\HoverPocket\AssetLibrary`で、既存Roaming設定やクリップボード履歴の保存先を変更しない。アカウント・Eagle・APIキー・FFmpegを基本機能の利用条件にしない。
- ストリームコピーとSHA-256、サイズ/更新時刻の前後検査、空き容量、書き込みjournal、原本の確定、重複の分類統合。保存元には書き込まない。途中終了後に確定済み原本を再登録し、不完全な取り込みは再選択を案内する。
- NFKCとUnicode 15.1.0の共通case folding、名前/タグ/拡張子の単語AND検索、日本語1〜2文字、IME、日付/種別、分類グループ内OR・グループ間AND、検索条件保存。
- フォルダ/タグ階層、複数選択、一括分類と分類解除、お気に入り、名前変更、アプリ内ゴミ箱、復元、直前の成功した一括メタデータ変更のUndo。
- ポケット内で画像の拡大/パン、動画の手動再生・シーク・音量、PDFのページ移動。素材の寸法と現在モニターからパネルを拡大し、作業領域の幅90%・高さ85%で制限。全画面は現在モニター全体、Esc/F11で復帰。通常サイズ設定を保持し、プレビュー中は固定する。
- 原本確認後のキャッシュ利用、可視範囲の仮想一覧、単一デコードキューと選択優先。画像は縮小デコード/EXIF/透明度、PDFは選択したページのみ。PDF描画は同梱実行ファイルの読み取り専用子プロセスへ分離し、30秒の未使用後に終了、次の要求で再開する。JPEGの大きい画像は縮小、非JPEGの32MP超はメモリを守るためプレビュー制限。再生成できるプレビュー/PDFキャッシュは2GiB、一覧サムネイルは別の1件64KiB予算。
- Claudeの改訂要件の指摘から、別アプリへ移ったプレビューの最前面解除、health checkの背景化保持、プレビュー中のTimerによるProvider切替の抑止、大容量ドラッグの非同期準備と再ドラッグ案内を追加。外へ引渡済みのコピーは再利用しない。
- 動画は選択中の短命URLのみで原本を読み、Rangeを返す。任意パスのHTTP公開なし。整理画面とポケットで単一再生所有者を共有し、別画面のプレビュー開始時に前のプレーヤーを停止する。
- 外へ渡すドラッグ・ファイルコピー・OSで開く操作では独立した作業コピーを作る。由来のZone.Identifierを保持。原本とコピーを混同せず、外部コピーの整理もOSごみ箱を利用する。
- アプリごみ箱を空にする操作はネイティブIFileOperationでOSごみ箱へ移す。移動失敗は原本と登録を保持する。原本の恒久削除へ切り替えない。
- ハッシュ付き完全バックアップ、検証してからの復元、置換前のライブラリ退避、破損/新しいDB版の保護、日次DBスナップショット、明示的な未登録原本の回収。初期版v1は新規migrationのみで、実在しない旧版へのmigrationを実施済みとは扱わない。

共通契約は[shared/asset-library](../../shared/asset-library/README.md)。SQLite migration、manifest schema、Unicode表、同じ正本fixtureをWindowsで読み戻す検証を追加した。macOSの読込/出力と実機往復は未検証。

## 検証

全て私有設定を使わない隔離した検証プロセスと、生成した画像/PDF/動画のfixtureで実施。

| 検査 | 結果・限界 |
| --- | --- |
| Release solution / Shell project build | 警告0・エラー0。出力先指定はShell projectに限定 |
| Assets.Core | 51項目PASS。正規化、重複、分類/検索、保存元不変、コピー、ゴミ箱、manifestの版/参照/ハッシュ検査、破損DBの保護、復旧、取り込み確定各段階の途中終了、由来保持、外部変更検知 |
| ネイティブ素材UI | WebView2の実表示、PNG透明画像、縦横ページ混在/1000ページPDF、壊れた画像/保護PDFの原本保持、自動拡大・固定・全画面、リース失効403、Range206、実H.264/AAC再生・シーク・音量/全画面継続、整理画面への再生所有者移動、CF_HDROPと空フォルダ、OSごみ箱への移動/読み戻しがPASS |
| 既存UI回帰 | Controls/Timer/Clipboard/Calendar/Calculator/Pocket Surface/設定、4サイズ×2入口、19,440ヒット境界点がPASS |
| shell | 100回開閉、位置保持、離脱、輪郭閉鎖、health repair、窓再生成、段階復旧がPASS。最終計測18フレーム・最大20.5ms（実描画遅延全体ではない） |
| settings / display / ui-model / clipboard | 最終一括回帰は全プロセスexit 0 |

`artifacts/asset-worker-final-*.log`に最終の既存機能の一括回帰、`asset-pdf-worker-feature.log`にPDF分離後の素材UI検証を保存した。ui / shell / settings / display / ui-model / clipboardは全てexit 0、終了後のPDF子プロセス数0。これらのartifactはgit除外。native UI検査の画像は生成素材だけで、ユーザーの実ライブラリを出力していない。

さらに最終バイナリで`HOVERPOCKET_ASSET_VERIFY_IDLE=1`を指定し、31秒待機後に未生成のPDFページを描画した。子プロセスの未使用終了から再開、全ての素材UI検査、終了コード0と子プロセス残存0を確認。記録は`artifacts/asset-worker-idle-final.log`。これはPDFの待機CPUや全アプリのメモリの受入測定を意味しない。

終了異常について：PDFを描画した初期ReleaseのUI検査で、機能チェックPASS後にネイティブ例外`0x87A`/exit 2170が発生した。一時的に再試験が通過しても再発したため、先の3回通過を最終結果として扱わない。自身の隔離した検証プロセスで取得したネイティブスタックは、プロセス終了時の`Windows.Data.Pdf.dll`→`d3d11.dll`→`dxgi.dll`を示した。COM処理の完了順、WebViewの終了順、PDFの明示解放だけでは解消せず、PDF描画を子プロセスへ分離した。本体はWindows PDFをロードせず、従来のWPF終了を維持する。子プロセスは永続データへ書き込まず、完成した描画結果をパイプで返し、未使用または親のパイプ終了時にOSから終了させ、問題のPDF/DXGI終了処理を避ける。子側の未処理エラーは失敗として扱い、本体の異常終了コードを成功へ置き換えていない。分離後の素材UIと既存回帰はexit 0。Windows標準DLLの不具合の範囲や他OSビルドでの再現性は未確定。

## 限定した性能測定

実PCは64GiBメモリ、実接続1画面5120×2160/150%。1万/10万件の合成メタデータと分類を作り、20条件を各5回測定。P95はnearest-rankで5回の最大を採用し、表は条件間の最悪値。

| SQLite問い合わせの完了時間 | 変更前 | 修正後 |
| --- | ---: | ---: |
| 10万件・最悪P95 | 336.60ms | 103.79ms |
| 10万件・条件間平均P95 | 265.70ms | 58.30ms |
| 1万件・最悪P95 | 未記録 | 10.20ms |

タグ検索の行ごとの相関問い合わせを分類集合のIN検索へ変更し、最近順と分類の索引を追加した。結果は`artifacts/asset-query-performance*.json`。原本、サムネイル、bridge、IMEの150ms待機、初回ペイントを含まない。AL-P02やEagleと同等の速度を達成した証拠ではない。

## 残る受入と次の作業

- macOSのコード/実機検証は未実施。Mac側Codexへの送信許可の質問には回答未受領で、別端末へ依頼を送っていない。
- 8GiB基準機、実データを含む10万件、AL-P01〜08の全体、256MiB総デコードメモリの実測、48MPの各画像形式、待機CPUは未受入。
- 実OSのOLEドラッグで別アプリへ渡す手動操作、実クラウドの未取得ファイル/ネットワーク切断、実ディスク満杯、実複数画面の切替は未検証。ファイルドロップと容量条件の実装/隔離テストとは区別する。
- installer/updaterでの新規ユーザー・更新/巻き戻し/アンインストール後のライブラリ保持、正式な公開物の検査は未実施。公開Release・feed・Mac版を変更していない。
- Claudeの改訂要件レビューは同じWindows会話・Opus 5.5/highで再開し、「要件として着手可、重大0件・中程度5件」。指摘の採否と現在の受入は[レビュー記録](../../docs/report/20261002-asset-library-requirements-review.md)。コードをClaudeが検証/承認したとは扱わない。
- 1GiB以上の外部ドラッグと、故障でHWNDを作り直す場合のプレビュー状態の引継ぎは未受入。通常のhealth checkによる全画面/背景化の保持とは区別する。

## 再実行

```powershell
dotnet build windows/HoverPocket.Windows.sln -c Release -v:q
dotnet run --project windows/tests/Assets.Core/Assets.Core.csproj -c Release
dotnet run --project windows/tests/Assets.Performance/Assets.Performance.csproj -c Release
$env:HOVERPOCKET_ASSET_VERIFY_ONLY='1'
# HOVERPOCKET_ASSET_VIDEO_FIXTURE と HOVERPOCKET_ASSET_PROTECTED_PDF_FIXTURE を隔離した生成fixtureへ指定すると追加検証を含む。
./windows/src/HoverPocket.Shell/bin/Release/net10.0-windows10.0.22621.0/HoverPocket.Shell.exe --verify ui
```

通常起動用のビルドでは、既存アプリのOAuth/publisher metadataを子プロセス内のみで引き継ぎ、一致を値を出力せず検査した。資格情報・私有設定のバックアップ・生成artifactをgitに追加しない。

## 通常起動への反映

03:17 JSTに自身が起動した前の開発版だけを終了し、`artifacts/asset-local-7-accepted-worker/HoverPocket.Shell.exe`を通常起動した。DLLのProductVersionは`0.2.9-local.7`、起動後もプロセスの存続を確認。置換直前に通常ライブラリが未初期化であることを確認し、ユーザーの取り込み処理を中断していない。設定ファイルのSHA-256は前後一致、入口の自動非表示オンを保持。起動だけでライブラリDBを作らず、最初の素材操作で初期化する。読み戻しはgit除外の`artifacts/asset-normal-final-readback.json`。新機能のcommit/push、公開Release・feed変更、既存インストーラーの置換は実施していない。
