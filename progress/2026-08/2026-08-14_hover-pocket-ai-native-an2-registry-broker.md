# HoverPocket AI-native AN2 Registry / Broker / Text Today Focus

## 現在地

AN1のProvider Capability 10件をmainへ統合し、AN2の隔離worktreeとremote branchを作成した。現在はChatGPT Pro OrchestratorのBuilderが、承認済み最終計画に基づく適用可能な`changes.patch`を生成中である。CodexはPro担当実装を並行して再実装せず、exact artifactの回収後に検査・適用・検証を担当する。

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

Pro-owned:

- Capability Registryをruntimeの単一正本へ昇格する。
- Capability Brokerを唯一の実行入口とする。
- schema validation、permission / risk、exact-plan approval bindingとTTL、durable idempotency replay、timeout / cancellation、Provider実行、authoritative readback、sanitized receipt、redacted append-only auditを実装する。
- Today FocusのText reference flowと両OSの決定論的verifierを実装する。

Codex-owned:

- artifactのbase、実hash、patch構文、allowed / forbidden pathを検査する。
- patchをAN2 worktreeへ適用し、local build、verifier、GitHub Actions、独立review、security scanを実行する。
- commit、push、Ready PR、CI / review readback、最終受入を行う。

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

- Pro artifact回収とSkillの`claim-synthesis`。
- patch検査、適用、修正、ローカル / CI検証。
- 独立Critic reviewとsecurity scan。
- progress最終更新、commit / push、Ready PR、全check / review readback。
