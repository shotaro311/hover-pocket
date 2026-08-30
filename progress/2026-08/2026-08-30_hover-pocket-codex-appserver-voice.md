# 2026-08-30 HoverPocket macOS Codex app-server Voice

## 結論

macOS Voice Laneの標準providerをCodex app-serverへ接続した。これはOpenAI APIキーを使うRealtime BYOK経路ではなく、ローカルCodexのログイン状態とapp-serverを使う経路である。Capabilityの正本は引き続きHoverPocketのRegistry / Brokerで、CodexはCalendar read/createとTimer startだけを同じBroker経由で実行する。

実装基盤と決定論的検証に加え、ChatGPT.app同梱Codex app-server `0.150.0-alpha.12.2`でChatGPT account、19 voices、ephemeral root thread、SDP answer、WebRTC接続、process teardownまで実接続した。さらにChatGPTログインの実CodexターンがTimer toolを選び、Broker承認、一時Timer、readbackまで完了することも確認した。OpenAI APIキーと物理マイクは使用していない。Homebrew Codex `0.145.0`はtool route不一致、隔離した公式`0.149.0`は現行backendとのRealtime session契約差で停止するため、通常解決順は互換性を実証したChatGPT同梱Codexを優先する。さらに製品と同じDeveloper ID要件の隔離candidateから、既存Google credentialと実Calendarを使ったVoice origin Calendar readをBroker / readback込みで成功確認した。

## 実装

- Codex app-server JSON-RPC client、account / voice確認、root thread、Realtime WebRTC SDP、transcript、root-scoped child session cardをmacOS Hostへ接続した。
- app-server dynamic toolは既存Capability Runtimeから生成し、Calendar read/create、Timer startを既存Broker、承認、監査、readbackへ委譲した。
- Voice専用`CODEX_HOME`を作成し、shell、MCP、app、plugin、web、image、multi-agentなどをconfigで無効化する。directoryは0700、configは0600とし、owner-onlyの既存Codex `auth.json`だけをsymlink参照する。
- installed Codex schemaに加え、local loopback providerへ実際に送られるResponses requestを起動前canaryで捕捉する。outbound `tools`の件数・名前がHost指定dynamic toolと完全一致した場合だけReadyにする。
- `account/read`は`requiresOpenaiAuth=true`かつ`account.type=chatgpt`だけを許可する。API key、Amazon Bedrock、custom provider、signed-outはVoiceを開始せず、BYOKへ自動fallbackしない。
- probe対象の実行ファイルURLとsize / mtime / inode由来identityを保持し、spawn直前と再起動ごとに同一性を検査する。PATHの再解決で別binaryへ切り替わらない。
- version応答、専用profile、tool digestもcache keyへ含める。Readyまたは決定論的なschema / route不一致だけをcacheし、一時的なtimeout、loopback、transport障害は次回初期化で再検査する。version subprocessは5秒、schema subprocessは15秒、route canaryは8秒、WebView readyは2秒、Voice開始全体は30秒で有限化した。
- WebRTC切断はserver Realtime stopとVoice Laneのdisconnected状態へ接続した。stop RPCはsingle-flightで共有し、provider切替、grant変更、失敗cleanupの重複を抑止した。
- app-server stdout / stderr chunkはstreamごとのserial queueから単一AsyncStream consumerへ渡し、stdout notificationも順番に処理する。
- transcript publishは67ms単位、root card timestampは固定、Expanded child session pollは接続中だけ3秒ごと、最新16件、thread/read最大4並列に制限した。
- Settingsは`Off / Codex app-server（推奨） / Realtime BYOK`の順とし、BYOKは明示選択時だけ利用し自動fallbackしない。
- Codex実行ファイルは、明示`HOVERPOCKET_CODEX_EXECUTABLE`の次にChatGPT.app同梱binaryを評価し、その後にHomebrew / local CLIへ進む。自動検出では各candidateを順にprobeして最初のReadyを採用し、明示指定はその1件だけを検証する。compatibility probe後は実行ファイルidentity、version、専用profileを固定してTOCTOUを防ぐ。
- `--verify-codex-app-server-realtime`を追加した。物理マイクpermissionを要求せず、非永続WKWebView、外部ICE serverなし、gain 0のWeb Audio track、data channelでoffer / answerを実接続し、tool execution 0、app-server process終了、一時workspace消滅まで検証する。
- Realtime error / SDP前closeはpending SDP waiterへ即時返却する。これにより上流契約不一致を`30秒timeout`と誤表示せず、安全化したcategoryだけをUI / verifierへ返す。v3のvoice既定値はapp-serverへ委譲し、HoverPocketからAPI model / API keyは渡さない。
- 隔離Voice E2Eの既定providerをRealtime BYOKからCodex app-serverへ変更した。receiptの認証状態はOpenAI keyの有無を固定参照せず、選択中providerがBYOKならkey、Codexならapp-server account readinessをreadbackする。
- Codex WebRTCのmic取得、remote audio track、remote audio playbackをreceiptへ接続し、mic取得と実再生の両方が揃ったattemptだけHost所有の確認sheetを一度表示する。旧attemptのsheet応答はattempt IDで拒否し、通常版ではreceipt storeが`nil`のため追加処理は即時終了する。
- E2E harnessの案内をCodex app-serverへ更新した。API keyを引数・環境変数・設定へ要求せず、Voiceは隔離設定画面で明示的に有効化する。
- `--verify-codex-app-server`を拡張し、local loopback Responses providerが決定論的なTimer function callを返す。実Codex app-serverから届いた`item/tool/call`を同じBridge、Capability Runtime、Registry / Broker、承認、Timer実行、readbackへ通し、replyをapp-server pipeへ書いた後にだけ成功とする。Calendar read/create、Timer approval / reject / replayは外部データを使わない一時fixtureでも縦断確認する。
- `--verify-codex-app-server-model-tool`を追加した。ChatGPT accountを`account/read`で確認し、指定値`gpt-5.6-sol / medium`のephemeral turnを実Codex app-serverへ送り、Timer-only dynamic tool、単一tool call、Host承認1回、Bridge、Registry / Broker、readback、`turn/completed`、process終了、一時workspace消滅を確認する。実採用model / effortはapp-server protocolからreadbackできないため、出力は`requested_model / requested_effort`と明記する。明示CLI以外から呼ばれず、Calendar access、API key、既存Timerは使用しない。

## 独立レビュー

別エージェントへ、安全対策が正常動作や性能を損なっていないかをread-onlyレビューさせた。初回P1はinstalled readiness表示、binary pin、subprocess timeout、WebRTC timeout / cancel、切断状態、stop重複、stdout順序の7件で、すべて局所修正した。さらにambient要求の入力順隔離、pending / current / 旧clientのidentity + generation分離、隔離後の再起動禁止まで再レビューし、最終結果はP0 / P1とも0件だった。

Broker限定policy、read-only sandbox、approval never、空workspace roots、root / generation / call / tool照合、非永続WebView、CSP、trusted custom scheme、5秒microphone armingは、過剰安全ではなくCapability境界に必要なため維持した。ambient分類とquarantineだけをstdout consumerで短く順序処理し、通常tool本体はその後にTask化するため、危険な要求の追い越しと長時間toolによるstdout停止を同時に避ける。

専用app-server profileとroute canaryの追加差分も別エージェントが再レビューした。API key accountをChatGPT loginとして誤受入れするP1と、一過性timeout / loopback / transport失敗をアプリ終了までcacheするP2を検出し、ChatGPT account限定と決定論的結果だけのcacheへ修正した。最終P0 / P1は0件。route canaryは公式0.149で0.27〜0.65秒、Voice設定時の初回1回だけでmic開始hot pathには入らず、app-server常駐も会話状態保持と次回高速起動のため妥当と評価された。

ChatGPT.app同梱Codexのlive接続差分を同じ別エージェントが再度read-onlyレビューした。candidate fallback、起動直後PID記録、SIGKILL後の終了待ち、fallback対応cache検証、OneShot競合、WebRTC cleanup、v3 voice選択を確認し、未使用のlegacy default voiceキーを必須にする過剰validationだけを削除した。最終結果は今回差分でP0 / P1 / P2すべて0件。live verifierのWebView、無音oscillator、最大0.5秒のcleanup待ちは明示検証コマンド内だけで、通常のhover / Voice開始hot pathには入らない。

物理E2EのCodex統一差分も別エージェントが独立レビューした。通常版ではreceipt storeが`nil`で、追加したfile writeと確認sheetは実行されない。E2E内もmedia event単位であり毎フレーム処理ではなく、operation IDとattempt IDでstale event / 旧sheet応答を拒否する。warnings-as-errors build、Voice Foundation、E2E isolation、receipt self-testを再実行し、P0 / P1 / P2すべて0件だった。

Calendar読み取り専用gateも同じエージェントが独立レビューした。初回は、Calendar検証が全Providerを組み立ててTimer singletonへ触れる点、Keychain preflight後にCalendar storeが資格情報を再読する点、token refresh失敗時に保存credentialを削除し得る点をP1として検出した。CalendarList handlerだけのRegistry、5秒上限で一度だけ読み込むpreloaded credential、credential mutationを無効にしたOAuth serviceへ修正し、最終P0 / P1 / P2は0件となった。通常経路は既定値が従来どおりで、新しい分岐は明示CLI flag時だけ実行する。

実Calendar初回実行で、private read共通3秒timeoutがURLSessionを取消し、Calendar取得を`URLError -999`で失敗させる過剰制限を検出した。Calendar get / listだけ15秒・30 calls/minへ分離し、Timerなどローカルreadは3秒を維持した。別エージェントは15秒上限、非同期待機、固定診断、個人情報非出力、他Capability非波及を再レビューした。Broker timeoutと取消由来`-999`の診断優先順位も修正し、最終P0 / P1 / P2すべて0件となった。

実app-server tool call検証も別エージェントが独立レビューした。初回はBridgeへ直接生成requestを渡すだけでapp-server本体のrequest shape driftを検出できないP2が1件あった。公式Responses streaming eventに沿うfunction callをloopback providerから返し、実Codex app-server発の`item/tool/call`、Bridge、Broker承認、Timer単一効果、readback、reply書込みを確認するよう修正した。通常compatibility probeはfunction callを発生させず、追加縦断は明示CLIだけで約1.02秒だった。再レビューはP0 / P1 / P2すべて0件である。

実モデルtool選択検証も同じ別エージェントがread-onlyレビューした。初回P2は、指定model / effortを実採用値のように表示する点と、app-server起動前の初期化失敗だけ一時workspaceが共通cleanup外になる点だった。出力を`requested_model / requested_effort`へ変更し、root作成直後のunconditional cleanupと成功後の不存在readbackを併用した。最終P0 / P1 / P2は0件で、完全一致の明示CLI分岐だけに存在するため通常起動、Hover、Voice開始hot pathの性能影響は実質0と評価された。

keyring-only Codex loginの実装制約は、Voice専用profileでChatGPT managed browser loginを開始する経路を追加して解消した。owner-onlyのfile-backed `auth.json`がある場合は従来どおりsymlink参照を優先し、HoverPocketのUIから外部credentialへlogin / cancel / logoutを実行しない。専用managed fileはcurrent-user所有・private permissionをreadbackする。実ブラウザログインとfile-backed認証からの移行はアカウント操作を伴う人手E2E gateとして残す。

## 検証とreadback

- 隔離E2E専用の`voice-e2e-performance.json`を追加した。固定schemaは現在attemptのattached有無、mic開始意図→attachedの直近10 sample / p95、snapshot publish、Expanded RPC、Realtime stop RPC、最大stop、計測時間、安全なevent名だけを保持し、会話本文、予定、tool引数、認証情報を保存しない。通常版はperformance storeが`nil`で、writer queueとfile I/Oを生成しない。
- 書込みはutility直列queueへ移し、mic開始と会話中の同期I/Oを避けた。現在attemptのattached状態を履歴sampleから分離し、final transcript、Timer readback、物理確認、safe closeでreadback可能なsnapshotをflushする。E2Eアプリ終了時だけ同期safe closeを行い、stopped receiptが一つ前のeventになる競合を除去した。
- 独立レビューは初回P1 2件 / P2 2件と、修正後P2 1件を検出した。すべて修正後のexact diffを再レビューし、最終P0 / P1 / P2は0件。通常起動 / Hover / Voiceは小さなnil分岐だけで、追加CPU、I/O、同期待機、Voice開始latencyへの実質的影響なし。E2E内の既存receipt同期書込みによるmic→attached値のごく小さい上振れだけを許容した。
- 新しい隔離E2EビルドでBuild / Run / Readback / ValidateIsolation / Stop / Cleanupを通過した。安定後10秒の外部process計測は21 sample、CPU平均0.157%、p95 0.2%、最大0.2%、RSS平均109.234 MiB、最大109.281 MiB。opt-in前なのでmedia attempt、snapshot、Expanded RPC、stop RPCは0。停止後はperformance receiptの`safe_close`とno-media stop 0をreadbackし、task生成のruntime / build / sessionをTrashへ移した。物理E2E PID 56971は停止せず稼働継続を確認した。
- 修正後のDebug / Release warnings-as-errors build、performance / physical receipt self-test、Voice静的42件、Voice E2E isolation、Capability 20 handler、Broker 21 descriptor / 20 handler、Pocket Surface / Pocket App / Timer / Panel 128 cases、Pocket contract 15 schema / 71 fixtureを2回、release readback 23 unit testがPASSした。Codex app-serverはChatGPT account、Timer model tool、承認1回、Broker readback、19 voices、ephemeral thread、SDP / WebRTC、process teardownまで再確認し、OpenAI API keyは使用していない。

- `swift build -Xswiftc -warnings-as-errors`: PASS
- `swift run --skip-build HoverPocket --verify-voice-foundation`: PASS
- `swift run --skip-build HoverPocket --verify-codex-app-server`: foundationとinstalled readinessがともにPASS
- `--verify-codex-app-server`: 実Codex app-server発の`item/tool/call`からTimerのBroker承認・実行・readback・reply書込みまで`codex_app_server_broker_invocation=verified`。外部Calendar / 既存Timer / API keyは未使用、明示CLI実測1.02秒
- `--verify-codex-app-server-model-tool`: ChatGPT account、requested `gpt-5.6-sol / medium`、`timer_countdown_start`、承認1回、一時Timer単一効果、Broker readback verified、turn completed、process closed、一時workspace残存0でPASS。最終実測8.03秒。実採用model / effortは未readbackのためrequested値としてのみ記録
- 環境変数なしの`--require-codex-app-server-ready`: ChatGPT.app同梱Codexを解決しPASS
- 環境変数なしの`--verify-codex-app-server-realtime`: `account=chatgpt`、voices 19、ephemeral thread、SDP / WebRTC connected、process closedでPASS。最終修正後の独立process 3回は2.171 / 2.312 / 2.224秒、失敗0、一時workspace残存0
- ChatGPT.app同梱Codex `0.150.0-alpha.12.2`: live verifier PASS。OpenAI API keyと物理マイクは未使用
- 隔離した公式Codex `0.149.0`: route / ChatGPT account / 19 voicesはPASS、SDP開始は約2.35秒で`realtime_error_realtime_model_session`を即時readback。旧30秒timeoutは解消
- Homebrew Codex `0.145.0`: 実canaryでHost指定外toolが混入するため`codex_broker_only_tool_route_mismatch`でfail closed
- `swift run --skip-build HoverPocket --verify-capabilities`: PASS、20 handler
- `swift run --skip-build HoverPocket --verify-broker`: PASS、21 descriptor / 20 handler
- `python3 script/verify_voice_foundation.py`: PASS、42 cases。app-server request admissionの順序、client quarantine、lifecycle / generation分離、probe timeout / executable pinも静的回帰で確認
- `python3 script/verify_pocket_contracts.py`: PASS、15 schema / 71 fixture
- `python3 -m unittest script.tests.test_verify_release_readback`: PASS、23 tests
- `git diff --check`: PASS
- 隔離E2E app bundle: build PASS、executable存在、`codesign --verify --deep --strict` PASS、microphone purpose stringにCodex app-serverを含むことをreadback。
- 修正後のDebug / Release `swift build -Xswiftc -warnings-as-errors`: PASS
- `swift run --skip-build HoverPocket --verify-voice-e2e-isolation`: PASS。Codex app-server既定、Voice default-off、Timer-only registry、ephemeral settings、外部integration拒否を確認
- `python3 script/verify_macos_voice_e2e_receipt.py --self-test`: PASS。Codex providerのphysical / stopped gateを確認
- 修正後の環境変数なしlive verifier 3回: 2.86 / 2.24 / 2.19秒、3回ともChatGPT account、19 voices、ephemeral thread、SDP / WebRTC connected、process closed
- ad-hoc署名の隔離E2Eアプリを実起動し、process所有、fresh temp runtime root、receipt存在、Codex app-server選択済み、Voice opt-in前の`featureEnabled=false / disconnected`、mic / remote audio / Timer readback / confirmationが未実行であることをreadback。Settingsの表示も「Codex app-server（推奨）」「APIキーは不要」を確認
- `--verify-calendar-capability-read-only`: grantなしは`calendar_read_grant_required`、bundle設定なしは`calendar_configuration_missing`でCalendar / browserへ到達せず停止。通常署名設定を複製した署名済み一時candidateは既存Keychain itemへのアクセスを5秒で`calendar_credential_check_timed_out`として停止し、Calendar API未到達、broker root残存0、一時candidate Trash移動をreadback
- Calendar verifierのCalendar-only Registry、Broker、readback、audit redaction、5秒Keychain上限、credential mutation禁止をVoice静的42件へ追加。Debug / Release warnings-as-errors、Capability 20 handler、Broker 21 descriptor / 20 handler、15 schema / 71 fixture、`git diff --check`が成功
- build 584隔離candidate: installed appと同じDeveloper ID、bundle ID、Team ID、Designated Requirement、`release` Keychain suffixをreadback。既存credentialを変更せず、Voice originの`calendar.events.list`が実CalendarとBrokerを2回通過した。最終実測3.16秒、`calendar_capability_readback=verified`、予定件数1、承認なし、audit redacted。候補は検証後Trashへ移動
- Calendar専用timeout回帰: 3秒ではBroker取消由来`URLError -999`、15秒では成功。Calendar get / listだけ15秒・30 calls/min、Timer getは3秒を`--verify-broker`で固定確認。独立性能・安全レビューはP0 / P1 / P2すべて0件
- 実モデルtool検証を含むcode commit `7194ff297df6c456d1ead2a88008e40826b36642`のDraft PR #39は、Router [33293498009](https://github.com/shotaro311/hover-pocket/actions/runs/33293498009)、macOS [33293498781](https://github.com/shotaro311/hover-pocket/actions/runs/33293498781)、Windows [33293498790](https://github.com/shotaro311/hover-pocket/actions/runs/33293498790)、3OS contract / compare [33293498775](https://github.com/shotaro311/hover-pocket/actions/runs/33293498775)、transition [33293498770](https://github.com/shotaro311/hover-pocket/actions/runs/33293498770)、release readback [33293498792](https://github.com/shotaro311/hover-pocket/actions/runs/33293498792)が成功。11成功・8 gate skip・失敗0・pending 0、Draft / OPEN / MERGEABLE / CLEAN、remote parity 0 / 0をreadback
- Calendar gate commit `a836856b570e7f949ab9081080c462d1ca6ce326`のDraft PR #39は、Router [33291040507](https://github.com/shotaro311/hover-pocket/actions/runs/33291040507)、macOS [33291041914](https://github.com/shotaro311/hover-pocket/actions/runs/33291041914)、Windows [33291041972](https://github.com/shotaro311/hover-pocket/actions/runs/33291041972)、3OS contract / compare [33291041947](https://github.com/shotaro311/hover-pocket/actions/runs/33291041947)、transition [33291041883](https://github.com/shotaro311/hover-pocket/actions/runs/33291041883)、release readback [33291041901](https://github.com/shotaro311/hover-pocket/actions/runs/33291041901)が成功。11成功・8 gate skip・失敗0・pending 0、Draft / OPEN / MERGEABLE / CLEAN、remote parity 0 / 0をreadback
- 実装commit `dc734a95f30e847cb70c705df8d67728178a578f`のDraft PR #39: Router [33289398813](https://github.com/shotaro311/hover-pocket/actions/runs/33289398813)、macOS [33289399447](https://github.com/shotaro311/hover-pocket/actions/runs/33289399447)、Windows [33289399448](https://github.com/shotaro311/hover-pocket/actions/runs/33289399448)、3OS contract / compare [33289399439](https://github.com/shotaro311/hover-pocket/actions/runs/33289399439)、transition [33289399443](https://github.com/shotaro311/hover-pocket/actions/runs/33289399443)、release readback [33289399458](https://github.com/shotaro311/hover-pocket/actions/runs/33289399458)が成功。公開成果物を必要とする8 gateは意図どおりskip、失敗0・pending 0。PRはDraft / OPEN / MERGEABLE。

## 配布bundle Realtime回帰と修正

- exact HEAD `9068d9674883a4916787dc62ef64e854dabfd97e`を`0.1.0 (597)`としてDeveloper ID署名・公証した。Apple submission `10bf95ad-0d86-4137-9336-cce2d8922937`は`Accepted`で、staple、Gatekeeper、app / ZIP再展開後のstrict codesign、SHA-256、Sparkle appcast、public dry-runはPASSした。しかし配布bundleの`--verify-codex-app-server-realtime`が失敗したため、build 597はRC不採用とし、公開していない。
- Debug / Release CLIは同じChatGPT account、19 voices、ephemeral thread、SDP / WebRTC、process teardownまでPASSした。Developer ID署名bundleだけは最初`realtime_probe_offer_unavailable`、ICE timeoutをbounded proceedへ変えた後は`realtime_probe_connection_unavailable`となり、WebKitログでmDNS host candidate登録失敗とcandidate pair未選択を確認した。raw SDP、ICE credential、候補addressは成果物、監査、進捗ログへ保存していない。
- verifierはWebKit例外を固定3段階codeへ変換し、本番と同じcustom URL scheme、非永続data store、検証中だけの1px offscreen host windowを使う。通常VoiceとverifierのICE収集はcandidateが3秒以内に得られれば早期継続し、未取得なら従来上限8秒まで成功余地を残し、8秒後は全体30秒上限下の接続判定へ進む。
- Apple TN3179のbundle app / 間接Bonjour境界に合わせ、`NSLocalNetworkUsageDescription`へWebRTC Voice接続だけの用途と周辺機器browseを行わないことを明記した。`NSBonjourServices`、multicast entitlement、外部TURN、API / BYOK fallbackは追加していない。現在の開発Macは署名bundleでLocal Network許可をreadbackできておらず、`realtime_probe_connection_unavailable`のため未完了gateである。
- 配布package scriptのprocess名停止が、維持対象だった隔離E2E PID 56971も停止した。同じruntime rootはfresh制約で再利用せず、新しいBuild / Run / Readbackでsession `HoverPocketVoiceE2ESession-4e6lUy`、runtime `HoverPocketVoiceE2E-wevAYd`、PID 70741を作り直した。build scriptはcanonical E2E引数を持つprocessを除外し、修正後のpackage実行前後でPID 70741が生存することをreadbackした。
- 独立レビューは初回、3秒一律確定が遅い正常candidateを捨てるP1を1件検出した。hybrid 3 / 8秒waitへ修正後はP0 / P1 / P2すべて0件。offscreen windowとsafe codeは明示verifier内だけ、追加purpose stringは起動処理なし、通常Voiceの追加処理は完了時に解除されるtimer最大2個で、CPU / RSS /通常起動への有意な悪化なしと判定された。
- Debug / Release warnings-as-errors、Voice Foundation、Capability 20、Broker 21 descriptor / 20 handler、Pocket Surface / App、Timer、Panel 128、E2E isolation、Codex foundation / model Timer / CLI Realtime、Voice静的42、Pocket contract 15 schema / 71 fixture、release readback 23 unit、receipt / performance self-test、shell syntax、`git diff --check`はすべてPASSした。
- commit `248539b05bccc7ece521a3d9c34bad5ae5e2ad7b`をDraft PR #39へpushし、CIは15 SUCCESS / 8 expected SKIPPED / failure 0 / pending 0。PRはDraft / OPEN / MERGEABLE / CLEAN、remote parity 0 / 0と別経路でreadbackした。merge / releaseは実施していない。

## 未完了gate

- 全candidateが非Ready、ChatGPT.app未導入、同梱Codexが将来非互換の場合の導入 / 更新UX。
- transcriptの実受信とroot-scoped session cardのlive readback。
- 起動中の隔離E2EアプリでVoiceを明示ONにし、物理マイク取得、remote audio再生、transcript、Timer start、承認、実行後readbackを人手確認する。人の発話と「話せた・聞こえた」確認は自動化・偽装しない。
- Calendar readはproduction accountと同じ署名・Keychain条件の隔離candidateで完了した。Calendar createは外部書き込みのため、予定内容を明示した承認と実行後readbackを別gateとして残す。
- 上記の実音声往復とCalendar / Timerを10回反復する。
- CPU / RSSの自動idle計測は完了した。mic clickからattachedまでのp95、snapshot publishes/sec、Expanded RPC/sec、stop RPC/session=1は、物理音声往復10回の人手gateで最終値を取得する。
- signed-out / keyring-only環境で、Settingsから実ChatGPT browser loginを完了・取消し、app更新後も専用credentialをreadbackするE2E。file-backed loginからmanaged fileへの移行も別途確認する。
- Draft PRのCIと人手レビュー。merge、release、既存notarized build 583の差し替えは未実施。

## Voice専用ChatGPT managed login

- `CodexVoiceAccountLoginController`を追加し、`account/login/start`へ`type=chatgpt`、hosted success page、ChatGPT brandだけを渡す。API key field、Device Code、external token、Bedrockは持たない。返却URLはHTTPSかつOpenAI / ChatGPT配下だけを許可し、login IDと完了通知を照合する。
- Voice専用profileは`cli_auth_credentials_store="file"`へ固定した。外部のowner-only file-backed credentialがあればsymlink参照を優先し、外部credentialにはHoverPocketからlogin / cancel / logoutを実行しない。外部fileがない場合だけ専用regular fileをmanaged対象にし、成功後は`account/read`のChatGPT account、current-user所有、group / other権限0をreadbackする。
- SettingsはCodex app-server選択時だけ状態確認、ChatGPTログイン、取消、再確認を表示する。Realtime BYOKのAPI key UIは明示provider選択時だけで、自動fallbackしない。Provider切替とapp終了は進行中loginを取消し、app-server processをcloseする。
- app-server候補解決とprofile準備はMainActor外へ移した。固定候補があればPATH探索を省略し、PATH-onlyの`which`は最大約2.5秒、候補選択は20秒、個別requestは最大8秒に制限した。失敗candidateはcloseして次へ進み、明示実行ファイルは単一候補を維持する。fallback終盤の短い選択timeoutは実loginへ持ち越さず、8秒clientへ入れ替える。
- 独立エージェントは初回から候補fallback、MainActor待機、終了再入、timeout持越し、managed不可時のprocess ownershipを段階的に検出した。全修正後のexact diffはP0 / P1 / P2すべて0件。先頭正常candidateは再起動せず、通常起動、Hover、マイク、remote audioのhot pathへ新しい処理は入らない。
- `swift build -Xswiftc -warnings-as-errors`、`swift build -c release -Xswiftc -warnings-as-errors`、Voice静的42件、`--verify-codex-app-server`、`git diff --check`はPASSした。local build 600はApple Development署名のstrict codesign、起動、graceful quitをreadbackした。隔離物理Voice E2E PID 70741は約1時間稼働後も生存し、停止・再起動していない。
- 実ChatGPT browser loginはユーザーのアカウント操作を伴うため、この実装ターンでは開始していない。従ってmanaged loginの実アカウント完了、cancel、更新後のcredential再利用は未完了gateであり、公開可能とは扱わない。
- 実装commit `4ed69eff3023d44b2452ee5d9772eef16d26ed73`のDraft PR #39は15 SUCCESS / 8 expected SKIPPED / failure 0 / pending 0だった。PRはDraft / OPEN / MERGEABLE / CLEAN、未解決review thread 0、remote parity 0 / 0。merge、release、Draft解除は行っていない。

## build 599 最終成果物readback

- product source exact HEAD `9961543db7c6502381830954c738029bf8da4c8d`を`0.1.0 (599)`としてDeveloper ID署名・公証した。Apple notary submission `52ecaaec-4b2c-4d44-97f7-57cb20dce3a2`は`Accepted`、messageは`Processing complete`である。
- `dist/releases/HoverPocket-0.1.0-599.zip`のSHA-256は`747c4e43cfc65d9cbd0fde5d960834f87f4df7cb41cfab82eb224cd6a10f302d`、sizeは`10138820` bytes。appcastはversion `599`、short version `0.1.0`、versioned URL、同じlength、88文字のSparkle署名を持つ。
- ZIPを新しい一時directoryへ独立展開し、top-levelが`HoverPocket.app`だけであること、bundle ID `local.codex.hover-pocket`、version `0.1.0`、build `599`、Local Network purpose stringをreadbackした。展開後appの`codesign --verify --deep --strict`、`stapler validate`、`spctl`はPASSし、Gatekeeper sourceは`Notarized Developer ID`、Team IDは`N7VVPW44ZA`だった。一時directoryは検証後Trashへ移した。
- release entitlementはApple Events、audio-input、cameraの3件だけで、Bonjour browseやmulticast entitlementは追加していない。
- 配布bundle内のCapability、Broker、Pocket Surface / App、Voice Foundation / E2E isolation、Codex app-server foundation、ChatGPT accountを使う実モデルTimer toolはPASSした。OpenAI API keyは使用していない。
- 配布bundle内の`--verify-codex-app-server-realtime`はexit 1、stdout `FAIL codex app-server realtime: realtime_probe_connection_unavailable`、stderr空だった。raw WebKit / SDP / ICE値は出力していない。Local Network許可と物理音声を通すまではbuild 599をVoice対応RCとして受け入れない。
- 独立エージェントによるhybrid 3 / 8秒ICE待機、Local Network purpose、verifier専用window、E2E process保護の再レビューはP0 / P1 / P2すべて0件。通常時の追加は完了時に解除されるtimer最大2個で、CPU / RSS /起動時間に有意な劣化はないと判定した。
- 公証・独立展開・packaged verifier後も隔離E2E PID `70741`は生存し、CPU `0.2%`、RSS約`82.5 MiB`をreadbackした。停止・再起動はしていない。
- GitHub Release、macOS public feed、merge、Draft解除は実施していない。

## managed login 実process lifecycle検証

- `CodexVoiceAccountLoginController`へ本番既定を変えない依存注入seamを追加し、実controllerと実`CodexAppServerClient`子processを使うfake app-server検証を実装した。本番は引き続き`app-server --stdio`、実browser opener、実credential change通知を使う。
- stub browserだけで、signed-out read、login start、完了通知、owner-privateな専用credential、ChatGPT account readback、別processでのcredential再利用を確認した。さらにcancel、Provider deactivate、app shutdownの各経路でlogin ID付きcancelとprocess closeを確認した。合計4シナリオ・6 processで、残留processと一時rootは0件だった。
- fake helperのreceiptは`O_NOFOLLOW`で開き、未作成時は`O_CREAT | O_EXCL`と0600、`fstat`で通常ファイル、current-user、exact 0600、link count 1を要求する。同じfdへpartial write / `EINTR`対応で追記し、明示検証時だけ`fsync`する。symlinkとhardlinkの負例はexit 2で拒否し、外部targetが未変更であることを別readbackした。
- 独立エージェントの初回レビューはreceipt symlink追記をP2 1件として検出した。上記fd境界へ修正後の最終結果はP0 / P1 / P2すべて0件。重い同期処理はhidden helperだけで、通常起動、Settings、Hover、Voice hot pathへの性能影響なしと判定された。
- Debug / Release warnings-as-errors、Voice静的42件、`--verify-codex-app-server`、auth control-plane、Realtime renderer、Voice Foundation、Panel 128、Capability 20、Broker 21 descriptor / 20 handler、Pocket Surface / App、Timer、`git diff --check`がPASSした。Release lifecycle verifierは1.60秒だった。
- local build 602はApple Development署名の`codesign --deep --strict`、起動、通常processのgraceful終了を確認した。隔離物理Voice E2E PID 70741は2時間超の稼働後も生存し、停止・再起動していない。
- 実装commitは`3ccf423e9b131f402cf9ba146778479b0a199f0d`。実ChatGPT browser login、物理マイク、remote audio、transcript、Calendar createは引き続き人手gateであり、この検証で完了扱いにしない。merge、release、Draft解除は実施していない。

## build 605 Release配布修正と最終成果物readback

- 配布scriptがSwiftPMのDebug binaryを梱包していることを、build 604の実行ファイルsizeとMach-O UUIDで検出した。build 604はApple公証と配布bundle内Codex app-server Realtimeを通過していたが、Release最適化されていないためRC候補から除外した。
- `build_and_run.sh`へ`debug / release`の明示configurationを追加した。通常開発はDebug既定、隔離E2EはDebug限定、`package_zip.sh`はRelease固定とし、`.build/$configuration`のmain、Sparkle、MediaRemoteAdapter、`run.pl`だけを直接参照する。Release依存欠落とmainの2つの`@rpath` closure不一致はZIP作成前にfatalとした。
- Debug / Release warnings-as-errors、shell構文、Voice静的42件、通常DebugのUUID一致、E2EでRelease拒否、Release mainのUUID一致、Capability 20、Broker 21 descriptor / 20 handler、Pocket App、Pocket Surface、Timer、Voice Foundation、managed login 4シナリオ / 6 process、Codex app-server RealtimeをPASSした。
- 別エージェントは初回にstaleな別target tripleを`find | head -1`で拾えるP2を1件検出した。active configuration直参照とRelease依存fatalへ修正後、最終P0 / P1 / P2は0件。追加処理はbuild / package時だけで通常runtime、Hover、Voice hot pathへの影響はなく、Release binaryはDebug比で約38%小さく性能改善側と判断された。
- exact code commit `02128284fb5d075b9773f297064440021c42c79e`を`0.1.0 (605)`としてDeveloper ID署名・公証した。Apple submission `73ee5ac8-1e9e-4643-aca4-cf451b4cdf01`は`Accepted`、staple、Gatekeeper、strict codesign、ZIP独立再展開をPASSした。
- `dist/releases/HoverPocket-0.1.0-605.zip`はSHA-256 `734f1d8ae8af77f253e655be12eaec61a679bd2b7dd425f671176a920085ad26`、size `7495993` bytes。appcastはversion `605`、short version `0.1.0`、同じlengthを持つ。ZIP top-levelは`HoverPocket.app`だけで、bundle ID `local.codex.hover-pocket`、Release sourceと配布mainのUUIDは`F3CFE9E0-17BC-3C73-BC66-114473CE2829`で一致した。
- 配布binary自身でCapability、Broker、Pocket App、Voice Foundation、managed login、Codex app-server Realtimeを再実行した。Realtimeは`account=chatgpt`、voices 19、ephemeral thread、SDP / WebRTC connected、process closedでPASSした。OpenAI API key、実ブラウザ、物理マイク、remote audio、transcript、Calendar createは使用していない。
- 公証と全readback後も隔離物理E2E PID 70741は約2時間31分稼働しており、CPU約0.1%、RSSはprocess readback約0.3%、Harnessのidle計測は平均0.114%、p95 / 最大0.2%、RSS平均 / 最大63.031 MiBだった。停止・再起動していない。
- build 605は未公開のmacOS配布RC候補として受け入れる。GitHub Release、public appcast、merge、Draft解除は実施していない。物理マイク、remote audio、transcript、音声経由Timer、Calendar create、実ChatGPT browser loginは人手gateとして残す。
- Draft PR #39へpush後、Router `33301419569`、Windows verify `33301420795`、macOS Capability `33301420798`、3OS contract / compare `33301420797`、transition `33301420806`、release metadata `33301420841`が成功した。合計11 SUCCESS / 8 expected SKIPPED / failure 0 / pending 0、Draft / OPEN / MERGEABLE / CLEAN、未解決review thread 0、remote parity 0 / 0をreadbackした。

## current HEAD build 607 物理E2E準備

- 継続中のbuild 597 PID `70741`を停止・再起動せず、現在HEAD `c081cf24897902890d80e2eb915c2c7d8f14e253`から別のad-hoc署名E2E bundleを作成した。fresh sessionは`HoverPocketVoiceE2ESession-jM7jH4`、runtimeは`HoverPocketVoiceE2E-pvPrV7`、PIDは`85676`で、旧・新の2 processが同時に生存している。
- build 607は`local.codex.hover-pocket.voice-e2e`、strict codesign、bundle mainと`.build/debug/HoverPocket`のMach-O UUID `02E274A9-60E7-3F24-89A1-DAF591FCC9B0`一致をreadbackした。canonical E2E引数なしの起動とVerifier併用起動は意図どおり拒否され、拒否試行の一時rootはTrashへ移した。
- receipt / performance / process / storage ownershipを検証し、`featureEnabled=false`、`disconnected`、microphoneなし、remote audioなし、Timer readbackなし、物理確認なし、credential currentなしを確認した。Isolation検証はPASSし、idle CPUは平均`0.114%`、p95 / 最大`0.2%`、RSSは平均約`109.650 MiB`、最大約`109.719 MiB`だった。
- 独立エージェントによる現行差分とbuild 605 Release成果物の安全性・性能レビューはP0 / P1 / P2すべて0件だった。安全検査はbuild / package / 明示Verifierへ限定され、通常起動、Hover、Voice hot pathへの有意な性能低下は確認されていない。
- desktop automationの登録済みアプリ一覧ではad-hoc E2E appを取得できず、同一表示名 / bundle IDの旧PID `70741`と新PID `85676`を安全に区別できなかった。このため自動クリックは行っていない。build 607のVoice明示ON、macOSマイク許可、物理発話、可聴remote audio、transcript、Timer承認 / readbackはユーザー操作gateのままである。

## 一意表示名のbuild 608物理E2E候補

- Computer Useはフルパス指定のAccessibility tree / screenshot取得ではbuild 607を一意に確認できたが、ad-hoc appへのclick時にnative pipeが閉じ、表示名指定は`/Applications/HoverPocket.app`へ解決された。誤操作を避け、Voice有効化やマイク許可は実行していない。
- 同じHEADとE2E binary、固定bundle ID `local.codex.hover-pocket.voice-e2e`、一意Keychain suffixを維持したまま、一時bundleの`CFBundleDisplayName` / `CFBundleName`だけを`ホバーポケット Voice E2E 608`へ変更し、既存entitlements付きad-hoc署名を再適用した。製品コード、通常bundle、ユーザーデータは変更していない。
- fresh session `HoverPocketVoiceE2ESession-Ia7yuR`、runtime `HoverPocketVoiceE2E-9OKeZP`、PID `86913`で起動した。strict codesign、Harness Readback / ValidateIsolation、process / storage ownershipがPASSし、Voice既定OFF、disconnected、mic / remote audio / Timer readback / 物理確認未実行を確認した。idle計測は7 sample、CPU平均 / p95 / 最大`0.1%`、RSS平均約`113.904 MiB`、最大約`113.984 MiB`だった。
- 同名だった中間build 607 PID `85676`はHarness Stopを使い、`safe_close`、process stopped、receipt / performance保持を別readbackした。長時間基準のPID `70741`は停止せず、一意表示名build 608 PID `86913`と同時に維持している。
- 次の人手gateは、前面の`ホバーポケット Voice E2E 608`を確認し、SettingsでVoiceを明示ON、macOSマイク許可、物理発話、可聴remote audio、transcript、Timer承認 / readbackを実行することである。人の発話と「話せた・聞こえた」確認は自動化・偽装しない。

## AN8残存gate独立監査

- 別エージェントはCodex app-server標準Voiceの安全性と性能を独立再レビューし、P0 / P1は0件と判定した。route canaryはVoice設定時の初回だけで同一process内ではcacheされ、通常起動、Hover、マイク開始hot pathへ毎回入らない。P2はkeyring-only環境で外部`auth.json`を継承できない互換性1件で、現在環境はowner-only file-backed credentialをreadbackできるため現行動作を止めない。
- ChatGPT Pro OrchestratorのCriticへ、exact HEAD `e02761e3c584810b5e66ed90fdcc74804d20b3a5`、要求・進捗・macOS / Windows Voice / 署名 / rollback関連allowlistを渡し、AN8初回実用リリースまでの完了済み・証拠不足・未完了gateを監査させた。runは`20260830-175124-hoverpocketdraft-pr-head-e02761ean8voice`、sessionは`pro-run-a9b6cde0-a`。
- 送信前にNode `v24.19.0`、Oracle `0.17.2`、request SHA-256 `904350bd45a6fdc0afd792ec66b8119d4720e724020f92cd0e9757cb16aa9be3`、source context SHA-256 `4d33e71405ce38d73438ed1af5ba26d0ec940f8d15ec96b4d2ed2c6b20b7cce8`、Project target、exact send commandをruntime preflightでreadbackした。初回のCodex同梱Nodeはnpm非同梱のため送信前に停止し、npm併設のHomebrew Node 24へ切り替えた。実送信は1回だけで、return bridgeによる自動回収待ちである。
- Criticはreview-onlyで、コード変更、GitHub書込み、merge、release、公開、外部申請を許可していない。物理マイク、可聴remote audio、transcript、Calendar create、Windows正式署名、公開transitionも自動完了扱いにしない。
