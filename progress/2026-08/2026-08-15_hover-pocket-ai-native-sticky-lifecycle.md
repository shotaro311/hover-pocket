# HoverPocket AI-native Sticky Notes Lifecycle Capability

## 現在地

Calculatorを統合済みの`main` exact head `8d7127f60dd94cc75df020970c1380359c835732`から、隔離worktree `/Users/shotaro/code/share/hover-menu-preview-ai-native-capability-expansion`のbranchを`codex/ai-native-sticky-lifecycle`へ切り替えた。Built-in Capability Expansionの次の縦断単位として、Sticky Notesの状態確認、archive、deleteをmacOS / Windowsへ追加した。

## 実装

- `sticky.note.status@1`
  - UUIDのメモを`active / archived / missing`で返すprivate read。
  - `sticky.read`権限、permission grant、same-store snapshot readback。
- `sticky.note.archive@1`
  - `sticky.write`権限、Broker承認、idempotency keyを要求するreversible local write。
  - 保存後に`sticky.note.status@1`を再実行し、`noteId / state / updatedAt`を照合する。
- `sticky.note.delete@1`
  - 通常書き込みと分離した`sticky.delete`権限、`destructive_sensitive`、`strong_per_call`承認、idempotency keyを要求する。
  - 削除済みを含む不存在はdesired postconditionとして`missing`を返し、同じstatus queryで再確認する。
- macOS / Windows Storeへarchive/deleteのatomic APIを追加した。保存に失敗した場合は、メモ配列とundo stateを操作前へ戻してエラーにする。
- archive handlerは不存在を成功扱いにせず、delete handlerだけをidempotentな不存在成功とした。出力schemaもarchiveは`archived`、deleteは`missing`へ固定し、handlerが別状態を返してもBrokerが成功扱いしない。
- 既存UIは今回まだBrokerへ移行していない。今回のCapabilityは既存UIと同じStoreを使うが、現行productionのText / Voice / Pocket App経路からdeleteは公開していない。

## 共通契約

- Golden Capability Registryへ、前のCalculator実装で未反映だった`calculator.expression.evaluate@1`と、今回のSticky 3 descriptorを追加した。
- runtime inventoryは15 descriptor / 14 handler。
- contract corpusは12 schema / 56 fixture。2回生成したJSON reportはbyte-for-byte一致した。

## ローカル検証

```text
swift build -Xswiftc -warnings-as-errors
  PASS

.build/debug/HoverPocket --verify-capabilities
  capability_verify=ok
  capability_handlers=14
  capability_sticky_lifecycle=ok

.build/debug/HoverPocket --verify-broker
  broker_verify=ok
  broker_registry_descriptors=15
  broker_available_handlers=14
  broker_sticky_lifecycle=ok
  broker_today_focus=ok

.build/debug/HoverPocket --verify-timer
  timer_verify=ok

.build/debug/HoverPocket --verify-clipboard
  clipboard_verify=ok

python3 script/verify_pocket_contracts.py
  PASS hoverpocket.pocket/v1: schemas=12 fixtures=56 matched=56
  2 report byte一致

git diff --check
  PASS
```

macOS verifierは、archive/delete、実行後status readback、永続化、invalid UUID拒否、archive/delete保存失敗時rollback、削除後不存在を確認する。Windowsにも同じ検証を追加したが、このMacには.NET SDKがないため、Windows Release buildと実行はPR CIの必須gateとする。

## Security readback

- scan ID: `9f03efcd-fbd3-4799-a5fd-c591a9ee1219`
- exact range: `8d7127f60dd94cc75df020970c1380359c835732...dd914488d5f954f3fd7dd3635f019a0d9dce9323`
- changed source review: 12 / 12
- reportable findings: 0
- status: sealed complete

`sticky.delete`は別permission、digest-bound TTL approval、single-use grant、UUID検証、atomic persistence、readbackを持つ。一方、現行production入口はToday Focusだけでdelete planを作成せず、`sticky.delete`権限も付与しない。将来AN4 / AN5でVoice、生成Pocket App、MCP等へ公開する前に、対象メモをHostが解決してユーザーへ表示する承認契約と、`strong_per_call`を通常承認から分ける固有制約を実装・再監査する。これは現行到達不能のためfindingではなくdeferred gateとして記録した。

## 未完了

- Sticky既存UIのBroker移行。
- `sticky.delete`を外部入力経路へ公開する前のtarget-specific approvalとstrong-per-call hardening。
- AN3実音声E2E、AN4 DSL Renderer回収、AN5以降の生成・sandbox・MCP / Connector・配布gate。

## GitHub Actions / PR readback

- implementation commit: `dd914488d5f954f3fd7dd3635f019a0d9dce9323`
- Draft PR: [#11](https://github.com/shotaro311/hover-pocket/pull/11)
- Windows run: [31854456305](https://github.com/shotaro311/hover-pocket/actions/runs/31854456305) `SUCCESS`
  - .NET 10 Release build、Capability、Broker、Timer、UI model、Updater、rendered WebView UIが成功した。
- macOS run: [31854456232](https://github.com/shotaro311/hover-pocket/actions/runs/31854456232) `SUCCESS`
  - Swift build、Capability 14 handler、Broker 15 descriptor / 14 handler、Sticky lifecycle、Today Focus、Timerが成功した。
- Pocket contract run: [31854456221](https://github.com/shotaro311/hover-pocket/actions/runs/31854456221) `SUCCESS`
  - Ubuntu / macOS / Windows 56 fixtureとcross-OS report byte比較が成功した。
- PR Router run: [31854456370](https://github.com/shotaro311/hover-pocket/actions/runs/31854456370) `SUCCESS`
- review thread 0、`MERGEABLE / CLEAN`。

## Merge readback

- final PR head: `bda78d8ad39a5f08d4930f441841ffac50e32adb`
- final Windows run: [31854634564](https://github.com/shotaro311/hover-pocket/actions/runs/31854634564) `SUCCESS`
- final macOS run: [31854634576](https://github.com/shotaro311/hover-pocket/actions/runs/31854634576) `SUCCESS`
- final Pocket contract run: [31854634592](https://github.com/shotaro311/hover-pocket/actions/runs/31854634592) `SUCCESS`
- final PR Router run: [31854643283](https://github.com/shotaro311/hover-pocket/actions/runs/31854643283) `SUCCESS`
- PR #11をReady化し、review thread 0、`MERGEABLE / CLEAN`のreadback後にmergeした。
- merge commit: `4640f5cf42ae18546de2b9f8bf4ba1b680fb6a55`
- merge後のmain / origin/mainは上記SHAで一致し、ahead / behindは`0 / 0`だった。
