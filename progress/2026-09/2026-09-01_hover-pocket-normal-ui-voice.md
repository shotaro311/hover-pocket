# 2026-09-01 HoverPocket 通常UIとVoice Lane

## Timer限定候補から通常版へ切り替え

- Timerだけが表示されていたprocessは、物理Voice E2E専用候補build 619だった。通常版Providerの不具合ではなく、E2E候補が本番データを隔離するためRegistryをTimerだけへ限定する仕様による。
- build 619のprocessを停止した。停止後の機能設定、mic、remote audio、credentialはすべてinactiveだったが、既存performance receiptは`currentAttemptAttached=true / stop RPC=0`のままでHarness Stop verifierが失敗したため、build 619を物理E2E合格証拠には使わない。session metadataはその失敗状態を保持している。
- `dist/HoverPocket.app`を通常bundle ID `local.codex.hover-pocket`で再build・Apple Development署名し、起動した。E2E markerはなく、strict codesignはPASSした。
- 通常版設定は`hiddenProviders=[]`、Voice ProviderはCodex app-server、Voice LaneとAI-nativeを有効にした。OpenAI API keyは使用していない。

## 実画面readback

- Accessibilityで通常版パネルにMirror、Calendar、Sticky Notes、Calculator、Timer、Controls、Clipboard、Today Focus、Settingsのbuttonがあることを確認した。
- 実際にCalendarへ切り替わり、下部にVoice Laneの開始、Compact / Expanded切り替え、終了buttonが表示されることを確認した。マイク開始buttonは操作していない。
- CalendarはOAuth設定をbundleへ含めているが、実画面は`未読み込み / 読み取り専用`だった。Google accountの認証完了とは判定しない。
- アプリ実体は`/Users/shotaro/code/share/hover-menu-preview-ai-native-final-integration/dist/HoverPocket.app`。通常版processは1つだけ起動している。

## E2E終了証拠の修正

- server起点のRealtime close / terminal errorでは、current attemptのattached状態をfalseにして、stop RPC 0回を正しく許容する。
- local stop応答ではattached証拠を保持し、直前のstop RPC countをserial queueへ永続化する。performance gateはattached attemptにstop RPC exactly 1回を要求し、0回と2回を拒否する。
- 通常版では`MacOSVoiceE2EPerformanceStore.shared`がnilであり、Voice、audio、transcript、snapshot、Provider描画のhot pathへfile I/Oやpollingを追加していない。
- 独立エージェント再レビューはP0 / P1 / P2すべて0件。通常runtimeの性能低下、過剰な安全実装、blocking test不足はないと判定した。

## 検証

- Debug / Release `swift build` warnings-as-errors: PASS
- macOS Voice E2E performance self-test: PASS
- Voice E2E isolation: PASS
- Voice Foundation runtime: PASS
- Voice static contract: PASS、42 cases
- macOS Realtime renderer: PASS
- Panel layout: PASS、128 cases
- `git diff --check`: PASS
- `build_and_run.sh --verify`: PASS、通常版起動とstrict codesign readback済み

## 未完了gate

- 実マイク、remote audio、user / assistant transcript、Capability承認 / readbackはユーザーの明示操作が必要なため未実施。
- Calendarの保存済みGoogle account確認と実予定readは未完了。
- Draft PR #39のmerge、release、公開は行わない。
