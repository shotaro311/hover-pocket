---
project_slug: hover-menu-preview
date: 2026-08-23
status: an8-a-final-readback-passed; pr-review-resolved; formal-windows-signing-pending
updated_by: codex
---

# AI-native AN8-A Final Release Readback

## 対象

- PR: [#20 AN8-A 公開成果物のreadback検証](https://github.com/shotaro311/hover-pocket/pull/20)
- verified code head: `e2e6a4a4f7de80c9dd40578cf138e89a858aa5f3`
- branch: `codex/ai-native-an8-release-readback-main`

## 実装した最終境界

- macOSはversioned Sparkle ZIP、stable / versioned手動ZIP、stable / versioned appcast、versioned checksumの6資産を1つのsnapshotへ固定した。
- native verifierは6資産のtag / name / size / SHA-256を最後のGitHub metadata再取得まで照合し、3 ZIPと2 appcastのbyte同一性、bundle identity、Sparkle feed URL / public key、Team ID、codesign / notarization / Gatekeeperを確認する。
- Windows beta verifierはSetupのVelopack bundle headerが示すexact rangeをfull `.nupkg`とsize / SHA-256で比較する。Portableはroot layoutと`current/`の506ファイルをfull package `lib/app/`と相対path / size / SHA-256で比較する。
- Setup payloadは末尾位置から推測せず、Velopack 1.2.0のbundle marker直前16 byteにあるoffset / lengthを一意に解析してexact rangeだけをhashする。署名時に末尾へ追加されるPE証明書表はpackage byteへ含めない。
- formalではSetup、Portable、full package内アプリのSignerCertificate raw byte SHA-256を一致させ、repository variable `WINDOWS_SIGNER_CERT_SHA256`へ固定した正規publisherとも照合する。未設定・不正・不一致はfail closed、betaは`not-evaluated`で分離する。
- appcastはnamespaceなし`rss` root、direct childの`channel` 1件、`item` 1件、`enclosure` 1件を必須にする。GitHub汎用Latestは全公開assetのdownload / digest検証後に再取得してからmacOS versioned releaseとの一致を判定する。
- workflowはnative macOS verifier変更時にも起動し、正式Authenticode gateとbeta package identity gateを分離する。

## 検証

- `python3 -m unittest script/tests/test_verify_release_readback.py`: 19件成功。
- Python compile、`bash -n script/verify_published_macos.sh`、workflow YAML parse、`git diff --check`: 成功。
- local live public readback: macOS 6資産とWindows全資産のdownload / digest照合に成功。macOS native verifierもcodesign / stapler / Gatekeeperを含め成功した。
- final workflow run [32629166708](https://github.com/shotaro311/hover-pocket/actions/runs/32629166708): exact head `3e8b79f217d2052a17b6acc101e320456ccb5d62`、全job成功。
- publisher follow-up run [32638170997](https://github.com/shotaro311/hover-pocket/actions/runs/32638170997): exact head `da75587759959f5760eedb9a59b153d5971fc786`、全job成功。Windows native jobで公開SetupのVelopack bundle parserを実行した。
- workflow artifactを新しい一時directoryへ別経路downloadし、次を確認した。
  - `published-release-readback`: `status=passed`、macOS 6資産、Windows `win-v0.2.7`の8資産。
  - `published-macos-gatekeeper-readback`: `status=passed`、`appcastParity=byte-identical`、`sparklePublicKey=verified`、`teamIdentifier=N7VVPW44ZA`、codesign / notarization / Gatekeeper成功。
  - `published-windows-package-identity-readback`: `status=passed`、`portablePayload=full-package-application-byte-equivalent`、`setupPayload=full-package-byte-equivalent`、`artifactSnapshot=verified`。
- security diff scan `1889e238-6153-4579-8ea6-d7801b6d2351`、`7291eb3a-5841-4176-942a-66f4ae39f02b`、`84906546-9cf0-472f-9e08-a33d5b3da72a`: coverage complete、reportable finding 0件、sealed complete。
- security diff scan `f436ab83-bc71-4ab6-b104-d49738aeeb45`: exact range `59cd53a...da75587`の5 / 5 file、coverage complete、reportable finding 0件、sealed complete。
- final workflow run [32638515063](https://github.com/shotaro311/hover-pocket/actions/runs/32638515063): exact head `e2e6a4a4f7de80c9dd40578cf138e89a858aa5f3`、全job成功。3 report artifactを`/tmp/hoverpocket-run32638515063.k2JOcU`へ別経路downloadし、macOS 6資産、RSS / Latestを含む公開readback、Windows 8資産、Setup / Portable payload、署名 / 公証 / Gatekeeper、beta publisher分離を確認した。
- security diff scan `ce3db805-6663-48a6-aad0-c650efc9be0f`: exact range `f6f24f6...e2e6a4a`、2 / 2 surface、coverage complete、reportable finding 0件、sealed complete。
- PR #20のreview 14件へ検証根拠を返信して解決し、fresh GraphQL readbackで未解決thread 0件を確認した。PRはReadyのまま、人間mergeを維持する。

## 失敗からの修正

- [32627459690](https://github.com/shotaro311/hover-pocket/actions/runs/32627459690): .NET一括SFX展開のcentral directory不一致を確認し、full packageは安全なentry単位展開へ変更した。
- [32627869765](https://github.com/shotaro311/hover-pocket/actions/runs/32627869765): root nuspec探索をexact `<packageId>.nuspec`へ固定した。
- [32628233979](https://github.com/shotaro311/hover-pocket/actions/runs/32628233979): Setup SFXを通常ZIPとして展開する前提を撤回し、いったんSFX末尾とfull packageの直接照合へ変更した。この方式は後続reviewでbundle header解析へ置換した。
- [32628492824](https://github.com/shotaro311/hover-pocket/actions/runs/32628492824): 修正後のSetup payload検証を含む全jobが成功した。

## 残るAN8 gate

- 正式署名済みWindows releaseのtimestamped Authenticodeと3 payload署名者一致。
- macOS / Windows実機のclean install、upgrade、downgrade、uninstall、reinstall。
- Host / Pocket App / data rollback、migration、offline、sleep-wake、soak、retention、backup / restore。
- PR #20は人間mergeを維持し、自動mergeしない。
