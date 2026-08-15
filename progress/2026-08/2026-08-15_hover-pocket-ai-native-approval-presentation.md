# HoverPocket AI-native Host-owned Approval Presentation

## Outcome

- branch: `codex/ai-native-approval-presentation`
- implementation commit: `4f6c2017d45b0668ec4cc6096650eb9db32bba47`
- base: `da0d5b6a13886d296cbabe7781d55fe71649709f`
- security scan: `6d4c59cd-c0e9-49bf-9afc-d6c8e4f5ab32`
- security result: coverage complete / reportable finding 0

## Implemented

- macOS / WindowsへHost-memory-onlyの`CapabilityApprovalPresentation`を追加した。
- `sticky.note.delete@1`の対象を共有Sticky StoreからHostが解決する。
- presentationをrequest ID、plan digest、step ID、argument digest、destructive effect、rollback availabilityへ結合する。
- 対象タイトルから空白・改行・control / format / bidirectional文字を除去し、80 Unicode scalar / rune以内へ制限する。
- 対象が存在しない場合はraw IDを表示せず`missing`状態を返す。
- `strong_per_call`でpresentationが欠落・不正・解決失敗した場合はpending approvalを破棄し、実行前にfail closedにする。
- presentationはCodable / JSON contractへ含めず、audit、durable ledger、receipt、Surface、transcriptへ保存しない。

## Validation

- Swift warnings-as-errors build: pass
- Broker verifier: 15 descriptor / 14 handler、approval presentation、negative 12件 pass
- Capability verifier: pass
- Timer / Clipboard / Calculator verifier: pass
- Panel layout: 112件 pass
- Pocket contract: 12 schema / 57 fixture、2回のreportがbyte一致
- `git diff --check`: pass
- Windows local build: .NET SDKがこのMacにないため未実施。PR CIを必須gateとする。

## Security Review

- exact source range `da0d5b6...4f6c201`、変更source 12 / 12を確認した。
- Host UI表示の証明がBroker grantへ含まれない候補は、現行productionで`DecideApproval`へ到達する外部・生成・Voice・MCP経路がなく、Today Focusはnative確認表示と限定permissionを使うためsuppressedとした。
- private target UUIDをplan/idempotency metadataへ符号化できる候補は、保存挙動がbaseから存在し、今回の差分が新しいsinkや外部plannerを追加していないためnot applicableとした。
- 将来のgenerated Pocket App / Voice / MCPでは、Brokerのapproval decision APIを公開せず、plan/idempotency metadata IDをHost生成へ固定する。

## Pro Orchestrator / AN4

- 初回AN4 patchはexact baseへ`git apply --check`できたが、許可外path `contracts/pocket-surface/**`、`Tests/HoverPocketTests/**`、`tools/pocket-surface-windows-verifier/**`を含み、必須`implementation-notes.md`も欠落していたため適用しなかった。
- 同じAN4 exact headに対し、既存pathへ統合してpatchとnotesを再生成する1回限りの修正依頼を送信した。
- 自動回収が完了するまで、AN4 worktreeへ変更を適用しない。

## Next Gates

1. このbranchをReady PRにし、macOS / Windows / Pocket contract CIを確認する。
2. review thread 0、head SHA一致、mergeabilityをreadbackする。
3. AN4 Pro修正版をclaim / receipt検証後だけexact worktreeへ適用する。
4. AN4 DSL / rendererをローカル・CI・security reviewまで通す。
