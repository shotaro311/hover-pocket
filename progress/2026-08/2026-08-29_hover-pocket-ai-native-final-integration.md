# HoverPocket AI-native final integration — 2026-08-29

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
