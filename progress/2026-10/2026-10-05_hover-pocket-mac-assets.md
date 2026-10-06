# 2026-10-05 Mac素材ライブラリ・撮影・収録のローカル実装

Windows 0.2.10の素材ライブラリ、注釈編集、撮影・収録をMac開発ビルド662へ実装した。保存・実WKWebView・上端パネル・短い実収録を確認した。外部への実ドロップ、撮影画面の全操作、複数画面、長時間収録等の受入は残るため、全面的な実機受入完了とはしない。

## 作業先と保護した既存変更

- 作業先: `/Users/shotaro/.codex/worktrees/mac-asset-library/hover-menu-preview`
- ローカルブランチ: `codex/macos-asset-library-0210`。変更は未コミット。
- 基点: `a02eb9f8f9347a8500b80b994e3af4addd6ca79d`、Windows機能基準: `eba3774e2ffb872080d12dbcc3d284ca65743f69`。
- 元checkout: `/Users/shotaro/code/share/hover-menu-preview`、開始時HEAD `0080be3`。既存の液体アニメーション等のMac差分21ファイルを作業先へ引き継いだ。全差分のうち、その引継ぎ分を今回の新規素材実装と混同しない。
- 元の未コミット・未追跡ファイル2,099件を `work/mac-asset-library-20261005-baseline/` へバックアップ。アーカイブSHA-256: `a73ec31f8ad39b616067d97f8d5f59feffbbc711667daba13d67f1750bb1cccc`。
- 最終的に元ファイル2,099件を再ハッシュし、変更0・欠落0。元checkoutのreset、既存作業の解消、原本削除はしていない。
- 本番版644と既存開発版661を上書きせず、今回の実機検査は一時ライブラリと検証用設定で行った。開発Bundle IDは `local.codex.hover-pocket.asset-dev`、Keychain識別子の接尾辞は `asset-dev`。
- push、PR、公開、更新feed、自動起動先、同期処理は変更していない。ローカル実装・非破壊検証・作業ブランチ作成は依頼範囲内として確認なしで実施した。

## 実装内容

一覧の動作とデータ契約はWindowsの正本を使う。`windows/ui/providers/assets/` のJS/CSSと共有SQL/JSONをビルド時に同梱し、固定した入力ファイルからWKWebView用の単一JSを生成する。外部依存を追加せず、Windows側はMac向け修飾キー・OS名の表示分岐だけを追加した。

- `Sources/HoverPocket/Assets/AssetLibraryModels.swift`、`AssetLibraryDatabase.swift`、`AssetLibraryStore.swift`: SQLite単一writer、schema1、NFKC/full case fold、128KiB単位の原本コピーとSHA-256、取り込み処理記録、分類・検索v1/v2・Undo・ごみ箱・バックアップ・復旧・独立した取り出しコピー。
- `AssetMedia.swift`: 画像の制限付きデコード、PDFKit、動画ポスター、範囲読取りと無効化を持つ動画URL。原本パスをJSへ渡さない。
- `AssetPaneModel.swift`、`AssetLibraryRuntime.swift`、`AssetsProvider.swift`、`Resources/AssetUI/`: 共有UIを既存パネル・整理ウィンドウへ接続。全画面・表示切替・動画停止、入力中/編集中/ファイル選択中の保持、実ファイルのドラッグ先・送り出しを実装。
- `AssetAnnotationEditor.swift`: 同じパネルでペン・文字・矩形・楕円・矢印・移動・消しゴム、色・線幅・Undo/Redo、取消確認、失敗時保持と再試行、原寸の別画像保存。
- `AssetCaptureController.swift`、`AssetScreenRecorder.swift`、`AssetPendingCapture.swift`、`AssetScreenshotToast.swift`: 対象の強調と範囲選択、その場で注釈、保存通知、画面/窓のH.264収録、システム音とマイクのAAC合成、停止/終了時保存、失敗素材の保持・再登録、ショートカット設定。
- `AppDelegate`、`StatusBarMenuController`、`ProviderStore`、`HoverPanelShell`、`HoverWindowController`: 標準機能登録、トレイ操作、収録表示、上端ドロップ、一時的な素材選択と元の機能への復帰。音声を切らずに全画面時の表示だけを調整する。

復元は空ライブラリへの復元に限定する。DBスナップショット復元前に現DBを退避し、原本は保持する。破損DBも上書きせず退避する。ゴミ箱移動の完了が記録済みなら次回にDBの後処理を行い、完了未確定なら原本・記録を自動削除せず案内する。

## 検証結果

環境はこのMacのarm64 / macOS 27.0 (26A428)。最終コマンドは `./script/verify_mac_assets.sh`、exit 0。署名の検証と `git diff --check` も通過。Apple Development署名であり、今回のビルドは公開用の公証済み成果物ではない。

| 検査 | 結果 | 根拠 |
| --- | --- | --- |
| 保存・検索・復旧 | 39項目通過 | [core-result.json](../evidence/2026-10-05-mac-assets/core-result.json) |
| 素材UI | 58項目通過。内部に共通JS45項目を含む（別加算しない） | [ui-result.json](../evidence/2026-10-05-mac-assets/ui-result.json)、[JS結果](../evidence/2026-10-05-mac-assets/web-interactions.json) |
| 新規プロセスで再開 | 永続データと全原本SHAの2項目通過 | [reopen-result.json](../evidence/2026-10-05-mac-assets/reopen-result.json) |
| 上端パネル | 実画像表示、拡大・全画面・復帰を含む20回の切替 | [記録](../evidence/2026-10-05-mac-assets/panel-result.txt)、[表示画像](../evidence/2026-10-05-mac-assets/notch-expanded.png) |
| 既存レイアウト | 128ケース、4サイズ、設定保存・電卓レイアウトが通過 | [panel-layout.log](../evidence/2026-10-05-mac-assets/panel-layout.log) |
| 既存クリップボード・タイマー | それぞれ既存検証が通過 | [clipboard.log](../evidence/2026-10-05-mac-assets/clipboard.log)、[timer.log](../evidence/2026-10-05-mac-assets/timer.log) |
| 既存パネルの反復 | 100回、provider切替100回、復帰5回。window 3→3、RSS 101.750→104.469MiB、thread 15→8（最大16）、socket/child 0→0 | [panel-soak.log](../evidence/2026-10-05-mac-assets/panel-soak.log) |
| 撮影・収録 | 実ウィンドウのPNG、640×388の3.103秒動画を保存・デコード | [capture-result.json](../evidence/2026-10-05-mac-assets/capture-result.json)、[撮影画像](../evidence/2026-10-05-mac-assets/screen-capture.png)、[録画フレーム](../evidence/2026-10-05-mac-assets/recording-frame.png) |
| 音声付き実収録 | システム音のみ2.242秒、マイクのみ2.043秒、両方2.092秒。各MP4の音声track 1、システム音のsample取得を確認 | 同上のcapture-result.json |

UIでは編集保存・失敗後の再試行・取消・原本保持、動画の再生/シーク・同じプレーヤーの全画面復帰、閉鎖90ms後の再生元解放、PDFページ移動を検査した。別途、実マウスで動画のPlay/PauseとPDFページ切替を確認した。4K・長時間・主観的な音声品質の受入をこれらの小さいfixtureから推定しない。

自動マウスによる画像ドラッグは準備完了通知まで進んだが、ネイティブドロップ完了は得られなかった。非同期のコピー準備後もドラッグ元イベントを保持し、失敗・取消時は準備済みコピーを再利用し、ゴミ箱の座標をWebKitの上下方向へ合わせた。最終修正後のUI58項目と再開2項目は通過したが、外部ドロップ成功と通知からの実ドラッグは未受入。

## 別経路のreadback

Swift保存処理を使わないPython/SQLiteの読み取りで、library 6件・Mac復元先4件・Windows fixture 1件のschema、quick_check、外部キー、全原本サイズ/SHAを検証した。Windows fixtureの全素材・分類・正規化した検索条件と再出力の意味が一致する。元ファイル2,099件、同梱JS/CSS/SQL/JSONのSHA、Bundle ID/build、署名も照合した。検証アプリの終了もPID不在で確認した。[独立確認JSON](../evidence/2026-10-05-mac-assets/independent-readback.json)。

最終実行の一時根拠は `/var/folders/mv/0d7m444d25d_q88sj2wfntj80000gn/T/HoverPocket-Assets-IYD2tw`。長期参照用にはfixture画像・JSON・検査ログだけを `progress/evidence/2026-10-05-mac-assets/` へコピーした。実マイク収録ファイルはリポジトリへ含めていない。

## 途中の失敗と修正

- ローカルHTMLのURLへquery/hashを付けるとWebKitが例外終了したため、bare file URLとdocument-startの設定注入へ変更。
- file URLのES module読込みはCORSで止まったため、正本モジュールをビルド時に固定入力からまとめた。
- 注釈の描画方向、全画面が成立しない経路、Unicodeの長い取り出し名、保存先の上書き防止、隔離属性保持、破損DB復旧、ゴミ箱処理の再開を修正。
- 検証ウィンドウの終了後にComputer Useが返したtimeoutは、実行中の検査失敗には算入していない。最終のCLI検査は全てexit 0。

## 未検証と次の受入

1. Finder/編集アプリ等への素材・通知の実ドラッグ成功、上端への外部ファイル投入、撮影対象ホバー/範囲選択/Enter/ダブルクリック/通知停止の全手操作。
2. 複数ディスプレイ、混在倍率、権限拒否と取消、マイク切断・対象終了・実ディスク満杯・実強制終了。今回の保存系失敗fixtureを実環境の全受入としない。
3. 長時間の音声同期、4K動画、10,000件の性能、最低基準端末、連続フレームでのちらつき。
4. Windows実機で今回のMac出力を復元する往復、インストール/更新/ロールバック、公開署名・公証・各OS feedのreadback。

次は上記1の操作受入から進める。通常起動では開発版も標準の素材保存先を使うため、検証モードの一時ライブラリと区別する。元checkoutへの統合は今回行っていない。共通UIを変更した13行とMac追加部分、引き継いだ液体アニメーションの差分を分けてレビューする。

[対応表](../../docs/plan/20261005_MAC_ASSET_PARITY.md) / [使い方](../../docs/usage/macos-asset-library.md) / [Windows配信記録](2026-10-04_hover-pocket-windows-0210-release.md)
