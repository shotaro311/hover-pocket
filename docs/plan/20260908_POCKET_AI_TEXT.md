# 生成ツールからのAI文章処理

Status: Accepted — 2026-09-08「生成ツール自身からAIを呼び出す機能」への「これもお願い」に基づくローカル実装。

## 変更と契約

従来はHostによるツール生成のみ。変更後は生成HTML内の `await pocket.ai.generate({instructions:"日本語で要約する",text:"入力した文章"})` が `{text:"要約結果"}` を返す。`pocket.ai.cancel()` で取消できる。

ライブラリは `pocket.ai-text`、操作は `ai.text.generate@1`、権限は `ai.text.send`。Descriptorが操作検査の正本、v2のrequest/response schemaが受渡形式の正本。既存manifestの宣言形式を使い、データ保存形式・digest・バックアップを変更しない。旧Hostは未対応操作を含む新ツールだけを拒否する。ロールバックで記録は失われず、既存ツールの移行は不要。

## 送信と実行

導入時の権限に加え、毎回HostがOpenAIへの送信先、Astra / Medium、依頼内容、文章全文を表示して承認を得る。音声確認の設定には依存しない。指示1,000、入力・出力16,000 Unicode scalar以内。空白のみ、NUL、追加キーを拒否する。

既存CodexログインとApp Serverを使い、依頼ごとに隔離されたephemeral threadを作る。実行前に操作制限をprobeし、ファイル・ブラウザ等の操作は公開しない。結果はstrict JSONで検査する。Hostは入力と結果を記録・監査ledgerへ自動保存しない。これはサービス側の保持方針を保証するものではない。

1画面1依頼、承認10回/分、サービス全体2並列を上限とする。処理120秒、確認を含む全体240秒。拒否・取消・画面終了・activation失効では一度だけ失敗を返し、遅れて届いた成功を表示しない。自動再送は行わない。

## 受入と利用側への影響

単体20検証、実Codexの結果42、実Astraで生成・導入した要約HTMLで入力→Host確認→実AI→結果表示が通過。実SwiftUI確認画面で全文表示・取消・模擬結果受信を確認した。v1/v2既存契約、ライブラリ、WebKit、パッケージ検証も通過。Windows実装・本番配信は含まない。
