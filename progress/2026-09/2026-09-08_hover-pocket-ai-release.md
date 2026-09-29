# 機能ライブラリとAI文章処理の本番配信

ユーザーの「本番配信をお願いします」に基づき、macOS 0.1.0 (642) の公開とこのMacのSparkle更新を完了。対象は直前に実装・検証した機能ライブラリと生成HTMLからのAI文章処理。公開・更新を承認済みの範囲として再確認せず実施した。

- ソース: `4cb4e953cbec44ddd11fe593b3d5b926d8fff42b`、タグ `v0.1.0-642`。ソース197ファイルのhashをビルド前後で照合。
- Developer ID署名、Apple公証Accepted（9a0ca586-29e9-48b2-ac8b-d9b8522ecf80）、staple、Gatekeeperが通過。
- 配布するRelease実物でAI単体20件、ライブラリ49件、既存パッケージ・health・backup、実AI結果42が通過。前段の実生成HTML→AI→結果表示、WebKit、App OS等の検証も保持。
- [3 OS契約CI](https://github.com/shotaro311/hover-pocket/actions/runs/34223706013): 4ジョブsuccess。
- 公開後の独立readback 93 checks、macOS署名・公証・Sparkle署名・appcast一致が通過。Windows 0.2.8の8資産は更新前後で不変。
- アプリ内「アップデートを確認」→642提示→Install Update→Install and Relaunchで641から642へ更新。公開ZIPを別途ダウンロードした実行ファイルとインストール済みbinaryが一致。起動数1。
- 確認対象の保存データ6ファイルが更新・再起動・UI確認後も一致。ChatGPTログイン済み、音声確認設定を保持。機能ライブラリ内にAI文章処理v1が有効と実画面で確認。設定値は変更せず確認画面を閉じた。

実マイクの音声会話、他のMac実機、Windowsへの新機能展開は今回未検証。

[本番642](https://github.com/shotaro311/hover-pocket/releases/tag/v0.1.0-642) / [検証根拠](../evidence/2026-09-08-pocket-ai-release/)。
