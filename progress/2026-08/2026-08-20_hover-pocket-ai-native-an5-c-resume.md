# HoverPocket AI-native AN5-C 再開・最終検証

## 再開地点

- branch: `codex/ai-native-an5-runtime-activation`
- worktree: `/Users/shotaro/code/share/hover-menu-preview-ai-native-an5c`
- PR: [#18](https://github.com/shotaro311/hover-pocket/pull/18)
- base: `a35b0ea8c224809ad4ff1bf1dc466882fc70169b`
- 再開時head: `f7c65f877f1996a4ec068b8fb5692de18ec4d91d`
- 実装head: `1c8b93fdded402805e4dc20751d03341c8e05bed`

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

## Review

- state束縛control永続化、取消後workflow確定、disabled生成Provider設定保持の3件へ修正根拠を返信した。
- 既存14 review threadはすべてresolvedにした。その後の最終head reviewで検出した入力0件workflowと管理外Apps entryの2件を追加修正した。
- source headの全CI成功後に`@codex review`を1回依頼した。追加修正の2 threadはpush後のCIとreadbackを確認して解決する。

## 残りgate

- progress同期を含む最終headのexact Security diff scan
- progress commit後のCI、未解決review thread 0、PR mergeability、remote parityのreadback
- macOS / Windows実機での生成Surface / runtime activation readback
- 実Codex generationのlocal-file confinement
- Voiceから生成、preview、承認、install、利用するCore Integration E2E

AN5-CはPR review-readyまでをこの作業の完了条件とし、mergeはユーザー判断後に行う。AN8全体は未完了である。
