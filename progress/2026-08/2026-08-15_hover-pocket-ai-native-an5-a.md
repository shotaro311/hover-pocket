# HoverPocket AI-native AN5-A Pocket App Lifecycle Foundation

## 結論

AN5の前半として、Codexが生成するPocket App draftを安全に受け入れるためのHost側ライフサイクル基盤をmacOS / Windowsへ実装した。draftをlive app directoryへ直接導入せず、Host所有snapshotで検証、tests、preview、権限差分、承認、immutable install、更新、無効化、保持削除、rollback、readbackを決定論的に扱う。

AN5全体はまだ完了ではない。Codexへの生成依頼、Host preview / 導入確認 / 管理UI、production入口への接続はAN5-Bに残す。

## Git / Pro回収

- base main: `2cd51b9d09dd50c00150b62be5175a56ff808e0f`
- branch: `codex/ai-native-an5-generator-install`
- worktree: `/Users/shotaro/code/share/hover-menu-preview-ai-native-an5`
- ChatGPT Pro Orchestrator generation 2: delivery `return-86ca754d9b618c814b0d87e2615c6b51`
- Pro返却はdelivery ID / state hash、receipt、base SHA、allowed path、artifact hashを検証してから適用した。Pro成果物を完了扱いせず、Codexが両OSの安全境界、回帰テスト、セキュリティ差分監査を追加した。

## 実装

### Snapshot / validate / preview

- untrusted draftをbounded inventoryで列挙し、symlink / reparse、非regular file、unsafe path、oversizeを拒否する。
- macOSはno-follow file descriptorとfile identity、Windowsはdirectory handleとfinal path確認を使ってsource byteを安定取得する。
- 取得したexact byteをHost所有staging snapshotへmaterializeし、parse / tests / preview / digest / installの入力を同じsnapshotへ固定する。
- package digest、preview digest、permission diff、実効Capability grant diff、current digestをapproval bindingへ含める。

### Install / update / rollback

- install、update、rollbackは権限増減の有無にかかわらず、exact binding digestへ結び付いた期限付きsingle-use Host approvalを必須にする。
- install先は`version / package digest / package`のimmutable snapshotとし、active recordのdurable writeと再読込後だけ成功receiptを返す。
- 現在の権限はmutableなactive recordではなく、active recordが指す検証済みimmutable packageから再構成する。
- 通常updateでのversion downgradeを拒否し、rollbackだけに分離する。version / directory / package digestが一致しないrollback対象は拒否する。
- numeric componentをmachine integerへ変換せず、任意長の数字列として比較する。64文字上限内の59桁versionから`1.0.0`へのdowngradeを両OSの回帰fixtureへ固定した。

### Disable / remove / recovery

- disableはimmutable versionsとユーザーデータを残し、active stateだけをdisabledへ切り替える。
- AN5-Aのremoveは`preserve`だけを許可し、ユーザーデータ削除は拒否する。
- preserve removeはVersionsを同一app root内のtombstoneへ移動し、removed stateのdurable write後だけcleanupする。書込み失敗時はtombstoneをVersionsへ戻す。
- 起動時recoveryはactive stateをreadbackし、removedならtombstoneをcleanup、それ以外ならVersionsへ復元する。

### Stable key

- package-controlled `stableKey`を長さと文字種が有限のgrammarへ制限する。
- 表示用に別の見かけ値へ変換せず、承認表示、plan digest、Provider実行、readback対象を同じcanonical値へ固定する。

## 検証

ローカルMac:

- `swift build -Xswiftc -warnings-as-errors`: 成功
- `HoverPocket --verify-pocket-app`: package / bundled / negative 10件 / lifecycle成功
- `HoverPocket --verify-pocket-surface`: 成功、negative 13件
- `HoverPocket --verify-capabilities`: 14 handler成功
- `HoverPocket --verify-broker`: 15 descriptor / 14 handler、negative 11件成功
- `HoverPocket --verify-panel-layout`: 128件成功
- Timer / Calculator / Clipboard / Weather verifier: 成功
- `python3 script/verify_pocket_contracts.py`: 12 schema / 57 fixture成功
- `python3 -m py_compile script/verify_pocket_contracts.py`: 成功
- `git diff --check`: 成功

Windows:

- macOSと同じLifecycle Manager、任意長version比較、59桁downgrade verifierを実装した。
- このMacには.NET SDKがないためローカル実行は未実施。PRのWindows Release buildとPocket App verifierを必須gateとする。

## Security readback

最終working-tree digest `codex-security-snapshot/v1:sha256:37f697dd6b046607687f7d4214efa2cd91af4d589fc71b8af257987dbbd03ff6`をCodex Security diff scan `8c157a4d-3351-4531-bb2e-fc8815d6a462`で検査した。

- changed file: 21 / 21 reviewed
- reportable finding: 0
- status: sealed complete
- oversized SemVerのdowngrade誤分類: 両OSの任意長比較と回帰testで解消
- deferred: lifecycle destination rootのpathname TOCTOU

deferred項目は現行production経路から到達しない。Lifecycle ManagerをUI、Voice、Pocket App、MCP、WebViewへ接続する前に、macOSではno-follow descriptor、Windowsでは検証済みdirectory handle相当で保存先rootを固定し、symlink / reparse race testを通す。

## 残り

- Ready PR作成とWindows / macOS / Pocket contract CIのreadback。
- AN5-B: user requestからCodex draft生成、Host preview、権限差分表示、導入確認、version管理UIへの接続。
- production composition前のdestination root pinningと両OSrace test。
- AN3のWindows実音声E2Eは別の実機gateとして継続する。
