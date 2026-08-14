---
project_slug: hover-menu-preview
date: 2026-08-14
status: an0-hardened; local-pass; security-pass; ci-pending
---

# AI-native AN0 Contract Hardening

## 目的

PR #7のAN0共通契約に対する独立レビューで、schemaを満たしてもHost semantic gateを迂回できる経路が12件再現した。AN1のSwift / C# runtime実装前に、同じ欠陥を両OSへ複製しないよう契約、validator、fixture、CIをfail closedへ修正した。

## 修正した境界

- `native_authority` / `runtime_prohibited` CapabilityをRegistry記述用として残し、Invocation、ExecutionPlan、PocketWorkflowの全経路で共通拒否する。
- descriptorの`maxPayloadBytes`をInvocationだけでなくPlan / Workflowにも適用する。
- Pocket AppのID、version、manifest digestをcanonical planへ含め、Invocation、ApprovalRequest、Receipt、Auditへ同じcontextをbindingする。Host-native principalはPocket App contextを持たない。
- Invocationを既知planのexact step、principal、idempotency keyへbindingし、Receiptを既知Invocation / Plan / App / Capabilityへbindingする。
- successful ReceiptはHost-owned typed observationと一致すること、evidence digestを観測値から再計算できること、descriptorの`readback.match` fieldがoutputと一致することを必須にする。
- Pocket App manifest全pathをsupport sourceのbyte digestへbindingし、Surface / Workflowの実fixtureと照合する。`asset://` traversal、package外asset、生成SurfaceのHost-owned receipt描画を拒否する。
- Calendar `range=today`とSticky namespaceをHost scopeとして検証し、Workflow / Surface / Invocation / Planのscope escapeを拒否する。
- Auditは固定keyだけでなく、opaque ID、不変enum、整数range、manifest binding、不可逆principal pseudonymを検査し、値に含まれるpath、URL、email、credential様文字列も拒否する。
- Auditを既知Invocation、descriptor、origin、trace、App context、入力digest、Host-owned readback digestへbindingし、呼び出し元が別入力や自己申告readbackの成功記録を残せないようにする。

## Fixture / CI

- corpusを31件から47件へ拡張した。
- 全reject fixtureにcanonical fixture digest、stable error code、exact error locationを固定した。
- unknown schema keywordとunresolved `$ref`のexplicit negative fixtureを追加した。
- GitHub Actionsは`ubuntu-24.04`、`macos-14`、`windows-2022`、Python `3.13.7`、Actionのexact commit SHAへ固定した。
- 各OSのdeterministic reportをartifactとして保存し、集約jobで3件のbyte一致を必須にした。
- `requirements.md`と`PLAN1.md`の変更でもcontract CIが起動するpath filterを追加した。
- Windows runnerがGit既定設定でpackage sourceをCRLFへ変換し、source byte digestを不一致にした。`contracts/pocket/v1/**`を`.gitattributes`でLF固定し、package byte列そのものを3OSで一致させた。CIの先頭実行はquietを外し、fail-closed理由をログへ残す。

## 検証

- `python3 script/verify_pocket_contracts.py`: 12 schema / 47 fixture / 47 matched。
- report JSON 2回生成 + `cmp`: byte一致。
- contract JSON 66件: 重複keyを拒否するparseに全件成功。
- `swift build`: 成功。
- `.build/debug/HoverPocket --verify-panel-layout`: 112件成功。
- `.build/debug/HoverPocket --verify-clipboard`: 成功。
- `.build/debug/HoverPocket --verify-timer`: 成功。
- `.build/debug/HoverPocket --verify-calculator`: 成功。
- `git diff --check`: 成功。
- security-relevant source確定時のCodex Security diff scan `0fc69191-40ee-4467-9d0d-e7089a13c172`: snapshot `codex-security-snapshot/v1:sha256:185523...8841`、coverage complete、6 / 6 surface review、reportable finding 0、sealed complete。

## Orchestrator

- 恒久修正済みのChatGPT Pro Orchestrator v0.7.2で、exact base `190ee90...`、Project proof、single-sendを維持して修正依頼を送った。
- Pro会話は前置きだけで成果物を返さず、40分timeout後も`changes.patch`が生成されなかった。monitor / recovery / harvestは動作し、同一依頼の再送はしていない。
- fallback方針に従いCodexが実装、ローカル検証、security readbackを引き継いだ。Pro runはblockedで確定済み。

## 変更していないもの

- macOS / Windows runtime source。
- Provider Registryと既存保存形式。
- `docs/requirement/requirements.md`と`docs/plan/20260813_PLAN1.md`。
- 承認済みVoice Lane UI画像。
- 配布release、feed、署名、インストール済みアプリ。

## 次のgate

1. 変更をcommit / pushし、PR #7のUbuntu / macOS / Windows / cross-OS report比較をreadbackする。
2. PR #7をreviewしてmergeする。
3. merge後にAN1のProvider handler化を別worktree / branchで開始する。
