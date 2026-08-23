# HoverPocket AI-native AN8 Pocket App健全性・復帰耐性

## 目的

AN8の長期運用条件として、ユーザー所有の生成Pocket Appが現在使えるか、最近使われているか、スリープ復帰後も再開できるかをHostが判定し、ユーザー自身が確認・無効化できるようにする。

## 実装

- macOS / WindowsへHost-owned `PocketAppHealthStore`を追加した。記録対象は初回activation、最終activation成功、最終利用、最終activation失敗、連続失敗数だけで、音声、会話、ユーザーデータ、Capability引数は保存しない。
- health recordはpackage IDごとのstrict JSON v1とし、ローカルのPocket App definition root配下`Health`へ保存する。bounded size、package ID validation、no-follow read、atomic replace、write後のbyte readbackを必須にした。
- 30日以上未使用のenabled Appだけを`unused / UNUSED_30_DAYS / disableSuggested=true`にする。提案はSettingsに表示するだけで、自動無効化しない。
- 3回連続のactivation失敗は`attention / ACTIVATION_FAILURES`とし、activation成功で失敗数を0へ戻す。health JSON破損、symlink / reparse、package管理問題は`attention`へ倒し、無効化提案は出さない。
- 生成Surfaceの実表示、Windowsの生成Provider選択、生成Host操作を利用として記録する。process内と永続Storeの両方で5分デバウンスし、頻繁なstate publishでdisk writeを増やさない。
- macOSはworkspace wake / session active、Windowsはsystem transitionでenabled AppをRegistry / Surfaceへ再activationし、実行後readbackを取り直す。Voice transitionがcancelされてもWindowsのPocket App復帰を`finally`で試行する。
- Settingsは各Appの正常、要確認、無効化済み、30日以上未使用を表示する。既存の明示的な無効化操作へ誘導し、Hostはユーザーの代わりに状態を変更しない。

## 決定論的検証

- 固定日時から30日と1秒進めて未使用提案を確認した。
- 利用記録後にhealthyへ戻ること、activation失敗3回でattention、次の成功で失敗数0へ戻ることを確認した。
- disabled Appへ提案を出さないこと、破損JSON、通常symlink、dangling symlinkをattentionへ倒して提案を出さないことを確認した。
- 5分以内の利用記録512回でrecord bytesが変わらず、一時fileが残らないことを確認した。
- system transition相当の再activationを64回反復し、Registry / Surfaceのactive App集合が増減しないことを確認した。

## ローカルreadback

- `swift build -Xswiftc -warnings-as-errors`: 成功。
- `.build/debug/HoverPocket --verify-pocket-app`: package / lifecycle / generation / capability migration / healthがすべて`ok`。
- `.build/debug/HoverPocket --verify-voice-foundation`: 成功。
- `.build/debug/HoverPocket --verify-panel-layout`: 128件成功。
- `python3 script/verify_pocket_contracts.py`: `14 schemas / 69 fixtures / 69 matched`。report 2回のbyte一致を確認した。
- `node --check windows/ui/settings/settings.js`: 成功。
- `git diff --check`: 成功。
- このMacには.NET SDKがないため、Windows C# Release build、native verifier、Settings bridge、rendered WebViewはDraft PR CIを受入gateにする。

## Draft PR readback

- Draft PR [#28](https://github.com/shotaro311/hover-pocket/pull/28)を`codex/ai-native-an8-compatibility-migration`へstackした。code headは`3b12a8a`である。
- Windows [32657261437](https://github.com/shotaro311/hover-pocket/actions/runs/32657261437)はRelease build警告0・エラー0、`pocket_app_health_verify=ok`、`pocket_app_runtime_activation_verify=ok`、Settings bridge、rendered WebView UIを確認して成功した。
- macOS [32657261433](https://github.com/shotaro311/hover-pocket/actions/runs/32657261433)はwarnings-as-errors buildと`pocket_app_health_verify=ok`を含む既存verifier一式が成功した。Router [32657261441](https://github.com/shotaro311/hover-pocket/actions/runs/32657261441)も成功した。
- PRは`Draft / MERGEABLE / CLEAN`、review / comment 0件、code head時点のremote parity `0 / 0`である。
- 追加レビューでdangling symlinkを記録なしと誤認し得る境界を修正した。macOSは`lstat`、Windowsはreparse属性を先に確認し、`1854d72`のWindows [32657525511](https://github.com/shotaro311/hover-pocket/actions/runs/32657525511)、macOS [32657525510](https://github.com/shotaro311/hover-pocket/actions/runs/32657525510)、Router [32657524602](https://github.com/shotaro311/hover-pocket/actions/runs/32657524602)が再成功した。

## 安全境界

- health保存失敗は生成App本体の実行を止めず、Settings表示だけを保守的に維持する。
- inactive / removed / built-in Today Focusを生成Appの利用として記録しない。
- network送信、telemetry、会話本文、Capability payloadはhealth recordへ含めない。
- 未使用判定は自動disable / remove / data deleteを行わない。
- system transition復帰は現在のimmutable active packageを再検証し、RegistryとSurfaceのreadback不一致時は既存fail-closed / disable経路を使う。

## 外部委譲と残件

- ChatGPT Pro OrchestratorのAN8-C backup / export / restore正本runは`monitoring / pending / unclaimed`であり、正式delivery前の成果物は読んでいない。
- WindowsはDraft PR CI、実Windows端末のsleep / wakeとSettings表示を最終受入gateにする。
- AN8全体ではAN8-C成果物の正式回収・統合、署名済み配布、macOS / Windows専用feedの配信後readback、rollback演習、長期soakの実時間観測が残る。
- このstack PRはmainへ自動mergeしない。
