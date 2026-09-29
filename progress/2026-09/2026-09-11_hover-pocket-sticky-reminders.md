# 付箋リマインダー

2026-09-11、作成・編集時の日時指定、HoverPocketの音と画面通知、Codex音声作成、本番公開とこのMac更新を依頼された。[設計](../../docs/plan/20260911_STICKY_REMINDERS.md)は「お願いします。」で合意済み。

## 実装と検証

- 本番643ソースfe32f5fを基準に変更。付箋へ任意reminder、日時編集、共通パネル通知、タイマーとの順次通知、復帰・起動時の未確認通知を追加。v1を保持してmacOS v2操作と音声経路を接続。
- Astra担当が保存、UI、Capabilityを分担し、独立レビューで保存失敗時の下書き消失、非表示providerでの停止不能、不正日時の正規化を検出・修正。親の実画面検査でUI日時の隠れた秒を分の先頭へ揃えた。
- warnings-as-errorsビルド、保存・通知（自動deadline/Combineを含む）、Timer、Capability、Broker、Voice Foundation、App OS、Panel、Voice Activity、Package/lifecycle/health/backup、Pocket Libraries/Tools、共有契約が通過。
- Voice回帰検証で未設定reminderのnullを最上位JSONへ変換して例外になる問題を修正。未設定付箋の回帰と日時付きの両方を確認。Brokerのdescriptor期待件数も修正。
- 実Codex Astra/mediumへ隔離された「10分後」の付箋作成を依頼し、tool1回、承認1回、日時now+600、timezone、ファイル再読込、process終了が一致。実マイク入力は使用していない。
- 隔離した実HoverPocketパネルで通知、停止、新規付箋への日時保存、変更・解除を確認。利用者の保存データ6ファイルは検証前後で不変。

## 配信

本番644を公開し、このMacをSparkleで643→644へ更新・再起動した。

- source: `ad17aa21eaaaef519a67ddc77325d887d6578368`、tag: `v0.1.0-644`。201 Swiftファイルのハッシュは署名ビルド前後・配信後で不変。
- Apple公証: Accepted、submission `d612e854-5093-46ea-968a-4162028b6c6f`。署名済みReleaseでも保存・通知・Timer・Capability・Broker・Voice・App OS・Panel・Pocket App保存復元・Libraries/Toolsと実Astra作成がPASS。
- CI: [34564335744](https://github.com/shotaro311/hover-pocket/actions/runs/34564335744)の3 OS既存契約と比較の4ジョブが成功。新v2リマインダー契約18件はローカル検証済み。
- 公式publishスクリプトで署名済みZIPを公開。ZIP SHA-256: `b103fd037bc6c111e1fc8db9c6a99512ffc31482a4c9154e10897391d7c1d5be`。
- 公開ファイル93 checksがPASS。別downloadでmacOS署名・公証・Gatekeeper・Sparkle鍵・appcast一致を再検証。Windowsの既存8資産はid/name/size/digest/updated_atまで不変。
- このMacはアプリ内の更新確認→Install Update→Install and Relaunchで644へ更新。再起動後のbinary SHA-256は`519ee21ee29c0a271c7af5a61aff53e80cb296385b06d02b0a6ba9bb1c396bc0`で公開ZIPに結び付く署名済みbinaryと一致。実プロセスは1件。
- 更新後も保存データ6ファイルのbyte一致、ChatGPTログイン、音声設定を確認。インストール済みappでも隔離した保存・通知verifierが通過。
- 実UIで通知と停止、新規日時設定、編集・解除、非表示付箋の共通通知を確認。分ちょうどの日時保存をファイルから再確認。検証用appは終了済み。
- 残る未検証: 実マイク発話による認識・音声応答、他のMac実機。音声操作経路は実Codexのtext入力で検証し、実発話の確認とは区別する。
- 旧mainの変更と本番worktreeの既存調査資料7件は保持。今回の実装・公開・このMac更新はユーザー承認範囲として追加確認なしで実施。

[本番リリース](https://github.com/shotaro311/hover-pocket/releases/tag/v0.1.0-644)。

## 根拠

[検証ログ](../evidence/2026-09-11-sticky-reminders/)。日時のUI readback、実Codex結果、各コマンドの結果を保存する。公開とインストールの独立readbackも保存済み。
