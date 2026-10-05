# 2026-10-05 Windowsの素材ドラッグとカメラ・録音

## 範囲

- Mac親タスクでユーザーが承認したライブラリ拡張のWindowsネイティブ実装。親は共有UI・共通仕様、Windows音声担当は通常チャットと既存音声基盤を担当。
- `codex/windows-library-extensions-20261005`、元はリファクタリング済み `3e7ba7c`。元のmain checkout、Downloadsの音声作業、公開版と自動起動設定を保持。
- 共有UIは `04c3d06` と `0d45739` の対象ファイルを取り込んだ。同期機能の実装と公開配信は対象外。

## 実装

- フォルダ間移動・お気に入り・未分類・ごみ箱・復元を単一トランザクションで処理。Undoはセッション内の一度限りで、後続の分類変更と衝突する場合は上書きしない。名前・タグ・他フォルダ所属・原本を保持する。
- 内部ドラッグは原本コピー0件。外部がファイル本体を要求した時点で独立した作業コピーを作る。サイドバーのスクロールに合わせて受け入れ範囲を更新する。
- 上端へ外部ドラッグすると暗色の保存先パネルを開く。通常パネルが上へ重なることを抑止。ファイル、画像、複数の仮想ファイル、直接メディアURLを受け取り、元データを保持する。OLE Dropから戻る前にデータを確保する。
- MediaCaptureのカメラ写真・動画・M4A録音、デバイス/フォルダ選択、明示開始、経過時間/停止バッジ、切断・容量不足・保存待ち回復を追加。
- `audioUrl` で音声を再生。動画と同じ選択期限・Range・終了時のファイル解放を使い、`videoUrl` は動画専用とする。

## 検証

- Release/Debugビルド: ともに警告0・エラー0。音声基盤統合後の保存コア: 120項目PASS。
- `artifacts/library-extensions-20261005/native-10/verify.log`: exit 0。内部ドラッグ時コピー0、外部コピー編集後の原本一致、実OLEファイル/複数仮想ファイルの内容と保存先、上端から自動表示・取り込み、直接PNG URL/HTML拒否、AACの保存待ち復旧・無音再生・シーク・範囲取得・期限失効・ファイル解放を確認。
- デバイスUIと欠落時回復PASS。この端末ではカメラ0台、マイク9台。カメラの実撮影、マイクの実収録、混在DPIでのドラッグは未検証。
- 初期検証では検査用パネルの重なり、原本の読み取り専用属性に対する書き込みopen、旧選択メニューの有無を前提とする待機を修正。失敗ログを `native-1`〜`native-8`、`assets-1`〜`assets-3`、`interactions-1` へ保持。

## 最終統合と検証

- 音声担当の `de82c57` / `75cd8f7` / `c5a19c8` を取り込み、ライブラリ拡張と通常チャットを一つのShellへ統合した。CaptureControllerはカメラ収録中のBusy判定と既存音声capture処理を共存させた。
- Macの共有DOM修正 `9187e0a` を `e2f399a` として取り込んだ。実DOMドロップ時の宛先を確定し、ホバーだけでは移動しない。nativeの宛先結果があれば優先する。
- 実OLEドラッグで保存先パネルが表示直後にヒットしない問題を避けるため、専用パネルのHWNDを不透明にした。検査は非同期の保存先読み込みと展開を待ってから、表示済みの行へポインターを移す。
- カメラ・録音画面を実描画して確認。未接続時の余白と白い無効選択欄を修正し、選択欄・スクロールバーも暗色へ揃えた。
- `integration-assets-final2`: exit 0。従来の画像・PDF・動画・編集・Delete/Undoに加え、整理画面の実ドラッグでフォルダ間移動/Undo、ごみ箱からフォルダへの復元、元の所属と原本保持を確認。
- `integration-extensions-final3`: exit 0。OLEファイル・複数仮想ファイル・上端から自動表示した保存先への取り込み、URL、AAC再生・シーク・ソース解放、デバイス欠落時の回復を確認。
- `integration-capture`: exit 0。生成fixtureでスクショのウィンドウ選択・装飾・保存・取消、トーストからファイルドラッグ、WGC動画開始/停止/リサイズ停止と保存待ち回復を確認。`HOVERPOCKET_CAPTURE_VERIFY_NO_AUDIO=1` として、実マイク/システム音声の取得は明示SKIP。
- `integration/voice.log` / `integration-chat` / `integration-chat-panel-final` / `integration-library-voice-3`: exit 0。19個の音声共通操作、チャットの入力/送信/停止/履歴/遅延応答隔離、実ヘッダーからチャット画面への接続、生成ウィンドウのスクショ/録画保存とreadbackを確認。
- チャットの実Codex接続による検証は音声担当の `progress/evidence/2026-10-05-windows-chat/` を参照。音声入力のみの接続は現ChatGPT認証で利用できず、理由付き無効。従量課金APIへ切り替えていない。
- 最終ログ: [検証証跡](../evidence/2026-10-05-windows-library-extensions/)。失敗時ログはartifactsに保持。直近の検査側修正は、更新完了前の旧カードへのdouble-click、表示前の保存先行への移動、検査用ウィンドウのforeground待機。

## 残る受入と運用状態

- カメラ実撮影/実動画、実マイク録音、物理デバイス切断、混在DPIの移動は未検証。外部ドロップは上端の既存入口へ到達すると表示し、最近の保存先はセッション内で保持する。全OSドラッグの常時監視や保存先ピン留めは未実装。
- 統合版は隔離fixture内で実際に各画面を起動して検証し、終了後に専用ウィンドウを閉じた。Timerのみの既存隔離モードを全機能常駐版として扱わず、新しい開発プロファイルは追加していない。
- 元の常駐本番 `HoverPocketWin/current/HoverPocket.Shell.exe`（PID 72424）を維持。main統合、公開配信、本番置換、自動起動変更、同期機能の実装は実施していない。
- Mac親タスクの既存承認範囲として実装・検証・commit/push・draft PR作成を行い、追加確認は求めていない。

## Gitと引き継ぎのreadback

- 実装コミット `a5fedee80f22a06300352bf57d052238b84bcda8` をpushし、`git ls-remote` とローカルHEADの一致を確認。作業ツリーはclean。
- [draft PR #47](https://github.com/shotaro311/hover-pocket/pull/47) を作成・このタスクへattach。GitHubの `headRefOid` 一致、`isDraft=true`、`state=OPEN`、base `codex/windows-refactor-20261005` をreadback。
- Mac親へSHA、PR、検証証跡、残る物理受入、本番維持を送信済み。最終プロセス確認はPID 72424のみ、既存 `HoverPocketWin/current` の実行ファイルでResponding=true。
- このreadback追記は文書のみであり、上記検証済み実装を変更しない。
