---
project_slug: hover-menu-preview
date: 2026-08-24
status: stacked-draft-pr-ci-green
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
- このMacには.NET SDKがないためWindowsローカル実行は行っていない。代わりにDraft PR [#26](https://github.com/shotaro311/hover-pocket/pull/26)のWindows run [32653742569](https://github.com/shotaro311/hover-pocket/actions/runs/32653742569)でRelease build、Settings UI module、Capability、Broker、Pocket Surface、Timer、Settings、Voice foundation、updater、rendered WebView UIが成功した。
- code head `cd3b974f18e0a55c01989132b515af62b34789f4`でmacOS run [32653742576](https://github.com/shotaro311/hover-pocket/actions/runs/32653742576)、3 OS deterministic contract / byte-identical compare [32653742551](https://github.com/shotaro311/hover-pocket/actions/runs/32653742551)、Router [32653742728](https://github.com/shotaro311/hover-pocket/actions/runs/32653742728)も成功した。

## ChatGPT Proレーン

- AN8-C backup / export / restoreの通常Pro runは同一sessionのdetached supervisorとreturn bridgeで回収継続中である。正式delivery前のresponse / artifactは読まず、再送・停止・手動回収を行っていない。
- 本branchはPro担当のworkspace backup / export / restoreを実装せず、独立したCapability履歴保持ポリシーだけを扱う。

## 次のgate

- Draft PR #26は`Draft / MERGEABLE / CLEAN`、remote parity `0 / 0`である。Core Integration Candidateへ取り込む前にexact diffとstack順を人手で確認する。
- mainへの自動mergeは行わない。次はAN8-C backup / export / restoreの正しいPro runの正式deliveryを待ちながら、schema / Capability廃止とmigration gateへ進む。
