# HoverPocket AI-native AN5-C 再開・最終検証

## 再開地点

- branch: `codex/ai-native-an5-runtime-activation`
- worktree: `/Users/shotaro/code/share/hover-menu-preview-ai-native-an5c`
- PR: [#18](https://github.com/shotaro311/hover-pocket/pull/18)
- base: `a35b0ea8c224809ad4ff1bf1dc466882fc70169b`
- 再開時head: `f7c65f877f1996a4ec068b8fb5692de18ec4d91d`
- 最終source head: `454a2d0f260ce6fec797540c5ee4c0c946ea42a9`

## 修正内容

### 生成Surfaceのstate保存

- Windows rendererのstate束縛text field、toggle、pickerを`pocketApp.updateState`へ接続した。
- workflow一時入力と永続stateを分離したまま、文字列、真偽値、数値を両OSのHost state storeで保存する。
- Provider再生成後も値が復元されるrendered WebView回帰と、両OSの型付きstate再読込回帰を追加した。

### workflow取消後の確定処理

- durable workflow開始後は、step間の取消で例外終了せず、未実行stepを`CAPABILITY_CANCELLED`のfailed receiptへ確定する。
- 実行中に取消されたwriteは副作用不明のため従来どおり`unknown`とし、実行前取消だけを`failed`として区別する。
- 既成功Timerのrollbackはcaller cancellationを継承しない経路で実行し、workflow receiptをdurable ledgerへ完了保存する。
- Timer成功直後に取消、Sticky write 0回、Timer rollback成功、failed workflow再読込をmacOS / Windows verifierへ追加した。

### disabled生成Providerの設定保持

- active Surface routeとdurable managed packageを別の正本として扱う。
- disabled中は生成Providerのorder、visibility、preferred、last-selectedを保持する。
- enable後に設定を復元し、preserve-only remove後だけ設定から除去する。
- 無関係な文字サイズ変更を挟むdisable / enable / remove回帰をWindows Settings verifierへ追加した。
- dynamic provider一覧が確定できない起動時は、有効なgenerated-provider IDを破壊しないbootstrap正規化へfail safeする。

### 最終reviewの追加修正

- Windowsの入力宣言が空の正当なworkflowを、入力数ではなく未解決値の有無で実行可否判定する。literalだけで構成したworkflowが空objectをHostへ渡して実行されるrendered UI回帰を追加した。
- macOS / Windowsの`Apps`直下に`.DS_Store`やpackage IDではない管理外directoryが混在しても無視し、正常な生成Appの管理snapshotと起動時復元を継続する。両OSのlifecycle回帰を追加した。

### 最終security reviewの追加修正

- 生成Appの`UserData/<appID>/state.json`をpath名だけで扱わない。macOSはpackage directoryのdevice / inodeを固定し、`openat(O_NOFOLLOW)`と同一directory内の`renameat`だけで読書きする。親pathがsymlinkへ差し替わった場合は実行前後のidentity readbackで拒否する。
- WindowsはUserData rootとpackage directoryをreparse拒否・`FileShare.Delete`なしのhandleで固定する。state読込みも`OPEN_REPARSE_POINT`のfile handleから行い、runtime解除時にhandleを確実に閉じる。他App directoryへの差替えを試みてもrenameを拒否し、他App stateが不変である回帰を追加した。
- macOSは生成Providerのdisable中には表示設定を保持する一方、preserve-only removeのruntime readback成功後にorder、hidden、preferred、last-selectedから対象Provider IDを削除する。UserDefaults再読込回帰を追加した。

### 最終head reviewの追加修正

- 生成ProviderのSurface modelは表示ごとに新規生成し、再度開いたときにCalendar等のqueryを再取得できるようにする。Registryは生存中modelを弱参照で追跡し、disable / remove時はすべて無効化する回帰を追加した。
- macOSの`$input`と`$state`を独立namespaceとして保持する。同じ名前のstateを更新しても一時入力を書き換えず、workflow準備時に入力を優先して不足分だけstateから解決する回帰を追加した。
- Windowsでinstall / update / enable後のruntime activationが失敗してrouteを解除した場合も、失敗後management refreshに続けてHostのrefresh hookを発火し、開いているPanelへ`state.changed`を配信する。失敗回帰は通知が1回発行されることを確認する。
- macOS / Windowsのpackage loaderはSurface controlが生成する値の型をstate schemaとworkflow宣言inputの両方へ照合する。text fieldへintegerを束縛する場合、stateをworkflow inputへfallbackする際の型不一致、複数workflow間の同名input型競合を導入前に拒否する。共通contract verifierにも同じcross-file意味検証を追加する。
- Windowsのstate束縛text fieldは入力を180msでdebounce保存し、`change`またはProvider切替時の`dispose`で保留値を即時flushする。同じstate keyへのwriteは順序を直列化し、changeを発火せず切り替えても値が保存されるrendered UI回帰へ変更する。

### 最終Codex review追随

- state束縛text / toggle / picker / Calendar選択を同じ保存queueへ統合する。失敗した最新値はpendingへ残し、次のflushで再試行する。Provider切替、強制再描画、update / rollback / disable / remove、AI-native OFF、defaults resetは保存完了を待ち、失敗時は状態変更を中止する。
- 更新中の操作禁止はApp IDだけでなくoperation IDへ結び、同じAppを切り替えて戻ったreplacement rendererにも同じleaseを付ける。重複operationは独立して数え、完了時は成功・失敗を問わず同じIDが取得した全renderer holdを解除する。
- generated Surfaceの描画keyへapp ID、version、manifest digestを含め、package差替え後は同じProvider IDでも新runtime / render modelへ再生成する。
- Windows runtime activation candidateがRegistryへ採用されなかった場合、activation leaseを無効化し、RuntimeHandle / user-state storeを必ず破棄する。receipt mismatch、restart restore mismatch、commit前failure injectionの回帰でhandle破棄を確認する。

## 検証

### macOSローカル

- `swift build -Xswiftc -warnings-as-errors`: 成功
- `--verify-broker`: 成功、取消後rollback / durable replayを含む
- `--verify-capabilities`: 成功、handler 14
- `--verify-pocket-app`: 成功、package negative cases 14
- `--verify-pocket-surface`: 成功、negative cases 15
- `python3 script/verify_pocket_contracts.py`: 成功、13 schema / 59 fixture
- `git diff --check`: 成功
- 最終review追加修正後もwarnings-as-errors build、Pocket App lifecycle / generation、Broker、Capability、Pocket Surface、Timer、13 schema / 59 fixture、JavaScript syntax、`git diff --check`が成功した。Windowsのrendered WebView回帰はPR CIを最終gateとする。
- 最終security修正後もwarnings-as-errors build、Broker、Capability、Pocket App lifecycle / generation、Pocket Surface、Timer、Clipboard、Calculator、Panel layout 128件、13 schema / 59 fixture、JavaScript syntax、`git diff --check`が成功した。macOSのdirectory差替え拒否と削除済みProvider設定pruneもdeterministic回帰で確認した。Windowsはローカルに.NET SDKがないためPR CIを最終gateとする。
- 最終head review追加修正後もwarnings-as-errors build、Broker、Pocket App lifecycle / generation、Capability、Pocket Surface、Timer、13 schema / 59 fixture、Windows JavaScript syntax、`git diff --check`が成功した。
- 追加3件の修正後、macOS warnings-as-errors build、Pocket App package / lifecycle / generation、Broker、Capability、Pocket Surface、Timer、13 schema / 59 fixture、Windows JavaScript syntax、`git diff --check`が成功した。Windows C# buildとrendered WebView UIは修正push後のCIを最終gateとする。

### PR CI

- Windows: [32331372164](https://github.com/shotaro311/hover-pocket/actions/runs/32331372164) 成功
  - .NET 10 Release build
  - Settings UI modules
  - Timer model / Bridge
  - rendered WebView UI
- macOS: [32331372103](https://github.com/shotaro311/hover-pocket/actions/runs/32331372103) 成功
  - warnings-as-errors build
  - Capability handlers / Broker / Today Focus
  - Pocket App package / Surface
  - Timer regression
- 3OS contract / compare: [32331372312](https://github.com/shotaro311/hover-pocket/actions/runs/32331372312) 成功
- PR Router: [32331370130](https://github.com/shotaro311/hover-pocket/actions/runs/32331370130) 成功
- 最終source head `454a2d0`:
  - Windows: [32346140249](https://github.com/shotaro311/hover-pocket/actions/runs/32346140249) 成功。Release build、generation / runtime activation、Settings、rendered WebViewを含む。
  - macOS: [32346140248](https://github.com/shotaro311/hover-pocket/actions/runs/32346140248) 成功。
  - 3OS contract / byte比較: [32346140258](https://github.com/shotaro311/hover-pocket/actions/runs/32346140258) 成功。
  - PR Router: [32346138524](https://github.com/shotaro311/hover-pocket/actions/runs/32346138524) 成功。

## Review

- state束縛control永続化、取消後workflow確定、disabled生成Provider設定保持の3件へ修正根拠を返信した。
- 既存14 review threadと、その後のreviewで追加されたthreadはすべて修正根拠を返信してresolvedにした。
- source head `4489791`のexact Security diff scan `e030446e-9c8f-401d-9d44-1b2cc996d943`は51 / 51 review itemを完了し、reportable finding 0件でsealed completeとなった。最終head review追加修正後は新しいexact source headを再scanする。
- source head `7816771`のexact Security diff scan `e5f9404b-aeae-488c-a1ac-6cf7e986b83c`も51 / 51 review itemを完了し、reportable finding 0件でsealed completeとなった。その後のreview追随を含む新しいsource headは再scanする。
- source head `454a2d0`への最終Codex reviewは重大な追加指摘なしで完了した。全review threadはresolved、PR #18は`MERGEABLE`、remote parityは`0 / 0`である。progress同期commitを含む最終headのexact Security diff scanを最後のPR gateとする。

## 残りgate

- progress同期を含む最終headのexact Security diff scan
- progress commit後のCI、未解決review thread 0、PR mergeability、remote parityのreadback
- macOS / Windows実機での生成Surface / runtime activation readback
- 実Codex generationのlocal-file confinement
- Voiceから生成、preview、承認、install、利用するCore Integration E2E

AN5-CはPR review-readyまでをこの作業の完了条件とし、mergeはユーザー判断後に行う。AN8全体は未完了である。
