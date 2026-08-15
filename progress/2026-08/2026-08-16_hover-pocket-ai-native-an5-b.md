# HoverPocket AI-native AN5-B 実装ログ

## 結論

AN5-BのHost側縦断をmacOS / Windowsへ実装した。ユーザー要求を固定schemaのPocket App draftへ変換し、Hostが検証、テスト、プレビュー、権限差分、ネイティブ承認、immutable lifecycle、実行後readbackを担当する。PR #17の両OS / 3OS contract CIと、最終hardening差分のSecurity scanは成功した。

ただし、実Codex processのproduction接続は完了扱いにしていない。Codexのread-only sandboxは書込みを防ぐが、ユーザーのローカルファイル読取りを十分に隔離しないため、両OSでfail closedにした。現在のproduction UIは安全な「生成機能は利用不可」状態になり、activation可能な生成はfixture verifierだけで通る。

## Git / 作業範囲

- worktree: `/Users/shotaro/code/share/hover-menu-preview-ai-native-an5b`
- branch: `codex/ai-native-an5-generator-ui`
- base: `151043c023098a8b8782895946cf01f8194579b3`
- stacked base branch: `origin/codex/ai-native-an5-generator-install`
- AN5-A PR: #16。最終review修正と両OSCI成功後、merge commit `c8db98d424cad04d88688bbca52b3afd72d521d2`でmainへ取り込んだ。
- AN5-B PR: #17。AN5-A merge後に`origin/main`をmergeし、baseをmainへ変更した。統合source headは`2a1cc007a7b883ef63761ebf402110de41edd8b3`。

## 実装内容

### 1. 生成契約

- Hostがrequest ID、app ID、version、namespace、有限Capability catalogを割り当てる。
- user requestと上記値をSHA-256 request digestへ束ねる。
- 生成応答は`pocket-app-generation-output.schema.json`の固定形式だけを受理する。
- path、file数、file size、総size、重複path、NUL、未知fieldをfail closedにする。
- manifest、state store、requested Capabilityのeffect / permission / scopeをHost catalogと完全一致させる。
- 64文字までの任意長semantic version patchをoverflowなしで増分する。

### 2. Host pipeline

- 生成workspaceとdraft rootをapplication rootから分離した。
- draftはHostがmaterializeし、AN4 package runtimeで再検証する。
- AN5-A lifecycleへstageし、declared tests、preview、permission差分、effective Capability grant差分を得る。
- 承認対象はpackage / preview / request / binding digestと完全なgrant差分を含む。
- install / update / rollback後はactive version、package digest、stateを再読込する。
- disable / preserve-only removeもHost receiptのreadback成功を必須にする。
- disabled packageをimmutable package ID / version / digest / permissions / state schema / Host compatibilityから再検証して有効化する。
- remove前に同じpackageのpending proposalだけをrejectし、別packageのproposalとstagingを保持する。

### 3. macOS UI

- SettingsにPocket App生成欄を追加した。
- request入力、生成、cancel、preview、権限・grant差分、導入確認、managed app一覧、disable / remove / rollbackをHost controllerへ接続した。
- 実Codexは`supportsConfidentialGeneration=false`でhard disableし、fixtureだけactivationを許可する。
- CLI identity、Team ID、strict signature、version、inode / device / owner / mode / digest、process group cleanupの実装は保持したが、confidentiality gateが開くまでproductionから呼ばない。

### 4. Windows UI

- Settings WebViewへ同等の生成・preview・管理UIを追加した。
- generation bridgeとstateは`BridgeSurface.Settings`だけへ登録し、Panelには公開しない。
- AI-native有効化はSettings専用かつWPF MessageBoxの既定Noを必須にした。
- rendererはapproval request ID / binding digestを決定できず、Host保持proposalをネイティブUIで承認する。
- productionの`CodexPocketAppGenerationAdapter.ResolveExecutable()`は`null`固定で、実processを起動しない。

### 5. 保存先とrecovery

- macOSはno-follow descriptorとdevice / inode、Windowsはdirectory handleとvolume / file IDでroot identityを固定する。
- generation controllerは起動時の`RecoverInterruptedTransactions`を無効化した。root pin後にpathnameが差し替えられた場合でも、起動だけでStagingやtombstoneを削除・移動しない。
- abandoned Staging sentinelがcontroller初期化後も残る回帰を両OSへ追加した。
- explicit lifecycle操作のpath raceを全面的に閉じるdescriptor-relative / handle-relative rewriteは次gateに残す。

## ChatGPT Pro Orchestrator

- run: `20260816-024012-hoverpocket-an5-boscodexpocket-app-drafthostimmutableuireadbackpatch`
- route: normal Pro / builder / Oracle browser transport
- target model: `gpt-5.6-sol` / Pro。UI上のmodel selection evidenceはunverified。
- GitHub access: read-only
- external writes: なし
- base: `151043c023098a8b8782895946cf01f8194579b3`
- Pro申告delta: `changes.patch`, 186896 bytes, SHA-256 `c9de646b1fe6f59d4bbbacfbd92f4d2a78e5d8b1fc5dcc0862abcab8554907a2`
- 実回収artifact: `changes.patch`, 71029 bytes, SHA-256 `f3c81be20de146a6ab5b9ecedea6dd72b810de79b2fd6466e75ff2c3c552d030`
- 判定: 申告deltaと回収物が一致せず、repairは1回上限へ到達した。Skillのblocked / artifact適用不能例外としてCodexがローカル修正した。
- ChatGPT Projectは検証済みだが、個別conversation URLは未確認。

## ローカル検証

成功:

- `swift build -Xswiftc -warnings-as-errors`
- `.build/debug/HoverPocket --verify-pocket-app`
  - package verify: ok
  - lifecycle verify: ok
  - generation verify: ok
- `.build/debug/HoverPocket --verify-capabilities`
- `.build/debug/HoverPocket --verify-broker`
- `.build/debug/HoverPocket --verify-pocket-surface`
- `.build/debug/HoverPocket --verify-timer`
- `.build/debug/HoverPocket --verify-clipboard`
- `.build/debug/HoverPocket --verify-calculator`
- `.build/debug/HoverPocket --verify-panel-layout`
  - 128 cases
- `python3 script/verify_pocket_contracts.py`
  - 13 schema / 58 fixture
- `node --check windows/ui/settings/settings.js`
- `git diff --check`

未確認:

- このMacには.NET SDKがないため、Windows Release build / verifierはPR CIへ委ねる。
- Windows実機のWPF MessageBox、Settings UI、install / rollback UI。
- 実Codex processのlocal-file confinementと生成E2E。

## Security scan

- scan ID: `7d0275cd-1935-4f89-8088-35189a382445`
- target: exact base `151043c`からの最新working-tree digest
- coverage: 25 / 25 file、complete
- findings: 0
- status: sealed complete
- 修正済み項目:
  - Windows rendererからのAI-native opt-inをSettings-only + native default-Noへ変更。
  - generation controller起動時のpathname-based automatic recoveryを無効化。
- 残るhardening:
  - explicit lifecycle操作をdescriptor / handle相対へ全面移行する。
  - Mac sandbox helper / Windows restricted tokenまたはAppContainerで実Codexのread範囲を実証する。

追加の最終hardening scan:

- `8e5e2370-6361-4e35-a1fd-6fe835e7db85`: `0bc4051...736d207`、coverage complete、findings 0、sealed complete。
- `695689dc-62ad-45ff-a733-62ce8389e1c1`: `736d207...cc95d61`、coverage complete、findings 0、sealed complete。
- `5756c702-3d31-4da0-a285-c7a477a57fdc`: `3bac0f6`からの最終review修正6 file、coverage complete、findings 0、sealed complete。

最終review修正:

- Windowsの`settings.resetDefaults`は保存値だけでなく、起動済みgeneration controllerへ`SetEnabled(false)`を通知する。進行中生成をcancelし、Host保持proposalをrejectして、write routeを`GENERATION_DISABLED`で拒否する回帰をSettings verifierへ追加した。
- macOS / Windowsの`enable`は、enabled record確定後のpackage / active record readbackが失敗した場合、元のdisabled recordを再書込みしてreadbackした後に失敗を返す。一回だけreadback failureを注入し、再起動相当の再読込でもdisabled、active packageなしとなる回帰を追加した。
- Macのwarnings-as-errors build、Pocket App package / lifecycle / generation verifier、共通contract 13 schema / 58 fixture、Windows Settings JavaScript syntax、`git diff --check`が成功した。Windows本体とSettings verifierはPR CIを最終gateとする。

## AN5-Cへ分離したruntime activation gate

PR reviewで、AN5-BのLifecycleが保持するactive packageと、実際の`pocketAppExecutionRuntime` / Surface登録がまだ接続されていないことを確認した。現在のproduction generatorはmacOS / Windowsともactivation不可なので、この未接続による成功receiptは利用者経路から到達しない。

任意app IDの生成Appを組み込みToday Focusの単一runtimeへ直接差し替えると、別アプリをToday Focusとして誤表示する。この簡易修正は採用せず、次のAN5-Cで以下を実装する。

- app ID単位の`PocketSurfaceRegistry` / execution-runtime registry。
- install / update / enable / disable / remove / rollbackの各操作で、Lifecycleと描画・実行側のapp ID、version、package digest、permission grantを照合するreadback。
- built-in Today Focusと複数generated appの分離、再起動後の復元、他app非干渉の回帰検証。
- runtime側の一致が確認できない場合はLifecycle操作の成功receiptを出さずfail closed。
- 上記とlocal-file confinementの両方が通るまでreal Codex activationを無効のまま維持する。

## 次のgate

1. PR #17のreview threadを閉じ、docs更新後のCIとremote parityをreadbackする。
2. AN5-Aをmergeする場合はAN5-Bのbaseをmainへ更新し、差分とSecurity snapshotを再確認する。
3. AN5-Cでgenerated packageをSurface / execution runtimeへ接続し、lifecycle receiptとの一致を両OSで検証する。
4. 実Codex confinementを別の小さいPRで実装・実機検証する。
5. AN3 Voiceと接続し、「こういうパネルが欲しい」からdraft / previewまでのCore Integration E2Eへ進む。
