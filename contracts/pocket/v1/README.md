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

AN0のreference corpusは1つのPocket App package contextとして検査し、manifestのSurface / Workflow ID、requested Capability、Surface query、Workflow stepの相互参照が一致しなければ拒否する。

Golden digestはUTF-8、key sort、空白なしのcanonical JSONに対するSHA-256である。file改行やOS path separatorには依存しない。execution planはtopological orderを正本とし、route固有のID、時刻、origin、principal、idempotency keyをcanonical plan digestへ含めない。approvalは同digestとprincipalへ別途bindingする。

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

Validatorは外部library、package manager、network、secret、環境値を使用しない。未知schema keyword、未解決`$ref`、重複JSON key、非有限数、unknown capability、version mismatch、semantic invariant違反を成功扱いにしない。
