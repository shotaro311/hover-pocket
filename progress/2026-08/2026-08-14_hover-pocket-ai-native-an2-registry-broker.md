# HoverPocket AI-native AN2 Registry / Broker / Text Today Focus

## 現在地

AN1のProvider Capability 10件をmainへ統合し、AN2の隔離worktreeとremote branchを作成した。ChatGPT Pro OrchestratorのBuilderはtimeoutで成果物を返せなかったため、Skillのblocked例外に従い、CodexがRegistry / Broker / Text Today Focusを両OSへ再実装している。macOSのruntimeと決定論的検証は成功し、WindowsはCI compile前である。

## Git / branch

- AN1 PR: [#8](https://github.com/shotaro311/hover-pocket/pull/8)（merged）
- AN1 merge commit / AN2 exact base: `3dce5df07c2b3ed687feefd78b6e78b0753e9958`
- AN2 branch: `codex/ai-native-an2-registry-broker`
- AN2 worktree: `/Users/shotaro/code/share/hover-menu-preview-ai-native-an2`
- branchは同名remoteをtrackingしている。

## Pro Builder run

- Run ID: `20260814-215620-hoverpocket-an2capabilityregistryruntimecapabilitybrokertext-today-focusmacos-windows`
- Route: normal ChatGPT Pro
- Model / mode: `GPT-5.6 Sol` / `Pro`
- Role: Builder
- Artifact: `changes.patch`
- GitHub access: read-only
- External actions: none
- exact source base: `3dce5df07c2b3ed687feefd78b6e78b0753e9958`
- source files: 64
- source SHA-256: `14dfd7634ac53ebe33f1ee6be7e6cb3f0950514fa263e1163fa166e8d56e4dcd`
- forbidden path hit: 0
- secret pattern hit: 0
- return mode: required。使い捨てbridgeから同じorigin threadへ1回だけ自動配送する。

### 回収結果

- delivery ID: `return-39f939c1e3050273947eb612c478c682`
- state SHA-256: `313647351081d10971d33416546ea02940a61ff022c0505d285be4b8b4bd0aa2`
- completion status: `blocked`
- Oracleは約40分後にtimeoutした。`response.md`は空で、`changes.patch`、artifact manifest、Pro receiptは生成されなかった。
- bridgeの`claim-synthesis`でdelivery IDとstate hashを一致確認し、成果物なしを確認後、`mark-done`を実行した。同じ通知の再適用と同じpromptの再送は行わない。
- configured ChatGPT Project内へ作成されたことも証明できなかったため、このrunを実装成果として扱わない。

Pro-owned:

- Capability Registryをruntimeの単一正本へ昇格する。
- Capability Brokerを唯一の実行入口とする。
- schema validation、permission / risk、exact-plan approval bindingとTTL、durable idempotency replay、timeout / cancellation、Provider実行、authoritative readback、sanitized receipt、redacted append-only auditを実装する。
- Today FocusのText reference flowと両OSの決定論的verifierを実装する。

Codex-owned（blocked後の再実装を含む）:

- artifactのbase、実hash、patch構文、allowed / forbidden pathを検査する。
- patchをAN2 worktreeへ適用し、local build、verifier、GitHub Actions、独立review、security scanを実行する。
- commit、push、Ready PR、CI / review readback、最終受入を行う。

## Codex再実装の現在地

- macOS / Windows共通で11 descriptorを持つ`CapabilityRegistry`を追加した。10個のAN1 handlerを利用可能にし、`system.native.authority@1`はruntime prohibitedでfail closedにする。
- `CapabilityBroker`はplan / principal / origin / Pocket App context / permission / exact argument schemaを検証し、承認が必要なwriteをdigest-bound、TTL付き、single-use grantへ固定する。Callerは`approved: Bool`を渡せない。
- JSON ledgerはworkflowとinvocationをpending / completedで保存する。同一plan再送はprocess再生成後もreceiptをreplayし、別digestはconflict、pendingはunknownとして自動再実行しない。
- write後はTimer / Sticky / Calendarを別queryでreadbackする。Today FocusでSticky保存が失敗した場合、開始済みTimerをBroker経由で停止し、rollback statusをreceiptへ残す。
- auditはinput digest、pseudonym、capability、status、readback evidenceだけをJSONLへ保存し、Calendar title / eventRef、Sticky本文、raw user IDを保存しない。
- Text Today Focus adapterは今日のCalendarを読み、選択予定からTimer startとSticky purpose upsertの2 step planを作る。writeは1枚のapproval requestにまとめる。
- feature flagはmacOS / Windowsとも既定オフ。off時はBroker ledger / audit、Codex process、Voice、microphoneを起動しない。Windowsは既存UIと同じ`PanelBridgeController.CapabilityHandlers`を使い、macOSは既存Singleton Storeを使う。
- 共通golden plan digestは`sha256:d098ea1b5f9f70e91486fd53229e7ddb68f73a9952ab94f17eed27cdeeb6413f`へ固定した。

## 実装後のローカル検証

macOSで次を確認した。

```text
swift build
  PASS (Swift 6)

.build/debug/HoverPocket --verify-broker
  broker_verify=ok
  broker_registry_descriptors=11
  broker_available_handlers=10
  broker_today_focus=ok
  broker_negative_cases=10
  broker_golden_plan_digest=sha256:d098ea...6413f

.build/debug/HoverPocket --verify-capabilities
  capability_verify=ok
  capability_handlers=10

.build/debug/HoverPocket --verify-timer
.build/debug/HoverPocket --verify-clipboard
.build/debug/HoverPocket --verify-calculator
.build/debug/HoverPocket --verify-panel-layout
.build/debug/HoverPocket --verify-media
  すべてexit 0。panel layoutは112 case。

python3 script/verify_pocket_contracts.py
  PASS hoverpocket.pocket/v1: schemas=12 fixtures=52 matched=52

git diff --check
  PASS
```

Broker verifierはnative authority拒否、extra argument拒否、permission不足、approval reject / expiry / plan tamper / token replay、restart replayと副作用1回、workflow conflict、audit本文非保存、partial failure時Timer rollback、timeoutのunknown receipt、default-off、共通digestを検査する。

## Patch適用前baseline

Exact head `3dce5df07c2b3ed687feefd78b6e78b0753e9958`で確認した。

```text
swift build
  PASS (Swift 6)

.build/debug/HoverPocket --verify-capabilities
  capability_verify=ok
  capability_handlers=10

.build/debug/HoverPocket --verify-timer
  timer_verify=ok

.build/debug/HoverPocket --verify-clipboard
  clipboard_verify=ok

.build/debug/HoverPocket --verify-calculator
  calculator_verify=ok

.build/debug/HoverPocket --verify-panel-layout
  panel_layout_verify=ok
  panel_layout_cases=112

python3 script/verify_pocket_contracts.py --report-json <report>
  PASS hoverpocket.pocket/v1: schemas=12 fixtures=52 matched=52
  2 runs byte-for-byte identical
  report SHA-256=b11c7a6f4e5e9b6dcfe6ad99e257d33086c7d92a567945f9fdb28b694ce5d0b0

git diff --check
  PASS
```

## AN2受入gate

- Registry descriptorのID、version、effect、permission、input / output schemaがmacOS / Windowsで一致する。
- Broker以外のVoice / Text / Codex Tool / generated Surface経路からProvider Storeへ到達できない。
- approvalがcanonical plan digest、exact args、origin、principal、permission scope、expiryへbindingされる。
- 改ざん、期限切れ、別principal、別origin、別permission、cross-plan reuseをfail closedで拒否する。
- 同一idempotency key + 同一planはprocess再起動後も同じreceiptを返し、同一key + 別planは拒否する。
- successful receiptはHost-owned authoritative readbackを持ち、write応答やProvider自己申告だけで成功にしない。
- auditへraw transcript、notes、clipboard、OAuth token、秘密値、raw identifierを保存しない。
- Today FocusはCalendar read、ユーザー選択eventRef、Timer start、Sticky upsertを同じcanonical planへ固定し、write前承認と実行後readbackを確認する。
- reject、partial failure、timeout、cancellation、persistence failure、concurrent duplicateを決定論的に検証する。
- feature default-offで既存geometry、startup、Provider ordering、microphone、Codex process、Legacy AI command laneの非表示が不変である。
- macOS Swift 6、Windows Release、contract parity、既存Provider回帰、security scanを同じsource headで通す。

## 未完了

- Windows GitHub ActionsでのRelease compile、`--verify broker`、既存verifier readback。
- timeout / cancellationのlate side effectなし、並行duplicate、ledger / audit persistence failureの追加hardening。
- 既存Calendar UIから同じToday Focus planを開始するHost-owned approval入口。
- 独立Critic reviewとsecurity scan。
- progress最終更新、commit / push、Ready PR、全check / review readback。
