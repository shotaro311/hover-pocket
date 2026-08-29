# HoverPocket AI-native final integration — 2026-08-29

## Windows Settings fixed-helper UAC boundary

- ChatGPT Pro Orchestrator run `20260829-195325-hoverpocket-windows-settings-fixed-helper-uac-boundary-patch`のdelivery `return-ef597cc5f3b9dee4a03b6d500d8a06f2`をclaim-synthesisで検証した。
- receipt、base `cc70c140cfccf28551a67b2dd775233240de1fc8`、artifact SHA-256 `a675afd34a5b4483e9c68db3d45d2308d5a9eeed7a35b0f1752c0659ec2309a0`、変更対象7ファイルを照合し、`changes.patch`を適用した。
- app-local helper copy / publishを削除し、Settingsから将来利用するhelperを固定`ProgramFilesX64` originだけに限定した。各path component、final file object、UAC後のprocess image identityを比較し、reparse /置換をUAC前後で拒否する。
- publisher metadata、WinVerifyTrust、certificate SHA pinを組み合わせ、native確認はdefault-No、requestはexact serialized arguments、elevationは単一`runas`、結果は固定errorとreadbackで扱う。
- production switchはShell / helperともにOFFである。Voice、Pocket App生成、startup、backgroundからこの境界へ到達するrouteは追加していない。

## Security remediationと差分スキャン

- 独立したresolverレビューで、初期案がWinVerifyTrustをrevocation無効かつcache-onlyにしており、将来の有効化時に失効済みsignerを受け入れる可能性を検出した。
- Shellとhelperの両方をwhole-chain revocation、root除外、cache-only fallbackなしへ変更した。revocation情報を取得できない場合もUAC前に停止する。Settings verifierとhelper self-testへ同じpolicy contractを固定した。
- Codex Security scan `92657ca5-0536-4875-8ad7-c45d2920458b`をexact range `cc70c140cfccf28551a67b2dd775233240de1fc8..82da1b7c110087b926010556869f6d8f63088d00`、snapshot `codex-security-snapshot/v1:sha256:5c94d0b10292c8061dbe33398491463ee47d826dd4f1458e7af02f430e9c5c29`でsealed完了した。対象9ファイル、6 surface、reportable findingは0件、coverageはpartialである。
- sealed reportは`/private/tmp/hoverpocket-security-uac-final.WmMDlf/report.md`、canonical manifest / findings / coverageも同directoryにあり、JSON parseとartifact SHA-256を別経路で再確認した。
- 実署名helper、physical UAC、cancel / timeout後のelevated process-tree cleanup、post-start identity readbackはscanのfollow-upへ残した。medium-integrity ShellがUAC後のelevated process treeを確実に終了できるかは物理canaryで確認する。

## ローカル検証

- `swift build -Xswiftc -warnings-as-errors`: 成功。
- `python3 script/verify_pocket_contracts.py`: `PASS hoverpocket.pocket/v1: schemas=15 fixtures=71 matched=71`。
- Codex auth control-plane、Codex confinement、macOS Voice E2E receipt、macOS realtime renderer、Voice foundation 42件、app Voice foundation / E2E isolation / panel layout、Capability、Broker、Pocket Surface、Pocket App package / lifecycle / generation / migration / health / workspace backup、Timer verifier: すべて成功。
- Shell project XML parseと`git diff --check`: 成功。
- ローカルMacに.NET SDKがないため、C# compileの成否をローカル結果から推測しない。Windows CIでRelease / Debug、`--verify settings`、helper contractを確認する。

## PR CIと修正readback

- 初回code head `efc3044eb6266e9c1082cd1b6eeee539e8f0fff0`のWindows run [33251115377](https://github.com/shotaro311/hover-pocket/actions/runs/33251115377)はRelease / Debug build、native helper contract、per-machine MSI contractまで成功し、Settings verifierだけが`ArgumentOutOfRangeException`で失敗した。
- 原因はWin32専用`FILE_FLAG_BACKUP_SEMANTICS` / `FILE_FLAG_OPEN_REPARSE_POINT`を.NET `FileOptions`へキャストしたことだった。`CreateFileW`でdirectory / regular file handleを明示的に開く形へ修正し、reparse拒否、share mode、handle identity pinを維持した。
- 修正code head `82da1b7c110087b926010556869f6d8f63088d00`のWindows run [33251291505](https://github.com/shotaro311/hover-pocket/actions/runs/33251291505)はRelease / Debug build警告0・エラー0、`PASS Codex sandbox helper contract`、`PASS Codex sandbox per-machine installer contract`、`PASS settings verify`、Voice 42件、`broker_verify=ok`、Pocket App generationに成功した。
- macOS [33251291487](https://github.com/shotaro311/hover-pocket/actions/runs/33251291487)、3 OS contract / compare [33251291502](https://github.com/shotaro311/hover-pocket/actions/runs/33251291502)、Router [33251290676](https://github.com/shotaro311/hover-pocket/actions/runs/33251290676)も成功し、Draft PR #39のcheckは7 / 7成功した。

## この境界の完了条件

- 更新headのWindows CIで警告0・エラー0、Settings verifier、helper contract、既存Voice / Broker / Pocket App契約が成功する。code head `82da1b7c110087b926010556869f6d8f63088d00`で達成済み。
- 正式publisherで署名したhelperを固定Program Filesへ配置し、通常Windows hostでnormal consent、UAC cancel、timeout、process-tree cleanup、署名 / origin / object / process identity、実行後readbackを保存する。
- これらが揃うまでproduction setup / generation / activationはOFF、Draft PR #39はReady / mergeへ進めない。

## 対象

- Draft PR #39のWindows Codex sandbox helperを、ユーザー書き込み可能なアプリ配置から分離し、固定Program Files originへ置くper-machine installer契約を実装した。
- ChatGPT Pro Orchestrator delivery `return-e69f9cd7ee0e439785b4ff7a8b365024`は既に処理済みであることをclaim-synthesisで確認し、成果物を再適用せずCodex実装を継続した。
- production setup / generation / activationは変更せずOFFを維持した。

## Per-machine MSI

- `HoverPocket.CodexSandboxSetup.Installer`をWiX SDK 5.0.2で追加した。
- self-contained `win-x64` helper publish一式を`%ProgramFiles%\HoverPocket\CodexSandboxSetup`へ64-bit componentとして配置する。
- embedded cabinet、固定UpgradeCode、major upgrade、uninstallを持ち、CustomAction、service、registry、environment、shortcutを持たない。
- `verify_codex_sandbox_installer.ps1`がMSI databaseを開き、machine scope、version / upgrade identity、directory ancestry、component属性、helper一意性、禁止table、cabinet、upgrade順序を検証する。

## 検証

- code head `209931a9faa541f1e33344908b66dfa4cb7c8336`のWindows run [33228860540](https://github.com/shotaro311/hover-pocket/actions/runs/33228860540): build警告0・エラー0、`PASS Codex sandbox per-machine installer contract`。
- Router [33228859399](https://github.com/shotaro311/hover-pocket/actions/runs/33228859399): 成功。
- 3 OS Pocket contract / compare [33228860568](https://github.com/shotaro311/hover-pocket/actions/runs/33228860568): Ubuntu / macOS / Windows / compareすべて成功。
- macOS Capabilities [33228860545](https://github.com/shotaro311/hover-pocket/actions/runs/33228860545): buildとVoice / Capability handlerは成功後、既存timeout fixtureの`timeout_status`だけで失敗。
- timeout fixtureをmacOS / Windows双方で30秒のcancellable waitへ変更した。ローカル`swift build`と修正後Broker verifier 50回連続、`git diff --check`は成功した。
- このMacには.NET SDKがないため、更新したC# fixtureのcompile / formatとMSI再検証は更新headのWindows CIを正本にする。
- 修正head `6c9e4708a8cf0dcc1b24107c2f4cf8d8665656e4`のWindows [33248167930](https://github.com/shotaro311/hover-pocket/actions/runs/33248167930)はRelease / Debug build警告0・エラー0、`PASS Codex sandbox helper contract`、`PASS Codex sandbox per-machine installer contract`、`broker_verify=ok`、Voice 42件に成功した。
- 同headのmacOS [33248167915](https://github.com/shotaro311/hover-pocket/actions/runs/33248167915)はbuild、Voice 42件、`broker_verify=ok`に成功し、元の`timeout_status`失敗を解消した。Router [33248166883](https://github.com/shotaro311/hover-pocket/actions/runs/33248166883)、push / PR起点の3 OS contract [33248165880](https://github.com/shotaro311/hover-pocket/actions/runs/33248165880) / [33248167921](https://github.com/shotaro311/hover-pocket/actions/runs/33248167921)も含め11 / 11 checkが成功した。

## セキュリティ差分レビュー

- Codex Security scan `71e7156e-74ac-4998-9c82-bc00a0a08c6c`をexact range `5c29adfbdf3b06b89c211d3f3bc0ed75f5911f8d..209931a9faa541f1e33344908b66dfa4cb7c8336`でsealed completeとした。
- 変更4ファイルを手動inventoryと独立脅威モデルで照合し、per-machine固定root、MSIの禁止table、upgrade / rollback構造、CI publish / MSI database readback、production fail-closedの5 surfaceをcoverage completeで確認した。reportable findingは0件である。
- scan reportは`/private/var/folders/mv/0d7m444d25d_q88sj2wfntj80000gn/T/codex-security-scans-HvGrWN/hover-menu-preview-ai-native-final-integration/209931a9faa541f1e33344908b66dfa4cb7c8336_20260829T102321Z_71d06mur/report.md`に生成され、completed scanのmanifest / findings / coverageも別経路で再読込した。
- 現行CIが保証するのはunsigned MSIの静的構造までである。署名、release channel、installed ACL / object identity、Settingsのfixed-origin resolver / UAC、実機install / upgrade / rollback / repair / uninstallは将来gateとして明示的に除外した。

## 未完了gate

- MSIとhelperの同一trusted publisherによるAuthenticode署名。
- Settingsが固定Program Files originのregular / non-reparse file、publisher、object identityを確認した後だけ作るUAC request。
- 通常Windows hostでのnormal setup、UAC cancel、whole-home / nested reparse、timeout descendant、marker / sandbox user / attestation readback、positive confinement。
- 実モデル生成、両OSの物理Voice E2E、正式署名・OS別配布・rollback readback。
- 上記が揃うまでDraft PR #39をReady / mergeにせず、production switchを有効化しない。
