# HoverPocket AI-native Strong Approval Isolation

## 結論

`strong_per_call`に分類した削除操作を、他の操作と同じ計画へまとめて承認できないようにした。macOS、Windows、共有JSON契約のすべてで、強い承認が必要なCapabilityを含むplanは1stepだけ許可する。単独削除の既存approval、idempotency、実行、missing readbackは維持する。

## 実装

- 基準main: `56607cf751e15ec24ff09746f5fb447331515508`
- source head: `bcbf7b017cdee485cfe7f668a7fecd247f2be2de`
- branch: `codex/ai-native-strong-approval`
- PR: [#12](https://github.com/shotaro311/hover-pocket/pull/12)

変更内容:

- macOS `CapabilityBroker`は、descriptorのpermission unionがplan宣言と一致した後、`strong_per_call`を含む複数step planを`CAPABILITY_PLAN_INVALID / strong_per_call`で拒否する。
- Windows `CapabilityBroker`も同じ順序とerror fieldで拒否する。
- prepareだけでなくexecuteも同じvalidatorを通るため、承認後の別plan差し替えでは実行できない。
- macOS / Windows verifierへ`sticky.note.status`と`sticky.note.delete`を同じplanへ入れたnegative caseを追加した。
- 共通contractへ`PLAN_APPROVAL_REQUIRED`、`$.steps[0].capability`で拒否するfixtureを追加し、57件へ更新した。
- 共有contractのPocket App requested Capability、range、namespace検査は無条件のまま維持した。

## 検証

ローカルMac:

- `swift build -Xswiftc -warnings-as-errors`: 成功
- `HoverPocket --verify-broker`: 15 descriptor / 14 handler、negative 11件、Sticky lifecycle / Today Focus / duplicate replay成功
- `HoverPocket --verify-capabilities`: 14 handler成功
- `HoverPocket --verify-timer`: 成功
- `HoverPocket --verify-clipboard`: 成功
- Pocket contracts: 12 schema / 57 fixture、2回成功、report byte一致
- `git diff --check`: 成功

GitHub Actions（source head `bcbf7b0`）:

- Windows: [31856092749](https://github.com/shotaro311/hover-pocket/actions/runs/31856092749) 成功
- macOS: [31856092697](https://github.com/shotaro311/hover-pocket/actions/runs/31856092697) 成功
- Pocket contracts: [31856092742](https://github.com/shotaro311/hover-pocket/actions/runs/31856092742) 成功
- Ubuntu / macOS / Windows report byte比較: 成功
- PR Router: [31856092669](https://github.com/shotaro311/hover-pocket/actions/runs/31856092669) 成功

## Security readback

初回source head `67fee14`のdiff scan `965505c2-53d2-4fd4-8b2e-59dcf8f40abd`は、共通contract verifierだけでHost-native planのPocket App scope検査を省く一般化を候補化した。これはproduction runtimeへ到達せず、現行Pocket App principalもappContextを省略できないためreportable findingにはならなかったが、security assurance低下として採用せず`bcbf7b0`で撤回した。

最終source range `56607cf...bcbf7b0`のscan `c0238875-7481-4226-8a22-eccdb874226d`は次をreadbackした。

- model: GPT-5.6 Sol / xhigh
- changed source: 5 / 5 reviewed
- contract fixture / manifest: 2 / 2 reviewed
- coverage: complete
- reportable finding: 0
- sealed: `2026-08-15T01:16:38.052661Z`
- tokens: 27,378

## 残る境界

- `sticky.note.delete@1`は現在のproduction Voice、生成Pocket App、MCPへ公開していない。
- 将来公開する前に、Host所有UIで対象メモを内容漏えいなく特定できる表示を追加し、同じ対象と引数がapproval digestへ結び付くことを両OS UI testで確認する。
- 生成UIへraw note本文、raw identifier、provider store参照を渡さない。
- WindowsはローカルMacに.NET SDKがないため、実行検証の正本はPR CIとWindows実機gateである。

## 次の完了条件

- 進捗文書追加後のPR headで全GitHub Actions成功。
- unresolved review thread 0、MERGEABLE / CLEAN。
- PR #12をmergeし、`main == origin/main`、ahead / behind `0 / 0`をreadbackする。
