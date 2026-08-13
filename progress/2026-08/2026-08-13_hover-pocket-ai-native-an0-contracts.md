---
project_slug: hover-menu-preview
date: 2026-08-13
status: an0-implemented; pr-open; ci-pass; review-pending
updated_by: codex
---

# HoverPocket AI-native AN0 Contracts and Verification

## 結果

- AIネイティブ最終実装計画の最初の独立単位AN0を実装した。
- Ready PR [#7](https://github.com/shotaro311/hover-pocket/pull/7)を作成した。
- PR head `6ef58f3732c91f0b44c21543b46cbc55619935f3`はGitHub上でMERGEABLE。
- Ubuntu、macOS、Windowsのcontract CIはpush・pull requestの両方で成功した。
- runtime behaviorと既存保存形式は変更していない。

## ChatGPT Proへの委譲と回収

- route: 通常ChatGPT Pro。ユーザーがChatGPT Pro Orchestratorの利用を明示したため。
- role: builder。ADR、versioned contracts、fixture、deterministic verifier、CIを`changes.patch`として作成。
- exact base: `8b636cae86104b1d3b589237d73ffd0f4ad9ee79`。
- conversation: `https://chatgpt.com/c/6a7db75f-852c-83e8-b850-ef0a52c85a6b`。
- response modeは画面上でProを確認した。OracleのDevTools接続が途中で切れたため、実モデルのpicker labelは未確認のまま残した。
- ChatGPT側は52分50秒で回答を完了していた。一方、Oracle workerはDevTools切断後の自動再接続に失敗し、transport状態が`running`のまま更新されなかった。
- 同一conversationとsessionから一度だけmanual harvestし、`## END`、回答、downloadable `changes.patch`を回収した。再送や別conversationへの迂回は行っていない。
- stuck childを終了してprofile leaseを解放し、runへresponseとartifactをingestした。
- download版とrun取込版のSHA-256は、ともに`35369356a4199d49b7afd038ec4871d8bcf0d3382cc3450211c9d0aedf75a174`。
- run directory: `/Users/shotaro/Documents/Codex/chatgpt-pro-orchestrator-runs/20260813-212212-hoverpocket-ai-nativean0base-shachanges-patchadrversioned-json-contractsvalid-invalid-golden-fixturescross-platform-deterministic-contract-verifierciruntime-behavior`。

## 実装内容

- `docs/adr/20260813-ai-native-an0-contract-boundary.md`
  - Registry / Brokerを実行正本にする境界。
  - callerがapproval済み状態を自己申告できない契約。
  - write成功には実状態readbackが必要なreceipt契約。
  - auditへraw transcript、予定本文、Sticky本文、Clipboard本文、secret、path、command lineを残さない契約。
- `contracts/pocket/v1/`
  - 12個のDraft 2020-12 JSON Schema。
  - 31件のvalid / invalid / golden fixtureと期待stable error code。
  - Today FocusのCalendar read、Timer start、Sticky upsert、approval / receipt / readbackのreference package。
  - Voice Laneのroot-scoped session、fullscreen禁止、Provider rect不変のgeometry fixture。
- `script/verify_pocket_contracts.py`
  - Python標準ライブラリだけで動くfail-closed verifier。
  - unknown keyword、unresolved `$ref`、duplicate key、extra property、unsafe path、cross-root session leak等を拒否。
  - 時刻や絶対pathを含まない決定論的JSON report。
- `.github/workflows/pocket-contracts-verify.yml`
  - Ubuntu、macOS、Windowsのmatrix。
  - 同じ検証を2回実行し、reportのbyte一致を確認。

## ローカル検証

- `git apply --check`: success。
- patch path: allowed pathだけ。48 files、7,024 additions。
- `python3 script/verify_pocket_contracts.py`: `schemas=12 fixtures=31 matched=31`。
- JSON report 2回: byte-for-byte一致。SHA-256 `4053ebf72d20572190bf58cd00bc9a6a82e793da9984d7663ab7ab91e8e56db3`。
- schema / fixture JSON 44件: parse success。
- fixture manifest: 31件を重複なく全列挙。
- `python3 -m py_compile script/verify_pocket_contracts.py`: success。生成cacheはゴミ箱へ移動した。
- `swift build`: success。
- `.build/debug/HoverPocket --verify-calculator`: success。
- `.build/debug/HoverPocket --verify-clipboard`: success。
- `.build/debug/HoverPocket --verify-timer`: success。
- `.build/debug/HoverPocket --verify-panel-layout`: 112 cases success。
- `git diff --check`: success。

## GitHub readback

- branch: `codex/ai-native-contracts`。
- planning commit: `8b636cae86104b1d3b589237d73ffd0f4ad9ee79`。
- AN0 implementation commit: `6ef58f3732c91f0b44c21543b46cbc55619935f3`。
- remote branch SHAはimplementation commitと一致。
- PR #7はReady / Open / MERGEABLE。
- `Verify Pocket Contracts`:
  - Ubuntu push / PR: success。
  - macOS push / PR: success。
  - Windows push / PR: success。
- `Codex PR Router`: success。

## 意図的に含めなかったもの

- Swift / C# runtime validator、Capability handler、Broker、Voice runtime接続。
- Provider Registry、Provider Store、既存UI、既存保存形式の変更。
- live Google Calendar書き込み、microphone / WebRTC、実音声E2E。
- 既存Windows verifier workflowの拡張。AN0の独立境界を越えるため、次のWindows runtime PRで扱う。
- 外部JSON Schema libraryの導入。プロジェクト依存を増やさず、3 OS CIと共有fixtureをAN0 gateにした。

## 残る判断と次のgate

- Compact 64、Expanded S / M / L / XL `190 / 220 / 250 / 280`をAN0 tokenとして採用した。XL 280は30刻みを延長した新規判断なので、PR reviewで明示確認する。
- PR #7のreview / merge前にAN1 runtime implementationへ進まない。
- merge後はAN1として、既存Provider操作の`PocketCapability` adapter、`CapabilityRegistry`、`CapabilityBroker`の最小骨格を実装する。
- 最初のruntime vertical sliceはTimerとし、schema validation、approval binding、idempotency、実行後readback、sanitized receiptを同じ経路で通す。
