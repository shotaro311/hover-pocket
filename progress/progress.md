---
project_slug: hover-menu-preview
updated: 2026-09-04
updated_by: codex
status: ai-native-in-progress; an2-merged; an3-a-pr-ready; an3-b1-draft-pr-ci-green; an3-b2-draft-pr-ci-green-security-clean-policy-blocked; an3-b3a-draft-pr-ci-green; an3-b3b-windows-security-ci-green-physical-e2e-pending; an3-b3b-macos-draft-pr-ci-green-physical-e2e-pending; macos-codex-appserver-chatgpt-bundled-0.150-live-webrtc-passed-no-physical-mic; macos-codex-appserver-broker-tool-live-probe-verified; macos-codex-appserver-live-model-timer-tool-verified; macos-codex-appserver-managed-chatgpt-login-local-verified-human-login-pending; macos-normal-ui-all-providers-voice-lane-readback; macos-voice-e2e-isolation-draft-pr-ci-green-security-clean-physical-e2e-pending; macos-voice-e2e-performance-readback-local-verified; macos-voice-e2e-terminal-receipt-fixed-local-verified; macos-voice-e2e-build608-legacy-nonphysical-only; macos-voice-e2e-build618-stopped; macos-voice-e2e-build619-stopped-receipt-invalid; macos-calendar-read-broker-live-verified; an4-merged; an5-a-merged; an5-b-merged; an5-c-pr-ready; an5-credential-broker-draft-pr-ci-green; an5-credential-peer-identity-draft-pr-ci-green-security-clean; an5-credential-mutual-identity-draft-pr-ci-green-security-clean; an5-credential-delivery-draft-pr-ci-green-security-clean-macos-auth-canary-passed; macos-codex-confinement-canary-passed; windows-codex-confinement-downgrade-negative-control-ci-green-positive-elevated-blocked-by-reparse-finding; windows-codex-sandbox-production-fail-closed-ci-green-original-path-fixed; windows-codex-sandbox-helper-internal-ci-green-semantic-readback-security-clean; windows-codex-sandbox-per-machine-msi-ci-green; windows-settings-fixed-helper-uac-boundary-ci-green-physical-canary-pending; production-generator-off; core-capability-reintegration-local-verified; core-integration-candidate-local-verified; core-ga-legacy-ai-path-removed-local-verified; core-ga-final-integration-draft-pr-ci-green-physical-e2e-pending; an8-a-pr-ready-review-resolved; an8-b-draft-macos-transition-verified-windows-beta-transition-verified; an8-c-draft-pr-ci-green; an8-retention-draft-pr-ci-green; an8-compatibility-migration-draft-pr-ci-green; an8-app-health-local-verified; an8-windows-signing-contract-ci-green-security-fixed-physical-signing-pending; windows-signpath-foundation-selected-application-pending; macos-an8-build583-notarized-release-candidate-verified-unpublished; macos-build597-notarized-rejected-packaged-realtime-local-network-gate; macos-build599-notarized-artifact-verified-packaged-realtime-local-network-gate; macos-build605-notarized-release-candidate-verified-unpublished; macos-build615-notarized-exact-runtime-head-rc-unpublished; macos-build628-voice-start-fix-notarized-unpublished-physical-voice-tools-accepted; macos-build629-voice-options-notarized-unpublished-physical-options-pending; an8-pro-gap-audit-complete-no-go; provider-bound-codex-physical-voice-ci-green; macos-panel-soak-verified; macos-settings-window-readable-and-resizable; an8-exact-runtime-head-evidence-bundle
---

## 2026-09-05 Googleログインと天気の現在地修正

- 本番629でGoogle設定が欠落し、位置情報の署名entitlementもなかったことを確認。既存審査済み設定の復元、配布前検証、location entitlement、20秒timeout / cancel / stale callback拒否、SettingsからのGoogle復元を実装した。
- Debug、現在地8シナリオ、配布設定5テスト、Panel / Voice検証はPASS。署名済み修正版の実機受入と公開readbackへ進む。
- 詳細: `progress/2026-09/2026-09-05_hover-pocket-google-weather-fix.md`。

## 2026-09-05 macOS 629の本番配信完了

- 追加確認: `/Applications/HoverPocket.app`の旧版168からアプリ内Sparkleで629へ更新・再起動済み。署名・公証と、設定の「アップデートはありません」を確認した。

- ユーザーの明示依頼により、公証済みbuild 629をmacOS本番フィードへ配信する。元の開発worktreeを保全し、`codex/macos-release-629`へ配信時点のソースを保存した。
- 配布ZIPの署名・公証・Gatekeeper・Sparkle Ed25519と、配布binaryの主要8検証がPASS。公開URLからZIPとappcastを再取得し、629への更新、hash一致、署名・公証・Gatekeeper・Sparkle署名を確認した。
- 詳細: `progress/2026-09/2026-09-05_hover-pocket-macos-release-629.md`。

## 2026-09-04 Voice設定とパネル非表示時の継続

- Voice Lane設定に`voiceContinueWhenPanelHidden`（既定OFF）と`voiceActionConfirmationEnabled`（既定ON）を追加し、AppSettingsのUserDefaults永続化、Settingsの日本語 / 英語Toggle、Voice OFF時のdisabledを実装した。
- パネルcloseは既定でmic / remote audioをmuteする。継続設定ONでも、既にconnectedかつunmutedの場合だけUI detachとして音声を維持し、connectingまたはmutedから自動開始・自動unmuteしない。設定をOFFへ戻したときはhidden中でも即時muteし、再hoverでsession、transcript、cardを保持する。
- Codex WebRTCのmute stateをJS内で保持し、既存remote audioとmute後に到着したremote trackへも適用する。明示終了後の新規sessionではmic / remoteをunmutedへ初期化する。BYOK / Codexの操作確認は保存値を非同期伝播せず、各approval開始時にsettings closureを一度だけsnapshotする。
- 確認OFFは現行5種（Calendar create、Timer start、Sticky upsert、brightness、volume）のnative presenterだけを省略し、Broker prepare、permission、decideApproval、execute、readback、audit、Calendar別grant、Timer 3件 / 分制限を維持する。将来tool、破壊的操作、native authority、生成Appへ自動拡張しない。
- 接続中にパネルが隠れた場合はpermission leaseを失効し、開始が遅れて成功しても`disconnected / idle / muted`へ戻す。確認OFFの自動承認はBroker実行とreadbackが終わるまで1件のreservationを保持し、同時書き込み、実行途中cancel、cancel後のreservation解放を検証した。
- Swift debug / release warnings-as-errors、`--verify-voice-foundation`、Node VMを含むPython静的Verifier、Capability、Broker、Voice E2E isolation、Codex app-server Realtime、`git diff --check`がPASSした。独立レビューの最終結果はP0 / P1 / P2すべて0件で、通常の逐次tool chainやVoice hot pathに有意な性能低下はない。
- `0.1.0 (629)`をDeveloper ID署名・公証した。submission `3b9a9f55-4e61-4ff7-92bc-c6e9c471fa49`は`Accepted`。app本体とZIP再展開後のstrict codesign、stapler、Gatekeeper、ZIP SHA-256をreadbackし、SHA-256は`627ad8d7d833221757f860946f3aca5f54506b716e15f3a13e1c0ba7044a1f42`。通常bundleをPID `52719`で起動した。
- GitHub Release、公開macOS appcast、PR、branchは変更していない。実マイクでのhidden continuation、remote audio継続、確認OFFの実操作はbuild 629でユーザー確認待ち。

## 2026-09-04 Codex Voice開始失敗の修正

- 通常版で「音声接続を開始できませんでした」と表示される報告を調査した。Codex app-serverはChatGPT account、19 voices、ephemeral thread、SDP、WebRTC、teardownまで成功しており、開始失敗はmacOS WebViewの`getUserMedia`と詳細エラーがgeneric `voice_start_failed`へ上書きされる経路へ限定した。既定入力はUSB接続のDJI MIC MINIで、失敗時のCoreAudio HALログも確認した。
- マイク取得を最大4候補に限定し、既定device、constraints非対応時だけplain default、同一groupを除外した代替deviceの順で試すようにした。permission拒否、deviceなし、不明エラーは即時停止し、stop / detach / timeout後に遅れて成功または`NotReadableError`が返っても次の取得へ進まない。
- 明示したマイク操作に紐づくpermission leaseとoperation epochを追加し、詳細な安全エラーをUIまで保持した。ProviderやOpenAI APIへの自動fallback、無限retry、polling、通常Hover経路の追加I/Oは追加していない。
- Luna Maxが実装し、別エージェントが安全性・通常動作・性能を独立レビューした。初回レビューのrace、候補重複、lease範囲、terminal error再試行、テスト網羅性の指摘をすべて修正し、最終findingは0件となった。
- Debug / Release warnings-as-errors、Voice Foundation、静的42 contract、Node VMによるlate success / late `NotReadableError`、Codex app-server Realtime、`git diff --check`がPASSした。
- `0.1.0 (628)`をDeveloper ID署名・公証した。submission `c4a78c35-ae53-43bc-b990-e1a0cad84e9a`は`Accepted`。app本体とZIP再展開後のstrict codesign、stapler、Gatekeeperが成功し、ZIP SHA-256は`7d86d140e9b8781361a0a60bc40aee11b97841d16f7f2f580e462957ac0cc500`。通常bundleをPID `42572`で起動した。
- ユーザー実機確認で音声会話、Sticky Notes追加、明るさ変更、音量変更がすべて動作した。GitHub ReleaseとmacOS appcastの公開先は変更していない。
- 詳細: `progress/2026-09/2026-09-04_hover-pocket-voice-start-fix.md`。

## 2026-09-01 Voice Lane capability tools and single microphone control

- Voice LaneのCompact / Expandedで、開始・接続待ちキャンセル・会話終了・再ホバー後の既存session再開を同じ大きなマイクcontrolへ統合した。connecting / recovering中も同じcontrolで保留中の開始をキャンセルでき、再表示だけでは録音を再開しない。別Voice session終了buttonは置かない。
- macOSの共通`OpenAIRealtimeMacOSCapabilityRuntime`へ、Registry / CapabilityBroker経由の`sticky_note_upsert`、`controls_brightness_set`、`controls_volume_set`を追加した。Calendar権限ありでは6 tool、権限なしではTimerと3つの新toolの4 toolだけを公開し、Provider Store直接参照は行わない。
- `controls.brightness.get@1`をprivate read capabilityとして追加し、明るさの相対変更は現在値をBroker readbackして0〜100のpercentage pointsで計算する。「10%下げて」は10ポイント減、`comfortable`は明るさ70% / 音量50%、`maximum`は100%、`minimum`は明るさ5% / 音量0%としてclampする。OS値の実行後readbackを必須にした。
- 付箋追加とControls変更は既存のBroker approval policyを通し、active writeのsingle-flight、idempotency、cancellation、safe errorを維持した。Timerの1分3件rate limitはTimer startだけへ限定し、付箋 / Controlsを不必要に止めない。
- macOSのVoice Foundation verifierでSticky readback、brightness `decrease value:10`、volume `preset maximum`、strict invalid arguments、idempotent replayを検証した。Codex app-server model verifierは4 tool面を公開し、Timerだけを実行する検証後にSticky Notesが空、Controls状態が不変、Calendar createが0件であることをreadbackする。
- macOS Debug / Release warnings-as-errors、`swift run HoverPocket --verify-capabilities`（21 handlers）、`--verify-broker`（22 descriptors / 21 handlers）、`--verify-voice-foundation`、`--verify-codex-app-server`、`python3 script/verify_voice_foundation.py`、`python3 script/verify_pocket_contracts.py`（72 fixtures）、`git diff --check`、`./script/build_and_run.sh --verify`がPASSした。通常bundleを再署名・起動し、strict codesign、単一process、bundle内の4つの新契約名をreadbackした。独立レビューは最終P0 / P1 / P2すべて0件。WindowsはCapability Registry / Handler / verifierを21 handlers・22 descriptorsへ更新したが、このMac環境に`dotnet`がないためWindows build / 実機Voiceは未確認。Windowsの既存Voice dynamic tool production gateは変更せず、Codex positive tool policy未承認のfail-closed契約を維持する。

## 2026-09-01 Voice Laneの再ホバー復帰

- ユーザーが通常版Codex Voiceで実際に音声会話できたことを確認した。一方、パネルを閉じて再ホバーすると、既存Realtime接続は`connected + muted`で保持されるのに、大きなマイクbuttonが新規開始専用のため無効になり、会話を再開できなかった。
- パネルを閉じた際は従来どおり即時mute / UI detachとし、再表示だけでは録音を自動再開しない。再ホバー後は大きなマイクbuttonを`音声会話を再開`として有効化し、明示操作で既存接続をunmuteする。切断済みの場合は従来どおり同じbuttonから新規接続する。
- UIは`一時停止中 · マイクを押して再開`と再開案内を表示する。決定論的検証でdetach後のmute、attach後もmute維持、resume後のunmute、`startCount == 1`維持をreadbackした。
- Debug / Release warnings-as-errors、Voice Foundation runtime、静的42 contract、Panel 128 cases、Capability 21 handlers / 22 descriptors、`git diff --check`、通常bundle build / launch / strict codesignがPASSした。独立レビューはP0 / P1 / P2すべて0件で、追加I/O、polling、probe、新規session起動はなく、過剰な安全実装やVoice hot path性能低下を認めなかった。
- macOS Voice sessionへ公開するCapability toolはCalendar権限に応じて6または4つである。Calendar作成、Timer開始、付箋追加、明るさ・音量変更はBrokerの既存承認ポリシーと実行後readbackを通る。Clipboard、Calculator、Timer pause / stop、任意のPocket App生成・導入はまだVoice toolとして公開していない。詳細: `progress/2026-09/2026-09-01_hover-pocket-normal-ui-voice.md`。

## 2026-09-01 Codex Voice開始導線の修正

- 通常版のVoice Laneが`切断・待機中`のまま応答しない報告を再現調査した。System Settingsのマイク権限は`HoverMenuPreview`がON、Codex app-serverのinstalled readinessと非物理RealtimeはChatGPT account / 19 voices / ephemeral thread / SDP / WebRTC / teardownまでPASSした。
- 表示していたcompatibility gate文言は実エラーではなく、Codex providerの開始前に常時出すplaceholderだった。Voiceは要件どおり自動listenせず、Panelのマイク操作でだけ開始するが、16pt相当のplain iconと誤ったplaceholderでは操作が伝わらなかった。
- 開始操作を36 x 36の円形buttonへ拡大し、待機statusを`開始前・マイクを押してください`、本文を`マイクを押すとCodexとの音声セッションを開始します`へ変更した。接続後に`mic.slash / 利用不可`と誤読されないよう、connection / muteに応じたsymbolとAccessibility文言も修正した。会話欄は開始前 / 接続中 / 接続済みで別文言を使い、開始後に開始案内を残さない。
- Debug warnings-as-errors、Voice Foundation runtime、静的42 contract、Panel 128 cases、`git diff --check`、通常bundle再build、strict codesign、bundle自身のCodex app-server RealtimeがPASSした。独立レビューの最終結果はP0 / P1 / P2すべて0件で、開始条件、layout、Accessibility、hot path性能に問題なし。修正版通常processを起動済み。物理マイク、可聴remote audio、user / assistant transcriptはユーザーの明示したマイク操作と発話を要するため未実施。詳細: `progress/2026-09/2026-09-01_hover-pocket-normal-ui-voice.md`。

## 2026-09-01 通常UIとVoice Laneのreadback

- Timer限定のbuild 619は物理Voice E2E隔離候補であり、通常版のProvider欠落ではなかった。build 619 processを停止し、既存performance receiptがattached状態を残したため物理E2E合格証拠には使わない。
- 通常bundle `local.codex.hover-pocket`を再build・署名・起動した。AccessibilityでMirror、Calendar、Sticky Notes、Calculator、Timer、Controls、Clipboard、Today Focus、Settingsと、下部固定のVoice Laneをreadbackした。実表示はCalendarへ切り替わり、Timer専用状態ではない。
- server closeとlocal stop応答のperformance証拠を分離した。attached local stopはstop RPC exactly 1回を要求し、server closeはattached=false / stop 0回を許容する。通常版ではE2E storeがnilのためhot pathへI/Oやpollingを追加しない。
- Debug / Release warnings-as-errors、Voice E2E performance / isolation、Voice Foundation、静的42件、Realtime renderer、Panel 128件、通常版build / strict codesignがPASSした。独立レビューはP0 / P1 / P2すべて0件で、過剰な安全実装や通常性能の悪化を認めなかった。
- Voice ProviderはCodex app-server、Voice Lane / AI-nativeはON、OpenAI API keyは不使用。実マイク、remote audio、transcript、Calendar account確認は未完了。詳細: `progress/2026-09/2026-09-01_hover-pocket-normal-ui-voice.md`。

## 2026-08-31 Voice Lane設定のruntime伝播修正

- build 618でSettingsのVoice toggleはON、Codex app-server選択、ChatGPTログイン済みだが、同一processのreceiptが`featureEnabled=false / providerId=off`のままでPanel下段のVoice Laneが出ないことを再現した。
- `@Published`の新値通知を捨ててpropertyの旧値を読み直していたことが原因だった。通知された`featureEnabled / preferredLayout / providerID`をimmutable configurationとしてそのままVoice runtimeへ渡し、Provider変更、Voice ON、Expanded変更が各1回で新値を反映する回帰テストを追加した。
- Debug / Release warnings-as-errors、Voice runtime、静的42 contract、Panel 128 cases、Voice E2E isolation、`git diff --check`がPASSした。fresh修正版`ホバーポケット Voice E2E 619`はPID `52065`で起動し、Harness isolation、strict ad-hoc codesign、初期Voice OFF / micなし / remote audioなしをreadbackした。
- 独立エージェントレビューはP0 / P1 / P2すべて0件で、設定変更時の発火回数は従来と同じ、音声hot pathへの追加負荷なし、必要最小限の修正と判定した。
- 実装commit `f6633dcd894abbc42f0b53f815e1adf40b1ad4c3`のDraft PR #39は11 SUCCESS / 8 expected SKIPPED / failure 0 / pending 0。macOS、Windows、3 OS共通契約を同一SHAで確認し、merge / release / 公開は行っていない。
- Timerだけの表示は物理Voice E2Eの隔離要件であり、通常版の全built-in Providerは変更していない。旧build 618はHarness Stopでsafe closeを確認し、build 619のVoice ON表示と物理音声を人手gateに残す。

## 2026-08-30 macOS隔離Voice候補のChatGPTログイン修正

- build 617の実設定画面をAccessibilityで再現し、Codex app-server選択中でも「再確認」だけが表示され「ChatGPTでログイン」が存在しないことを確認した。原因は、物理Voice E2E要件が専用ChatGPTログインを求める一方、隔離runtimeのCodex認証storageが`.disabled`へ固定されていた契約不一致である。
- 認証policyを`disabled / managedOnly / externalOrManaged`へ分離した。隔離Voice E2Eは`managedOnly`とし、fresh runtime内のVoice専用Codex Homeだけへowner-only regular fileを作成できる。本番は従来の`externalOrManaged`を維持し、Hostの`~/.codex/auth.json`、Keychain、通常版HoverPocketの認証を隔離候補から参照・symlink・変更しない。
- Harnessは`CodexVoiceAppServer`を隔離allowlistへ追加し、profile / Codex Home / config / managed credentialの型、current-user所有、権限、hardlink数を検査する。physical stageでは専用credentialが存在しない限り合格させず、Cleanupは従来どおりruntime全体を回収する。
- Debug / Release warnings-as-errors、Codex app-server管理ログイン4シナリオ・6 process、Voice E2E isolation、Voice Foundation、Panel 128 cases、Voice静的42 cases、shell構文、`git diff --check`がPASSした。
- fresh候補`ホバーポケット Voice E2E 618`をsession `HoverPocketVoiceE2ESession-1lQSaT` / runtime `HoverPocketVoiceE2E-dSiGNi` / PID `25480`で起動した。設定画面に「HoverPocket専用のCodexプロファイルは未ログインです。」「ChatGPTでログイン」「再確認」が表示されることをAccessibilityでreadbackした。profile / configはcurrent-user所有の`0700 / 0600`、専用`auth.json`はログイン前のため未作成、Voiceは既定OFFでmic / remote audio / Timer / physical confirmationなし。実ブラウザログインはまだ開始していない。
- 旧build 617はHarness Stopで`safe_close`、process停止、receipt保持を確認して一時session / runtime / buildをTrashへ移した。物理Voiceの人手gateはbuild 618だけへ引き継ぐ。
- 独立安全・性能レビューはP0 / P1 0件、実装上のP2 0件。Host auth非参照、runtime内`CODEX_HOME / HOME`、credentialの型・owner・mode・hardlink、Cleanup、本番`externalOrManaged`不変、通常起動 / Voice hot pathへの継続負荷なしを確認した。唯一の文書P2だったHarness usageの旧「logged-in Codex account共有」表現は、隔離profile内で個別ログインしHost credentialを共有しない説明へ修正した。
- 実装commit `c96457c7778a3767da8639d8bf6d0bebf20df3ea`をDraft PR #39へpushした。CIは15 SUCCESS / 8 expected SKIPPED / failure 0 / pending 0で、macOS、Windows、3 OS契約、routerを同一SHAで確認した。PRはDraft / OPEN / MERGEABLE、remote parity 0 / 0で、merge、公開、releaseは行っていない。

## 2026-08-30 macOS設定画面の見切れ修正

- 設定ウィンドウとSwiftUI rootがともに`460 x 500`固定で、ウィンドウがリサイズ不可だった。実候補build 615の設定画面をAccessibility / screenshot / CGWindowで確認し、Voice Lane付近の左端テキストが欠け、window frameが`460 x 532`であることを再現した。
- 初期本文サイズを`620 x 700`、最小を`520 x 480`とし、画面のvisible frameから24pt余白とタイトルバーを差し引いてclampする。ウィンドウをリサイズ可能にし、SwiftUI側の固定frameを削除して縦ScrollViewの本文を利用可能幅へleading配置した。再表示時はユーザーが変えた位置・サイズを維持し、画面外へ出た場合だけ現在screenへ戻す。
- `--verify-panel-layout`へpreferred / compact clamp / minimum / resizable契約を追加した。warnings-as-errors build、Panel 128 cases、Voice Foundation runtime、Voice静的42件、`git diff --check`がPASSした。
- 修正版の一意表示candidate `ホバーポケット Voice E2E 617`をfresh session `HoverPocketVoiceE2ESession-1B3yId` / runtime `HoverPocketVoiceE2E-snVEbU` / PID `19758`で起動した。設定windowはCGWindow readbackで`620 x 732`、Accessibilityでzoom button有効、左端欠落なしを確認した。Harness isolation / process ownershipもPASSし、Voice OFF、disconnected、microphone / remote audio / Timer / 物理確認なしを維持する。
- 比較用build 615 / 616はHarness Stopで`safe_close`とprocess停止を確認し、一時session / runtime / buildをTrashへ移した。物理Voiceの人手gateはbuild 617へ引き継ぐ。

## 2026-08-30 AN8 exact-head evidence bundle

- runtime source HEAD `9a110e9ae260ec65f7c99496baf36ff8c899b250`はremote parity `0 / 0`で、Draft PR #39の11 SUCCESS / 8 expected SKIPPED / failure 0 / pending 0をreadbackした。Windows [33307549713](https://github.com/shotaro311/hover-pocket/actions/runs/33307549713)、macOS [33307549728](https://github.com/shotaro311/hover-pocket/actions/runs/33307549728)、3 OS contract / compare [33307549725](https://github.com/shotaro311/hover-pocket/actions/runs/33307549725)は同一SHAで成功した。公開・正式署名・実機transitionを要する8件のskipは未完了gateとして分離した。
- 同HEADをmacOS `0.1.0 (615)`としてDeveloper ID署名・公証した。submission `2f2ead18-b466-4831-844d-3fcffb42ff54`は`Accepted`、ZIP SHA-256 `2901a0136531dff1834dee26c0cf14649e059b4f323e5c3293d37e516b3266d9`、size `7511492` bytes。main Mach-O UUID `45B20385-18C5-30FD-ACCD-04D272923CA3`、strict codesign、stapler、Gatekeeper `Notarized Developer ID`、Sparkle `2.9.3` / MediaRemote dependency closure、appcast build / length / EdDSAを再readbackした。GitHub Releaseとpublic appcastは変更していない。
- build 615配布binaryでVoice OFFの100回開閉、100 provider switch、5 recovery、3 animated transitionを実行し、window `3->3`、socket `0->1`、child `0->0`、RSS増加約`12.5 MiB`でPASSした。Capability、Broker、Pocket Surface、Pocket App package / lifecycle / generation / migration / health / workspace backup、Voice Foundation / E2E isolationも同じ配布binaryで成功した。
- Codex app-serverはAPI keyを使わず、ChatGPT account / 19 voices / ephemeral thread / SDP / WebRTC / teardownと、`gpt-5.6-sol` / `medium`のTimer tool 1回、Broker承認、readback、子process終了を確認した。物理マイク、remote audio、transcript、Calendar createは使用していない。
- exact evidenceは`progress/evidence/2026-08-30_an8-exact-head-9a110e9.json`へ固定した。既存の物理Voice候補PID `70741`を含む3 processは停止せず生存を確認した。現候補は旧runtime sourceのため、人手gate前にcurrent exact HEADから一意表示candidateを新規作成する。
- runtime source HEAD `9a110e9ae260ec65f7c99496baf36ff8c899b250`と同じ実装から、一意表示名`ホバーポケット Voice E2E 615`のprovider-bound候補をfresh buildした。session schema 2 / expected provider `codex_app_server`、PID `10329`、strict ad-hoc codesign、bundle / Debug main UUID `3FA123A2-0564-313B-8780-41017D7B0F7F`一致、process / storage所有をreadbackした。Voiceは既定OFF、disconnected、mic / remote audio / Timer / 物理確認なし。120秒235 sampleのidle CPU平均`0.113%`、p95`0.1%`、最大`2.7%`、RSS平均`100.988 MiB`、最大`101.609 MiB`で、前後の子process / network socketは`0->0`、Voice media attempt / snapshot / Expanded RPC / stop RPCは0だった。旧PID `619` / `70741` / `86913`は同時刻帯にAppKitの正常終了経路へ入り、現在はfresh候補1 processだけを人手物理gate待ちとして維持する。旧process終了の発火元は断定せず、crashとは扱わない。
- 独立レビューは耐久検証の遅延初期化フレークを検出し、検証専用の両Provider warm-up、前後500ms待機、socket `baseline + 1`、実数付き失敗ログへ修正した。修正後P0 / P1 / P2はすべて0件で、通常起動、Hover、Voice、app-serverのCPU / I/O / latencyへの影響はない。判定は引き続きNO-GOで、Draft解除、merge、release、公開は実施していない。

## 2026-08-30 macOS Codex app-server Voice基盤

- file-backed認証を安全に共有できない環境向けに、Voice専用profile内の`account/login/start`によるChatGPT managed browser loginを実装した。Settingsの明示操作だけで開始し、API key、Device Code、external token、Bedrockは公開しない。ログイン完了通知、`account/read`のChatGPT account、専用`auth.json`のcurrent-user所有とprivate permissionをreadbackした後だけVoiceへ反映する。
- owner-onlyの外部`auth.json`がある場合は従来どおりsymlink参照を優先し、そのcredentialに対してHoverPocketからlogin / cancel / logoutを行わない。専用managed fileと外部credentialの所有境界を分離し、Provider切替、cancel、app終了ではlogin ID付き取消とapp-server closeをboundedに実行する。
- 独立エージェントは候補fallback、MainActor上の`which`、終了再入、候補選択timeoutの持越し、managed不可時のprocess参照喪失を検出した。固定候補時のPATH探索省略、PATH-only探索最大約2.5秒、候補選択20秒、request最大8秒、shutdown gate、全clientのclose / clearへ修正し、最終P0 / P1 / P2はすべて0件。先頭正常候補は再起動せず、通常起動、Hover、Voice hot pathへの性能影響なしと判定された。
- Debug / Release warnings-as-errors、Voice静的42件、Codex app-server foundation / exact Broker tool route、`git diff --check`がPASSした。Apple Development署名のlocal build 600はstrict codesign、起動、graceful quitを確認し、隔離物理Voice E2E PID 70741は停止せず生存した。実ChatGPT browser loginはアカウント操作を伴うため未実行で、人手E2E gateに残す。
- 実装commit `4ed69eff3023d44b2452ee5d9772eef16d26ed73`のDraft PR #39は15 SUCCESS / 8 expected SKIPPED / failure 0 / pending 0、Draft / OPEN / MERGEABLE / CLEAN、未解決review thread 0、remote parity 0 / 0をreadbackした。merge / release / Draft解除は実施していない。
- managed loginを実controllerと実子processで通す決定論的検証を追加した。stub browserだけを使い、成功、専用credential再利用、cancel、Provider切替、app終了の4シナリオ・6 processを確認し、すべてのprocess終了と一時workspace消滅を別readbackした。実ブラウザや実アカウントは操作していない。
- fake app-serverのreceiptは検証用CLIだけで開き、`O_NOFOLLOW`、排他的作成、current-user所有、通常ファイル、0600、hardlinkなしを固定した。symlink / hardlink負例はともに拒否され、外部target未変更をreadbackした。独立再レビューはP0 / P1 / P2すべて0件で、同期`fsync`は明示helper内だけ、通常起動・Settings・Hover・Voice hot pathへの性能影響なしと判定した。
- 実装commit `3ccf423e9b131f402cf9ba146778479b0a199f0d`でDebug / Release warnings-as-errors、Voice静的42件、app-server lifecycle、Voice、Panel 128、Capability 20、Broker 21 / 20、Pocket Surface / App、TimerがPASSした。Apple Development署名のlocal build 602はstrict codesign、起動、graceful quitをreadbackし、隔離物理Voice E2E PID 70741は停止せず生存した。
- 配布scriptが`.build/debug/HoverPocket`を梱包していたことを実バイナリsize / UUIDで検出した。公証済みbuild 604はCodex app-server Realtimeを通過したが、Debug成果物のためRC候補から除外した。`build_and_run.sh`へ明示configurationを追加し、通常開発はDebug既定、隔離E2EはDebug限定、`package_zip.sh`はRelease固定とした。
- 配布依存はactive configurationのSparkle / MediaRemoteAdapter / `run.pl`を直接参照し、Release欠落とmainの`@rpath` closure不一致をZIP作成前にfatalとした。独立エージェントは通常runtime / Voice / Hoverのhot pathへ処理が増えず、配布版はRelease最適化で改善側と確認し、最終P0 / P1 / P2は0件だった。
- code commit `02128284fb5d075b9773f297064440021c42c79e`を`0.1.0 (605)`としてDeveloper ID署名・公証した。Apple submission `73ee5ac8-1e9e-4643-aca4-cf451b4cdf01`は`Accepted`で、staple、Gatekeeper、strict codesign、ZIP SHA、appcast、独立再展開をPASSした。ZIP SHA-256は`734f1d8ae8af77f253e655be12eaec61a679bd2b7dd425f671176a920085ad26`、sizeは`7495993` bytesである。
- ZIP内mainのUUIDは`.build/release/HoverPocket`と一致し、配布mainは`17442032` bytes、Debugは`28203648` bytesだった。配布binary自身でCapability 20、Broker 21 / 20、Pocket App、Voice Foundation、managed login 4シナリオ / 6 process、Codex app-server ChatGPT account / 19 voices / ephemeral thread / SDP / WebRTC / teardownをPASSした。OpenAI API key、実ブラウザ、物理マイク、remote audio、Calendar createは使用していない。
- Draft PR #39のHEAD `3576b83bf253473f0a439d8bfb2c4d7cc1b5b356`は11 SUCCESS / 8 expected SKIPPED / failure 0 / pending 0、Draft / OPEN / MERGEABLE / CLEAN、未解決review thread 0、remote parity 0 / 0だった。merge / release / Draft解除は実施していない。
- 既存の長時間隔離E2E build 597（PID `70741`）を停止せず、現在のDraft PR HEAD `c081cf24897902890d80e2eb915c2c7d8f14e253`から別のad-hoc署名build 607を作成し、fresh session `HoverPocketVoiceE2ESession-jM7jH4` / runtime `HoverPocketVoiceE2E-pvPrV7` / PID `85676`として同時起動した。bundleとDebug mainのMach-O UUID `02E274A9-60E7-3F24-89A1-DAF591FCC9B0`一致、strict codesign、process所有、receipt / performance存在、Voice既定OFF、disconnected、mic / remote audio / Timer readback / 物理確認未実行をreadbackし、Isolation検証もPASSした。
- build 607のidle計測はCPU平均`0.114%`、p95 / 最大`0.2%`、RSS平均約`109.650 MiB`、最大約`109.719 MiB`だった。独立レビューの最終結果はP0 / P1 / P2すべて0件で、通常runtime・起動・Hover・Voice hot pathを損なう過剰な安全処理は確認されていない。macOS desktop automationでは同一表示名 / bundle IDの旧・新E2E processを正確に識別できないため、自動クリックは行わず、最新build 607の物理マイク / remote audio / transcript / Timer承認を人手gateとして残した。
- 一意表示名のbuild 608はPID `86913`で既定OFF・人手物理E2E待ちを維持し、長時間基準PID `70741`も停止していない。別エージェントの最終レビューはP0 / P1が0件で、通常起動・Hover・Voice hot pathを損なう過剰な安全処理を認めなかった。P2はkeyring-only環境の認証継承互換性1件で、現在環境はowner-only `auth.json`を使えるため動作阻害ではない。
- ChatGPT Pro Orchestratorへexact HEAD `e02761e3c584810b5e66ed90fdcc74804d20b3a5`のAN8残存gate監査をreview-onlyで単一送信した。Node `v24.19.0`、Oracle `0.17.2`、request / task packet / source context hash、ChatGPT Project targetをruntime preflightで検証後に開始し、runは`20260830-175124-hoverpocketdraft-pr-head-e02761ean8voice`、sessionは`pro-run-a9b6cde0-a`。コード変更、GitHub書込み、merge、release、公開は許可しておらず、同じ依頼を再送せずreturn bridgeで回収する。
- 人手gateを一意に識別できるよう、同じHEADのE2E binaryと固定bundle IDを維持したまま、隔離bundleの表示名だけを`ホバーポケット Voice E2E 608`へ変更しad-hoc再署名した。fresh session `HoverPocketVoiceE2ESession-Ia7yuR` / runtime `HoverPocketVoiceE2E-9OKeZP` / PID `86913`で、strict codesign、Harness Readback / ValidateIsolation、CPU平均 / p95 / 最大`0.1%`、RSS平均約`113.904 MiB`を確認した。中間PID `85676`はHarness Stopで`safe_close`をreadbackして正常停止し、長時間基準PID `70741`と一意表示名PID `86913`だけを維持した。Voiceは明示OFFのままで、次はユーザーが表示名を確認してSettingsから有効化し、macOSマイク許可、物理発話、可聴remote audio、transcript、Timer承認 / readbackを行う。

- 隔離Voice E2Eへ性能readbackを追加した。mic開始意図からtransport attachedまでの直近10件とp95、snapshot publish、Expanded RPC、Realtime stop RPC、計測時間を会話本文・認証情報なしの固定schemaで保存し、HarnessのReadback / Validate / Stopがexact allowlist、現在attempt、単一stop、safe closeを検証する。通常版はStoreを生成せず、計測file I/Oとwriter queueは起動しない。
- 独立性能・安全レビューの初回指摘は、過去成功sampleと現在attemptの混同、active readbackのstale、mic開始hot pathの同期atomic write、Readbackでのreceipt実検証不足だった。`currentAttemptAttached`、utility直列writer、transcript / Timer / 物理確認時flush、`--require-receipt`で修正した。終了直前の非同期safe close競合もE2E終了時だけ同期flushして修正し、最終P0 / P1 / P2はすべて0件。通常起動、Hover、Voice開始への実質的なCPU / I/O / latency影響なしと判定された。
- 新しい隔離E2Eビルドの安定後10秒外部計測は21 sample、CPU平均0.157%、p95 0.2%、最大0.2%、RSS平均109.234 MiB、最大109.281 MiB。Voice opt-in前のためmedia attempt / snapshot / Expanded RPC / stop RPCはすべて0である。readback、隔離検証、safe close、stop、cleanupを実バイナリで確認し、既存の物理E2E PID 56971は停止せず維持した。

- macOS Voice Laneの標準providerを、OpenAI APIキーではなくCodex app-serverへ接続した。Codexのログイン状態を利用し、Calendar read/createとTimer startは既存Capability Registry / Broker / 承認 / readbackを通す。Realtime BYOKは明示選択時だけ使う代替経路で、自動fallbackしない。
- Voice専用`CODEX_HOME`でambient機能を無効化し、installed schemaに加えてlocal loopback providerへ実際に送られるResponses requestを起動前canaryで検査する。outbound `tools`がHost指定dynamic toolと件数・名前とも完全一致した場合だけReadyにする。解決済み実行ファイルURL、size / mtime / inode由来identity、version、専用profile、tool digestをcache keyへ固定し、spawn直前とbounded restartごとにidentityとversionを再確認する。
- `account/read`はChatGPTログインだけを許可し、API key、Amazon Bedrock、custom provider、signed-outを停止する。Codexの既存`auth.json`はowner-only sourceを専用profileからsymlink参照するだけで、OpenAI API keyはHoverPocketへ入力・保存しない。
- 通常の実行ファイル解決順で`/Applications/ChatGPT.app/Contents/Resources/codex`をHomebrew版より先に評価し、自動検出時は候補を順にcompatibility probeして最初のReadyを採用する。明示`HOVERPOCKET_CODEX_EXECUTABLE`は指定した1件だけを検証し、勝手に別binaryへfallbackしない。probe後はbinary identity / version / profileを固定して同じCodex app-serverだけを起動する。
- 物理マイクを取得しない明示live verifierを追加した。非永続WKWebView内で外部ICE serverなしのpeer、無音Web Audio track、data channelを作り、ChatGPT account、19 voices、ephemeral root thread、SDP answer、WebRTC connected、tool未実行、app-server process終了、一時workspace消滅を順にreadbackする。
- `thread/realtime/error`またはSDP前の`closed`を30秒timeoutまで隠さず、pending negotiationへ即時返却する。v3 requestではapp-serverにvoice既定値選択を任せ、APIモデル / APIキーをHoverPocketから指定しない。
- Voice開始はWebView ready待ちを2秒、全体を30秒で有限化し、取消、切断、停止をcleanupへ接続した。app-server stdout / notificationは順序処理、transcriptは67ms単位、Expanded child cardは接続中だけ3秒ごと・最新16件・最大4並列readに制限した。root card timestampもdeltaごとに更新しない。
- 独立エージェントの安全性 / 性能レビューは、ChatGPT.app同梱Codexのlive差分まで最終再レビューし、今回差分でP0 / P1 / P2すべて0件。Broker限定policy、read-only sandbox、空workspace roots、非永続WebView、CSP、5秒microphone leaseは必要な境界として維持した。一方、ambient要求だけを入力順に短く隔離し、通常tool本体は並行実行するため、stdout停止や応答遅延を増やさない。pending / current / 旧clientはidentityとgenerationで分離し、隔離済みclientは再起動しない。live verifierのWebView、無音oscillator、最大0.5秒のcleanup待ちは明示検証コマンドに限定し、通常hot pathへ入れない。v3では未使用のlegacy default voiceキーを要求せず、非空voice集合だけを確認する。
- app-server専用profileの追加差分も別エージェントが再レビューし、API key認証の誤受入れと一過性probe失敗の無期限cacheを検出・修正した。公式0.149のroute canaryは0.27〜0.65秒でVoice設定時に1回だけ、mic開始hot pathには入らない。keyring-only環境向けの専用ChatGPT managed login実装はローカル検証済みで、実ブラウザログインとfile-backed認証からの移行readbackを人手gateに残す。
- `swift build -Xswiftc -warnings-as-errors`、Voice Foundation、Capability、Broker、Pocket contract 15 schema / 71 fixture、Voice静的42件、app-server入力順 / client隔離の回帰、`git diff --check`が成功した。隔離E2E bundleはad-hoc署名を`codesign --deep --strict`で確認し、実行ファイルとmicrophone purpose stringを別経路でreadback後、生成物をTrashへ移した。
- 隔離Voice E2Eの既定providerとreceipt判定をCodex app-serverへ統一した。app-server readinessを選択中providerからreadbackし、Codex WebRTCでもmic取得とremote audio再生後にHost所有の「話せた・聞こえた」確認をattempt単位で一度だけ表示する。通常版はreceipt storeが`nil`で即時returnするためhot pathへ同期I/Oを追加しない。別エージェントの独立レビューはP0 / P1 / P2すべて0件で、stale operation、旧alert応答、終了競合も拒否されることを確認した。
- 修正後のDebug / Release warnings-as-errors build、Voice Foundation、Voice E2E isolation、receipt physical / stopped self-test、Capability 20 handler、Broker 21 descriptor / 20 handler、Pocket contract 15 schema / 71 fixture、静的42件、`git diff --check`が成功した。環境変数なしのChatGPT.app同梱Codex live verifierは3回連続で2.86 / 2.24 / 2.19秒、account / 19 voices / ephemeral thread / SDP / WebRTC / teardownを通過した。
- Calendar実データをVoice originの`calendar.events.list`として既存Registry / Brokerへ通す`--verify-calendar-capability-read-only`を追加した。外部integration、明示`--grant-calendar-read`、既存Google credentialを必須とし、CalendarList handlerだけを登録する。予定内容は表示せず件数だけを返し、承認なし、実行後readback verified、auditに`safeTitle` / `eventRef` / `calendarId`が残らないことを検証する。ブラウザ認証とCalendar書き込み経路は持たない。
- 通常署名設定を引き継いだ一時candidateは、既存Keychain itemへの新規candidateアクセスがSecurity.framework内で停止した。診断用Keychain readをdetached taskと5秒OneShot gateへ分離し、同じcredentialをmutation-disabled OAuth / Calendar storeへ注入して二重Keychain readを除去した。署名済みcandidateは5秒で`calendar_credential_check_timed_out`、Calendar API未到達、broker root残存0をreadbackし、一時candidateをTrashへ移した。通常Google Calendar経路はdefault引数で従来動作を維持する。
- インストール済みappを隔離コピーし、最新Release binaryへ差し替えたbuild 584 candidateを同じDeveloper ID、bundle ID、Team ID、Designated Requirement、`release` Keychain suffixで再署名した。既存Google credentialを変更せず読み込めることを確認し、Voice originの`calendar.events.list`が実Calendar、Broker、readbackまで2回成功した。最終実測は3.16秒、予定内容を出さず件数1、承認なし、audit redactedである。
- private read共通3秒timeoutは実Calendar取得を`URLError -999`で途中取消していた。Calendar get / listだけを15秒・30 calls/minへ分離し、Timerなどローカルreadは3秒のまま維持した。Broker timeoutは取消由来のnetwork errorより優先して`calendar_capability_timed_out`へ固定分類する。独立再レビューはP0 / P1 / P2すべて0件で、MainActor同期停止、個人情報漏洩、他Capabilityへの性能影響がないことを確認した。
- local loopback Responses providerから決定論的function callを返し、実Codex app-serverが送信した`item/tool/call`を同じBridge、Capability Runtime、Registry / Broker、承認、Timer実行、readbackへ通す明示CLI検証を追加した。replyはapp-server pipeへの書込み後にだけcaptureし、同一call replay、拒否、root scopeも既存fixtureと合わせて確認する。外部Calendar、既存Timer、API keyへ触れず、通常compatibility probeは`invocation=nil`のままである。CLI実測は約1.02秒、通常起動 / Voice hot pathへの追加実行なし。独立再レビューはP0 / P1 / P2すべて0件だった。
- `--verify-codex-app-server-model-tool`を追加し、ChatGPTログイン済みCodex app-serverへ指定値`gpt-5.6-sol / medium`の実ターンを1回送った。公開toolは一時Timerの`timer_countdown_start`だけで、Codex自身が60秒Timerを選択し、Host承認1回、Bridge、Registry / Broker、実行、readback、app-serverへのreply書込み、`turn/completed`、process終了、一時workspace消滅まで確認した。app-serverが実採用したmodel / effortはprotocolからreadbackできないため、CLI出力も`requested_model / requested_effort`と明記する。Calendar accessはfalse、作成件数0、API key参照なし、既存Timer非使用。明示CLIは6.81〜9.61秒、最終8.03秒で、通常起動 / Hover / Voice開始hot pathから呼ばれない。独立レビューで初期化前失敗時のworkspace回収とmodel表示の誤読余地を修正し、最終P0 / P1 / P2は0件、通常時の性能影響は実質0と判定された。
- 実モデルtool検証を含むcode commit `7194ff297df6c456d1ead2a88008e40826b36642`のDraft PR #39は、Router [33293498009](https://github.com/shotaro311/hover-pocket/actions/runs/33293498009)、macOS [33293498781](https://github.com/shotaro311/hover-pocket/actions/runs/33293498781)、Windows [33293498790](https://github.com/shotaro311/hover-pocket/actions/runs/33293498790)、3OS contract / compare [33293498775](https://github.com/shotaro311/hover-pocket/actions/runs/33293498775)、transition [33293498770](https://github.com/shotaro311/hover-pocket/actions/runs/33293498770)、release readback [33293498792](https://github.com/shotaro311/hover-pocket/actions/runs/33293498792)が成功した。11成功・8 gate skip・失敗0・pending 0、Draft / OPEN / MERGEABLE / CLEAN、remote parity 0 / 0をreadbackした。
- Calendar候補は検証後にTrashへ移し、物理Voice E2E process PID 56971は停止せず維持した。Calendar create、Timer start、物理マイク / remote audioは引き続き別の明示承認・人手確認gateとする。
- 独立エージェントは初回に、無関係なTimer singleton初期化、後続Keychain再読込、token refresh失敗時の保存credential削除というP1 3件を検出した。Calendar-only Registry、preloaded credential、`allowsStoredCredentialMutation=false`で修正し、最終再レビューはP0 / P1 / P2すべて0件だった。通常起動とVoice hot pathには新CLI分岐以外の実質的なCPU / RSS増加がない。
- ad-hoc署名の隔離E2Eアプリを実起動し、Timerだけのregistry、通常データと外部integrationの隔離、Codex app-server選択済み、Voice明示opt-in前の停止状態をprocessとreceiptからreadbackした。物理マイク、実remote audio、transcript、Timer承認は人の発話・聴覚確認が必要なため未完了で、公開可とは扱わない。
- Homebrew Codex `0.145.0`は追加tool混入でroute gateを停止し、隔離した公式`0.149.0`はroute / account / 19 voicesまで成功後、現行backendとの`session.model`契約差でSDP開始を即時停止する。一方、ChatGPT.app同梱Codex `0.150.0-alpha.12.2`は環境変数なしでaccount、19 voices、ephemeral thread、SDP、WebRTC、teardownを全通過し、Codexの実ターンによるTimer tool選択もBroker / readback込みで成功した。物理マイク、remote audio、transcript、音声経由のCalendar / Timer E2Eは引き続き未完了であり、公開可能とは扱わない。
- Calendar読み取りgate commit `a836856b570e7f949ab9081080c462d1ca6ce326`のDraft PR #39は、Router [33291040507](https://github.com/shotaro311/hover-pocket/actions/runs/33291040507)、macOS [33291041914](https://github.com/shotaro311/hover-pocket/actions/runs/33291041914)、Windows [33291041972](https://github.com/shotaro311/hover-pocket/actions/runs/33291041972)、3OS contract / compare [33291041947](https://github.com/shotaro311/hover-pocket/actions/runs/33291041947)、transition [33291041883](https://github.com/shotaro311/hover-pocket/actions/runs/33291041883)、release readback [33291041901](https://github.com/shotaro311/hover-pocket/actions/runs/33291041901)が成功した。11成功・公開成果物を要する8 gate skip・失敗0・pending 0、Draft / OPEN / MERGEABLE / CLEAN、remote parity 0 / 0をreadbackした。
- 実装commit `dc734a95f30e847cb70c705df8d67728178a578f`のDraft PR #39は、Router [33289398813](https://github.com/shotaro311/hover-pocket/actions/runs/33289398813)、macOS [33289399447](https://github.com/shotaro311/hover-pocket/actions/runs/33289399447)、Windows [33289399448](https://github.com/shotaro311/hover-pocket/actions/runs/33289399448)、3OS contract / compare [33289399439](https://github.com/shotaro311/hover-pocket/actions/runs/33289399439)、transition [33289399443](https://github.com/shotaro311/hover-pocket/actions/runs/33289399443)、release readback [33289399458](https://github.com/shotaro311/hover-pocket/actions/runs/33289399458)が成功した。公開成果物を必要とする8 gateは意図どおりskip、失敗0・pending 0、`MERGEABLE`である。merge / releaseは実施していない。
- 詳細: `progress/2026-08/2026-08-30_hover-pocket-codex-appserver-voice.md`。

## 2026-08-30 macOS配布bundle Realtime回帰

- 現行HEAD `9068d9674883a4916787dc62ef64e854dabfd97e`を`0.1.0 (597)`としてDeveloper ID署名・Apple公証し、submission `10bf95ad-0d86-4137-9336-cce2d8922937`は`Accepted`、app / ZIP再展開後のcodesign、stapler、Gatekeeper、SHA-256、appcast、公開dry-runまで成功した。ただし配布bundleの`--verify-codex-app-server-realtime`だけが再現性をもって失敗したため、build 597はRCとして不採用とした。GitHub Release / appcast公開はしていない。
- Debug / Release CLIはRealtime接続まで成功する一方、Developer ID署名bundleはWebKitのmDNS host candidate登録に失敗した。verifierへ非機密の固定段階code、本番と同じcustom URL scheme、検証中だけの1px offscreen host windowを追加した。通常VoiceとverifierのICE待機は、candidate取得済みなら3秒、未取得なら従来上限8秒まで待ち、8秒後は後段の接続判定へ進む方式に統一した。
- `NSLocalNetworkUsageDescription`へWebRTC Voice接続だけの用途を明記し、Bonjour browse / advertise、`NSBonjourServices`、multicast entitlementは追加していない。現在の開発Macでは署名bundleが`realtime_probe_connection_unavailable`のままで、System SettingsのLocal Network許可を伴う人手readbackが残る。テスト用build 598は未公証・非RCである。
- 配布package scriptがprocess名だけで既存HoverPocketを停止し、維持対象だった物理E2E PID 56971も停止する回帰を検出した。同じruntime rootはfresh制約で再利用せず、新しい隔離sessionをBuild / Run / ReadbackしてPID 70741を復旧した。build scriptはcanonicalな`--voice-e2e --voice-e2e-root`引数を持つprocessを停止対象から除外し、その後の配布package実行後もPID 70741が生存することをreadbackした。
- 独立エージェントは初回、ICEを一律3秒で確定すると3〜8秒にcandidateが出る正常系を落とすP1を1件検出した。上記hybrid waitへ修正後の最終再レビューはP0 / P1 / P2すべて0件。Debug / Release warnings-as-errors、Capability 20、Broker 21 descriptor / 20 handler、Pocket Surface / App、Timer、Panel 128、Voice静的42、Codex実モデルTimer、CLI Realtime、E2E isolation、Pocket contract 15 schema / 71 fixture、release readback 23 test、receipt / performance self-testはすべてPASSした。
- 修正commit `248539b05bccc7ece521a3d9c34bad5ae5e2ad7b`のDraft PR #39は15成功・公開artifactを要する8 gate skip・失敗0・pending 0、Draft / OPEN / MERGEABLE / CLEAN、remote parity 0 / 0をreadbackした。merge / releaseは実施していない。
- product source exact HEAD `9961543db7c6502381830954c738029bf8da4c8d`をbuild `599`としてDeveloper ID署名・公証した。Apple submission `52ecaaec-4b2c-4d44-97f7-57cb20dce3a2`は`Accepted`で、ZIP SHA-256は`747c4e43cfc65d9cbd0fde5d960834f87f4df7cb41cfab82eb224cd6a10f302d`、sizeは`10138820` bytes。別の一時directoryへZIPを展開し、top-levelが`HoverPocket.app`だけ、bundle ID `local.codex.hover-pocket`、version `0.1.0`、build `599`、appcast version / URL / length一致、strict codesign、stapler、Gatekeeper `Notarized Developer ID`をreadbackした。公開releaseは作成していない。
- build 599配布bundleのCapability、Broker、Pocket Surface / App、Voice Foundation / E2E isolation、Codex app-server foundation / 実モデルTimer toolはPASSした。標準VoiceはOpenAI API keyではなくChatGPT accountのCodex app-serverを使い、Realtime BYOKは明示選択時だけの代替経路のままである。
- build 599配布bundleの`--verify-codex-app-server-realtime`だけは`realtime_probe_connection_unavailable`で失敗した。署名bundleのLocal Network許可と物理音声往復が未確認のため、build 599は公証・成果物検証済みcandidateだがVoice対応RCとしては未受入である。
- 再レビュー済みのhybrid ICE待機は、candidateが3秒以内に得られた場合だけ早期継続し、未取得時は8秒まで正常接続余地を維持する。独立エージェントの最終判定はP0 / P1 / P2すべて0件で、通常hot pathの追加は解除されるtimer最大2個、purpose stringとverifier専用1px windowには常駐処理がない。過剰安全による正常動作・CPU / RSS /起動性能の有意な悪化は認めなかった。
- 隔離物理Voice E2EはPID `70741`、fresh runtime `HoverPocketVoiceE2E-wevAYd`で稼働を維持し、公証・ZIP独立展開・packaged verifier後も生存をreadbackした。停止・再起動はしていない。

## 2026-08-30 AN8 macOS notarized release candidate build 583

- Windows正式署名は、まず無料のSignPath Foundation OSS枠を使用する方針とした。申請、受入、CI origin verification接続は未完了であり、正式Windows署名の完了とは扱わない。
- exact head `cd71796aabceee56407e1b738c5ceb59255d1c86`からmacOS `0.1.0 (583)`をDeveloper ID Applicationで署名し、Apple notary submission `a11f687d-ce71-463f-bd5d-7080b8b21214`が`Accepted`となった。appへticketをstapleし、app本体と最終ZIP再展開後の両方で`codesign --deep --strict`、`stapler validate`、`spctl`が成功した。
- リリース候補`HoverPocket-0.1.0-583.zip`のSHA-256は`6dbcba8649850a7c36bdc493af266a41a73871e321c15d88d2d9609c72b1157f`。ZIPのtop-levelは`HoverPocket.app`のみで、appcastはbuild 583、version 0.1.0、versioned URL、Sparkle EdDSA signatureを持つ。公開scriptのnotarized dry-runも成功した。
- notarization済みappバイナリからCapability、Broker、Pocket Surface、Pocket App package / lifecycle / generation / migration / health / workspace backup、Voice Foundation、Voice E2E isolation verifierを実行し全件成功した。release用entitlementsはApple Events、microphone、cameraの3件、hardened runtimeとsecure timestampを確認した。
- GitHub releaseと`macos-latest`は更新していない。一般公開版は引き続き`0.1.0 (168)`である。build 583はDraft PR #39の未公開候補であり、物理マイク / remote audio / transcriptのユーザー確認、PR Ready / merge判断が完了するまで公開しない。
- 詳細: `progress/2026-08/2026-08-30_hover-pocket-an8-macos-release-candidate.md`。

## 2026-08-29 AN8 Windows署名配布・readback・transition契約

- ChatGPT Pro Orchestrator delivery `return-1e6256872e7bbbcef22f6e3a91b220ac`をbase / artifact hash / pathで検証し、formal専用MSI、schema 2 manifest、公開asset readback、署名 / publisher照合、manual install / rollback transitionの契約を適用した。betaとproduction機能は引き続きOFFである。
- Security finding `csf_e7d87707f7a44496d2c2d690`を修正し、IdentityOnlyからMSI DB / `msiexec /a`を到達不能にした。formalはtimestamped署名とcanonical certificate pinの後だけMSIを解析する。PowerShell AST契約をWindows CIへ追加し、将来の別call siteもguard外なら拒否する。
- code head `7b0dd71725d6dd18648c79823ef0cda99122d870`でPR #39は19成功・16 gate skip・失敗0・pending 0、`MERGEABLE / CLEAN`。Windows [33256015304](https://github.com/shotaro311/hover-pocket/actions/runs/33256015304)はRelease / Debug / MSI build警告0・エラー0、署名契約とAST契約、Voice 42件、Broker、Settings、UIを成功した。release readback、transition syntax、macOS、3 OS contractも成功した。
- Pro runはgeneration 2の全7 acceptanceとlocal verificationをPASSにし、terminal receipt `complete`、delivery `synthesis_completed_at`までreadbackした。既存公開release readback [33256489278](https://github.com/shotaro311/hover-pocket/actions/runs/33256489278)はWindows package identityとmacOS署名 / notarization / Gatekeeperを成功した。
- 初回の実Windows transitionでGUI executableの`$LASTEXITCODE`未定義と、公開版へbuild-time OAuth照合値を要求する責務混在を検出した。`Process.ExitCode` readbackと公開版Updater verifierへ修正し、head `f9fa4267f237c7e6e1bd7780c46e68d5a2a277a2`でWindows [33256921874](https://github.com/shotaro311/hover-pocket/actions/runs/33256921874)を含む13 check成功・11 gate skip・失敗0、Draft / CLEANを確認した。
- 実transition [33256955463](https://github.com/shotaro311/hover-pocket/actions/runs/33256955463)は公開Windows beta `0.2.6 → 0.2.7 → rollback → re-upgrade → uninstall → reinstall`とuser data保持をartifact receiptから確認した。macOSの公開版transitionも [33256490541](https://github.com/shotaro311/hover-pocket/actions/runs/33256490541) で成功した。
- 正式署名済みMSI/helperの生成・公開とそのtransition、通常Windows hostのUAC、公開後formal Authenticode readback、物理Voice / 実モデル生成は未完了。Draft PR #39はReady / mergeへ進めず、production setup / generation / activationをOFFで維持する。
- 詳細: `progress/2026-08/2026-08-29_hover-pocket-ai-native-final-integration.md`。

## 2026-08-29 Windows Settings fixed-helper UAC boundary

- ChatGPT Pro Orchestrator delivery `return-ef597cc5f3b9dee4a03b6d500d8a06f2`をclaim-synthesisで検証し、base `cc70c140cfccf28551a67b2dd775233240de1fc8`、artifact SHA-256 `a675afd34a5b4483e9c68db3d45d2308d5a9eeed7a35b0f1752c0659ec2309a0`、変更対象7ファイルを照合して適用した。
- Settings専用の将来境界として、固定`ProgramFilesX64` helperだけを解決するresolver、full path component / final object / launched process image identity、publisher metadata / Authenticode / certificate SHA pin、native default-No承認、exact request、単一`runas`起動、固定errorとreadbackを追加した。app-local helper copy / publishは除去した。
- SecurityレビューでWinVerifyTrustのcache-only / revocation無効候補を検出し、Shellとhelperの両側をwhole-chain revocation、root除外、cache-only fallbackなしへ修正した。revocation確認不能もUAC前にfail closedとする。
- 初回Windows run [33251115377](https://github.com/shotaro311/hover-pocket/actions/runs/33251115377)はRelease / Debug buildとhelper / MSI contractまで成功後、Win32 flagを.NET `FileOptions`へ渡したSettings verifierだけが`ArgumentOutOfRangeException`で失敗した。directory / reparse handle openを`CreateFileW`へ修正し、identity pinの意味を維持した。
- 修正code head `82da1b7c110087b926010556869f6d8f63088d00`でWindows [33251291505](https://github.com/shotaro311/hover-pocket/actions/runs/33251291505)、macOS [33251291487](https://github.com/shotaro311/hover-pocket/actions/runs/33251291487)、3 OS contract / compare [33251291502](https://github.com/shotaro311/hover-pocket/actions/runs/33251291502)、Router [33251290676](https://github.com/shotaro311/hover-pocket/actions/runs/33251290676)の7 / 7 checkが成功した。WindowsはRelease / Debug build警告0・エラー0、Settings、helper / MSI contract、Voice 42件、Broker、Pocket App generationをログ本文からreadbackした。
- Codex Security scan `92657ca5-0536-4875-8ad7-c45d2920458b`はexact range `cc70c140cfccf28551a67b2dd775233240de1fc8..82da1b7c110087b926010556869f6d8f63088d00`、snapshot `codex-security-snapshot/v1:sha256:5c94d0b10292c8061dbe33398491463ee47d826dd4f1458e7af02f430e9c5c29`、対象9ファイル、6 surface、reportable finding 0件、coverage partialでsealed完了した。署名済みhelper /物理UAC / elevated process cleanupはfollow-upとして分離した。
- ローカルではSwift warnings-as-errors build、15 schema / 71 fixture、Codex auth / confinement、macOS Voice E2E receipt / renderer、Voice 42件、Capability / Broker / Pocket Surface / Pocket App package・lifecycle・generation・migration・health・workspace backup、Timer、`git diff --check`が成功した。
- 通常Windowsでの署名済みhelper、UAC normal / cancel / timeout、elevated process-tree cleanup、post-start identity readbackが揃うまでproduction setup / generation / activationはOFF、Draft PR #39はReady / mergeへ進めない。
- 詳細: `progress/2026-08/2026-08-29_hover-pocket-ai-native-final-integration.md`。

## 2026-08-29 Windows Codex sandbox per-machine installer

- `HoverPocket.CodexSandboxSetup`のself-contained `win-x64` publish一式を、専用per-machine MSIから固定`%ProgramFiles%\HoverPocket\CodexSandboxSetup`へ配置する契約を追加した。WiX SDKは法的受諾を自動化しない5.0.2へ固定し、embedded cabinet、固定UpgradeCode、64-bit component、major upgrade / uninstallだけを持たせた。
- `verify_codex_sandbox_installer.ps1`はMSI databaseを別経路で開き、`ALLUSERS=1`、ProductVersion / UpgradeCode、Program Files ancestry、全componentの64-bit属性、helperの一意性、embedded cabinet、upgrade順序を検証する。CustomAction、service、registry、environment、shortcutは0件を必須にする。
- code head `209931a9faa541f1e33344908b66dfa4cb7c8336`のWindows run [33228860540](https://github.com/shotaro311/hover-pocket/actions/runs/33228860540)でMSI buildは警告0・エラー0、`PASS Codex sandbox per-machine installer contract`となった。Router、3 OS Pocket contract / compareも成功した。
- Codex Security diff scan `71e7156e-74ac-4998-9c82-bc00a0a08c6c`をexact range `5c29adfbdf3b06b89c211d3f3bc0ed75f5911f8d..209931a9faa541f1e33344908b66dfa4cb7c8336`でsealed completeとし、per-machine固定root、MSIの禁止table、upgrade順序、CI publish / readback、production fail-closedの5 surfaceをcoverage complete、reportable finding 0件で確認した。署名、installed ACL / object identity、Settings UAC、実機install / upgrade / rollback / uninstallは別gateとして除外した。
- 同headのmacOS Capabilities [33228860545](https://github.com/shotaro311/hover-pocket/actions/runs/33228860545)は、既存の10ms timeout対100ms handler fixtureだけが`timeout_status`で失敗した。直前19 runとローカル30回は成功しており、macOS / Windows双方のfixtureをtimeoutでcancelされるまで30秒待つ形へ変更した。Swift buildと修正後50回連続のBroker verifierは成功した。
- 修正head `6c9e4708a8cf0dcc1b24107c2f4cf8d8665656e4`でWindows [33248167930](https://github.com/shotaro311/hover-pocket/actions/runs/33248167930)、macOS [33248167915](https://github.com/shotaro311/hover-pocket/actions/runs/33248167915)、Router [33248166883](https://github.com/shotaro311/hover-pocket/actions/runs/33248166883)、push / PR起点の3 OS contract [33248165880](https://github.com/shotaro311/hover-pocket/actions/runs/33248165880) / [33248167921](https://github.com/shotaro311/hover-pocket/actions/runs/33248167921)を含む11 / 11 checkが成功した。WindowsはRelease / Debug build警告0・エラー0、`broker_verify=ok`、helper contract、MSI contract、Voice 42件を、macOSはbuild、`broker_verify=ok`、Voice 42件をログ本文からreadbackした。
- MSIとhelperの署名、Settingsによる固定origin / publisher / object identityの検証、UAC dispatch、Windows実機physical canaryは未実装である。production setup / generation / activationは引き続きOFF、Draft PR #39はReady / mergeへ進めない。
- 詳細: `progress/2026-08/2026-08-29_hover-pocket-ai-native-final-integration.md`。

## 2026-08-28 Windows Codex setup semantic readback

- OpenAI Codex `rust-v0.145.0` / commit `25af12f7e61572b0bc18ddb1008be543b91519b0`の実装を照合し、`setup_marker.json`と`sandbox_users.json`をversion 5のexact schemaとして意味検証する`CodexSetupReadbackVerifier`を追加した。unknown / duplicate field、非canonical base64、無効なusername、同一password、空でないproxy / read / write rootsを拒否する。
- machine-scope DPAPIで2つのpasswordを復号し、公式実装と同じ24 byte・`ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#$%^&*()-_=+`の文字集合・相互に異なる値を要求する。managed / native plaintextをzero化し、native bufferを`LocalFree`する。
- 初期案の英数字限定が公式passwordの記号を誤拒否する不一致を実ファイル照合で検出し、コミット前に公式文字集合へ修正した。
- ローカルではhelper contract、Release / Debug全solution build警告0・エラー0、Settings target、Voice Foundation 42件、YAML parse、変更file限定format、`git diff --check`が成功した。
- Codex Security diff scan `b89a6dad-fb92-44f2-b70e-81c931e7b3a1`はworking-tree snapshot `codex-security-snapshot/v1:sha256:f5246e1fe992305b4426d541c20c5c989fc0a32c019c83b71012ce2771f6f47e`を3 / 3 authoritative item、6 surface、coverage complete、reportable finding 0件でsealed completeとした。path checkとreadの間隔は、readback完了までhomeがadmin-onlyであるため現状の非管理者attack pathから棄却し、ACL順序変更時の再監査条件として残した。
- 実装commit `7f5ab9938057ae9aad92b2519b50ba6d6dd938f3`のWindows run [33177820477](https://github.com/shotaro311/hover-pocket/actions/runs/33177820477)で、Windows専用machine-scope DPAPI round-tripを含む`PASS Codex sandbox helper contract`、vendor closure、Release / Debug buildと全既存Verifierが成功した。
- 同headでRouter [33177819003](https://github.com/shotaro311/hover-pocket/actions/runs/33177819003)、macOS Capabilities [33177820374](https://github.com/shotaro311/hover-pocket/actions/runs/33177820374)、3 OS contract / compare [33177820470](https://github.com/shotaro311/hover-pocket/actions/runs/33177820470)を含むPR check 7 / 7が成功した。Draft PR #39は`MERGEABLE / CLEAN`である。
- production setup / generationは引き続きOFF。残りは、署名済みhelperを固定Program Files originへ配置するper-machine installer、SettingsからそのoriginだけをUAC起動する契約、通常Windows hostのphysical canaryである。
- 詳細: `progress/2026-08/2026-08-28_hover-pocket-ai-native-final-integration.md`。

## 2026-08-28 Windows Codex sandbox native helper internal implementation

- `HoverPocket.CodexSandboxSetup`内部に、`%ProgramData%`配下の管理者所有root、公式Codex 0.145.0の6ファイルclosureを複製済みhandleから固定配置する処理、nonceごとのsingle-use Codex Home、固定argument / cleared environment、Job Objectによる子process所有、実行後marker / attestation readbackを実装した。production setup dispatchとSettingsからのUAC接続は引き続きOFFである。
- nonce Homeは既存objectがあれば`HP_CODEX_SANDBOX_TARGET_ALREADY_EXISTS`で拒否し、attestationは元user SIDだけが読めるSID別directoryへ保存する。Builtin Usersへのidentity metadata公開と、同じnonce Homeを再利用する条件付きgapを実装段階で閉じた。
- ChatGPT Pro Orchestrator run `20260828-205951-...`は`sent-state-unknown`から同じsessionのbounded harvestを2回行ったがartifactを回収できず、terminal化して`mark-done`した。同じpromptは再送せず、Skillが許可するblocked時のCodex実装へ切り替えた。
- Codex Security scan `ddedf27f-5261-41f9-8522-1d08412fbc66`は修正前working-tree snapshot `codex-security-snapshot/v1:sha256:a8adc5749b8f661509a2fbb2d099472b5263ff405b422d041ca32a848a08aaad`を5 / 5 surface、coverage complete、reportable finding 0件で完了した。single-use HomeとSID限定attestationは条件付きgapとして残ったため、その後の実装で修正した。このscanを修正後head全体のSecurity合格証拠としては扱わない。
- ローカルではRelease / Debugの全solution buildが警告0・エラー0、helper contract self-test、production pre-parse exit 21、Settings JavaScript、Voice共通契約42件、workflow YAML、`git diff --check`に合格した。変更file限定の`dotnet format whitespace --verify-no-changes`は合格し、全solution formatは今回と無関係な既存whitespace差分で不合格のため変更していない。
- code head `f63e265f91ad1366369dc6a9c39b72c392701368`のWindows run [33175266675](https://github.com/shotaro311/hover-pocket/actions/runs/33175266675)は、helper contractとvendor closureの合格後、PowerShellがnative exit 21をassert前にjob失敗として扱うCI harnessだけで失敗した。`ProcessStartInfo`でstdout / stderr / exit codeを明示取得する修正後、code head `48933374f8a5c29cc764ad52bce95c09641594f9`のWindows run [33175584387](https://github.com/shotaro311/hover-pocket/actions/runs/33175584387)は全stepに合格した。
- 同headでRouter [33175576923](https://github.com/shotaro311/hover-pocket/actions/runs/33175576923)、macOS Capabilities [33175583944](https://github.com/shotaro311/hover-pocket/actions/runs/33175583944)、3 OS contract / compare [33175584002](https://github.com/shotaro311/hover-pocket/actions/runs/33175584002)を含むPR check 7 / 7が成功し、Draft PR #39は`MERGEABLE / CLEAN`である。
- 未完了gateは、署名済みhelperの固定admin-owned installer配置、そこからだけ起動するSettings UAC、`sandbox_users.json`の意味検証、通常Windows hostでのwhole-home / nested reparse・UAC取消・timeout descendant・正常setup・post-readback fail-closedのphysical canaryである。これらと実モデル生成readbackが揃うまでproduction generatorを有効化しない。
- 詳細: `progress/2026-08/2026-08-28_hover-pocket-ai-native-final-integration.md`。

## 2026-08-28 Windows Codex sandbox production fail-closed remediation

- Security finding `csf_3caf7ab99af268f9b88d011e`への即時対処として、Settings bridge、production provisioner、production generator resolver、管理者PowerShellのsetup / repair全入口を固定errorで閉じた。旧setup-v5 markerや既設`codex.exe`だけではproduction生成を再有効化しない。
- forged Settings requestはpickerと承認より前に停止し、production provisionerの直接呼び出しもbinary copy、directory作成、管理者判定、process起動へ進まない。Settingsは初回state readback前からsetupボタンを無効化する。
- ChatGPT Pro Orchestrator run `20260828-113152-...`は`sent-state-unknown`から同一session回収を試みたが、bounded recoveryの総時間上限でartifact未回収のままblockedとなった。再送せず、Skillが許可するPro blocked時のCodex再実装へ切り替えた。
- `git diff --check`、Settings JavaScript構文、initial disabled回帰、Voice共通契約42件、workflow YAML parseは成功した。独立したread-only bypass / regression reviewではserver-side bypass 0件、初期ボタン有効の表示回帰1件を検出し、修正後の回帰検証が成功した。
- code head `8658d6cc078287a3ad98fe3b5e6dfef46f727daf`のPR Windows run [33168494246](https://github.com/shotaro311/hover-pocket/actions/runs/33168494246)で、PowerShell parser / self-test / nonexistent-drive Check・Provision、Release / Debug build、Settings / Pocket / Voice / Updater / rendered UI verifierがすべて成功した。Release / Debug buildは警告0・エラー0である。
- 同headでmacOS Capabilities [33168494251](https://github.com/shotaro311/hover-pocket/actions/runs/33168494251)、3 OS contract / compare、Routerを含むPR check 7 / 7が成功し、PRは`MERGEABLE / CLEAN`である。
- read-only Security verifyはfinding `csf_3caf7ab99af268f9b88d011e`を`fixed`と判定した。元の昇格sinkはproduction全入口から到達不能で、既存Settings・Voice・Capability契約もCIで維持された。これは元の脆弱経路の修正判定であり、安全な正規setup機能の完成判定ではない。
- 中間のWindows run [33168222594](https://github.com/shotaro311/hover-pocket/actions/runs/33168222594)と[33168369422](https://github.com/shotaro311/hover-pocket/actions/runs/33168369422)は製品実装ではなくfail-closed CI harnessの配列binding / native nonzero捕捉で失敗し、`.NET ProcessStartInfo`でexit codeとstderrを明示取得する形へ修正後に上記runで成功した。
- これは安全な停止境界であり、最終機能の代替ではない。署名済みnative helper、元user SID binding、admin-owned root、公式Codex resource closureのexact検証、absolute-path起動、single-flight、child process所有、実UAC canaryは未完了である。
- 詳細: `progress/2026-08/2026-08-28_hover-pocket-ai-native-final-integration.md`。

## 2026-08-28 AI-native final-head security gate

- Draft PR #39のcode head `a20a35f1e2480e6e5e557f43256699fe5567be51`は、Router、Windows Verify、macOS Capabilities、macOS / Windows / UbuntuのPocket contract compareを含む全7 checkが成功した。通常ユーザーWindows実機の隔離taskでも、provisioning self-test、未準備時の`HP_CODEX_SANDBOX_NOT_READY`、Release build警告0・エラー0、Settings / Pocket Surface verifier、配布物へのprovisioning script混入0をreadbackした。
- Codex Security diff scan `47c3e1c5-ce27-4c96-8d1e-6d522c79b040`をexact range `16090d7a86c81ab19d85018462814c7279bb8801..a20a35f1e2480e6e5e557f43256699fe5567be51`で完了し、59 / 59 review item、3 / 3 candidate validation、coverage complete、sealed artifactを再読込した。
- reportable findingは1件で、severityはmedium、occurrenceは`occ_6b501da2f23a262f400826dd`。固定Codex executableのsize / SHA / handle pinは任意binary差し替えを防ぐが、固定`codex-home`のdirectory identityをUAC前に保持しないため、同一ユーザーのmedium-integrity processが事前配置したjunctionを公式Codex setupが昇格後に再解決し、reparse先へfile作成またはDACL変更を行う可能性がある。
- actual Windows UAC setup、junction canary、positive elevated confinementは実行していない。production generation / activationは引き続きfail closedであり、現行setup / repairを実用リリースの受入対象から外した。
- 次の実装gateは、trusted native elevated helperで各path componentのreparseを拒否し、handle-relativeなdirectory identityを全昇格処理の終了まで保持すること。無害なadmin-owned canary rootでwhole-home / nested reparse拒否、target不変、正常setup、UAC取消、post-readback失敗時のfail closedを検証する。
- 詳細: `progress/2026-08/2026-08-28_hover-pocket-ai-native-final-integration.md`。

## 2026-08-27 AI-native AN5 Codex auth control-plane runtime canary

- macOS / Windowsの生成adapterへ、Host resourceのSHA-256を固定したstatic model catalogを追加した。modelは`gpt-5.6-sol`、reasoning effortは`medium`へ固定し、生成processからremote `/models`へアクセスさせない。
- catalogはregular file、size、digest、model、tool / search / parallel / multi-agent無効化をHostが検証してから、fresh workspaceへread-onlyでコピーする。改ざんbytesは両OSの決定論的Verifierで拒否する。
- exact signed `codex-cli 0.145.0`を使う非機密surrogate canaryで、2回のResponses request、remote model catalog access 0、auth helper起動1回、モデルtoolからhelper read / execute拒否、request body / stdout / stderr / temp diskへのcredential非残留をreadbackした。さらにHost固定のgeneration output schemaが両Responses requestへ結合され、Codex stdoutがToday Focus Pocket envelopeのcanonical JSONだけになることを確認した。
- Swift warnings-as-errors build、Pocket App package / lifecycle / generation / migration / health / workspace backup、Capability、Broker、Pocket Surface、Voice Foundation、Panel layout、Timer、15 schema / 71 fixtureの2回byte一致、workflow YAML、`git diff --check`が成功した。
- exact working-tree Security scan `d01e40c3-9ea3-47d7-875b-c0dd6e3fff3b`はsnapshot `codex-security-snapshot/v1:sha256:26f7188cdd471fd51706f8e9cb48e83e286607f49675836f6f941bdb522a9929`、changed source 8 / 8、coverage complete、reportable finding 0件でsealed completeとなり、完成manifest / findings / coverageを再読込した。
- generation schema縦断追加のexact working-tree Security scan `6386a980-8f9a-4988-85fa-9f5c38f2fe7c`はsnapshot `codex-security-snapshot/v1:sha256:68d21b2a3cceb696b23002109acb2a40dc1571a33bea0f3984f0057d9753dc0d`、changed source 1 / 1、coverage complete、reportable finding 0件でsealed completeとなった。schema / fixture差し替えとcredential漏えいの候補は、固定digest、両requestのexact schema一致、canonical stdout完全一致、実Codex canaryのbody / output / disk非残留で閉じ、完成manifest / findings / coverageを再読込した。
- code head `034f5f3fd587a55e58c404a482e8881f8e330be7`でRouter [33031829954](https://github.com/shotaro311/hover-pocket/actions/runs/33031829954)、Windows [33031831285](https://github.com/shotaro311/hover-pocket/actions/runs/33031831285)、macOS [33031831272](https://github.com/shotaro311/hover-pocket/actions/runs/33031831272)、3OS Pocket contract [33031831229](https://github.com/shotaro311/hover-pocket/actions/runs/33031831229)がすべて成功した。macOS logで新auth control-plane self-testと`pocket_app_generation_verify=ok`、Windows logでRelease / Debug warning 0 / error 0、`generation-parent-chain`、`pocket_app_generation_verify=ok`、3OS reportのbyte一致をreadbackした。push起点の重複contract [33031829090](https://github.com/shotaro311/hover-pocket/actions/runs/33031829090)も成功した。
- Draft PR #39は同headで`Draft / OPEN / MERGEABLE / CLEAN`、review / comment 0件である。
- 同じToday Focus fixtureはHost製品Verifierでschema検証、preview、承認、install、update、rollback、disable / enable、remove、readbackまで成功した。これはmock Responses transportの隔離証拠であり、実モデル生成の代替にはしない。
- production gateは変更していない。macOS `supportsConfidentialGeneration == false`、Windows `ResolveExecutable() == null`、両OS preview-onlyを維持する。Windows compile / Verifierは更新headのPR CIで確認済みだが、native elevated positive canaryは通常Windows hostの独立gateとする。

## 2026-08-27 AI-native AN5 Codex生成credential delivery接続

- Codex 0.145.0のcommand-backed custom providerはauth helperをstdinなしで起動することを公式config契約とexact sourceで確認した。旧v1 helperのHost起動・stdin bootstrapは独立contract testとして残し、production生成用にはHost → Codex生成process → auth helperの親子関係からendpointを導出するv2を追加した。
- macOSはHost PIDとCodex生成PIDからowner-only Unix socketを作り、helperのsame UID、Codex直接child、HoverPocket designated requirementをserver側で確認する。helper側もserverのexact Host PIDとdesignated requirementを確認する。
- Windowsは同じPID pairから`CurrentUserOnly` named pipeを作り、OSが返すclient / server PID、Codex直接child、`Environment.ProcessPath`一致を相互確認する。providerはCredential Managerを認証済みrequest後に遅延readする。
- 両OSともAPI key、endpoint、capabilityをargument、environment、workspace、receipt、logへ置かない。内部leaseは30秒・1回限りで、provider失敗を含む最初のredeemで消費し、broker終了時にsocket / pipeを閉じる。model toolのfilesystem profileはhelper executable pathを明示denyする。
- Codex custom providerは`auth.command`、constant helper arg、`auth.refresh_interval_ms=0`、request / stream retry 0へ固定した。直接bearerやcredential環境変数は使わない。
- production gateは変更していない。macOSは`supportsConfidentialGeneration == false`、Windowsは`ResolveExecutable() == null`、両OSはpreview-onlyを維持する。実API key、実model生成、activation、実マイク、署名、配布には接続していない。
- 最新差分でSwift warnings-as-errors build、Pocket App package / lifecycle / generation / migration / health / workspace backup、Capability、Broker、Pocket Surface、Voice Foundation、Timer、15 schema / 71 fixture、Voice静的42件、Windows JavaScript構文、`git diff --check`が成功した。macOS verifierはv1 one-shot / replay / expiry / mutual identityに加え、v2 Host → generation probe → helper parent chainとsocket cleanupを実実行した。
- exact working-tree Security scan `55b573a8-4b94-4ec0-b077-286887885e00`はsnapshot `codex-security-snapshot/v1:sha256:bb7ef31f647030015b83542f5230dbe7dfd08936c7e631c9bb2e835630967ef0`、changed source 10 / 10、coverage complete、reportable finding 0件でsealed completeとなり、完成manifest / findings / coverageを再読込した。
- code head `ab7fcc8dd75c97f4bcd59aa7d8cf1061c9296991`はremote parity `0 / 0`であり、Router [33028857939](https://github.com/shotaro311/hover-pocket/actions/runs/33028857939)、Windows [33028858902](https://github.com/shotaro311/hover-pocket/actions/runs/33028858902)、macOS [33028858917](https://github.com/shotaro311/hover-pocket/actions/runs/33028858917)、3OS Pocket contract [33028858939](https://github.com/shotaro311/hover-pocket/actions/runs/33028858939)がすべて成功した。重複push run [33028856731](https://github.com/shotaro311/hover-pocket/actions/runs/33028856731)も3OS verifier / byte一致を含め成功した。
- Windows logで`generation-parent-chain`の開始・終了、`pocket_app_generation_verify=ok`、Release / Debug Voice E2E buildのwarning 0 / error 0をreadbackした。macOS logでもSwift buildと`pocket_app_generation_verify=ok`をreadbackした。Draft PR #39は`Draft / OPEN / MERGEABLE / CLEAN`、review / comment 0件である。
- 残る受入は、通常Windows hostのelevated positive confinement、実モデルを使うauth control-plane / model-tool helper deny分離、credential非永続readback、Pocket App DSL生成からrollback、両OS物理Voice E2E、正式署名・配布である。

## 2026-08-27 AI-native AN5 macOS Codex sandbox実行canary

- 本番Pocket App生成の`supportsConfidentialGeneration == false`を維持したまま、固定vendor path、OpenAI Developer ID署名、Team ID、strict codesign、exact `codex-cli 0.145.0`を満たす実行体だけを許可するmacOS verifierを追加した。symlink、非regular file、group / world writable、想定外owner・version・署名は実行前にfail closedで拒否する。
- fresh temp rootへread-only workspace、deny Codex Home、deny virtual User Home、専用TMPDIRを作り、別sibling rootとloopback listenerを置いた。`codex sandbox -P hoverpocket-generation`でworkspace readのみ成功し、workspace write、Codex Home read、User Home read、outside-root read、loopback接続がすべて拒否されることを実実行でreadbackした。
- childは10秒上限とprocess group TERM / KILL、stdout / stderr上限、exact JSON結果、stderr canary非露出、validated temp cleanupへ閉じた。receiptはversionとallowlist booleanだけで、秘密値、canary本文、path、PIDを含めない。CIは署名済みCLIの存在へ依存させず、全判定反転とpermission markerを確認する`--self-test`だけを実行する。
- ローカルでPython self-test、実sandbox canary、symlink CLI拒否、Swift warnings-as-errors build、Pocket App package / lifecycle / generation / migration / health / workspace backup、workflow YAML parse、`git diff --check`が成功した。実canary receiptはsigned executable、workspace read、write denial、両Home / outside-root read denial、network denial、listener未到達、stderr上限をすべてtrueとして返した。
- exact working-tree Security scan `a020f0d1-bfde-401f-94ab-243146343be9`はsnapshot `codex-security-snapshot/v1:sha256:ff99dad207ee72deafdbf38d21001cb1444b175dfdd61da4a96ee2b4b838ee05`をcoverage complete、reportable finding 0件で封印・再読込した。workflow-only差分とproduction fail-closed root controlも補助surfaceとして確認した。
- code head `8cd445b`はremote parity `0 / 0`であり、同じexact headを手動dispatchしたmacOS [33022481993](https://github.com/shotaro311/hover-pocket/actions/runs/33022481993)、Windows [33022484529](https://github.com/shotaro311/hover-pocket/actions/runs/33022484529)、3OS Pocket contract [33022486583](https://github.com/shotaro311/hover-pocket/actions/runs/33022486583)が成功した。最終進捗commitを含むhead `ebb0aa7`では遅れて通常のPR workflowも自動起動し、Router [33022842034](https://github.com/shotaro311/hover-pocket/actions/runs/33022842034)、macOS [33022844429](https://github.com/shotaro311/hover-pocket/actions/runs/33022844429)、Windows [33022844408](https://github.com/shotaro311/hover-pocket/actions/runs/33022844408)、3OS Pocket contract [33022844417](https://github.com/shotaro311/hover-pocket/actions/runs/33022844417)の全7 checkが成功した。
- Draft PR #39は`Draft / OPEN / MERGEABLE / CLEAN`、review / comment / unresolved thread 0件である。macOS logで新self-test、Windows全既存Verifier、3OS byte一致をreadbackした。実マイク・実API・配布gateが未完了なのでReady / mergeには進めない。
- Windows側はnative elevated sandboxをproduction templateへ固定し、unelevated backendがread-only profileを受理しないnegative-controlを追加した。pinned `codex-cli 0.145.0`のarchive / executable hash、Authenticode、signer、versionを検証し、CI [33024514348](https://github.com/shotaro311/hover-pocket/actions/runs/33024514348)でself-test、actual downgrade rejection、Release / Debug build、全既存Verifierをreadbackした。これはelevated成功の証拠ではない。
- Windows exact code range `d8520c9...12aa701`のSecurity scan `0db33908-e8ec-4fe2-87b4-75079f34849c`はsnapshot `codex-security-snapshot/v1:sha256:ba93a9bd10cff7fd7dd79e08615faf1e7e1890f1a44006b66ec964d8060fb19a`、coverage complete、finding 0件でsealed completeとなった。productionは`ResolveExecutable() == null`、activationは`AllowsActivation == false`を維持する。
- 残るgateは、通常Windows hostでのnative elevated positive canary、Host-owned一回限りcredential deliveryと実DSL生成、両OSの実マイク / API Voice E2E、正式署名、配布、rollbackである。これらが完了するまでproduction生成を有効化しない。詳細: `progress/2026-08/2026-08-27_hover-pocket-ai-native-final-integration.md`。

## 2026-08-26 AI-native Core GA final integration candidate

- main `a35b0ea8`とDraft PR #32〜#38のheadをGitHubから再確認し、ChatGPT Pro criticの独立レビューに固定した。Pro runは送信後のdownload処理で`setTypeOfService EINVAL`になったが、新規promptを送らず同じsessionをharvestし、standalone `integration-review.md`（SHA-256 `8e8bc5c4...5b80`）を回収した。exact head、統合順、競合責務、physical E2E / signing分離、stop条件の受入4 / 4をCodexがreadbackし、runをterminal化した。
- exact #36 `16090d7`から隔離branch `codex/ai-native-core-ga-final-integration`を作り、#37 `7472c73`、#38 `5883925`、#35 `e4cd8f0`の順に統合した。R1は`8f3a348`、R2は`9201154`、R3は`b66392f`。#32〜#34は#35の祖先として1回だけ取り込み、再mergeしていない。
- 競合はPro予測どおり`progress/progress.md`とWindows `Program.cs`に限定された。Windowsはcredential helperを`StartupOptions`、Velopack、WPFより先にterminal dispatchし、通常経路ではVoice E2E専用rootと本番rootの隔離を維持した。Windows workflowはRelease / Debug build、Pocket Surface timeout、Voice E2E isolation、PowerShell構文、既存signing contractをすべて保持した。
- final headで`swift build -Xswiftc -warnings-as-errors`、Voice静的42件、Voice Foundation、Panel layout 128件、Capability 20 handler、Broker 21 descriptor / 20 handler、Pocket Surface、Pocket App package / lifecycle / generation / migration / health / backup、Timer、Pocket contract 15 schema / 71 fixtureの2回byte一致、Windows JavaScript / Settings生成先、`git diff --check`が成功した。
- exact差分Security scanは39 / 39 sourceを確認し、sealed complete、reportable finding 0件だった。追加のrelease hardeningとして、Windows Debug Voice E2Eと通常Verifierの併用を明示拒否し、本番credential / Calendarへ再接続できる設定上書きを閉じた。macOSはマイク許可待ち中のcloseを世代管理し、遅れて返る音声streamを停止してSDP・session stateを残さないよう修正した。実行型のrenderer回帰、静的Voice契約、Swift warnings-as-errors build、製品Verifier、共通contractはローカルで成功し、Windows C# buildは更新headのCIをgateとする。
- `b51e7f0`をbaseに、macOS実音声を本番状態から分離して検証するDebug専用E2E harnessを追加した。専用bundle / fresh temp root / ephemeral defaults / process-memory credential / Timer-only Provider Registryへ閉じ、Google OAuth、Calendar、Weather、Camera、Updater、production Application Support、UserDefaults、Keychainを使わない。Run / Stop / Cleanupはsession lockで直列化し、exact command / PID、top-level symlink・型・canonical containment、attempt-bound native confirmation、stopped receipt後のcleanupを検証する。
- 秘密値・マイクなしの実ライフサイクルで、事前lock拒否、Run、receipt readback、隔離検証、allowlist名のsymlink拒否、Stop後の`safe_close` / credential 0、Trash cleanup、source path不在、exact process不在を別経路で確認した。Swift debug / release warnings-as-errors、Voice / Capability / Broker / Pocket App / Surface / Timer、Windows JavaScript、15 schema / 71 fixtureの2回byte一致、`git diff --check`も成功した。最終Security scan `710a8647-1d45-4f45-98dc-56d0b66a5909`はsnapshot `ad8cb7ef...`の20 / 20 fileをcoverage complete、finding 0件で封印した。
- Draft PR #39 code head `c3435b1`で、Windows [32952589486](https://github.com/shotaro311/hover-pocket/actions/runs/32952589486)、macOS [32952589632](https://github.com/shotaro311/hover-pocket/actions/runs/32952589632)、Router [32952585405](https://github.com/shotaro311/hover-pocket/actions/runs/32952585405)、Pocket contractの全11 checkが成功した。macOSはE2E receipt self-test、renderer、静的Voice契約、隔離Verifierを含み、WindowsはRelease / Debug Voice E2E buildと全既存Verifierを含む。PRは`Draft / OPEN / MERGEABLE / CLEAN`、review / comment / unresolved threadは0件である。実API key、マイク、可聴remote audio、署名済みTCCは未実施である。
- Draft PR [#39](https://github.com/shotaro311/hover-pocket/pull/39) hardening code head `b328243`で、Windows [32941881191](https://github.com/shotaro311/hover-pocket/actions/runs/32941881191)、macOS [32941881164](https://github.com/shotaro311/hover-pocket/actions/runs/32941881164)、Router [32941879235](https://github.com/shotaro311/hover-pocket/actions/runs/32941879235)が3 / 3成功した。WindowsはRelease / Debug buildが警告0・エラー0で、Voice E2E verifier mutual exclusion、PowerShell構文、signing contract、rendered WebView2まで成功した。macOSは新しいlate microphone capture回帰を実行し、track停止、stale state / SDP offer不在を確認した。両OSの実マイク・可聴remote audio、macOS notarization / Gatekeeper / Sparkle、Windows timestamped Authenticode / Velopack / feed、実配布rollback、stack mergeは未完了である。詳細: `progress/2026-08/2026-08-26_hover-pocket-ai-native-final-integration.md`。

## 2026-08-26 AI-native AN3-B3B macOS Realtime Voice

- AN3-B3A exact head `16090d7`から隔離worktreeとbranch `codex/ai-native-an3b3b-macos-realtime`を作り、macOSのOpenAI Realtime BYOK実音声transportを実装した。Voice Laneを有効にしただけではマイクを開始せず、パネルのマイク操作後だけ接続する。
- API keyはKeychainからnative ephemeral `URLSession`へだけ渡し、非永続・非inspectable WebViewはmicrophone / WebRTC / remote audio / data channelだけを所有する。Calendar list/createとTimer startは共有Capability Registry / Broker、native承認、実行後readbackを経由する。
- Voice承認を同時1件、拒否を含め60秒3件へ制限し、セッション終了・Calendar grant取消・credential変更で承認と処理を取消してadapterを再構築する。承認文面の単一行化、function異常時のmedia close、JavaScript mute / teardown readbackとfail-closed page resetも追加した。
- Codex Security差分scan `5670016c-fea6-463c-a42b-6e9aea700b55`の5件のLowをすべて局所修正し、元の攻撃経路と対応回帰を再照合した。WebContent異常時の物理microphone停止は、静的fallbackだけでなく実機fault-injectionを最終gateとして残す。
- ローカルではSwift warnings-as-errors build、Voice Foundation、Capability 20 handler、Broker 21 descriptor / 20 handler、Pocket App、Pocket Surface、Panel layout 128件、Timer、共通contract 15 schema / 71 fixture、Voice静的契約、`git diff --check`が成功した。SwiftPMにはTests targetがないため`swift test`は`no tests found`であり、製品内の決定論的verifierを正本とした。
- Draft PR [#38](https://github.com/shotaro311/hover-pocket/pull/38) code head `a0140fa`で、Windows [32919662223](https://github.com/shotaro311/hover-pocket/actions/runs/32919662223)、macOS [32919662200](https://github.com/shotaro311/hover-pocket/actions/runs/32919662200)、Router [32919662240](https://github.com/shotaro311/hover-pocket/actions/runs/32919662240)が3/3成功した。PRは`Draft / MERGEABLE / CLEAN`、review / comment 0件、remote parity `0 / 0`である。
- 未完了gateは、実API keyと実マイクによる発話・remote audio一往復、Calendar read/createとTimer startの実データ承認/readback、mute/end/WebContent異常時の物理track停止、stack PRの人手mergeである。詳細: `progress/2026-08/2026-08-26_hover-pocket-ai-native-an3-b3b-macos-realtime.md`。

## 2026-08-26 AI-native AN3-B3B Windows実音声E2E security follow-up

- exact base `16090d7a86c81ab19d85018462814c7279bb8801`からcode head `276e5eb57b06e45c0cc8f8a5ffe064b46040eeca`までをCodex Security scan `32812599-f0a7-4397-af98-fcce4a65990f`で確認し、Low 4件を検出した。coverageはchanged source 13 / 13である。
- E2E receiptへHost発行media leaseと順序検証を追加し、rendererがHost-ownedのtransport detach / safe closeを記録する経路を除去した。さらにrenderer診断だけでは合格にせず、WPFのネイティブ確認ダイアログでユーザーが実マイク入力とremote audioを確認した場合だけ`physicalMediaUserConfirmed=true`を記録する。receipt schemaはv2とし、PowerShell `Validate`は実音声確認、Timer Capability readback、接続状態を必須にした。
- media receipt telemetryはfire-and-forgetにし、未完了Promiseでもmicrophone / WebRTC cleanupが先に完了するharnessへ固定した。E2E API keyはCredential Managerへ永続化せずzeroing process-memory storeだけを使い、Productionは従来どおりCredential Managerを使う。E2E Panel / Settingsからの外部browser起動もHost policyで拒否する。
- verify-fixでは、telemetry cleanup、credential persistence、external browserの3件をfixedと判定した。最初のrenderer receipt findingも、active rendererがleaseを知るだけではHost-owned user confirmationを作れず、最終`Validate`がその確認を必須にする現headでfixedと再判定した。renderer由来のmedia fieldsは診断情報であり、単独では合格証跡にしない。
- ローカルで`node --check`（panel / i18n / settings）と`git diff --check`が成功した。このMacには.NET SDK / PowerShellがないため、Windows CIを必須gateにした。
- Draft PR [#37](https://github.com/shotaro311/hover-pocket/pull/37) code head `ba1273fb832463307d4a41de3e0b769607d4677c`で、Windows [32914420289](https://github.com/shotaro311/hover-pocket/actions/runs/32914420289)はRelease / Debug build、Voice foundation、Voice E2E isolation、PowerShell構文、rendered WebView2を含む全stepが成功した。Router [32914419440](https://github.com/shotaro311/hover-pocket/actions/runs/32914419440)も成功し、PRは`Draft / MERGEABLE / CLEAN`、review / comment 0件である。
- 未完了はWindows実機でのAPI key入力、実マイク、remote audio、Timer承認、ネイティブ実音声確認、`Validate`、Stop後cleanupのreadbackである。macOS AN3-B3Bは既存のChatGPT Pro runの正本delivery待ちで、重複promptは送らない。詳細: `progress/2026-08/2026-08-26_hover-pocket-ai-native-an3-b3b-windows-security.md`。

## 2026-08-24 AI-native AN3-B3B Windows実音声E2E隔離基盤

- `codex/ai-native-an3b3b-windows-e2e`をAN3-B3A exact head `16090d7`から分離し、Pro担当中のmacOS Realtime transportと重ならないWindows実機E2E基盤を実装した。
- Debug専用fresh temp rootへ設定、WebView2、Provider data、Capability Broker、receiptを閉じ、本番と別のCredential Manager targetとIPCを使う。ReleaseはE2E flagsを拒否し、Updater / startup / Google Calendar / Controls / Clipboard / Codex app-server / AI-nativeはfail closedにした。
- WebRTCのmicrophone、remote audio track / playback、teardownをHostへsafe eventとして返し、transcript本文・音声・SDP・API key・path・PIDを含まないallowlist receiptへatomic保存する。Timer Capability Brokerの実行後readbackもbooleanで記録する。
- `voice_e2e_windows.ps1`へBuild / Run / Readback / Stopを追加した。ローカルではWindows UI JavaScript構文と`git diff --check`が成功した。このMacに.NET SDK / PowerShellがないため、C# warnings-as-errors、Debug verifier、PowerShell、rendered WebView2はDraft PR Windows CIを必須gateとする。
- 現行OpenAI coordinatorはtranscript eventをsnapshotへ反映しないため、ProのmacOS artifactで共通event契約を確定してからWindowsへ統合する。実API keyを使うWindows物理E2EはCI後のWindows実機gateであり、秘密値・transcript・音声・SDPをartifactへ残さない。詳細: `progress/2026-08/2026-08-24_hover-pocket-ai-native-an3-b3b-windows-e2e.md`。
- Draft PR #37の初回Windows run `32722365200`で検出した通常UI verifierの`clipboard.getState`未登録を、E2E隔離境界を`IsIsolatedVoiceE2E`へ限定して修正した。修正後run `32722634593`はRelease / Debug build、Voice E2E isolation、PowerShell構文、rendered WebView UIを含む全stepが成功した。code head `b8b1a912d9f657fd0792740c39b39c66d127fac3`は`Draft / MERGEABLE / CLEAN`、review / comment 0件、remote parity `0 / 0`である。

## 2026-08-24 AI-native AN5 credential broker mutual process identity

- PR #34 final head `81cf0eee`からstack branch `codex/ai-native-an5-credential-broker-mutual-identity`を分離し、Hostが実helperを起動してPIDを取得してからbrokerを作り、version付きbounded JSONを専用stdin pipeへ渡す起動順序へ変更した。endpoint / capabilityを環境変数やprocess argumentへ置かない。
- macOSはclient / server双方でpeer UID、exact PID、designated requirementを確認する。Windowsは`GetNamedPipeClientProcessId` / `GetNamedPipeServerProcessId`のexact PIDとHoverPocket executable pathを双方で確認する。同じHoverPocket binaryでもHostが起動した対象PIDと異なるprocessは拒否する。
- macOS verifierは実helper child成功、同一binary誤PID、誤server PID、Python foreign peer拒否を含むPocket App verificationを3回連続で成功した。warnings-as-errors build、Voice契約42件、Panel 128件、Capability / Broker / Surface / Timer、15 schema / 71 fixture、Windows JavaScript構文、`git diff --check`も成功した。
- final head `1d55dab3`でWindows [32672304607](https://github.com/shotaro311/hover-pocket/actions/runs/32672304607)、macOS [32672304592](https://github.com/shotaro311/hover-pocket/actions/runs/32672304592)、PR Router [32672304100](https://github.com/shotaro311/hover-pocket/actions/runs/32672304100)が成功した。Windows Release buildはwarning 0 / error 0で、helper、foreign peer、same-binary wrong PID、wrong server PIDを含む全caseの終端をreadbackした。
- final exact range `81cf0eee...1d55dab3`のCodex Security diff scan `210c26b0-0934-4e9d-875e-60e7fd663a63`は変更source 5 / 5件を確認し、reportable finding 0件で封印・再読込した。snapshot digestは`codex-security-snapshot/v1:sha256:ca026630152d323ee57fbdf94f326bbb28cb195b7106cad365a8aa73d3211126`。coverageは正式Authenticode publisher bindingとproduction store / confined generator E2Eだけをdeferred gateに残す。production generatorは未接続でfail-closedを維持する。詳細: `progress/2026-08/2026-08-24_hover-pocket-ai-native-an5-credential-broker-mutual-identity.md`。
- stacked Draft PR [#35](https://github.com/shotaro311/hover-pocket/pull/35)の初回Windows run [32672078767](https://github.com/shotaro311/hover-pocket/actions/runs/32672078767)では実helper childがtimeoutした。childは`Console.OpenStandardInput()`でredirect済みstdinを明示取得し、HostはCRLFではなくLFを明示書込みするよう修正した。`Environment.ProcessPath`が`dotnet` hostの場合のentry assembly再起動も追加し、修正後CIで全case成功を確認した。

## 2026-08-24 AI-native AN5 credential broker peer identity

- PR #33 head `7447e329`からstack branch `codex/ai-native-an5-credential-broker-identity`を分離し、credential値やAN3-B3AのKeychain / Credential Manager契約を変更せず、broker接続元のidentity gateだけを追加した。
- macOSはUnix socketのpeer UIDと`LOCAL_PEERPID`を取得し、実行中peer codeが現在のHoverPocketと同じdesignated requirementを満たす場合だけrequestを読む。別実行体へ正しいfixture capabilityを渡す先着canaryはsecretを取得できず、leaseを消費してfail closedになった。同じHoverPocket helper subprocessは成功した。
- Windowsは`GetNamedPipeClientProcessId`でclient PIDを取得し、現在のHoverPocket executableと同じ正規化pathのprocessだけを許可する。PowerShell別processの先着canaryと注入authorizerのnegative caseを追加した。正式releaseでのAuthenticode signer bindingは別gateとして残す。
- `swift build -Xswiftc -warnings-as-errors`、Pocket App package / lifecycle / generation / migration / health / workspace backup、Pocket Surface、Capability、Broker、Voice、15 schema / 71 fixture、Voice contract 42件、`git diff --check`が成功した。このMacに.NET SDKはないためWindows Release buildとforeign-peer verifierはstacked Draft PR CIで確認する。
- Codex Security diff scan `efe77173-169f-402b-a202-85475b321270`はreportable finding 0件で封印・再読込した。coverageはpartialで、production有効化前にmacOS helper側server identity pinningと、両OSexpected helper PID bindingを必須gateとして残す。先行不正接続によるlease消費はcredential漏えいなし・単一ローカル生成のfail-closed失敗に限定されるためsecurity findingから除外した。
- 初回PR #34 Windows CI `32670323133`はRelease build、Settings UI、Capability、Brokerまで成功したが、cold PowerShell foreign-peer canaryが5秒のprocess wait上限に達した。broker server lifetimeを20秒、process waitを15秒へ分け、server expiryによる偽陽性を避けながらCI起動時間を許容するbounded timeoutへ修正した。
- 修正後macOS回帰で、foreign peerが拒否応答前にsocketを閉じた際の`SIGPIPE` exit 141を1回再現した。broker server/client socketへ`SO_NOSIGPIPE`を設定し、signal終了ではなく通常のfail-closed write failureへ固定した。
- 修正後code head `cd3be0d`のPR [#34](https://github.com/shotaro311/hover-pocket/pull/34)で、Windows [32670574517](https://github.com/shotaro311/hover-pocket/actions/runs/32670574517)はRelease warning 0 / error 0、foreign-peer / unauthorized-peer / helperの全BEGIN / END、Pocket App generationと全後続verifierが成功した。macOS [32670574498](https://github.com/shotaro311/hover-pocket/actions/runs/32670574498)とRouter [32670573186](https://github.com/shotaro311/hover-pocket/actions/runs/32670573186)も成功した。
- final exact-range Codex Security scan `63f51914-16de-4553-b765-bd3119ac2086`はreportable finding 0件で封印・再読込した。snapshot digestは`codex-security-snapshot/v1:sha256:40827c3008d55d7d8abd24e3a09d14328c2f3820693ccef02fb662f798433f04`。coverageはpartialで、macOS server identity pinningと両OSexpected helper PID bindingをproduction有効化前gateに残す。
- 正本AN3-B3A Pro runは同一sessionで`inProgress`、bridgeはsignal未着のままであり、新規送信・再送・成果物先読みをしていない。詳細: `progress/2026-08/2026-08-24_hover-pocket-ai-native-an5-credential-broker-identity.md`。

## 2026-08-24 AI-native AN5 Host-owned credential broker foundation

- `codex/ai-native-an5-codex-confinement` head `e6747898`からstack branch `codex/ai-native-an5-credential-broker-foundation`を分離し、macOSのprivate Unix socketとWindowsの`CurrentUserOnly` Named Pipeへ、最大60秒・256 bit・一度だけ使えるcapability leaseを実装した。secretは最大8 KiB、制御文字禁止、request / response上限と2秒timeoutを持つ。
- 両OSのHost executableへ`--codex-credential-helper`入口を追加した。helperはendpointとcapabilityだけを環境から受け、secretを成功時の標準出力だけへ返す。API keyの値を引数、ファイル、ログ、UI、fixtureへ置かない。実credential storeとproduction generatorはまだ接続せず、fail-closedを維持する。
- Windows clientはCancellationTokenだけでなく、`.NET 10`の明示`TimeSpan` timeout付き`NamedPipeClientStream.ConnectAsync`を使い、server不在時も接続待ちを有限化した。
- Windows CIの停止位置を段階ログで`named-pipe`の最初の`await`へ絞り、WPF UI threadでasync verifierを同期待ちしていたdeadlockを修正した。broker verifierはthread pool上で開始し、CI stepにも2分上限を設けた。
- 修正後head `143ed3f`のDraft PR [#33](https://github.com/shotaro311/hover-pocket/pull/33)で、Windows [32668817459](https://github.com/shotaro311/hover-pocket/actions/runs/32668817459)はRelease build warning 0 / error 0、lease / Named Pipe / wrong capability / helperの全broker段階、Pocket App generation、Settings、Voice、rendered UIまで成功した。macOS [32668817516](https://github.com/shotaro311/hover-pocket/actions/runs/32668817516)とRouter [32668816613](https://github.com/shotaro311/hover-pocket/actions/runs/32668816613)も成功した。
- macOSでone-shot、expiry、replay、wrong capability、socket権限、helper child process、明示cancel cleanupを検証した。セキュリティ監査でdeinit-only deadlockを再現したため、FD / socket / directoryのcleanup stateをserver objectから分離し、明示cancelなしの子process probeを追加した。修正後probeはexit 0、新規一時socket残留0件である。
- Codex Security diff scan `cc22a511-9d5a-4052-a3ea-7097aa17dd3f`はreportable finding 0件で封印・再読込した。coverageはpartialで、production接続前にhelper peer identity、macOS socket identity、両OSのsame-user first-client raceを実機canaryで再検証する5項目を残す。manifest SHA-256は`090a54f6df21106c35ba76fd9cc96ae30a37010da2e954084503682c200f0e42`。
- macOS warnings-as-errors build、Pocket App package / lifecycle / generation / migration / health / workspace backup、Pocket Surface、Capability、Broker、Voice、15 schema / 71 fixture、Voice contract 42件、`git diff --check`が成功した。このMacには.NET SDKがないため、Windows Release buildとnative broker verifierはDraft PR CIを必須gateにする。
- 不一致だった旧Pro deliveryはreceipt / artifactを読まず、適用・`mark-done`・再利用をしていない。正本AN3-B3A bridgeは`running`のままで、新しいsignalを待つ。詳細: `progress/2026-08/2026-08-24_hover-pocket-ai-native-an5-credential-broker.md`。

## 2026-08-24 AI-native AN5 Codex confinement audit

- 通知された旧AN3-B3A Pro deliveryは、delivery ID / expected state hash付き`claim-synthesis`が`run state hash does not match the completion signal`で失敗した。receipt・成果物を読まず、適用・`mark-done`・同run再利用を行っていない。後続の正本runは別deliveryとして検証・terminal化済みである。
- Codex CLI 0.145.0のnamed permission profileを実コードから確認し、`:minimal`と生成workspaceだけをread、network無効、shell environment継承なしにした。直接sandboxとGPT-5.6 Solの実`codex exec` canaryで、workspaceだけがreadable、兄弟worktree・`~/.codex/auth.json`・Obsidian Vaultはunreadableになった。
- ファイル隔離はmacOSで成立したが、API keyを環境変数・引数・auth fileへ置かないHost-owned credential brokerとWindows実機canaryは未実装である。現行macOS / Windows production generatorのfail-closedを維持する。
- 採用案はKeychain / Credential Manager、one-time capability、private Unix socket / named pipe、isolated `CODEX_HOME` / `HOME`、command-backed bearer auth、helper path denyを組み合わせる。AN3-B3Aのcredential store exact diff確定後、別の小さいstacked branchで実装する。詳細: `progress/2026-08/2026-08-24_hover-pocket-ai-native-an5-codex-confinement-audit.md`。
- 隔離branch `codex/ai-native-an5-codex-confinement`で、macOS / Windows adapterをrun単位のworkspace / `CODEX_HOME` / HOME / tempへ分離し、named permission profile、network無効、tool環境継承なしへ変更した。macOS warnings-as-errors build、Pocket App / Surface / Capability / Broker / Voice、15 schema / 71 fixtureが成功した。Windows C#はDraft PR CIを必須gateに残し、credential broker未接続のため両OSproduction generatorはfail-closedを維持する。
- code head `4a38a9f`のDraft PR [#32](https://github.com/shotaro311/hover-pocket/pull/32)で、Windows [32666112335](https://github.com/shotaro311/hover-pocket/actions/runs/32666112335)はRelease build warning 0 / error 0とPocket App生成・Voice・Settings・rendered UI verifier、macOS [32666112324](https://github.com/shotaro311/hover-pocket/actions/runs/32666112324)はwarnings-as-errors buildとPocket App / Voice contract、Router [32666112338](https://github.com/shotaro311/hover-pocket/actions/runs/32666112338)が成功した。PRはDraft / MERGEABLE / CLEANで、実Windows confinement canaryは未完了gateに残す。

## 2026-08-24 AI-native AN3-B3A Realtime BYOK provider

- GPT-5.6 SolのPro artifact `changes.patch`を、delivery ID / state hashの一意claim後にexact base `b95ef1681510781a38ccbb0b95cbf51384faa594`へ適用した。artifactは187,716 bytes、SHA-256 `0b089aee...c952`、standalone検証済みである。CodexはWindows build、Settings fixture、API key削除readback、Voice transition rollback、SDP応答上限の局所修正だけを追加した。
- Windowsへ明示provider選択、既定OFF、Credential Manager、Host-owned `/v1/realtime/calls` SDP交換、`gpt-realtime-2.1`、Registry由来Calendar list/create・Timer startだけのfunction surface、Capability Broker承認/readback、call ID / generation / root / size fenceを実装した。既存Codex app-server providerの互換gateは弱めていない。
- macOSへ同じprovider設定、Keychain、adapter seamを追加した。production audio adapterはAN3-B3Bまで明示的にunavailableであり、実音声transportへ暗黙fallbackしない。
- ローカルではSwift warnings-as-errors、Voice runtime / 静的42件、Capability 20 handler、Broker 21 descriptor / 20 handler、Pocket Surface、Panel layout 128件、Timer、共通contract 15 schema / 71 fixture、Windows UI構文、Settings生成先、`git diff --check`が成功した。
- Draft PR [#36](https://github.com/shotaro311/hover-pocket/pull/36) code head `16cc7a0`で、Windows [32717846919](https://github.com/shotaro311/hover-pocket/actions/runs/32717846919)、macOS [32717846913](https://github.com/shotaro311/hover-pocket/actions/runs/32717846913)、3 OS contract / byte比較 [32717847153](https://github.com/shotaro311/hover-pocket/actions/runs/32717847153)、Router [32717844455](https://github.com/shotaro311/hover-pocket/actions/runs/32717844455)を含む7/7 checkが成功し、進捗同期後のdocs-only headでも7/7を再確認した。PRは`Draft / MERGEABLE / CLEAN`、review / comment / unresolved thread 0件、remote parity `0 / 0`である。
- Pro run `20260824-144554-hoverpocket-an3-b3a-realtime-byok-windows-vertical-slice-patch`はlocal verification `PASS`、受入7/7 `PASS`、release gate readyをreadback後に`done`へfinalizeした。bridge terminal receipt SHA-256は`6404ac9f...f9c`で、同deliveryの再適用を禁止した。AN3-B3BにはmacOS実transport、Windows実機microphone / remote audio一往復、native-owned media isolationを残す。詳細: `progress/2026-08/2026-08-24_hover-pocket-ai-native-an3-b3a-realtime-byok.md`。

## 2026-08-24 AI-native AN8-C workspace backup / restore

- 正本Pro deliveryをdelivery ID / state hash付きでclaimしたが、same-session harvest timeoutで成果物は空だった。再送せず、PR #30 exact head `d93abf8`から隔離branch `codex/ai-native-an8-backup-restore-core`を作り、CodexがAN8-Cを実装した。
- macOS / Windows共通のversion付きcanonical JSON schema、package全version / lifecycle / permission / data digest、native file dialog、default-No承認、stale preview拒否、commit後runtime / data readback、失敗時の復元前snapshot rollbackを追加した。OAuth、credential、Capability audit / receipt、Codex workspace、外部pathは対象外である。
- macOS warnings-as-errors build、Pocket App workspace backup回帰、Capability、Broker、Pocket Surface、Timer、Panel layout 128件、Voice foundation、共通contract `15 schema / 71 fixture`、Windows Settings JavaScript、`git diff --check`が成功した。
- 初回Windows CIがC# collection expressionの型互換エラー6件を検出したため、実装commit `d00de9b`で明示型へ修正した。Draft PR [#31](https://github.com/shotaro311/hover-pocket/pull/31)で、Windows [32662630254](https://github.com/shotaro311/hover-pocket/actions/runs/32662630254)、macOS [32662630273](https://github.com/shotaro311/hover-pocket/actions/runs/32662630273)、3 OS contract / byte比較 [32662630305](https://github.com/shotaro311/hover-pocket/actions/runs/32662630305)、Router [32662629078](https://github.com/shotaro311/hover-pocket/actions/runs/32662629078)を含む全7 checkが成功し、進捗同期後のdocs-only headでも再成功した。PRは`Draft / MERGEABLE / CLEAN`、review / comment / unresolved thread 0件、remote parity `0 / 0`である。詳細: `progress/2026-08/2026-08-24_hover-pocket-ai-native-an8-workspace-backup-restore.md`。

## 2026-08-24 AI-native Core GA旧AI直結経路の除去

- `codex/ai-native-an8-windows-signing-pipeline` head `3448eda`からstack branch `codex/ai-native-core-ga-legacy-path-removal`を分離し、UI非表示だけで残っていたmacOSの`AICommandStore -> CalendarPocketTool(approved: Bool)`と、Windowsの`AiLaneController -> CalendarStore`を製品sourceから除去した。Voice / Text / Native UI / PocketSurfaceの実行正本はCapability Registry / Brokerだけに限定する。
- Windowsの既存`--verify ailane`は互換名を維持しつつ、旧`aiLane` state、`ailane.submit / approve / reject` bridge route、旧AI Providerがすべて存在しないことを検証するnegative verifierへ置換した。共通Voice contractも旧実装ファイルの再混入を拒否する。
- macOS warnings-as-errors build、Panel layout 128件、Capability 20 handler、Broker 21 descriptor / 20 handler、Pocket App / Surface / Voice / Timer、Pocket contract `14 schema / 69 fixture`、Voice contract、Windows JavaScript構文、`git diff --check`が成功した。Draft PR [#30](https://github.com/shotaro311/hover-pocket/pull/30)のcode head `1874daa`で、Windows [32659682483](https://github.com/shotaro311/hover-pocket/actions/runs/32659682483)はRelease build、旧AI lane不在、Voice、Broker、rendered UIを含め全成功し、macOS [32659682571](https://github.com/shotaro311/hover-pocket/actions/runs/32659682571)もwarnings-as-errors buildと全AI-native verifierに成功した。
- Core GA全体は未完了である。残りはAN8-C backup / export / restore正式回収、両OSproduction Voiceと実音声E2E、VoiceからPocket App生成・導入する実Codex confinement E2E、Windows正式署名済み配布とrollback、stack PRの人手mergeである。AN6 / AN7は計画どおりCore GAを塞がない。詳細: `progress/2026-08/2026-08-24_hover-pocket-ai-native-core-ga-legacy-removal.md`。

## 2026-08-24 AI-native AN8 Windows正式署名生成経路

- 現行stack head `c8366b0`から公開release readback [32657994406](https://github.com/shotaro311/hover-pocket/actions/runs/32657994406)をbeta modeで実行し、macOS signature / notarization / Gatekeeper / Sparkleと、Windows 0.2.7 Setup / Portable / full package identityを再確認した。3 artifactを別経路で取得し、report hashも固定した。
- Windows公開版は引き続き未署名betaで、repository variable `WINDOWS_SIGNER_CERT_SHA256`とActions secretは未登録である。formal Authenticodeは未完了のままbeta identityと分離した。
- `codex/ai-native-an8-windows-signing-pipeline`で、Windows certificate store選択、HTTPS RFC 3161 timestamp、Velopack `--signParams`、pack後のSetup / Portable / full package 3点署名readbackを追加した。全検証成功後だけmanifestを`signed-timestamped-verified`にし、betaへの署名引数混在、不正fingerprint、HTTP / credential入りtimestamp URLは停止する。既存publish / release outputの余剰payload混入を防ぐため、空でないdirectory、file、reparse pointも削除・上書きせず停止する。
- exact stack head `b95ef168`からmacOS release transition run [32664697767](https://github.com/shotaro311/hover-pocket/actions/runs/32664697767)を実行し、`v0.1.0-161 -> v0.1.0-168`のinstall、upgrade、rollback、uninstall、reinstallとuser data保持が成功した。artifact receiptのSHA-256は`7d72c722...d4080ea`である。Windows実行と未署名beta許可は無効のまま維持した。
- 同じexact stack headから公開release監視run [32664908332](https://github.com/shotaro311/hover-pocket/actions/runs/32664908332)を実行し、macOS 6 asset / Sparkle / Developer ID / stapled notarization / Gatekeeperと、Windows `win-v0.2.7`の8 asset / Setup / Portable / full package identityを再確認した。3 reportのSHA-256は以前のrunと同一だった。Windowsは未署名のためformal Authenticodeだけ未完了である。
- 現行stack binaryでBroker retention、Pocket App capability migration / health / workspace backup、Pocket Surfaceを再実行し、すべて成功した。共通contract 15 schema / 71 fixtureは2回のreportがbyte一致した。横断証拠: `progress/2026-08/2026-08-24_hover-pocket-ai-native-an8-operations-readback.md`。
- Python release readback 19件、py_compile、shell構文、YAML、JavaScript、`git diff --check`が成功した。Draft PR [#29](https://github.com/shotaro311/hover-pocket/pull/29)のcode head `397b52f`で、Windows [32658702169](https://github.com/shotaro311/hover-pocket/actions/runs/32658702169)はRelease build warning 0 / error 0、署名contract、Capabilities / Broker / Pocket Surface / Voice / Updater / rendered UIを含め全成功した。release readbackのpush / PR両runもdeterministic testsとPowerShell contractが成功した。PRは`Draft / MERGEABLE / CLEAN`、remote parity `0 / 0`である。詳細: `progress/2026-08/2026-08-24_hover-pocket-ai-native-an8-windows-signing.md`。

## 2026-08-24 AI-native AN8 Pocket App健全性・復帰耐性

- `codex/ai-native-an8-compatibility-migration` head `707ecb3`からstack branch `codex/ai-native-an8-app-health`を作り、Host-ownedのPocket App健全性メタデータをmacOS / Windowsへ追加した。最終利用、起動成功、連続起動失敗をローカルだけに保存し、30日以上未使用のAppはSettingsで無効化を提案する。自動無効化は行わない。
- 生成パネルの表示・選択・Host操作を実利用として記録し、5分間はdisk writeを抑制する。3回連続の起動失敗または破損メタデータは要確認、無効Appは無効化済みと表示する。破損・symlinkはfail-safeで提案を出さない。
- macOS / Windowsのsystem transitionはVoice復帰に加えて、enabled Pocket Appの再activation、Registry / Surface readback、Settings health再読込を行う。64回の復帰反復、512回の利用記録、30日判定、破損・symlink、atomic temporary cleanupを決定論的verifierへ固定した。
- macOS warnings-as-errors build、Pocket App package / lifecycle / generation / migration / health、Voice foundation、Panel layout 128件、共有contract `14 schema / 69 fixture`、report 2回byte一致、Windows Settings JavaScript構文、`git diff --check`が成功した。このMacには.NET SDKがないためWindows C#とrendered SettingsはDraft PR CIを受入gateにする。
- Draft PR [#28](https://github.com/shotaro311/hover-pocket/pull/28)のcode head `3b12a8a`でWindows [32657261437](https://github.com/shotaro311/hover-pocket/actions/runs/32657261437)、macOS [32657261433](https://github.com/shotaro311/hover-pocket/actions/runs/32657261433)、Router [32657261441](https://github.com/shotaro311/hover-pocket/actions/runs/32657261441)が成功した。WindowsはRelease build警告0・エラー0、Health / runtime activation、Settings、rendered WebView UIまで成功した。PRは`Draft / MERGEABLE / CLEAN`、review / comment 0件、remote parity `0 / 0`である。
- dangling symlinkを記録なしと誤認しないhardeningを`1854d72`へ追加し、Windows [32657525511](https://github.com/shotaro311/hover-pocket/actions/runs/32657525511)、macOS [32657525510](https://github.com/shotaro311/hover-pocket/actions/runs/32657525510)、Router [32657524602](https://github.com/shotaro311/hover-pocket/actions/runs/32657524602)が再成功した。
- AN8-C Pro backup / export / restore正本runは`monitoring / pending / unclaimed`であり、未claim成果物を先読みしていない。詳細: `progress/2026-08/2026-08-24_hover-pocket-ai-native-an8-app-health.md`。

## 2026-08-24 AI-native AN8 Capability互換・移行

- `codex/ai-native-an8-retention-governance` head `65694b6`からstack branch `codex/ai-native-an8-compatibility-migration`を作り、Capabilityの`active / deprecated / removed`、version基準の廃止猶予、明示置換、循環禁止をmacOS / Windows / 共有contractへ追加した。現行built-in catalogは空なので既存Capabilityは変化しない。
- Pocket App migratorはinstalled sourceを直接変更せず、新app versionのmanifest / Workflow / Surface referenceだけを置換し、state schema bytesとuser data storeを保持する。Settingsの「互換更新を準備」から既存preview、tests、permission / grant差分、明示承認、immutable install、readbackを通す。
- macOS warnings-as-errors buildとToday Focusの実package縦断が成功した。承認前の1.0.0維持、承認後の1.0.1、旧版snapshot保持、issue解消をreadbackした。共有contractは`14 schema / 69 fixture`全一致、report 2回byte一致、Windows Settings JavaScript構文と`git diff --check`も成功した。
- このMacには.NET SDKがないためWindowsはDraft PR CIを必須gateにする。AN8-C Pro backup / export / restore runは正式delivery待ちで、未claim成果物を先読みしていない。詳細: `progress/2026-08/2026-08-24_hover-pocket-ai-native-an8-compatibility-migration.md`。
- Draft PR [#27](https://github.com/shotaro311/hover-pocket/pull/27)の修正後head `66de848`でWindows、macOS、3 OS contract / compare、Routerの全7 checkが成功した。初回Windows compileで検出したverifierのnamespace import漏れは`66de848`で修正済みである。

## 2026-08-24 AI-native AN8 Capability履歴保持・削除

- `codex/ai-native-an8-core-integration-candidate` head `a330099`からstack branch `codex/ai-native-an8-retention-governance`を作り、macOS / WindowsへCapability監査ログとreceiptの`7日 / 30日 / 90日 / 無期限`保持、既定90日、Settings専用の確認付き全削除を実装した。
- 完了receipt内容を削除してもplan / argument / capability digestとcompleted stateの墓標を残し、同じidempotency key / plan IDは`unknown`で停止する。audit fileはstrict filename regular fileだけを対象とし、malformed / symlink / reparseをfail closedにする。
- macOS warnings-as-errors build、Broker retention / migration / symlink回帰、Capability、Pocket App、Pocket Surface、Voice、Panel layout 128件、Timer、13 schema / 66 fixture、Windows Settings JavaScript構文が成功した。Draft PR [#26](https://github.com/shotaro311/hover-pocket/pull/26)のcode head `cd3b974`でWindows [32653742569](https://github.com/shotaro311/hover-pocket/actions/runs/32653742569)、macOS [32653742576](https://github.com/shotaro311/hover-pocket/actions/runs/32653742576)、3 OS contract / compare [32653742551](https://github.com/shotaro311/hover-pocket/actions/runs/32653742551)、Router [32653742728](https://github.com/shotaro311/hover-pocket/actions/runs/32653742728)が成功した。
- PR #26は`Draft / MERGEABLE / CLEAN`、remote parity `0 / 0`である。mainへ自動mergeせず、Core Integration Candidateへのstack順とexact diffを人手gateに残す。
- AN8-C Pro backup / export / restore runは正式delivery待ちであり、成果物を先読み・再送していない。詳細: `progress/2026-08/2026-08-24_hover-pocket-ai-native-an8-retention-governance.md`。

## 2026-08-24 AI-native Core Integration Candidate

- 分岐していたAN5-C + AN3 Voice / Calendar / Timer stack、Controls / approval presentation再統合、AN8 release transition / readbackを通常mergeだけで`codex/ai-native-an8-core-integration-candidate`へ集約した。統合候補headは`4e297b7`で、各exact headのancestryをreadbackした。
- 競合は進捗正本とWindows Host composition / verifierに限定された。共有BrokerへVoice runtimeとControls、Sticky Notesに結び付くHost承認表示を同時接続し、21 descriptor / 20 handlerの構成を維持した。
- macOSでwarnings-as-errors build、13 schema / 66 fixture、Voice contract 42件、release readback unit 19件、Capability、Broker、Pocket App、Pocket Surface、Voice、Timer、Panel layout 128件、Windows JavaScript構文、shell構文、`git diff --check`が成功した。このMacには.NET SDKがないためWindowsはDraft PR CIを受入gateにする。
- Draft PR [#25](https://github.com/shotaro311/hover-pocket/pull/25)のhead `32b316f`で、Windows Release / native / rendered UI、macOS Capability、3 OS deterministic contract / cross-OS byte比較、release metadata、transition syntax、Routerを含む19 checkが成功し、失敗0、pending 0だった。公開署名成果物が必要な14 checkはPRでは意図どおりskipであり、未完了gateとして維持する。PRは`Draft / MERGEABLE / CLEAN`、remote parity `0 / 0`である。
- 正しいAN8-C Pro runは継続回収中であり、旧oversize runは成果物なしとして再利用しない。統合候補はDraft、人手merge gate、AI / Voice default-off、未署名Windows beta自動実行なしを維持する。詳細: `progress/2026-08/2026-08-24_hover-pocket-ai-native-core-integration-candidate.md`。

## 2026-08-23 AI-native AN3-B2 Final Safety Integration

- Draft PR #21の最終head `d29849a`をDraft PR #22へ通常mergeし、Calendar read / Timer startのCapability Broker経路へAN3-Aの最終表示秘匿とAN3-B1のtransport teardown直列化を伝播した。CoordinatorはRealtime cleanupとapp-server owner teardownを別Taskで保持し、crash、unexpected request、stale startup disconnect後のrestart / Voice再有効化 /終了が旧client破棄完了を待つ。Broker-only production approvalは`false`、Calendar grantはSettings-only既定OFF、`eventRef`非送信、Timer native approvalは維持した。
- ローカルではSwift warnings-as-errors build、署名付きmacOS app、Voice foundation、Panel layout 128件、Capability 14 handlers、Broker、Pocket Surface、Pocket App package / lifecycle / generation、Timer、Voice contract 42件、共通contract 13 schema / 60 fixture、Windows JavaScript構文、署名検証、`git diff --check`が成功した。
- 統合code head `f77ac87`でWindows [32644395509](https://github.com/shotaro311/hover-pocket/actions/runs/32644395509)、macOS [32644395539](https://github.com/shotaro311/hover-pocket/actions/runs/32644395539)、3OS contract / compare [32644395501](https://github.com/shotaro311/hover-pocket/actions/runs/32644395501)、Router [32644394230](https://github.com/shotaro311/hover-pocket/actions/runs/32644394230)の全7 checkが成功した。exact Security scan `824fcceb-34c9-4312-a42f-155f29aeffc3`は5 / 5 surface、coverage complete、finding 0、sealed completeである。
- docs-only headのmacOS CIで、timeoutがhandler開始前に勝つ安全な経路を`timeout_handler_cancelled`として誤検知するflaky verifierを検出した。本番Brokerを変えず、未開始または開始後取消の両経路で遅延結果を返さないことを検証する`caa13c1`へ修正した。Swift warnings-as-errors buildとBroker verifier 50回連続が成功し、Security scan `3c86f9cc-972d-4ba0-876a-2c3c0fc9fbe1`は1 / 1 surface、finding 0、sealed completeである。Windows [32645098065](https://github.com/shotaro311/hover-pocket/actions/runs/32645098065)、macOS [32645098030](https://github.com/shotaro311/hover-pocket/actions/runs/32645098030)、3OS contract / compare [32645098063](https://github.com/shotaro311/hover-pocket/actions/runs/32645098063)、Router [32645096808](https://github.com/shotaro311/hover-pocket/actions/runs/32645096808)の全7 checkが成功した。
- PR #22はDraft、`CLEAN / MERGEABLE`、remote parity `0 / 0`である。現行Codexには正のBroker-only tool allowlistがないためproduction Voiceは引き続きapp-server開始前にfail closedとし、Draftを維持する。PRのmerge自体は人手gateである。次はAN8 release-readback PR #23へ進み、配布後readbackと長期運用の残差を閉じる。詳細: `progress/2026-08/2026-08-23_hover-pocket-ai-native-an3-b2-integration.md`。

## 2026-08-23 AI-native AN3-B1 Final Safety Integration

- 検証済みPR #19 branchをDraft PR #21へ通常mergeし、Windowsのproduction microphone / WebRTC / Codex experimental Realtimeへ最終AN3-A安全境界を取り込んだ。CoordinatorはRealtime cleanup taskとtransport teardown taskを別々に保持し、crash / unexpected request / stale startup disconnectの旧client破棄完了後だけrestart、Voice再有効化、終了を進める。current-root、user / assistant role、relative path、Bearer、OpenAI key、JSON credential fieldの表示前境界も実Realtime transcriptへ接続した。
- 署名付きmacOS app、Voice verifier、Swift warnings-as-errors、42件Voice contract、Windows JavaScript構文、`git diff --check`は成功した。Windows [32643782605](https://github.com/shotaro311/hover-pocket/actions/runs/32643782605)、macOS [32643782572](https://github.com/shotaro311/hover-pocket/actions/runs/32643782572)、3OS contract [32643782576](https://github.com/shotaro311/hover-pocket/actions/runs/32643782576)、Router [32643781540](https://github.com/shotaro311/hover-pocket/actions/runs/32643781540)も成功した。
- exact integration Security scan `b09c2248-5609-4417-8202-59171f3bfdec`は4 / 4 surfaceをcoverage completeで閉じ、finding 0、sealed completeとなった。PR #21はDraft、review thread 0件、`CLEAN / MERGEABLE`、remote parity `0 / 0`である。実Windows端末のinstalled Codex / microphone / remote audio 1往復までDraftを維持し、次にPR #22へ通常mergeで伝播する。詳細: `progress/2026-08/2026-08-23_hover-pocket-ai-native-an3-b1-integration.md`。

## 2026-08-23 AI-native AN3-A Final Review Hardening

- PR #19のreview 2件をChatGPT Pro Orchestratorの`pro-primary` / builderへ委譲し、exact base `b506557`に対する`changes.patch`（13,796 bytes、SHA-256 `f7ee3235...f88d`）をbase / hash / 4 allowed pathまで検証して適用した。最終code head `90492d8`では、macOS / Windowsの可視VoiceテキストからPOSIX / Windows relative filesystem path、Bearer、裸のOpenAI key、JSON token / API key / client secretを表示前に秘匿する。Windowsのcrash / disconnect / active unexpected request / stale startup disconnect後restartは旧app-server clientの非同期teardown完了を待ち、追跡用completionをowner disposal開始前に登録する。
- macOS bundle build、署名検証、`--verify-voice-foundation`、Swift warnings-as-errors、Voice contract 42件、`git diff --check`は成功した。ローカルMacには.NET SDKがないためWindowsローカル検証は実行できず、Windows [32643299113](https://github.com/shotaro311/hover-pocket/actions/runs/32643299113)、macOS [32643299061](https://github.com/shotaro311/hover-pocket/actions/runs/32643299061)、3OS contract [32643299059](https://github.com/shotaro311/hover-pocket/actions/runs/32643299059)、Router [32643297550](https://github.com/shotaro311/hover-pocket/actions/runs/32643297550)を最終code受入根拠とした。
- 最終follow-up Security diff scan `e05df431-7f64-410e-87e4-c3a7bf9581a5`は`57052db...90492d8`の4 / 4 surfaceをcoverage completeで閉じ、finding 0、sealed completeとなった。先行するBearer、stale disconnect、teardown事前登録、裸のOpenAI key、JSON credential fieldのexact scanもすべてfinding 0である。PR #19はreview thread 66件中未解決0件、Ready、`CLEAN / MERGEABLE`、remote parity `0 / 0`である。docs-only headまで全CI成功後、PR #19の修正をPR #21、その後PR #21をPR #22へ通常mergeで伝播する。PRのmerge自体は人手gateを維持する。詳細: `progress/2026-08/2026-08-23_hover-pocket-ai-native-an3-a-review-followup.md`。

## 2026-08-21 AI-native AN3-B2 Voice Capability Security Remediation

- Draft PR #22のexact head `c9be7e4`を対象にしたSecurity scan `84b21db5-185f-4300-b813-3e150a52a11a`で、Codex RealtimeがHoverPocketのdynamic toolsに加えてambient shell / MCP / app / plugin / extensionを継承し得るHigh、Voice Calendar permissionをruntime自身が生成するMedium、Timer native approvalを並行要求で滞留させ得るLowの3件を確認した。
- Codex app-server 0.145.0の`dynamicTools`は既存toolへの追加であり、`read-only`、`approvalPolicy=never`、instructions、`environments=[]`だけではBroker限定を証明できない。実生成schemaにも正のtool policyがないことをreadbackした。このため、official positive allowlistとdelegated turn E2Eを確認済みのversionだけを明示承認するproduction gateを追加し、現行0.145.0はapp-server開始前に固定理由でfail closedにした。将来fieldが追加されてもsource側の承認定数を自動解除しない。
- Calendar予定名 / 時刻のCodex共有は、Google接続・Voice有効化・Microphoneとは別のSettings permissionとして既定OFF、native approval、永続化、取り消し可能にした。許可前はCalendar toolを定義へ含めず、runtime再確認でもProvider呼出しを0件にする。許可変更中のactive Voiceは停止して再構成する。
- TimerはHost-owned custom WPF dialogへexact title / durationを表示し、既定操作をキャンセルにした。native promptは同時1件、1分3件までとし、拒否もrate limitへ数える。session取消ではqueued / visible dialogを閉じ、未使用Broker approvalをrejectし、停止後のtool resultをapp-serverへ返さない。
- ローカルではSwift warnings-as-errors build、macOS Voice foundation、Panel layout 128件、Capability 14 handler、Broker、Pocket Surface、Pocket App package / lifecycle / generation、Timer、Voice contract 42件、共通contract 13 schema / 60 fixture、Settings generation、Windows JavaScript syntax、`git diff --check`が成功した。このMacには.NETがないため、Windows Release build、Voice / Settings / rendered WebView /既存Provider verifierはpush後CIを最終gateとする。
- 主要修正head `9705fe0`のSecurity scan `7e463a78-a2b0-4305-849e-f1418c495949`は15 / 15件、compile-only head `057d090`の増分scan `ef74ba38-38cd-4df9-8fc7-a813566d1dac`は1 / 1件を完全確認し、いずれもreportable finding 0件でsealed completeとなった。
- 本番解禁前の防御強化として、Codexへ返すCalendar結果からProvider内部`eventRef`を除去した。Voice有効化とCalendar grant変更を同じHost semaphoreで直列化し、Calendar権限取消は設定保存より先にactive Voice tool処理を非取消で停止する。Voice contractとnative verifierへ識別子非送信、直列化、revoke-before-saveを固定した。
- 最終source head `8e8a064`の増分Security scan `c5d44635-05a9-4081-9236-65937fbb289e`は5 / 5件、coverage complete、reportable finding 0件でsealed completeとなった。Windows [32406234638](https://github.com/shotaro311/hover-pocket/actions/runs/32406234638)、macOS [32406234704](https://github.com/shotaro311/hover-pocket/actions/runs/32406234704)、3OS contract / compare [32406234731](https://github.com/shotaro311/hover-pocket/actions/runs/32406234731)、PR Router [32406231112](https://github.com/shotaro311/hover-pocket/actions/runs/32406231112)が成功した。PR #22はDraft、`MERGEABLE / CLEAN`、remote head一致、未解決review thread・review・commentはいずれも0件である。
- PR #21最終head `97099ea`を通常mergeし、実WebRTC / Codex Realtime / root-scoped transcriptとCalendar read / Timer startのCapability Broker経路を同じCoordinatorへ統合した。競合はHost compositionとCoordinator停止処理の2ファイルだけで、Broker-backed tool、Settings-only Calendar grant、Timer native approval、tool取消、`Stopping`表示、非取消のdisable teardownをすべて維持した。
- 統合head `b197f3a`のexact Security scan `95c5ee8a-8105-4bcf-97f7-d3bd3f10f02e`は16 / 16 review item、coverage complete、reportable finding 0件でsealed completeとなった。Windows [32419442331](https://github.com/shotaro311/hover-pocket/actions/runs/32419442331)、macOS [32419442358](https://github.com/shotaro311/hover-pocket/actions/runs/32419442358)、3OS contract / compare [32419442324](https://github.com/shotaro311/hover-pocket/actions/runs/32419442324)、PR Router [32419439979](https://github.com/shotaro311/hover-pocket/actions/runs/32419439979)は全7 check成功。未解決review thread 0件、`CLEAN / MERGEABLE`、remote parity `0 / 0`をreadbackした。
- 現行Codex 0.145.0ではpositive Broker-only tool policyがないためapp-server開始前に停止し、実Codex Voice E2Eは実行しない。次はCore Integration Gateの残差をlive監査し、公式positive allowlistまたはBrokerだけを公開する専用最小runtimeの採否を確定する。詳細: `progress/2026-08/2026-08-21_hover-pocket-ai-native-an3-b2-security.md`。

## 2026-08-21 AI-native AN3-B1 Windows Voice Runtime

- AN3-A PR #19 head `b34c1fc`から隔離worktree / branchを作り、Windowsの明示microphone click → exact-origin permission → WebRTC offer / answer → Codex experimental Realtime → remote audio / transcript → mute / stopをdefault-offで接続した。AN3-B1のroot threadはread-only / approval never / tools禁止で、Capability Broker / MCPへは未接続である。
- installed Codexは絶対path / SHA-256、experimental schema、platform、account、voice一覧を検証する。app-serverとschema probeはkill-on-close Job Objectへ所属し、SDPは262,144 bytes上限とroot thread / connection generationで束縛する。SettingsへVoice state / SDPを渡さず、raw audio / SDP / transcriptを監査やdiskへ保存しない。
- 初回Security scan `2ab97a76-4999-41f5-9413-04f00df8fdf7`で、getUserMedia成功後のWebRTC構築失敗と、明示終了時のapp-server応答待ちによりlocal microphone停止が遅れる2件を再現した。取得直後のstreamを必ずcleanup対象へ置き、終了操作はnative停止より先にlocal track / peer / audioを破棄するよう修正した。exact-code回帰は両経路の即時停止を確認した。
- 修正後のexact working-tree Security scan `878927ec-12f6-49ea-a571-ed47182f1692`は14 / 14 review itemを完了し、reportable finding 0件でsealed completeとなった。外部Codex CLIの初回trust anchorとProcess.StartからJob assignmentまでのWindows raceは、Windows実機 / 製品方針で確定するfollow-upとして残す。
- ローカルではVoice contract 42件、Windows JS syntax、macOS warnings-as-errors build、Voice foundation、Panel layout 128件、Capability 14 handler、Broker、Pocket Surface、Pocket App、Timer、共通contract 13 schema / 60 fixture、`git diff --check`が成功した。fake app-serverとrendered fake WebRTC回帰を追加済みである。このMacには`dotnet`がないためWindows Release / native / rendered UIはPR CI、実Codex / microphone / WebRTC 1往復はWindows実機を最終gateとする。詳細: `progress/2026-08/2026-08-21_hover-pocket-ai-native-an3-b1.md`。
- Draft PR [#21](https://github.com/shotaro311/hover-pocket/pull/21)をPR #19へstackした。初回Windows CIでJob Object情報classの定数名とstruct名が衝突するcompile errorを検出し、`aa25244`で意味を変えず定数名を修正した。修正後headではWindows [32390802586](https://github.com/shotaro311/hover-pocket/actions/runs/32390802586)、macOS [32390802558](https://github.com/shotaro311/hover-pocket/actions/runs/32390802558)、3OS contract [32390802562](https://github.com/shotaro311/hover-pocket/actions/runs/32390802562)、PR Router [32390800203](https://github.com/shotaro311/hover-pocket/actions/runs/32390800203)がすべて成功した。WindowsはRelease build、Voiceのaccount / voice / Realtime / SDP / stop回帰、Settings、rendered WebView UI、既存Provider回帰まで成功した。実Windows Codex / microphone / remote audio 1往復を通すまでDraftを維持する。
- PR #19最終head `b506557`を通常mergeし、実Realtime transcriptへroot session ID、非損失identifier、path / secret / Unicode format control除去、重複event統合を接続した。統合Security scan `4c7e30aa-5797-4cda-bedf-739dd5093467`で外部`system` roleをHost表示に昇格できるlow finding 1件を検出し、`190ce80`で`user / assistant`だけを受理してpartial蓄積前に拒否し、UI fallbackも非権威化した。remediation scan `d8751ccf-e635-4747-9ad0-56d1b2b83539`は4 / 4 review、finding 0、sealed completeである。
- 最終実装head `190ce80`のWindows [32418050929](https://github.com/shotaro311/hover-pocket/actions/runs/32418050929)、macOS [32418050661](https://github.com/shotaro311/hover-pocket/actions/runs/32418050661)、3OS contract / byte比較 [32418050662](https://github.com/shotaro311/hover-pocket/actions/runs/32418050662)、PR Router [32418047807](https://github.com/shotaro311/hover-pocket/actions/runs/32418047807)は全7 check成功。未解決review thread 0件、`CLEAN / MERGEABLE`、remote parity `0 / 0`をreadbackした。

## 2026-08-21 AI-native AN3-A Review Follow-up

- PR #19の実装head `fd61652`で、macOS / WindowsのVoice停止中表示、終了時transition drain、system recovery取消直列化、未知transcript role拒否、非損失ID検証、可視テキストのpath / secret / Unicode format control除去、互換性状態のwire値、root単位のtranscript分離を完成させた。SwiftのJSON復号でcustom initializerを迂回したevent / sessionもruntime境界で再sanitizationし、同一event IDのinterim / finalは1件へ統合してfinalからinterimへ戻さない。
- Windows [32416504434](https://github.com/shotaro311/hover-pocket/actions/runs/32416504434)はRelease build、Settings、Voice、rendered WebViewまで成功した。macOS [32416504417](https://github.com/shotaro311/hover-pocket/actions/runs/32416504417)、3OS contract / byte比較 [32416504404](https://github.com/shotaro311/hover-pocket/actions/runs/32416504404)、PR Router [32416501502](https://github.com/shotaro311/hover-pocket/actions/runs/32416501502)も成功した。PRは`CLEAN / MERGEABLE`、remote parity `0 / 0`、未解決review thread 0件である。
- 追加Security scan `b520fb75-bb1d-4bb8-bd4b-6c14d04b434b`（7 / 7）、`c90ca20e-099c-4c0d-ae80-8d1a6d59fea4`（6 / 6）、`166c9616-3ea4-405a-ac6c-a3778e21b15a`（5 / 5）はcoverage complete、finding 0でsealed completeとなった。これ以前のremediation scan 3件もfinding 0である。未完了はPR #21 / #22への通常mergeと各headのCI / review、AN8 release-readback修正である。詳細: `progress/2026-08/2026-08-21_hover-pocket-ai-native-an3-a-review-followup.md`。

## 2026-08-20 AI-native AN3-A Voice Lane Foundation

- 最終source head `7ce9a68`でWindows [32378916573](https://github.com/shotaro311/hover-pocket/actions/runs/32378916573)、macOS [32378916499](https://github.com/shotaro311/hover-pocket/actions/runs/32378916499)、3OS contract / byte比較 [32378916471](https://github.com/shotaro311/hover-pocket/actions/runs/32378916471)、PR Router [32378945838](https://github.com/shotaro311/hover-pocket/actions/runs/32378945838)がすべて成功した。PR #19は未解決review thread 0件、`CLEAN / MERGEABLE`、remote parity `0 / 0`である。PR #18も最終head `2d8b89c`で全check成功、未解決thread 0件、`CLEAN / MERGEABLE`であり、両PRとも人手merge待ちである。
- 追加Codex review 6件を修正した。Windows app-server受信loopはfail-closed handler登録後にだけ開始し、client生成前から待機する想定外requestもReadyへ昇格させない。Voice UIはwire値`waiting_for_approval` / `waiting_for_user`を両言語へ変換し、未知error codeより互換性理由を優先表示する。WindowsのON / OFF変更を直列化し、macOSは切り離した旧adapter停止と音声終了 / mute commandをruntime所有Taskとして順序どおり完了させ、設定変更・復旧・shutdownが待つ。PR #18の最新head `2d8b89c`もmerge済みである。統合後のmacOS warnings-as-errors build、Voice、Broker、Pocket App 18 negative、Voice contract 42件、共通contract 13 schema / 60 fixture、Windows JavaScript構文、`git diff --check`は成功し、Windows C# buildとPR CIを最終gateとする。
- PR [#19](https://github.com/shotaro311/hover-pocket/pull/19)の最終source head `77af78f`で、追加Codex review 4件を修正した。Windowsは起動途中candidateをVoice OFF前に取消・破棄し、app-server teardownの非同期処理をWPF dispatcherへ戻さず、切断とReady昇格の競合を同一lock内で判定する。macOSはVoice Laneのstatus、placeholder、session、button、accessibility文言をAppLanguageの日本語 / 英語へ統一した。
- 最終headのWindows [32372769351](https://github.com/shotaro311/hover-pocket/actions/runs/32372769351)、macOS [32372769330](https://github.com/shotaro311/hover-pocket/actions/runs/32372769330)、3OS contract / byte比較 [32372769256](https://github.com/shotaro311/hover-pocket/actions/runs/32372769256)、PR Router [32372766956](https://github.com/shotaro311/hover-pocket/actions/runs/32372766956)はすべて成功した。PRは`CLEAN`、remote head一致、未解決review thread 0件をreadbackした。
- exact差分の追加security reviewでは、権限拡張、Bridge越境、raw transcript / secret出力、生成Appの直接Provider Storeアクセス、path境界の後退は見つからなかった。今回の追加差分はprocess / startup cleanup、atomic promotion、表示localizationに限定される。ChatGPT Pro Orchestrator delivery `return-1624b849f10726e95b63d0eecb8feaf6`は最終受入後に`processed`へmark-doneした。
- AN5-Cの途中head `0c121f1`から隔離worktree `/Users/shotaro/code/share/hover-menu-preview-ai-native-an3a`、branch `codex/ai-native-an3-voice-foundation`を作り、AN3を実音声より前の安全なfoundationへ分割した。実装後、AN5-C最新head `eb08eba`の2コミットを競合なく取り込み、Pocket App入力検証を欠落させないstacked branchへ更新した。
- macOS / Windowsへ、全Provider共通のHost-owned最下段Voice Lane、default-off、Compact / Expanded、明示toggle、root / child / descendant session card、memory-only transcript、bounded redaction、fail-closed server request、schema / account / capability gate、bounded restart stateを追加した。Compactは視覚タイトルを持たず、ExpandedはProvider領域を変えずパネル外枠だけを下へ伸ばす。
- macOSの全パネル非表示経路を同じdetach / mute境界へ集約した。WindowsはVoice transcript / session stateをPanel surfaceだけへ返し、Settings WebViewへ渡さない。app-server clientは初期化失敗・取消・transport crashでもownerを破棄し、受信JSONLは改行前に1 MiB上限を強制する。deterministic回帰を追加した。
- ChatGPT Pro Orchestratorはrun `20260820-170946-an5-c-exact-head-0c121f1pr-6voicean3-aoshost-owned-voice-lane-foundationdefault-offcompact-expandedroot-scoped-cardslifecycle-state-machinedeterministic-testschanges-patch`のbuilderとして使用した。返却receiptを検証後、Codexが不足修正、安全境界、検証を補完し、ローカル / CI受入完了後にmark-doneした。
- macOSでSwift warnings-as-errors build、Voice foundation、Panel layout 128件、Capability 14 handler、Broker、Pocket Surface、Pocket App package / lifecycle / generation、Timer、共通contract 13 schema / 60 fixture、Voice geometry / scope 42件、Windows JS syntax、Settings generation target、`git diff --check`が成功した。開発bundleはApple Development署名の`codesign --verify --deep --strict`に合格し、`SUFeedURL`を持たない。
- AN3-Aではproduction microphone、WebRTC、実Codex Realtime、Broker tool execution、MCP公開を有効化しない。PR CIとreview gateは完了した。残りはPR #18を先に人手でmergeした後のPR #19 merge、両OS実機UI、AN3-Bの実音声接続である。詳細: `progress/2026-08/2026-08-20_hover-pocket-ai-native-an3-a.md`。

## 2026-08-16 AI-native AN5-C Runtime / Surface Activation

- PR #18の追加reviewで、同じworkflow inputへ異なる選択肢集合を持つ複数Pickerを束縛するとmacOS / Windowsの実行可否が分岐する問題を確認した。package導入時に同一bindingのPicker domain完全一致を両OS runtimeと共通contract verifierで必須にし、相反packageをnegative回帰へ追加した。durationPickerはschemaどおり`$input`専用であることも意味検証へ明示した。ローカルのmacOS warnings-as-errors build、Pocket App 18 negative、共通contract 13 schema / 60 fixture、Windows renderer構文、`git diff --check`は成功し、Windows C# buildとPR CIを最終gateとする。
- PR [#18](https://github.com/shotaro311/hover-pocket/pull/18)のhead `f968bc0`では、Windows [32367934055](https://github.com/shotaro311/hover-pocket/actions/runs/32367934055)、macOS [32367934146](https://github.com/shotaro311/hover-pocket/actions/runs/32367934146)、3OS contract / byte比較 [32367934240](https://github.com/shotaro311/hover-pocket/actions/runs/32367934240)を含む全checkが成功した。その後の追加review修正は新しいCIをgateとする。mergeと両OS実機readbackは未実施である。
- 最終head `0c121f1`への追加Codex reviewで、複数Surface間の入力束縛をpackage全体で合算していたP2を検出した。ボタンから到達するworkflowごとに、同じSurface内の`$input` / `$state`束縛だけで全宣言inputを解決できることをmacOS / Windows runtimeと共通contract verifierで検証する。表示されない別Surfaceだけが不足inputを束縛するpackageを両OSのnegative回帰へ追加し、commit `54ff41e`へ反映した。ローカルのmacOS warnings-as-errors build、Pocket App 18 negative、Pocket Surface 15 negative、共通contract 13 schema / 60 fixture、`git diff --check`は成功した。PRではWindows [32348665332](https://github.com/shotaro311/hover-pocket/actions/runs/32348665332)、macOS [32348665277](https://github.com/shotaro311/hover-pocket/actions/runs/32348665277)、3OS contract / byte比較 [32348665365](https://github.com/shotaro311/hover-pocket/actions/runs/32348665365)、PR Router [32348663509](https://github.com/shotaro311/hover-pocket/actions/runs/32348663509)を含む全11 checkが成功した。review thread解決と最終remote readbackを残す。
- source head `454a2d0`までの最終Codex reviewを完了し、重大な追加指摘なし、未解決thread 0件をreadbackした。Windows [32346140249](https://github.com/shotaro311/hover-pocket/actions/runs/32346140249)、macOS [32346140248](https://github.com/shotaro311/hover-pocket/actions/runs/32346140248)、3OS contract / byte比較 [32346140258](https://github.com/shotaro311/hover-pocket/actions/runs/32346140258)、PR Router [32346138524](https://github.com/shotaro311/hover-pocket/actions/runs/32346138524)はすべて成功した。PR #18は`MERGEABLE`である。
- 最終review追随として、Windows生成Surfaceの更新前state保存を全controlへ統合し、失敗値を次回flushまで保持する。更新中はoperation ID単位のleaseで元・差替え後rendererをinertにし、重複操作を個別完了する。install / update / rollback / disable / remove / AI-native OFF / defaults resetは保存失敗時に中止し、成功・失敗の完了時に同じleaseの全rendererを復帰する。採用されなかったruntime activation candidateはreceipt不一致、復元不一致、commit前失敗、構築途中例外の全経路でlease無効化とRuntimeHandle破棄を行う。
- 2026-08-20再開時に残っていた3件を修正した。生成Surfaceのstate束縛controlは型付きHost state storeへ保存して再生成後も復元する。durable workflow開始後の取消は、未実行stepをfailed receiptへ確定し、既成功Timerを非取消経路でrollbackしてworkflowを完了保存する。Windowsの生成Provider設定はdisabled中のdurable managed package IDを保持し、remove後だけorder / visibility / preferred / last-selectedから除去する。
- 最終head reviewで追加検出した2件も修正した。入力宣言0件でliteralだけを使う生成workflowをWindowsで実行可能にし、macOS / Windowsの`Apps`直下に`.DS_Store`や無関係directoryがあっても正常Appの管理snapshotと復元を継続する。両OS回帰を追加し、macOSローカル検証は成功した。Windows rendered WebViewは修正push後のCIをgateとする。
- 最終security reviewで検出した生成App stateのpath差替え境界も両OSで閉じた。macOSは固定directory descriptorから`openat` / `renameat`で相対読み書きし、WindowsはrootとApp directoryをreparse拒否・置換不可handleで固定する。他App directoryへのsymlink / junction差替えをfail closedにし、macOSの生成Providerはpreserve-only remove後にorder / hidden / preferred / last-selected設定も削除する。macOSの全関連verifyは成功し、Windows buildと回帰は修正push後のCIをgateとする。
- source head `4489791`のWindows [32333436230](https://github.com/shotaro311/hover-pocket/actions/runs/32333436230)、macOS [32333436235](https://github.com/shotaro311/hover-pocket/actions/runs/32333436235)、Ubuntu / macOS / Windows contractとbyte比較 [32333436242](https://github.com/shotaro311/hover-pocket/actions/runs/32333436242)、PR Router [32333435108](https://github.com/shotaro311/hover-pocket/actions/runs/32333435108)はすべて成功した。exact Security diff scan `e030446e-9c8f-401d-9d44-1b2cc996d943`は51 / 51 review itemを完了し、reportable finding 0件でsealed completeとなった。
- 上記headへの最終Codex reviewで、生成Providerを再度開いても同じSurface modelを再利用してqueryを更新できない点と、macOSで同名の`$state`更新が`$input`へ複製される点を検出した。Surface表示ごとにfresh modelを生成し、activation解除時は生存中modelをすべて無効化する。`$input`と`$state`は独立namespaceのままworkflow準備時にだけ解決し、再表示と同名binding分離の回帰を追加した。
- source head `7816771`の再reviewでWindowsの3件を追加修正した。runtime activation失敗後も生成Provider routeの`state.changed`を発行し、開いているPanelから失効Surfaceを除く。Surface control、state schema、workflow宣言inputの型を両OS package load時に照合して、state fallbackを含む不整合packageを導入前に拒否する。state束縛text fieldは180ms debounceで保存し、Provider切替時は未保存値をdisposeから即時flushする。
- source head `1c8b93f`で、Windows [32331372164](https://github.com/shotaro311/hover-pocket/actions/runs/32331372164)、macOS [32331372103](https://github.com/shotaro311/hover-pocket/actions/runs/32331372103)、Ubuntu / macOS / Windows contractとbyte比較 [32331372312](https://github.com/shotaro311/hover-pocket/actions/runs/32331372312)、PR Router [32331370130](https://github.com/shotaro311/hover-pocket/actions/runs/32331370130)がすべて成功した。WindowsはRelease build、Settings、Timer、rendered WebView UIを含む全verifyが成功した。
- PR #18の全review threadへ修正根拠を返信し、未解決threadを0件にした。progress同期後のexact Security diff scan、最終CI / mergeability / remote parity readback、両OS実機gateを残す。詳細: `progress/2026-08/2026-08-20_hover-pocket-ai-native-an5-c-resume.md`。
- PR #17はmerge commit `a35b0ea8c224809ad4ff1bf1dc466882fc70169b`でmainへ統合し、merge後のWindows、macOS、3OS contract CIも成功した。最新`origin/main`から隔離worktree `/Users/shotaro/code/share/hover-menu-preview-ai-native-an5c`、branch `codex/ai-native-an5-runtime-activation`を作成し、ahead / behind `0 / 0`、cleanをreadbackした。
- AN5-Cは、検証済みactive packageをapp ID単位の`PocketSurfaceRegistry` / execution-runtime registryへ反映し、install / update / enable / disable / preserve-only remove / rollback / restart restoration後にapp ID、version、package digest、effective permission grantがLifecycle receiptと描画・実行側で一致した場合だけ成功にする。組み込みToday Focusと生成Appは別entryとし、複数生成Appを共存させる。
- ChatGPT Pro Orchestratorへexact base `a35b0ea`、GitHub read-only、GPT-5.6 Sol / Pro、builder、patch artifactとして実装と両OS回帰を委譲した。run: `20260816-074324-hoverpocket-an5-c-runtime-activation-registryos`。Codexはartifactのbase / hash / path検証、適用、ローカル検証、security review、Git / PR / mergeを担当する。実Codex生成activationは引き続きfail closedとする。
- 適用前baselineとして、Swift warnings-as-errors build、Pocket App package / lifecycle / generation、Capability 14 handler、Broker、Today Focus、Pocket Surface、Timer、共通contract、`git diff --check`が成功した。`./script/build_and_run.sh --build-only`でmacOS app bundleを作成し、Apple Development署名の`codesign --verify --deep --strict`も成功した。開発buildは`SPARKLE_FEED_URL`を明示しない限り`SUFeedURL`を持たない設計であり、feed、notarization、配布署名はAN8の正式成果物で検証する。
- Pro返却はdelivery ID / state hashをclaimしてreceiptを検証したが、適用可能なpatch contractを満たさなかった。1回のrepair上限後はSkillのisolated-recovery手順へ切り替え、mainを変更せず専用worktree内でCodexがAN5-Cを復元した。返却は再適用せずmark-done済みである。
- 両OSへapp ID keyed runtime / Surface Registry、receiptとapp ID / version / digest / effective grantの一致、複数App分離、disable / remove / rollback、restart restoration、activation失敗時のdurable disabled fallbackを実装した。生成App用のglobal WebView bridgeは公開せず、実Codex生成もfail closedのままである。
- security reviewで検出したstale runtime競合を持ち越さず、macOSはactivation leaseが実行Taskを取消し、BrokerとTimer writeが取消を再確認するようにした。Windowsはlease CancellationTokenをBridgeのtokenへ連結し、Brokerのqueue / step / handlerへ伝播する。disable / remove / default-off後にqueue済み実行がmaterial writeへ進まない回帰を追加した。
- 初回実装commit `63fc75b`をPR [#18](https://github.com/shotaro311/hover-pocket/pull/18)へpushし、Windows Release [31917292784](https://github.com/shotaro311/hover-pocket/actions/runs/31917292784)、macOS [31917292788](https://github.com/shotaro311/hover-pocket/actions/runs/31917292788)、3OS contract / compare [31917454979](https://github.com/shotaro311/hover-pocket/actions/runs/31917454979)が成功した。reviewで、WindowsのAI-native OFF時に生成App runtimeを解除していない点と、起動時復元失敗をdurable disabledへ戻していない点を検出した。
- review修正では、WindowsのAI-native OFF / defaults resetで全activation leaseとSurfaceを即時解除し、両OSの起動時復元失敗をLifecycle Manager経由でdisabledへ保存・再読込確認する。shutdownと復元失敗永続化のdeterministic回帰を両OSへ追加し、Macのwarnings-as-errors build、Pocket App、Capability、Broker、Surface、Timer、共通contract、bundle build、Apple Development署名検証が再成功した。旧scan `d40de7c5-0469-4f95-985b-d97b1a30c08e`は初回差分の証拠であり、review修正後のexact差分は再scanを完了条件とする。
- exact range `a35b0ea...8c0e2ee`のscan `9eb0f0ad-8926-4f80-b1f8-7b215fb7f407`は22 / 22 fileを確認し、Windowsで組み込みToday Focusの実行中取消がOFFへ連動しないlow finding 1件と、生成Registryのactivation / Shutdown競合を検出した。組み込みruntimeとdirect Today FocusへHost所有leaseを接続し、OFF / reset / disposeでcancelする。生成Registryはactivation、復元、OFF、disposeを同じlockとenabled stateで直列化する。実行中handler取消、後続Sticky writeなし、activation競合後のentry 0件、再有効化後の新規transition成功をdeterministic回帰へ追加した。
- 未完了は上記remediationのWindows CI、修正後exact Security scan、push、macOS / 3OS contract CI再確認、review thread解決、merge後readback、両OS実機での生成Surface / runtime activation readback、実Codex confinement、Voiceから生成・導入するCore Integration E2Eである。詳細: `progress/2026-08/2026-08-16_hover-pocket-ai-native-an5-c.md`。

## 2026-08-24 AI-native Core Capability Reintegration

- current `main` exact `a35b0ea`をbaseに、隔離worktree `/Users/shotaro/code/share/hover-menu-preview-ai-native-core-reintegration`、branch `codex/ai-native-core-capability-reintegration`で、競合中PR #13のHost-owned destructive approval presentationとPR #15のControls Capabilityを再統合した。既存PRのユーザー変更は戻していない。
- macOS / Windows共通でControls 6 CapabilityをRegistry / Broker / OS adapterへ接続し、明示mute set、mute保持volume set、対象displayだけのfresh brightness readback、boundedかつ制御文字除去済みmedia metadataを実装した。WindowsのCapability media経路はdirect UIのtimeout fallbackを使わず、providerが返すcommand confirmation / errorを保持する。
- Windows DDC/CIでは、write後read失敗時に楽観更新値を成功readbackへ転用しない。`fresh.Error`があれば`WriteVerified=false`とし、deterministic verifierへ回帰を追加した。macOS外部display音量も、通常UIは従来の記憶値fallbackを維持する一方、Capability readbackでは実DDC/CoreAudio観測がなければfail closedにした。
- exact working-tree Security scan `8d09288e-c2a3-4c21-988d-1c96ca07ca71`は変更source 30 / 30をreviewし、sealed complete、reportable finding 0件となった。DDC false readbackは実在したが現行は同一ユーザーのlocal manual UIだけでself-onlyのためsecurity policy上ignore。実装安全gateとして上記修正を適用した。Sticky delete target-version binding、完全なcross-platform media causal identity、custom WebView bridge分離はgeneric Voice / MCP / generated UI公開前の未完了gateとして残す。
- ローカルMacでSwift warnings-as-errors build、Capability 20 handler、Broker 21 descriptor / 20 handler、Pocket Surface、Pocket App package / lifecycle / generation、共通contract 13 schema / 64 fixtureの2回成功、`git diff --check`をreadbackした。Windows .NET SDKはこのMacにないため、Windows build / Controls / Capability / Broker verifierはPR CIを必須gateとする。
- Draft PR [#24](https://github.com/shotaro311/hover-pocket/pull/24)のimplementation head `5a1369c`で、Windows、macOS、Ubuntu / macOS / Windows contract、2件のcross-OS compare、PR Routerを含む11 / 11 checkが成功し、`MERGEABLE / CLEAN`をreadbackした。PRはDraftのまま保持し、自動mergeしていない。
- ChatGPT Pro OrchestratorへAN8-C backup / export / restore / data-version readbackのexact base `2d8b89c`・両OSchanges patchを委譲済み。run `20260824-000623-hoverpocket-an8-cpocket-app-workspacebackup-export-restoredata-version-readbackmacoswindowschanges-patch`は自動回収待ちで、返却時はdelivery ID / state hash claim後だけ適用する。
- 次はPR #24のhuman reviewを受け、同時にAN8-C返却を隔離worktreeで検証する。Windows unsigned betaは明示承認なしに実行しない。詳細: `progress/2026-08/2026-08-24_hover-pocket-ai-native-core-capability-reintegration.md`。

## 2026-08-15 AI-native Controls Capability

- exact `main` `2cd51b9`から隔離worktree `/Users/shotaro/code/share/hover-menu-preview-ai-native-core-expansion`、branch `codex/ai-native-core-capability-expansion`を作成し、Built-in Capability ExpansionのControls単位を実装した。
- macOS / WindowsのRegistryとProvider adapterへ`controls.availability.get@1`、`controls.volume.get@1`、`controls.volume.set@1`、`controls.mute.set@1`、`controls.brightness.set@1`、`controls.media.command@1`を追加した。readは`controls.read`、writeは`controls.write`、writeはidempotency key、Broker承認、実OS状態readbackを必須にし、出力はvolume / mute、bounded display ID、safe title / sourceだけへ限定した。
- 監査で、再生位置の自然な進行だけでnext / previous成功と誤認できる問題と、macOSのvolume setが承認されていないmute解除も行う問題を検出して修正した。track readbackはtitleの変化を要求し、volume setはmute状態を保持する。外部DDCで保持できない場合は、音を出さずfail closedにする。
- ローカルMacでSwift warnings-as-errors build、Capability 20 handler、Broker 21 descriptor / 20 handler、Controlsのnegative readback、Media、Timer、Clipboard、Pocket Surface、Pocket App、Panel layout、12 schema / 63 fixtureの2回の決定論的contract report、全Windows JavaScript syntax、`git diff --check`が成功した。Windows .NET SDKはこのMacにないため、Windows Release build / verifierはPR CIを必須gateとする。
- exact working-treeのCodex Security diff scan `27dc0225-9797-4d2f-b8eb-0eb111210182`は変更source 15 / 15を確認し、sealed complete、reportable finding 0件となった。2件は現行のdefault-offかつControls adapter未公開では攻撃経路なしとしてrejectedだが、将来Voice / Pocket App / MCPへ公開する前の必須修正として実装へ反映済みである。詳細: `progress/2026-08/2026-08-15_hover-pocket-ai-native-controls-capability.md`。

## 2026-08-23 AI-native AN8-B Release Transition Gate

- PR [#23](https://github.com/shotaro311/hover-pocket/pull/23)へ、公開済み旧版と新版のinstall、upgrade、明示rollback、再upgrade、uninstall、reinstall、user data sentinel保持を確認するOS別手動workflowを追加した。通常push / PRではBash / PowerShell構文とWindowsのrelease snapshot差し替え拒否contractだけを実行し、公開release codeはOS別の明示inputがある場合だけ使い捨てrunnerで実行する。
- workflow_dispatchの自由入力tagは`run:`へ直接展開せずenv経由へ固定した。macOS / Windowsとも開始時にtag、draft / prerelease状態、全assetの名前・size・GitHub SHA-256・download URLをsnapshot化し、合格証跡の直前に再取得して完全一致しない場合は失敗する。
- Windows 0.2.x未署名betaは`execute_windows_release_code`と`allow_unsigned_beta`の二重opt-inを必須にした。正式署名版はSetupだけの署名確認では受理せず、full package内アプリを独立した正式署名readback snapshotへ結合できるまで失敗側に閉じた。
- Macローカルで公開版`v0.1.0-161`→`v0.1.0-168`の全遷移、codesign、Apple公証staple、Gatekeeper、Sparkle Ed25519署名、user data保持、開始 / 終了release snapshot一致が成功した。一時結果は恒久削除せずTrashへ移動した。
- 手動workflow [32646526001](https://github.com/shotaro311/hover-pocket/actions/runs/32646526001)はexact head `35077c9be0109089701cc55788e7aa72aad8e2fc`でmacOS実transition、macOS / Windows contractが成功し、Windows実行は意図どおりskipした。artifact `macos-release-transition` ID `9495013952`を別経路downloadし、全遷移=`verified`、`userDataPreserved=true`を確認した。
- 初回手動run [32646384473](https://github.com/shotaro311/hover-pocket/actions/runs/32646384473)は`actions/upload-artifact`の短縮SHAをGitHubが拒否してsetup段階で失敗した。GitHub APIが解決した完全commit SHAへ両jobを修正し、上記成功runで証跡uploadまで再確認した。
- 初回Security scan `b4dec798-00d3-4a79-8b1e-a3019b036dea`はrelease途中差し替えで古いpassed receiptが残り得るCWE-367をlow 1件として検出した。snapshot再取得で修正し、full remediation scan `cb82d38f-2c6f-4cdc-b069-34cbb261bab4`は6領域、final action-pin scan `3ec61eaa-b29d-4b70-8e27-629bd51b599b`は2領域をcoverage complete、finding 0件でsealed completeにした。
- PRはDraft、`MERGEABLE / CLEAN`を維持し、人間merge gateを変更していない。残る実行gateはWindows未署名betaの明示承認と、将来の正式署名Windows releaseでの再検証である。日常端末のSparkle / Velopack UI、実データmigration、sleep-wake、長時間soakは後続gateに残す。詳細: `progress/2026-08/2026-08-23_hover-pocket-ai-native-an8-transition.md`。

## 2026-08-21 AI-native AN8-A Codex Review Follow-up

- PR [#20](https://github.com/shotaro311/hover-pocket/pull/20)のCodex review 2件をGmailとGitHubの両方で照合した。指摘どおり、formal Windows gateはSetup / PortableだけでVelopack full update package内アプリを検証しておらず、macOS readbackはversioned release側の手動install ZIPを実downloadしていなかった。
- Windows formal gateはfeedが指定する唯一のfull `.nupkg`を再取得し、checksum / feed size / SHA-1 / SHA-256を照合してから安全に展開する。Setup、Portable内アプリ、full package内アプリの3点すべてでtimestamped Authenticodeを確認し、署名者一致を必須にした。
- macOSはversioned Sparkle ZIP、`macos-latest`手動ZIP、versioned release手動ZIPの3コピーを別々に再取得し、GitHub metadataと相互のsize / SHA-256一致を確認する。versioned手動ZIPの改変を拒否するunit testを追加した。
- 追加reviewで、`auto`がWindows prereleaseを選び得る点と、Windows releaseがGitHub汎用Latestを置換しても検出できない点を確認した。両言語の自動選択からdraft / prereleaseを除外し、汎用Latestはrelease選択に使わずmacOS versioned releaseのままであることだけを検査する。
- unit 12件、Python compile、workflow YAML parse、`git diff --check`が成功した。公開beta readbackも再実行し、macOS `v0.1.0-168`の3コピーとSparkle署名、Windows `win-v0.2.7`の全asset / feed / checksum、汎用Latest=`v0.1.0-168`が一致した。ローカルMacにPowerShellがないため、formal scriptのparseとWindows側確認はPR CIを最終gateとする。詳細: `progress/2026-08/2026-08-21_hover-pocket-ai-native-an8-review-followup.md`。
- source head `77dc721`でPR CIのrelease metadata、PowerShell構文、Windows verifier、PR Routerがすべて成功した。exact security diff scan `11fdb6d9-9e92-45d1-9ffe-c5f3df1c7fbc`はcoverage complete、reportable finding 0件でsealed completeとなった。4件のreviewへ検証根拠を返信し、未解決thread 0件をreadbackした。
- 追加reviewで、formal実行時にmetadata jobとAuthenticode jobが`auto`を別々に解決する競合を確認した。Windows tagは専用jobで1回だけ確定し、両jobへ同じoutputを渡す。`actions/upload-artifact`はGitHubが要求する完全commit SHAへ修正し、手動run [32421539868](https://github.com/shotaro311/hover-pocket/actions/runs/32421539868)で`auto`が`win-v0.2.7`へ固定され、公開readbackが成功した。
- Gmailで届いた追加reviewは、共通Python verifierが`Type=Full`と整合したhash / sizeだけを確認し、Setup executableを偽のFull targetとして受理できる点だった。`abae752`でfeed targetをexact `HoverPocketWin-<version>-full.nupkg`へ固定し、Setupを指すnegative testを追加した。
- さらに、Pythonの失敗が`tee`のexit 0で隠れるworkflow経路と、任意prefixのSetup / Portable名を受理する経路を確認した。`b850daf`で明示`bash`のpipefailを有効にし、Python / PowerShellともcanonical `HoverPocketWin-win-Setup.exe` / `HoverPocketWin-win-Portable.zip`へ固定した。unit 16件、Python compile、workflow YAML parse、PRのrelease metadata / PowerShell構文 / Windows verifier / Routerが成功した。
- incremental security scan `efc4bd2f-f212-46e7-8a30-d6afea320c87`、`9e9fb119-5642-451d-baf5-0c3933ab344e`、`25c81e42-a975-4749-9c7a-992218c1f256`はいずれもcoverage complete、reportable finding 0件、sealed complete。最終手動run [32422064352](https://github.com/shotaro311/hover-pocket/actions/runs/32422064352)のartifactも`status=passed`。合計8件のreviewへ検証根拠を返信して解決し、未解決thread 0件をreadbackした。
- 最後の追加reviewで、同じtagのassetを`--clobber`中に並行2 jobが別世代として検証できる競合を確認した。`aff7ab6`でpublished jobが実downloadした全8 assetのname / size / SHA-256 snapshotをartifactへ保存し、formal jobは同じsnapshotの全assetを再download/hash、署名前後にGitHub metadataも再照合する。unit 17件とincremental security scan `0de1ebe2-4950-49ea-be21-f884bb4bd5f1`は成功。beta run [32422720262](https://github.com/shotaro311/hover-pocket/actions/runs/32422720262)で8 asset snapshotをreadbackし、formal run [32422832966](https://github.com/shotaro311/hover-pocket/actions/runs/32422832966)は現行未署名manifestを意図どおり拒否した。合計9件のreviewを解決し、未解決thread 0件をreadbackした。
- 2026-08-23の追加reviewを`7cb1764`、`b957a54`、`b34d576`、`1e6a8c8`、`3e8b79f`で修正した。macOSは3 ZIP、stable / versioned appcast、checksumの6資産をimmutable snapshotへ固定し、最終metadata再取得まで同一性を確認する。配布bundleの`SUFeedURL`、`SUPublicEDKey`、`TeamIdentifier=N7VVPW44ZA`もexact検証する。Windows betaの初期修正ではSetup SFX末尾とfull `.nupkg`全byte、Portable `current/`の506ファイルとfull package `lib/app/`を照合した。Setupの末尾推測は後続`da75587`で正規bundle header解析へ置換した。workflow path filterもmacOS native verifier変更時に起動する。
- 途中run [32627459690](https://github.com/shotaro311/hover-pocket/actions/runs/32627459690)、[32627869765](https://github.com/shotaro311/hover-pocket/actions/runs/32627869765)、[32628233979](https://github.com/shotaro311/hover-pocket/actions/runs/32628233979)でSFX展開とnuspec探索の実形式差を検出して修正し、[32628492824](https://github.com/shotaro311/hover-pocket/actions/runs/32628492824)でSetup payload検証まで成功した。最終run [32629166708](https://github.com/shotaro311/hover-pocket/actions/runs/32629166708)はexact head `3e8b79f217d2052a17b6acc101e320456ccb5d62`で全job成功した。
- 最終runの3 report artifactを新しい一時directoryへ別経路downloadした。macOSは6資産、3 ZIP / 2 appcastのbyte同一性、Sparkle公開鍵 / feed URL、Team ID、codesign / stapler / Gatekeeperを確認した。Windowsは`win-v0.2.7`のSetup全payloadとPortable 506ファイルのfull package同一性を確認した。unit 19件、Python compile、shell構文、YAML parse、`git diff --check`も成功した。security scan `1889e238-6153-4579-8ea6-d7801b6d2351`、`7291eb3a-5841-4176-942a-66f4ae39f02b`、`84906546-9cf0-472f-9e08-a33d5b3da72a`はすべてcoverage complete、reportable finding 0件、sealed completeである。詳細: `progress/2026-08/2026-08-23_hover-pocket-ai-native-an8-final-readback.md`。
- 追加review 2件を`da75587`で修正した。Setup payloadは末尾推測を撤回し、Velopack 1.2.0の固定marker直前にあるlittle-endian offset / lengthをstreaming KMPで一意に解決するため、AuthenticodeのPE証明書表をpackageと誤認しない。formalでは3成果物のSignerCertificate raw byte SHA-256が同一で、repository variable `WINDOWS_SIGNER_CERT_SHA256`の正規64桁値と一致することも必須にした。betaのIdentityOnlyは署名評価を行わず`publisherIdentity=not-evaluated`を返す。
- exact scan `f436ab83-bc71-4ab6-b104-d49738aeeb45`はrange `59cd53a...da75587`の5 / 5 fileを確認し、coverage complete、finding 0件、sealed complete。Windows native beta run [32638170997](https://github.com/shotaro311/hover-pocket/actions/runs/32638170997)はexact head `da75587759959f5760eedb9a59b153d5971fc786`で全job成功した。3 report artifactの別経路readbackでも、Setup / Portable payload、macOS 6資産、署名 / 公証 / Gatekeeper、beta publisher分離が一致した。
- 最終review 2件を`e2e6a4a`で修正した。appcastはnamespaceなし`rss` root、direct childの`channel` 1件、`item` 1件、`enclosure` 1件を順に必須化し、非RSS rootと複数channelを拒否する。GitHub汎用Latestは約270 MBの公開asset検証後に再取得してからmacOS releaseとの一致を判定する。unit 19件とexact scan `ce3db805-6663-48a6-aad0-c650efc9be0f`は成功。最終run [32638515063](https://github.com/shotaro311/hover-pocket/actions/runs/32638515063)はexact head `e2e6a4a4f7de80c9dd40578cf138e89a858aa5f3`で全job成功し、3 report artifactの別経路readbackでもmacOS 6資産、Windows 8資産、Setup / Portable payload、署名 / 公証 / Gatekeeper、beta publisher分離が一致した。
- PR #20のreview 14件へcommit / CI / artifact / scanの根拠を返信して解決し、fresh GraphQL readbackで未解決thread 0件を確認した。PRはReadyを維持し、人間mergeの境界を変更しない。

## 2026-08-20 AI-native AN8-A Public Release Readback

- 最新`origin/main`の`a35b0ea`から専用worktree `/Users/shotaro/code/share/hover-menu-preview-ai-native-an8-readback`、branch `codex/ai-native-an8-release-readback-main`を作成した。mainは`origin/main`と同一、cleanへ戻した。
- macOSとWindowsの公開channelをGitHubの汎用Latestで混同せず、`macos-latest` / versioned macOS releaseと最大semantic versionの`win-v...` releaseを別々にreadbackする検証器を追加した。
- macOSはappcast、versioned ZIP、手動インストールZIPを公開URLから再取得し、実測size / SHA-256、checksum、公開鍵によるSparkle Ed25519署名を照合する。Windowsは全公開assetを再取得し、実測size / SHA-256、checksum、feed内full packageのSHA-1を照合する。
- Windows正式版はmanifestの自己申告だけで完了にせず、Windows runnerで公開SetupとPortable内`HoverPocket.Shell.exe`の実Authenticode署名、タイムスタンプ、署名者一致を確認する別gateを追加した。週次は現行未署名betaを監視し、formalは手動実行に限定する。
- deterministic unit 10件、Python構文、YAML parse、`git diff --check`は成功した。公開中のmacOS `0.1.0 (168)`とWindows `0.2.7`を合計約270MB再取得したlive beta readbackも成功し、Windows formal gateは未署名manifestを理由にexit 1で正しく拒否した。
- このAN8-Aは公開asset / signature / feedの継続readback基盤である。AN8全体の完了には、Windows正式署名済みrelease、両OSのclean install / upgrade / downgrade / uninstall / reinstall、Host / Pocket App / data version rollback、migration、offline / sleep-wake / long-running soak、retention / backup / restoreの実機証拠が残る。詳細: `progress/2026-08/2026-08-20_hover-pocket-ai-native-an8-release-readback.md`。

## 2026-08-16 AI-native AN5-B Codex Pocket App Generation / Management UI

- AN5-A exact head `151043c`をbaseに、隔離worktree `/Users/shotaro/code/share/hover-menu-preview-ai-native-an5b`、branch `codex/ai-native-an5-generator-ui`でAN5-Bを実装した。自然言語要求、Host割当app ID / version / namespace、有限Capability catalogをrequest digestへ束ね、固定schemaのPocket App draftだけを受け取る。生成物はHost側でmaterialize、package再検証、declared test、preview、permission / effective grant差分へ進み、承認後だけAN5-Aのimmutable lifecycleへ渡す。
- macOS SettingsへSwiftUIの生成・preview・導入確認・管理UI、Windows Settings WebViewへ同等UIを追加した。install / update / disable / preserve-only remove / rollbackはHost保持proposalとネイティブ既定No承認へ結び、rendererからapproval binding値を受け取らない。WindowsのAI-native有効化もSettings surface限定かつネイティブ既定Noにし、Panelからの呼出しは`unknown_method`、OFF起動後のONではCodex / workspaceをhot-startしない。
- 実Codexは、read-only sandboxだけではユーザーのローカルファイル読取りを隔離できないためproductionでfail closedにした。macOSは`supportsConfidentialGeneration=false`、Windowsは`ResolveExecutable()=null`、両OSとも実Codex出力はactivation不可である。activation可能な生成adapterはdeterministic fixture専用で、Host pipeline全体の検証にだけ使う。
- reviewで、AN5-Bのlifecycle receiptと実際の`pocketAppExecutionRuntime` / Surface登録がまだ接続されていないことを確認した。現在はproduction generator自体がactivation不可なので利用者へ偽成功は到達しない。任意app IDの生成Appを組み込みToday Focusの単一slotへ直接差し替える修正は誤登録を生むため採用せず、app ID単位の`PocketSurfaceRegistry` / execution-runtime registryとactive version / digest / grant readbackをAN5-Cの必須gateにした。
- 保存先rootはdescriptor / handleでidentityを固定する。生成controllerの起動時にはpathnameベースの自動recoveryを実行せず、放置Stagingを勝手に削除しない回帰を両OSへ追加した。通常の明示lifecycle操作をdescriptor-relativeへ全面移行することと、Mac sandbox helper / Windows AppContainer等による実Codexのlocal-file confinementは次gateに残す。
- ChatGPT Pro Orchestratorは通常Pro `gpt-5.6-sol` target / builderとして使用した。follow-upはdelta patch `186896 bytes / c9de646b...`を申告したが、回収artifactは初回patch `71029 bytes / f3c81be...`のままで一致しなかった。1回のrepair上限後はSkill例外に従い、Codexが不足実装と修正を担当した。run: `20260816-024012-hoverpocket-an5-boscodexpocket-app-drafthostimmutableuireadbackpatch`。
- MacローカルでSwift warnings-as-errors build、Pocket App package / lifecycle / generation、Capability、Broker、Pocket Surface、Timer、Clipboard、Calculator、Panel layout 128件、共通contract 13 schema / 58 fixture、Windows Settings JavaScript syntax、`git diff --check`が成功した。PR [#17](https://github.com/shotaro311/hover-pocket/pull/17)はAN5-A merge commit `c8db98d`を取り込み、baseをmainへ変更した。最終source headは`63f5e9c`である。
- exact hardening range `0bc4051...736d207`のSecurity diff scan `8e5e2370-6361-4e35-a1fd-6fe835e7db85`と、package-scope cleanup range `736d207...cc95d61`のscan `695689dc-62ad-45ff-a733-62ce8389e1c1`はいずれもcoverage complete、reportable finding 0件でsealed completeとなった。
- 最終reviewの2件を`15d793b`で修正した。WindowsのSettings既定値リセットは既存generation controllerを先に無効化し、進行中処理をcancel、同じpackageのpending proposalをrejectし、以後のwrite routeを`GENERATION_DISABLED`で拒否する。macOS / Windowsのpackage再有効化は、enabled recordを書いた後のpackage readbackが失敗した場合、以前のdisabled recordを再書込み・再検証してから失敗を返す。両OS回帰を追加し、exact 6 fileのSecurity scan `5756c702-3d31-4da0-a285-c7a477a57fdc`はcoverage complete、reportable finding 0件、sealed completeとなった。
- 追加reviewの4件を`3744f69`、`9e8d4da`、`7f6fad6`で修正した。commit後に別Appの破損で全体refreshが失敗しても、操作対象を単独readbackしreceiptと一致した場合だけ成功を保持する。Windowsはupdate targetの明示解除、enable後のpackage実byte再検証とdisabled rollbackを追加した。別Appのdisable / enable / removeでは承認待ちproposalを保持し、phase判定を同じstate lock内で行う。両OSへ非干渉回帰を追加した。
- exact range `3744f69...7f6fad6`のSecurity scan `c68750f8-a73f-4491-812c-e0bf96c4b599`は関連境界6件を完全確認し、reportable finding 0件、sealed completeとなった。PR #17の最終headでWindows [31911734637](https://github.com/shotaro311/hover-pocket/actions/runs/31911734637)、macOS [31911734658](https://github.com/shotaro311/hover-pocket/actions/runs/31911734658)、3OS contract / compare [31911734659](https://github.com/shotaro311/hover-pocket/actions/runs/31911734659)、PR Router [31911733717](https://github.com/shotaro311/hover-pocket/actions/runs/31911733717)が成功し、未解決review thread 0、`MERGEABLE / CLEAN`をreadbackした。
- 最終追加reviewの2件を`63f5e9c`で修正した。更新対象なしの生成は同じ依頼文でも毎回Hostが新しいapp IDを割り当て、明示対象がある場合だけupdateする。管理一覧はApp単位で検証し、壊れたpackageを要修復として隔離するため、正常Appと管理UIを維持する。壊れたAppのupdate / enable / disableは拒否し、安全に扱える場合だけpreserve-only removeを提供する。exact range `b1efe58...63f5e9c`のSecurity scan `3117e462-c7c2-455c-ae94-02291a2c116e`は8 / 8件を完全確認し、reportable finding 0件、sealed completeとなった。Windows [31912271187](https://github.com/shotaro311/hover-pocket/actions/runs/31912271187)、macOS [31912271209](https://github.com/shotaro311/hover-pocket/actions/runs/31912271209)、3OS contract / compare [31912271135](https://github.com/shotaro311/hover-pocket/actions/runs/31912271135)、PR Router [31912270332](https://github.com/shotaro311/hover-pocket/actions/runs/31912270332)が成功した。
- 未完了gateは、AN5-Cのruntime / Surface activation readback、Windows実機でのSettings native approvalと管理UI、実Codex confinement、Voiceから生成依頼するCore Integration E2Eである。詳細: `progress/2026-08/2026-08-16_hover-pocket-ai-native-an5-b.md`。

## 2026-08-15 AI-native AN5-A Pocket App Lifecycle Foundation

- exact `main` `2cd51b9`から隔離worktree `/Users/shotaro/code/share/hover-menu-preview-ai-native-an5`、branch `codex/ai-native-an5-generator-install`でAN5-Aを実装した。ChatGPT Pro Orchestratorのgeneration 2返却はdelivery ID / state hash、receipt、base、allowed path、artifact hashを検証した後だけ適用し、Codexが安全境界と回帰検証を補完した。
- 両OSへ、untrusted draftをno-follow / stable identityでHost所有snapshotへ取り込む処理、package validate / declared tests / preview、permissionと実効Capability grant差分、exact single-use approval、immutable version install、update、disable、preserve-only remove、rollback、active version / digest readbackを追加した。`stableKey`は安全な有限grammarへ制限し、承認表示と実行値を同じ値へ固定した。
- mutableな`active.json`を権限の正本にせず、検証済みimmutable packageから現在の権限を復元する。rollback対象はversionとpackage digestの一致を必須にし、通常updateでのdowngradeを拒否する。64文字内の巨大な数値versionも任意長の数字列として比較し、59桁versionから`1.0.0`へのdowngrade回帰を両OS verifierへ追加した。
- removeはユーザーデータを保持する経路だけを実装した。Versionsをtombstoneへ移動し、removed stateのdurable write後だけcleanupする。途中失敗・再起動時はactive stateに応じて復元またはcleanupし、`dataDisposition=delete`はAN5-Aでは拒否する。承認期限切れ時のstaging / grant cleanup、複数manager間のWindows lifecycle直列化、起動ごとの全final snapshot再保護とreadbackも両OSの回帰検証へ固定した。
- macOSでSwift warnings-as-errors build、Pocket App lifecycle、Pocket Surface、Capability、Broker、Panel layout、Timer、Calculator、Clipboard、Weather、共通contract 12 schema / 58 fixtureの2回byte一致、`git diff --check`が成功した。公開Capability schemaも末尾改行を真の終端で拒否し、runtimeとの不一致をnegative fixtureへ固定した。PR [#16](https://github.com/shotaro311/hover-pocket/pull/16)のsource head `a9fb8ed`でWindows [31897975620](https://github.com/shotaro311/hover-pocket/actions/runs/31897975620)、macOS [31897975587](https://github.com/shotaro311/hover-pocket/actions/runs/31897975587)、3OS contract / cross-OS compare [31897975600](https://github.com/shotaro311/hover-pocket/actions/runs/31897975600)、PR Router [31897982011](https://github.com/shotaro311/hover-pocket/actions/runs/31897982011)が成功した。未解決review threadは0、remote parity `0 / 0`をreadbackした。PRは自動mergeしていない。
- 承認previewの実byte再検証、grantのrequest ID binding、remove recordのfile / directory durable sync、manager破棄時のstaging ownership解放、両OSのstable key true-end anchorとASCII制御文字拒否まで追加hardeningした。さらにmacOSのimmutable snapshotをactive record確定前に全file / directoryへdurable syncし、両OSのversion保存先をUTF-8 byteの可逆な16進keyへ変更してcase-insensitive filesystemの衝突を防いだ。同一rootの承認待ちsnapshotは複数manager合算で最大4件に制限し、5件目を既存proposalを壊さずfail closedにした。
- exact range `c949676...5f6a04f`のscan `114557d4-7318-42cd-b744-c7cdc392025c`と、承認待ち上限range `5f6a04f...a9fb8ed`のscan `28517aef-7d8b-45a4-80d7-a97c92fd3834`は各4 / 4 fileを完全レビューし、どちらもcoverage complete、reportable finding 0件でsealed completeとなった。既知の保存先root pathname TOCTOUはproduction接続前の別gateとして残す。
- 最終reviewで、起動後からrollback実行までに保存版fileの書込み属性が復元された場合、digest一致だけでactive化できる経路を検出した。`9dc6ac7`でmacOS / Windowsとも、承認後のactive record確定直前にdigest container全体を再保護し、属性、package digest、属性の順で再検証するよう修正した。両OS verifierはproposal作成後に対象fileを書込み可能へ戻し、rollback成功時に再びimmutable / read-onlyであることを確認する。
- 上記27行のexact working-tree差分はCodex Security scan `71bed277-674c-4551-8bf4-72e0abda759e`で4 / 4 surfaceを確認し、coverage complete、reportable finding 0件、sealed completeとなった。Macのwarnings-as-errors buildとPocket App lifecycle verifierは成功し、WindowsはPR CIを最終gateとする。
- PR #16は全CIとreview解決後、merge commit `c8db98d`でmainへ取り込んだ。AN5全体は未完了である。AN5-BのHost生成 / preview / 管理UIはPR #17で検証済みだが、AN5-C runtime activation readback、実Codex confinement、Voice生成E2Eが残る。初回実装: `progress/2026-08/2026-08-15_hover-pocket-ai-native-an5-a.md`。最終hardening: `progress/2026-08/2026-08-16_hover-pocket-ai-native-an5-a-hardening.md`。AN5-B: `progress/2026-08/2026-08-16_hover-pocket-ai-native-an5-b.md`。

## 2026-08-15 AI-native AN4 Pocket App DSL / Renderer

- exact `main` `da0d5b6`を取り込んだ隔離worktree `/Users/shotaro/code/share/hover-menu-preview-ai-native-an4`、branch `codex/ai-native-an4-dsl-renderer`でAN4を実装した。ChatGPT Pro Orchestratorの返却patchはdelivery ID / state hash、base、allowed path、artifact hashを検証した後だけ適用し、Codexが不足分と安全境界を補完した。
- `manifest.json`、intent、state schema、Surface、workflow、testsを閉じたpackageとして読み込み、unknown file / component / capability、path traversal、symlink / reparse、oversize、unbound input、scope逸脱を両OSでfail closedにした。package digestは全構成fileのpathとraw byte digestを順序付きで束ね、macOS / Windowsのgolden値 `sha256:e9c369e0b52620d95c14baa2e04070535a1f21020308090f0467eed8cf4f04df`へ一致させた。
- SwiftUIとWindows DOMの有限component renderer、Host所有state store、read query、workflow実行、approval、Broker、readback付きreceiptを接続した。Today Focusは宣言packageだけから描画し、Calendar read、Timer start、Sticky upsertを既存UIと同じCapability Registry / Brokerへ通す。title / bodyは承認前にcanonical化し、承認と実行を同じplan digestへ結び付け、成功表示は実Capability receiptとreadbackからHostが動的に生成する。
- ローカルMacでSwift warnings-as-errors build、Broker、Pocket App package、Pocket Surface、Panel layout、12 schema / 57 fixtureの共通contract、JavaScript syntax、`git diff --check`が成功した。PR [#14](https://github.com/shotaro311/hover-pocket/pull/14)のhead `5eb528f`でWindows、macOS、Ubuntu / macOS / Windows contract、cross-OS byte比較、PR Routerがすべて成功し、`MERGEABLE / CLEAN`をreadbackした。
- exact hardening range `341db0a...5eb528f`のCodex Security diff scan `d6d90a84-3a8e-4b34-882a-a03f0c3d0c09`は変更11 / 11 fileを確認し、reportable finding 0件でsealed completeとなった。4件は現行の固定内蔵packageから到達せず、AN5で生成package導入を開く時だけ成立する境界としてdeferredにした。
- AN5の必須gateは、両OSでHost所有のimmutable install snapshotへno-follow / stable identityで取り込み、検証byteと実行byteを同一にすること、`stableKey`を安全な有限grammarまたはHost所有canonical表示へ固定し、承認表示と実行値を完全一致させることである。これらを実装するまで外部生成packageをactivateしない。詳細: `progress/2026-08/2026-08-15_hover-pocket-ai-native-an4.md`。
- 最終head `b1cdd0d`の11 check成功、未解決review thread 0、Ready、`MERGEABLE / CLEAN`をreadbackしてPR #14をmergeした。merge commit `1a6565f`でmain / origin/mainは一致し、merge後のWindows [31884679828](https://github.com/shotaro311/hover-pocket/actions/runs/31884679828)、macOS [31884679826](https://github.com/shotaro311/hover-pocket/actions/runs/31884679826)、Pocket contracts [31884679824](https://github.com/shotaro311/hover-pocket/actions/runs/31884679824)もすべて成功した。

## 2026-08-15 AI-native Strong Approval Isolation

- Sticky Notes lifecycle統合後のexact `main` `56607cf`からbranch `codex/ai-native-strong-approval`を作成し、`strong_per_call` Capabilityを1計画1stepだけに限定した。状態確認などの低リスク操作と削除を同じ承認へ混在させるplanは、承認要求を作る前にmacOS / WindowsのBrokerが拒否し、実行時にも同じplanを再検証する。
- 共通contract verifierにも同じ規則とnegative fixtureを追加し、12 schema / 57 fixtureへ更新した。途中レビューでHost-native planだけPocket App scope検査を省く過度な一般化を検出したため撤回し、requested Capability、range、namespaceの既存検査を緩めずに`strong_per_call`を先に拒否する形へ固定した。
- ローカルではSwift warnings-as-errors build、Broker 15 descriptor / 14 handler・negative 11件、Capability、Timer、Clipboard、2回の決定論的contract report、`git diff --check`が成功した。単独の`sticky.note.delete@1`は既存どおり承認、実行、missing readbackまで成功し、複数step planだけを拒否する。
- 最終source range `56607cf...bcbf7b0`のCodex Security diff scan `c0238875-7481-4226-8a22-eccdb874226d`は変更source 5 / 5とfixture 2件を確認し、coverage complete、reportable finding 0件でsealed complete。旧head `67fee14`のscan `965505c2-53d2-4fd4-8b2e-59dcf8f40abd`で見つけたCI verifier限定のscope検査低下はproduction到達性なしとしてsuppressedし、後続`bcbf7b0`で撤回済みである。
- PR [#12](https://github.com/shotaro311/hover-pocket/pull/12)の最終head `0439757`で、Windows [31856271399](https://github.com/shotaro311/hover-pocket/actions/runs/31856271399)、macOS [31856271417](https://github.com/shotaro311/hover-pocket/actions/runs/31856271417)、Pocket contract [31856271438](https://github.com/shotaro311/hover-pocket/actions/runs/31856271438)、PR Router [31856275029](https://github.com/shotaro311/hover-pocket/actions/runs/31856275029)が成功し、3 OS contract reportもbyte一致した。review thread 0、`MERGEABLE / CLEAN`をreadbackしてmergeし、merge commit `005f174`のWindows [31856376397](https://github.com/shotaro311/hover-pocket/actions/runs/31856376397)、macOS [31856376384](https://github.com/shotaro311/hover-pocket/actions/runs/31856376384)、Pocket contract [31856376430](https://github.com/shotaro311/hover-pocket/actions/runs/31856376430)も成功した。進捗記録の追記後もmain / origin/mainは一致し、ahead / behind `0 / 0`となった。詳細: `progress/2026-08/2026-08-15_hover-pocket-ai-native-strong-approval.md`。

## 2026-08-15 AI-native Sticky Notes Lifecycle Capability

- Calculator統合後のexact `main` `8d7127f`から隔離branch `codex/ai-native-sticky-lifecycle`を作成し、Sticky Notesの状態確認、archive、deleteをmacOS / Windowsの共通Capabilityへ追加した。既存UIのStoreと同じ保存先を使い、Provider Viewや生成UIからStoreへ直接アクセスさせない。
- `sticky.note.status@1`は`sticky.read`、`sticky.note.archive@1`は`sticky.write`とBroker承認、`sticky.note.delete@1`は独立した`sticky.delete`と`strong_per_call`承認を要求する。archive/deleteはidempotency key、atomic save、保存失敗時memory rollback、状態再照会によるreadbackを必須にした。
- 共有Golden Registryへ未反映だったCalculator descriptorと今回の3 descriptorを追加し、runtimeは15 descriptor / 14 handler、共通契約は12 schema / 56 fixtureへ揃えた。macOSでwarnings-as-errors build、Capability、Broker、Timer、Clipboard、2回の決定論的contract report、`git diff --check`が成功した。Windowsはローカルに.NET SDKがないためPR CIを必須gateとする。
- exact source range `8d7127f...dd91448`のSecurity diff scan `9f03efcd-fbd3-4799-a5fd-c591a9ee1219`は変更source 12 / 12をレビューし、reportable finding 0、sealed complete。将来のVoice / Pocket App / MCPからdeleteを公開する前に、Host-ownedの対象メモ表示と`strong_per_call`固有制約を追加する項目はdeferredとして固定した。現時点のproduction経路はToday Focusのみでdeleteを公開も権限付与もしていない。詳細: `progress/2026-08/2026-08-15_hover-pocket-ai-native-sticky-lifecycle.md`。
- Draft PR [#11](https://github.com/shotaro311/hover-pocket/pull/11)のhead `696912b`で、Windows [31854456305](https://github.com/shotaro311/hover-pocket/actions/runs/31854456305)、macOS [31854456232](https://github.com/shotaro311/hover-pocket/actions/runs/31854456232)、Pocket contract [31854456221](https://github.com/shotaro311/hover-pocket/actions/runs/31854456221)、PR Router [31854456370](https://github.com/shotaro311/hover-pocket/actions/runs/31854456370)が成功した。3 OS contract reportはbyte一致し、review thread 0、`MERGEABLE / CLEAN`をreadbackした。
- 最終head `bda78d8`でもWindows [31854634564](https://github.com/shotaro311/hover-pocket/actions/runs/31854634564)、macOS [31854634576](https://github.com/shotaro311/hover-pocket/actions/runs/31854634576)、Pocket contract [31854634592](https://github.com/shotaro311/hover-pocket/actions/runs/31854634592)、PR Router [31854643283](https://github.com/shotaro311/hover-pocket/actions/runs/31854643283)が成功した。PR #11をmergeし、main / origin/mainはmerge commit `4640f5c`で一致、ahead / behind `0 / 0`をreadbackした。

## 2026-08-15 AI-native Built-in Capability Expansion

- AN2 merge後のexact `main` `014032d`から隔離worktreeとbranch `codex/ai-native-capability-expansion`を作成し、最初のExpansion単位としてCalculatorをpure local `calculator.expression.evaluate@1`へCapability化した。
- macOS / WindowsのRegistry、Broker、runtime composition、単体 / Broker verifierへ同じID、schema、制限、決定論的な結果形式を追加した。任意コード評価は使わず、式長、値数、桁数、演算子、overflow、除算ゼロをfail closedで制限する。
- macOSでSwift warnings-as-errors build、Capability 11 handler、Broker 12 descriptor / 11 handler、Calculator、Timer、Clipboard、Panel layout 112件、Media、Pocket contract 12 schema / 52 fixture、`git diff --check`が成功した。
- 最終head `ff7d642`のPR [#10](https://github.com/shotaro311/hover-pocket/pull/10)で、macOS [31853288589](https://github.com/shotaro311/hover-pocket/actions/runs/31853288589)、Windows [31853288565](https://github.com/shotaro311/hover-pocket/actions/runs/31853288565)、PR Router [31853287341](https://github.com/shotaro311/hover-pocket/actions/runs/31853287341)が成功し、review thread 0、`MERGEABLE / CLEAN`をreadbackしてmainへmergeした。main / origin/mainはmerge commit `e456222ae3d064ab3c1efbf73aea97fdb4a41fcc`で一致した。Security diff scan `1b18c190-d37b-450c-960f-c924f26ea9ae`は変更source 10 / 10、coverage complete、finding 0でsealed complete。既存Calculator UIのBroker移行と、Expansion trackの残りは後続単位である。詳細: `progress/2026-08/2026-08-15_hover-pocket-ai-native-capability-expansion.md`。

## 2026-08-15 AI-native AN2 Registry / Broker / Text Today Focus

- AN1 PR [#8](https://github.com/shotaro311/hover-pocket/pull/8)を全check成功、未解決review thread 0件、Ready、MERGEABLE / CLEANのreadback後にmergeした。`main` / `origin/main`はmerge commit `3dce5df07c2b3ed687feefd78b6e78b0753e9958`で一致する。
- exact mainからworktree `/Users/shotaro/code/share/hover-menu-preview-ai-native-an2`、branch `codex/ai-native-an2-registry-broker`を作成し、remote trackingを設定した。
- ChatGPT Pro OrchestratorのBuilder runは40分でtimeoutし、回収receiptは`completion_status=blocked`、`response.md`は空、`changes.patch`なしだった。delivery ID / state hashをbridgeでclaimし、重複適用を防ぐ`mark-done`まで完了した。同じ依頼は再送せず、Skillのblocked例外に従いCodexがAN2を再実装した。
- macOS / WindowsへRegistry 11 descriptor、Capability Broker、single-use approval、durable idempotency ledger、metadata-only audit、独立readback、Timer補償、Text Today Focus、既存Calendar UIのHost-owned承認入口、default-off compositionを実装した。最終実装headは`5d7cbe1ba6be44261c578ea3195d7fe5ccb03d45`で、remote branchと一致し、worktreeは進捗文書更新前までcleanだった。
- ローカルではSwift warnings-as-errors build、Broker、Capability 10 handler、Timer、Clipboard、Calculator、Panel layout 112件、Media、Pocket contract 12 schema / 52 fixture、`git diff --check`が成功した。Broker verifierは並行duplicate、timeout完了待ち、cancellation、rollback、ledger / audit persistence failure、approval binding、redactionを含む。
- exact headのGitHub ActionsはWindows [31819648677](https://github.com/shotaro311/hover-pocket/actions/runs/31819648677)、macOS [31819652540](https://github.com/shotaro311/hover-pocket/actions/runs/31819652540)、共通契約 [31819655023](https://github.com/shotaro311/hover-pocket/actions/runs/31819655023)がすべて成功した。
- remediation range `7c05e54...5d7cbe1`のCodex Security scan `d596e8a5-1d07-4f13-b9c9-2672f51fc36f`は8 / 8 fileを完全レビューし、coverage complete、finding 0件でsealed completeとなった。外部Google Calendar実mutationと、未接続のVoice / MCP / Connector / generated PocketSurface ingressは後続gateである。
- ChatGPT Pro Orchestratorの独立Critic run `20260815-013805-hoverpocket-an2headready-pr`は、通常Chat / GPT-5.6 Sol / Pro、GitHub read-only、外部操作なしで開始したが、Oracleが指定Project内のchat作成証拠を確定できず`blocked`となった。delivery ID / state hashのclaimは成功し、`response.md`は1 byte、`critic-review.md`とartifact manifestは存在しないことをreadbackして`mark-done`した。Pro verdictは得られていない。
- Pro blocked後、ローカル独立レビューの長文承認境界をexact headで再確認した。両OSとも承認表示、Timer title、Sticky bodyは同じ80 Unicode scalar以下のcanonical値を使い、100文字fixtureでexact equalityを検証済みなので追加修正は不要だった。
- 未完了gateは進捗文書の最終commit、Ready PR作成とPR headの全check / mergeability readbackである。詳細: `progress/2026-08/2026-08-14_hover-pocket-ai-native-an2-registry-broker.md`。

## 2026-08-14 AI-native AN1 Provider Capabilities

- AN0 PR [#7](https://github.com/shotaro311/hover-pocket/pull/7)を全必須check成功、Ready、MERGEABLEのreadback後にmergeし、`main`のmerge commit `6e248c8`から隔離worktree `hover-menu-preview-ai-native-an1`とbranch `codex/ai-native-an1-provider-capabilities`を作成した。
- macOS / Windowsへ共通ID・version・typed argumentsを持つProvider Capability handlerを追加した。実行可能な10 handlerはCalendar list / get / create、Timer start / get / pause / resume / stop、Sticky upsert / get。既存UIと同じStore instanceへ接続する一方、Voice / WebView / MCP / Pocket Appからの外部呼出し口はまだ接続していない。
- Calendar createはnull以外の明示calendarをfail closedで選択し、作成応答のevent IDとGET readbackを返す。終日予定はGoogleのdate-only値を保持し、requested timezoneのcivil dayでlist対象を選ぶ。DST、異なるoffset、multi-day、確認済みwrite後のUI cache refreshを補正した。Timer / Stickyはatomic persistence失敗時にmemory stateをrollbackし、Windows Timer stopは期限切れ後も一致するalertとsoundを停止する。全write handlerはidempotency keyを必須にしたが、durable replay ledgerはAN2のBroker責務として未接続である。
- 最終実装head `c3917ef`で`swift build`、`--verify-capabilities`（10 handlers）、Timer、Clipboard、Calculator、Panel layout 112件、Media、`git diff --check`が成功した。Pocket contractは12 schema / 52 fixtureが2回成功し、reportはbyte一致、SHA-256 `b11c7a6f...d0b0`。`--verify-google-calendar`はこのworktreeにOAuth client IDがなく未実行で、外部予定は作成・変更していない。
- GitHub Actions run [31795599989](https://github.com/shotaro311/hover-pocket/actions/runs/31795599989)でUbuntu / macOS / Windows contract verifierとcross-OS byte比較、run [31795600008](https://github.com/shotaro311/hover-pocket/actions/runs/31795600008)でWindows Release build / Capabilityを含む既存回帰、run [31795599988](https://github.com/shotaro311/hover-pocket/actions/runs/31795599988)でmacOS Swift 6 build / Capability / Timerが成功した。
- exact source range `6e248c8...c3917ef`のCodex Security scan `hoverpocket_an1_c3917ef_20260814T112020Z`は24 source fileとsupporting contracts / CIを完全レビューし、coverage complete、reportable finding 0件でsealed complete。approval binding、durable replay、sanitized receipt、audit enforcementはAN2の必須gateであり、それ以前は外部経路へ公開しない。
- Ready PR [#8](https://github.com/shotaro311/hover-pocket/pull/8)へ実装と検証を集約した。詳細: `progress/2026-08/2026-08-14_hover-pocket-ai-native-an1-provider-capabilities.md`。

## 2026-08-14 AI-native AN0 Contract Hardening

- PR #7の独立レビューで再現した12経路をfail closedへ修正した。`native_authority`実行、Pocket App版差し替え、self-claimed readback、unbound package source、scope escape、asset traversal、生成Surfaceのreceipt描画、audit raw ID、oversized plan / workflow payloadを拒否し、未知schema keyword / unresolved `$ref`もnegative fixtureへ固定した。
- Pocket App ID / version / manifest digestをplan、invocation、approval、receipt、auditへbindingし、successful receiptはHost-owned typed observation、再計算evidence digest、descriptor match field一致を必須にした。manifest全pathはsource byte digestへbindingし、scopeとaudit値をHost validatorで強制する。
- contract corpusは12 schema / 47 fixtureへ増え、全reject fixtureが本文digest、stable error code、exact error locationを持つ。監査ログも既知Invocation、descriptor、入力digest、Host-owned readback digestへbindingする。contract treeはLFへ固定する。CIは固定runner / Python / Node 24世代Action SHAを使い、Ubuntu / macOS / Windowsのreport artifactをbyte-for-byte比較する。
- ローカルでは47 / 47 fixture、2回report byte一致、JSON 66件の重複key拒否parse、`swift build`、Panel layout 112件、Clipboard、Timer、Calculator、`git diff --check`が成功した。exact commit range `190ee90...5e9097c`の最終Codex Security scan `85f50deb-45e1-40d2-8457-867c749f729b`は6 surfaceを完全レビューし、coverage complete、reportable finding 0件でsealed completeとなった。
- implementation head `5e9097c`のpush run [31759179183](https://github.com/shotaro311/hover-pocket/actions/runs/31759179183)とPR run [31759179663](https://github.com/shotaro311/hover-pocket/actions/runs/31759179663)で、Ubuntu / macOS / Windowsとcross-OS byte比較が成功した。以後は検証readbackの`progress/`記録だけを追加し、実装差分は変えていない。PR #7はReady、MERGEABLE。runtime source、Provider Registry、既存data format、requirements、PLAN1、承認画像は変更していない。詳細: `progress/2026-08/2026-08-14_hover-pocket-ai-native-an0-hardening.md`。

## 2026-08-13 AI-native AN0 Contracts and Verification

- 承認済み最終計画の最初の実装単位AN0として、`contracts/pocket/v1/`へ12個のversioned JSON Schema、31件のvalid / invalid / golden fixture、決定論的な標準Python verifierを追加した。macOS / Windowsのruntime source、Provider Registry、既存保存形式は変更していない。
- `CapabilityRegistry / Broker`、approval、readback付きreceipt、Voice Lane、Pocket App / Surface / Workflow、最小監査データをADRへ固定した。Voice Lane geometryはCompact 64、Expanded S / M / L / XLを190 / 220 / 250 / 280としてgolden fixture化した。
- ChatGPT Pro Orchestratorのbuilderへexact base `8b636cae...`を渡して`changes.patch`を生成させ、Codexがdownload版とrun取込版のSHA-256 `35369356...a174`一致、allowed path、`git apply --check`を確認して適用した。OracleのDevTools接続切断により自動回収表示が止まったが、同一会話から一度だけ手動harvestし、再送せずreceiptを復旧した。
- ローカルでcontract 12 schema / 31 fixture、2回のJSON report byte一致、JSON全44件parse、`swift build`、Calculator / Clipboard / Timer / Panel layout 112ケース、`git diff --check`が成功した。GitHub ActionsもUbuntu / macOS / Windowsのpush・PR両経路で成功した。
- Ready PR [#7](https://github.com/shotaro311/hover-pocket/pull/7)を作成した。Headは`6ef58f3732c91f0b44c21543b46cbc55619935f3`で、GitHub readbackはMERGEABLE。AN1以降のruntime handler実装は、この契約PRのreview / merge後に開始する。詳細: `progress/2026-08/2026-08-13_hover-pocket-ai-native-an0-contracts.md`。

## 2026-08-13 AI-native Final Implementation Plan

- 現行`main`、正本requirements、macOS / Windows双方のProvider・AI・Bridge・Store実装、Draft PR #6のVoice Lane branch、worktree、MulmoClaude 5資料、OpenAI公式資料を再監査し、ユーザー承認済みの最終実装プランを`docs/plan/20260813_PLAN1.md`へ確定した。
- 最終構造は、表示を`PocketSurface`、操作を`PocketCapability`へ分離し、`CapabilityRegistry`を単一正本、`CapabilityBroker`を唯一の実行入口とする。Voice、Text、既存UI、生成Pocket App、MCPは同じBrokerを通す。
- 最初の縦断候補はToday Focus Pocket。Calendar read、Timer start、Sticky upsert、write approval、実行後readbackを両OSで通し、別gateでCalendar createの実音声・承認・event ID readbackも確認する。
- Voice Lane UIはHost所有の全Provider共通最下段とし、Compactは視覚タイトルなし・短い波形・会話優先、ExpandedはProvider領域を潰さずパネル外枠だけを下方向へ伸ばす。左に現在会話、右に同一rootのcurrent / child session cardsを表示し、fullscreenと全履歴browserは採用しない。
- 承認済み画像を`docs/plan/assets/20260813-ai-native/voice-lane-compact.png`（1475×1067）と`voice-lane-expanded.png`（1254×1254）へ保存し、文章要件を正本、画像を視覚的受け入れ基準とした。
- `docs/requirement/requirements.md`へLegacy AI command laneとCodex Voice Laneを分離した要件、Shell geometry、共通Capability、UI / E2E条件を同期した。
- この項目は計画確定時点の記録。現在の実装状態は直上のAN0エントリを正とする。詳細: `progress/2026-08/2026-08-13_hover-pocket-ai-native-final-plan.md`。

## 2026-08-12 Cross-platform Multiple Stopwatches and Timer UI

- macOSとWindowsのストップウォッチを、名前・色・独立したpause / resume / stopを持つ最大4件の同時実行へ拡張した。カウントダウンも両OSで最大4件とし、別枠で扱う。
- Windows Timerを「実行中」の1列コンパクトリストと「新しく追加」のストップウォッチ / タイマー / ポモドーロ3カードへ再構成した。名前欄、左上アイコンの色メニュー、種類別アイコン、sound、時間編集、pinを維持している。
- macOSのSwift / 112 layout / 署名済みbundleと、WindowsのRelease cross-build / JavaScript / 600x430・520x372ブラウザ描画を検証した。GitHub ActionsのWindows runnerもRelease build、timer / ui-model / updater / WebView UIを含めて成功した。
- 共通source `fefc4c6`から、macOS Latest [`v0.1.0-168`](https://github.com/shotaro311/hover-pocket/releases/tag/v0.1.0-168)とWindows専用 [`win-v0.2.7`](https://github.com/shotaro311/hover-pocket/releases/tag/win-v0.2.7)を公開した。macOSはApple公証、署名、staple、Gatekeeper、appcast、公開ZIP、ローカル再インストールを確認し、Windowsは8 asset、checksum、manifest、専用feedを公開URLから再取得して一致を確認した。Windows公開後もGitHub LatestとmacOS appcastはmacOS build 168のまま維持した。詳細: `progress/2026-08/2026-08-12_hover-pocket-cross-platform-multiple-stopwatches.md`。
- 配布サイトをCloudflare Worker version `1522796a-4b37-4740-b926-196dd07ce836`へ更新した。2つの公開ドメインはWindows 0.2.7 Setupリンクを返し、HTML SHA-256がローカルと一致した。GitHub Pagesの同一更新runも成功した。

## 2026-08-12 macOS Timer Organized List UI

- macOS Timerを、上段の「実行中」1列リストと下段の「新しく追加」3カードへ再構成した。実行中はストップウォッチ1件とカウントダウン最大4件を、種類、設定名、時間、pause / resume、stopを揃えた高さ38ptの1行カードで表示する。
- ストップウォッチ、Timer、Pomodoroの追加カードを同じ高さで横並びにし、3種類すべてへ「名前を設定（任意）」と左上アイコンから開く4色メニューを追加した。色ドット列は廃止し、アイコンを`stopwatch.fill` / `hourglass` / `target`へ分けた。
- 旧drafts JSON互換、ストップウォッチの名前・色引き継ぎ、Timer 2件 + Pomodoro 2件の同時実行、3アイコン非重複、全4パネル幅、Small / Large / Extra Large描画、署名済み開発bundleの起動を検証した。詳細: `progress/2026-08/2026-08-12_hover-pocket-timer-organized-list-ui.md`。
- 公開release、appcast、Windows版は変更していない。

## 2026-08-12 macOS Latest Reinstall Readback

- `/Applications/HoverPocket.app`の旧`0.1.0 (155)`を終了し、アプリ本体だけをmacOSのゴミ箱へ退避して、GitHub Latest `v0.1.0-161`の公開手動インストールZIPから`0.1.0 (161)`を再インストールした。Application Support内の設定・保存データは削除していない。
- 公開ZIP SHA-256 `f4981150...b6b0801`のGitHub digest一致、展開後appとインストール先の実行ファイルSHA-256一致、Developer ID Application署名、公証staple、Gatekeeper `Notarized Developer ID`をreadbackした。
- 再インストール後に`/Applications/HoverPocket.app/Contents/MacOS/HoverPocket`の起動を確認した。詳細: `progress/2026-08/2026-08-12_hover-pocket-build-161-windows-0.2.6-release.md`。

## 2026-08-12 macOS Build 161 / Windows 0.2.6 Public Release

- 共通source commit `f0172f2`から、macOS build 161とWindows 0.2.6をOS別releaseへ公開した。macOSはGitHub Latest `v0.1.0-161`と`macos-latest` appcast、Windowsは`latest=false`の`win-v0.2.6`と`releases.win.json`を使用した。
- macOS build 161はDeveloper ID Application署名、hardened runtime、Apple公証`Accepted`、staple、Gatekeeper、公開ZIP展開後の再検証に合格した。公開ZIP SHA-256は`f4981150...b6b0801`、appcast SHA-256は`401e5a38...f04cab`で、build 161とversioned ZIP URLを返した。
- Windows 0.2.6はRelease buildと`controls / ui-model / ui / timer / updater / settings / shell / display / release-config` verifierが成功した。8 assetはGitHub digest・ローカル生成物・公開URL再取得物でsize / SHA-256が一致し、manifestは`oauthMetadata=embedded-and-verified`、`updateChannel=win`、0.2.x方針どおり`authenticode=unsigned`。
- Windows実機の既存0.2.5へ公開feedのfull packageを適用し、起動中processと`current` exeのProductVersionが`0.2.6+f0172f2...`、ARPが`DisplayVersion=0.2.6`、InstallLocationが既存rootと一致することをreadbackした。実ブラウザYouTube操作とアプリ内MessageBoxの手動クリック経路は誤操作回避のため未確認で、CLI verifierとVelopack適用readbackで代替した。
- 公式Cloudflare Worker static assetsをversion `3132a282-07ca-426b-a127-04a1009c995c`へ配信した。正規ドメインと旧aliasはHTTP 200でWindows 0.2.6 Setupリンクを返し、公開HTML SHA-256はローカル`site/index.html`と一致した。詳細: `progress/2026-08/2026-08-12_hover-pocket-build-161-windows-0.2.6-release.md`。

## 2026-08-12 Mac Media Controls and Stopwatch

- Controlsの再生速度がDia通常起動時に変わらない原因を、AppleScript経由のJavaScript拒否後、既存のYouTubeショートカットへ到達する前に処理を終了していた分岐と特定した。対象URL一致を確認したYouTubeタブだけへショートカットを送り、MediaRemoteの実速度が指定方向へ変化した場合だけ成功として反映するよう修正した。
- メディアサムネイルをクリックすると、記録済みURLに一致するブラウザタブとウィンドウを前面へ出し、成功時にHoverPocketパネルを閉じる操作を追加した。
- Timerへ100分の1秒表示のストップウォッチを追加した。開始、一時停止、再開、リセットに対応し、パネルを閉じたりproviderを切り替えたりしてもアプリ稼働中は計測を継続する。
- 実YouTube / Diaで再生速度`1.0 → 1.25 → 1.0`と復元、前面化後のfrontmost app=`Dia`をreadbackした。`swift build`、署名済みapp生成、Timer、panel layout 112ケース、Media、Clipboard、Calculator、Weather verifier、`git diff --check`が成功した。Small / LargeのTimer画像で重なりと欠落がないことを目視確認した。詳細: `progress/2026-08/2026-08-12_hover-pocket-media-stopwatch.md`。
- 公開release、appcast、Windows版は変更していない。

## 2026-08-12 Repository Sync and Development Audit

- `git fetch origin`後、ローカル`main`が`origin/main`より2 commit遅れていることを確認し、履歴を分岐させない`git merge --ff-only origin/main`で`bb8f06a`へ更新した。
- macOS最新公開版はGitHub Latest `v0.1.0-155`、appcastはbuild 155のZIPを参照している。Windows最新公開版は専用release `win-v0.2.5`で、feedは0.2.5のfull packageを返した。
- `feature/codex-voice-lane`は監査開始時の`main` `bb8f06a`を含む40 commit先行のDraft PR #6。最新CIは成功しているが、production UI接続、microphone / WebRTC、実音声E2Eなどが未完了のため未マージを維持した。今回の監査ログcommitはmainだけに追加する。
- 最新`main`で`swift build`、panel layout 112ケース、Clipboard、Timer、Calculator verifier、`git diff --check`が成功した。監査ログcommitのpush後にlocal / origin SHA一致、ahead / behind `0 / 0`、未コミット・未追跡なしをreadbackする。詳細: `progress/2026-08/2026-08-12_hover-pocket-repository-audit.md`。

## 2026-08-02 Windows 0.2.5 Public Beta Release

- Windows版で予定の作成・編集時に `Invalid time zone definition for start time.` が出る原因は、Google Calendar APIがIANA形式を要求する`start.timeZone` / `end.timeZone`へ、Windows形式の`TimeZoneInfo.Local.Id`（本端末では`Tokyo Standard Time`）を送っていたことだった。
- ローカルtime zoneを.NET標準APIでIANA形式へ変換し、本端末では`Asia/Tokyo`を送るようにした。変換不能時は不正な値を送らず`timeZone`を省略し、offset付きRFC3339日時へフォールバックする。予定一覧の`timeZone` queryにも同じ変換を適用した。
- source target `1277173`からWindows専用release [`win-v0.2.5`](https://github.com/shotaro311/hover-pocket/releases/tag/win-v0.2.5)を`latest=false`で公開した。8 assetのGitHub API digestと匿名download SHA-256、Windows feed、GitHub Pages、公式Cloudflare custom domain 2件のSetup導線をreadbackした。
- Debug / Release buildはwarnings 0 / errors 0、両構成の全13 verifierとWindows UI JavaScript 12ファイルがexit 0。self-contained publish実体のrelease-config / shell / ui / calendar-liveもexit 0。
- このPCのインストール済み0.2.3をVelopack経路で0.2.5へ更新した。ARP両view、root / current exe、通常起動processが0.2.5を示し、インストール済み実体のcalendar / UI / Calendar live読み取り検証が成功した。実予定の更新は外部書き込みになるため未実施。
- GitHub LatestとmacOS専用appcastはbuild 155のまま不変。詳細: `progress/2026-08/2026-08-02_hover-pocket-windows-0.2.5-release.md`、`progress/2026-08/2026-08-02_hover-pocket-windows-calendar-timezone.md`。

## 2026-08-01 Mac Build 155 Release

- exact `main` / `origin/main`の`274217e`をtargetに、macOS build `155`をDeveloper ID Application署名とhardened runtimeで作成した。Apple公証submission `b20ce703-0722-4e20-a0a1-0816cecf2eba`は`Accepted`。
- staple、`codesign --verify --deep --strict`、`stapler validate`、Gatekeeper、ZIP展開後の再検証に合格した。
- GitHub Release [`v0.1.0-155`](https://github.com/shotaro311/hover-pocket/releases/tag/v0.1.0-155)をGitHub Latestとして公開し、macOS専用`macos-latest`のappcastと手動インストールZIPをbuild 155へ同期した。
- versioned / stable appcastはSHA-256 `c0aa1ec496b8e6ffdfc8a7c6a82e2a4d1871ef0e3952efa41653acdcb8f0da43`で一致し、`sparkle:version=155`、versioned ZIP URL、88文字のEdDSA署名を返した。
- 匿名公開URLから再取得したversioned / stable ZIPのSHA-256は`a6965480b0e35892ea4a4bf2a943597ff2e8da994e22fbcb099c4113f299870b`でローカルと一致した。ZIP top-levelは`HoverPocket.app`のみで、展開後も`0.1.0 (155)`、release Keychain suffix、macOS専用feed、Developer ID、公証staple、Gatekeeperを確認した。
- 配信前に`swift build`、`./script/build_and_run.sh --verify`、panel layout 112ケース、Clipboard、Timer compact、Calculator、Weatherの実API / cache verifierが成功した。Windows `win-v0.2.3`は8 asset・target commit `7bfbee4`のまま変更していない。詳細: `progress/2026-08/2026-08-01_hover-pocket-build-155-release.md`。

## 2026-07-29 Windows 0.2.4 Release Candidate

- panel instant close、Controls preview停止競合修正、0.2.4版上げ、README / Webサイト導線更新をsource commit `7a51fd7`へ確定した。
- Debug / Release buildはwarnings 0 / errors 0。両構成の全13 verifier、Windows UI JavaScript 12ファイル、self-contained publish実体のrelease-config / shell / ui / calendar-liveに合格した。
- Windows専用channel `win`の8 assetを生成し、ProductVersion `0.2.4+7a51fd7...`、Google OAuth metadata一致、NUPKG / feed 0.2.4、checksum 7件一致、0.2.x方針どおりAuthenticode未署名を確認した。
- 外部書き込みは未実施。`win-v0.2.4`はsource commit `7a51fd7`をtargetに`--latest=false`で公開し、macOS Latest `v0.1.0-150`とappcast SHA-256 `0618463f...`の不変を公開後に確認する。詳細: `progress/2026-07/2026-07-29_hover-pocket-windows-0.2.4-release-candidate.md`。

## 2026-07-29 Windows Instant Panel Close

- パネルを閉じる終盤に細長い黒いバーが横へ滑る問題は、commit `b9dcdc4`で追加されたWebView2静止画モーフィングが原因だった。全幅の静止画を220msかけてcollapsed `72x12`へ`Stretch.Fill`で圧縮し、進捗78%まで不透明のまま表示するため、内容がバー状へ潰れていた。
- 開く時とパネルサイズ変更時の静止画モーフィングは維持し、閉じる時だけanimation generationとsnapshot refreshを停止して、opacity 0、hide、collapsed配置を同一ターンで行うようにした。使われなくなったclose easing / crossfade分岐も削除した。
- 即時closeで露出したControlsライブプレビューの停止競合をクラッシュダンプで特定した。capture停止より先にlinked tokenをcancelするとframe processorが同期再起動を繰り返して`0xC00000FD`になるため、captureを先に停止し、cancel済みsessionでは再起動しないようにした。
- `--verify shell`へ「close要求開始直後にWPF/nativeの中間表示が残らない」検査を追加し、Debug / Releaseとも25 cycleで`instant_close=true`、open animation `31 / 29` frames、最大frame gap `17.5 / 18.1ms`を確認した。両構成のbuildはwarnings 0 / errors 0、全13 verifierとWindows UI JavaScript 12ファイルのsyntax checkがexit 0。0.2.4へ版上げし、updater dry-runは0.2.3から0.2.4を検出した。詳細: `progress/2026-07/2026-07-29_hover-pocket-windows-instant-close.md`。

## 2026-07-29 Windows Start Menu Shortcut Repair

- ユーザーのスタートメニューに `HoverPocket.lnk` と `HoverPocket.Shell.lnk` の2件があり、前者はインストール済み0.2.3、後者は2026-07-09作成のDebug 0.2.1を指していた。
- 古い `HoverPocket.Shell.lnk` のtarget、working directory、iconを、インストール済みの `C:\Users\shotaro\AppData\Local\HoverPocketWin\current\HoverPocket.Shell.exe`へ揃えた。
- WScript.Shellで両ショートカットを独立readbackし、target存在、ProductVersion `0.2.3+7bfbee4ed54ed989b1ad470fd4420b0d8efeda13`、working directory、iconの一致を確認した。
- Git管理外の古い `windows\src\HoverPocket.Shell\bin\Debug`（76ファイル、34,244,026 bytes）を対象範囲確認後にWindowsのゴミ箱へ移し、対象不存在と親 `bin` の保持をreadbackした。インストール済み0.2.3とその実行中プロセスは保持した。詳細: `progress/2026-07/2026-07-29_hover-pocket-windows-start-menu-shortcut.md`。

## 2026-07-29 Mac Timer Compact Cards

- 実装前にローカル`main`の3コミットを`origin/main`へpushし、local / originが`bf954b028767db6d8b1559f8ee378ca095d4eff5`、ahead / behind `0 / 0`で一致することを確認した。
- Timer / Pomodoroの横並び入力カードは、外側padding、内部spacing、Pomodoroのwork / rest間隔、startボタンを詰めて縦幅を縮めた。
- 実行中セクションの大きな外枠を外し、進捗リング、タイトル、残り時間、pin、pause / resume、stopを1行へ収めた高さ`44pt`の横長カードへ変更した。複数タイマーと終了アラートは`5pt`間隔で縦に並ぶ。
- 時間入力、調整バー、sound、start、pause / resume / stop、pin / unpin、アラーム停止の動作は維持した。`--verify-timer`へcompact layout値の回帰検証を追加した。詳細: `progress/2026-07/2026-07-29_hover-pocket-timer-compact-cards.md`。
- `swift build`、`--verify-timer`のside-by-side / compact、`--verify-panel-layout` 112ケース、`--verify-clipboard`、`./script/build_and_run.sh --verify`が成功した。

## 2026-07-29 Mac Browser Media Playback Rate DOM Readback

- Controlsの再生速度操作を、対象ブラウザタブの`HTMLMediaElement.playbackRate`へ直接設定し、同じvideo要素から読み戻した値だけを成功表示する方式へ変更した。UIと専用verifierは同じ`MediaRemoteService` / browser fallback経路を使う。
- DiaがJavaScript実行結果を引用符付き文字列で返すのに直接`Double`変換していたため、DOM読取成功後に数値化だけ失敗していた。JSON文字列としてdecodeしてから数値化するよう修正した。あわせて、小数1桁への整形で`1.25`が`1.2`へ丸められる問題を解消した。
- UIの先行値更新、未確認shortcut期待値、6秒間の再生速度override、ブラウザ対象への未確認MediaRemote fallbackを撤去した。DOM readback不能時は表示を変更せず失敗扱いにする。
- Apple Development署名とAutomation entitlementを含む製品bundleで、実DOM値`1.0 → 1.25`、`browser_dom` readback、`1.0`への復元、`media_verify=ok`を確認した。verifier終了後も別経路のDOM readbackで`1.0`を確認した。`swift build`、bundle生成、`codesign --verify --deep --strict`、`git diff --check`が成功した。
- DOM操作は、DiaではAppleScript JavaScript有効の起動条件、Chrome / SafariではApple EventsからのJavaScript実行が許可されている場合に利用できる。既存ブラウザ設定、Windows版、公開release / feed、他providerは変更していない。詳細: `progress/2026-07/2026-07-29_hover-pocket-media-playback-rate.md`。

## 2026-07-29 Mac Clipboard / Timer / Extra Large Integration

- Clipboardを「すべて / お気に入り」の2タブへ整理し、両タブでテキストと画像を50:50のsplit viewにした。各項目のコピー、星、個別削除、外部ドラッグ、全体プレビュー、favorite保護clearは維持した。
- Timer入力カードを横並びにし、実行中セクションをtimer color、大きな残り時間、進捗リングで強調した。既存の調整バー、start、pause / resume / stop、pin / unpin、アラーム停止は維持した。
- パネルと文字を4段階へ拡張し、Extra Largeパネル`760x546`、文字`+3pt`を追加した。旧3段階の寸法とraw valueは維持した。
- READMEとrequirementsを同期した。requirementsではmacOSのExtra Largeを追加し、Windows版の現行3段階は変更しないことを明記した。
- 統合検証は`swift build`、`--verify-timer`、`git diff --check`が成功した。Timer verifierは本番保存先を作らず、start / pause / resume / stop、pin / unpin、4段階の横並び幅を確認した。詳細: `progress/2026-07/2026-07-29_hover-pocket-clipboard-timer-extra-large.md`。

## 2026-07-29 Mac Extra Large Panel and Text Sizes

- パネルサイズと文字サイズを`Small / Medium / Large / Extra Large`の4段階へ拡張した。Extra Largeパネルは`760x546`、Extra Large文字は基準フォント`+3pt`。
- 既存3段階の寸法と保存値は維持した。上部サイズ切り替え、Settings、AppSettings永続化、日英表示、Calendar/Weatherメトリクスを4段階へ対応させた。
- `swift build`、panel layout 112ケース、旧raw value・寸法・UserDefaults再読込、calculator、clipboard、`git diff --check`が成功した。実画面の目視readbackとWindows版は未実施。詳細: `progress/2026-07/2026-07-29_hover-pocket-extra-large-sizes.md`。

## 2026-07-29 Mac Calendar Save Button Placement

- Calendarの新規予定・予定編集フォームで、下端にあった保存ボタンをフォーム上部ヘッダーへ移動した。スクロールせずに保存操作へ到達できる。
- 保存処理、保存中表示、入力不能時の無効化、`Command + Return`ショートカットは維持した。編集時の削除ボタンは誤操作を避けるためフォーム下部に残した。
- `swift build`、`./script/build_and_run.sh --verify`、`--verify-panel-layout` 63ケース、`git diff --check`が成功した。Computer Useではホバー専用ウィンドウのフォームをアクセシビリティ経由で開けなかったため、実画面の目視readbackは未確認。詳細: `progress/2026-07/2026-07-29_hover-pocket-calendar-save-button.md`。

## 2026-07-28 Mac Global Weather Locations

- Calendar天気の地点設定を、現在地、世界の都市・郵便番号検索、日本47都道府県の簡易選択へ拡張した。既存の都道府県コードは同じ代表地点へ自動移行する。
- Open-Meteo Geocoding API、地点別`timezone=auto`、高精度座標、自動 / ℃ / ℉、地点・単位別キャッシュを追加した。Core Locationは「現在地を使用」を押した時だけ単発取得する。
- `swift build`、63 panel layout、calculator、clipboard、bundle起動、位置情報説明文、codesignが成功した。実Settingsのアクセシビリティreadbackで福岡、現在地、都市・郵便番号検索、都道府県、温度単位を確認した。
- weather verifierは東京とロンドンの実API取得を一度通過した。最終再実行時はOpen-Meteoの無料Forecast / Statusホストだけが接続タイムアウトし、Geocoding / 公式サイト / customer APIホストは到達できたため、外部側の一時障害として記録した。保存済み予報フォールバックは維持している。
- 現在地の実座標取得は位置情報許可を自動承認せず未実施。Windows版と公開配信は未変更。詳細: `progress/2026-07/2026-07-28_hover-pocket-global-weather-locations.md`。

## 2026-07-28 Mac Build 150 Release

- Calendarの日本47都道府県天気、当日＋7日予報、週間行の整列、上段予定詳細・編集スクロール、天候別SF Symbolsモーションを含む機能commit `96d11ce`までの5 commitを`origin/main`へpushし、local / origin SHA一致を確認した。
- macOS build `150`をDeveloper ID Application署名とhardened runtimeで作成した。Apple公証submission `e0430c08-b7da-457f-ab3f-94afd8011358`は`Accepted`。staple、`codesign`、`stapler validate`、Gatekeeper、ZIP展開後の再検証に合格した。
- GitHub Release [`v0.1.0-150`](https://github.com/shotaro311/hover-pocket/releases/tag/v0.1.0-150)をGitHub Latestとして公開し、macOS専用`macos-latest`の手動インストールZIPとappcastをbuild 150へ同期した。tagは機能commit `96d11ce`を指す。
- 匿名公開URLから再取得したZIPのSHA-256 `507fe20a598794588f845d29170c904f4db82f4b1f301924b0ddb08caf2364e0`はローカルと一致した。versioned / stable appcastは同一SHA、`sparkle:version=150`、同じversioned ZIP URL、88文字のEdDSA署名を返した。
- 公開ZIPの展開後アプリは`0.1.0 (150)`、macOS専用feed URL、Developer ID、公証staple、Gatekeeper、実API weather verifierへ合格した。Windows `win-v0.2.3`は8 asset・target commit `7bfbee4`のまま不変。

## 2026-07-28 Mac Calendar Weather

- Calendarの下段全幅を天気エリアへ変更し、上段とは区切り線で分離した。下段左側に当日の天気、右側に拡大した今後7日間の曜日・天気・最高/最低・降水確率を配置し、Small / Medium / Largeで`58 / 67 / 122pt`へ適応する。
- Calendar表示時に本日のSF Symbolから週間7個へ70ms間隔で続く一回限りの出現モーションを追加した。本日のアイコンはmacOS 15以上で、晴れをRotate、晴れ時々曇りを雲固定・太陽のみRotate、曇り・霧をBreathe、雨をVariable Color、雪をWiggle、雷をPulseで約5秒だけ動かす。macOS 14はPulse / Variable Colorへ戻り、Reduce Motion有効時は即時表示する。
- 週間7列を上揃えにし、SF Symbolを固定高さの枠へ収めた。晴れ・曇り・雨などアイコン固有の寸法が違っても、曜日・アイコン・気温・降水確率のY位置が揃う。
- 高さが短くなった上段右側は予定詳細・予定編集を縦スクロール化し、長い予定一覧や編集フォームが天気エリアへ重ならないようにした。
- Settingsへ日本47都道府県の表示地域pickerを追加した。保存値は都道府県コード（JIS X 0401）、初期値は東京都`13`、予報地点は都道府県庁所在地付近。Macの位置情報、APIキー、秘密情報は使わない。
- Open-Meteoから`Asia/Tokyo`の当日＋7日を取得し、地域単位のローカルキャッシュ、保存済み予報の警告付きオフライン表示、キャッシュなし時の再試行、画面内の帰属リンクを実装した。無料APIの非商用条件と商用化時の移行要件をREADME / requirementsへ記録した。
- `swift build`、実APIを使う`--verify-weather --render-weather-preview`、地域設定save/readback、オフラインcache readback、天候別6プリセット・macOS 14フォールバック・5秒設定、週間行の固定配置、`--verify-panel-layout` 63ケース、`./script/build_and_run.sh --verify`、bundle内weather verifier、codesign、`git diff --check`が成功した。`swift test`はPackageにtest targetがないため`no tests found`で、専用verifierを検証経路とした。生成appは期待pathの1 processで起動した。
- SwiftUI component画像`dist/verification/calendar-weather-preview.png`と、起動したLargeパネルの画面合成画像`dist/verification/calendar-panel-layout.png`で、月グリッド・予定3件・区切り線・下段天気の表示欠けや重なりがないことを確認した。Windows版は未変更でparity残件。詳細: `progress/2026-07/2026-07-28_hover-pocket-calendar-weather.md`。
- 実アプリの120fps録画`dist/verification/calendar-weather-motion.mov`で、本日→週間の順序、8個の最終表示維持、常時ループなしをフレーム確認した。
- 実アプリの8.9秒録画`dist/verification/calendar-weather-modern-motion.mov`で、本日の「晴れ時々くもり」は雲が固定されたまま太陽の光線だけが回転し、約5秒後に停止することを確認した。停止後の7.5秒・8.0秒・8.5秒フレームは画像ハッシュが完全一致した。

## 2026-07-26 Windows 0.2.3 Public Beta Release

- exact main `7bfbee4`をtargetに、GitHub Release `win-v0.2.3`を`draft=false`、`prerelease=false`、`latest=false`で公開した。8 assetのGitHub API size / digest、匿名公開URL、feed 0.2.3、unsigned manifest、checksum 7件を別経路でreadbackし、全件一致した。
- Debug / Release buildはwarnings 0 / errors 0。全12 JS、Release重要verifier、`release-config`はexit 0。OAuth metadataはprocess内注入で`present-and-matched`、channelは`win`、ProductVersionはexact mainを含む。
- 実機baselineのアプリ0.2.2 / ARP 0.2.1から、公開nupkgを実install rootのVelopack 1.2.0経路で検出・download・apply / restartした。更新後はcurrent / root / process / locatorが0.2.3、ARP両viewが0.2.3、InstallLocationと静的valueは保持、一時test keyは0。
- 更新後のself-healは両viewとも`AlreadyCurrent`でno-op。Velopack applyが`InstallDate` / `EstimatedSize`だけをinstall metadataとして更新した。インストール済み0.2.3のControls / 実WebView2 UI verifierはexit 0、2回目の更新確認はup-to-date。
- `--verify calendar-live`は既存credentialでCalendar 6件 / event 91件をread-only取得してexit 0。予定の作成・更新・削除は行っていない。
- GitHub LatestはmacOS `v0.1.0-131`、appcastはSparkle 131 / SHA-256 `b66fe0cc0d65cef699992cf7998a35831c5d340cc59c9ce2474f599fe8e56655`で公開前から不変。詳細: `progress/2026-07/2026-07-26_hover-pocket-windows-0.2.3-release.md`。

## 2026-07-26 Windows 0.2.3 ARP DisplayVersion Repair Candidate

- 0.2.2実update後にARP `DisplayVersion`だけ0.2.1へ残った事象へ、通常再起動processでのself-healを追加した。`VelopackLocator.Current`が示す実インストールrootと既存`HoverPocketWin` keyの`InstallLocation`が一致する場合だけ、Registry64/Registry32の`DisplayVersion`を現在versionへ更新する。
- portable、非インストール、keyなし、path mismatch、例外、verify、second-instance probeではproduction ARPを変更しない。UpdaterVerifierの一時test keyでstale 0.2.2→0.2.3、path mismatch no-op、他value維持、cleanupをDebug / Releaseともに確認した。
- Debug / Release buildはwarnings 0 / errors 0。Debug主要12 verifier、Release重要6 verifier、全12 JSの`node --check`、`git diff --check`はすべてexit 0。
- OAuth値をprocess内だけで注入して0.2.3 candidateを生成した。`release-config`は0.2.3・Release・OAuth metadata一致・channel `win`でexit 0、nupkg / Portable内部version、feed、unsigned manifest、checksum 7件も一致した。GitHub Release作成・asset uploadは行っていない。
- インストール済み0.2.2とARP 0.2.1は上書きせず保持した。残るgateは0.2.3公開後の実update apply/restartと、ARP `DisplayVersion`および他value維持のreadback。詳細: `progress/2026-07/2026-07-26_hover-pocket-windows-0.2.3-arp-fix.md`。

## 2026-07-26 Windows 0.2.2 Release Candidate Verification

- `origin/codex/windows-0.2.2-release`をtrackingするローカルbranchへ、cleanな状態からswitchした。開始時のlocal / origin / GitHub SHAは`4873e19`で一致し、Windowsローカル`main`とrecovery branchは動かしていない。
- Release候補の実アカウントread-only gateとして`--verify calendar-live`を追加し、予定内容を出さずCalendar / event件数だけを返すようにした。commit `df4c652`を同branchへ通常pushし、origin SHA一致をreadbackした。
- Debug / Release buildは最終的にwarnings 0 / errors 0。Debugの指定12 verifierとReleaseの重要6 verifier、全12 JSの`node --check`、`git diff --check`はすべてexit 0。最初のDebug buildだけは正本Debugプロセスのfile lockで失敗し、該当プロセスだけを終了して再実行後に成功した。
- process内だけでOAuth設定を注入して`publish_release.ps1`を実行し、0.2.2のSetup / Portable / nupkg / Windows feed / manifest / checksumを生成した。`release-config`は0.2.2・Release・OAuth metadata一致・channel `win`でexit 0、feed / manifest readbackとchecksum 7件も一致した。成果物は0.2.x方針どおり未署名で、GitHub Release作成・asset uploadは行っていない。
- Portable Release候補を別processで2回起動し、既存Credential Manager資格情報によるCalendar refresh / readがともにexit 0。Calendar 6件、event 91件で一致し、予定の作成・更新・削除は行っていない。インストール済み0.2.1は実行ファイル2件・uninstall entry 1件・version 0.2.1のまま保持した。
- 残件は、requirementsの現行配布署名必須記述とREADME / manifestの0.2.x未署名方針の不一致、公開後にのみ可能な0.2.1→0.2.2 update apply / restart、端末ポリシーに拒否されたTemp展開物の後片付け。詳細: `progress/2026-07/2026-07-26_hover-pocket-windows-0.2.2-release-candidate.md`。

## 2026-07-24 Mac Build 131 Release

- commit `83a7e23`（ホバー入口の自動復旧＋パネル開始位置のずれ修正）を `origin/main` へpushし、macOS build `131` を配信した。tag `v0.1.0-131` は `83a7e23` を指す。
- Apple公証 submission `ae7f4e7e-aed6-41e2-9d60-22af75c644aa` は `Accepted`。Developer ID署名、staple、Gatekeeper評価に合格したZIPをGitHub Release `v0.1.0-131` とmacOS専用 `macos-latest` へ公開し、GitHub Latestもbuild `131` へ更新した。
- 公開URLから再取得したZIPのSHA-256は `97c4819fa5c9a442e72334b12530ad2be02c24218397fc96aff01fb4561dd79c` でローカル成果物と一致した。`macos-latest` の手動インストール用 `HoverPocket-macOS-app.zip` も同一ハッシュだった。
- 展開後の `CFBundleVersion=131`、`CFBundleShortVersionString=0.1.0`、`SUFeedURL=https://github.com/shotaro311/hover-pocket/releases/download/macos-latest/appcast.xml`、`codesign --verify --deep --strict`、`stapler validate`、`spctl --assess` を確認した。
- macOS専用appcastは `sparkle:version=131` とversioned ZIP URLを返した。**初回取得はCDNキャッシュで127を返したため、`Cache-Control: no-cache` とクエリ付きで再取得して確認した。** 配信直後のfeed確認では同じ注意が必要。
- rollback手順: `gh release edit v0.1.0-127 --latest` でLatestを戻し、`v0.1.0-127` のassetから `appcast.xml` と `HoverPocket-macOS-app.zip` を `macos-latest` へ `gh release upload macos-latest ... --clobber` で再アップロードする。これでSparkleクライアントは127へ戻る。

## 2026-07-24 Mac Panel Open Animation Anchor Fix

- 妻のM2 Mac（配布版build 127）で、パネル開閉アニメーションが上部中央からではなく右上部から左へスライドして見える報告に対応した。原因機構は `NSHostingController` の既定 `sizingOptions` で、`HoverPanelShell` の固定frameがウィンドウのmin/maxサイズとして確定し、開始フレーム `collapsedPreview`（72x12）が左上を起点に全幅へ引き伸ばされる。
- プレビュー／アクセス両ウィンドウの `NSHostingController` に `sizingOptions = []` を設定した。寸法制約の明示クリアはプローブで単独無効と分かったため採用していない。
- 未確認事項: **開発機（macOS 26、ノッチなし、miniBar経路）では build 127 の時点で既に症状が再現しない。** 実アプリreadbackで127・修正版とも開始70x12・中心オフセット0だった。確認できたのは「単体プローブで既定設定が中心を304pt右へずらす＝症状を再現する」ことと「修正版に回帰がない」ことのみ。妻のM2 Macでの実機確認が必要。
- `swift build`、`--verify-panel-layout`（63ケース）、`--verify-calculator`、`--verify-clipboard`、`git diff --check` が成功。
- 詳細: `progress/2026-07/2026-07-24_hover-panel-open-anchor.md`

## 2026-07-17 Mac Hover Entry Self-Recovery

- build 127 を3日以上連続稼働した状態で、プロセスと上端のアクセスウィンドウは存在するがホバーしてもプレビューが開かない事象を確認した。アプリ再起動後は同じ公開バイナリで復旧したため、永続設定やOAuth改修ではなく、長時間稼働・スリープ・画面遷移後の入力状態不整合として対策した。
- SwiftUIの `.onHover` に加え、アクセスウィンドウと現在のマウス座標を0.12秒間隔で照合するAppKitフォールバックを追加した。通常のホバー通知が失われてもプレビューを開ける。
- 2秒間隔でアクセスウィンドウの存在、表示状態、スタイル、位置を検査し、不整合時は入口だけを自動再生成する。スリープ復帰、ログインセッション再開、ディスプレイ構成変更時は画面情報が安定するまで即時・0.45秒後・1.4秒後の3段階で再構築する。
- `swift build`、`--verify-panel-layout`（63ケース）、`--verify-calculator`、`--verify-clipboard`、`./script/build_and_run.sh --verify`、`git diff --check`が成功した。通常の `.onHover` を無効化した診断起動でも、カーソルを上端へ移すと680x488のプレビューがオンスクリーンになり、退避後に閉じることをCoreGraphics readbackで確認した。通常起動でも同じ開閉を確認した。
- 公開版build 127、GitHub Release、appcastは変更していない。修正はローカル開発ビルドで検証済みで、正式配布には次buildの署名・公証・release/appcast更新が必要。
- 詳細: `progress/2026-07/2026-07-17_hover-panel-recovery.md`

## 2026-07-15 Google OAuth Review Remediation

- Google OAuth reviewerの追加要求に対応し、公式サイトとプライバシーポリシーの正本を `https://hoverpocket.s-original.com/` へ移した。Cloudflare Worker `hoverpocket-site` のcustom domainとして公開し、ローカルHTMLと公開GET本文のSHA-256一致を確認した。旧 `hoverpocket.shotaromatsumoto.com` は移行用aliasとして維持している。
- 公開ページから現行UIに存在しないAI lane表記を除去し、第三者AIサービス連携はないこと、GoogleユーザーデータをAI/MLモデルの作成・学習・改善へ使わないこと、実験的Apple Foundation Models処理は端末内のみであることを日英で明記した。
- `shotaro.matsu0311@gmail.com` でSearch ConsoleのURL-prefix property `https://hoverpocket.s-original.com/` の所有権をHTMLファイルで自動確認した。Google Auth Platformのhomepage、privacy policy、authorized domainを新URL / `s-original.com` へ更新し、検証センターが引き続き「ブランディングとデータアクセスは現在審査中」と表示することを確認した。
- 審査スレッドへ最終canonical URLの訂正を英語で返信した。送信message IDは `19f65d9ac9d51760`、thread IDは `19f658cbca0ca966`。Gmail connectorで対象アカウント、送信本文、新URL、`SENT`をreadbackした。
- 詳細: `progress/2026-07/2026-07-15_hover-menu-preview.md`

## 2026-07-21 Windows Clipboard Tabs / Calculator Sidebar / Brightness Drag Reliability

- Clipboardを既定の「すべて」と「お気に入り」の2タブへ整理し、両タブでテキスト/画像を中央50:50のsplit viewにした。外部ドラッグボタンを全項目の赤いゴミ箱へ置き換え、画像の解像度表示を時刻へ変更した。全体プレビューは画像をパネル内へcontainし、テキストを選択可能な全文スクロールにした。
- CalculatorはmacOS版と同じ左履歴サイドバーへ変更した。履歴がある時だけ表示し、上部ボタンで開閉、結果の再利用、式の復元、履歴全消去を維持する。実画面で`7+5=12`の履歴サイドバー表示と収まりを確認した。
- BrightnessはDDC/CIの約50ms API特性に対して連続送信が詰まらないよう、WebViewを110msのlatest-only、nativeを100msの最小間隔にした。書き込み失敗時は55ms待機で1回再試行し、それでも失敗した時だけ対象の物理モニターハンドルを開き直す。英語の失敗文を日本語化し、display一覧の横overflowも止めた。
- Debug buildはwarnings 0 / errors 0。`clipboard`、`calc`、`ui-model`、`controls`、`ui` verifierはexit 0。実機`Generic PnP Monitor`で85→77→69を169.3msで連続writeし最終値をreadback、85への復元にも成功した。通常起動は最新Debug TFMの1processをreadbackした。詳細: `progress/2026-07/2026-07-21_hover-pocket-windows-clipboard-calculator-brightness.md`。

## 2026-07-20 Windows Monitorian-style Brightness Control

- 実アプリで「明るさを検出しています。」が残るreadbackを受け、検出完了とControls初期snapshot作成、非表示中のprovider mountが競合して確定値を失う2経路を修正した。最新display結果を独立保持して通常・cached snapshotへ必ず合成し、検出中だけ900ms間隔・最大3回の軽量再確認を行う。UI上の一時状態は「非対応」ではなく「検出中…」と表示する。
- `controls_brightness_detection_race=ok`、`controls_brightness_cached_merge=ok`を追加し、WebView2 UI verifierも一時状態が4.5秒以内に解消しなければ失敗するよう強化した。Debug buildはwarnings 0 / errors 0、Controls実機変更・復元とUI verifierはexit 0。
- Monitorian公式実装を参照し、DDC/CIの物理モニターハンドル、対応方式、raw最小・最大値を検出後に保持する方式へ変更した。輝度変更ごとのdisplay再列挙、capability再取得、全画面readbackを廃止し、対象モニターへ直接書き込んでローカル状態を更新する。
- high-level brightness APIが使えないモニターではVCP luminance `0x10`へfallbackし、一時的なDDC通信エラーだけを1回再試行する。実機の`Generic PnP Monitor`が従来の非対応判定から39%の対応表示へ変わった。
- 応答しないDDC検出はUIから180msで切り離し、完了後にnative eventで表示を更新する。スライダーは60ms間隔のlatest-only送信とし、処理中に古い値を積まず、輝度変更時の音量・メディア再取得も廃止した。
- Debug buildはwarnings 0 / errors 0。実機`--verify controls --change-brightness`で初回応答188.6ms、cached read 0.0ms、直接write 61.1ms、39→40→39の実readbackと復元に成功した。`--verify ui`もexit 0。詳細: `progress/2026-07/2026-07-20_hover-pocket-windows-monitorian-brightness.md`。

## 2026-07-20 Windows Sticky Actions / Timer Layout / Controls Performance

- 付箋編集の右上操作をarchive / trash / saveのSVGアイコンへ変更し、淡色カード上で判別できる青・赤・緑の高コントラスト背景、境界線、focus表示を追加した。削除はbackspace記号からゴミ箱マークへ置き換えた。
- Timerは実行中とプリセットを全幅、通常TimerとPomodoroを必要幅に応じた左右カードとし、小幅では1列に戻るresponsive layoutへ変更した。時間バーの`input`でbridge更新とDOM全置換を繰り返さず、ドラッグ中は数値表示だけを更新し、操作完了時に保存する。空のプリセット欄はMac版と同様に非表示にした。
- ControlsはJavaScript側の5秒pollingを廃止してnative event + 10秒fallbackに一本化。750ms snapshot cacheと15秒brightness cacheを追加した。media eventは90msで合流し、artworkは曲情報が変わるまで再利用する。Windows Graphics Captureのsoftware JPEG / Base64変換は最新frame 1枚のみ、最大10fpsに制限した。timeline更新だけでmedia canvasを再生成しない。
- Debug buildはwarnings 0 / errors 0。`sticky`、`timer`、`controls`、`ui-model`、`ui`はすべてexit 0。UI verifierでControlsの同一DOM refresh、Timerの横overflowなし、duration input DOM維持を検査した。実機はmedia sessionなしのため、再生中live previewのCPU実測は未実施。詳細: `progress/2026-07/2026-07-20_hover-pocket-windows-sticky-timer-controls.md`。

## 2026-07-18 Windows Hover / Text Input / Clipboard Flicker / Calendar UI

- 最大化した通常ウィンドウを全画面表示と誤判定して上端ホバーを抑止していたため、`IsZoomed` を使って最大化を除外し、画面全体を覆うボーダーレス表示だけを抑止するようにした。実カーソルを `2560x1440` 主画面の上端中央へ移動したreadbackで、最大化中でもpanelが `940,9,1620,497` に開き、上端を離れると閉じることを確認した。
- panelはホバー中の非アクティブ表示を維持し、panel内をクリックした時とテキスト入力開始時だけ `WS_EX_NOACTIVATE` を外してkeyboard focusを受ける。編集終了・provider切替・panel closeではstyleを復元する。live Win32 probeで `MA_ACTIVATE=1`、入力中のno-activate解除、close後の復元をreadbackした。
- provider iconをstate更新ごとに全再生成していた経路を、同じ構成では同一DOM nodeを再利用する方式へ変更し、hover選択要求も直列・最新値へ集約した。既存Clipboard root / unchanged refresh維持と合わせ、clipboard icon上の微小移動でmouseenterと再生成が循環しないようにした。
- Windows CalendarをmacOS `GoogleCalendarPreviewView`と同じ左右2paneへ変更した。小サイズ248px、中・大282pxの月表示、42日grid、各日最大3色dot、縦divider、右側の日付・更新時刻・色bar付き予定行へ揃え、接続/setup/editor状態は維持した。
- 最終検証はDebug build warnings 0 / errors 0、`--verify shell` 25 cycle、`sticky`、`clipboard`、`calendar`、`ui-model`、`settings`、`ui`がすべてexit 0。通常起動はPID `41980`の1process、期待Debug path、`Responding=True`をreadbackした。詳細: `progress/2026-07/2026-07-18_hover-pocket-windows-hover-input-calendar.md`。

## 2026-07-18 Windows Google Calendar Login Diagnosis

- 実際に稼働していたのはインストール先ではなく、正本cloneのDebug `HoverPocket.Shell.exe` 0.2.1.0だった。実assemblyにGoogle OAuth client metadataはなく、`%APPDATA%\HoverPocket\oauth.json`とCredential ManagerのHoverPocket refresh tokenも存在しないため、ログイン不能の原因は`missing_configuration`で確定した。
- 現行コードと一時copyの`--verify calendar`は、承認済み2 scope、S256 PKCE、state、動的`127.0.0.1` loopback、Credential Manager、request builder、read-only guardを通過した。コード修正ではなく、承認済みprojectのWindows Desktop OAuth clientを次のWindows build / releaseへ安全に設定する必要がある。
- Windows上には利用可能なclient設定、gcloud session、GitHub Actions variable / secretがなく、Chromeの既存Cloud Console sessionも指定対象アカウントではなかった。アカウント切替、MFA/利用規約操作、同意、token取得、Calendar read/writeは行わず停止した。詳細: `progress/2026-07/2026-07-18_hover-pocket-windows-calendar-login-diagnosis.md`。
- 再確認でもOAuth設定は未配置だった。missing-configuration setup cardにはJSON配置先はあったが再起動案内がなかったため、配置後にHoverPocketを終了・再起動する手順を日英で追加し、`--verify calendar`へ配置先と再起動案内の検査を追加した。一時copyのbuild、calendar、ui verifierはすべてexit 0。設定不足のため実アカウントE2Eはblockedのまま。
- 指定対象アカウントでGoogle Cloud Consoleの`hoverpocket` projectをreadbackしたが、既存OAuth clientはmacOS用iOS client 1件だけでDesktop appは0件だった。新規client作成は禁止されているため、JSON取得・配置、アプリ再起動、同意、Calendar read / refresh / reconnectは実施せずblocked。client ID / secret / JSON / tokenは出力していない。
- ユーザー承認後、対象アカウントと`hoverpocket` projectを再確認し、Desktop app `HoverPocket Windows`を1件作成して成功ダイアログをreadbackした。作成後にChrome ExtensionのCloud Console操作が連続timeoutとなり、DownloadsにもJSONがないため、重複作成せずclient詳細画面での手動JSON download待ち。oauth.json配置、アプリ再起動、同意、Calendar E2E、審査status確認は未実施。
- 手動downloadされたDesktop OAuth JSONを構造検査して`%APPDATA%\HoverPocket\oauth.json`へatomic配置し、Downloads原本を保持した。指定対象アカウントだけで初回同意とCalendar readに成功し、Credential Manager保存、Debug本体再起動後のrefresh/read、切断によるcredential消失、再同意・再接続、再起動後readまでexit 0で確認した。Google Auth Platformは同じ対象アカウント・`hoverpocket` projectでbranding / data accessとも検証済み表示を維持し、再審査要求は表示されなかった。正式Windows artifactへの安全なclient設定注入は未実施。
- 現行作業ツリーをWindows Debugとして再ビルドし、warnings 0 / errors 0を確認した。旧`net10.0-windows`プロセスを終了し、生成直後の`net10.0-windows10.0.22621.0\HoverPocket.Shell.exe`へ切り替えた。再起動後は1プロセスのみ、期待path、`Responding=True`をreadbackした。

## 2026-07-17 Windows Hover Self-Recovery and OAuth Audit

- 既存の120ms pointer pollingを維持し、約2秒ごとのaccess surface / panel health checkを追加した。HWND、WPF/native visibility、`WS_EX_NOACTIVATE` / `WS_EX_TOOLWINDOW` / `WS_EX_TOPMOST`、期待frameを検査し、修復可能な異常は同じwindowへ再適用、無効HWNDだけを再生成する。panel再生成時は既存`PanelBridgeController`とprovider stateを維持する。
- display / DPI change、Power Resume、session unlock / console connect / remote connectで、pollingとhealth timerを再始動し、即時・450ms・1.4秒後の3段階recoveryを実行する。Disposeではtimer、予約task、SystemEvents、HWND hooks、WebView bridge attachmentを解除する。
- 一時copyで`dotnet build`、`--verify shell`、`--verify display`、`--verify calendar`がexit 0。shell verifierはpolling-only open、hidden / 位置ずれ / style欠落の修復、window再生成、3段階scheduler、25回open/closeを通過した。実カーソルreadback中にcloseとhealth checkの競合を検出して修正し、最終GUI再試行は全画面抑止またはタイミングの影響でopenを再現できなかったため、最終の実GUI open/closeは未確定として残す。
- Windows OAuthコードは承認scope 2件、S256 PKCE、state、動的`127.0.0.1` loopback、offline refresh token、Credential Manager、再接続判定に対応済み。現在インストール済み0.2.1と公開`win-v0.2.1`の実assemblyにはOAuth metadataがなく、ローカル`oauth.json`と本番Credential Manager資格情報もないため、現行配布物のログインは未対応。実アカウントE2Eは外部操作を避けて未実施。詳細: `progress/2026-07/2026-07-17_hover-pocket-windows-recovery-oauth-audit.md`。

## 2026-07-13 Mac Build 127 Release

- メディア操作の応答性改善、前後トラック操作、ScreenCaptureKit 30fpsライブプレビュー、取得不能時のサムネイルフォールバックを含むcommit `01fb33d`を`origin/main`へpushし、macOS build `127`を配信した。
- Apple公証submission `453cc3ff-3033-4d43-b544-8d457c5d8508`は`Accepted`。Developer ID署名、staple、Gatekeeper評価に合格したZIPをGitHub Release `v0.1.0-127`とmacOS専用`macos-latest`へ公開し、GitHub Latestもbuild `127`へ更新した。
- 公開URLから再取得したZIPのSHA-256は`6dda40d9b9d2012b80f2e25398131b2fa1c265a43cc3f982ada58cb3f515056c`でローカル成果物と一致した。展開後の`CFBundleVersion=127`、`CFBundleShortVersionString=0.1.0`、`SUFeedURL=https://github.com/shotaro311/hover-pocket/releases/download/macos-latest/appcast.xml`、`codesign`、`stapler validate`、`spctl`を確認した。
- macOS専用appcastとGitHub Latest経由のlegacy appcastは、どちらも`version=127`とversioned ZIP URLを返した。tag `v0.1.0-127`はcommit `01fb33d`を指し、最終の`HEAD...origin/main`は`0/0`だった。

## 2026-07-13 Mac Media Live Preview

- Controls のメディア画像を、0.75秒ごとの `SCScreenshotManager` 静止画取得から、ScreenCaptureKit `SCStream` の392×220・30fps連続キャプチャへ置き換えた。
- `CMSampleBuffer` の IOSurface を小さな `NSViewRepresentable` / CALayer bridge へ直接渡し、NSImage変換を廃止した。描画待ちフレームは最新1枚へ集約し、UI負荷時に古いフレームが溜まらないようにした。
- アートワーク／プレースホルダーを常にライブ層の背面へ置き、画面収録未許可、window IDなし、対象window解決失敗、stream開始失敗、初回2秒以内のframe未到達、stream停止時はライブ層を透明化して自動フォールバックする。
- 画面収録権限は従来どおりpreflightのみで、Controlsの受動表示から許可ダイアログを再要求しない。ライブcaptureはControls表示中だけ起動し、view破棄時に停止する。
- 署名済みアプリのGUIでYouTubeプレビュー表示を確認。`--verify-media --toggle-playback --verify-live-preview` は0.7秒で完全frame 22枚、`media_live_preview_mode=live`、`media_toggle_verified=true`、`media_verify=ok`。`--verify-live-preview-fallback` は `fallback_no_window`、`media_live_preview_fallback=true`、`media_verify=ok`。

## 2026-07-13 Mac Media Control Responsiveness and Track Navigation

- Controls の常駐 mediaremote-adapter loop が受け付ける stdin コマンド経路を利用し、再生/停止とシークのたびに別の perl プロセスを起動していた遅延・取りこぼしを解消した。常駐 stream が使えない場合は既存 one-shot / MediaRemote fallback を維持する。
- 再生/停止は pipe への書き込み完了ではなく、media stream から期待した実状態が返った時点で成功確定する。通知が欠けた場合は 1.5 秒後に readback して楽観表示と pending 状態を復旧する。
- メディア操作列に前のトラック、次のトラックのボタンを追加した。既存の冒頭へ戻るボタンは `arrow.counterclockwise` に変更し、前のトラックとのアイコン重複を避けた。
- 各メディアボタンのクリック領域を 32pt、主ボタンを 34pt へ拡大し、透明部分を含む矩形全体を hit-test 対象にした。
- 検証は `swift build`、`git diff --check`、`./script/build_and_run.sh --verify`、`--verify-panel-layout` が成功。`--verify-media --toggle-playback` は `media_toggle_transport=adapter_stream`、`media_toggle_verified=true`、`media_verify=ok` を返し、再生状態を元へ復元した。

## 2026-07-12 Google OAuth Verification Submitted

- Uploaded the final OAuth review recording to YouTube as unlisted: `https://youtu.be/swDXmcJxJrE` (`HoverPocket Google OAuth Verification Demo`). YouTube readback confirmed the 1:04 video, unlisted selection, and completed copyright/community-guidelines checks with no issues detected. Anonymous HTTP readback returned `200` and the expected video title.
- Confirmed Search Console still reports `shotaro.matsu0311@gmail.com` as a verified owner of the exact URL-prefix property `https://shotaro311.github.io/`. Updated the Google Auth Platform homepage to the actual app page `https://shotaro311.github.io/hover-pocket/`; homepage and privacy-policy URLs both returned HTTP `200`.
- Google Auth's automated branding check continued to report the GitHub Pages homepage as unregistered despite the Search Console ownership readback. Continued through the `detected issue is incorrect` manual-review path and added the ownership evidence to the submission details.
- Saved the combined justification for `calendar.events` and `calendar.calendarlist.readonly`, the YouTube demo URL, and the supplemental ownership/project information. Submitted the verification questionnaire with HoverPocket classified as public, external, production-ready software rather than personal, internal, test/staging, or a WordPress SMTP plugin.
- Final Google Cloud readback: Verification Center displays `Branding and data access are currently under review` for project `hoverpocket`.
- Created active automation `hoverpocket-oauth` (`HoverPocket OAuth審査メール監視`) to check `shotaro.matsu0311@gmail.com` twice daily at 09:00 and 18:00 JST. It reports only new OAuth-review mail, excludes the ordinary Google-account access security notification, and does not send, archive, delete, label, or mark messages read.
- Initial Gmail readback found only the ordinary `HoverPocket` Google-account access security notification from 2026-07-12 12:32; no verification-submission or reviewer-response mail was present yet.

## 2026-07-12 Google OAuth Review Video Final Edit

- Reviewed `/Users/shotaro/Downloads/画面収録 2026-07-12 12.31.26.mov` for the Google OAuth verification demo. The original is 83.51s, 3024x1964, H.264, and has no audio stream.
- Rebuilt the final from the two video materials currently remaining in Downloads. The original opening now remains from 0:00, only the Japanese OAuth consent section is replaced by the English consent section from `/Users/shotaro/Downloads/画面収録 2026-07-12 12.46.52.mov`, and the original Calendar create/delete flow resumes afterward.
- Created `/Users/shotaro/Downloads/HoverPocket-Google-OAuth-verification-final.mov` with no blur or mosaic processing, as requested.
- Verification passed: full decode produced no warnings; `ffprobe` reports 63.90s, 3024x1928, H.264, yuv420p, 30fps, no audio. Full contact-sheet and targeted-frame review confirmed the restored opening, English consent and both scopes, both replacement boundaries, Calendar operations, completed event deletion, and an ending before the unrelated article card.
- Submission caveat: the source does not show clicking the final OAuth `Continue` button. It transitions from selected English scopes into HoverPocket's connected state, so Google may request a retake under the end-to-end OAuth grant-flow requirement.

## 2026-07-10 Windows Clipboard Flicker Fix

- Clipboard表示のちらつきは、同じproviderのstate更新でもprovider DOMを全削除し、Clipboard rootを再生成して登場animationを再発火していたことが原因だった。
- provider id / languageが同じ場合はmountを維持し、登場animationをprovider切替時だけcontainerへ適用した。Clipboardはcached stateを即時表示し、同じstate signatureのrefreshではDOMを置換しない。scroll位置維持、refresh合流、選択済みproviderのno-opも追加した。
- Debug `--verify ui` 10回連続、Release `--verify ui` 5回連続、Clipboard verifier、Release shell 25 cycleがすべてexit code 0。最終Release shellは20 frames / 最大gap 20.1ms。`0.2.1`ローカル配布物を再生成したが未署名・未公開。詳細: `progress/2026-07/2026-07-10_hover-pocket-windows-clipboard-flicker.md`。

## 2026-07-10 Windows Controls, Settings, and Smooth Motion

- Windows 版から Mirror / Microphone を除外し、macOS 版は変更しない方針を requirements に反映した。
- Windows Controls provider を追加した。Core Audio の音量・ミュート、WMI / DDC/CI の輝度、Windows system media session の Now Playing・再生/停止・シーク・再生速度に対応し、各APIの遅延・非対応はタイムアウト付きで個別に fallbackする。
- Settings に表示先、provider復元方式、固定provider、上端ハンドル B / C / None、ハンドル横幅、全画面抑止、Sticky grid、表示先リセット、データフォルダー導線を追加した。実ハンドルは文字ではなくmacOS相当のchevron / pocket glyphを描画する。
- パネル開閉・リサイズを描画タイミング同期、WebView snapshot morph / crossfade、反転可能な animationへ変更し、通常時のWebView2 GPUを有効化した。Debugの最終closeは18 frames / 最大gap 23.6ms、Releaseは18 frames / 最大gap 26.1ms。open/close 25 cycle、WebView2 Controls 3領域の実描画・収まり、Debug全verifier、Releaseのsettings/controls/ui/shellがすべてexit code 0。
- `publish_release.ps1` で `0.2.1` のSetup / Portable / Velopack feedをローカル生成した。未署名で、GitHub公開は未実施。詳細: `progress/2026-07/2026-07-10_hover-pocket-windows-controls-motion.md`。

## 2026-07-06 Windows Build 124 Clipboard and Calculator Parity

- Added Windows Clipboard parity for macOS build 124: `Text` / `Images` / `Favorites` tabs, star favorite toggles for text and image items, favorite-preserving clear, explicit favorite deletion from the Favorites tab, saved image file deletion on explicit image removal, and full-panel text/image preview. Card click now opens preview; copy stays on the copy icon/button. Existing `%APPDATA%\HoverPocket\clipboard\history.json` entries without `favorite` fields load as `favorite=false`.
- Added Windows Calculator JIS keyboard parity and Mac calculator follow-up parity: `;` maps to `+`, `:` maps to `×`, plain `8` remains numeric, continuous expressions are evaluated on final equals with precedence (`6+5+9/2+3-5=` -> `13.5`), pending expressions are visible, and a history clear action is available. History result click still inputs only the result value, while restore returns to the captured calculation state.
- Removed the AI command lane from the normal Windows panel UI and set Windows panel metrics so visible panel height no longer includes the deferred AI lane.
- Verification passed: `node --check` for `windows\ui\providers\clipboard\clipboard.js`, `windows\ui\providers\calculator\calculator.js`, and `windows\ui\js\app.js`; `dotnet build windows\HoverPocket.Windows.sln --nologo -p:NuGetAudit=false`; `dotnet run --no-build --project windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify calc`; `--verify clipboard`; `--verify ui-model`; `--verify updater`; and `git diff --check`. Details: `progress/2026-07/2026-07-06_windows-build124-parity.md`.
- No Windows release was created. Windows feed/updater code was not changed; `--verify updater` remains green. Hands-on WebView2 Clipboard/Calculator UI confirmation is still pending.

## 2026-07-06 Mac Calculator JIS Keyboard Shortcuts

- Added Japanese keyboard-friendly Calculator operator input. On JIS keyboards, the unshifted `;` key now inputs `+`, and the unshifted `:` key now inputs `×`, so addition and multiplication no longer require Shift for those physical keys.
- The mapping is applied in the SwiftUI key handler, keyCode fallback, Calculator expression parser, and `--verify-calculator` sequence parser. Existing `+`, `*`, `×`, numpad operators, Enter, Escape, and Backspace behavior remains intact.
- Verification passed: `swift build`, `.build/debug/HoverPocket --verify-calculator`, `--calculator-sequence '5;6:2='` producing `17`, `.build/debug/HoverPocket --verify-clipboard`, `.build/debug/HoverPocket --verify-panel-layout`, and `git diff --check`.
- Released build `124` as notarized/stapled macOS ZIP including the Clipboard favorites/full-preview work and JIS Calculator keyboard fix. `notarytool` submission `f8bac523-7bf7-4612-ad77-e2d9f9506bf6` returned `Accepted`; GitHub Release `v0.1.0-124` is GitHub Latest and `macos-latest` assets now point to build `124`. Remote readback confirmed stable and legacy appcasts both report `sparkle:version=124`, stable ZIP SHA256 `cd951f79b2e10826022f9231f105b48c1d98cb523f6b5fe36b8f955cede5ef89`, extracted app `CFBundleVersion=124`, macOS feed URL, and `codesign` / `stapler validate` / `spctl`.

## 2026-07-06 Mac Clipboard Favorites and Full Preview

- Updated macOS Clipboard from a fixed text/image split into `Text` / `Images` / `Favorites` tabs. Text and image cards now have star buttons; favorite items remain visible in their original tabs and are collected in the Favorites tab.
- Changed Clipboard clear behavior so it removes only non-favorite history. Favorite text/image items survive clear; favorite-tab trash buttons delete those favorite items explicitly, including image files.
- Added full-panel preview for text and images. Clicking a text or image card opens an expanded preview inside the panel; clicking again or the close icon dismisses it. Long text previews are scrollable.
- Added `--verify-clipboard` with temp-storage coverage for favorite preservation, favorite image deletion, non-favorite image cleanup, and legacy JSON decode defaults.
- Verification passed: `swift build`, `.build/debug/HoverPocket --verify-clipboard`, `.build/debug/HoverPocket --verify-panel-layout`, `.build/debug/HoverPocket --verify-calculator`, `git diff --check`, and `./script/build_and_run.sh --verify`. Clipboard verifier readback: favorite text/image after clear `1/1`, regular image removed `true`, legacy decode default favorite `true`.

## 2026-07-06 Mac Calculator Responsive Panel Layout

- Fixed Calculator layout breakage when switching panel size. The Calculator now derives sidebar width, display height, keypad height, spacing, and font sizes from the available provider area, so Small / Medium / Large keep the history sidebar, expression display, and keypad inside the panel.
- Added `--verify-panel-layout`, which mounts all built-in providers across Small / Medium / Large and panel text size Small / Medium / Large. The verifier also checks Calculator with history visible against the available content height.
- Verification passed: `swift build`, `.build/debug/HoverPocket --verify-panel-layout`, `.build/debug/HoverPocket --verify-calculator`, `--calculator-sequence '6+5+9/2+3-5='`, `git diff --check`, and `./script/build_and_run.sh --verify`. Layout readback: 63 provider cases, Calculator `small=310.0/317.0`, `medium=359.0/375.0`, `large=428.0/433.0`, all `fits:true`.
- Released build `122` as notarized/stapled macOS ZIP. `notarytool` submission `84ea8472-6967-44a0-aa01-ddcf277c4836` returned `Accepted`; GitHub Release `v0.1.0-122` is GitHub Latest and `macos-latest` assets now point to build `122`. Remote readback confirmed stable and legacy appcasts both report `sparkle:version=122`, stable ZIP SHA256 `2ed3b4ae8865414a54d2ae3a84d1352c7e0303ec7cf2d7c99564ca1982b40c6b`, extracted app `CFBundleVersion=122`, macOS feed URL, and `codesign` / `stapler validate` / `spctl`. LINE-share ZIP copied to `~/Downloads/HoverPocket-macOS-app-122.zip`.

## 2026-07-06 Mac Calculator Continuous Expressions and Clear History

- Added a Calculator history clear action exposed from the left history sidebar header.
- Reworked macOS Calculator operation input so chained expressions stay visible until equals and are evaluated together with standard precedence. Example: `6+5+9/2+3-5=` now produces `13.5`, and the history row keeps `6 + 5 + 9 ÷ 2 + 3 − 5`.
- Verification passed: `swift build`, `.build/debug/HoverPocket --verify-calculator`, targeted calculator sequences for continuous expressions, decimal precedence, backspace editing, divide-by-zero, `git diff --check`, and `./script/build_and_run.sh --verify`. Details: `progress/2026-07/2026-07-06_hover-menu-preview.md`.

## 2026-07-06 Mac Calculator Sidebar and AI Lane Removal

- Updated macOS Calculator so pending operations are visible in the display area (`5 +`, `5 + 6`, and completed expressions), history results click into the input as a single number, and each history row's restore icon inserts the expression itself such as `5 + 6`.
- Moved Calculator history from an inline strip to a left sidebar with a top-left sidebar toggle. Added numpad keycode handling including keypad Enter for equals.
- Removed the AI command lane from the visible macOS panel and restored panel total height to the provider area only. The AI implementation files remain in the repo for later planning, but the app no longer instantiates or renders the lane.
- Verification passed: `swift build`, `.build/debug/HoverPocket --verify-calculator`, `--calculator-sequence '5+6='`, `--calculator-sequence '12+3=+4='`, `git diff --check`, and `./script/build_and_run.sh --verify`. Details: `progress/2026-07/2026-07-06_hover-menu-preview.md`.
- Released build `119` as notarized/stapled macOS ZIP. `notarytool` submission `2983802e-460f-490b-93c8-d0dcab3df943` returned `Accepted`; GitHub Release `v0.1.0-119` is GitHub Latest and `macos-latest` assets now point to build `119`. Remote readback confirmed stable and legacy appcasts both report `sparkle:version=119`, stable ZIP SHA256 `afc547f8b8def559a638483e79e6a8232df48ad18a48c21003aa1a509720b8b4`, extracted app `CFBundleVersion=119`, macOS feed URL, and `codesign` / `stapler validate` / `spctl`. LINE-share ZIP copied to `~/Downloads/HoverPocket-macOS-app-119.zip`.

## 2026-07-06 Mac Sparkle Update Popup Foregrounding

- Updated macOS Sparkle integration so manual update checks from Settings, the menu bar, or the provider header activate HoverPocket and bring Sparkle update/status windows to the front.
- The foregrounding window is bounded to user-initiated checks only; the launch-time update probe still updates the in-panel badge/status without stealing focus.
- Verification passed: `swift build`, `git diff --check`, and `./script/build_and_run.sh --verify`. Details: `progress/2026-07/2026-07-06_hover-menu-preview.md`.
- Released build `117` as notarized/stapled macOS ZIP. `notarytool` submission `715e3a67-4c6f-4bb7-94b5-5970fd6af407` returned `Accepted`; GitHub Release `v0.1.0-117` is GitHub Latest and `macos-latest` assets now point to build `117`. Remote readback confirmed stable and legacy appcasts both report `sparkle:version=117`, stable ZIP SHA256 `b3031f5cfac919a7eff91e3e7023fd96911725353a8a5e4aee9c1d89e6928dae`, extracted app `CFBundleVersion=117`, macOS feed URL, and `codesign` / `stapler validate` / `spctl`.

## 2026-07-06 OAuth Public Verification Console Execution

- Enabled GitHub Pages for `site/` through `.github/workflows/pages.yml`, manually dispatched the workflow after Pages creation, and verified public readback for `https://shotaro311.github.io/hover-pocket/`, `privacy.html`, and `googlea0eda7d7223f8019.html`.
- Completed Search Console ownership verification for both `https://shotaro311.github.io/hover-pocket/` and the root `https://shotaro311.github.io/`. Created the auxiliary public repo `shotaro311/shotaro311.github.io` so the root verification file can remain available.
- Kept the existing Google Cloud project `hoverpocket`: project is active, `shotaro.matsu0311@gmail.com` is a project owner, and no separate Google Cloud project is needed for this app.
- Updated Google Auth Platform: Branding has `HoverPocket`, support/contact email, privacy URL, authorized domain `shotaro311.github.io`, and root homepage URL `https://shotaro311.github.io/` because the original `/hover-pocket/` homepage failed Google's branding ownership check. Audience is External / In production. Data Access is saved with `calendar.calendarlist.readonly` and `calendar.events` only.
- Reached `Prepare for verification`. Final submit remains blocked by Google's required YouTube demo video field; the scope reason text is prepared but cannot be saved in the form until a YouTube video URL is supplied. Details: `progress/2026-07/2026-07-06_hover-menu-preview.md`.

## 2026-07-06 Mac Calculator History and macOS Feed Split

- Updated macOS release packaging so distribution builds embed the macOS-only Sparkle feed `https://github.com/shotaro311/hover-pocket/releases/download/macos-latest/appcast.xml`. `publish_github_release.sh` now marks versioned macOS releases as GitHub Latest for old builds that still read `latest/download/appcast.xml`, and also syncs `HoverPocket-macOS-app.zip` / `appcast.xml` to the stable `macos-latest` release.
- Fixed notch-origin panel expansion by centering the final preview frame on the detected notch center instead of always using screen midpoint. This keeps the collapsed and expanded panel center aligned on notched MacBooks.
- Added Calculator history on macOS: result history rows, result click-to-input, and per-row restore to the captured calculation state. Keyboard handling now reads shifted characters such as `+`, `*`, `%`, and symbolic `×` / `÷`.
- Verification passed: `swift build`, `bash -n` for release scripts, `.build/debug/HoverPocket --verify-calculator` plus chain / percent / divide-by-zero sequences, `git diff --check`, and `./script/build_and_run.sh --verify`. Non-notarized dry-run packaging generated build `111` artifacts with the new `SUFeedURL`.
- Released build `112` as notarized/stapled macOS ZIP. `notarytool` submission `70397200-f50b-4dfb-a0b1-2a51821f7904` returned `Accepted`; versioned release `v0.1.0-112` and stable macOS feed release `macos-latest` are published. Remote readback confirmed `macos-latest/appcast.xml` and legacy `latest/download/appcast.xml` both report `sparkle:version=112`, the stable ZIP SHA256 is `b13fda6a78544fb27c5cb03f1ad67ccd060bfb3028bcd08643d8fca49df86eb2`, extracted app `CFBundleVersion=112`, `SUFeedURL=https://github.com/shotaro311/hover-pocket/releases/download/macos-latest/appcast.xml`, and `codesign` / `stapler validate` / `spctl` all pass.

## 2026-07-06 Windows Calculator History and Feed Separation

- Implemented Windows Calculator keyboard normalization for normal keys, shifted operator input, and numpad-equivalent tokens on both the WebView key handler and C# engine boundary.
- Added Calculator history to the Windows bridge/UI. History is stored chronologically in the C# engine; clicking a history result puts that value into the current input, and the restore button restores display plus accumulator, pending operation, entering-new-value flag, last operation, and last operand.
- Explicitly pinned Windows updates to Velopack channel `win` / `releases.win.json`, added updater verifier metadata checks, and updated Windows release packaging docs/script output so Windows releases use `win-v...` tags with `--latest=false` and read back Windows feed separately from the macOS `macos-latest` appcast.
- Verification completed: `dotnet build windows\HoverPocket.Windows.sln --nologo -p:NuGetAudit=false`, `dotnet run --project windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify calc`, `--verify ui-model`, `--verify updater`, `node --check windows/ui/providers/calculator/calculator.js`, Windows feed readback for `win-v0.2.1/releases.win.json`, macOS appcast readback for `macos-latest/appcast.xml`, and `git diff --check`. Details: `progress/2026-07/2026-07-06_windows-calc-history-feed.md`.
- Windows-side commit `e4dcaf3` was pushed to `origin/main` after rebasing on the macOS build `112` log. Final Windows status was clean.

## 2026-07-06 Cross-platform Agent Read Gate

- Added root `AGENTS.md` so Codex and other repo-aware AI agents have a mandatory entrypoint before implementation. It points agents to `progress/progress.md`, `docs/requirement/requirements.md`, and the OS-specific README/script files.
- Added `docs/requirement/requirements.md` section `1.4 Mac / Windows 横断ワークフロー` to keep the existing docs structure instead of introducing a separate `product.md`. It defines OS ownership, shared-spec flow, release feed separation, and readback completion gates.

## 2026-07-06 W14 OAuth Public Pages and User Steps

- Added GitHub Pages-ready static pages under `site/`: `index.html` for the app homepage and `privacy.html` for the Japanese/English privacy policy. The policy reflects the current Windows behavior: Google refresh tokens in Windows Credential Manager, local app data under `%APPDATA%\HoverPocket`, Clipboard Private mode and Clear, Sticky Notes delete/archive distinction, AI lane minimal audit metadata with 90-day pruning, and GitHub Releases as the update source.
- Added `docs/report/20260706-oauth-scope-justification.md` using W13's final scopes: `calendar.events` plus `calendar.calendarlist.readonly`. Legacy `calendar.readonly` is documented only as an accepted existing-token compatibility case, not as a new Cloud Console scope.
- Added `docs/plan/20260706-google-cloud-console-steps.md` with user-run steps for GitHub Pages, Search Console ownership verification, Google Auth Platform Branding/Audience/Data Access, and Prepare for verification. Recommended Pages path is GitHub Actions deploying `site/` because branch publishing supports only `/` or `/docs`. Details: `progress/2026-07/2026-07-06_oauth-docs-w14.md`.

## 2026-07-06 W13 Windows OAuth Review Prep

- Changed Windows Google OAuth configuration loading to prefer build-time embedded `AssemblyMetadata`, then `%APPDATA%\HoverPocket\oauth.json`, then the existing missing-configuration state. `publish_release.ps1` now passes `HOVERPOCKET_GOOGLE_CLIENT_ID` / `HOVERPOCKET_GOOGLE_CLIENT_SECRET` to `dotnet publish` as MSBuild properties without printing values, and `.gitignore` excludes build outputs and local secret JSON.
- Google official Calendar API docs confirm `calendar.events` alone cannot call CalendarList.list. Requested scopes are minimized from `calendar.events` + `calendar.readonly` to `calendar.events` + `calendar.calendarlist.readonly`; legacy stored credentials with `calendar.readonly` remain accepted because Google still authorizes CalendarList.list with that broader scope.
- Verification: `dotnet build windows\HoverPocket.Windows.sln --nologo -p:NuGetAudit=false`, `--verify calendar`, `--verify ui-model`, dummy embedded-property `--verify calendar`, final normal rebuild, and `git diff --check` all completed with exit code 0 and build warnings 0. WebView2 `--verify ui` remains architect desktop-session follow-up. Details: `progress/2026-07/2026-07-06_windows-oauth-w13.md`.

## 2026-07-06 W12 Windows Security Review Fixes

- Fixed security review F-1/F-2/F-3 for the Windows build. DevTools and default WebView2 context menus now enable only in Debug builds or with explicit `--devtools`; Release without the flag disables both. Panel and Settings WebView2 now block navigation outside their virtual hosts and route external `http(s)` URLs to the OS default browser while suppressing all `NewWindowRequested` popups.
- Minimized AI lane audit JSONL to `timestamp` / `action` / `actionType` / `result` / `eventId` / `calendarId`, removed action id, field keys, title, location, notes, command text, and free-form failure reason text, and added 90-day write-time pruning for old daily audit files.
- Verification: `dotnet build windows\HoverPocket.Windows.sln --nologo -p:NuGetAudit=false`, `dotnet build windows\HoverPocket.Windows.sln --nologo -c Release -p:NuGetAudit=false`, `--verify ailane`, `ui-model`, `settings`, `shell`, Release `--verify settings`, and `git diff --check` completed with exit code 0 and build warnings 0. `--verify ui` remains architect desktop-session follow-up because this sandbox cannot launch the WebView2 renderer. Details: `progress/2026-07/2026-07-06_windows-security-w12.md`.

## 2026-07-06 W11 Velopack Windows Updates

- Implemented Windows Phase 2 W11 Velopack updater and release packaging: `VelopackApp.Build().Run()` now runs from `Program.Main` except verify/probe paths, updater checks GitHub Releases `shotaro311/hover-pocket`, tray and Settings `Check for Updates` are wired, startup auto-check defaults on and is non-blocking, and `--verify updater` covers local-folder no-update/update-available dry-runs.
- Added `windows/script/publish_release.ps1` for `dotnet publish` self-contained `win-x64` plus `vpk pack`, generated `HoverPocketWin-*` assets, and printed a `gh release upload` command example without uploading. README documents unsigned Phase 2 SmartScreen warnings and keeps signing credentials out of Git/log/progress/README.
- Verification: `dotnet build` completed with warnings 0/errors 0; `--verify updater`, `ui-model`, `settings`, `ailane`, `sticky`, `calc`, `timer`, `display`, `clipboard`, `calendar`, and exe-based `shell` all completed with exit code 0; JS syntax checks completed with exit code 0; publish dry-run generated the Windows Velopack assets under `dist/windows/releases/0.2.0/`. Real GitHub update apply/restart and WebView2 runtime checks remain architect/user follow-up. Details: `progress/2026-07/2026-07-06_windows-phase2-w11.md`.

## 2026-07-06 W9 Clipboard Provider

- Implemented Windows Phase 2 Clipboard provider: `AddClipboardFormatListener` / `WM_CLIPBOARDUPDATE` monitoring while provider visibility is ON, text 30 / image 20 history limits, PNG normalization, SHA-256 image deduplication, `%APPDATA%\HoverPocket\clipboard\history.json` + PNG persistence, corrupt JSON fallback, private mode, click-to-copy, clear all, and C# `DoDragDrop` external drag payloads.
- Added Clipboard WebView UI under `windows/ui/providers/clipboard/` with text/image history lists, private mode status/button, clear action, copy-on-click, and mouse-down drag handles. Settings now exposes Clipboard private mode plus the ja/en confidentiality note.
- Shared files were limited to provider registration, bridge registration, `--verify clipboard`, panel hide notification for external drag, Settings/app/i18n wiring, and ui-model coverage.
- Verification: `node --check` for `app.js` / `settings.js` / `clipboard.js`, `dotnet build windows\HoverPocket.Windows.sln --nologo -p:NuGetAudit=false`, `--verify clipboard`, `--verify ui-model`, and `git diff --check` completed with exit code 0. Initial plain build hit an existing `HoverPocket.Shell` file lock, then succeeded after the required wait; plain NuGet audit emitted `NU1900` while `api.nuget.org` was unreachable.
- WebView2 hands-on Clipboard UI, long-running real clipboard listener, and external app drop remain architect desktop-session confirmation. Details: `progress/2026-07/2026-07-06_windows-phase2-w9.md`.

## 2026-07-06 W10 Google Calendar Provider

- Implemented Windows Phase 2 Google Calendar provider: Desktop-app OAuth with loopback redirect + PKCE S256, external `%APPDATA%\HoverPocket\oauth.json` client configuration, refresh-token storage in Windows Credential Manager, in-memory access tokens only, Calendar API v3 REST calendar/event read and CRUD, 42-cell month grid UI, read-only calendar guards, and AI lane calendar read/create connection through the existing approval flow.
- Scope choice is `calendar.events` plus `calendar.readonly`: event CRUD requires `calendar.events`, while calendar list/read-only metadata requires `calendar.readonly`; this keeps the Windows provider narrower than full calendar account access.
- Credential storage choice is Win32 `CredWrite` / `CredRead` / `CredDelete` generic credentials instead of `PasswordVault`, because the task requires Windows Credential Manager verification and direct cleanup of verification entries.
- Verification: `dotnet build windows\HoverPocket.Windows.sln --nologo -p:NuGetAudit=false`, `--verify calendar`, `--verify ailane`, `--verify ui-model`, JS syntax checks, and `git diff --check` completed with exit code 0. The previous default-output file lock cleared and the standard build now passes with warnings 0 / errors 0.
- Real Google account E2E is waiting for architect/user after placing `%APPDATA%\HoverPocket\oauth.json`. Details: `progress/2026-07/2026-07-06_windows-phase2-w10.md`.

## 2026-07-06 W8 Hover Open/Close Stability

- Fixed the hover controller path so an already-visible panel no longer re-opens or re-anchors from cursor polling, and display resync preserves the display chosen when the panel opened.
- Unified close detection around the active access-surface/panel physical rectangles inflated by +4 DIPs converted per monitor scale, with optional `HOVERPOCKET_HOVER_TRACE` file tracing.
- Extended `--verify shell` with simulated pointer checks for stable panel `Left/Top` while moving inside the panel and close after simulated pointer leaves the active hover region.
- Verification: `dotnet build windows\HoverPocket.Windows.sln --nologo --no-restore`, expanded `--verify shell`, and existing `--verify display` / `ui-model` / `calc` / `timer` / `sticky` / `settings` / `ailane` all completed with exit code 0. `--verify shell` reported `stable_position=true` and `outside_close=true`. Real mouse feel remains user-confirmation pending. Details: `progress/2026-07/2026-07-06_windows-bugfix-w8.md`.

## 2026-07-06 W6 Sticky Trash Drop Bugfix

- Fixed Sticky Notes bottom trash drop archiving. The cause was re-rendering the board/trash DOM during Chromium/WebView2 HTML5 drag, which could replace the active drop target before `drop` fired.
- Separated internal panel drag from external drag: note body/card drag now handles reorder and trash archive inside the panel, while external app drag remains on the dedicated top-right export handle through C# `DoDragDrop`.
- Added `sticky.archiveDropped` and `StickyNotesStore.ArchiveDroppedNote()` so `--verify sticky` covers the trash-drop archive state transition plus undo.
- Verification: `node --check windows/ui/providers/sticky/sticky.js`, `dotnet build windows\HoverPocket.Windows.sln --nologo`, `--verify sticky`, `--verify ui-model`, and `git diff --check` completed with exit code 0. WebView2 hands-on drag/drop remains user/architect desktop-session confirmation.

## 2026-07-05 W5 Integration Turn

- Resolved the Windows Phase 1 integration blockers from W5: Calculator/Timer bridge handlers are now registered from `PanelBridgeController.Attach()`, Timer alerts now select the Timer provider, open the panel automatically, and statically highlight the access mini-bar.
- Fixed the self-evident AI lane verifier regression where `14時` was parsed as `4時`.
- `dotnet build windows\HoverPocket.Windows.sln --nologo` completed with exit code 0, warning 0, error 0.
- Final verify exit codes: `shell=0`, `display=0`, `ui-model=0`, `calc=0`, `timer=0`, `sticky=0`, `settings=0`, `ailane=0`.
- WebView2 runtime checks (`--verify ui`, Settings actual window launch) remain architect desktop-session verification items.

## 2026-07-05 W7 Settings + AI command lane

- Implemented Windows Phase 1 W7 Settings and AI command lane frame: Settings window, HKCU Run key service, settings verifier, deterministic AI stub, approval flow, audit JSONL, and AI lane UI.
- W7 JS syntax checks passed with exit code 0 for app.js, ailane.js, settings.js, and i18n.js.
- dotnet build and --verify settings / --verify ailane / --verify ui-model stopped before runtime because W5 Calculator has 3 compile errors. See progress/2026-07/2026-07-05_windows-phase1-w7.md.
- Follow-up: exposed Sticky Notes Undo toast in Settings using the Sticky store as source of truth. Grid size remains provider-local because W6 already exposes S/M/L there. dotnet build and --verify settings / sticky / ui-model / ailane are now exit code 0.

# Project Progress: ホバーポケット

## 概要

- `ホバーポケット` は、macOS 画面上部へホバーすると、ミラー、Controls、Google Calendar、Clipboard 履歴、Sticky Notes を素早く開ける macOS app。
- `/Users/shotaro/Documents/Codex/.../outputs/hover-menu-preview` で作成した prototype を、開発継続用に `/Users/shotaro/code/share/hover-menu-preview` へ移行済み。

## 最新の検証済み状態

- 2026-07-05: Windows Phase 1 W5 Calculator + Timer provider を実装し、統合ターンで共有基盤への接続まで完了。`Providers/Calculator/` に C# `CalculatorEngine` / bridge handler / verifier、`Providers/Timer/` に `%APPDATA%\HoverPocket\timer\` 永続化の Timer store / bridge handler / verifier、`windows/ui/providers/calculator/` と `windows/ui/providers/timer/` に Web UI を追加。`PanelBridgeController.Attach()` へ Calculator/Timer bridge handlers を登録し、Timer 終了時のパネル自動表示・Timer provider 選択・ミニバーハイライトを追加。`dotnet build windows\HoverPocket.Windows.sln --nologo` は exit code 0 / 警告 0、`--verify shell` / `display` / `ui-model` / `calc` / `timer` / `sticky` / `settings` / `ailane` はすべて exit code 0。WebView2 実行系検証はアーキテクト通常 desktop session 実行待ち。詳細は `progress/2026-07/2026-07-05_windows-phase1-w5.md`。
- 2026-07-05: Windows Phase 1 W6 Sticky Notes provider を実装。`Providers/Sticky/` に C# model/store/bridge/verifier、`windows/ui/providers/sticky/` にボードグリッド、inline editor、色、S/M/L、drag reorder、下部 archive drop、右クリックメニュー、Undo toast、C# `DoDragDrop` 起点の外部ドラッグ入口を追加。共有ファイルは sticky descriptor、`--verify sticky` 分岐、app.js renderer 登録、sticky bridge handler 登録のみ追記。`dotnet build windows\HoverPocket.Windows.sln` は exit code 0 / 警告 0、`--verify sticky` と `--verify ui-model` は exit code 0、JS 構文チェックと `git diff --check` も exit code 0。WebView2 実行系の Sticky UI 操作確認と外部ドラッグ実アプリ drop はアーキテクト通常 desktop session 実行待ち。詳細は `progress/2026-07/2026-07-05_windows-phase1-w6.md`。
- 2026-07-05: Windows Phase 1 W4 差し戻し対応。アーキテクト通常 desktop session の `--verify ui` で発覚した `ExecuteScriptAsync` 戻り値 decode バグを修正。`RunWebVerifyScriptAsync()` の `Deserialize<string>` 二重エンコード前提を削除し、JS 側の verify 結果を `window.__hoverPocketVerifyResult` に置いたうえで C# が `UiWebVerifyResult` として直接 deserialize する形へ統一。同種点検で `ExecuteScriptAsync` 使用箇所は `PanelWindow.cs` のみ、二重エンコード前提は残っていない。アーキテクト追加の `VerifyConsole` `HOVERPOCKET_VERIFY_LOG` は維持。`dotnet build windows\HoverPocket.Windows.sln` は exit code 0 / 警告 0、`--verify shell` / `--verify display` / `--verify ui-model` は exit code 0。修正後の `--verify ui` はアーキテクト通常 desktop session 実行待ち。詳細は `progress/2026-07/2026-07-05_windows-phase1-w4.md`。
- 2026-07-05: Windows Phase 1 W4 WebView2 統合基盤を実装。`PanelWindow` に WebView2 host(透明背景、virtual host mapping、NOACTIVATE/TOOLWINDOW、`WM_MOUSEACTIVATE -> MA_NOACTIVATE`、rounded HWND region)を追加し、`windows/ui/` に bundler なしの HTML/CSS/ES modules、C# `Bridge/` dispatcher、JS `bridge.js`、provider header、placeholder provider registry 3枠、`%APPDATA%\HoverPocket\settings.json` store、`--verify ui` / `--verify ui-model` を追加。`dotnet build windows\HoverPocket.Windows.sln` は exit code 0 / 警告 0。`HoverPocket.Shell.exe --verify ui-model`、`--verify shell`、`--verify display` は exit code 0。`--verify ui` は sandbox 内 WebView2 初期化で `COMException E_UNEXPECTED` のため exit code 1、計画書 A4 に従いアーキテクト通常 desktop session 実行待ち。詳細は `progress/2026-07/2026-07-05_windows-phase1-w4.md`。
- 2026-07-05: Windows Phase 0 W3 candidate C risk spikes を `windows/spikes/HoverPocket.Spikes.sln` として本体 sln から分離して追加。S1 WebView2 x NOACTIVATE transparent overlay、S2 Clipboard listener + PNG 正規化 + drag payload、S3 WebView2 getUserMedia camera を実装。`dotnet build windows\spikes\HoverPocket.Spikes.sln --no-restore` は exit code 0 / 警告 0。S2 `--verify` は exit code 0。S1/S3 は WebView2 Runtime `150.0.4078.48` を検出したが、baseline から `RenderProcessExited:LaunchFailed` / `GpuProcessExited:Crashed` で exit code 1。候補Cは未確定、通常 desktop session での S1/S3 再検証が必要。詳細は `docs/report/20260705-windows-candidate-c-spike-findings.md` と `progress/2026-07/2026-07-05_windows-phase0-w3.md`。
- 2026-07-05: Windows Phase 0 W2 multi-monitor / mixed DPI 対応を追加。`--display-placement <main|sub|all>`、`ShellSettings`、`DisplayLayoutService`、複数 access surface、`Sub` のサブなし fallback、`WM_DISPLAYCHANGE` / `WM_DPICHANGED` / display settings / sleep resume hook による再同期、`--verify display` を実装。現在の検証環境は monitor count `1`。`dotnet build windows\HoverPocket.Windows.sln`、`dotnet run --project windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify shell`、`dotnet run --project windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify display` はすべて exit code 0、build 警告 0。追加で `--display-placement sub --verify display` と `--display-placement all --verify display` も exit code 0。実マルチモニター / mixed DPI / display hotplug / sleep wake 実機手動確認は未実施。
- 2026-07-05: Windows Phase 0 W1 shell spike を追加。`windows/HoverPocket.Windows.sln` + WPF `HoverPocket.Shell` で tray、top-edge access surface、NOACTIVATE panel、hover open/close、多重起動防止、Per-Monitor V2 manifest、`--verify shell` を実装。`dotnet build .\windows\HoverPocket.Windows.sln` と `dotnet run --project .\windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify shell` はどちらも exit code 0、警告 0。手動 hover E2E は未検証。
- 移行元 prototype は `./script/build_and_run.sh --verify` 成功済み。
- 移行先 `/Users/shotaro/code/share/hover-menu-preview` で `./script/build_and_run.sh --verify` 成功済み。
- 2026-06-03: 上部 pill の 5pt top inset を削除し、`CGWindowListCopyWindowInfo` で `Y = 0` を確認済み。
- 2026-06-03: preview panel の opening animation を追加し、`optionOnScreenOnly` の frame sampling で `h=199 -> 267 -> 297 -> 308 -> 312` への拡大を確認済み。
- 2026-06-03: pill を top corners square / bottom corners rounded の top-docked shape に変更し、window 切り出しで確認済み。
- 2026-06-03: pill height を 33pt に伸ばし、下端の細い隙間を抑えたことを切り出し画像と window frame で確認済み。
- 2026-06-03: notch sizing と `33pt = safeAreaInsets.top + 1pt` の設計メモを `README.md` に記録済み。
- 2026-06-03: 二段階の `neck / elastic overshoot` animation はもっさり見えたため撤回し、直前の `source -> final` のシンプルなノッチ中央 morphing に戻したことを確認済み。
- 2026-06-03: preview close animation を open と同じ `0.32s` にし、timing curve も open の逆カーブにして、開く動きの逆再生として閉じることを frame sampling で確認済み。
- 2026-06-03: top pill の text / session count 表示を消し、ノッチ左側の小さい `arrow.right` handle だけを表示する状態に変更済み。
- 2026-06-03: `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` から実ノッチ幅を取り、left handle 右端をノッチ左端へ揃えて、ノッチ裏まで黒い UI base を敷くように変更済み。
- 2026-06-03: top pill の shadow を無効化し、上端 `3pt` を黒で overfill して、上部の細いスリット状の抜けを埋めたことをピクセル検査で確認済み。
- 2026-06-03: 左上 handle のラウンド形状変更は意図と違ったため撤回し、元の連続した黒ベース形状へ戻したことを確認済み。
- 2026-06-03: `main.swift` の単一ファイル構成を App / Windowing / State / Models / Providers / Views / Support に分割し、今後の追加機能を `NotchProvider` として差し込む土台へ変更。デモ用 sessions / usage 表示は削除済み。
- 2026-06-03: Display placement 設定を追加。`Auto / Main / Sub` で表示先を選べるようにし、ノッチなし画面では fake notch ではなく top-center handle に切り替えるよう変更済み。
- 2026-06-04: Built-in `Mirror` provider を追加し、panel active 中だけ Mac camera を起動する鏡機能を実装。`swift build`、`./script/build_and_run.sh --verify`、`NSCameraUsageDescription`、hover 後 panel onscreen を確認済み。
- 2026-06-04: Mirror hover 時の crash を修正。原因は camera session start と preview layer attach の race。preview layer 常駐化、4秒 warm grace、`vga640x480` preset、OSLog を追加。hover stress 後も process 生存、該当例外なし、close 後 CPU 0% を確認済み。
- 2026-06-04: Mirror close 時の点滅 / 残像対策として、close animation 中は content を維持し、window `orderOut` 後に `contentVisible=false` にする順序へ変更。open / close window state と crash 例外なしを確認済み。
- 2026-06-04: Mirror の軽快化として、見た目の animation は維持したまま、`contentVisible` と provider active state を分離。camera access 許可済みなら app launch 時に session 構成だけ prewarm し、`startRunning()` は hover active 時だけに限定。`.eventDriven` provider の panel open refresh も skip するように変更。`swift build`、`./script/build_and_run.sh --verify`、hover in/out metadata、crash 例外なしを確認済み。
- 2026-06-04: Mirror 表示のカクつき / ちらつき対策を追加。camera preview layer の layout 時に暗黙 Core Animation を無効化し、開閉 animation 中だけ preview window shadow を切るように変更。閉じかけからの再 hover では collapsed frame へ戻さず、現在の frame / alpha から開き直す。live camera への SwiftUI blur も削除。`swift build`、`./script/build_and_run.sh --verify`、idle CPU 0%、crash 例外なしを確認済み。
- 2026-06-04: Mirror が UI 枠より遅れて表示される問題を修正。preview window animation 開始前に `contentVisible=true` を非アニメーションで反映し、ミラー映像が枠の clip と同時に広がるように変更。`swift build`、`./script/build_and_run.sh --verify`、open/close metadata、idle CPU 0%、crash 例外なしを確認済み。
- 2026-06-04: close 時にカメラ映像の残像が残る問題を抑えるため、close animation 開始時点で `providerActive=false` にし、panel 本体より先に camera preview を fade out するように変更。camera preview fade は `0.12s -> 0.06s` に短縮。`swift build`、`./script/build_and_run.sh --verify`、open/close metadata、idle CPU 0%、crash 例外なしを確認済み。
- 2026-06-04: 繰り返し open / close 後にもっさりする体感への処理系対策を追加。close fallback reset task を単一管理して古い task を cancel、`contentVisible` / `providerActive` / camera status の同値 publish を抑制、同一 provider 選択を no-op 化、close delay task の参照を実行後に解放。25 cycle stress 後も pill window 1枚へ復帰し、warm grace 後 CPU 0.0%、crash 例外なしを確認済み。
- 2026-06-04: `GoogleCalendarProvider` を追加。Google installed app OAuth の loopback redirect + PKCE、Keychain token保存、Calendar API `calendarList.list` / `events.list`、月グリッド + 日付hover詳細UI、Settings の connect / disconnect 導線を実装。`swift build`、`./script/build_and_run.sh --verify`、dummy OAuth値の `Info.plist` 注入、loopback socket port確保、callback早着対策、setup check、crash 例外なしを確認済み。gcloud / Calendar API は設定済み。`gcloud iam oauth-clients` と既存gcloud tokenではCalendar OAuth検証に使えないことも確認済み。実Googleアカウント取得には OAuth desktop client ID 設定が必要。
- 2026-06-04: `shotaro.matsu0311@gmail.com` のChrome `Default` profileで Google Auth Platform の Desktop OAuth client を作成し、`.env.local` に client ID / secret を保存。実OAuth consent、Keychain保存、Calendar API取得まで検証済み。`./script/verify_google_calendar.sh --force-google-sign-in` は `calendar_sources=5`、`events_in_visible_grid=53`、`days_with_events=37`、`today_events=3`。保存済み認証での再取得も `used_login_flow=false` で成功。`./script/build_and_run.sh --verify`、`git diff --check`、起動後 `CPU 0.0%`、直近crash例外なしを確認済み。
- 2026-06-07: Google Calendar の日付クリック詳細固定、予定追加、編集、削除 UI と Calendar API 書き込み処理を追加。OAuth scope を `calendar.events` に変更し、古い read-only credential は再接続が必要な状態として扱うようにした。`swift build`、`./script/check_google_calendar_setup.sh`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。実Googleアカウントの write scope 追加同意は OAuth callback 待ちで未完了。
- 2026-06-07: Clipboard provider を追加。テキスト/画像 clipboard 履歴、画像の Application Support 保存、クリック再コピー、外部アプリへの drag/drop provider を実装。provider の表示/非表示、順番、最後に開いた panel / default panel 設定を追加。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。起動後 CPU 0.0% を確認。
- 2026-06-07: Codex chat 欄への画像 drag/drop が効かない報告を受け、drag 開始直後に hover panel を一時非表示にし、画像 drag payload を file URL 起点の `NSItemProvider` に変更。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- 2026-06-07: Mirror provider に A案ベースの compact microphone check row を追加。設定で表示/非表示を切替可能。Mirror microphone row 表示中は `AVAudioEngine` で meter を自動起動し、panel 非表示/非active/設定OFFで停止。button は一時録音用に変更し、`録音 -> 停止 -> 再生 -> 再生完了後にメモリから削除` の流れにした。audio file は作成しない。`NSMicrophoneUsageDescription` を generated app bundle に追加。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- 2026-06-07: 一時的なアプリ名で GitHub public repository へ push。現在の正式名称は `ホバーポケット` / `HoverPocket`。
- 2026-06-07: README を日本語中心へ全面更新。概要、機能、実行方法、Google Calendar 設定、表示先、実装メモ、ノッチサイズ、注意事項を日本語で読めるようにした。
- 2026-06-08: パネルを開いたまま provider アイコンを切り替えると機能だけ切り替わりアイコン選択状態が更新されない問題を修正。ヘッダーを `ProviderStore` 監視の `ProviderHeaderView` に分離。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- 2026-06-08: GitHub Actions `Codex PR Router` を追加。PR作成/更新/レビュー時に変更ファイルを分類し、Mac worker 向け origin / autofix / human merge / docs-only auto-merge safe ラベルを付ける。trusted author の docs-only PR だけ auto-merge 有効化を試みる。
- 2026-06-08: `github-codex-autofix` plugin を Mac / Windows 両方へ配置。Mac / Windows Codex Automation を毎日 10:00 / 12:00 / 15:00 / 18:00 / 21:00 に設定し、対象PRがない場合は軽量チェックだけで終了する運用にした。
- 2026-06-08: 実PR `#1` で `Codex PR Router` のラベル付与、Mac helper の対象PR検出、claim / release、Windows helper の Mac向けPR除外を確認。`.github/*.md` の docs-only 誤判定も修正し、Mac / Windows plugin へ反映済み。
- 2026-06-08: PR `#2` で表示領域サイズを `小 / 中 / 大` の3段階に切り替える機能を追加。Settings とパネル見出し右側の `小 中 大` ボタンから変更でき、表示中のパネルはイージング付きで `456 x 326pt / 520 x 372pt / 600 x 430pt` にリサイズされることを実ウィンドウフレームで確認済み。
- 2026-06-08: PR `#2` の追加修正として、ヘッダーのサイズ表示を現在サイズ1文字だけに変更。サイズ変更時は上端 `Y = 33` を維持することを実ウィンドウフレームで確認。今後のPR作成運用も Mac / Windows ともに Draft ではなく Ready PR 前提へ変更済み。
- 2026-06-09: 上部ヘッダー右端の電源アイコンを廃止し、provider アイコン群と設定ボタンの間に薄い縦線の仕切りを追加。Settings で `Icon switching` を `Click / Hover` から選べるようにし、`Hover` ではアイコンにポインタを重ねた時点で provider が切り替わる。追加でヘッダーUIを `ProviderHeaderView.swift` へ分離し、`ProviderStore` の設定監視を provider 構成関連に限定。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- 2026-06-09: Google OAuth の Keychain 許可ダイアログが毎回出る問題を調査し、Calendar Store 初期化時の Keychain 読み込みを廃止。Calendar を開く / Connect を押すタイミングまで認証確認を遅延。`script/build_and_run.sh` で利用可能な `Apple Development` 署名IDを自動検出して app bundle を安定署名するよう変更。`codesign` で ad-hoc ではなく Apple Development 署名を確認済み。
- 2026-06-09: アプリ名を正式名称の `ホバーポケット` / `HoverPocket` へ変更。SwiftPM package / executable / generated app bundle / README / OAuth callback page / permission descriptions を更新。source path を `Sources/HoverPocket` へ移し、provider protocol を `PocketProvider` に改名。旧保存先からの Keychain service と Clipboard 保存先の移行は維持。GitHub repository slug と local `origin` は `shotaro311/hover-pocket` へ変更済み。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。generated app bundle は `HoverPocket.app`、bundle ID は `local.codex.hover-pocket`。
- 2026-06-09: MIT License を `LICENSE` として追加し、README に `License` セクションを追加。ソースコードは MIT License、`ホバーポケット` / `HoverPocket` の名称・ロゴ・ブランド表示の商標的利用は別扱いであることを明記。`git diff --check` 成功。
- 2026-06-10: AI native Phase 1 MVP を `feature/ai-native-phase1` で実装。Apple Foundation Models provider、`PocketAction` / `ToolResult` / `IntentPlan` / `ApprovalGate` / `AuditLog`、Calendar read/write tool、下段 command palette lane、構造化 action 由来の承認 UI、解釈候補 fallback UI を追加。`swift build` 成功。Ollama、Codex harness、Clipboard Tool、マルチステップ自律実行、チャット履歴は未実装。
- 2026-06-10: AI native Phase 1 の review fix として、ApprovalCard が全 `approvalFields` を表示するよう修正。`PocketAction.requiresApproval` を `kind` 由来の computed property に変更し、Calendar write は常に承認必須にした。`swift build` 成功。
- 2026-06-15: AI command palette の自動フォーカス、Apple Foundation Models `@Generable` structured output 経路、Calendar write 承認 summary、Calendar editor の手入力/ドラッグ調整対応日時入力、日付セルのダブルクリック新規予定起動を追加。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。Computer Use では hover panel を開くイベント再現ができず、実画面確認は未完了。
- 2026-06-15: Product Compass レポートを生成し、6/22 の伊勢田さん向け検証を「Calendar を開かず予定を見る・追加する」に絞った。AI command deterministic fallback は `今日の予定`、`明日14時 打ち合わせ`、`金曜 デザイン納期`、`来週月曜10時 撮影 場所: 天神` を安定して扱う方向へ強化。承認 summary は場所/メモも先に見える形へ調整し、6/22 観察チェックリストを追加。
- 2026-06-15: ZIP配布検証用に `script/package_zip.sh` を追加。Developer ID Application 署名、hardened runtime、versioned Info.plist、OAuth secret 非埋め込みで `dist/releases/HoverPocket-0.1.0-30.zip` を作成し、ZIP展開後の起動確認まで成功。notarization は未実施のため一般配布前に必要。
- 2026-06-15: Sparkle 2.9.3 を導入し、Settings に `Check for Updates` を追加。GitHub Releases latest appcast URL と Sparkle EdDSA 公開鍵を app bundle に注入し、`script/generate_appcast.sh` / `script/publish_github_release.sh` で ZIP / SHA256 / appcast を配信できる土台を追加。初期配布では delta update を無効化し、フルZIP更新だけを appcast に載せる。
- 2026-06-15: Sparkle 更新確認の公開前エラーを修正。ローカル開発ビルドでは未公開の GitHub appcast URL を自動注入せず、配布ビルドでも手動更新確認前に appcast 取得可否を確認して、404 では Sparkle 汎用エラーではなく Settings の状態表示に留める。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify`、`./script/package_zip.sh` 成功。
- 2026-06-15: Calendar 日時セグメントの数値調整UIは A案のインライン目盛りバーを採用。フォーカス中の数値に黄色枠を出し、直下に目盛り付きルーラーと黄色ノブを表示して、バー自体も左右ドラッグで調整できるようにした。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- 2026-06-15: Calendar 日時セグメントの調整バーが小さく操作しづらかったため、目盛り幅、バー高さ、ノブサイズ、ドラッグ判定領域を拡大。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- 2026-06-15: Calendar 調整バー表示時に日時フィールドの横位置が崩れないよう、バーの横幅を通常レイアウト計算から外してオーバーレイ表示へ変更。ドラッグ中のノブは連続移動にし、バー上のマウススクロールでも日時を調整できるようにした。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- 2026-06-15: Calendar 調整バーは選択数字の直下へ移動させず、日時入力レーン内の固定位置に1つだけ表示する仕様へ変更。対象数字は黄色枠で示す。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- 2026-06-15: Calendar 表示初期のラグ対策として、保存済みGoogle認証の確認中でもCalendar本体を先に表示する `restoring` 状態を追加。予定データ取得前でも空の日付グリッドを即描画し、Google Calendar取得は背後で更新するようにした。空グリッドの月単位キャッシュと DateFormatter 生成削減も実施。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- 2026-06-15: Google Cloud に HoverPocket 専用 project / OAuth consent app を作成し、Google Calendar API を有効化。`shotaro.matsu0311@gmail.com` を test user に追加し、iOS OAuth client + custom URL scheme + PKCE + `ASWebAuthenticationSession` のネイティブ認証フローへ変更。生成 app bundle には iOS OAuth client ID / URL scheme のみ入り、Desktop OAuth client secret は通常入らない。`./script/verify_google_calendar.sh --force-google-sign-in` と保存済み credential 再取得が成功。
- 2026-06-19: 決定アプリアイコンを `Resources/AppIcon.png` として追加し、`script/build_and_run.sh` で `AppIcon.icns` を生成して `CFBundleIconFile=AppIcon` を app bundle に入れるようにした。Mirror は4秒遅延停止と再ホバー起動が競合しても、古い停止完了後に active intent が残っていれば自動再起動するよう修正。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。実マウス移動の hover open / close 5サイクルで毎回 preview が開き、最後の再openも成功。
- 2026-06-19: 一般配布向けに `script/notarize_release.sh` を追加。ZIP作成、notarytool submit/wait、staple、spctl検証、staple後の再ZIP、SHA256 / appcast 再生成を1コマンド化した。`publish_github_release.sh` も既定で notarization を通し、既存ZIP利用時は展開後に `stapler validate` / `spctl` で未notarized ZIPを拒否する。`bash -n` と認証情報未設定時の安全な停止は確認済み。
- 2026-06-20: `hover-pocket` notarytool Keychain profile を作成し、`NOTARYTOOL_PROFILE=hover-pocket ./script/notarize_release.sh` で Apple notarization を実行。submission `dd941d6b-7078-4d6a-94a7-c5a0f8697637` は `Accepted`。`dist/HoverPocket.app` と `dist/releases/HoverPocket-0.1.0-41.zip` 展開後 app の両方で `codesign --verify --deep --strict`、`stapler validate`、`spctl --assess --type execute` 成功。ZIP SHA256 は `362a6fcea234f3faf8b19eb5df625b48594eb573fc3fb5f79a765ff8ffd0986e`。
- 2026-06-20: Sticky Notes drag UX を改善。並び替え中の JSON 保存をドロップ完了時へ寄せ、ホバーウィンドウ外へ出た時点だけ外部ドラッグ閉じ処理を走らせるようにした。空タイトル/本文の新規付箋は確定時に破棄し、ドラッグ中の下部ゴミ箱ドロップでアーカイブできるようにした。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- 2026-06-20: top pill の handle icon を Settings から `B / C / None` で選べるようにした。ノッチに合わせた pill / preview の geometry は変更せず、中央アイコン描画だけを差し替える構成。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- 2026-06-20: top pill のノッチ横 handle area を Settings から表示/非表示に切り替えられるようにした。実ノッチありのときだけ横 handle 幅を外せるようにし、ノッチ本体の黒い領域と preview center は維持する。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- 2026-06-20: 最新コミット `1744fe3` を build `45` として配布。`APP_VERSION=0.1.0 APP_BUILD=45 NOTARYTOOL_PROFILE=hover-pocket ./script/publish_github_release.sh` により notarization/staple、ZIP再生成、GitHub Release `v0.1.0-45` 公開、latest appcast 公開まで完了。remote ZIP の SHA256、Sparkle EdDSA署名、展開後 app の `codesign` / `stapler validate` / `spctl`、build 41 から Settings > Check for Updates 経由で build 45 へ更新されることを確認済み。
- 2026-06-20: README と AI architecture report を現在の `ホバーポケット` / `HoverPocket`、Sticky Notes、AI command lane、notarized GitHub Release、Sparkle 更新済みの状態へ同期。`publish_github_release.sh` の既定 release notes も初回配布向け文言から一般 release 文言へ更新。
- 2026-06-20: GitHub Release の自動生成 Source code ZIP とアプリ配布ZIPの誤認対策として、README に一般ユーザー向け download `HoverPocket-macOS-app.zip` を明記。`publish_github_release.sh` も app-only の alias asset を upload するようにした。ZIP 作成は `ditto --norsrc --keepParent` に切り替え、公開ZIPのトップレベルは `HoverPocket.app` のみにした。
- 2026-06-20: Google OAuth credential は Data Protection Keychain 保存を試したが `errSecMissingEntitlement (-34018)` で保存できないため通常 Keychain に戻した。旧Keychain項目は認証UIなしで読める場合だけ移行し、読めない/重複する古い項目はログイン後の新credentialで上書きする。menu bar status item、Camera / Microphone permission off 時の System Settings CTA、Calendar の Google login CTA も追加。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify`、`./script/verify_google_calendar.sh` 成功。
- 2026-06-20: Camera Privacy 設定で許可した直後にMirrorが復帰しない問題に対応。Camera Settings を開いた後の permission recovery polling と、アプリ復帰時の authorization status 再確認で、許可済みに変わったらその場で camera session を開始するようにした。
- 2026-06-20: コミット `e1b5a5e` を build `53` として配布。notarytool submission `d309c2db-47e2-4db1-b880-73787671cc96` は `Accepted`。staple後に `HoverPocket-0.1.0-53.zip` / `HoverPocket-macOS-app.zip` / appcast を GitHub Release `v0.1.0-53` へ公開し、latest download ZIP のトップレベルが `HoverPocket.app` のみ、SHA256 が `4243fb02dd1eb16ea4deb6d60d50dd2e31c2bbdd0419ef22cc68ce65f32cda0e` であることを確認。
- 2026-06-20: コミット `8a4489d` を build `51` として配布。notarytool submission `17e76b3f-36d5-4caf-b714-474ec42854aa` は `Accepted`。staple後に `HoverPocket-0.1.0-51.zip` / `HoverPocket-macOS-app.zip` / appcast を GitHub Release `v0.1.0-51` へ公開し、latest download ZIP のトップレベルが `HoverPocket.app` のみ、SHA256 が `ca9c21fe9f8be9e4d7517227504e3d72b1a0c71c6285f372a40817cac00cd96b` であることを確認。
- 2026-06-21: UI 言語設定を追加。既定は日本語で、Settings から `日本語` / `English` を切り替え可能。Settings、Calendar、Mirror、Clipboard、Sticky Notes、provider header、status bar menu、AI command lane の主要固定文言を言語設定へ接続。Provider header の機能アイコンを drag & drop で並べ替え可能にした。build `59` を notarized/stapled ZIP として GitHub Release `v0.1.0-59` に公開し、latest appcast が build `59` を指すことを確認済み。
- 2026-06-21: サブディスプレイ向けに控えめなミニバー起点と表示先 `すべて` を追加。サブディスプレイから開いた場合に Mirror provider を非表示にする設定を追加し、既定オフにした。Sparkle の probing update check で更新が見つかった場合だけ、ホバーウィンドウ上部に青い更新アイコンを表示し、クリックで更新 UI を開けるようにした。build `61` を notarized/stapled ZIP として GitHub Release `v0.1.0-61` に公開し、latest appcast が build `61` を指すことを確認済み。
- 2026-06-21: 表示先の `自動` モードを廃止し、既存保存値が `automatic` の場合は `メイン` に移行するようにした。`すべて` 選択時は全ディスプレイの起点ウィンドウを同期時に即前面化し、ノッチなし画面のミニバー反応領域を 520 x 64pt へ拡大。透明ヒット領域全体で開くようにして、上端や横方向からの高速 hover 取りこぼしを減らした。build `63` を notarized/stapled ZIP として GitHub Release `v0.1.0-63` に公開し、latest appcast が build `63` を指すことを確認済み。
- 2026-06-21: ノッチなし画面のミニバー縦ヒット領域を 8pt に縮小し、早く開きすぎる挙動を抑えた。更新アイコン押下後はホバーウィンドウを閉じて Sparkle 更新 UI を見やすくした。Settings を `表示 / 起点表示 / パネル / 機能` へ整理し、メインノッチ左のアイコンエリアはオフ時に横エリア自体を描画しないようにした。build `65` を notarized/stapled ZIP として GitHub Release `v0.1.0-65` に公開し、latest appcast が build `65` を指すことを確認済み。
- 2026-06-22: Controls provider のディスプレイ/サウンド/メディア UI を整列し、外部ディスプレイの DDC/CI VCP `0x10` 輝度制御、YouTube などのブラウザ active tab fallback 認識、倍速ボタンの丸アイコン配置を追加。外部ディスプレイは DDC/CI を先に試し、`DisplayServices` が成功扱いを返して DDC を迂回する問題を修正した。build `73` を notarized/stapled ZIP として GitHub Release `v0.1.0-73` に公開し、latest appcast が build `73` を指すことを確認済み。
- 2026-06-30: Controls のメディア倍速ボタンが UI を止め、倍速操作の成否が UI / 診断で判別できない問題を修正。AppleScript / MediaRemote 操作は background task で実行し、refresh 時は対象ブラウザタブの実 `video.playbackRate` を読み戻す。Dia は `focus browserTab` 経路で対象動画タブへ fallback 操作を当てるが、`--enable-applescript-javascript` なしでは exact `1.1x` を外部から設定できないため、未確認の目標値を反映済みとして表示しない。`--verify-media --set-playback-rate 1.1` は `media_playback_rate_verified=false` / `media_verify=failed` を返し、実反映できない状態を成功扱いしないことを確認。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- 2026-06-30: コミット `ac4eb0b` を build `81` として配信。notarytool submission `88f7efe9-b3ab-460e-8a94-fed9fd3e1352` は `Accepted`。staple後に `HoverPocket-0.1.0-81.zip` / `HoverPocket-macOS-app.zip` / appcast を GitHub Release `v0.1.0-81` へ公開し、latest appcast が build `81` を指すことを確認。公開ZIPの top-level は `HoverPocket.app` のみ、SHA256 は `2d1d7fe8bf434263eedcf84675679b67bdfe547214fce2204353618a77854316`。公開ZIP展開後の `codesign` / `stapler validate` / `spctl` も成功。
- 2026-07-01: Calendar の小サイズ表示で固定幅セルと余白が詳細ペインを押し出す問題を修正。小サイズでは calendar grid / padding / spacing / font を縮小し、月表示は minimumScaleFactor を持たせた。Controls の画面収録サムネイルは受動表示時に `CGRequestScreenCaptureAccess()` を呼ばず、許可済みなら live preview、未許可なら artwork / placeholder へ fallback するよう変更。ScreenCaptureKit 設定では audio / microphone capture を明示 false にした。メディア操作は play/pause と倍速を pending state 付きの直列タスクにし、操作中の stale refresh と連打を抑制。Dia の JavaScript 不可経路では JS readback timeout を避け、YouTube shortcut の 0.25 刻みを UI で `1.25x` のように表示できるようにした。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify`、`--verify-media`、`--set-playback-rate 1.25 -> 1.0` 成功。
- 2026-07-01: コミット `72d8ff9` を build `83` として配信。notarytool submission `5bd53681-39cb-4821-8167-ca7bc4e74241` は `Accepted`。staple後に `HoverPocket-0.1.0-83.zip` / `HoverPocket-macOS-app.zip` / appcast を GitHub Release `v0.1.0-83` へ公開し、latest appcast が build `83` を指すことを確認。公開ZIPの top-level は `HoverPocket.app` のみ、SHA256 は `cb7062eb9a8ce00b65fba56de8e9eb08a1a2c735ec47205310ff7db781ae4dae`。公開ZIP展開後の `codesign` / `stapler validate` / `spctl` も成功。
- 2026-07-02: Sticky Notes の title/body を入力中に毎キー永続化していた経路を止め、編集終了時に first responder を外して draft を保存する流れへ変更。付箋を開く際は app を activate し、標準 Edit menu の cut/copy/paste/select all/undo/redo を app main menu に追加して macOS の通常テキスト操作が responder chain で届くようにした。色変更、archive、delete、外側クリック、別付箋切替では編集中 draft を先に確定する。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify`、`codesign --verify --deep --strict --verbose=2 dist/HoverPocket.app` 成功。
- 2026-07-02: コミット `126e05e` を build `85` として配信。notarytool submission `cb67081a-54d3-44ca-b961-ce6e728b2451` は `Accepted`。staple後に `HoverPocket-0.1.0-85.zip` / `HoverPocket-macOS-app.zip` / appcast を GitHub Release `v0.1.0-85` へ公開し、latest appcast が build `85` を指すことを確認。公開ZIPの top-level は `HoverPocket.app` のみ、SHA256 は `56da2b0b609af0cd33edea1efae4afbcbf060632359ae38396ec5da4d347362f`。公開ZIP展開後の `codesign` / `stapler validate` / `spctl` も成功。
- 2026-07-03: Calculator provider を追加し、ProviderRegistry に日本語 title `電卓` として登録。四則演算、小数、符号反転、パーセント、バックスペース、AC、コピー、キーボード入力、0除算時の `Error` 表示に対応。パネル preview size は `small=520x372`、`medium=600x430`、`large=680x488` へ拡大し、ホバーパネル内の可読テキスト用に `文字サイズ` 設定を追加。Google Calendar、Clipboard、Controls、Sticky Notes、Timer、Calculator、AI command lane の主要テキストへ適用。`swift build`、calculator verify 2系統、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- 2026-07-03: コミット `af86e29` を build `96` として配信。notarytool submission `e6e801d1-7a43-4d98-8b99-3804482bd322` は `Accepted`。staple後に `HoverPocket-0.1.0-96.zip` / `HoverPocket-macOS-app.zip` / appcast を GitHub Release `v0.1.0-96` へ公開し、latest appcast が build `96` を指すことを確認。公開ZIPの top-level は `HoverPocket.app` のみ、SHA256 は `179917a6294b91cae94471fc97c8b6fae8d4d0d07247f78664c22a7106ad08e9`。公開ZIP展開後の `codesign` / `stapler validate` / `spctl` も成功。
- 2026-07-04: コミット `f02ab81` を build `98` として配信。notarytool submission `1fa7ad28-14be-4234-b455-cbafbdcaf5d1` は `Accepted`。staple後に `HoverPocket-0.1.0-98.zip` / `HoverPocket-macOS-app.zip` / appcast を GitHub Release `v0.1.0-98` へ公開し、latest appcast が build `98` を指すことを確認。公開ZIPの top-level は `HoverPocket.app` のみ、SHA256 は `33efbaf3e32d1f59b382b21b390c29376bf6a4ef35ab253f354e2c3166baeb0e`。公開ZIPを再取得し、展開後の `codesign` / `stapler validate` / `spctl` も成功。
- 2026-06-29: Google OAuth を Chrome profile override なしの OS 既定ブラウザ起動へ統一し、native/custom URL scheme flow は `AppDelegate` の `kAEGetURL` callback で待機処理へ渡す形に変更。Calendar token 失効や scope 不足を再接続扱いにする改善、外部モニター音量の DDC/CI VCP `0x62` 対応、クラムシェル外部カメラなし時の Mirror 非表示を追加。README / `.env.example` / `script/build_and_run.sh` から旧 Chrome override 説明と `GoogleOAuthChrome*` Info.plist 注入を削除。`swift build`、`git diff --check`、`./script/verify_google_calendar.sh` 成功。Apple Developer Program License Agreement 同意後、`script/notarize_release.sh` の notarytool 事前検証を補正し、build `79` を notarized/stapled ZIP として GitHub Release `v0.1.0-79` に公開。latest appcast が build `79` を指すことを確認済み。

## 進行中

- Codex: `ホバーポケット` / `HoverPocket` として GitHub public repository `shotaro311/hover-pocket` へ公開済み。`Mirror`、`Controls`、`Calculator`、`Calendar`、`Clipboard`、`Sticky Notes` の built-in provider が有効。Controls は明るさ表示/調整、最小/最大輝度トグル、CoreAudio 音量/ミュート、MediaRemote bridge による Now Playing サムネイル/再生位置/再生制御/再生速度調整を持つ。MediaRemote が空の場合はブラウザの active tab title / URL で YouTube などを fallback 認識する。再生/停止と倍速操作は pending state 付きの background task で直列化し、操作中の stale refresh と連打を抑える。ブラウザ由来メディアの倍速は、対象media URLに一致するタブの同一video DOMへ設定し、実`playbackRate`のreadbackに成功した場合だけUIへ反映する。DOM readback不能時は未確認値を表示せず失敗扱いにする。画面収録サムネイルは未許可時に自動 permission request を出さず、許可済みの場合だけ ScreenCaptureKit preview を使う。外部ディスプレイは DDC/CI を先に試し、DDC が使えない場合だけ DisplayServices とソフト輝度 fallback を使う。Calendar は Google iOS OAuth client + custom URL scheme + PKCE + OS 既定ブラウザで実アカウント接続、予定取得、追加、編集、削除まで実装済み。Google OAuth credential は通常 Keychain に保存し、開発版と配布版で Keychain service suffix を分離する。パネル preview size は `small=520x372`、`medium=600x430`、`large=680x488`、`extraLarge=760x546`。Settings の`文字サイズ`でhover panelの主要可読テキストを小/中/大/特大の4段階に切り替え可能。Sticky Notes は inline editor、title optional、drag reorder、外部 drag text payload、下部ゴミ箱 drop archive、S/M/L grid、Undo toast 設定に対応し、入力中 draft は外側クリック/別付箋切替/操作実行時に確定する。標準 Edit menu 経由の cut/copy/paste/select all/undo/redo も使える。AI native Phase 1 として Apple Foundation Models provider、Calendar read/write tool、ApprovalGate、AuditLog、下段 command lane、fallback candidates を実装済み。UI は Settings で `日本語` / `English` を切り替え可能で、既定は日本語。Provider header の機能アイコンは drag & drop で並べ替え可能。上部 handle は `B / C / None` とメインノッチ左アイコンエリア表示/非表示を Settings から選択可能で、非表示時は横エリア自体を描画しない。表示先は `メイン / サブ / すべて` で、ノッチなし画面は縦ヒット 8pt の控えめなミニバー起点を使う。サブディスプレイから開いた場合の Mirror 表示は Settings から制御でき、既定は非表示。macOS menu bar status item から設定 / 更新確認 / 終了を実行可能。更新がある場合はホバーウィンドウ上部にも青い更新アイコンを表示し、押下後はホバーウィンドウを閉じる。Camera / Microphone permission off 時は System Settings へのCTA、Calendar未接続時はGoogle login CTAを表示する。Camera Settings で許可後はpermission recovery pollingとアプリ復帰検知でMirrorを再起動する。配布版は hardened runtime 用の camera / audio-input entitlements 入り。build `98` は notarized/stapled ZIP として GitHub Release `v0.1.0-98` に公開済みで、latest appcast も build `98` を指している。

## 次アクション

- 別Macまたは quarantine 付きダウンロードで、GitHub Release ZIP の初回起動時 Gatekeeper UX を確認する。
- Mirror の初回 permission UX と表示品質をユーザー実機で確認する。
- Clipboard provider の text/image drag/drop を、Finder / Slack / browser input など複数アプリで手動確認する。
- Apple Foundation Models の実機可用性を macOS 26 / Apple Intelligence 環境で確認する。
- AI command lane の手動 UX 確認を行い、曖昧入力時の候補表示と Calendar write 承認導線を確認する。
- 2026-06-22: 伊勢田さんに Calendar Pocket 検証を行い、`progress/2026-06/2026-06-22_calendar-pocket-validation.md` の観察項目に沿って記録する。
- アプリ化の次要件を決める: 終了/自動起動、Google OAuth consent screen、正式 installer、今後追加する provider。
- 次の本物のレビューコメント付きPRで、Codex Automation がレビュー内容を読んで修正commitを積むところまで確認する。

## Blocker / Risk

- Developer ID 署名、notarization 済み ZIP、GitHub Release、Sparkle appcast は整備済み。LaunchAgent、自動起動、正式 installer は未実装。
- 初回 camera permission はユーザー操作が必要。
- 自動検証では顔が写る映像確認は避けている。ユーザー側で mirror 映像の見え方確認が必要。
- 機密情報や token は含めていない。
- `.env.local` には Google OAuth 設定値が入るため、値を出力せず、repo に含めない。配布用 app bundle へは iOS OAuth client ID / URL scheme のみ注入し、Desktop OAuth client secret は通常入れない。
- Google OAuth consent screen が Testing の場合、登録済み test user のみログイン可能。一般公開には Google OAuth app verification が必要になる可能性がある。
- 現在の公開ZIP成果物 `dist/releases/HoverPocket-0.1.0-98.zip` は Developer ID Application 署名と notarization/staple 済みで、GitHub Release `v0.1.0-98` に公開済み。latest appcast も build `98` を指す。一般ユーザー向けには同じ app-only payload を分かりやすい `HoverPocket-macOS-app.zip` として案内し、公開URLから再取得したZIPのトップレベルが `HoverPocket.app` のみであることを確認済み。SHA256 は `33efbaf3e32d1f59b382b21b390c29376bf6a4ef35ab253f354e2c3166baeb0e`。
- Sparkle秘密鍵は macOS Keychain の `hover-pocket` アカウントにある。秘密鍵ファイルをGitに書き出さない。
- App Store Connect の有料アプリ契約と EU DSA の trader compliance は未完了表示が残るが、今回の Developer ID notarization / Sparkle 配信は成功済み。
- ブラウザ動画の倍速変更にはDOM readbackが必要。DiaはAppleScript JavaScriptを許可した起動条件、Chrome / SafariはApple EventsからのJavaScript実行を許可した状態で利用する。DOMを利用できない場合はshortcut / MediaRemoteへ未確認fallbackせず、UI値を変更しないで失敗扱いにする。
- 旧 Keychain の Google OAuth item が現在の署名で読めない場合は、Keychainパスワードダイアログを出さずに未接続扱いへ落とす。Google再ログイン後は通常 Keychain に新credentialを保存する。credentialはローカルMacのKeychainに保存され、app bundle / ZIP / repo には含めない。
- Calendar event 書き込みには `calendar.events` scope が必要。既存の read-only token では再接続が必要。
- AI native Phase 1 の Apple Foundation Models provider は SDK / OS が未対応の場合、deterministic fallback で候補生成する。モデル本体の実行確認は対応OSで別途必要。
- Clipboard history は機密テキストも拾えるため、今後は除外ルール、保存期間設定、private mode を追加する余地がある。
- Microphone meter は Mirror microphone row 表示中に自動起動する。初回 permission prompt は手動操作が必要。
- 再ビルド後の ad-hoc 署名では camera / microphone permission prompt が再表示されることがある。配布時は安定した署名で確認する。

## 引き継ぎ

- Project root: `/Users/shotaro/code/share/hover-menu-preview`
- GitHub: `https://github.com/shotaro311/hover-pocket`
- Run: `./script/build_and_run.sh --verify`
- Product name: `ホバーポケット` / `HoverPocket`
- UI source: `Sources/HoverPocket/Views/`
- Windowing source: `Sources/HoverPocket/Windowing/`
- Provider source: `Sources/HoverPocket/Providers/`

## 重要パス

- Project root: `.`

## 詳細ログ

- [2026-07-04](2026-07/2026-07-04_hover-menu-preview.md)
- [2026-07-03](2026-07/2026-07-03_hover-menu-preview.md)
- [2026-07-02](2026-07/2026-07-02_hover-menu-preview.md)
- [2026-07-01](2026-07/2026-07-01_hover-menu-preview.md)
- [2026-06-30](2026-06/2026-06-30_hover-menu-preview.md)
- [2026-06-29](2026-06/2026-06-29_hover-menu-preview.md)
- [2026-06-23](2026-06/2026-06-23_hover-menu-preview.md)
- [2026-06-22](2026-06/2026-06-22_hover-menu-preview.md)
- [2026-06-21](2026-06/2026-06-21_hover-menu-preview.md)
- [2026-06-20](2026-06/2026-06-20_hover-menu-preview.md)
- [2026-06-19](2026-06/2026-06-19_hover-menu-preview.md)
- [2026-06-15](2026-06/2026-06-15_hover-menu-preview.md)
- [2026-06-10](2026-06/2026-06-10_hover-menu-preview.md)
- [2026-06-09](2026-06/2026-06-09_hover-menu-preview.md)
- [2026-06-08](2026-06/2026-06-08_hover-menu-preview.md)
- [2026-06-07](2026-06/2026-06-07_hover-menu-preview.md)
- [2026-06-04](2026-06/2026-06-04_hover-menu-preview.md)
- [2026-06-03](2026-06/2026-06-03_hover-menu-preview.md)
- [2026-06-02](2026-06/2026-06-02_hover-menu-preview.md)

## 旧進捗ソース

- 一時成果物: `/Users/shotaro/Documents/Codex/2026-06-02/files-mentioned-by-the-user-2026/outputs/hover-menu-preview`

## 移行検証後の削除候補

- [cleanup-candidates.md](cleanup-candidates.md)

## 最近の更新

- 2026-07-05: Windows 版要件定義を `docs/requirement/requirements.md` に作成。既存 macOS 版の README / progress / Swift source から HoverPocket の本質、Provider 機能、開閉操作感、Settings、保存/権限、配布更新を抽出し、3 つのサブエージェントで macOS 体験、Windows OS 代替、受け入れテスト/失敗モードを分担調査。Windows App SDK、WebView2、Tauri、Google OAuth、Microsoft Win32/Windows API の一次情報を確認し、技術選定は固定せず `top-edge overlay / tray / mixed DPI / Clipboard drag-drop / camera permission` の spike を Phase 0 とする方針にした。`git diff --check` 成功。Windows 環境では `swift` 未導入のため build は未実行。
- 2026-07-05: Windows 側の作業準備として `C:\Users\shotaro\code\shared\hover-pocket` へ public repo `shotaro311/hover-pocket` を clone。HEAD は `0cd6ec1`、origin は `https://github.com/shotaro311/hover-pocket.git`、GitHub latest release は `v0.1.0-98`。Windows 環境では Bash は利用可能だが `swift` が PATH 上になく、`swift build` / `./script/build_and_run.sh --verify` は未実行。`git diff --check` と `git status -sb` は成功。現行構成は SwiftPM macOS 14+ の AppKit/SwiftUI/Sparkle/MediaRemote 依存が強いため、Windows 対応はまず domain/state と OS integration/UI shell の分離から始める。
- 2026-07-04: Calculator UI を整理。電卓本体の最大幅を 430pt に制限し、大きいパネルでキーが横に伸びすぎないようにした。表示エリア内の重複タイトルを削除し、コピーは右上の `doc.on.doc` アイコン1つに統一。バックスペースは表示エリア右上へ移動。キーパッドを `Grid` 化して `0` の2列幅、演算子、`=` の配置崩れを防ぎ、演算子表記を `÷` / `×` / `−` に変更。`swift build`、calculator verify 2系統、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- 2026-07-04: build `98` を notarized/stapled ZIP として GitHub Release `v0.1.0-98` に公開。latest appcast は build `98`、公開 `HoverPocket-macOS-app.zip` の top-level は `HoverPocket.app` のみ、SHA256 は `33efbaf3e32d1f59b382b21b390c29376bf6a4ef35ab253f354e2c3166baeb0e`。公開ZIP再取得後の `codesign` / `stapler validate` / `spctl` 成功。
- 2026-07-03: Calculator provider を追加し、ProviderRegistry に日本語 title `電卓` として登録。四則演算、小数、符号反転、パーセント、バックスペース、AC、コピー、キーボード入力、0除算時の `Error` 表示に対応。パネル preview size は `small=520x372`、`medium=600x430`、`large=680x488` へ拡大し、ホバーパネル内の可読テキスト用に `文字サイズ` 設定を追加。Google Calendar、Clipboard、Controls、Sticky Notes、Timer、Calculator、AI command lane の主要テキストへ適用。`swift build`、calculator verify 2系統、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- 2026-07-03: build `96` を notarized/stapled ZIP として GitHub Release `v0.1.0-96` に公開。latest appcast は build `96`、公開 `HoverPocket-macOS-app.zip` の top-level は `HoverPocket.app` のみ、SHA256 は `179917a6294b91cae94471fc97c8b6fae8d4d0d07247f78664c22a7106ad08e9`。公開ZIP展開後の `codesign` / `stapler validate` / `spctl` 成功。
- 2026-07-02: Sticky Notes の入力中毎キー保存を止め、外側クリック/別付箋切替/色変更/archive/delete で編集中 draft を確定する流れへ変更。app main menu に標準 Edit menu を追加し、付箋編集開始時に app を activate して、cut/copy/paste/select all/undo/redo が通常の macOS テキスト操作として届くようにした。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify`、`codesign --verify --deep --strict --verbose=2 dist/HoverPocket.app` 成功。
- 2026-07-02: build `85` を notarized/stapled ZIP として GitHub Release `v0.1.0-85` に公開。latest appcast は build `85`、公開 `HoverPocket-macOS-app.zip` の top-level は `HoverPocket.app` のみ、SHA256 は `56da2b0b609af0cd33edea1efae4afbcbf060632359ae38396ec5da4d347362f`。公開ZIP展開後の `codesign` / `stapler validate` / `spctl` 成功。
- 2026-07-01: Calendar 小サイズ UI 崩れ、画面収録/システムオーディオ権限の再要求、Controls メディア操作のラグ/倍速不安定を修正。build `83` を notarized/stapled ZIP として GitHub Release `v0.1.0-83` に公開し、latest appcast が build `83` を指すことを確認。
- 2026-06-30: Controls のメディア倍速ボタンを非同期化し、クリック時の UI フリーズと未確認の倍速成功表示を修正。対象 media URL / title に一致するブラウザタブへ操作し、refresh 時は実 `playbackRate` を読み戻す。Dia は `focus browserTab` 経路へ分岐するが、AppleScript JS 実行が拒否されるため exact `1.1x` は未対応として検出する。`--verify-media --set-playback-rate 1.1` が `media_verify=failed` を返すこと、`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- 2026-06-30: build `81` を notarized/stapled ZIP として GitHub Release `v0.1.0-81` に公開。latest appcast は build `81`、公開 `HoverPocket-macOS-app.zip` の top-level は `HoverPocket.app` のみ、SHA256 は `2d1d7fe8bf434263eedcf84675679b67bdfe547214fce2204353618a77854316`。公開ZIP展開後の `codesign` / `stapler validate` / `spctl` 成功。
- 2026-06-29: Google OAuth を native/custom URL scheme と legacy/loopback の両方で OS 既定ブラウザ起動へ統一し、AppDelegate の `kAEGetURL` callback 受け渡しを追加。古い Chrome profile override 設定は README / `.env.example` / build script から削除。Calendar token/reconnect、外部モニター音量 DDC/CI VCP `0x62`、クラムシェル外部カメラなし Mirror 非表示も progress に記録。`swift build`、`git diff --check`、`./script/verify_google_calendar.sh` 成功。Apple Developer Program License Agreement 同意後、build `79` を notarized/stapled ZIP として GitHub Release `v0.1.0-79` に公開。latest appcast は build `79` を指す。
- 2026-06-23: ハンドルアイコン `なし` 選択時に、ノッチ横の黒いハンドル背景も描画しないようにした。表示判定と access window のジオメトリを `showNotchSideHandleArea && pillHandleIconStyle != .none` に揃え、設定変更直後に再同期されるようにした。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- 2026-06-22: Controls のメディア表示に live video preview を追加。MediaRemote / JXA の再生情報にブラウザタブ URL と表示中 window id を合成し、ScreenCaptureKit で小さい映像枠を継続更新する。YouTube 判定は実動画URLだけに絞り、ブラウザタブ列挙 / JS 操作は timeout 付きにした。倍速操作は browser media tab へ試し、失敗時は YouTube keyboard fallback へ落とす。UI には現在速度 `1.0x` ピルを追加。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify`、`--verify-media`、`--set-playback-rate 1.1 -> 1.0` が成功。build local verified、未リリース。
- 2026-06-22: Controls のメディア認識が YouTube で空になる問題を再修正。配布署名済み app から直接 `MRNowPlayingRequest` を読むと `Operation not permitted` になるため、JXA 経由の MediaRemote 取得を先に使い、既存 `MRMediaRemoteGetNowPlayingInfo` と browser tab fallback を後続にした。`--verify-media` 診断を追加し、生成済み `dist/HoverPocket.app` で YouTube の title / source / duration / progress が取れること、検証時間帯に `Operation not permitted` が出ないことを確認。build `74` local verified、未リリース。
- 2026-06-22: YouTube が Controls で認識されない報告に対応。MediaRemote が空の場合だけ Chrome / Safari / Edge / Arc の active tab title / URL を Apple Events で読む fallback を追加し、YouTube などをメディアとして表示するようにした。倍速ボタンは独立カプセルをやめ、10秒戻し / 再生停止 / 10秒送りの横に同じ丸アイコンボタンで配置。build `71` を notarized/stapled ZIP として GitHub Release `v0.1.0-71` に公開し、latest appcast は build `71` を指す。
- 2026-06-22: Controls provider のレイアウトを修正し、ディスプレイ / サウンド / メディアのバー幅と右端アクション位置を揃えた。ディスプレイ名はアイコン hover tooltip へ移動し、見出しアイコンを削除。外部ディスプレイは Apple Silicon の DDC/CI VCP `0x10` で明るさ取得/設定を試し、内蔵ディスプレイ最小輝度は 5% にした。MediaRemote の認識条件を広げ、再生速度 `-0.1 / +0.1` と冒頭へ戻る操作を追加。build `69` を notarized/stapled ZIP として GitHub Release `v0.1.0-69` に公開し、latest appcast は build `69` を指す。
- 2026-06-21: Controls provider を追加。A案の縦積みコンパクトレイアウトで Displays / Volume / Now Playing をまとめ、Header は既存 `ProviderHeaderView` に任せる構成にした。内蔵ディスプレイの明るさ取得、CoreAudio 音量/ミュート、MediaRemote symbol 存在確認、`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` が成功。build `67` を notarized/stapled ZIP として GitHub Release `v0.1.0-67` に公開し、latest appcast は build `67` を指す。
- 2026-06-21: ノッチなし画面のミニバー縦ヒット領域を 8pt に縮小し、早く開きすぎる挙動を抑えた。更新アイコン押下後はホバーウィンドウを閉じて Sparkle 更新 UI を見やすくした。Settings を `表示 / 起点表示 / パネル / 機能` へ整理し、メインノッチ左のアイコンエリアはオフ時に横エリア自体を描画しないようにした。build `65` を notarized/stapled ZIP として GitHub Release `v0.1.0-65` に公開し、latest appcast は build `65` を指す。
- 2026-06-21: 表示先の `自動` モードを廃止し、Settings は `メイン / サブ / すべて` の3択にした。`すべて` 選択時に全ディスプレイの起点ウィンドウを即時前面化し、ノッチなし画面のミニバー反応領域を 520 x 64pt へ拡大して、上端や横方向からの hover 取りこぼしを減らした。build `63` を notarized/stapled ZIP として GitHub Release `v0.1.0-63` に公開し、latest appcast は build `63` を指す。
- 2026-06-21: サブディスプレイ向けに、ノッチなし画面だけ控えめなミニバー起点を使う `すべて` 表示を追加。サブディスプレイから開いた際に Mirror provider を表示するかどうかを Settings で切り替え可能にし、既定はオフ。更新がある場合はホバーウィンドウ上部に青い更新アイコンを表示し、クリックで Sparkle 更新 UI を開く。build `61` を notarized/stapled ZIP として GitHub Release `v0.1.0-61` に公開し、latest appcast は build `61` を指す。
- 2026-06-21: UI 言語設定を追加し、既定日本語 / English 切り替えに対応。Settings、Calendar、Mirror、Clipboard、Sticky Notes、provider header、status bar menu、AI command lane の主要固定文言を言語設定へ接続。Provider header の機能アイコンを drag & drop で並べ替え可能にした。build `59` を notarized/stapled ZIP として GitHub Release `v0.1.0-59` に公開し、latest appcast は build `59` を指す。
- 2026-06-20: 配布版でMirrorが映らない問題に対応。原因は Developer ID + hardened runtime の app bundle に `com.apple.security.device.camera` / `com.apple.security.device.audio-input` entitlements が入っていなかったこと。`Resources/HoverPocket.entitlements` を追加し、codesign 時に適用するよう変更。`--verify-camera` 診断も追加し、build `57` を notarized/stapled ZIP として GitHub Release `v0.1.0-57` に公開。latest appcast は build `57` を指す。
- 2026-06-20: Keychain password prompt 再発に対応。Google OAuth Keychain service を開発版 `development` と配布版 `release` に分離し、旧 `local.codex.hover-pocket.google-oauth` は自動読み取りしないようにした。Camera permission 復帰も AppDelegate 側で再確認するよう補強し、build `55` を notarized/stapled ZIP として GitHub Release `v0.1.0-55` に公開。latest appcast は build `55` を指す。
- 2026-06-20: build `53` を notarized/stapled ZIP として GitHub Release `v0.1.0-53` に公開。latest `HoverPocket-macOS-app.zip` と appcast が build `53` を指すことを確認。
- 2026-06-20: Camera permission 許可後にMirrorが復帰しない問題と、Googleログイン後にリンクされない問題を修正。Google側は Data Protection Keychain の `-34018` が原因だったため通常 Keychain 保存へ戻し、`./script/verify_google_calendar.sh` で Calendar API 到達まで確認。
- 2026-06-20: build `51` を notarized/stapled ZIP として GitHub Release `v0.1.0-51` に公開。latest `HoverPocket-macOS-app.zip` と appcast が build `51` を指すことを確認。
- 2026-06-20: Google OAuth Keychain の起動時パスワードダイアログ対策として Data Protection Keychain 保存へ移行。menu bar status item、Camera / Microphone privacy settings CTA、Calendar Google login CTA を追加。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- 2026-06-20: README と AI architecture report を最新状態へ同期。README は `ホバーポケット` / `HoverPocket` の名称、Sticky Notes、AI command lane、notarized GitHub Release、Sparkle 更新済みの状態へ更新し、古い「notarization 未整備」記述を削除。
- 2026-06-20: GitHub Release の Source code ZIP 誤認対策として、README と release upload script に `HoverPocket-macOS-app.zip` の app-only download 導線を追加。配布ZIPは `__MACOSX` を含まない形式へ差し替え、公開URLからの再ダウンロードでもトップレベルが `HoverPocket.app` のみであることを確認。
- 2026-06-20: top pill の handle icon を `B / C / None` から選択可能にした。ノッチに合わせた pill geometry は変更せず、Settings の `Handle icon` から切り替える。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- 2026-06-20: top pill のノッチ横 handle area を Settings から表示/非表示にできるようにした。非表示時もノッチ本体側の黒い領域と preview center は維持する。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- 2026-06-20: Sticky Notes のドラッグ改善として、並び替え中の保存頻度を下げ、外部ドラッグ閉じ判定をホバーウィンドウ外へ出た時点へ変更。空の新規付箋は確定時に破棄し、ドラッグ中の下部ゴミ箱ドロップでアーカイブできるようにした。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- 2026-06-20: Sticky Notes UI をリファクタリング。`StickyNotesView.swift` を root state / action / layout に絞り、カード/ヘッダー/色スウォッチ/Undo toast などを `StickyNoteComponents.swift`、drop delegate を `StickyNoteDropDelegates.swift` へ分離。`swift build` 成功。
- 2026-06-20: Sticky Notes の追加修正として、drag reorder 後の薄い表示残り対策、Ctrl+Enter確定、付箋外クリックで一覧へ戻る挙動、別付箋クリック時のリアルタイム保存付き編集切替、色ダブルクリック新規作成、付箋グリッドサイズ `S/M/L` 切替を実装。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- 2026-06-20: Sticky Notes の Board Grid UI を追加。hover archive、フル幅に拡大する inline editor、color swatches、context menu、drag reorder、外部 drag text payload、undo toast を `StickyNotesView.swift` に実装し、`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- 2026-06-20: Sticky Notes の model / store / provider / Settings toggle を追加。Application Support `HoverPocket/StickyNotes/notes.json` への JSON 永続化、archive/delete undo、provider registry 接続を実装し、`swift build` と `git diff --check` 成功。
- 2026-06-20: Apple notarization を実行し、`HoverPocket-0.1.0-41.zip` を notarized/stapled ZIP として再生成。app 本体と ZIP 展開後 app の両方で Gatekeeper accepted を確認。
- 2026-06-19: 決定アプリアイコンを app bundle に反映し、Mirror camera の遅延停止/再起動競合を修正。実マウス移動の hover open / close 5サイクルで preview 再open を確認。
- 2026-06-07: Calendar provider に日付クリック固定、予定追加、編集、削除 UI / API を追加。OAuth scope は `calendar.events` に変更し、既存 read-only credential は再接続扱いにした。
- 2026-06-07: Clipboard provider と provider 表示/順番/default panel 設定を追加。
- 2026-06-07: Clipboard image drag の drop 互換性改善として、panel 一時非表示と file URL provider を追加。
- 2026-06-07: Mirror 下に compact microphone check row と Settings toggle を追加。
- 2026-06-07: Microphone permission 許可直後の crash を修正。CoreAudio tap closure を MainActor から分離し、権限待ち中に panel が閉じた場合は後から mic を起動しないようにした。
- 2026-06-07: Microphone meter 無反応対策として、input tap を `outputFormat(forBus:)` に変更し、dBFS ベースの感度へ調整。
- 2026-06-07: Microphone meter を Mirror 表示中に自動起動する仕様へ変更。右端 button は一時録音/停止/再生にし、再生完了後にメモリ上の録音を削除する。
- 2026-06-07: Microphone button 操作後に panel が閉じない問題を修正。preview 表示中だけ window controller 側で mouse location を監視して hover exit 取りこぼしを補完し、open animation 中の mouse event 無効時間を短縮。録音ボタンの hit area も 30pt に拡大。
- 2026-06-07: 一時的なアプリ名で SwiftPM package / executable / generated app bundle の公開名を更新。
- 2026-06-07: GitHub public repository `shotaro311/notch-pocket` を作成し、`main` を push。`gh repo view` で visibility `PUBLIC` を確認。
- 2026-06-07: README を日本語中心へ更新し、公開 GitHub のトップで概要と使い方が伝わる状態にした。
- 2026-06-08: provider アイコン切替時のヘッダー未更新バグを修正。`ProviderHeaderView` が `ProviderStore` を直接監視する構成に変更。
- 2026-06-08: `Codex PR Router` workflow を追加し、ハイブリッド自動修正運用の GitHub 側分類を導入。
- 2026-06-08: `github-codex-autofix` plugin を Mac / Windows に配置し、両環境で Codex Automation を設定。Windows 側は peer 経由で zip SHA 一致、script 存在、`list-targets` 対象なしを確認。
- 2026-06-08: 実PR `#1` で `Codex PR Router` のラベル付与、Mac helper の対象PR検出、claim / release、Windows helper の Mac向けPR除外を確認。検証PRはマージせず閉じ、テストブランチは削除済み。
- 2026-06-08: PR `#2` でパネル表示領域の `小 / 中 / 大` サイズ切替を追加。ヘッダーの `小 中 大` ボタンと Settings の `Panel size` picker から変更できる。
- 2026-06-08: PR `#2` のサイズボタンを現在サイズ1文字表示へ変更し、サイズ変更時の上端固定を確認。Mac / Windows のPR作成手順も Ready PR 前提へ更新。
- 2026-06-09: 上部ヘッダーの電源アイコンを廃止し、provider アイコン群と設定ボタンの間に薄い縦線の仕切りを追加。Settings の `Icon switching` で `Click / Hover` を選べるようにした。リファクタリングとして `ProviderHeaderView.swift` を分離し、`ProviderStore` の不要な設定変更再通知を減らした。
- 2026-06-09: Google OAuth Keychain 許可の毎回表示対策として、起動時の Keychain 読み込みを遅延し、開発ビルドの app bundle を Apple Development 署名に変更。
- 2026-06-09: アプリ名を正式名称の `ホバーポケット` / `HoverPocket` に変更し、README、SwiftPM product、build script、callback文言、progressを同期。source path は `Sources/HoverPocket`、provider protocol は `PocketProvider` へ更新。旧保存先から移行できる状態を維持。
- 2026-06-09: MIT License を追加し、README にライセンス欄を追加。GitHub 公開上のOSSライセンスを明確化。
- 2026-06-10: AI native Phase 1 MVP として、Apple Foundation Models provider、構造化 action / tool / approval / audit 基盤、Calendar read/write tool、下段 command palette lane、解釈候補 fallback UI を追加。`swift build` 成功。
- 2026-06-10: Review fix として ApprovalCard の全 approval field 表示と `requiresApproval` の computed 化を実施。`swift build` 成功。
- 2026-06-15: AI command palette 自動フォーカス、FoundationModels `@Generable` 経路、承認 summary、Calendar 日時手入力/ドラッグ調整、日付ダブルクリック新規予定起動を追加。`swift build` / `git diff --check` / `./script/build_and_run.sh --verify` 成功。
- 2026-06-04: Mirror close 時の点滅対策として、content 非表示化を window `orderOut` 後へ移動。
- 2026-06-04: Mirror の軽快化として、camera prewarm / provider active 分離 / eventDriven refresh skip を追加。見た目の animation は変更なし。
- 2026-06-04: Mirror のカクつき / ちらつき対策として、camera preview layer の暗黙 animation 無効化、animation 中 shadow off、閉じかけ再 hover の frame snap 防止、live camera への blur 削除を追加。
- 2026-06-04: Mirror が UI 枠より遅れて追従する問題に対応し、content reveal を window animation 完了後ではなく開始前へ移動。
- 2026-06-04: Mirror close 時の camera 残像対策として、close 開始時に provider active を落とし、camera preview fade を短縮。
- 2026-06-04: 繰り返し開閉時の処理系改善として、reset task 単一管理、同値 publish 抑制、camera active 重複通知抑制、provider select no-op を追加。
- 2026-06-04: `GoogleCalendarProvider`、Google OAuth loopback + PKCE、Keychain token保存、Calendar API client、月表示 + 日付hover詳細UI、Settings接続導線を追加。
- 2026-06-04: Google Calendar を実Googleアカウントで接続し、Calendar APIから予定取得できることを確認。
- 2026-06-04: Mirror の crash を修正し、preview layer 常駐化、4秒 warm grace、`vga640x480` preset で軽量化。
- 2026-06-04: Built-in `Mirror` provider を追加し、Mac camera の鏡プレビューを実装。
- 2026-06-03: 二段階の neck / overshoot animation を撤回し、直前の軽い morphing に戻した。
- 2026-06-03: preview close animation を open animation の逆再生に調整。
- 2026-06-03: top pill を文字なしの左側 arrow handle 表示へ変更。
- 2026-06-03: top pill の黒ベースを実ノッチ幅に合わせ、ノッチ裏の隙間を解消。
- 2026-06-03: top pill 上端のスリット状の抜けを黒 overfill で解消。
- 2026-06-03: 左上 handle のラウンド形状変更を撤回し、元の形へ復帰。
- 2026-06-03: Provider/Registry/Store の基盤を追加し、デモ用 sessions / usage 表示を削除。
- 2026-06-03: 設定ウィンドウを追加し、表示先を `Auto / Main / Sub` から選べるように変更。
- 2026-06-03: preview morphing を上部ノッチ中央から出て、上部ノッチ中央へ戻る動きに調整。
- 2026-06-03: notch sizing / point-pixel compensation の設計メモを README に追記。
- 2026-06-03: pill の下端の隙間を抑えるため、pill height を 33pt に調整。
- 2026-06-03: pill の上左右を丸めず、画面上面に接する top-docked design に調整。
- 2026-06-03: preview panel が pill 下端に接した小さいカプセルから液体的に広がる opening animation を追加。
- 2026-06-03: 上部 pill の位置を画面上端へ合わせ、余白 0pt に調整。
- 2026-06-02: Prototype app を `/Users/shotaro/code/share/hover-menu-preview` に移行し、開発用 Git repository と `.gitignore` を用意。
- 2026-06-02: 共通進捗管理を初期化。
