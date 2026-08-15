# HoverPocket AI-native AN5-A Pocket App Lifecycle Foundation

## 結論

AN5の前半として、Codexが生成するPocket App draftを安全に受け入れるためのHost側ライフサイクル基盤をmacOS / Windowsへ実装した。draftをlive app directoryへ直接導入せず、Host所有snapshotで検証、tests、preview、権限差分、承認、immutable install、更新、無効化、保持削除、rollback、readbackを決定論的に扱う。

AN5全体はまだ完了ではない。Codexへの生成依頼、Host preview / 導入確認 / 管理UI、production入口への接続はAN5-Bに残す。

## Git / Pro回収

- base main: `2cd51b9d09dd50c00150b62be5175a56ff808e0f`
- branch: `codex/ai-native-an5-generator-install`
- worktree: `/Users/shotaro/code/share/hover-menu-preview-ai-native-an5`
- PR: [#16](https://github.com/shotaro311/hover-pocket/pull/16)
- source head: `3003bb908848cace06a06c3f08af47fd5eecf2a0`
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
- 期限切れapprovalはapprove、install、次のstage開始の各境界でrequestに紐づくstaging snapshot、pending state、grantを回収する。
- Windowsはprocess-wide lifecycle lockで複数managerからのactivate / disable / removeを直列化する。macOSは`@MainActor`で同じ直列化境界を持つ。
- 起動時はtombstone復元直後だけでなく、すべての既存final snapshotへimmutable属性を再適用してreadbackする。復元直後に異常終了した場合も、次の起動で再保護される。

### Stable key

- package-controlled `stableKey`を長さと文字種が有限のgrammarへ制限する。
- macOS / Windowsともtrue end-of-string anchorを使い、ASCII制御文字と末尾改行を明示的に拒否する。
- 表示用に別の見かけ値へ変換せず、承認表示、plan digest、Provider実行、readback対象を同じcanonical値へ固定する。

## 検証

ローカルMac:

- `swift build -Xswiftc -warnings-as-errors`: 成功
- `HoverPocket --verify-pocket-app`: package / bundled / negative 13件 / lifecycle成功。期限切れcleanup、複数manager競合、tombstone復元、反復起動時の再保護を含む
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
- このMacには.NET SDKがないためローカル実行は未実施した。PR source head `3003bb9`のWindows run [31896377388](https://github.com/shotaro311/hover-pocket/actions/runs/31896377388)でRelease buildとPocket App lifecycleを含む既存verifierが成功した。

GitHub Actions:

- Windows verify [31896377388](https://github.com/shotaro311/hover-pocket/actions/runs/31896377388): 成功
- macOS verify [31896377398](https://github.com/shotaro311/hover-pocket/actions/runs/31896377398): 成功
- Pocket contracts [31896377387](https://github.com/shotaro311/hover-pocket/actions/runs/31896377387): Ubuntu / macOS / Windowsとcross-OS report比較が成功
- PR Router [31896377423](https://github.com/shotaro311/hover-pocket/actions/runs/31896377423): 成功

最初のPR head `aa6e8e2`では、macOS CIだけがimmutable化した一時フォルダを最終名へ移動できず失敗した。最終headでは、検証済みprivate treeを先に最終digest pathへatomic moveし、直後にimmutable化してreadbackする順序へ両OSを統一した。hardeningまたはreadbackが失敗した場合は、この操作が移動したfinal treeをmutable化してcleanupし、active recordは更新しない。

## Security readback

初回implementation range `2cd51b9d09dd50c00150b62be5175a56ff808e0f...2efac67e77fddc7eae4c5dbd214019873d93c680`をCodex Security diff scan `5b314036-2b06-4806-844b-48f65c503fc9`で検査した。reviewで見つかった不足を補完した後、exact follow-up range `38aaf88212b8afe5405c877ed262eff27ab2a857...0289f152683bf2b8fee1ff33f40768f178cf883f`をscan `b2698e1d-350b-4975-bed3-33d71de87ad4`で再検査した。

- follow-up changed file: 4 / 4 reviewed
- reportable finding: 0
- deferred: 0
- coverage: complete / sealed complete
- oversized SemVerのdowngrade誤分類: 両OSの任意長比較と回帰testで解消
- tombstone復元後の異常終了で通常final treeがmutableのまま残る候補: 起動ごとの再保護と反復起動testで解消

既知のdestination root pathname TOCTOUは今回のfollow-upで悪化しておらず、現行production経路から到達しないため新規findingには含めていない。Lifecycle ManagerをUI、Voice、Pocket App、MCP、WebViewへ接続する前に、macOSではno-follow descriptor、Windowsでは検証済みdirectory handle相当で保存先rootを固定し、symlink / reparse race testを通す。

最終レビューhardeningでは、承認preview実byteの再digest、grantのrequest ID binding、remove recordのdurable sync、manager破棄時のstaging cleanup、両OSstable keyのtrue-end anchorを追加した。exact range `16e7cda162653749c07c125f3e662477687f3153...88f41bd988b5dc2426afdf72fc9b48770f35db58`のscan `f62b2099-b34d-4ce9-8609-5f514aa90358`は5 / 5 file、`88f41bd988b5dc2426afdf72fc9b48770f35db58...3003bb908848cace06a06c3f08af47fd5eecf2a0`のscan `38a3798b-2171-4980-9db7-59492e69c7ff`は1 / 1 fileを完全レビューし、どちらもfinding 0でsealed completeとなった。

## 残り

- PR #16はReady、全CI成功、未解決review thread 0、`MERGEABLE / CLEAN`、`needs-human-merge`付き。人間によるmerge判断は未実施。
- AN5-B: user requestからCodex draft生成、Host preview、権限差分表示、導入確認、version管理UIへの接続。
- production composition前のdestination root pinningと両OSrace test。
- AN3のWindows実音声E2Eは別の実機gateとして継続する。
