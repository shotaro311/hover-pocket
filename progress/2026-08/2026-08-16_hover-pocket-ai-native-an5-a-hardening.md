# HoverPocket AI-native AN5-A Final Hardening

## 結論

PR [#16](https://github.com/shotaro311/hover-pocket/pull/16)のPocket App lifecycle基盤を、承認期限切れ、複数manager競合、remove中断、起動時復旧まで含めて両OSでfail closedにした。AN5-AはReady、CI green、Codex Security finding 0の状態で、人間によるmerge待ちである。PRは自動mergeしていない。

## 最終source

- branch: `codex/ai-native-an5-generator-install`
- source head: `3003bb908848cace06a06c3f08af47fd5eecf2a0`
- Windows verify: [31896377388](https://github.com/shotaro311/hover-pocket/actions/runs/31896377388) 成功
- macOS verify: [31896377398](https://github.com/shotaro311/hover-pocket/actions/runs/31896377398) 成功
- Pocket contracts: [31896377387](https://github.com/shotaro311/hover-pocket/actions/runs/31896377387) でUbuntu / macOS / Windowsとcross-OS byte比較が成功
- PR Router: [31896377423](https://github.com/shotaro311/hover-pocket/actions/runs/31896377423) 成功
- unresolved review threads: 0
- merge state: `MERGEABLE / CLEAN`

## 追加hardening

- approval expiry時にrequestへ紐づくstaging snapshot、pending state、grantを回収する。
- Windowsの全lifecycle操作をprocess-wide lockで直列化し、別managerからのactivateとdisable / removeが古い状態を再投入しないようにした。
- preserve removeのtombstone復元直後にimmutable属性を再適用してreadbackする。
- さらに毎回の起動で、全既存final snapshotを再保護してreadbackする。tombstone rename後、再保護前に異常終了しても次回起動で回復する。
- macOS / Windows verifierへ期限切れ3経路、複数manager競合、tombstone復元、通常final treeの反復起動再保護を追加した。
- previewの実byte列をdefensive copyし、proposalとfresh packageのpreview digestをactivation直前に再計算する。
- approval grantをbinding digestだけでなくrequest IDにも結び付け、別requestでの流用失敗時に元grantを消費しない。
- macOSはactive record fileと親directoryをfsyncし、Windowsはwrite-through replace後にだけtombstone cleanupへ進む。
- manager破棄時にlive staging ownershipを解放し、pending stagingを削除する。
- stable keyは両OSでtrue end-of-string anchorを使い、ASCII制御文字と末尾改行を拒否する。

## ローカル検証

- `swift build -Xswiftc -warnings-as-errors`: 成功
- Pocket App / Surface / Capability / Broker / Panel layout / Timer / Calculator / Clipboard / Weather verifier: 成功
- Pocket App negative case: 13件成功
- Pocket contract: 12 schema / 57 fixtureを2回生成しbyte一致
- contract report SHA-256: `5239f573a8f703a4a40dcb1735b09795569cba8781eef6fd9e3d085474f557e5`
- `git diff --check`: 成功

## Security readback

exact range `38aaf88212b8afe5405c877ed262eff27ab2a857...0289f152683bf2b8fee1ff33f40768f178cf883f`をCodex Security diff scan `b2698e1d-350b-4975-bed3-33d71de87ad4`で再検査した。

- changed source: 4 / 4 reviewed
- coverage: complete
- reportable finding: 0
- deferred: 0
- status: sealed complete

前scanの「tombstone復元直後に異常終了すると通常final treeがmutableのまま残り得る」候補は、毎起動時の再保護と反復起動testで解消した。既知のdestination root pathname TOCTOUはこの差分で悪化しておらず、production composition前の別gateとして残す。

review follow-up range `16e7cda162653749c07c125f3e662477687f3153...88f41bd988b5dc2426afdf72fc9b48770f35db58`はscan `f62b2099-b34d-4ce9-8609-5f514aa90358`で5 / 5 file、最終stable key range `88f41bd988b5dc2426afdf72fc9b48770f35db58...3003bb908848cace06a06c3f08af47fd5eecf2a0`はscan `38a3798b-2171-4980-9db7-59492e69c7ff`で1 / 1 fileを完全レビューした。両scanともcoverage complete、reportable finding 0、sealed completeである。

## 次

- PR #16は人間によるmerge判断待ち。自動mergeしない。
- merge後はAN5-Bとして、Codex requestからdraft生成、Host preview、権限差分表示、導入確認、管理UI、production compositionへ進む。
- lifecycleをproductionへ接続する前に、保存先root pinningとsymlink / reparse race testを完了する。
