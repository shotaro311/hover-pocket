# HoverPocket AI-native AN3 Voice Foundation Integration

## 現在地

Draft PR #6のVoice Lane foundationをAN2のRegistry / Broker実装へ統合している。これはAN3完了ではなく、旧branchを現行契約へ載せ替えるための隔離準備である。両OSのHost-owned Voice Lane UI骨格までは実装したが、microphone、WebRTC、音声E2E、Broker tool dispatch、両OSVoice runtimeは未実装である。

## Git / worktree

- worktree: `/Users/shotaro/code/share/hover-menu-preview-ai-native-an3`
- branch: `feature/codex-voice-lane`
- branch開始head: `374aa6a39b5860ebfb6cd944a62f08106c72cff4`
- 統合対象AN2 head: `5d7cbe1ba6be44261c578ea3195d7fe5ccb03d45`
- AN2実装と両OSのVoice Lane表示基盤をmerge commit `52bf00c`で統合し、AN2最終進捗commit `15e44f0`もmerge commit `cdc5a8f`で取り込んだ。
- AN2 Ready PR [#9](https://github.com/shotaro311/hover-pocket/pull/9)はWindows / macOS / PR Routerが全成功し、MERGEABLE / CLEANである。AN3はローカル統合済みで、Draft PR #6の更新とCI readbackが次のgateである。

## 再利用したVoice基盤

- JSONL request相関、timeout / cancellation、malformed line隔離、process tree cleanupを持つ`CodexAppServerClient`。
- application-lifetime stateとmemory-only bounded transcriptを持つ`CodexVoiceCoordinator`。
- default-off設定、`disabled / compact / expanded` layout、Panelサイズ別geometry。
- fake app-server、protocol / coordinator / geometryの決定的Verifier。
- 未実装approval / user-input server requestを拒否するfail-closed既定。

## 今回の改善

- `CodexAppServerClientOptions.ExperimentalApi`を既定`false`へ変更した。実experimental capabilityは、明示的な互換性確認やVerifierでだけ有効化する。
- protocol Verifierへ、experimental capabilityが既定無効であるnegative assertionを追加した。
- `voice-lane-windows-ci.yml`を現行Windows契約へ合わせ、次の決定的対象を同一workflowへ追加した。
  - Shell / Display / rendered WebView UI / UI model
  - Sticky / Clipboard / Controls / Calculator / Timer / Calendar / Settings
  - legacy AI lane absence、Capability、Broker、Updater
  - Voice layout、app-server protocol、Voice coordinator
- 現行Macの`codex-cli 0.145.0`でexperimental JSON Schemaを生成し、`thread/realtime/start`、`thread/realtime/sdp`、`thread/realtime/listVoices`、`thread/list.ancestorThreadId`が存在することをread-onlyで確認した。対象Windowsでは改めてinstalled schemaと実WebRTCを確認する。

## macOS Host-owned Voice Lane UI骨格

- `HoverWindowController`がapplication-lifetimeの`VoiceLaneViewModel`を1つ所有し、Provider切替でLaneを再生成しない構造にした。
- `HoverPanelShell`を`Header + ProviderHost + VoiceLane`へ分け、既存のBase Panelサイズを維持したままVoice Laneだけを下へ加算する。Compactは64pt、ExpandedはS / M / L / XLごとに190 / 220 / 250 / 280ptである。
- Compactは視覚タイトルを置かず、64ptの短い波形より会話欄へ幅を優先した。レーン背景では切り替えず、明示chevronだけでCompact / Expandedを変更し、fullscreen state / route / buttonは持たない。
- Expandedは左transcript、右current root配下のchild session cardsという2列構成にした。両列は内部scrollを持ち、Provider領域を縮めない。
- 設定へVoice Lane default-off、既定Compact、別opt-inの自動listenを追加した。短い画面でExpanded全体が収まらない場合はCompactへfail-safeし、上端とProvider領域を維持する。
- 現段階のViewModelは実音声runtimeへ未接続で、transcript / session cardsは空状態を表示する。未完成機能を配布しないため、AN3 release gateまではbranch内だけで保持する。

## Windows Host-owned Voice Lane UI骨格

- `PanelBridgeController.BuildState()`へrequested settingとdisplayごとに解決したeffective layoutを分けて公開し、`settings.setCodexVoiceEnabled` / `settings.setCodexVoiceLayout`を追加した。
- `DisplayLayoutService`へVoice Lane設定を接続し、Expandedが収まらない画面ではCompactへ縮退する。`DisplaySurfaceLayout`が解決済みlayoutを保持し、表示先の切替時もWebView stateと物理window geometryを一致させる。
- `HoverShellController`は設定・表示先変更時にPanel全体だけをresizeする。WebView内の`Header + ProviderHost`は既存baselineを保ち、その下へVoice Laneを通常rowとして追加した。
- Compactは視覚タイトルなし、波形64px以下、会話欄優先、背景click無効、明示toggle、fullscreen affordanceなし。Expandedは左transcript / 右current root配下session cardsの2列と内部scrollを持つ。
- Settingsへdefault-off toggleとCompact / Expanded pickerを追加した。現在のvoice stateは`notConnected`で、実音声runtimeへ未接続のためstart / mute / end操作は無効である。
- `--verify ui-model`へ設定round-tripとbridge dispatch、`--verify voice-lane-layout`へ短画面縮退、`--verify ui`へCompact / Expanded描画とProvider rect不変を追加した。

## ローカル検証

```text
swift build -Xswiftc -warnings-as-errors
  PASS

.build/debug/HoverPocket --verify-broker
  PASS / registry 11 descriptors / 10 handlers / Today Focus / 10 negative cases

.build/debug/HoverPocket --verify-capabilities
  PASS / 10 handlers

.build/debug/HoverPocket --verify-voice-lane-layout
  PASS / 4 panel sizes x Compact / Expanded = 8 rendered cases
  PASS / Compact 64 / Expanded 190, 220, 250, 280
  PASS / provider rect invariant / downward expansion / default-off / persistence

Timer / Clipboard / Calculator / Panel layout 112 / Media
  PASS

python3 script/verify_pocket_contracts.py --root .
  PASS / 12 schemas / 52 fixtures

Windows UI JavaScript syntax / workflow YAML parse / git diff --check
  PASS

macOS capability workflow YAML parse
  PASS / Voice Lane source paths and verifier step included
```

## 未完了gate

1. Draft PR #6へ統合headをpushし、Windows Debug / Release warnings-as-errors、macOS、共通契約と全VerifierをGitHub Actionsで確認する。
2. AN2 PR #9は人間によるmerge待ちである。AN3は既に同じAN2 headを統合済みだが、AN2 merge後にmainとのparityを再確認する。
3. installed Codex version / generated schema / account / voicesを対象Windows実機でreadbackする。
4. application-lifetime coordinatorのproduction ownership、restart / backoff、詳細state machineを接続する。
5. 両OSのUI骨格を実runtime state / transcript / root-scoped child cardsへ接続する。
6. origin限定microphone、WebRTC SDP / remote audio、1往復、safe closeを実機検証する。
7. Voice intentをAN2 Capability Brokerへ接続し、Calendar read / create、Timer start、Today Focusのapprovalとreadbackを確認する。
8. macOS Voice runtimeと共通semantic contractを実装して両OS gateを通す。
