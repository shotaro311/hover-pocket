# HoverPocket AI-native AN4 Pocket App DSL / Renderer

## 結論

AN4のPocket App DSL、汎用Renderer、宣言型Today Focus packageをmacOS / Windowsへ実装した。生成UIはProvider Storeへ直接触れず、Calendar read、Timer start、Sticky upsertを既存UIと同じCapability Registry / Broker経由で実行する。実装head `5eb528fa63e4d4233f254cea2eac4e3cc0e6867a`はローカル検証と全GitHub Actionsに合格し、PR #14は`MERGEABLE / CLEAN`である。

## Git / Pro回収

- base main: `da0d5b6`
- branch: `codex/ai-native-an4-dsl-renderer`
- worktree: `/Users/shotaro/code/share/hover-menu-preview-ai-native-an4`
- PR: [#14](https://github.com/shotaro311/hover-pocket/pull/14)
- implementation head: `5eb528fa63e4d4233f254cea2eac4e3cc0e6867a`
- ChatGPT Pro Orchestratorの返却は、bridgeのdelivery ID / state hash、receipt、base SHA、allowed path、artifact hashを確認した後だけ適用した。重複通知は再適用していない。
- Pro成果物をそのまま完了扱いにせず、Codexが両OSのbuild、共通contract、package digest、approval / execution、receipt / readback、安全境界を再検証して補完した。

## 実装

### Package / DSL

- `manifest.json`、intent、state schema、Surface、workflow、testsをファイルとして保持する。
- manifestに列挙したexact file closureだけを受け入れ、unknown file、unsafe relative path、symlink / reparse、非regular file、oversizeを拒否する。
- package digestはdomain separator、正規化path、NUL、各file raw byte SHA-256を順序付きで束ねる。両OSのgolden digestは `sha256:e9c369e0b52620d95c14baa2e04070535a1f21020308090f0467eed8cf4f04df`。
- unknown component / query / workflow / Capability、循環・未解決binding、scope逸脱、unbounded payloadをfail closedにする。

### Renderer / state

- macOSはSwiftUI、Windowsはbundled DOM rendererで同じ有限component treeを描画する。
- Surfaceはstate keyのallowlistとsize上限だけを利用し、Calendar / Timer / StickyのStoreを直接参照しない。
- user stateはpackage定義から分離したHost所有保存先へatomicに保存し、Surfaceを再生成してもintentとdataを維持できる。
- WindowsはtextContentとHost sanitizerを使い、生成値をHTMLとして解釈しない。

### Workflow / Broker

- Today Focus packageは今日のCalendar予定を読み、選択予定に合わせたTimerと今日の目的のSticky upsertをplan化する。
- workflow executionはpresentable allowlistに限定し、Timer startとSticky upsertだけを許可する。
- title / bodyをplan作成前にcanonical化し、承認表示、plan digest、実行引数を一致させる。
- 成功summaryはpackageの固定文ではなく、実Capability receiptとverified readbackからHostが生成する。途中step失敗やreadback不一致では成功表示を返さない。

## 検証

ローカルMac:

- `swift build -Xswiftc -warnings-as-errors`: 成功
- `swift run HoverPocket --verify-broker`: 成功
- `swift run HoverPocket --verify-pocket-app`: 成功
- `swift run HoverPocket --verify-pocket-surface`: 成功
- `swift run HoverPocket --verify-panel-layout`: 成功
- `python3 script/verify_pocket_contracts.py --root .`: 12 schema / 57 fixture成功
- Windows UI JavaScript syntax: 成功
- `git diff --check`: 成功

GitHub Actions（head `5eb528f`）:

- PR Router [31883742762](https://github.com/shotaro311/hover-pocket/actions/runs/31883742762): 成功
- Pocket contracts [31883743720](https://github.com/shotaro311/hover-pocket/actions/runs/31883743720): Ubuntu / macOS / Windowsとcross-OS byte比較が成功
- Windows [31883743792](https://github.com/shotaro311/hover-pocket/actions/runs/31883743792): 成功
- macOS [31883743784](https://github.com/shotaro311/hover-pocket/actions/runs/31883743784): 成功

Windowsローカル実行はこのMacに.NET SDKがないため未実施し、PR CIを受入証拠にした。

## Security readback

exact hardening range `341db0a26bc8eecd72b43aefab124cf08508c711...5eb528fa63e4d4233f254cea2eac4e3cc0e6867a`をCodex Security diff scan `d6d90a84-3a8e-4b34-882a-a03f0c3d0c09`で検査した。

- model: GPT-5.6 Sol / xhigh
- changed file: 11 / 11 reviewed
- reportable finding: 0
- status: sealed complete
- manifest sealedAt: `2026-08-15T12:23:49.773365Z`
- current product coverage: 全変更surfaceをレビュー済み

次の4項目は現行の固定内蔵Today Focus packageから到達せず、AN5の生成 / import / install surfaceを開いた時だけ成立するためdeferredとした。

1. macOS / Windowsでpackage-controlled `stableKey`のcontrol / bidi文字が承認表示を誤認させる可能性。
2. macOS / Windowsでwritable staging packageをinventory後に差し替えるTOCTOUの可能性。

## AN5への必須gate

- 外部生成packageをlive directoryへ直接書かない。
- stagingからHost所有immutable snapshotへ、symlink / reparseを辿らず、stable file identityを保ってatomicに取り込む。
- 検証したexact byte snapshotだけをparse / preview / activateする。macOSのsecurity-bound inputはmapped readにしない。
- `stableKey`は安全な有限grammarと上限を持つexact execution valueにするか、Host所有のcanonical表示へ結び付ける。
- control / bidi / 長文fixtureで、承認表示、plan digest、実行値、readback対象が一致することを両OSで検証する。
- このgateが通るまで生成 / import packageをactivateしない。

## 残件

- PR #14をReady化し、最終headの全check、未解決review thread 0、mergeabilityを再readbackしてmainへ統合する。
- AN5でCodex生成、検証、preview、permission diff、atomic install、disable / remove / rollbackへ進む。
- AN3のWindowsユーザー発話とProvider live E2Eは別branchの実機gateとして残る。
