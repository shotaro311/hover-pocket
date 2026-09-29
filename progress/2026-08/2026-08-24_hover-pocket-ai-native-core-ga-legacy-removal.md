# HoverPocket AI-native Core GA旧AI直結経路の除去

## 目的

`docs/plan/20260813_PLAN1.md` 28.1の「`approved: Bool`や直接Store mutationのAI経路が残らない」を、UI非表示ではなく製品sourceの削除とnegative testで満たす。

## 実装

- 基点: `codex/ai-native-an8-windows-signing-pipeline` / `3448edaf4f2cc9a14efb69dd00b619389a113563`
- branch: `codex/ai-native-core-ga-legacy-path-removal`
- macOS:
  - `AICommandStore`、`CalendarPocketTool`、旧`ApprovalGate / AuditLog`、旧`AICommandPaletteView`、その専用model / Apple Foundation Models plannerを削除した。
  - 現行のCapability Registry / Broker、Today Focus Text Adapter、Voice Lane、Pocket App runtimeは変更していない。
- Windows:
  - 旧`Providers/AiLane`、`CalendarAiLaneConnector`、CalendarStoreの旧AI専用read / create method、未使用constructor互換引数、旧UI moduleを削除した。
  - `--verify ailane`は互換CLI名のまま`LegacyAiLaneVerifier`へ置換し、旧stateと3 routeを`unknown_method`で拒否し、旧Provider IDがないことを確認する。
- 共通Voice contractは旧実装pathの再出現と、negative verifier欠落をfail closedにした。
- 削除対象はローカルのゴミ箱へ退避し、Git履歴からも復元できる。

## 検証

| 検証 | 結果 |
|---|---|
| `swift build -Xswiftc -warnings-as-errors` | 成功 |
| `--verify-panel-layout` | 128件、成功 |
| `--verify-capabilities` | 20 handler、成功 |
| `--verify-broker` | 21 descriptor / 20 handler、成功 |
| `--verify-pocket-surface` / `--verify-pocket-app` | 成功 |
| `--verify-voice-foundation` / `script/verify_voice_foundation.py` | 成功 |
| `--verify-timer` | 成功 |
| `script/verify_pocket_contracts.py` | 14 schema / 69 fixture、全一致 |
| Windows `app.js` / `settings.js` syntax | 成功 |
| `git diff --check` | 成功 |

ローカルMacには.NET SDKがないため、Windows Release build、`--verify ailane` negative runtime、rendered UIはPR CIを受入gateにした。Draft PR [#30](https://github.com/shotaro311/hover-pocket/pull/30)のcode head `1874daa`で、Windows [32659682483](https://github.com/shotaro311/hover-pocket/actions/runs/32659682483)とmacOS [32659682571](https://github.com/shotaro311/hover-pocket/actions/runs/32659682571)が成功した。WindowsはRelease build、Capability、Broker、Pocket Surface、旧AI lane不在、Voice、署名contract、rendered WebView UIをすべて通過した。

## AN1〜AN8完了監査

| 領域 | 現在地 | Core GA判定 |
|---|---|---|
| AN0〜AN2 / Built-in Capability | main取り込み済み + 統合stack CI済み。今回、旧AI直結sourceを除去 | 内部実装は満たす |
| AN3 Voice | Host-owned Compact / Expanded、Windows transport / Broker slice、macOS foundationは実装済み。現行Codexには正のBroker-only tool allowlistがなく、macOS production adapterと両OS実音声E2Eも未完了 | 未完了 |
| AN4 | DSL / renderer / Today Focus packageはmain取り込み済み | 満たす |
| AN5 | generation / lifecycle / runtime activation stackはCI済み。実Codex local-file confinementとVoice生成E2Eはfail closedのまま | 未完了 |
| AN8 data | retention / compatibility migration / healthはCI済み。backup / export / restoreは正しいPro runの正式delivery待ち | 未完了 |
| AN8 release | macOS公開署名readbackとWindows beta identityは再確認済み。Windows正式証明書、timestamped Authenticode公開物、正式rollbackは未実施 | 未完了 |
| AN6 / AN7 | 任意の別release train | Core GA対象外 |
| Git統合 | PR #25〜#29はstacked Draft、CI green / clean。mainへの人手mergeは未実施 | 未完了 |

## 次の順序

1. このbranchをWindows / macOS CIへ載せ、旧route不在を両OSで確定する。
2. 正しいAN8-C Pro deliveryだけをhash / claim / receipt検証後に隔離worktreeへ適用する。
3. AN8-Cを現行stack headへ統合し、data version付きbackup / restoreを両OSで検証する。
4. production Voice provider方針を決定し、positive tool allowlist、実音声、Calendar create、Pocket App生成E2Eを両OS実機で閉じる。
5. Windows正式署名資格情報を登録し、signed release、feed、install / update / rollbackを別経路readbackする。
6. stackを順に人手review / mergeし、main exact headでCore GA監査を再実行する。
