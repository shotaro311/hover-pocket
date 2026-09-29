# 個人用ツールのv2契約

macOSの標準collection画面と隔離HTML画面で同じHost保存APIを使う。v1のmanifest、保存state、workflow、declarative surface、生成envelopeを変更しない。v2はmanifestのapiVersionで明示し、Windowsの現在のv1 runtimeはv2を拒否する。Windowsへの機能実装・実機検証は未実施。

## 保存形式と正本

- `pocket-app.schema.json`: v2定義。最大16 collection、surfaceはdeclarative/collection/html。
- `pocket-collection.schema.json`: 項目名、型、必須、null許可、enum候補。最大32項目。文字列、有限数、真偽値、YYYY-MM-DD、enumを扱う。
- `pocket-collection-surface.schema.json`: 標準画面。参照collectionと文字列の見出し項目はruntimeが照合する。
- `pocket-collection-data.schema.json`: Hostが生成するUUIDとrecord.fields、schemaVersion、revision。最大1万件・8 MiB/collection。revisionを指定した更新だけを許し、競合は最新値を読み直して利用者が再操作する。
- `pocket-tool-checkpoint.schema.json`: 成功したプレビュー/導入/履歴復元の定義snapshot。日時はUTC RFC3339。ユーザーデータを含めない。
- `pocket-app-workspace-backup.schema.json`: v2の全体archive。v1のstateとv2のdata payloadを区別する。
- `pocket-tool-backup-data.schema.json`: stateとcollection snapshotをまとめるv2 payload。

レコードは定義と別ディレクトリにあり、null、未設定、空文字を区別する。日付の実在性、項目ごとの型、record IDの重複、JSONの厳密な真偽値/数値、パス、ファイル同一性、サイズ、権限、データとschemaの対応はSwift runtimeが追加検証する。JSON Schemaだけで移行の可否を判断しない。

## HTMLとHost操作

HTMLはopaque sandboxの子frame内で実行する。CSP、WKContentRuleList、navigation delegateの制限を併用し、ネットワーク、任意ファイル、親画面、localStorage、カメラ/マイクを使わせない。Swiftへ直接接続できるのはHostの親frameだけ。生成側は型付きcollection APIと宣言済みworkflowの確認準備APIを呼ぶ。実行確認と結果はnative UIが持つ。

現行の生成ガイドは`PocketToolGuide`から必要なトピックごとに取得する。Host実装が契約の正本であり、AIの説明や生成テスト結果だけを操作確認として扱わない。

## 更新・復元・保持

任意項目の追加など、入力済みの値を検証できる変更だけを自動移行する。必須値や変換の推測は行わない。項目/collectionの削除は影響を表示し、導入前のdataを保持する。承認に元dataのdigestを含め、変更があれば再確認する。journalに元definition/dataを残し、途中終了後も復元する。

自動checkpointはツールごと20件、定義の合計100 MiB以内。現在利用する定義と直前の定義のruntimeコピーも容量に算入し、余分なruntimeコピーはゴミ箱へ移す。古い版へはcheckpointから新しい版として復元できる。最新・直前・導入中の保護対象だけで上限に達する場合は新規履歴を作らず案内する。試し入力は導入/新規作成時にゴミ箱へ移す。データ本体、移行backup、export、ゴミ箱は上限に含めない。

## 検証

`python3 script/verify_pocket_tools_contracts.py`は既存の標準ライブラリのみのSchemaEngineを使い、v2 fixturesとv1拒否、必須・型・個数・日時を検証する。`fixtures/books`と`fixtures/plants`は実Astra Mediumが作った検証用パッケージで、ユーザーデータを含まない。実WebKit・保存・移行の検証は`--verify-pocket-tools-platform`、`--verify-pocket-tools-html`、`--verify-pocket-tools-generated-ui`で行う。

## 同梱ライブラリの設定（2026-09-08）

`pocket-library-settings.schema.json`はmacOS HostのUserDefaultsから取り出す設定部分の契約。キーが未保存なら全ライブラリが有効。`disabledPocketLibraries`は重複のないID配列で、空配列に戻すと従来動作へ戻る。将来の未知IDは保持しても現在の機能を追加する権限にはならない。旧Hostは追加キーを無視する。

これはツールmanifestやバックアップの追加フィールドではない。依存関係は既存の画面形式・collections・requestedCapabilitiesから導出する。ツールの記録、v1/v2定義、既存digestは変更しない。Codex向け台帳はHost内部の一時情報で、生成要求のdigestに含む。設計と追加手順は[ライブラリ設計](../../../docs/plan/20260908_POCKET_LIBRARY_ARCHITECTURE.md)を参照。

## HTMLツールのAI文章処理（2026-09-08）

`pocket-ai-text-request.schema.json` と `pocket-ai-text-response.schema.json` は `pocket.ai.generate({instructions, text})` の依頼と応答の正本。依頼は1〜1,000 Unicode scalar、文章と結果は1〜16,000 scalar。依頼では余分なキー・空白のみ・NULを実行時にも拒否する。Promiseは `{text}` を返す。manifest v2の既存requestedCapabilitiesへ `ai.text.generate@1`、permissionsへ `ai.text.send` を宣言する。workflowからのAI実行は拒否し、HTML専用のHost確認を必須とする。

既存manifest形式・記録・バックアップは変更しない。旧Hostでは新操作を含むツールが未対応として拒否される。既存ツールの移行は不要。`--verify-pocket-ai-text`、`--verify-pocket-ai-text-live`、`--verify-pocket-ai-generated` で権限・取消・実モデル・生成HTMLからの結果表示を確認する。
