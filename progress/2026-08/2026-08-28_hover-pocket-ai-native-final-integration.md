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
