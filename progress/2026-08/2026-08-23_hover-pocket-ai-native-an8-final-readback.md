---
project_slug: hover-menu-preview
date: 2026-08-23
status: an8-a-final-readback-passed; pr-review-followup-in-progress; formal-windows-signing-pending
updated_by: codex
---

# AI-native AN8-A Final Release Readback

## 対象

- PR: [#20 AN8-A 公開成果物のreadback検証](https://github.com/shotaro311/hover-pocket/pull/20)
- verified code head: `3e8b79f217d2052a17b6acc101e320456ccb5d62`
- branch: `codex/ai-native-an8-release-readback-main`

## 実装した最終境界

- macOSはversioned Sparkle ZIP、stable / versioned手動ZIP、stable / versioned appcast、versioned checksumの6資産を1つのsnapshotへ固定した。
- native verifierは6資産のtag / name / size / SHA-256を最後のGitHub metadata再取得まで照合し、3 ZIPと2 appcastのbyte同一性、bundle identity、Sparkle feed URL / public key、Team ID、codesign / notarization / Gatekeeperを確認する。
- Windows beta verifierはSetup SFXの末尾全byteをfull `.nupkg`とsize / SHA-256で比較する。Portableはroot layoutと`current/`の506ファイルをfull package `lib/app/`と相対path / size / SHA-256で比較する。
- workflowはnative macOS verifier変更時にも起動し、正式Authenticode gateとbeta package identity gateを分離する。

## 検証

- `python3 -m unittest script/tests/test_verify_release_readback.py`: 19件成功。
- Python compile、`bash -n script/verify_published_macos.sh`、workflow YAML parse、`git diff --check`: 成功。
- local live public readback: macOS 6資産とWindows全資産のdownload / digest照合に成功。macOS native verifierもcodesign / stapler / Gatekeeperを含め成功した。
- final workflow run [32629166708](https://github.com/shotaro311/hover-pocket/actions/runs/32629166708): exact head `3e8b79f217d2052a17b6acc101e320456ccb5d62`、全job成功。
- workflow artifactを新しい一時directoryへ別経路downloadし、次を確認した。
  - `published-release-readback`: `status=passed`、macOS 6資産、Windows `win-v0.2.7`の8資産。
  - `published-macos-gatekeeper-readback`: `status=passed`、`appcastParity=byte-identical`、`sparklePublicKey=verified`、`teamIdentifier=N7VVPW44ZA`、codesign / notarization / Gatekeeper成功。
  - `published-windows-package-identity-readback`: `status=passed`、`portablePayload=full-package-application-byte-equivalent`、`setupPayload=full-package-byte-equivalent`、`artifactSnapshot=verified`。
- security diff scan `1889e238-6153-4579-8ea6-d7801b6d2351`、`7291eb3a-5841-4176-942a-66f4ae39f02b`、`84906546-9cf0-472f-9e08-a33d5b3da72a`: coverage complete、reportable finding 0件、sealed complete。

## 失敗からの修正

- [32627459690](https://github.com/shotaro311/hover-pocket/actions/runs/32627459690): .NET一括SFX展開のcentral directory不一致を確認し、full packageは安全なentry単位展開へ変更した。
- [32627869765](https://github.com/shotaro311/hover-pocket/actions/runs/32627869765): root nuspec探索をexact `<packageId>.nuspec`へ固定した。
- [32628233979](https://github.com/shotaro311/hover-pocket/actions/runs/32628233979): Setup SFXを通常ZIPとして展開する前提を撤回し、SFX末尾とfull packageの直接照合へ変更した。
- [32628492824](https://github.com/shotaro311/hover-pocket/actions/runs/32628492824): 修正後のSetup payload検証を含む全jobが成功した。

## 残るAN8 gate

- 正式署名済みWindows releaseのtimestamped Authenticodeと3 payload署名者一致。
- macOS / Windows実機のclean install、upgrade、downgrade、uninstall、reinstall。
- Host / Pocket App / data rollback、migration、offline、sleep-wake、soak、retention、backup / restore。
- PR #20は人間mergeを維持し、自動mergeしない。
