# 2026-10-05 ライブラリ操作・撮影・チャットの拡張

## 採用した方針

ユーザーが提案を承認。内部drag移動、外部drag取り込み、通常chat、App Server dictationの小検証、Libraryを入口としたcamera photo/video/audio収録を実装する。Macは共有assets UIとSwift、Windows担当はnative保存/drag/captureとchatの専用worktreeを担当する。公開・main統合は含めない。

## 共通UIの最初の引き渡し

- フォルダ/ゴミ箱/お気に入り/未分類のdrop targets、移動中のsidebar表示・強調・スクロール追従、source folderを限定する移動、undoTokenを追加。
- カメラ写真・動画・録音メニューを追加。native device選択/実収録はこの時点では実装中。
- [bridge契約](../../shared/asset-library/interactions.md)を両OSの基準にする。DB schemaは変更なし。
- Mac保存49項目、共有UIを含む既存UI59項目、既存AI52項目・100回開閉等が通過。追加したfolder/trash→folder/capture menuの検査は引き渡し直前の実WKWebView検査で確認する。
- native外部dragの追加・Macカメラ・通常chatは進行中。実機の外部アプリからのドラッグ、物理camera/mic録音は未受入。

## Windows担当

- Library: thread 01a0ff46-72f0-7582-afea-1f910bf1abb6、branch codex/windows-library-extensions-20261005。
- Chat: thread 01a10712-359c-7560-89da-e89d14751fdc、branch codex/windows-chat-dictation-20261005。
- Windows CLI 0.160.0のChatGPTログインで、Realtime text v3はv2必須、v2はAPI key auth必須として拒否されたとの実検証報告。課金APIへ切り替えず、音声入力は制限表示、通常chatを進める。Macでの同等検証は未実施。

## 共有UIの音声プレビューとWindows AI入口

- 音声ファイルの手動再生と終了時のsource解放、Windows `showAsset(id)` と `window.hpLibrary` を共通UIへ追加。
- Mac保存54、UI65（新規drag・音声preview・Windows入口を含む）、再開2項目が通過。通常chatの状態・履歴9項目も通過。根拠は `/private/tmp/hp-666-chat-final.log` と `/private/var/folders/mv/0d7m444d25d_q88sj2wfntj80000gn/T/HoverPocket-Assets-SO5sjn/`。
- 一度UI検査だけを空のevidence先で実行しnative fixture不足で失敗した。保存検査でfixtureを作成した後の再検査は通過。初期追加時のSwiftコンパイルエラーを修正し、成功したビルドで上記を確認。

## Mac実装と最終回帰

- 開発版666へSwiftのフォルダ移動/Undo、外部ドロップパネルとfile promise・画像・直接メディアURLの受け取り、カメラ写真/動画/M4A録音、Mirror入口、通常Codex chatを接続。外部コピーは必要時のみ作り、インターネット由来とハッシュを保持する。内部移動の準備は原本全体を読み直さない。
- 録音中の画面を閉じても上端に経過時間/停止を表示し、保存失敗は作業ファイルを保持する。chatは同じBrokerを通し、手入力の操作元をtextとして記録する。停止後も元の会話を再開でき、古い応答や別スレッドの結果を混ぜない。
- 最終一式: 保存54、UI68、再開2、chat9、既存音声/Broker/128レイアウト/100回開閉PASS。根拠 `/private/tmp/hp-666-releasecheck-verify.log` と `HoverPocket-Assets-Fq8gie`。その後のtext origin追加はLibrary53とchat9・音声foundation42を再検証 (`/private/tmp/hp-666-origin-*.log`)。
- Windows実機の指摘でDOM dropの宛先を実drop時のみ記録するよう修正。`9187e0a`。hoverだけでは移動しない検査を追加。最初の合成DataTransfer検査はWebKitで書き込み不可となるため、要求したdropEffectを観測するfixtureへ修正。失敗ログも保持した。
- 共通JSON Schemaと代表fixtureは既存uvキャッシュのjsonschemaで正常5/拒否3を検証。DB版1・原本形式の変更はなくmigration不要。
- Macの実ドラッグはComputer Useのdown→drag→upが0.2ms以内に到着し、非同期のnative drag開始前にmouseupとなった。通常の人のドラッグとしては未受入であり、fixture通過を実ドラッグ成功とは扱わない。外部Finder/ブラウザ間の実操作、物理camera/mic・切断・長時間収録も未受入。

## Windows統合の読み戻し

- Windows担当は音声基盤、通常chat、nativeライブラリ拡張と共有UIを統合。実装 `a5fedee`、記録後の最終 `6db2a23db40e897e383efbacd1db630f5c436655`。[Draft PR #47](https://github.com/shotaro311/hover-pocket/pull/47)。Mac側からfetchとGitHub headRefOid一致、日別ログを読み戻した。
- Release/Debug warnings0/errors0、保存120、実folder移動/Undo/trash復元、OLEファイル/複数仮想ファイル/上端パネル、音声preview、無音fixture撮影/収録、19tools、通常chatが通過。実ChatGPTでの手入力・隔離folder作成・保存readback・応答stream・履歴再開もWindows担当が確認。
- カメラ0台のため物理撮影、実マイク・デバイス切断・混在DPIは未検証。外部パネルは上端の入口へdragして表示。保存先ピン留めは今回未実装。通常版PID72424を維持し、検証用画面は終了。公開・main統合は実施していない。
