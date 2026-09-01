# 2026-09-01 HoverPocket 通常UIとVoice Lane

## 再ホバー後の音声会話復帰

- ユーザーが通常版Codex Voiceで実際に会話できたことを確認した。パネルを閉じると、要件どおり音声はmuteされUIはdetachされるが、Codex app-serverのroot threadとRealtime接続はアプリ生存中に保持される。
- 再表示後のsnapshotは`connected + muted + uiAttached`になる。従来の大きなマイクbuttonは`disconnected`専用だったため無効になり、別のspeaker button以外に分かりやすい復帰導線がなかったことが原因である。
- 大きなマイクbuttonを開始 / 再開の共通操作にした。`connected + muted + uiAttached`では既存接続へ`setMuted(false)`だけを送り、`disconnected`では従来どおり`beginAudioSession()`を呼ぶ。再表示だけではunmuteしないため、ホバーだけで録音が再開することはない。
- 一時停止中は`一時停止中 · マイクを押して再開`、会話欄は`マイクを押すと音声会話を再開します。`、Accessibility labelは`音声会話を再開`と表示する。
- runtime verifierへdetach → mute、reattach → mute維持、明示resume → unmute、adapter `startCount == 1`維持を追加した。既存接続を再利用し、重複Realtime sessionを開始しないことをreadbackした。
- Debug / Release warnings-as-errors、Voice Foundation runtime、Voice静的42 cases、Panel 128 cases、Capability 20 handlers、`git diff --check`、通常bundle再build・起動、strict codesignがPASSした。通常版processは`dist/HoverPocket.app`から起動している。
- 独立レビューはP0 / P1 / P2すべて0件。再表示時の自動録音なし、新規開始回帰なし、追加I/O / polling / probeなし、Voice hot path性能への実質的な影響なしと判定した。

## 現在Voiceから使える機能

- 自然な音声会話と音声応答。Codex app-server / ChatGPT account経路を使い、通常設定ではOpenAI API keyを必要としない。
- `calendar_events_list`: ログインとCalendar権限がある場合に、今日の予定を最大24件まで読み取る。タイトル、開始、終了を返す。
- `calendar_event_create`: タイトル、開始、終了、終日指定で予定を1件作成する。毎回ネイティブ承認を表示し、CapabilityBrokerの実行後readbackを確認してから成功を返す。
- `timer_countdown_start`: 1秒から24時間までのカウントダウンTimerを任意タイトル付きで開始する。毎回ネイティブ承認を表示し、CapabilityBrokerの実行後readbackを確認してから成功を返す。
- Compact / Expanded表示、会話transcript、現在rootに属するsession cards、mute / unmute、明示終了、パネルclose後のroot / transcript / session保持と明示再開。
- RegistryにはSticky Notes、Clipboard、Controls、Calculator、Timer pause / resume / stop等もあるが、Voice sessionのtool allowlistは上記3 toolだけであり、まだ音声からは操作できない。Calendar編集 / 削除、Timer一時停止 / 停止、Pocket App生成・導入もVoice toolとしては未公開である。

## Codex Voice開始前の表示修正

- ユーザー画面は`切断・待機中`でsafe errorなしだった。実コードではCodex providerの`conversationPlaceholder`がruntime状態に関係なくcompatibility gate文言を表示しており、実際の互換性失敗と開始前の待機を区別できなかった。
- macOS System Settingsのマイク一覧を読み取り、`HoverMenuPreview`と隔離`HoverPocketVoiceE2E`がともにONであることを確認した。設定変更は行っていない。
- 通常bundleのCodex app-server Realtime verifierは、ChatGPT account、19 voices、ephemeral thread、SDP、WebRTC connected、process closedを確認した。CLI verifierは物理マイクを取得しないため、バックエンドとWebRTC契約の確認に限定する。
- 要件`R-SHELL-006`に従い、Voice LaneをONにしただけでは自動listenせず、Panel上の明示マイク操作で開始する契約は維持した。
- Compact / Expanded共通のマイク開始操作を36 x 36の円形buttonへ変更した。開始可能な待機状態は`開始前・マイクを押してください`、本文は`マイクを押すとCodexとの音声セッションを開始します`と表示する。接続中 / 接続済みのsymbolとAccessibility labelも実接続状態に合わせた。会話欄はdisconnected / connecting・recovering / connectedを開始案内 / 接続中 / 話しかけてくださいへ分ける。
- `VoiceFoundationVerificationCommand`へCodex開始前の日本語statusと、開始前 / 接続中 / 接続済みの会話文言回帰を追加した。Debug warnings-as-errors、Voice Foundation runtime、静的42 contract、Panel 128 cases、`git diff --check`、通常bundle再build、strict codesign、bundle自身の非物理Realtime verifierはPASSした。bundle binaryに新しい3状態の英語文言があり、旧compatibility placeholderがないことも別readbackした。
- 独立レビューは開始後も開始案内が残るP2を1件検出し、上記3状態分岐と回帰assertで解消した。最終P0 / P1 / P2はすべて0件で、明示開始条件、36 x 36 layout、Accessibility、通常runtime / Voice hot path性能に問題なしと判定した。
- 修正版通常processを起動済み。物理マイク、可聴remote audio、user / assistant transcript、Voice経由Capability実行は、Panelのマイクbuttonをユーザーが押して発話する人手gateとして未完了である。

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
