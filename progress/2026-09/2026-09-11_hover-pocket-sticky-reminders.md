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

本番644を予定。署名・公証・公開readbackとこのMac更新は未完了。旧mainの変更と本番worktreeの既存調査資料は保持。

## 根拠

[検証ログ](../evidence/2026-09-11-sticky-reminders/)。日時のUI readback、実Codex結果、各コマンドの結果を保存する。公開とインストールの結果は完了後に追記する。
