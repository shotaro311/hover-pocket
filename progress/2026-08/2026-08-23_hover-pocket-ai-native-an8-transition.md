# HoverPocket AI-native AN8-B Release Transition Gate

## 結果

PR [#23](https://github.com/shotaro311/hover-pocket/pull/23)に、公開済み旧版と新版を使い捨てrunnerへ導入し、更新・復元・削除・再導入を確認するAN8-B gateを実装した。macOSはローカルとGitHub runnerの両方で実公開版の全遷移が成功した。Windowsは構文とrelease snapshot差し替え拒否contractまで成功し、未署名betaの実行だけを明示承認待ちに残した。

## 実装

- `.github/workflows/release-transition-verify.yml`
  - macOS / Windowsの実行inputを分離した。
  - 自由入力tagをshellへ直接展開せず、環境変数経由に固定した。
  - 通常push / PRでは構文とsnapshot contractだけを実行する。
  - 実公開release codeは手動workflowで対象OSを明示した場合だけ使い捨てrunnerで実行する。
  - `actions/checkout`と`actions/upload-artifact`を完全commit SHAへ固定した。
- `script/verify_macos_release_transition.sh`
  - 旧版・新版releaseのpublished状態と全assetの名前、size、GitHub SHA-256、URLをcanonical snapshotへ固定した。
  - downloadは初期snapshotだけを参照し、reinstall後に両releaseを再取得して完全一致を確認してからpassed receiptを書く。
  - version、build、ZIP構造、checksum、Sparkle Ed25519、codesign、公証staple、Gatekeeperを確認する。
- `windows/script/verify_release_transition.ps1`
  - 同じwhole-release snapshotと最終再取得比較を実装した。
  - Windows CIへdigest変更を必ず拒否する決定論的contract testを追加した。
  - 未署名betaは`AllowUnsignedBeta`がなければ停止する。
  - `signed-timestamped-verified`はSetupだけで合格にせず、full package内アプリを正式署名readback snapshotへ固定する連携が入るまで停止する。

## 検証

### ローカルmacOS

`bash script/verify_macos_release_transition.sh v0.1.0-161 v0.1.0-168`がexit 0となった。

- install: verified
- upgrade: verified
- rollback: verified
- re-upgrade: verified
- uninstall: verified
- reinstall: verified
- user data preserved: true
- 開始 / 終了release snapshot: 一致
- Developer ID署名、公証staple、Gatekeeper、Sparkle署名: 合格

検証用の一時directoryは終了時にmacOSのTrashへ移動した。

### PR CI

head `35077c9be0109089701cc55788e7aa72aad8e2fc`で次が成功した。

- Codex PR Router
- Verify Windows
- macOS transition script syntax
- Windows transition script syntax
- Windows immutable release snapshot contract

### 手動実機CI

手動workflow [32646526001](https://github.com/shotaro311/hover-pocket/actions/runs/32646526001)で次を確認した。

- macOS実transition: success
- macOS contract: success
- Windows contract: success
- Windows実transition: 指定どおりskip
- receipt artifact ID `9495013952`: expired=false、289 bytes

artifactを新しい一時directoryへ別経路downloadし、`status=passed`、旧版`v0.1.0-161`、新版`v0.1.0-168`、全遷移`verified`、`userDataPreserved=true`を`jq`で確認した。readback後の一時directoryはTrashへ移動した。

初回run [32646384473](https://github.com/shotaro311/hover-pocket/actions/runs/32646384473)は、`actions/upload-artifact`のSHAが39文字でGitHub setupに拒否された。GitHub APIで完全40文字commit SHAを照合して修正し、成功runでuploadまで確認した。

## Security

- `b4dec798-00d3-4a79-8b1e-a3019b036dea`
  - 修正前rangeを確認。
  - release途中差し替えでstale passed receiptが残り得るCWE-367をlow 1件として検出した。
- `cb82d38f-2c6f-4cdc-b069-34cbb261bab4`
  - whole-release snapshot修正後のfull rangeを6領域確認。
  - coverage complete、reportable finding 0件、sealed complete。
- `3ec61eaa-b29d-4b70-8e27-629bd51b599b`
  - final upload-artifact pin修正を2領域確認。
  - coverage complete、reportable finding 0件、sealed complete。

## 現在の境界

- PR #23はDraft、`MERGEABLE / CLEAN`。mergeは行っていない。
- macOS package lifecycle gateは実用レベルのCI証拠まで完了した。
- Windows 0.2.xは公開未署名betaのため、実行には別の明示承認が必要である。
- Windows正式署名版のreleaseはまだ存在せず、formal transitionは意図的にfail closedである。
- このgateは使い捨てrunner上のpackage lifecycleを確認する。日常利用端末でのSparkle / Velopack UI、自動更新、実データmigration、sleep-wake、長時間soakは後続gateである。
