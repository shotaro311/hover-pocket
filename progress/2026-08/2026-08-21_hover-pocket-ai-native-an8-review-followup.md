---
project_slug: hover-menu-preview
date: 2026-08-21
status: implemented; local-verified; public-beta-readback-passed; pr-ci-green; security-scan-green; review-resolved; formal-signing-pending
updated_by: codex
---

# AI-native AN8-A Codex Review Follow-up

## 対象

- PR: [#20 AN8-A 公開成果物のreadback検証](https://github.com/shotaro311/hover-pocket/pull/20)
- reviewed head: `5befd76719623e91f54a550024dedead3c55c7e8`
- Codex review:
  - P1: Velopack full update package内アプリのAuthenticodeを検証する。
  - P2: versioned release側の`HoverPocket-macOS-app.zip`も実際にdownloadしてhashを照合する。
  - P2: `auto`のWindows release発見からdraft / prereleaseを除外する。
  - P2: Windows公開後もGitHub汎用LatestがmacOS versioned releaseのままであることを確認する。

## 修正

- `windows/script/verify_published_authenticode.ps1`
  - `releases.win.json`が指す唯一のfull `.nupkg`を公開releaseから取得する。
  - checksum、feed size、SHA-1、SHA-256を実download byteと照合する。
  - ZIP path traversal、1ファイル512 MiB、合計1 GiB、10,000 entry超を拒否して展開する。
  - Setup、Portable内`HoverPocket.Shell.exe`、full package内`HoverPocket.Shell.exe`のtimestamped Authenticodeと署名者一致を必須にする。
- `script/verify_release_readback.py`
  - versioned Sparkle ZIP、stable手動ZIP、versioned手動ZIPを別directoryへ取得する。
  - 3コピーのsize / SHA-256とGitHub metadata、checksum、appcast lengthを照合する。
  - Windowsの自動発見はdraft / prereleaseを除外する。GitHub汎用Latestは選択に使わず、appcastが示すmacOS versioned releaseと一致することの確認にだけ使う。
- `script/tests/test_verify_release_readback.py`
  - versioned手動ZIPの正常系とdigest不一致拒否、Windows prerelease除外、GitHub汎用Latest置換拒否を追加した。
- workflow / README
  - formal gateがSetup、Portable、update packageの3署名を検査することを明記した。

## Readback

- `python3 -m unittest script/tests/test_verify_release_readback.py`: 12件成功。
- `python3 -m py_compile script/verify_release_readback.py script/tests/test_verify_release_readback.py`: 成功。
- workflow YAML parse: 成功。
- `git diff --check`: 成功。
- PR source head `77dc721c8ac7684fa46fd92ef6d641e26263d8f0`:
  - release metadata verifier: 成功。
  - Windows Authenticode verifier syntax: 成功。
  - Windows verify: 成功。
  - PR Router: 成功。
- exact security diff scan `11fdb6d9-9e92-45d1-9ffe-c5f3df1c7fbc`: coverage complete、reportable finding 0件、sealed complete。対象rangeは`8a900c9...77dc721`。
- live beta readback:
  - macOS `v0.1.0-168`: versioned Sparkle ZIP、stable手動ZIP、versioned手動ZIPの実測size / SHA-256一致、Sparkle Ed25519署名成功。
  - Windows `win-v0.2.7`: 公開全assetのsize / SHA-256、checksum、full package SHA-1一致。
  - macOS / Windowsのrelease tag分離: 成功。
  - GitHub汎用Latest=`v0.1.0-168`でappcastのmacOS versioned releaseと一致: 成功。
- 未確認:
  - ローカルMacにはPowerShellがないため、PowerShell parseはPRのWindows CIで確認する。
  - 現行Windows `0.2.7`は未署名betaであり、3点の実Authenticode検証は正式署名済みreleaseでのみ完了できる。
- Codex review 4件へ修正内容とreadback根拠を返信し、GitHub GraphQLで未解決thread 0件を確認した。

## 完了境界

この修正でCodex reviewの検証漏れを閉じる。AN8全体の完了には、正式署名済みWindows release、両OS実機のinstall / update / rollback / uninstall / reinstall、migration、backup / restore、offline / sleep-wake / soakが引き続き必要である。
