# HoverPocket AI-native AN2 Registry / Broker / Text Today Focus

## 現在地

AN1のProvider Capability 10件をmainへ統合し、AN2の隔離worktreeとremote branchを作成した。ChatGPT Pro OrchestratorのBuilderはtimeoutで成果物を返せなかったため、Skillのblocked例外に従い、CodexがRegistry / Broker / Text Today Focusを両OSへ再実装した。最終実装head `5d7cbe1ba6be44261c578ea3195d7fe5ccb03d45`はローカル回帰、Windows / macOS / 共通契約CI、最終security scanを通過した。独立Pro CriticはProject証拠不足で成果物なしの`blocked`となったため、Pro verdictは受入根拠に含めない。

## Git / branch

- AN1 PR: [#8](https://github.com/shotaro311/hover-pocket/pull/8)（merged）
- AN1 merge commit / AN2 exact base: `3dce5df07c2b3ed687feefd78b6e78b0753e9958`
- AN2 branch: `codex/ai-native-an2-registry-broker`
- AN2 worktree: `/Users/shotaro/code/share/hover-menu-preview-ai-native-an2`
- branchは同名remoteをtrackingしている。
- 最終実装head / remote head: `5d7cbe1ba6be44261c578ea3195d7fe5ccb03d45`

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
- 既存Calendar UIの「選択予定から集中を開始」は、両OSで同じText Today Focus adapterとBrokerへ入り、Host-owned approvalの後にだけTimer / Stickyを書き込む。
- timeoutはunknown receiptを先に返さず、cancelled handlerの完了を待ってから呼出元を再開する。これによりtimeout後のlate side effectとVerifierのraceを除去した。

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

Broker verifierはnative authority拒否、extra argument拒否、permission不足、approval reject / expiry / plan tamper / token replay、restart replayと副作用1回、workflow conflict、audit本文非保存、partial failure時Timer rollback、timeout完了待ち、cancellation、ledger / audit persistence failure、並行duplicate、default-off、共通digestを検査する。最終headでは同Verifierを20回連続実行して成功し、2026-08-15の再実行でも全ローカル回帰が成功した。

## GitHub Actions / Security readback

- Windows Release / Broker / 既存回帰: [31819648677](https://github.com/shotaro311/hover-pocket/actions/runs/31819648677) `SUCCESS`
- macOS Swift 6 / Broker / 既存回帰: [31819652540](https://github.com/shotaro311/hover-pocket/actions/runs/31819652540) `SUCCESS`
- Ubuntu / macOS / Windows Pocket contract parity: [31819655023](https://github.com/shotaro311/hover-pocket/actions/runs/31819655023) `SUCCESS`
- 3 runともhead SHAは`5d7cbe1ba6be44261c578ea3195d7fe5ccb03d45`で一致する。
- Codex Security scan `d596e8a5-1d07-4f13-b9c9-2672f51fc36f`はremediation range `7c05e5416494a54fe400302809ecccb396fbe93d...5d7cbe1ba6be44261c578ea3195d7fe5ccb03d45`の8 / 8 fileをレビューし、coverage `complete`、finding 0、sealed `completed`である。
- security scanの明示的な未検証範囲は、外部Google Calendar実mutationと、AN2で未接続のVoice / MCP / Connector / generated PocketSurface ingressである。

## Pro Critic run

- Run ID: `20260815-013805-hoverpocket-an2headready-pr`
- Route / role: normal ChatGPT Pro / independent Critic
- Model / mode: `GPT-5.6 Sol` / `Pro`
- GitHub access / external actions: read-only / none
- exact base / head: `3dce5df07c2b3ed687feefd78b6e78b0753e9958...5d7cbe1ba6be44261c578ea3195d7fe5ccb03d45`
- required artifact: `critic-review.md`
- return mode: required。使い捨てbridgeのdelivery ID `return-137465ac8cfbb28ac1365a184a26dfb2`を1回だけclaimする。
- 2026-08-15 02:19 JSTにcompletion `blocked`を受信した。理由は`Oracle completion does not prove that the chat was created in the configured ChatGPT Project`。
- delivery ID `return-137465ac8cfbb28ac1365a184a26dfb2`とstate SHA-256 `30d4925a...6b2`の`claim-synthesis`は成功した。
- `response.md`は1 byte、SHA-256 `01ba4719...46b`、`critic-review.md` / `pro-receipt.json` / `artifact-manifest.json`は存在しない。よってartifact適用、Pro findings、Pro verdictはなし。
- `mark-done`後の`delivery.synthesis_completed_at`は`2026-08-15T02:20:23+09:00`。同じ通知を再適用しない。
- blocked例外に従い、Codexが既存の独立security reviewとexact headを再照合した。長文目的の表示・実行ずれ候補は、両OSで`TodayFocusApprovalText`が80 Unicode scalarへcanonicalizeし、その同一値をapproval display、Timer title、Sticky bodyへ使う現行実装と100文字fixtureで既に解消済みだった。追加コード変更は不要である。

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

- 進捗文書だけをcommit / pushする。
- Ready PR作成後、docs-only head差分、全check、未解決review thread、mergeabilityをreadbackする。
