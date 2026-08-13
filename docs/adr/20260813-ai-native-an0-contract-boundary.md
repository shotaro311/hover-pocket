# ADR: AI-native AN0 共通契約境界

- Status: Accepted
- Date: 2026-08-13
- Base: `8b636cae86104b1d3b589237d73ffd0f4ad9ee79`
- Scope: AN0（ADR、versioned JSON contracts、fixture、contract verifier、CI）のみ

## Context

HoverPocketの既存UI、Voice、Text、生成Pocket App、MCP Adapterが別々の実行経路を持つと、権限、承認、idempotency、readback、監査、OS差分が入力面ごとに分岐する。macOSのSwift実装とWindowsのC#実装はOS固有資産を維持しつつ、同じ契約と期待結果を共有する必要がある。

AN0はruntime behaviorを変更せず、後続AN1以降が依存する境界だけを固定する。既存Provider Registry、保存形式、UI、requirements、PLAN1、progress、承認画像は変更しない。

## Decision

### 1. RegistryとBrokerを実行正本にする

`PocketCapability`のID、major version、input/output schema、effect、permission、approval、idempotency、availability、limit、readbackを`CapabilityRegistry`の正本とする。すべての実行は`CapabilityBroker`を通す。MCP、Voice、Text、Native UI、PocketSurfaceは入力Adapterであり、Provider StoreやOS操作を直接呼ばない。

LLM、生成UI、呼び出し元は承認済み状態を自己申告できない。`invocation`契約に`approved`やgrant/tokenのfieldを設けず、approvalはBrokerがplan digest、principal、effect、引数digest、期限、nonceへbindingする。

### 2. 12個のversioned JSON契約を共有する

`contracts/pocket/v1/`に次の12 schemaを置く。

1. `capability-descriptor.schema.json`
2. `invocation.schema.json`
3. `execution-plan.schema.json`
4. `approval-request.schema.json`
5. `receipt.schema.json`
6. `error.schema.json`
7. `voice-lane-state.schema.json`
8. `agent-session-summary.schema.json`
9. `voice-transcript-event.schema.json`
10. `pocket-app.schema.json`
11. `pocket-surface.schema.json`
12. `pocket-workflow.schema.json`

全schemaはJSON Schema Draft 2020-12、安定した`hoverpocket://schemas/.../v1` ID、明示的な`additionalProperties`を使う。v1のobjectはfieldを暗黙受理しない。breaking changeはmajor versionとschema IDを上げる。platform差は同じCapability IDを維持し、availabilityとstable safe errorで表す。

### 3. Schemaだけで表せないHost invariantをsemantic gateで検証する

`script/verify_pocket_contracts.py`はPython標準ライブラリだけで動作し、使用中のDraft 2020-12語彙を明示的に実装する。未知のschema keyword、未解決`$ref`、重複JSON key、非有限数、追加fieldを成功扱いにしない。

Schema validation後、次を決定論的に検証する。

- RegistryにないCapabilityと未対応major versionを区別して拒否する。
- Capability引数とreceipt outputをdescriptor内schemaで再検証する。
- planをtopological orderで固定し、dependency、permission union、write approval、canonical digestを検証する。canonical digestは入力経路ごとに変わるplan ID、時刻、origin、principal、idempotency keyを除外し、Capability、引数、依存、approval、permissionだけを正規化する。approvalはprincipalへ別途bindingする。
- approvalをplan、principal、write effect、argument digest、10分以内の期限へbindingする。
- side effectの成功はdescriptorどおりのverified readbackがある場合だけ許可する。
- Pocket Appのpath traversal、権限参照、workspace ownership、secret境界を検証し、reference app、Surface、Workflow、requested Capabilityのfixture相互参照を同じpackage contextとして照合する。
- PocketSurfaceのcomponent数・深さ・query/workflow参照を有限化する。
- PocketWorkflowのCapability参照、topological dependency、input type、approval、limitを検証する。v1の動的bindingはtop-levelの`$input.<name>`と、Today FocusでHostが型を保証する`$context.today` / `$context.selectedEvent.title`だけを許可し、未知・nested bindingを拒否する。
- Voice session cardを現在rootとそのchild/descendantへ限定する。
- auditをmetadata/digestだけに限定し、禁止fieldを再帰的に拒否する。
- geometryのShell top、Header、ProviderHost、下方向拡張、非overlap、fullscreen禁止を数値fixtureで検証する。

検証器自身が理解できない項目はfail closedとする。ネットワーク、package manager、外部library、secret、環境依存値は使用しない。出力reportには時刻や絶対pathを入れず、同じ入力から同じbyte列を生成する。

### 4. permission、error、readbackをHost契約に含める

Effectと既定policyを次で固定する。

| Effect | Approval | Idempotency |
|---|---|---|
| `pure` | `none` | `not_applicable`または`optional` |
| `private_read` | `permission_grant` | `not_applicable`または`optional` |
| `reversible_local_write` | `broker_policy` | `required` |
| `external_write` | `per_call` | `required` |
| `destructive_sensitive` | `strong_per_call` | `required` |
| `native_authority` | `runtime_prohibited` | `required` |

safe errorはstable code、retryability、message key、限定detailsだけを返す。raw exception、token、Authorization、filesystem path、process command lineを返さない。

副作用Capabilityは`readback.strategy=none`を使用できない。実行APIが成功してもreadbackが一致しなければ`succeeded`にしない。readback不能で副作用の有無が不明な場合は`unknown`等を返し、自動再送の根拠にしない。

### 5. Voice LaneはHost-owned bottom rowとして固定する

Voice LaneはProviderではなく、`Header + ProviderHost + VoiceLane`の最後のrowである。`disabled / compact / expanded`を持ち、明示controlだけで切り替える。Compactは視覚タイトルを持たず会話領域を優先する。Expandedは左transcript、右current-root-scoped session cardsとし、fullscreen、別Provider、overlayを禁止する。

Geometry tokenは次で固定する。

- Header: `54`
- Compact: `64`
- Expanded Small / Medium / Large / Extra Large: `190 / 220 / 250 / 280`
- Baseline: Windows `520x372 / 600x430 / 680x488`、macOSは追加で`760x546`

Extra Largeの`280`は、承認済み候補のSmallからLargeまでの30刻みを継続し、AN0で両OS共通fixtureとして固定した値である。画面高がExpandedに1 pointでも不足するfixtureでは、Providerを縮めずCompactへ戻す。

### 6. Voice/sessionと監査は最小データにする

Voice transcript eventはmemory-only、bounded、non-persistentとする。session summaryはtitle、状態、進捗、更新時刻、安全な要約だけを持ち、raw command、filesystem path、全文transcriptを持たない。

AuditはID、匿名化principal、Capability/effect、permission/approval decision、input digest、status、duration、retry/idempotency、readback/evidence digest、stable error codeだけを保存する。raw transcript、prompt、Calendar本文、Sticky本文、Clipboard本文、OAuth token、API key、Authorization、raw exception、path、command lineを保存しない。

### 7. Pocket App workspaceはユーザー所有にする

App定義とuser dataを分離し、workspaceはinspect/export/delete/rollback可能とする。secretはworkspaceへ置かずmacOS KeychainまたはWindows Credential Manager相当へ置く。canonical JSONを共通machine contractとし、Swift/C#は同じschemaとfixtureを別実装でdecode・validateする。

生成Pocket Appが描画できるのは`provider_host`内のdeclarative `PocketSurface`だけである。Header、Voice Lane、approval、receiptを生成UIへ委譲しない。arbitrary JavaScript、Swift、C#、shell、自由なfilesystem/network、unbounded recursionはv1に含めない。

### 8. Legacy AI command laneを分離する

Legacy AI command laneとCodex Voice Laneは別namespace、別要件、別migration対象とする。AN0は旧laneを再表示せず、runtime sourceにも接続しない。後続実装はLegacyのCalendar直結planner/connectorを新しい共通契約の正本として流用しない。

## Fixtures and deterministic result contract

`fixtures/expected-results.json`をfixture正本とする。manifestは全valid/invalid/golden JSONを重複なく列挙し、goldenはcanonical JSON digestを固定する。invalid fixtureは期待するstable rejection codeまで固定する。

必須negative caseには次を含める。

- unknown capability
- capability version mismatch
- extra property / caller-supplied approval
- cross-root session leak
- fullscreen Voice state
- succeeded receipt without verified readback
- Pocket App path traversal
- workflow unknown capability
- ProviderHost geometry mutation
- forbidden audit field

## Consequences

### Positive

- macOS SwiftとWindows C#が同じ受理・拒否結果を実装できる。
- UI、AI、Voice、MCP、Pocket Appでpermission、approval、readback、receiptの意味を共有できる。
- JSON Schemaで表現できないsecurity/privacy/UI invariantをfixtureとしてreviewできる。
- runtime behaviorを変えずにAN1以降の境界を先に固定できる。

### Costs

- 標準ライブラリvalidatorは汎用JSON Schema engineではなく、利用語彙を明示管理する必要がある。
- Schemaまたはsemantic rule追加時は、Python verifier、将来のSwift/C# validator、fixtureを同時更新する必要がある。
- arbitrary codeより表現力を意図的に制限する。

## AN0 exit gate

AN0は次をすべて満たした時だけ完了とする。

1. 12 schemaがDraft 2020-12、安定ID、strict object policyを満たす。
2. manifestの全fixtureが期待どおりpass/rejectし、reject codeも一致する。
3. 同じvalidatorを連続2回実行したJSON reportがbyte-for-byte一致する。
4. Ubuntu、macOS、WindowsのCIで標準Pythonだけを使って同じfixture結果になる。
5. `git diff --check`とbase SHAへの`git apply --check`が通る。
6. AN0の機能差分がADR、contracts、validator、専用CIだけである。リポジトリ運用規則に従う実施結果の`progress/`更新は、別commitの記録差分として許可する。
7. 既存macOS/Windows verifierはpatch適用先の実機・正式worktreeで回帰実行する。
8. runtime source、Provider Registry、既存data format、requirements、PLAN1、承認画像に変更がない。`progress/`は実装状態と検証証拠だけを更新し、契約判断を上書きしない。

標準実行:

```sh
python3 script/verify_pocket_contracts.py
python3 script/verify_pocket_contracts.py --report-json pocket-contracts-report.json --quiet
```

Windows:

```powershell
py -3 script/verify_pocket_contracts.py
py -3 script/verify_pocket_contracts.py --report-json pocket-contracts-report.json --quiet
```
