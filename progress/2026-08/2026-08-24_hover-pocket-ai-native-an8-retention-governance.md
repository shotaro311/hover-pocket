---
project_slug: hover-menu-preview
date: 2026-08-24
status: local-verified; windows-ci-pending
branch: codex/ai-native-an8-retention-governance
base: a330099a86d9504ee700cf5bfc2478e26aa46f55
---

# AN8 Capability履歴の保持期間・削除

## 実装

- macOS / WindowsのCapability Broker台帳をv2へ移行し、完了receiptへ`completedAt`を保存した。v1台帳はreceipt時刻から移行し、v2へdurable writeする。
- Settingsへ`7日 / 30日 / 90日 / 無期限`の保持期間を追加し、既定を90日にした。AI-native機能がOFFでも既存履歴を管理できる。
- 期限超過または明示削除では、監査JSONLと完了receiptの内容・完了時刻を削除する。plan / argument / capability digestとcompleted stateは墓標として残し、同じ副作用を再実行させない。
- 全削除はSettings専用とし、macOS SwiftUI alert / Windows native MessageBoxを既定Noで表示する。Windows WebViewからはHost methodだけを呼び、Panel surfaceへmethodを公開しない。
- audit対象を`capability-YYYYMMDD.jsonl` regular fileへ限定した。malformed file、macOS symlink、Windows reparse / directoryをfail closedにし、append / retention / readbackを同一process lockで直列化した。
- 削除前にaudit / ledgerをpreflightし、壊れたaudit entryを検出した状態でreceipt redactionを先行させない。

## ローカルreadback

- `swift build -Xswiftc -warnings-as-errors`: 成功。
- `.build/debug/HoverPocket --verify-broker`: 成功。21 descriptor / 20 handler、`broker_retention_governance=ok`を確認した。
- retention verifierで期限削除、明示削除、墓標後のworkflow lookup=`unknown`、symlink拒否、v1→v2 migrationを確認した。
- `--verify-capabilities`、`--verify-pocket-app`、`--verify-pocket-surface`、`--verify-voice-foundation`、`--verify-panel-layout`、`--verify-timer`: すべて成功。
- `python3 script/verify_pocket_contracts.py --report-json /tmp/hoverpocket-an8-retention-contract-report.json`: 13 schema / 66 fixture成功。
- `node --check windows/ui/settings/settings.js`、`node windows/script/verify_settings_generation_target.mjs`、`git diff --check`: 成功。
- このMacには.NET SDKがないため、Windows Release build / Broker / Settings / rendered WebViewはDraft PR CIを受入gateとする。

## ChatGPT Proレーン

- AN8-C backup / export / restoreの通常Pro runは同一sessionのdetached supervisorとreturn bridgeで回収継続中である。正式delivery前のresponse / artifactは読まず、再送・停止・手動回収を行っていない。
- 本branchはPro担当のworkspace backup / export / restoreを実装せず、独立したCapability履歴保持ポリシーだけを扱う。

## 次のgate

- 変更をcommit / pushし、Core Integration CandidateへstackしたDraft PRでWindows CIとmacOS回帰をreadbackする。
- CI成功後にexact diffを再確認し、Core Integration Candidateへ取り込む順序を固定する。mainへの自動mergeは行わない。
