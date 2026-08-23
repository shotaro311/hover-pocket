---
project_slug: hover-menu-preview
date: 2026-08-21
status: implemented; local-verified; public-beta-readback-passed; pr-ci-green; security-scan-green; review-followup-pending; formal-signing-pending
updated_by: codex
---

# AI-native AN8-A Codex Review Follow-up

## 対象

- PR: [#20 AN8-A 公開成果物のreadback検証](https://github.com/shotaro311/hover-pocket/pull/20)
- reviewed code head: `e2e6a4a4f7de80c9dd40578cf138e89a858aa5f3`
- Codex review:
  - P1: Velopack full update package内アプリのAuthenticodeを検証する。
  - P2: versioned release側の`HoverPocket-macOS-app.zip`も実際にdownloadしてhashを照合する。
  - P2: `auto`のWindows release発見からdraft / prereleaseを除外する。
  - P2: Windows公開後もGitHub汎用LatestがmacOS versioned releaseのままであることを確認する。
  - P2: `auto`のWindows tagをmetadata / Authenticodeの両jobで別々に解決せず、1つの確定tagを共有する。
  - P2: 共通beta verifierでもfeed targetがversioned full `.nupkg`であることを必須にする。
  - P1: Python verifierのexit 1を`tee`のexit 0で隠さず、workflowを確実に失敗させる。
  - P2: Setup / Portableは任意prefixではなくcanonical公開asset名を必須にする。
  - P2: formalの2 jobでtagだけでなく同一世代の全Windows asset byte snapshotを共有する。
  - P1: macOS公開物の`SUFeedURL`と`SUPublicEDKey`を配布bundleから直接検証する。
  - P1: 進捗正本を最新head、検証、readbackへ更新する。
  - P2: Portableの実アプリpayloadをfull `.nupkg`とbyte単位で照合する。
  - P2: macOS署名の`TeamIdentifier`を期待値へ固定する。
  - P2: 両appcastとchecksumも最初のsnapshotから最後のmetadata再確認まで固定する。
  - P1: 署名済みSetupのPE証明書表をpackage末尾と誤認せず、Velopack bundle headerからoffset / lengthを解決する。
  - P2: Windowsの3署名が互いに一致するだけでなく、正規HoverPocket publisher証明書へ固定する。
  - P2: 長時間のasset download後にGitHub汎用Latestを再取得する。
  - P2: appcastの`rss` rootとdirect childの`channel` 1件を必須にする。

## 修正

- `windows/script/verify_published_authenticode.ps1`
  - `releases.win.json`が指す唯一のfull `.nupkg`を公開releaseから取得する。
  - checksum、feed size、SHA-1、SHA-256を実download byteと照合する。
  - ZIP path traversal、1ファイル512 MiB、合計1 GiB、10,000 entry超を拒否して展開する。
  - Setup、Portable内`HoverPocket.Shell.exe`、full package内`HoverPocket.Shell.exe`のtimestamped Authenticodeと署名者一致を必須にする。
  - betaでもSetupのVelopack bundle headerが示すexact rangeとfull `.nupkg`全byteが一致することをsize / SHA-256で検証する。
  - Setup payloadはファイル末尾から推測せず、Velopack 1.2.0の固定marker直前16 byteにあるlittle-endian offset / lengthをstreaming KMPで一意に解決する。署名時に追加されるPE証明書表をpackage byteへ含めない。
  - Portable `current/`の506ファイルをfull `.nupkg`の`lib/app/`と相対path / size / SHA-256で照合し、package専用の2ファイルだけを明示除外する。
  - formalではSetup、Portable、full package内アプリのSignerCertificate raw byteをSHA-256化し、3点一致とrepository variable `WINDOWS_SIGNER_CERT_SHA256`の64桁正規値への一致を必須にする。値はreport / errorへ出さない。
- `script/verify_release_readback.py`
  - versioned Sparkle ZIP、stable手動ZIP、versioned手動ZIPを別directoryへ取得する。
  - 3コピーのsize / SHA-256とGitHub metadata、checksum、appcast lengthを照合する。
  - Windowsの自動発見はdraft / prereleaseを除外する。GitHub汎用Latestは選択に使わず、appcastが示すmacOS versioned releaseと一致することの確認にだけ使う。
  - workflow用のtag解決専用modeを追加し、`auto`または明示tagを1回だけpublished releaseへ解決する。
  - Windows feed targetはexact `HoverPocketWin-<version>-full.nupkg`だけを許可し、Setup / Portable等を`Type=Full`として指すmetadata confusionを拒否する。
  - Setup / Portableはexact `HoverPocketWin-win-Setup.exe` / `HoverPocketWin-win-Portable.zip`だけを許可する。
  - 実downloadした全Windows assetのname / size / SHA-256を決定論的なsnapshotとしてreportへ含める。
  - macOSの3 ZIP、stable / versioned appcast、versioned checksumの6資産を最初のimmutable snapshotへ含める。
  - appcastはnamespaceなし`rss` root、direct childの`channel` 1件、`item` 1件、`enclosure` 1件を必須にし、曖昧なXML構造を拒否する。
  - GitHub汎用Latestは全公開assetのdownload / digest検証完了後に再取得し、macOS versioned releaseとの一致を判定する。
- `script/verify_published_macos.sh`
  - 6資産を別々にdownloadし、snapshotのrelease tag / name / size / SHA-256と最後のGitHub metadata再取得まで一致させる。
  - 3 ZIPと2 appcastのbyte同一性、bundle ID、version / build、`SUFeedURL`、`SUPublicEDKey`、`TeamIdentifier=N7VVPW44ZA`、codesign / stapler / Gatekeeperを検証する。
- `script/tests/test_verify_release_readback.py`
  - versioned手動ZIPの正常系とdigest不一致拒否、Windows prerelease除外、GitHub汎用Latest置換拒否を追加した。
  - workflowの2つのreadback jobが同じ確定tagを使うこと、完全な`upload-artifact` commit SHAを使うこと、Setupを偽Full targetとして指すfeedを拒否することを追加した。
  - internally consistentな`Old-Setup.exe` / `Old-Portable.zip`を拒否し、公開readback stepが明示`bash`を使うことを追加した。
  - 8 asset snapshotの決定論的順序、formal jobのartifact依存、全asset download、署名前後のmetadata再照合を固定した。
  - macOS 6資産、Sparkle設定 / Team ID、Setup SFX全payload、Portable全payloadの回帰契約を追加した。
  - 非RSS root、複数direct channelの拒否と、download完了後にだけLatestを再取得する呼出順を固定した。
- workflow / README
  - formal gateがSetup、Portable、update packageの3署名を検査することを明記した。
  - `resolve-windows-release` jobでtagを1回だけ確定し、metadata / Authenticodeの両jobへ同じoutputを渡す。
  - 公開readback stepへ明示`bash`を指定し、`pipefail`でPython verifierの失敗をjobへ伝播する。
  - formal PowerShell verifierもcanonical Setup / Portable名へ揃えた。
  - formal jobはpublished readback成功後に同runのreport artifactを取得する。PowerShellはsnapshotの全assetを再取得・hashし、署名前後で同じGitHub metadata集合を確認する。

## Readback

- `python3 -m unittest script/tests/test_verify_release_readback.py`: 19件成功。
- `python3 -m py_compile script/verify_release_readback.py script/tests/test_verify_release_readback.py`: 成功。
- workflow YAML parse: 成功。
- `git diff --check`: 成功。
- PR source head `77dc721c8ac7684fa46fd92ef6d641e26263d8f0`:
  - release metadata verifier: 成功。
  - Windows Authenticode verifier syntax: 成功。
  - Windows verify: 成功。
  - PR Router: 成功。
- exact security diff scan `11fdb6d9-9e92-45d1-9ffe-c5f3df1c7fbc`: coverage complete、reportable finding 0件、sealed complete。対象rangeは`8a900c9...77dc721`。
- tag固定と完全Action SHAのincremental scan `efc4bd2f-f212-46e7-8a30-d6afea320c87`: coverage complete、reportable finding 0件、sealed complete。
- full `.nupkg` target固定のincremental scan `9e9fb119-5642-451d-baf5-0c3933ab344e`: 1 / 1 sourceを確認、reportable finding 0件、sealed complete。
- pipefailとcanonical asset名固定のincremental scan `25c81e42-a975-4749-9c7a-992218c1f256`: 1 / 1 production sourceと3 supporting surfaceを確認、reportable finding 0件、sealed complete。
- cross-job asset snapshot固定のincremental scan `0de1ebe2-4950-49ea-be21-f884bb4bd5f1`: 1 / 1 production sourceと3 supporting surfaceを確認、reportable finding 0件、sealed complete。
- exact diff scan `56fce146-0912-464c-9dfa-2be4262fd400`とincremental scan `44ccf6fa-b72b-495a-a731-757b87abd78e`: coverage complete、reportable finding 0件、sealed complete。
- Setup / Portable / macOS固定を段階確認したscan `1889e238-6153-4579-8ea6-d7801b6d2351`、`7291eb3a-5841-4176-942a-66f4ae39f02b`、`84906546-9cf0-472f-9e08-a33d5b3da72a`: いずれもcoverage complete、reportable finding 0件、sealed complete。最終scanは`1e6a8c8...3e8b79f`の4 surfaceを確認した。
- Velopack bundle headerとWindows publisher固定のexact scan `f436ab83-bc71-4ab6-b104-d49738aeeb45`: range `59cd53a...da75587`の5 / 5 fileを確認し、coverage complete、reportable finding 0件、sealed complete。
- 最終RSS / Latest順序修正のexact scan `ce3db805-6663-48a6-aad0-c650efc9be0f`: range `f6f24f6...e2e6a4a`の2 surfaceを確認し、coverage complete、reportable finding 0件、sealed complete。
- live beta readback:
  - macOS `v0.1.0-168`: versioned Sparkle ZIP、stable手動ZIP、versioned手動ZIPの実測size / SHA-256一致、Sparkle Ed25519署名成功。
  - Windows `win-v0.2.7`: 公開全assetのsize / SHA-256、checksum、full package SHA-1一致。
  - macOS / Windowsのrelease tag分離: 成功。
  - GitHub汎用Latest=`v0.1.0-168`でappcastのmacOS versioned releaseと一致: 成功。
  - 手動run [32421539868](https://github.com/shotaro311/hover-pocket/actions/runs/32421539868): `auto`を`win-v0.2.7`へ1回だけ固定し、新しいfull package名制約を含む全公開readbackとreport uploadが成功。artifactを別途downloadし、`status=passed`を確認した。
  - 最終手動run [32422064352](https://github.com/shotaro311/hover-pocket/actions/runs/32422064352): canonical Setup / Portable名とpipefailを含むheadで全job成功。artifactを別途downloadし、macOS `v0.1.0-168`、Windows `win-v0.2.7`、`status=passed`を確認した。
  - snapshot beta run [32422720262](https://github.com/shotaro311/hover-pocket/actions/runs/32422720262): `win-v0.2.7`の8 assetを全download/hashし、artifact内snapshotのtag、件数、canonical名、`status=passed`を別経路readbackした。
  - formal run [32422832966](https://github.com/shotaro311/hover-pocket/actions/runs/32422832966): deterministic / PowerShell parse / tag固定は成功し、published formal gateが現行未署名manifestを拒否した。正式署名済みasset snapshotの署名検証は引き続きAN8の実機gateである。
  - run [32627459690](https://github.com/shotaro311/hover-pocket/actions/runs/32627459690): .NETの一括SFX展開がcentral directory不一致で失敗し、安全なentry単位展開へ変更した。
  - run [32627869765](https://github.com/shotaro311/hover-pocket/actions/runs/32627869765): root nuspec探索の前提不一致を検出し、full package rootのexact nuspecへ固定した。
  - run [32628233979](https://github.com/shotaro311/hover-pocket/actions/runs/32628233979): Setup SFXを通常ZIPとして展開できない実形式を確認し、いったんSFX末尾とfull `.nupkg`全byteの直接照合へ変更した。この末尾推測は後続reviewでVelopack bundle header解析へ置換した。
  - run [32628492824](https://github.com/shotaro311/hover-pocket/actions/runs/32628492824): Setup payload同一性を含む全job成功。3 artifactを別経路downloadして内容を確認した。
  - 最終run [32629166708](https://github.com/shotaro311/hover-pocket/actions/runs/32629166708): exact head `3e8b79f217d2052a17b6acc101e320456ccb5d62`で全job成功。3 report artifactを新しい一時directoryへ別経路downloadし、macOS 6資産、3 ZIP / 2 appcastのbyte同一性、Sparkle設定、Team ID、codesign / notarization / Gatekeeper、Windows Setup全payload、Portable 506ファイル、release tagとsnapshotの一致を確認した。
  - publisher follow-up run [32638170997](https://github.com/shotaro311/hover-pocket/actions/runs/32638170997): exact head `da75587759959f5760eedb9a59b153d5971fc786`で全job成功。Windows native jobでVelopack marker / offset / lengthによる公開Setup payload解析を実行した。3 artifactを別経路downloadし、macOS 6資産、Windows 8資産、`setupPayload=full-package-byte-equivalent`、`portablePayload=full-package-application-byte-equivalent`、betaの`publisherIdentity=not-evaluated`を確認した。
  - final RSS / Latest run [32638515063](https://github.com/shotaro311/hover-pocket/actions/runs/32638515063): exact head `e2e6a4a4f7de80c9dd40578cf138e89a858aa5f3`で全job成功。3 report artifactを`/tmp/hoverpocket-run32638515063.k2JOcU`へ別経路downloadし、macOS 6資産と署名 / 公証 / Gatekeeper、Windows 8資産とSetup / Portable payload同一性、betaの`publisherIdentity=not-evaluated`を確認した。公開readback jobの成功により、厳格RSS構造とdownload後のLatest再取得も実データで通過した。
- 未確認:
  - ローカルMacにはPowerShellがないため、PowerShell parseはPRのWindows CIで確認する。
  - 現行Windows `0.2.7`は未署名betaであり、3点の実Authenticode検証は正式署名済みreleaseでのみ完了できる。
- Codex reviewの最終返信・解決は、進捗正本commitと最新head CIのreadback後に行う。

## 完了境界

この修正でCodex reviewの検証漏れを閉じる。AN8全体の完了には、正式署名済みWindows release、両OS実機のinstall / update / rollback / uninstall / reinstall、migration、backup / restore、offline / sleep-wake / soakが引き続き必要である。
