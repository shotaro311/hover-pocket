# HoverPocket AN8 macOS notarized release candidate

## 対象

- branch: `codex/ai-native-core-ga-final-integration`
- exact head: `cd71796aabceee56407e1b738c5ceb59255d1c86`
- app version: `0.1.0`
- app build: `583`
- public release before this work: `0.1.0 (168)`

## 実行結果

- macOS KeychainのDeveloper ID Application identityを検出し、Keychain profile `hover-pocket`でnotary historyをreadbackした。秘密鍵や認証値は表示・exportしていない。
- `APP_VERSION=0.1.0 APP_BUILD=583 NOTARYTOOL_PROFILE=hover-pocket ./script/notarize_release.sh`を実行した。
- Apple notary submission `a11f687d-ce71-463f-bd5d-7080b8b21214`は`Accepted`。staple後のapp本体と最終ZIP再展開後のappで、次を確認した。
  - `codesign --verify --deep --strict --verbose=2`: success
  - `xcrun stapler validate`: success
  - `spctl --assess --type execute --verbose=2`: `accepted`, `source=Notarized Developer ID`
- `PUBLISH_DRY_RUN=1 PUBLISH_PREPARE_RELEASE=0 PUBLISH_REQUIRE_NOTARIZED=1`で公開scriptを検証し、外部releaseを変更せず成功した。
- `HoverPocket-0.1.0-583.zip`:
  - SHA-256: `6dbcba8649850a7c36bdc493af266a41a73871e321c15d88d2d9609c72b1157f`
  - top-level: `HoverPocket.app`のみ
  - size: 約9.0 MiB
- appcastは`sparkle:version=583`、`sparkle:shortVersionString=0.1.0`、versioned download URL、Sparkle EdDSA signatureを持つ。
- hardened runtime、secure timestamp、stapled notarization ticketを確認した。release用entitlementsは次の3件である。
  - `com.apple.security.automation.apple-events`
  - `com.apple.security.device.audio-input`
  - `com.apple.security.device.camera`

## 配布物からの機能検証

notarization済み`dist/HoverPocket.app/Contents/MacOS/HoverPocket`から次を実行し、全件成功した。

- `--verify-capabilities`: 20 handler、Calculator、Controls readback、Timer、Sticky、Calendar
- `--verify-broker`: 21 descriptor、Today Focus、approval presentation、Pocket App、retention governance、negative case
- `--verify-pocket-surface`: valid 6 node、negative 15 case
- `--verify-pocket-app`: package、lifecycle、generation、migration、health、workspace backup
- `--verify-voice-foundation`: default-off、root scope、transcript bound、compact / expanded geometry
- `--verify-voice-e2e-isolation`: Debug-only marked bundle、fresh temp root、外部integration拒否、process-memory credential、Release拒否

## 公開境界

- GitHub Release `v0.1.0-583`は作成していない。
- `macos-latest`と公開appcastは変更していない。
- Draft PR #39はReady / mergeへ変更していない。
- build 583は公開用候補として署名・notarization・配布物内verifierまで完了したが、一般公開は未完了である。

## 残りのmacOSゲート

- 隔離Voice E2E appで、実マイク入力、OpenAI Realtime接続、user / assistant transcript、remote audio再生、Timer Capability readbackをユーザーが物理確認する。
- production UIでVoice Lane compact / expandedとセッションカードを実画面確認する。
- 実モデルによるPocket App生成はproduction generator OFFのため、セキュアな有効化条件が満たされるまで実行しない。
- 上記結果とPR全体の受入後に、versioned releaseと`macos-latest`を公開し、公開URLから再取得したZIP、appcast、Sparkle署名、Gatekeeperを別経路でreadbackする。

## Windows方針

- 正式Windows署名はSignPath Foundationの無料OSS枠を第一候補とする。
- HoverPocketはMIT Licenseだが、SignPathの申請、プロジェクト受入、build origin verification、manual approval policy、MSI / helper署名統合は未完了である。
