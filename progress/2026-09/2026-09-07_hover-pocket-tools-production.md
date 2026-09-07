# 個人用ツールを実パネルに適合させる

- 日付: 2026-09-07
- 対象: macOS、`codex/pocket-tools-platform`
- 依頼: 生成ツールをHoverPocketの本番機能として動く状態まで実装する。
- 範囲: ローカル実装、署名済みアプリ、実パネルでの受入検証。外部公開、既存インストールの置換、Windows実装は別。

## 修正

- HTMLを包む固定高さと二重スクロールを取り除き、実パネルの空き領域を使う。共通の暗い背景、配色、コンパクトな操作部品、文字サイズ設定を適用する。
- 標準の記録画面は一覧を最初に見せ、追加・編集時だけ入力欄を表示する。保存とキャンセルはスクロール外に固定する。
- 生成ガイドに最小パネルの利用可能領域、一覧優先、入力欄の出し入れ、文字拡大、キーボード操作を明記。設定のプレビューも現在のパネル寸法と文字サイズへ揃える。
- 実パネルを開く検証用入口は本物のHoverWindowController、HoverPanelShell、生成器、導入管理、Host操作、データ保存を使い、保存先と設定だけを一時領域へ分ける。
- 実生成したタイマーと付箋のツールで、ガイドでは省略可能だったsourceRefをBrokerが必須とする不一致を発見。v2の省略値をHostで補完し、導入前にも同じ実行仕様で固定値と入力型を検証する。ガイドの付箋色も実装と一致させた。

## 確認できた内容

- Astra Mediumで水やりツールと会話更新、タイマー+付箋ツールを実生成。成果物は`progress/evidence/2026-09-07-pocket-tools-production/`に保存。
- 実パネルの水やりデータは別経路で読み直し、植物名・場所・日付と1件の記録を確認。
- 生成した操作ツールを本物の導入・実行処理へ通し、確認とキャンセルでは変更なし、承認後にタイマー開始と付箋保存が成功。新しいStoreで付箋を読み直して一致。
- Debugの個人用ツール65項目、共有v1契約72、v2契約46、Voice Foundation静的42項目がPASS。静的コマンドの初回はファイル名の誤りで未実行だったため、正しい`script/verify_voice_foundation.py`で実行し直してPASS。
- Developer ID署名・Hardened Runtime付きのRelease build633で、個人用ツール65項目、既存package/lifecycle/backup、隔離WebKit16項目、実生成UI9項目と保存項目の移行、実生成Host操作、Broker、Personal Tools、Voice Foundation、Panel Layoutの検証がPASS。
- 同じ署名済みアプリで、生成HTMLツールを含むパネル開閉100回、機能切り替え100回、復旧5回、アニメーション3回がPASS。ウィンドウ3→3、socket1→1、RSS114.9→126.7MiBで既存の上限内。
- strict codesignとGoogle/現在地の配布設定検証がPASS。binary SHA-256: `fd4113d461fa9a7aace00b56ddd5201185804eb30cceda0a53549761e3e39302`。証拠: `packaged-verification.json`、各検証ログ、`source-file-digests.json`。
- 実際の本体設定にある「パネルで開く」から生成ツールを表示。最小パネルと最大文字サイズの組み合わせでも一覧・編集・保存へ到達し、大きいパネルへ切り替えても表示が追従した。
- 実パネルの確認ダイアログでキャンセルするとTimer/Sticky保存ファイルなし。承認すると15分タイマー1件と付箋1件が保存され、Hostに「2件確認済み」を表示。保存先を別経路で読み直して一致。
- 水やりツールの再起動後の記録表示、場所の編集・保存、履歴からの復元と新しい版としての導入を確認。植物名・日付・同じrecord IDを保持。旧画面に戻すときは「置き場所」を現在の項目から除く説明を表示し、その値「リビングの窓辺」が移行前バックアップに残ることを独立確認した。
- 最終build633の本体設定からAstra Mediumで標準collectionの「読書メモ」を実生成・導入した。最小パネル・最大文字サイズで、入力・数値エラー後の入力保持・訂正保存・検索・削除確認のキャンセル・再起動後の復元を確認。保存ファイルを読み直し、タイトル、数値42、真偽値trueを確認した。
- 実パネルのPNGは`actual-panel-small.png`、`actual-panel-small-large-text.png`、`actual-panel-editor-large-text.png`、`actual-panel-actions-complete.png`、`actual-panel-standard-collection.png`。本体のヘッダーを含む実パネルの撮影であり、単体HTML検証窓ではない。
- 最終readback: `native-panel-final-readback.json`、`standard-collection-readback.json`、`native-standard-restart.txt`。検証用アプリだけを終了し、既存インストール版は継続。

## 完了範囲

- macOSの実装と署名済みローカルアプリでの受入検証は完了。依頼に含まれる実装・一時データによる検証・記録更新は、追加確認なしで実施した。
- 公証、GitHubへの書き込み、公開フィード更新、インストール済みアプリの置換、Windows対応は未実施。
- 任意に生成される全ツールの動作を保証するものではない。導入前の契約検証と、生成後のプレビューを使って内容を確認する。今回の実生成3用途（水やり、作業開始、読書メモ）では上記の受入操作を確認した。

## 前回報告の訂正

build632の幅320・高さ720のスクリーンショットは単体HTMLの動作証拠であり、HoverPocket全体でのUI受入証拠ではなかった。基盤の動作確認と実パネルへの適合を分けて記録する。
