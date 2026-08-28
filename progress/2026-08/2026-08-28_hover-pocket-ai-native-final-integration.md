# HoverPocket AI-native final integration — 2026-08-28

## 実施範囲

- ChatGPT Pro Orchestratorの同一deliveryは、保存済みstateと重複防止状態を確認し、成果物の再適用や新規promptの再送を行わなかった。
- Draft PR #39の最新code head `a20a35f1e2480e6e5e557f43256699fe5567be51`について、CI、通常ユーザーWindows readback、Codex Securityのsealed scanを最終受入証拠として照合した。
- findingを受け、Windows実UAC、junction canary、positive elevated confinementを実行せず、production generation / activationのfail-closedを維持した。

## CIと実機readback

- PR checksは7 / 7成功した。Windows Verify [33133241784](https://github.com/shotaro311/hover-pocket/actions/runs/33133241784)でRelease / Debug buildと製品Verifier、macOS Capabilities、PR Router、macOS / Windows / Ubuntu Pocket contractとcompareを確認した。
- 通常ユーザーWindowsの隔離task `01a040c4-cff6-7102-a81c-60df235bdb21`はexact head `a20a35f1e2480e6e5e557f43256699fe5567be51`で実行した。
- `CodexGenerationSandboxProvisioner` self-test、未準備状態の`HP_CODEX_SANDBOX_NOT_READY`、専用Codex Homeの実行前後不在、Release build警告0・エラー0、Settings verifier、Pocket Surface verifier、publish artifact内provisioning script 0件をreadbackした。
- この実機readbackは未準備時の安全停止を示す。actual UAC setup、sandbox OS identity、positive confinement、実API、実生成の成功証拠ではない。

## Codex Security final-head scan

- scan ID: `47c3e1c5-ce27-4c96-8d1e-6d522c79b040`
- exact range: `16090d7a86c81ab19d85018462814c7279bb8801..a20a35f1e2480e6e5e557f43256699fe5567be51`
- completed / sealed: `2026-08-28T02:20:26.849471Z`
- coverage: 59 / 59 authoritative review item、3 / 3 candidate validation、coverage complete
- reportable: 1件、severity medium、finding `csf_3caf7ab99af268f9b88d011e`、occurrence `occ_6b501da2f23a262f400826dd`
- sealed artifacts: `findings.json` SHA-256 `6cc61c9486e028a373ae50665f6c2d4e307de51abf9695d94e81fcb0a0707093`、`coverage.json` SHA-256 `199f5d91ad29596208609d9e8cd2c91f6f43123eae824fa7f7e1677a584ff25b`

## findingと判断

- 固定Codex executableはexact size / SHA-256で検証し、コピー元と固定先をhandleでpinしている。このcontrolは任意binary差し替えとuser-writable scriptの昇格を防ぐ。
- 一方で、固定`%LOCALAPPDATA%`配下の`codex-home`はUAC前にdirectory objectとして束縛されず、path文字列として公式Codex 0.145.0 setupへ渡る。
- 同一ユーザーのmedium-integrity processがwhole-homeまたは既知の子directoryへjunctionを事前配置した場合、ユーザーの正規UAC承認後、公式setupがpathを再解決し、reparse先へdirectory / file作成またはDACL変更を行う可能性がある。setup後readbackは誤activationを防ぐが、先に生じた昇格filesystem effectを戻せない。
- したがって、現行setup / repairはAN8の実用リリース受入から外す。actual UACと危険なjunction PoCは実行しない。

## 次の安全な実装境界

1. trusted native elevated helperを用意し、dedicated Homeの各path componentを昇格identityで開く。
2. junction、symlink、mount point、未知のreparse tagを拒否し、handle-relative creationとobject identityを全privileged effectの終了まで保持する。
3. 途中のrename / delete / replaceを拒否し、公式Codex setupが保持対象以外へ作用できない構成にする。
4. standard userによるwhole-home / nested reparseを無害なadmin-owned canary rootへ向け、固定error code、target file / ACL不変を確認する。
5. 正常setup、UAC取消、invalid binary、post-setup readback failureでproduction generationが引き続きfail closedであることを確認する。

## 未完了gate

- reparse-safe elevated helperの実装、deterministic test、通常Windows hostでの安全なcanary
- ユーザー承認後のone-time provisioningとno-UAC positive confinement
- 両OSの物理microphone / OpenAI Realtime round-trip
- signed macOS / Windows candidate、notarization / Authenticode、installer、OS別feed、rollback readback
- Draft PR #39をReadyにする判断、merge、初回実用リリース

## production fail-closed remediation

### Pro回収と担当切り替え

- ChatGPT Pro Orchestrator run: `20260828-113152-hoverpocket-windowscodex-generation-sandbox-setupvalidated-reparse-uac-findingproduction-setup-repairchanges-patch`
- route / role: 通常Pro / builder、local receipt、exact base `978533d57ca31b02b0efd304145e75c8dde9778f`
- contract SHA-256: `dabf6caf4f17d596436f0737596700744cc92dde40db283277523db00d9dc5fe`
- 2026-08-28 11:31:52 JSTに開始し、13:27:25 JSTに`oracle-exit-failed` / `sent-state-unknown`でblockedとなった。同一sessionのbounded recoveryは総時間上限に達し、changes patchは回収できなかった。
- delivery `return-d5f8312874fe6431b14c06511e33aea0`はstate hash照合後に一度だけclaimされ、再開時は`already processed`をreadbackした。新規prompt、replacement run、旧artifactの推測適用は行っていない。
- Proがblockedでartifactを返せなかったため、Orchestrator Skillの例外規定に従いCodexが修正を再実装した。

### 実装した即時安全境界

- `CodexGenerationSandboxProvisioner`はproductionで`GENERATOR_SANDBOX_SETUP_UNAVAILABLE`を返し、ready / setup / repair / restartをすべてfalseにする。binary検査・copy・UAC・process起動の実装をproduction provisionerから除去した。
- Settings bridgeは`SetupAvailable`をpickerと承認より先に確認する。forged requestもpicker 0回、承認0回、filesystem変更0回で同じstateを返す。
- `CodexPocketAppGenerationAdapter.ResolveExecutable()`はproduction policyが閉じている限り`null`を返す。旧setup-v5 marker、既設の固定binary、通常のUI stateからproduction generatorを構成できない。
- 管理者PowerShellは`-CodexBin`のpath解決、file read、管理者判定、directory作成、copy、process起動より前に`HP_CODEX_SANDBOX_SETUP_UNAVAILABLE`で停止する。`-SelfTest`だけがfail-closed policyを検査する。
- Settingsのsetup / repairボタンは初期HTMLからdisabledで、Host stateが明示的にsetup可能と返した場合だけ有効化される。現在のproduction stateでは常にdisabledである。
- 要件とWindows READMEへ、公式Codex resource closure、署名済みhelper、元user SID、admin-owned object identity、PATH非依存、absolute-path起動を再有効化条件として明記した。

### ローカル検証

- `git diff --check`: 成功
- `node --check windows/ui/settings/settings.js`: 成功
- `node --check windows/script/verify_settings_generation_target.mjs`: 成功
- `node windows/script/verify_settings_generation_target.mjs`: 成功。generation targetに加え、初回state readback前のsetup disabledを確認した。
- `python3 script/verify_voice_foundation.py`: 成功。42 geometry / state caseと既存Voice / Broker契約を確認した。
- Ruby Psychによる`.github/workflows/windows-verify.yml` parse: 成功
- production provisionerと手動scriptのsink検索: `runas`、`--elevated`、setup process起動、binary copy、directory作成は0件。generation adapter本体の通常非昇格process起動はruntime resolverがproductionで`null`のため到達不能である。
- 独立read-only reviewer: server-side bypass 0件。初期HTMLでsetupが有効になる表示回帰1件を検出し、`disabled`属性とNode回帰を追加後に再検証した。
- Mac環境に`dotnet` / `pwsh`がないため、C# build、Settings verifier、PowerShell parser / self-test / fail-closed実行はPR Windows CI待ちである。

### 受入境界

- code head `8658d6cc078287a3ad98fe3b5e6dfef46f727daf`のWindows run [33168494246](https://github.com/shotaro311/hover-pocket/actions/runs/33168494246)で、PowerShell parser / self-test、nonexistent-drive Check / Provisionの固定error、Release / Debug build、Settings / Pocket / Voice / Updater / rendered UI verifierが成功した。両buildは警告0・エラー0である。
- 同headのmacOS Capabilities [33168494251](https://github.com/shotaro311/hover-pocket/actions/runs/33168494251)、3 OS contract / byte compare、Routerを含むPR checkは7 / 7成功した。PR #39は`MERGEABLE / CLEAN`である。
- `codex-security:verify-fix`のread-only traceはfinding `csf_3caf7ab99af268f9b88d011e`を`fixed`と判定した。production provisionerと手動scriptから昇格・copy・process sinkを除去し、Settingsはpicker前、runtimeは旧marker評価前に停止する。Windows CIで元入口と既存機能の正常系を確認した。
- 元scanのcompleted artifactをSecurity MCPで再読込したところ、artifact rootがsafe regular directoryではないとして拒否された。この外部artifact readbackは未確認のため、workbench occurrenceの状態更新は行っていない。修正判定はcurrent source、exact head、Windows CI、独立reviewを根拠にする。
- 中間run [33168222594](https://github.com/shotaro311/hover-pocket/actions/runs/33168222594)と[33168369422](https://github.com/shotaro311/hover-pocket/actions/runs/33168369422)はfail-closed verifierの配列bindingとnative nonzero捕捉で失敗した。製品scriptの安全停止ではなくharness側の問題であり、`.NET ProcessStartInfo`でexit code / stdout / stderrを取得する形へ修正して最終runを成功させた。
- この修正は危険なproduction入口を停止する即時対策である。署名済みnative helperと安全な正規setupの完成をAN8から除外せず、次の実装gateとして維持する。
- actual UAC、junction PoC、positive elevated confinementはこの修正では実行しない。

## Windows Codex sandbox native helper internal implementation

- ChatGPT Pro Orchestrator run `20260828-205951-...` / delivery `return-e69f9cd7ee0e439785b4ff7a8b365024`は、`sent-state-unknown`として同一sessionのbounded harvestだけを再試行したがartifactを回収できなかった。重複送信せずterminal化し、`mark-done`済みである。
- `HoverPocket.CodexSandboxSetup`へ以下を実装した。
  - `%ProgramData%\HoverPocketCodexSandbox\v1`配下の管理者所有・protected ACL root。
  - 公式Codex 0.145.0の6ファイルclosureを、admission済みの複製handleから空のstagingへcopyし、size / SHA-256 / Authenticodeを再検証して固定packageへ昇格する処理。
  - 元SIDとnonceから導出するsingle-use Codex Home。既存objectは`HP_CODEX_SANDBOX_TARGET_ALREADY_EXISTS`で拒否する。
  - 絶対pathの`codex.exe`へ`--user` / `--codex-home`を固定し、環境をclearしたchild process、5分timeout、kill-on-close Job Object。
  - setup marker / sandbox users regular-file検査、元SIDだけが読めるattestationのdurable writeとequality readback。
- productionは二重にOFFである。Shell provisionerはsetup入口を閉じ、native helperも`ProductionSetupActivated == false`によりrequest parse前にexit 21 / `HP_CODEX_SANDBOX_HELPER_NOT_ACTIVATED`を返す。Settings、UAC、production generator resolverへは接続していない。

### Security gate

- Codex Security scan `ddedf27f-5261-41f9-8522-1d08412fbc66`を修正前working-tree snapshot `codex-security-snapshot/v1:sha256:a8adc5749b8f661509a2fbb2d099472b5263ff405b422d041ca32a848a08aaad`に対して完了した。5 / 5 review surface、coverage complete、reportable finding 0件である。
- scanは、同一nonce Homeの再利用とBuiltin Usersから読めるidentity-bearing attestationを、production sinkが到達不能な条件付きgapとして棄却した。この2点はscan後に、create-new限定HomeとSID-specific read ACLへ修正した。したがってscan結果を修正後working tree全体のSecurity scanとしては扱わない。
- scanが残したproduction受入質問は、固定admin-owned helper origin、全component identity、ACL、Job Object descendant termination、exact marker semantics、`sandbox_users.json`の意味検証である。

### Local verification

- 一時.NET 10 SDKでRelease / Debugの全solution build: どちらも警告0・エラー0。
- helper `--contract-self-test`: PASS。macOSではWindows専用ACL部分だけskip。
- helper不正`--setup-request`: exit 21と`HP_CODEX_SANDBOX_HELPER_NOT_ACTIVATED`をreadback。
- Settings JavaScript構文、Settings generation target verifier、Voice Foundation 42件、workflow YAML parse、`git diff --check`: PASS。
- helper projectの変更file限定`dotnet format whitespace --verify-no-changes`: PASS。全solution `dotnet format --verify-no-changes`は今回と無関係な既存whitespace差分で不合格のため、既存fileは変更しなかった。

### PR CI readback

- 実装commit `f63e265f91ad1366369dc6a9c39b72c392701368`のWindows run [33175266675](https://github.com/shotaro311/hover-pocket/actions/runs/33175266675)は、Release / Debug build、Windows専用ACLを含むhelper contract、公式6ファイルclosureまで合格した後、native exit 21をPowerShellがassert前にjob失敗として扱うCI harnessだけで失敗した。
- `.NET ProcessStartInfo`でbuilt helperのstdout / stderr / exit codeを回収するcommit `48933374f8a5c29cc764ad52bce95c09641594f9`へ修正した。
- Windows run [33175584387](https://github.com/shotaro311/hover-pocket/actions/runs/33175584387)は、production fail-closed、unelevated downgrade拒否、Release / Debug build警告0・エラー0、native helper contract、公式Codex 0.145.0 vendor closure、Settings、Capability、Broker、Pocket Surface、Voice、Updater、signing contract、rendered UIの全stepに合格した。
- 同headでRouter [33175576923](https://github.com/shotaro311/hover-pocket/actions/runs/33175576923)、macOS Capabilities [33175583944](https://github.com/shotaro311/hover-pocket/actions/runs/33175583944)、3 OS contract / compare [33175584002](https://github.com/shotaro311/hover-pocket/actions/runs/33175584002)も成功した。PR checkは7 / 7、Draft PR #39は`MERGEABLE / CLEAN`である。

### Remaining gates

- helperを署名済みinstallerから固定admin-owned pathへ配置し、そのpathだけをSettingsの明示操作からUAC起動する。
- 通常Windows hostでwhole-home / nested reparse拒否、target不変、UAC取消、timeout descendant終了、正常setup、marker / attestation / sandbox user readbackをphysical canaryする。
- `sandbox_users.json`の意味検証、positive elevated confinement、実model generation / credential非残留、physical Voice E2E、正式署名・配布を完了する。
- 上記が揃うまでproduction setup / generation / activationはOFFを維持する。
