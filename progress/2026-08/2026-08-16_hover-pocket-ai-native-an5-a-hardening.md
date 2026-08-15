# HoverPocket AI-native AN5-A Final Hardening

## 結論

PR [#16](https://github.com/shotaro311/hover-pocket/pull/16)のPocket App lifecycle基盤を、承認期限切れ、複数manager競合、remove中断、起動時復旧まで含めて両OSでfail closedにした。AN5-AはReady、CI green、Codex Security finding 0の状態で、人間によるmerge待ちである。PRは自動mergeしていない。

## 最終source

- branch: `codex/ai-native-an5-generator-install`
- source head: `a9fb8ed0bfd065d1a78d33a128dc14894718342d`
- Windows verify: [31897975620](https://github.com/shotaro311/hover-pocket/actions/runs/31897975620) 成功
- macOS verify: [31897975587](https://github.com/shotaro311/hover-pocket/actions/runs/31897975587) 成功
- Pocket contracts: [31897975600](https://github.com/shotaro311/hover-pocket/actions/runs/31897975600) でUbuntu / macOS / Windowsとcross-OS byte比較が成功
- PR Router: [31897982011](https://github.com/shotaro311/hover-pocket/actions/runs/31897982011) 成功
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
- 公開Capability descriptorも`$(?![\\s\\S])`で真の終端を要求し、末尾改行をschema段階で拒否するnegative fixtureを追加した。
- macOSのimmutable snapshotは全regular file、深いdirectory、Versions / App / Apps / lifecycle rootをactive record確定前にfsyncする。`snapshot_sync`失敗時に旧active versionを保持する回帰testを追加した。
- version保存先は両OSでUTF-8 byte列の可逆な16進keyを使う。case-insensitive filesystemでも`1.0.0-ALPHA`と`1.0.0-alpha`が共存し、それぞれへrollbackできる。
- 承認待ちのdisposable staging snapshotは同一rootにつき最大4件とし、複数managerのprocess-wide registryで合算する。5件目はcopy前に拒否し、既存4 proposalは保持する回帰testを両OSへ追加した。

## ローカル検証

- `swift build -Xswiftc -warnings-as-errors`: 成功
- Pocket App / Surface / Capability / Broker / Panel layout / Timer / Calculator / Clipboard / Weather verifier: 成功
- Pocket App negative case: 13件成功
- Pocket contract: 12 schema / 58 fixtureを2回生成しbyte一致
- contract report SHA-256: `5926130e504ca64e4aa39c340a53ba29cbcb74cfa5e5fb0b646a268d66ca0857`
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

その後のPR reviewで、runtimeは末尾改行を拒否する一方、公開Capability descriptorの`$`だけが改行直前matchを許す不一致を検出した。`c949676`で真の終端確認と末尾改行negative fixtureを追加し、ローカル2回byte一致、3 OS契約CI、Windows / macOS本体CIで解消をreadbackした。

snapshot durabilityとcase-insensitive version storageのexact range `c9496763765d4137f27302eb99cf350c4286153d...5f6a04f0b43f49fea047943261e4997c66824231`はscan `114557d4-7318-42cd-b744-c7cdc392025c`で4 / 4 fileを確認した。承認待ち上限のexact range `5f6a04f0b43f49fea047943261e4997c66824231...a9fb8ed0bfd065d1a78d33a128dc14894718342d`はscan `28517aef-7d8b-45a4-80d7-a97c92fd3834`で4 / 4 fileを確認した。両scanともcoverage complete、reportable finding 0、sealed completeである。

## 次

- PR #16は人間によるmerge判断待ち。自動mergeしない。
- merge後はAN5-Bとして、Codex requestからdraft生成、Host preview、権限差分表示、導入確認、管理UI、production compositionへ進む。
- lifecycleをproductionへ接続する前に、保存先root pinningとsymlink / reparse race testを完了する。
