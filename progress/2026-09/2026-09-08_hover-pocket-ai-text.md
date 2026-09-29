# 生成ツールからのAI文章処理

## 依頼と実装範囲

「生成ツール自身からAIを呼び出す機能」への「これもお願い」に基づき、macOSローカル実装を完了。既存の機能ライブラリ作業と同じ隔離作業ツリーで変更を保持した。確認を追加せず、依頼に含まれるローカル実装・検証を進めた。公開・本番アプリ置換・Windows変更はしていない。

`pocket.ai-text` を10個目の同梱ライブラリとして登録。生成HTMLが `pocket.ai.generate({instructions,text})` を呼び、Hostの全文確認後、実Codex / Astra Mediumの文章処理結果を受け取る。導入権限・宣言・有効ライブラリの再検査、取消、時間切れ、画面終了時の中止、並列数・頻度上限を実装した。入力と出力はHostの記録・監査ledgerへ自動保存しない。仕様・互換性は[設計](../../docs/plan/20260908_POCKET_AI_TEXT.md)を参照。

## 検証とreadback

- Swift warnings-as-errors build: PASS。
- AI単体20件: PASS。権限不足・承認前・拒否では未送信、古い承認・二重送信の拒否、取消の一度だけの応答、終了、実WKWebViewブリッジを確認。
- 実Codex: PASS。依頼を送信し、期待した42を構造検査して受信。
- 実生成からの通し確認: PASS。AstraがAI対応HTMLを生成、パッケージ検査・導入権限を経て、HTML入力→Host確認→実AI→HTML表示。表示結果をサービス側の受信結果と別に照合。
- 実SwiftUI: CUAで送信先・依頼・文章全文と両ボタンを読取。取消後のAI_CANCELLEDと、再依頼の模擬承認後AI_UI_RESULT_RECEIVEDをプロセス出力から確認。検証アプリを終了。
- 既存パッケージ・health・backup: PASS。WebKit20件、ライブラリ49件、v2契約62件、Pocket App OS49件、音声foundation契約: PASS。

検証用文章のみを使用。Windowsと本番配布後の実機動作は未検証。根拠は[evidence](../evidence/2026-09-08-pocket-ai-text/)と同ディレクトリのソースSHA256。

## 本番配信

追加の配信依頼により、macOS 642として公開し、このMacもSparkle経由で更新済み。[配信とreadback](2026-09-08_hover-pocket-ai-release.md)。
