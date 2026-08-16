# HoverPocket AI-native AN5-C Runtime / Surface Activation

## 目的

Lifecycle上で検証・保存されたPocket Appを、実際の描画とCapability実行へapp ID単位で反映する。保存記録だけの成功を禁止し、Lifecycle receiptとSurface / execution runtimeの実測状態が一致した場合だけ成功とする。

## 作業環境

- base: `a35b0ea8c224809ad4ff1bf1dc466882fc70169b`
- branch: `codex/ai-native-an5-runtime-activation`
- worktree: `/Users/shotaro/code/share/hover-menu-preview-ai-native-an5c`
- 作成時parity: `HEAD...origin/main = 0 / 0`

## 必須契約

- Host所有のapp ID keyed `PocketSurfaceRegistry`とexecution-runtime registryを設ける。
- 組み込みToday Focusと生成Pocket Appを別entryとして保持する。
- 複数の生成Appを同時登録し、一方の操作で他方を変更しない。
- install / update / enable / disable / preserve-only remove / rollback後に、app ID、version、package digest、effective permission grantを実runtimeからreadbackする。
- disable / remove後は対象Appを描画・実行できず、enable / rollback後は選択された検証済み版だけを利用できる。
- 再起動後にenabled Appを復元し、不一致や破損はfail closedにする。
- 任意native codeと実Codex生成activationは有効化しない。

## ChatGPT Pro Orchestrator

- run: `20260816-074324-hoverpocket-an5-c-runtime-activation-registryos`
- route: normal Chat / GPT-5.6 Sol / Pro
- role: builder
- source: public GitHub、exact base `a35b0ea`、read-only
- artifact: `changes.patch`
- Pro担当: AN5-C設計、両OS実装、deterministic tests、判断記録
- Codex担当: delivery claim、receipt / hash / base / path検証、適用、ローカルtest、security review、docs、Git / PR / merge、実機受入

## 適用前baseline

- `swift build -Xswiftc -warnings-as-errors`: 成功
- `.build/debug/HoverPocket --verify-pocket-app`: 成功
  - package / lifecycle / generation: 成功
- `.build/debug/HoverPocket --verify-capabilities`: 成功
  - handler: 14
- `.build/debug/HoverPocket --verify-broker`: 成功
  - Registry descriptor: 15
  - available handler: 14
  - Pocket App declared tests: 4
  - Pocket App layout cases: 16
- `.build/debug/HoverPocket --verify-pocket-surface`: 成功
- `.build/debug/HoverPocket --verify-timer`: 成功
- `python3 script/verify_pocket_contracts.py --quiet`: 成功
- `git diff --check`: 成功
- `./script/build_and_run.sh --build-only`: 成功
- `codesign --verify --deep --strict --verbose=2 dist/HoverPocket.app`: 成功
- 開発bundleのidentifier: `local.codex.hover-pocket`
- 開発bundleは`SPARKLE_FEED_URL`未指定時に`SUFeedURL`を持たない。正式feed検証はAN8で行う。

## 回収と実装

- ChatGPT Pro Orchestratorのdelivery `return-c57fbeea41bcf7a2a8f80a27f1323e4b`とstate hashをbridgeでclaimし、receiptを検証した。
- 返却成果物は適用可能なpatch contractを満たさず、1回のrepair上限後にisolated recoveryへ切り替えた。main worktreeを変更せず、AN5-C worktreeだけでCodexが復元し、返却は再適用せずmark-doneした。
- macOS / Windowsへapp ID keyed execution runtime RegistryとPocket Surface Registryを追加した。組み込みToday Focusの予約IDを生成Appから分離し、複数Appを同時保持する。
- lifecycleのinstall / update / enable / disable / preserve-only remove / rollbackをruntime同期へ接続した。成功条件はapp ID、version、package digest、effective permissionsの一致であり、不一致時はruntimeを解除してdurable stateもdisabledまたはremovedへ戻す。
- enabled Appは起動時にverified active packageから復元する。壊れたAppやreserved identityはfail closedにし、生成Appのglobal WebView bridge routeは登録しない。
- real Codex generationは引き続きfail closedであり、生成packageの任意native code hot installも行わない。

## stale runtime hardening

- macOSのactivation leaseは登録済みのquery / workflow Taskを保持し、disable / remove / replacement / default-off時にcancelする。
- Swift Capability Brokerはexecution slot取得後と各step前に取消を確認し、timeout用の子Taskへ親取消を伝播する。Timerはpending write待ちの直後、state変更前に再確認する。
- Windowsのactivation leaseはCancellationTokenを所有し、runtimeがcaller tokenと連結してBrokerのqueue、各step、handlerへ伝播する。
- verifierへlease invalidationとcancellation signalの回帰を両OSで追加した。

## 適用後検証

- `swift build -Xswiftc -warnings-as-errors`: 成功
- `.build/debug/HoverPocket --verify-pocket-app`: 成功
  - package / lifecycle / generation / runtime activation: 成功
  - package negative cases: 13
- `.build/debug/HoverPocket --verify-capabilities`: 成功、handler 14
- `.build/debug/HoverPocket --verify-broker`: 成功、descriptor 15、handler 14、negative cases 11
- `.build/debug/HoverPocket --verify-pocket-surface`: 成功、negative cases 13
- `.build/debug/HoverPocket --verify-timer`: 成功
- `python3 script/verify_pocket_contracts.py --quiet`: 成功
- `git diff --check`: 成功
- `./script/build_and_run.sh --build-only`: 成功
- `codesign --verify --deep --strict --verbose=2 dist/HoverPocket.app`: 成功
- WindowsはこのMacに`dotnet`がないため、Debug / Release buildと全verifierをPR CIで必須確認する。

## Security review

- 初回scan `5f04b3fc-a7cc-4398-a46e-358898ae6026`で19 / 19 fileを確認し、production caller接続前のstale runtime競合を特定した。
- 競合対策を実装した最終差分digestは`codex-security-snapshot/v1:sha256:b244af1e59a2cad40f5fce0173cbf78f491660efccde9fc0a12c69518f8b294f`。
- 最終scan `d40de7c5-0469-4f95-985b-d97b1a30c08e`は22 / 22 file、coverage complete、reportable finding 0件、sealed complete。
- Windowsのsame-user pathname raceは追加権限を生まないhardening debt、単一破損Appによる復元停止はrobustness debtとしてsecurity findingから分離した。production生成UI接続前にApp単位recovery隔離も改善候補とする。

## 未完了

- PR、CI、merge後readback
- 両OS実機でのSurface / runtime activation readback
- 実Codex generationのlocal-file confinement
- Voiceから生成、preview、承認、install、利用するCore Integration E2E
