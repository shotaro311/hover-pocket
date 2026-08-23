# HoverPocket AI-native AN8 Windows formal signing pipeline

## Scope

- AN8のOS別release / feed / signing / readbackのうち、未署名Windows betaから正式署名版へ進むための生成経路をfail closedで追加する。
- 公開済みreleaseの変更、未署名beta installerの実行、証明書やsecretの登録は行わない。
- AN8-C backup / export / restoreのChatGPT Pro runとは担当範囲を分離し、正式delivery前の成果物を読まない。

## Public release readback

- 現行stack head `c8366b03a4d61620825d1b215c82ce47b4443a1b`から`Verify Published Release Readback`をbeta modeで手動実行した。
- run [32657994406](https://github.com/shotaro311/hover-pocket/actions/runs/32657994406)は6受入jobが成功し、formal Authenticode jobだけがbeta指定どおりskipされた。
- 3 artifactを`/tmp/hoverpocket-release-readback.lzqzjU`へ別経路で取得した。
  - `release-readback-report.json`: SHA-256 `f547e7f8b173697a611ac5c3f0482b59bb0d71668dd23d4a37c4683ebd613e05`
  - `macos-gatekeeper-readback-report.json`: SHA-256 `9c034f6b7b189ccf0f910d1a9891b27d6ec4af903defa9a53e2633bbda4bfe7c`
  - `windows-package-identity-readback-report.json`: SHA-256 `38382f9063bc45207032f9ca12b5fe3db2de4e1a0736299f8a3bc2309cf1c083`
- macOSは`macos-latest` / `v0.1.0-168`、build 168、Developer ID、stapled notarization、Gatekeeper accepted、Sparkle Ed25519、manual ZIP parityが合格した。
- Windowsは`win-v0.2.7`、Setup / Portable / full packageのversion、runtime、payload identity、snapshotが合格した。manifestは`authenticode=unsigned`であり、publisher / signerはbetaでは評価しない。
- repository variable `WINDOWS_SIGNER_CERT_SHA256`とActions secretはいずれも未登録である。正式署名済みreleaseは未作成のため、formal gateは未完了である。

## Implementation

- stack branch `codex/ai-native-an8-windows-signing-pipeline`を`c8366b0`から作成した。
- `windows/script/publish_release.ps1`へ`beta / formal` signing gateを追加した。
  - betaは署名引数が混在した時点で停止し、従来どおり`authenticode=unsigned`だけを生成する。
  - formalはWindows証明書storeのSHA-1 thumbprint、期待publisher証明書SHA-256、credentialを含まないHTTPS RFC 3161 URLを必須にする。
  - PFX path / passwordを引数として受け取らない。
  - Velopack `--signParams`へ`/fd sha256 /td sha256 /tr`を渡す。
  - pack後にSetup、Portable内アプリ、full package内アプリを別々に読み、valid Authenticode、timestamp、3点の署名者一致、期待publisher一致を確認する。
  - 全readback成功後だけmanifestを`signed-timestamped-verified`にする。
- Security差分レビューで、version固定の既存publish / release directoryを再利用すると、過去buildの余剰payloadを新しい署名releaseへ混入させ得ることを確認した。出力directoryが空でない、通常directoryでない、reparse pointである場合は削除・上書きせず停止し、fresh `OutputRoot`を必須にした。
- PowerShell contract testは、betaの互換動作、formal引数の決定性、署名引数混在、不正fingerprint、HTTP timestamp、credential入りURLのfail-closedを固定する。
- Windows CIとrelease readback CIへcontract testを追加した。
- Velopackの現行公式docsで`vpk pack --signParams`と絶対path / signtool引数の契約を確認した。

## Verification

- `python3 -m unittest script.tests.test_verify_release_readback`: 19件成功。
- `python3 -m py_compile script/verify_release_readback.py script/tests/test_verify_release_readback.py`: 成功。
- `bash -n script/verify_published_macos.sh script/verify_macos_release_transition.sh`: 成功。
- `node --check windows/ui/settings/settings.js`: 成功。
- workflow YAML parse: 成功。
- `git diff --check`: 成功。
- このMacにはPowerShell / .NET SDKがないため、PowerShell parser、contract test、Windows Release buildはDraft PR CIを最終受入gateにする。

### Draft PR readback

- Draft PR [#29](https://github.com/shotaro311/hover-pocket/pull/29)を、`codex/ai-native-an8-app-health`をbaseにしたstack PRとして作成した。
- code head `397b52f4a81ec14ff01ac8cdd96a3786b1a87829`のWindows run [32658702169](https://github.com/shotaro311/hover-pocket/actions/runs/32658702169)は成功した。
  - Release build: warning 0 / error 0。
  - PowerShell parser: 成功。
  - `windows_release_signing_contract_verify=ok`をreadbackした。
  - Capabilities、Broker、Pocket Surface、Voice、Updater、rendered WebView UIを含む全stepが成功した。
- release readback workflowはpush [32658690390](https://github.com/shotaro311/hover-pocket/actions/runs/32658690390)とPR [32658702176](https://github.com/shotaro311/hover-pocket/actions/runs/32658702176)でdeterministic testsとPowerShell publisher contractが成功した。公開asset jobはschedule / manual dispatch限定のためskipが正しい。
- PRは`Draft / MERGEABLE / CLEAN`、review / comment 0件、remote parity `0 / 0`である。

## Security review note

- Codex Security diff scan `ad2ab060-a5e7-4e6f-93d7-c02981da8a93`はpreflight 3 / 3に合格したが、Workbenchがworking-tree inventoryを0件と返し、実Git差分6件を登録できなかったためsealed reportにはしていない。
- exact Git差分6件は手動で全件確認した。既存出力再利用による余剰payload混入のhardeningを適用し、空でないdirectory / file / reparse pointのfail-closed contractをWindows CIで確認した。
- TAC access statusはconnector未接続のため未確認であり、保護scan出力のUI表示可否は未確認である。

## Remaining gates

1. 正規コード署名証明書を取得し、Windows certificate storeへ安全に導入する。secretをGitやprogressへ記録しない。
2. 正規publisher証明書SHA-256をrepository variableへ登録する。
3. formal modeで署名済みWindows release候補を生成し、ローカル3成果物readbackを通す。
4. Windows専用tagへ`--latest=false`で公開し、formal readback workflowで公開3成果物の署名・timestamp・publisher一致を再検証する。
5. 署名済み旧版 / 新版が揃った後、Windows install / update / rollback / re-upgrade / uninstall / reinstall transitionを実行する。

## macOS release transition readback

- stack exact head `b95ef1681510781a38ccbb0b95cbf51384faa594`から`Verify Release Install and Rollback Transitions`を手動実行した。macOS実行だけを有効化し、Windows実行と未署名beta許可は無効のままにした。
- run [32664697767](https://github.com/shotaro311/hover-pocket/actions/runs/32664697767)は、macOS / Windows script contractとmacOS実transitionが成功し、Windows実transitionは指定どおりskipされた。
- `macos-release-transition` artifactを別経路で取得し、receipt SHA-256 `7d72c7221dc7dc6ca9dcb8df1f22ee60817fab5e353f201c036ee8a25d4080ea`を固定した。
- receiptは`status=passed`、`v0.1.0-161 -> v0.1.0-168`のinstall、upgrade、rollback、uninstall、reinstallがすべて`verified`、`userDataPreserved=true`を示した。
- これによりmacOSの公開済み署名・公証版transition gateは完了した。Windowsは正式署名済みの旧版 / 新版が存在しないため、正式transition gateを未完了として維持する。
