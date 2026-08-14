# HoverPocket Pocket Contracts v1

AN0のmacOS / Windows共通machine contractである。runtime実装ではなく、後続のSwift / C#実装が共有する受理・拒否境界を定義する。

## Contract documents

| Schema | Purpose |
|---|---|
| `capability-descriptor.schema.json` | Capability ID、major version、effect、permission、approval、limit、input/output、readback |
| `invocation.schema.json` | UI / Voice / Text / Surface / MCP / Connector共通呼び出し |
| `execution-plan.schema.json` | route-independent canonical plan |
| `approval-request.schema.json` | Broker-owned、digest-bound、single-use approval prompt data |
| `receipt.schema.json` | execution、readback、rollback、safe errorの共通結果 |
| `error.schema.json` | stable redacted error |
| `voice-lane-state.schema.json` | Host-owned Compact / Expanded state |
| `agent-session-summary.schema.json` | current-root-scoped session card |
| `voice-transcript-event.schema.json` | bounded memory-only transcript event |
| `pocket-app.schema.json` | user-owned app manifestとworkspace boundary |
| `pocket-surface.schema.json` | finite declarative ProviderHost surface |
| `pocket-workflow.schema.json` | finite typed workflow |

全schemaはDraft 2020-12と`hoverpocket://schemas/.../v1` IDを使用する。objectは`additionalProperties`を必ず明示し、未知fieldを暗黙受理しない。

## Fixture contract

- `fixtures/valid/`: schemaとHost invariantの両方を満たす。
- `fixtures/invalid/`: fail-closedで拒否し、期待するstable error codeを持つ。
- `fixtures/golden/`: Registry、geometry、audit redaction、canonical JSON、error code setの正本。
- `fixtures/expected-results.json`: 全fixtureの一意なmanifestと期待結果。

AN0のreference corpusは1つのPocket App package contextとして検査する。manifestが列挙する全ファイルはsource byte digestへbindingし、Surface / Workflowの実fixture、requested Capability、scope、Surface query、Workflow stepが一致しなければ拒否する。`asset://`は正規化済みpackage内pathだけを許し、生成SurfaceはHost-owned receiptを描画できない。

Golden digestはUTF-8、key sort、空白なしのcanonical JSONに対するSHA-256である。file改行やOS path separatorには依存しない。reject fixtureもfixture本文のdigest、stable error code、exact error locationを固定する。execution planはtopological orderを正本とし、route固有のID、時刻、origin、principal、idempotency keyをcanonical plan digestへ含めない。Pocket App ID / version / manifest digestはplan digestへ含め、invocation、approval、receiptまで同じcontextへbindingする。

`native_authority` / `runtime_prohibited` CapabilityはRegistryへ記述できても、Invocation、ExecutionPlan、PocketWorkflowの全実行経路で共通fail-closed gateが拒否する。descriptorの`maxPayloadBytes`とPocket App scopeも同じ3経路で強制する。

成功receiptの`verified`は呼び出し元の自己申告ではない。Host-owned observation fixtureと一致するtyped `observed`を検証し、そのcanonical digestをverifierが再計算し、descriptorの`readback.match`で実行outputと照合する。auditは既知Invocation、descriptor、App context、入力digest、Host-owned readback digestへbindingする。固定shape、opaque ID、不可逆principal pseudonymだけを許し、key名だけでなく値に含まれるpath、URL、email、credential様文字列も拒否する。

PocketWorkflow v1の動的bindingはtop-levelの`$input.<name>`と、Host型付きcontextの`$context.today` / `$context.selectedEvent.title`に限定する。未知またはnested bindingはfail closedで拒否する。

## Verification

macOS / Linux:

```sh
python3 script/verify_pocket_contracts.py
```

Windows:

```powershell
py -3 script/verify_pocket_contracts.py
```

Machine-readable report:

```sh
python3 script/verify_pocket_contracts.py --report-json pocket-contracts-report.json --quiet
```

Validatorは外部library、package manager、network、secret、環境値を使用しない。未知schema keyword、未解決`$ref`、重複JSON key、非有限数、unknown capability、version mismatch、semantic invariant違反を成功扱いにしない。CIは固定OS / Python / Action revisionで3OS reportを生成し、最後にbyte-for-byte一致を確認する。
