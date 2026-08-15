# HoverPocket AI-native Built-in Capability Expansion

## 現在地

AN2を統合した`main`のexact head `014032d412ab488c5e526f1ed2e7d23218c38a87`から、隔離worktree `/Users/shotaro/code/share/hover-menu-preview-ai-native-capability-expansion`とbranch `codex/ai-native-capability-expansion`を作成した。最初の縦断単位として、Calculatorのpure local `calculator.expression.evaluate@1`をmacOS / Windowsの共通Registry、Broker、runtime compositionへ追加した。

## 実装

- 入力は`expression`だけを受け、`+ - * /`、単項符号、小数、演算子優先順位を決定論的に評価する。
- 式は256文字、値は64個、整数18桁、小数12桁へ制限し、除算ゼロ、未知文字、overflow、過大payloadをfail closedで拒否する。
- 任意コード評価、関数、変数、括弧、指数、ネットワーク、Provider Storeへの直接アクセスは持たない。
- Registry上は`pure`、権限なし、承認なし、rollbackなし、Host-owned outputを使う`none` readbackとした。
- macOS / Windowsで同じCapability ID、schema、制限、normalized expression、result形式、正負の代表値と不正入力fixtureを持つ。
- 既存Calculator UIのBroker移行はExpansion trackの後続単位であり、この差分では既存UI挙動を変更していない。

## ローカル検証

macOSで次をreadbackした。

```text
swift build -Xswiftc -warnings-as-errors
  PASS

.build/debug/HoverPocket --verify-capabilities
  capability_verify=ok
  capability_handlers=11
  capability_calculator_evaluate=ok

.build/debug/HoverPocket --verify-broker
  broker_verify=ok
  broker_registry_descriptors=12
  broker_available_handlers=11
  broker_calculator_evaluate=ok
  broker_today_focus=ok
  broker_negative_cases=10

.build/debug/HoverPocket --verify-calculator
.build/debug/HoverPocket --verify-timer
.build/debug/HoverPocket --verify-clipboard
.build/debug/HoverPocket --verify-panel-layout
.build/debug/HoverPocket --verify-media
  すべてexit 0。panel layoutは112 case。

python3 script/verify_pocket_contracts.py --root .
  PASS hoverpocket.pocket/v1: schemas=12 fixtures=52 matched=52
  report SHA-256=b11c7a6f4e5e9b6dcfe6ad99e257d33086c7d92a567945f9fdb28b694ce5d0b0

git diff --check
  PASS
```

## 未完了

- 検証結果を進捗文書へ反映したdocs commitをpushし、最終PR headのcheck、mergeability、未解決reviewを再確認する。
- Expansion trackの残りで、Calendar update / delete、Timer / Sticky既存UI移行、Controls、Clipboard、Calculator既存UI移行を段階実装する。
- AN3の実音声E2E、AN4以降のDSL / 生成 / sandbox / MCP / Connector / 配布gateは別worktreeで継続する。

## GitHub Actions / Security readback

- 実装commit / remote head: `76990dc427428c213b0cd8a1779cd09012b76436`
- Draft PR: [#10](https://github.com/shotaro311/hover-pocket/pull/10)
- macOS run: [31852926760](https://github.com/shotaro311/hover-pocket/actions/runs/31852926760) `SUCCESS`
  - Swift build、Capability 11 handler、Broker 12 descriptor / 11 handler、Calculator Capability、Today Focus、Timerが成功した。
- Windows run: [31852926787](https://github.com/shotaro311/hover-pocket/actions/runs/31852926787) `SUCCESS`
  - .NET 10 Release buildは0 error。Capability、Broker、Timer、UI model、Updater、rendered WebView UIがすべてexit 0だった。
- PR Router run: [31852926762](https://github.com/shotaro311/hover-pocket/actions/runs/31852926762) `SUCCESS`
- exact headのPR readbackは`MERGEABLE / CLEAN`、3 check成功だった。
- Codex Security diff scan `1b18c190-d37b-450c-960f-c924f26ea9ae`は変更source 10 / 10を完全レビューし、coverage `complete`、finding 0、sealed `completed`となった。総token usageは104,917。外部service mutationはpure Calculator差分に存在せず対象外である。
