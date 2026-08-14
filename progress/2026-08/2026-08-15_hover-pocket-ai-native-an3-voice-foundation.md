# HoverPocket AI-native AN3 Voice Foundation Integration

## 現在地

Draft PR #6のVoice Lane foundationをAN2のRegistry / Broker実装へ統合し、Windowsではapplication-lifetime runtime、origin限定microphone permission、WebRTC SDP / remote audio、VoiceからBrokerへのdynamic tool dispatchまで実装した。macOSにも専用app-server clientとVoice Coordinator基盤を追加した。両OSのText / Voice / Native UIで共有するroute-independent canonical plan digestも実装済みである。これはAN3完了ではなく、対象Windows実機の実音声・実Calendar操作、root-scoped child cards、macOSのHost / microphone / Broker接続、両OSE2Eが残っている。

## Git / worktree

- worktree: `/Users/shotaro/code/share/hover-menu-preview-ai-native-an3`
- branch: `feature/codex-voice-lane`
- branch開始head: `374aa6a39b5860ebfb6cd944a62f08106c72cff4`
- 統合対象AN2 head: `5d7cbe1ba6be44261c578ea3195d7fe5ccb03d45`
- AN2実装と両OSのVoice Lane表示基盤をmerge commit `52bf00c`で統合し、AN2最終進捗commit `15e44f0`もmerge commit `cdc5a8f`で取り込んだ。
- AN2 Ready PR [#9](https://github.com/shotaro311/hover-pocket/pull/9)はWindows / macOS / PR Routerが全成功し、MERGEABLE / CLEANである。AN3の最新実装head `33d45ade1646ef16dfa12d3766fa0812c537d54d`はDraft PR #6へpush済みで、remote parity `0 / 0`、PRの全5チェックが成功し、GitHub readbackはMERGEABLE / CLEANである。

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

## Windows Voice runtime / WebRTC

- `CodexVoiceRuntimeHost`がapp lifetimeでCoordinatorを所有し、設定の有効化時だけexperimental app-serverを起動する。`initialize`後にaccountとvoice capabilityを確認し、signed-out / incompatibleはfail closed、process crashはbounded backoffで再起動する。
- Panel WebViewのマイク許可は、exact origin `https://app.hoverpocket.local`、ユーザー操作、Voice有効、Panel表示中、8秒以内のsingle-use armをすべて満たす場合だけ許可する。許可はprofileへ保存せず、その他のpermissionは拒否する。
- `thread/realtime/start`はisolated workspace、read-only sandbox、approval `never`、永続root thread、WebRTC対応の`v1`で開始する。SDP offer / answer、remote audio、mute、transport detach、stop / closedをtyped Bridgeで接続し、audioとfull transcriptはHoverPocketへ保存しない。
- fake app-server verifierへthread開始、WebRTC SDP、transport接続、transcript、detach、crash / restart、stopを追加した。実装head `91aa8d3`のGitHub ActionsはWindows Voice 2系統、Windows通常verify、macOS verify、PR Routerがすべて成功した。

## Windows Voice → Capability Broker

- app-server `item/tool/call`を受けるHost-owned Adapterを追加し、root thread一致、function allowlist、closed input schema、bounded identifier / payloadを検証してからだけBroker planを作る。未知request、別root、namespace付きcall、余分な引数はfail closedとする。
- 初期toolは`hoverpocket_calendar_today`、`hoverpocket_timer_start`、`hoverpocket_calendar_create`、`hoverpocket_today_focus`の4件である。VoiceからProvider Storeや既存WebView Bridgeへ直接到達する経路は作らず、AN2 Registry / Broker、approval、ledger、audit、readbackをそのまま使う。
- Calendar readは許可済みprivate readとして実行する。Timer開始、Calendar作成、Today FocusはHostのWPF確認画面でcanonical title / duration / start / end / purposeを表示し、Panel表示中、Voice有効、AI-native有効のときだけ承認できる。拒否時は書き込みゼロで、承認後はreadback一致を成功条件にする。
- tool call IDと引数digestをbindingしたbounded memory cacheで同一callの再送を1回の結果へ集約し、同じcall IDで引数が変わった場合はidempotency conflictとして拒否する。Calendar / TimerのBroker plan IDとToday Focus operation tokenもcallへbindingし、cache消失後の再送は二重実行せずledger conflictでfail closedする。
- verifierは4 tool schema、別root拒否、readの承認不要、Timer拒否時の書き込みゼロ、承認表示と実行title一致、readback、同一call再送、改変再送拒否、Calendar create event readback、Today FocusのTimer / Sticky readbackを検査する。fake app-serverは`thread/start.dynamicTools`が空なら失敗するfixtureを持つ。
- 実装head `b8f830b`のGitHub Actions run `31827122722`はDebug / Release warnings-as-errorsを0 warning / 0 errorで通過し、`codex-voice-coordinator` verifierが`Broker-routed Voice tools with approval/readback/idempotency`をPASSした。PR #6のWindows Voice CI 2系統、Windows通常verify、macOS verify、PR Routerはすべて成功した。

## 入力経路をまたぐcanonical plan digest

- AN0の正本契約は、同じ操作のcanonical plan digestからroute固有のplan ID、時刻、origin、principal、idempotency keyを除外し、Pocket App context、Capability ID / version、正規化済み引数、依存、承認方式、必要権限だけを含める。従来のSwift / C# Brokerはroute固有値まで含めていたため、TextとVoiceで同じToday Focusを作ってもdigestが一致しなかった。
- 両OSのBrokerがRegistry検証済みdescriptorから`none`または`before_writes / all_writes`のapproval projectionを作り、route-independent projectionをSHA-256へ正規化するよう修正した。共通golden digestは`sha256:57c7e72e02919aead49c27299c9f174ff49f776bedf616749a6e4951345da69d`である。
- plan ID等を意味的digestから外しても実行単位が衝突しないよう、receipt invocation ID、audit trace、rollback idempotency keyはcanonical plan digestとplan IDの不可逆digestを併用する。approval grantは従来どおりplan ID、principal、App context、期限、single-use tokenへbindingし、step ledgerはidempotency key、plan digest、argument digest、Capabilityを検証する。
- macOS `TodayFocusTextAdapter`へWindowsと同じ`origin`とbounded operation tokenを追加し、異なるplan ID、時刻、origin、principal、idempotency keyでも同じToday Focusが同じdigestになり、引数変更ではdigestが変わる両OSfixtureを追加した。
- 実装head `e53e14a`のGitHub Actions run `31828804099` / `31828809462`はWindows Debug / Release warnings-as-errorsを0 warning / 0 errorで通し、Brokerと全Voice verifierを成功させた。Windows通常verify `31828809754`、macOS verify `31828809468`、PR Router `31828806287`も成功した。PR #6はDraftのままMERGEABLE / CLEANである。

## macOS Codex app-server / Voice Coordinator基盤

- Swift actorとして専用`CodexAppServerClient`を追加し、JSONL request相関、initialize、timeout / cancellation、malformed / unknown response隔離、bounded stdout / stderr、server request fail-closed、process cleanupを実装した。既定のexperimental APIは無効で、Voice featureが明示有効なCoordinatorだけが有効化する。
- `CodexVoiceCoordinator`はaccount / voice gate、persistent root thread、read-only isolated workspace、WebRTC `thread/realtime/start` / SDP、memory-only bounded transcript、mute / stop、bounded restartを持つ。現時点ではdynamic toolは空で、Host UI / microphone / Capability Brokerへ本番接続していない。
- fake Python app-serverを使う`--verify-codex-app-server`をmacOS CIへ追加した。初期化、malformed isolation、未対応server request拒否、timeout後の回復、transport終了、child process cleanupを検査する。ローカルと最終CIで成功した。

## ChatGPT Pro Criticと安全性remediation

- Critic run `20260815-031722-hoverpocket-an3-windows-voicecapability-broker-exact-diff`は通常Chat / GPT-5.6 Sol / Pro、GitHub read-only、外部操作なしでexact diffをレビューした。自動parserが4連backtickのartifactを認識しなかったため、保存済みresponseを同一runへcanonical ingestし、`critic-review.md` 34,451 byte、SHA-256 `68f0715fe28e8799c4d2780877c3964df2ea85039262f4871b713e24aeb4d095`として検証した。
- 指摘6件を実コードで再現して修正した。現在のclient generation、`Ready`、root threadが一致しないtool callはCoordinatorで拒否し、transport終了時にrootを無効化する。`thread/realtime/started`は既存rootを変更できず、別root transcriptも採用しない。
- Panel open / close、AI-native / Voice設定変更、reset、disposeをauthorization epochへbindingした。resetは設定保存だけでなくVoice runtimeを停止し、承認ダイアログ表示後とBroker execute直前にもepochを再確認する。無効化後は既存Calendar read cacheも返さない。
- call identityをthread / turn / call IDへ固定し、tool+argsをfingerprintとして比較する。同じcall IDでtoolまたは引数を変えた再送はidempotency conflictとして拒否する。
- app-server stdout lineを1 Mi character、tool requestを20 KiB、argumentsを16 KiB、同時server request / pending tool callを各8件へ制限し、超過はfail closedにした。JSON-RPC error replyは`code / message / data`のlowercase wire形式を固定した。
- negative verifierはpre-ready tool call、mismatched root、transport generation切替、reset / authorization epoch、stale modal approval、tool substitution、oversized payload、pending overload、oversized protocol line、error wire casingを検査する。Critic delivery `return-d93b67beedc6244189005b6d854d25b5`は受入後に`processed` / `synthesis_completed_at=2026-08-15T04:12:37+09:00`へmark-doneした。

## ローカル検証

```text
swift build -Xswiftc -warnings-as-errors
  PASS

.build/debug/HoverPocket --verify-broker
  PASS / registry 11 descriptors / 10 handlers / Today Focus / Text-Voice route digest / 10 negative cases
  PASS / golden plan digest sha256:57c7e72e...a69d

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

GitHub Actions / implementation head 91aa8d3
  PASS / Windows Voice CI x 2 / Windows verify / macOS verify / PR Router

GitHub Actions / implementation head b8f830b
  PASS / Windows Debug + Release warnings-as-errors / 0 warning / 0 error
  PASS / Voice dynamic tools / Host approval / Broker execution / readback / idempotency verifier
  PASS / Windows Voice CI x 2 / Windows verify / macOS verify / PR Router

GitHub Actions / implementation head e53e14a
  PASS / Windows Debug + Release warnings-as-errors / 0 warning / 0 error
  PASS / Broker route-independent digest / route-specific execution identity / existing rollback and idempotency regression
  PASS / Windows Voice CI x 2 / Windows verify / macOS verify / PR Router

GitHub Actions / implementation head 33d45ad
  PASS / Windows Debug + Release warnings-as-errors / all deterministic Voice and existing Provider verifiers
  PASS / Windows Voice CI run 31832027003 and 31832020335
  PASS / Windows verify run 31832027020
  PASS / macOS Capability / Broker / Timer / Voice Lane / app-server run 31832027042
  PASS / PR Router run 31832023369
  PASS / PR #6 MERGEABLE / CLEAN / remote parity 0 / 0
```

## 未完了gate

1. AN2 PR #9は人間によるmerge待ちである。AN3は既に同じAN2 headを統合済みだが、AN2 merge後にmainとのparityを再確認する。
2. installed Codex version / generated schema / account / voicesを対象Windows実機でreadbackする。
3. origin限定microphone、WebRTC SDP / remote audio、1往復、safe closeを対象Windows実機で検証する。
4. 対象Windows実機でVoice intentからCalendar read / create、Timer start、Today Focusを呼び、Host approval、実Provider状態、event / timer / note ID readbackを確認する。
5. root-scoped child session cardsを実thread stateへ接続する。
6. macOS Voice Coordinatorをapplication-lifetime Host、Voice Lane、origin限定microphone / WebRTC transport、Capability Brokerへ接続し、両OS実音声gateを通す。
