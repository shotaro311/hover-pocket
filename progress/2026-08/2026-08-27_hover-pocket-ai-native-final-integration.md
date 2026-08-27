# HoverPocket AI-native Core GA final integration follow-up

## 目的

AN5のproduction Codex Pocket App生成を有効化せず、macOSで実Codex CLIのfilesystem / network隔離境界を証明し、macOS / Windows双方でHost-owned一回限りcredential deliveryを隔離generatorへ接続する。CIでは再現可能なself-testとunelevated downgrade rejectionを確認し、Windows elevated実行、実モデル生成、Voice物理E2E、署名・配布を別gateとして維持する。

## ChatGPT Pro回収状態

- Pro run `20260826-132725-hoverpocketan8realtime16090d7windows-voice-7472c73macos-voice-5883925an5-mutual-credential-e4cd8f0criticgate`は、既存sessionのbounded recovery後にstate `completed`、受入4 / 4、terminal receipt `complete`であることをreadbackした。
- 同一deliveryは処理済みであり、新規prompt、重複claim、成果物の再適用を行っていない。
- Pro criticの境界どおり、production生成はoffのまま、macOS隔離canaryだけを独立した次の証拠にした。

## 実装

### Codex生成command-backed credential delivery

- Codex 0.145.0のcustom model providerは`auth.command`をstdin nullで起動するため、既存v1 helperのHost起動・stdin bootstrapをproduction生成へ直接接続できないことを確認した。v1はexact PID / mutual identityの独立contract testとして維持する。
- v2はHoverPocket HostがCodex生成processを起動して直接childであることを確認し、Codexがauth helperを直接childとして起動する。helperは自身のparent / grandparent PIDからHost PID、generation PID、決定論的endpointを導出し、endpointやcapabilityをargument、environment、fileへ渡さない。
- macOSはowner-only Unix socket、same UID、exact Host PID、helperのCodex直接child、HoverPocket designated requirementを相互確認する。Windowsは`CurrentUserOnly` named pipe、OS取得client / server PID、Codex直接child、exact `Environment.ProcessPath`を相互確認する。
- Hostは認証済みrequest後だけKeychain / Credential ManagerからAPI keyを遅延取得する。leaseは最大30秒・1回限りであり、期限切れ、unauthorized、malformed、provider失敗、取消、process終了で消費・失効する。
- custom providerは`https://api.openai.com/v1`、Responses wire API、`auth.refresh_interval_ms=0`、request / stream retry 0に固定した。helper executable pathはmodel tool permissionで明示denyし、credential環境変数は設定しない。
- productionはmacOS `supportsConfidentialGeneration == false`、Windows `ResolveExecutable() == null`、両OS preview-onlyのままである。実API key、実model request、生成package activationは使用していない。

- `script/verify_codex_generation_confinement_macos.py`
  - fixed npm vendor pathだけを候補にする。
  - regular file、非symlink、owner、group / world write禁止、OpenAI Developer ID authority / Team ID、strict codesign、exact `codex-cli 0.145.0`を検証する。
  - fresh temp root内のworkspaceをread-only、Codex Home / virtual User Homeをdeny、networkをoff、shell environment inheritanceをnoneにする。
  - root外sibling fileとloopback listenerをcanaryにし、outside-root readとnetwork接続を実行時に検証する。
  - 10秒timeout、process group TERM / KILL、bounded stdout / stderr、exact JSON、canary非露出、cleanup rootの親・prefix・type・owner検証を行う。
  - receiptはallowlist booleanとpinned versionのみを出力する。
  - `--self-test`は期待結果を1項目ずつ反転して拒否し、named permission profileの固定markerも確認する。
- `.github/workflows/macos-capabilities-verify.yml`
  - script変更をpush / pull request triggerへ追加した。
  - Python compileと`--self-test`をmacOS CIへ追加した。
  - CI runnerへ署名済みpinned CLIがあることを仮定せず、実sandbox canaryはlocal / manual evidenceとして分離した。
- `Sources/HoverPocket/PocketApps/CodexPocketAppGenerationAdapter.swift`の`supportsConfidentialGeneration == false`は変更していない。

### Windows native elevated sandbox

- `windows/script/verify_codex_generation_confinement.ps1`
  - `codex-cli 0.145.0`のlocal executableだけを対象にし、非UNC、全path component非reparse、exact length / SHA-256、Valid Authenticode、`OpenAI OpCo, LLC` signer、exact versionを実行前に照合する。
  - defaultはnative `elevated` sandboxとし、fresh sibling rootでworkspace read、workspace write拒否、isolated Codex Home / User Home read拒否、root外sibling read拒否、loopback接続拒否をactual child PowerShellで測る。
  - 45秒timeout、process tree kill、exact JSON、stderr上限・canary/path秘匿、listener / write artifactの独立readback、親・prefix・reparse検証済みtemp cleanupへ閉じる。
  - `--SelfTest`相当の`-SelfTest`で6判定の反転、必須permission marker、exact unelevated rejectionを確認する。
- `windows/src/HoverPocket.Shell/PocketApps/CodexPocketAppGenerationAdapter.cs`
  - dormant production templateを`windows.sandbox="elevated"`へ固定し、ambient environmentを継承せず、system `PATH / SYSTEMROOT / WINDIR / COMSPEC`とisolated Home / AppData / tempだけを明示する。
  - `ResolveExecutable() == null`と`AllowsActivation == false`は維持する。positive canary、Host-owned credential delivery、trusted resolverが揃うまでproduction生成・activationへ接続しない。
- `.github/workflows/windows-verify.yml`
  - exact vendor packageとarchive SHA-512を固定し、script側のexecutable hash / Authenticode / version検証と二重化する。
  - hosted runnerでelevated positive canaryを成功扱いせず、actual `unelevated` backendがread-only profileをexact diagnosticで拒否することだけをnegative-controlとして確認する。
- 仕様根拠はOpenAI公式の[Windows sandbox](https://learn.chatgpt.com/docs/windows/windows-sandbox)と[Sandboxing](https://learn.chatgpt.com/docs/sandboxing)を正本とした。公式推奨どおり`elevated`を優先し、`unelevated`は弱いfallbackとしてもread-only profileの代替にしない。

## ローカル検証

- `python3 script/verify_codex_generation_confinement_macos.py --self-test`: PASS
- `python3 script/verify_codex_generation_confinement_macos.py`: PASS
  - signed executable: true
  - workspace read: true
  - workspace write denied: true
  - Codex Home read denied: true
  - virtual User Home read denied: true
  - outside-root read denied: true
  - network denied / loopback listener unreached: true
  - stderr bounded: true
- symlinkの`/opt/homebrew/bin/codex`を`--codex-bin`へ指定するnegative test: 想定どおりregular file検証でFAIL
- `swift build -Xswiftc -warnings-as-errors`: PASS
- `.build/debug/HoverPocket --verify-pocket-app`: PASS。package、lifecycle、generation、migration、health、workspace backupを含む
- workflow YAML parse: PASS
- `git diff --check`: PASS
- `swift build -Xswiftc -warnings-as-errors`: 最新credential delivery差分で再度PASS
- `.build/debug/HoverPocket --verify-pocket-app`: v2 generation-parent-chain、one-shot lease、replay / expiry / peer rejection、socket cleanupを含めPASS
- `.build/debug/HoverPocket --verify-capabilities` / `--verify-broker` / `--verify-pocket-surface` / `--verify-voice-foundation` / `--verify-timer`: PASS
- `python3 script/verify_pocket_contracts.py`: 15 schema / 71 fixture PASS
- `python3 script/verify_voice_foundation.py`: 42 case PASS
- Windows panel / Settings / Pocket Surface JavaScriptの`node --check`: PASS
- Windows code head `12aa70167661f68ea2e5c95f933502154fdd6a6b`のCI [33024514348](https://github.com/shotaro311/hover-pocket/actions/runs/33024514348): SUCCESS
  - `PASS Codex generation confinement verifier self-test`
  - negative receiptは`mode=negative-control`、`readOnlyFallbackRejected=true`、`elevatedRequired=true`
  - Release / Debug Voice E2E build warning 0 / error 0
  - Capability、Broker、Pocket Surface、Timer、Settings、Voice / Voice E2E isolation、Updater、signing contract、rendered WebView2: PASS

## Codex Security readback

- scan ID: `a020f0d1-bfde-401f-94ab-243146343be9`
- snapshot: `codex-security-snapshot/v1:sha256:ff99dad207ee72deafdbf38d21001cb1444b175dfdd61da4a96ee2b4b838ee05`
- mode: exact working-tree diff
- coverage: complete
- reportable finding: 0件
- reviewed surfaces:
  - macOS Codex generation confinement executable verifier
  - macOS capabilities CI integration
  - production Codex Pocket App generation fail-closed root control
- limitations:
  - 実canaryはmacOS Seatbeltのみ。
  - Windows CIはdeterministic self-testとactual unelevated rejectionまでで、native elevated positive canaryは未完了。
  - credential delivery、実モデル生成、Voice物理E2E、署名、releaseは対象外。

### Windows exact diff scan

- scan ID: `0db33908-e8ec-4fe2-87b4-75079f34849c`
- exact range: `d8520c9d908e6cca1f50d204476bb983a0eb5ebb...12aa70167661f68ea2e5c95f933502154fdd6a6b`
- snapshot: `codex-security-snapshot/v1:sha256:ba93a9bd10cff7fd7dd79e08615faf1e7e1890f1a44006b66ec964d8060fb19a`
- coverage: complete
- reportable finding: 0件
- reviewed surfaces: production reachability / activation、elevated argument / environment template、PowerShell positive / negative canary、CI supply-chain / downgrade control、deterministic C# verifier、loopback network probe limitation
- open gate: normal Windows hostのelevated positive canary、Host-owned credential delivery、trusted executable resolver

### Credential delivery exact working-tree scan

- scan ID: `55b573a8-4b94-4ec0-b077-286887885e00`
- snapshot: `codex-security-snapshot/v1:sha256:bb7ef31f647030015b83542f5230dbe7dfd08936c7e631c9bb2e835630967ef0`
- changed source: 10 / 10
- coverage: complete
- reportable finding: 0件
- reviewed surfaces: Host credential provider、Codex generation process、command-backed auth helper、macOS Unix socket、Windows CurrentUserOnly named pipe、mutual PID / ancestry / executable identity、one-shot lease、cleanup、model-tool helper deny、production reachability / activation
- open runtime questions: Codex auth stdoutの非保持、auth control-planeとmodel-tool denyの分離、Windows packaged executable path

## Draft PR / CI readback

- credential delivery code head `ab7fcc8dd75c97f4bcd59aa7d8cf1061c9296991`はremote parity `0 / 0`である。
- Router [33028857939](https://github.com/shotaro311/hover-pocket/actions/runs/33028857939): SUCCESS。
- Windows [33028858902](https://github.com/shotaro311/hover-pocket/actions/runs/33028858902): SUCCESS。`generation-parent-chain`の開始・終了、`pocket_app_generation_verify=ok`、Release / Debug Voice E2E buildのwarning 0 / error 0をlogでreadbackした。
- macOS [33028858917](https://github.com/shotaro311/hover-pocket/actions/runs/33028858917): SUCCESS。Swift build、Voice、Capability、Broker、Pocket App / Surface、Timerが成功し、`pocket_app_generation_verify=ok`をlogでreadbackした。
- 3OS Pocket contract [33028858939](https://github.com/shotaro311/hover-pocket/actions/runs/33028858939): SUCCESS。Ubuntu / macOS / Windows verifierとreport比較の4 jobが成功した。重複push run [33028856731](https://github.com/shotaro311/hover-pocket/actions/runs/33028856731)も同じ4 jobが成功した。
- Draft PR #39は`Draft / OPEN / MERGEABLE / CLEAN`、review 0、comment 0である。production generatorはOFFのままであり、CI greenを実モデル・実credential・物理Voice・署名・配布の証拠には使わない。

- code head: `8cd445bdf6ebf6fe7c3150aea877be7c459fd035`
- remote parity: `0 / 0`
- Router [33022367720](https://github.com/shotaro311/hover-pocket/actions/runs/33022367720): SUCCESS
- macOS [33022481993](https://github.com/shotaro311/hover-pocket/actions/runs/33022481993): SUCCESS。Swift build、Codex confinement self-test、Voice、Capability、Broker、Pocket App / Surface、Timerが成功し、logで`PASS Codex generation confinement verifier self-test`と`pocket_app_generation_verify=ok`をreadbackした。
- Windows [33022484529](https://github.com/shotaro311/hover-pocket/actions/runs/33022484529): SUCCESS。Release / Debug Voice E2E build、Settings、Capability、Broker、Pocket Surface、Timer、Voice Foundation / E2E isolation、Updater、signing contract、rendered WebView2が成功した。
- 3OS Pocket contract [33022486583](https://github.com/shotaro311/hover-pocket/actions/runs/33022486583): SUCCESS。Ubuntu / macOS / Windows verifierとreport比較の4 jobが成功し、3 reportのbyte一致をlogでreadbackした。
- PR同期時はRouterだけが自動起動し、通常の`pull_request` workflow runが作成されなかった。上記3本は同じexact headを手動dispatchした証拠であり、PR required checkへの接続を代替しない。
- 最終進捗commitを含むhead `ebb0aa7570acfd0db1bb4c85ffac9cb89234926f`では、遅れて通常のPR workflowが自動起動した。Router [33022842034](https://github.com/shotaro311/hover-pocket/actions/runs/33022842034)、macOS [33022844429](https://github.com/shotaro311/hover-pocket/actions/runs/33022844429)、Windows [33022844408](https://github.com/shotaro311/hover-pocket/actions/runs/33022844408)、3OS Pocket contract [33022844417](https://github.com/shotaro311/hover-pocket/actions/runs/33022844417)の全7 checkがSUCCESSである。
- Draft PR #39は`Draft / OPEN / MERGEABLE / CLEAN`、review 0、comment 0、unresolved thread 0へ戻った。CI greenは実マイク、実API、credential delivery、production生成、署名、配布の完了証拠には使わない。

## 未完了gate

1. 通常Windows hostでnative elevated sandboxのpositive canaryを実行し、workspace read、write拒否、両isolated Home / outside-root read拒否、network拒否、listener未到達をreadbackする。CIのunelevated rejectionは代替にしない。
2. 実モデルを使う隔離generatorで、auth helperは起動できるがmodel toolから同じhelper pathを読取り・実行できないこと、credentialがargument、environment、Codex Home、disk、logへ残らないことをreadbackする。
3. 同じ隔離境界でPocket App DSLを1件生成し、schema検証、preview、install、activation、readback、remove / rollbackまで確認する。
4. 両OSの実API key / microphone Voice E2E、正式署名、配布、rollbackを別々に完了する。
5. 上記が完了するまでproduction generatorを有効化しない。
