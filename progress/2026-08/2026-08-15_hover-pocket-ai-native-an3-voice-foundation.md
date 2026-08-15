# HoverPocket AI-native AN3 Voice Foundation Integration

## 現在地

Draft PR #6のVoice Lane foundationをAN2のRegistry / Broker実装へ統合し、Windows / macOSの両方でapplication-lifetime runtime、origin限定microphone permission、WebRTC SDP / remote audio、VoiceからBrokerへのdynamic tool dispatchまでproduction経路へ接続した。両OSのText / Voice / Native UIで共有するroute-independent canonical plan digestと、current root配下だけを表示するchild / descendant session cardsも実装済みである。これはAN3完了ではなく、対象実機のマイク・remote audio・音声1往復・実Calendar操作と、Windows実機のinstalled schema probeが残っている。

## Git / worktree

- worktree: `/Users/shotaro/code/share/hover-menu-preview-ai-native-an3`
- branch: `feature/codex-voice-lane`
- branch開始head: `374aa6a39b5860ebfb6cd944a62f08106c72cff4`
- 統合対象AN2 head: `5d7cbe1ba6be44261c578ea3195d7fe5ccb03d45`
- AN2実装と両OSのVoice Lane表示基盤をmerge commit `52bf00c`で統合し、AN2最終進捗commit `15e44f0`もmerge commit `cdc5a8f`で取り込んだ。
- AN2 Ready PR [#9](https://github.com/shotaro311/hover-pocket/pull/9)はWindows / macOS / PR Routerが全成功、MERGEABLE / CLEANのreadback後にmergeした。`origin/main`は`014032d412ab488c5e526f1ed2e7d23218c38a87`、AN3は通常merge commit `90bd31fd9a772387027add6c93414d7882b3eed5`で同期した。Draft PR #6は未マージのまま維持する。

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
- このUI骨格の実装時点ではViewModelは実音声runtimeへ未接続だった。後述の追加統合でtranscriptとroot-scoped child / descendant session cardsをproduction runtimeへ接続済みである。実音声E2Eが終わるまで、AN3 release gateは閉じない。

## Windows Host-owned Voice Lane UI骨格

- `PanelBridgeController.BuildState()`へrequested settingとdisplayごとに解決したeffective layoutを分けて公開し、`settings.setCodexVoiceEnabled` / `settings.setCodexVoiceLayout`を追加した。
- `DisplayLayoutService`へVoice Lane設定を接続し、Expandedが収まらない画面ではCompactへ縮退する。`DisplaySurfaceLayout`が解決済みlayoutを保持し、表示先の切替時もWebView stateと物理window geometryを一致させる。
- `HoverShellController`は設定・表示先変更時にPanel全体だけをresizeする。WebView内の`Header + ProviderHost`は既存baselineを保ち、その下へVoice Laneを通常rowとして追加した。
- Compactは視覚タイトルなし、波形64px以下、会話欄優先、背景click無効、明示toggle、fullscreen affordanceなし。Expandedは左transcript / 右current root配下session cardsの2列と内部scrollを持つ。
- Settingsへdefault-off toggleとCompact / Expanded pickerを追加した。後続統合でproduction Voice runtimeへ接続し、start / mute / endとcurrent root配下session cardをHost bridgeからtyped stateとして返す。
- `--verify ui-model`へ設定round-tripとbridge dispatch、`--verify voice-lane-layout`へ短画面縮退、`--verify ui`へCompact / Expanded描画とProvider rect不変を追加した。

## Windows Voice runtime / WebRTC

- `CodexVoiceRuntimeHost`がapp lifetimeでCoordinatorを所有し、設定の有効化時だけexperimental app-serverを起動する。`initialize`後にaccountとvoice capabilityを確認し、signed-out / incompatibleはfail closed、process crashはbounded backoffで再起動する。
- Panel WebViewのマイク許可は、exact origin `https://app.hoverpocket.local`、ユーザー操作、Voice有効、Panel表示中、8秒以内のsingle-use armをすべて満たす場合だけ許可する。許可はprofileへ保存せず、その他のpermissionは拒否する。
- `thread/realtime/start`はisolated workspace、read-only sandbox、approval `never`、永続root threadで開始する。初期実装時はWebRTC対応の`v1`だったが、同日のMac実音声PASSを正本として現在は`v3` / `includeStartupContext=false`へ更新した。SDP offer / answer、remote audio、mute、transport detach、stop / closedをtyped Bridgeで接続し、audioとfull transcriptはHoverPocketへ保存しない。
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
- `CodexVoiceCoordinator`はaccount / voice gate、persistent root thread、read-only isolated workspace、WebRTC `thread/realtime/start` / SDP、memory-only bounded transcript、mute / stop、bounded restartを持つ。この基盤実装時点ではdynamic toolは空だったが、後述の追加統合でHost UI / microphone / Capability Brokerへ接続した。
- fake Python app-serverを使う`--verify-codex-app-server`をmacOS CIへ追加した。初期化、malformed isolation、未対応server request拒否、timeout後の回復、transport終了、child process cleanupを検査する。ローカルと最終CIで成功した。

## ChatGPT Pro Criticと安全性remediation

- Critic run `20260815-031722-hoverpocket-an3-windows-voicecapability-broker-exact-diff`は通常Chat / GPT-5.6 Sol / Pro、GitHub read-only、外部操作なしでexact diffをレビューした。自動parserが4連backtickのartifactを認識しなかったため、保存済みresponseを同一runへcanonical ingestし、`critic-review.md` 34,451 byte、SHA-256 `68f0715fe28e8799c4d2780877c3964df2ea85039262f4871b713e24aeb4d095`として検証した。
- 指摘6件を実コードで再現して修正した。現在のclient generation、`Ready`、root threadが一致しないtool callはCoordinatorで拒否し、transport終了時にrootを無効化する。`thread/realtime/started`は既存rootを変更できず、別root transcriptも採用しない。
- Panel open / close、AI-native / Voice設定変更、reset、disposeをauthorization epochへbindingした。resetは設定保存だけでなくVoice runtimeを停止し、承認ダイアログ表示後とBroker execute直前にもepochを再確認する。無効化後は既存Calendar read cacheも返さない。
- call identityをthread / turn / call IDへ固定し、tool+argsをfingerprintとして比較する。同じcall IDでtoolまたは引数を変えた再送はidempotency conflictとして拒否する。
- app-server stdout lineを1 Mi character、tool requestを20 KiB、argumentsを16 KiB、同時server request / pending tool callを各8件へ制限し、超過はfail closedにした。JSON-RPC error replyは`code / message / data`のlowercase wire形式を固定した。
- negative verifierはpre-ready tool call、mismatched root、transport generation切替、reset / authorization epoch、stale modal approval、tool substitution、oversized payload、pending overload、oversized protocol line、error wire casingを検査する。Critic delivery `return-d93b67beedc6244189005b6d854d25b5`は受入後に`processed` / `synthesis_completed_at=2026-08-15T04:12:37+09:00`へmark-doneした。

## macOS production Voice / WebRTC / Broker追加統合

- `AppDelegate`がAI-native Brokerと`TodayFocusTextAdapter`を1回だけ構成し、`HoverWindowController`のapplication-lifetime Voice runtimeへ渡す。Voice有効化時だけCodex app-serverを起動し、全Provider共通のVoice Laneへsnapshot / transcriptを反映する。
- 非永続WKWebViewをRender / WebRTC transportだけに限定した。exact custom origin、main frame、microphone-only、表示中、明示開始から5秒以内のsingle-use armをすべて満たす場合だけ許可し、音声は保存しない。Promiseを返す`start` / `acceptAnswer`は`callAsyncJavaScript`で待ち、JavaScript / Swift双方のoperation IDとepochでclose後のマイク・接続復活を拒否する。
- Coordinatorはthread生成前からnegotiation attemptを予約するsingle-flightへ変更した。client generation、root generation、attempt ID、UTF-8 131,072 byte上限をSDPへbindingし、timeout / stop / close / transport crash時はpending waiterを必ず完了させる。restart backoffのキャンセルを握りつぶさず、disable / dispose後に新しいCodex processを起動しない。
- Voice toolはCalendar today / create、Timer start、Today Focusの4件で、現在rootとauthorization epochへbindingする。Calendar read toolはHost設定の`calendar.events.read`が明示ONのときだけdynamic toolへ登録し、grant変更時はruntimeを安全に再構成する。write承認はCancelをReturn既定、Escapeをreject、Allowを明示2番目操作にし、表示したcanonical引数とBroker planを一致させる。
- Codex Security scan `47bd0464-3c05-44cc-9e9f-196393d8ee5e`のmedium 1件 / low 2件をreadbackした。Calendar read自己grantをHost-owned persisted grantへ移し、close animation開始前にsurface-activeをfalseへし、approval既定Allowを廃止した。実Calendar mutationと実マイク / remote audioはscanの制限どおり未検証である。

## ChatGPT Pro Critic追加回収と修正

- run `20260815-045421-hoverpocket-an3exact-diff-3d319d4-ab50042macwkwebview-webrtcapp-server-lifecyclewindowscliverifier`は通常Chat route、Oracle model `gpt-5.6-sol`、Pro thinking、critic、GitHub read-only、外部操作なしで実行した。Project targetは検証済みだが、会話URLとUI model-selection checkpointは未確認である。
- canonical artifactは`critic-review.md` 23,646 byte、SHA-256 `7d4f589a415e321ac7a45a29229a2eb2f21c66543407c792e2a821fd44f6229a`。verdictはCHANGES REQUESTED、P1 5件 / P2 1件で、Promise bridge、restart cancellation、JavaScript operation epoch、SDP attempt identity、Windows async verifier exception、Swift UTF-8 byte境界を指摘した。
- 6件をすべて修正し、`codex_voice_webrtc_epoch`、`codex_voice_sdp_attempt_isolation`、`codex_voice_restart_cancellation`とWindowsのinjected verifier failure gateを追加した。最終実装headでローカル検証receiptをPASSとして記録し、Pro runのrelease gateは`ready_for_publish=true`になった。

## root-scoped session cardsとinstalled Codex live probe

- macOS / WindowsのCoordinatorが`thread/list`をcurrent rootの`ancestorThreadId`、明示`sourceKinds`、同じVoice session IDで取得し、parent chainがcurrent rootへ到達するchild / descendantだけを採用する。opaque cursorは1ページ64件、最大8ページ / 512件まで追跡し、cursor cycle、過大page、malformed continuationでは既存snapshotを維持してfail closedとする。
- 同一thread IDが複数recordへ現れた場合は全recordを破棄し、そのIDをparentにするdescendantも到達不能として除外する。UI IDは`root:<server-id>` / `thread:<server-id>`へ名前空間化し、serverの`current-root`等と衝突しない。
- `thread/read includeTurns=true`はthread / session / parent / updatedAtをkeyに、identity検証済みmessageまたは検証済みno-messageだけをcacheする。RPC失敗、timeout、identity mismatch時のpreview fallbackはcacheせず、同じupdatedAtでも次pollで再readして回復する。
- WindowsのWebRTC negotiation失敗はmacOSと同じくfailed attemptのroot、child cards、poll、read cache、tool routing contextをatomicに破棄する。再試行は新しい`thread/start`を使う。Unix timestampは両OSとも`0 < seconds <= 253402300799`へ統一した。
- ChatGPT Pro Critic run `20260815-064708-hoverpocket-an3-root-scoped-session-cards`は通常Chat route、Oracle model `gpt-5.6-sol`、Pro thinking、critic、GitHub read-only、外部書き込みなしでexact diff `131467d8...fdd6d86`をレビューした。本文内artifactはP1 2件 / P2 3件 / P3 2件、response SHA-256 `d4f5b9844213886599bef4ce2b64ab30188bf47b4c83a21b5aa52ddf64f618ae`で完全回収した。自動artifact parserが`critic-review.md`を別ファイルへ抽出できずreceiptは`blocked`のため、この警告は消さずにCodexの実コード再確認とローカル検証を受入根拠にした。
- 両OSfixtureは2ページ取得、read初回失敗からの回復、conflicting duplicateと配下除外、UI sentinel衝突、cross-root readback、Windows negotiation失敗後のroot破棄 / 新root作成、exact list requestを検査する。実装head `0ca7834b07795a8b546ea125ac8928b730f67800`のWindows Voice CI 2本、通常Windows、macOS、PR Routerは全成功した。
- macOSへ`--verify-codex-app-server-live`を追加した。accountやrate limitの中身、voice名、token、stderr本文は出力せず、initialize / account readiness / rate limit availability / voice count / default voice / protocol counterだけをreadbackする。
- Mac実機のCodex CLI `0.145.0`でlive probeはaccount ready、rate limits ready、voice 19件、default voice ready、malformed / unknown 0件でPASSした。`generate-json-schema --experimental`は347 files、bundle digest `19e2a84b...2311`で、Realtime / account methodと`ancestorThreadId` / `sourceKinds` / `useStateDbOnly` / `includeTurns`を確認した。
- Windows実機のCodex CLI `0.147.0`では、隔離clone / detached / cleanのhead `0ca7834`でexperimental schema、phase0 KeepRawなし、initialize / account / rateLimits / listVoices、voice 19件がPASSした。`account/rateLimits/read`はrequest keyが`method,id`だけでwire上の`params`が省略され、schemaと一致した。Debug / Releaseは0 warning / 0 error、workflow相当18 / 18 VerifierとJavaScript 13 / 13、task-scoped process残存0、remote parity一致をreadbackした。

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

.build/debug/HoverPocket --verify-codex-app-server-live
  PASS / Codex CLI 0.145.0 / account ready / rate limits ready
  PASS / voice count 19 / default voice ready / malformed 0 / unknown 0

.build/debug/HoverPocket --verify-codex-app-server
  PASS / fake transport / WebRTC / restart / tool dispatch / root-scoped sessions

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

GitHub Actions / implementation head a822916
  PASS / Voice Lane Windows CI runs 31841209115 and 31841213311
  PASS / Windows verify run 31841213324
  PASS / macOS verify run 31841213322
  PASS / PR Router run 31841211479
  PASS / injected UiModel exception exits with code 1 instead of hanging
  PASS / PR #6 MERGEABLE / CLEAN / remote parity 0 / 0

GitHub Actions / implementation head 0ca7834
  PASS / Voice Lane Windows CI runs 31845753392 and 31845756516
  PASS / Windows verify run 31845756521
  PASS / macOS verify run 31845756517
  PASS / PR Router run 31845754575
  PASS / Windows real-device read-only gate / Codex 0.147.0 / phase0 / 18 verifiers / process residue 0
```

## 未完了gate

1. origin限定microphone、WebRTC SDP / remote audio、1往復、safe closeを対象Windows / macOS実機で検証する。
2. 対象Windows / macOS実機でVoice intentからCalendar read / create、Timer start、Today Focusを呼び、Host approval、実Provider状態、event / timer / note ID readbackを確認する。

## macOS隔離Voice E2E受入基盤

- 製品版HoverPocketとユーザーデータを上書きせず、LaunchServices / TCCが同じ検証アプリを追跡できる安定した`dist/HoverPocketVoiceE2E.app`と、毎回freshな0700 temp data rootを作る`--voice-e2e-build-only` / `--voice-e2e-run`を追加した。bundle ID、実行名、Keychain namespaceを分離し、Google OAuth、Sparkle feed、installer launcherを無効化した。再build前は検証用processだけを終了し、製品processには触れない。
- DEBUG時だけ`HOVERPOCKET_ISOLATED_E2E=1`とsystem temp配下の`HOVERPOCKET_TEST_DATA_ROOT`を受け入れ、Audit、Clipboard、Sticky、Timer、Broker、Voice workspaceを隔離data rootへ向ける。Releaseは同じ環境変数を無視し、通常のApplication Supportを使う。
- 検証用署名は`HoverPocketVoiceE2E.entitlements`へ分離し、microphone entitlementだけを持たせた。製品用のcamera / Apple Events entitlementは検証bundleへ含めない。
- `voice-e2e-receipt.json`はavailability、session、root / transport、transcriptのrole別件数、app-server / voice数、microphone / remote audioの取得・現在状態だけを保存する。生transcript、音声、SDP、token、file path、Provider dataは保存しない。
- 隔離bundleの署名、bundle ID、実行名、LSEnvironment、OAuth / Sparkle key不在、installer launcher false、0700 temp rootをreadbackした。起動後はCodex app-server ready、voice 19件、feature enabled、microphone未取得、remote audio未取得で待機し、既存製品processは継続稼働した。
- Compact / Expandedの実画面は`600x494` / `600x650`で、幅とProvider領域を変えずVoice Lane分だけ下へ伸びた。Compactは視覚タイトルなし、短い波形、会話優先、明示expand、Expandedは左会話 / 右current-root session cards、明示collapse、fullscreenなしで契約と一致した。
- WebViewのmedia permissionだけでTCCへ進めていた経路を修正し、明示mic click後にnative `AVCaptureDevice` authorizationを確認し、未決定ならOS許可を要求、許可済みの場合だけ5秒single-use armを再発行してWebView `getUserMedia`へ進む。denied / restricted / unknownはWebRTC開始前にfail closedとし、failure時はarmを消去する。policy verifierはauthorized / notDetermined / denied / restrictedを固定した。
- 安定bundleのLaunchServices登録、Codex app-server ready、voice 19件、feature enabled、native許可要求、receiptのsession=`requestingPermission`を実機readbackした。TCCの明示許可、microphone取得、remote audio、音声1往復、safe closeは未完了である。auto-listenはOFFのため、ユーザーのmic click前に権限要求や音声取得は発生しない。

## 追加検証

```text
swift build -Xswiftc -warnings-as-errors
  PASS

swift build -c release -Xswiftc -warnings-as-errors
  PASS

.build/debug/HoverPocket --verify-codex-app-server
  PASS / native microphone policy / exact-origin WebView policy / WebRTC / epoch / restart / tool dispatch / root-scoped sessions

.build/debug/HoverPocket --verify-broker
  PASS / 11 descriptors / 10 handlers / Today Focus / Voice tools / negative cases

.build/debug/HoverPocket --verify-capabilities
  PASS / 10 handlers / Timer / Sticky / Calendar readback

.build/debug/HoverPocket --verify-voice-lane-layout
  PASS / 8 render cases / Compact 64 / downward expansion / Provider rect invariant / default-off

DEBUG --verify-application-data with isolated env
  PASS / isolation requested=true / effective=true

RELEASE --verify-application-data with isolated env
  PASS / isolation requested=true / effective=false / release override disabled=true

Codex Security scan 04214399-d7ba-4a97-8007-63ab89259da1
  PASS / 11 of 11 changed files / coverage complete / finding 0 / sealed

GitHub Actions / isolated E2E implementation head d916c1d
  PASS / Voice Lane Windows CI runs 31851023897 and 31851024054
  PASS / Windows verify run 31851024094
  PASS / macOS verify run 31851024055
  PASS / PR Router run 31851022775
  PASS / Draft PR #6 MERGEABLE / CLEAN / remote parity 0 / 0

GitHub Actions / native microphone gate head eaf8db4
  PASS / Voice Lane Windows CI runs 31860148084 and 31860150830
  PASS / Windows verify run 31860150992
  PASS / macOS verify run 31860150901
  PASS / PR Router run 31860149039
```
