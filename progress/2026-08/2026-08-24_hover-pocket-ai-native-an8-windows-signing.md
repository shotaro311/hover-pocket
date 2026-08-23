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

## Remaining gates

1. Windows CI / release readback CIでPowerShell contractを実行し、artifact / logをreadbackする。
2. 正規コード署名証明書を取得し、Windows certificate storeへ安全に導入する。secretをGitやprogressへ記録しない。
3. 正規publisher証明書SHA-256をrepository variableへ登録する。
4. formal modeで署名済みWindows release候補を生成し、ローカル3成果物readbackを通す。
5. Windows専用tagへ`--latest=false`で公開し、formal readback workflowで公開3成果物の署名・timestamp・publisher一致を再検証する。
6. 署名済み旧版 / 新版が揃った後、Windows install / update / rollback / re-upgrade / uninstall / reinstall transitionを実行する。
