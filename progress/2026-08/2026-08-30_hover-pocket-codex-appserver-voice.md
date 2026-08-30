# 2026-08-30 HoverPocket macOS Codex app-server Voice

## 結論

macOS Voice Laneの標準providerをCodex app-serverへ接続した。これはOpenAI APIキーを使うRealtime BYOK経路ではなく、ローカルCodexのログイン状態とapp-serverを使う経路である。Capabilityの正本は引き続きHoverPocketのRegistry / Brokerで、CodexはCalendar read/createとTimer startだけを同じBroker経由で実行する。

実装基盤と決定論的検証に加え、ChatGPT.app同梱Codex app-server `0.150.0-alpha.12.2`でChatGPT account、19 voices、ephemeral root thread、SDP answer、WebRTC接続、process teardownまで実接続した。OpenAI APIキーと物理マイクは使用していない。Homebrew Codex `0.145.0`はtool route不一致、隔離した公式`0.149.0`は現行backendとのRealtime session契約差で停止するため、通常解決順は互換性を実証したChatGPT同梱Codexを優先する。さらに製品と同じDeveloper ID要件の隔離candidateから、既存Google credentialと実Calendarを使ったVoice origin Calendar readをBroker / readback込みで成功確認した。

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

## 独立レビュー

別エージェントへ、安全対策が正常動作や性能を損なっていないかをread-onlyレビューさせた。初回P1はinstalled readiness表示、binary pin、subprocess timeout、WebRTC timeout / cancel、切断状態、stop重複、stdout順序の7件で、すべて局所修正した。さらにambient要求の入力順隔離、pending / current / 旧clientのidentity + generation分離、隔離後の再起動禁止まで再レビューし、最終結果はP0 / P1とも0件だった。

Broker限定policy、read-only sandbox、approval never、空workspace roots、root / generation / call / tool照合、非永続WebView、CSP、trusted custom scheme、5秒microphone armingは、過剰安全ではなくCapability境界に必要なため維持した。ambient分類とquarantineだけをstdout consumerで短く順序処理し、通常tool本体はその後にTask化するため、危険な要求の追い越しと長時間toolによるstdout停止を同時に避ける。

専用app-server profileとroute canaryの追加差分も別エージェントが再レビューした。API key accountをChatGPT loginとして誤受入れするP1と、一過性timeout / loopback / transport失敗をアプリ終了までcacheするP2を検出し、ChatGPT account限定と決定論的結果だけのcacheへ修正した。最終P0 / P1は0件。route canaryは公式0.149で0.27〜0.65秒、Voice設定時の初回1回だけでmic開始hot pathには入らず、app-server常駐も会話状態保持と次回高速起動のため妥当と評価された。

ChatGPT.app同梱Codexのlive接続差分を同じ別エージェントが再度read-onlyレビューした。candidate fallback、起動直後PID記録、SIGKILL後の終了待ち、fallback対応cache検証、OneShot競合、WebRTC cleanup、v3 voice選択を確認し、未使用のlegacy default voiceキーを必須にする過剰validationだけを削除した。最終結果は今回差分でP0 / P1 / P2すべて0件。live verifierのWebView、無音oscillator、最大0.5秒のcleanup待ちは明示検証コマンド内だけで、通常のhover / Voice開始hot pathには入らない。

物理E2EのCodex統一差分も別エージェントが独立レビューした。通常版ではreceipt storeが`nil`で、追加したfile writeと確認sheetは実行されない。E2E内もmedia event単位であり毎フレーム処理ではなく、operation IDとattempt IDでstale event / 旧sheet応答を拒否する。warnings-as-errors build、Voice Foundation、E2E isolation、receipt self-testを再実行し、P0 / P1 / P2すべて0件だった。

Calendar読み取り専用gateも同じエージェントが独立レビューした。初回は、Calendar検証が全Providerを組み立ててTimer singletonへ触れる点、Keychain preflight後にCalendar storeが資格情報を再読する点、token refresh失敗時に保存credentialを削除し得る点をP1として検出した。CalendarList handlerだけのRegistry、5秒上限で一度だけ読み込むpreloaded credential、credential mutationを無効にしたOAuth serviceへ修正し、最終P0 / P1 / P2は0件となった。通常経路は既定値が従来どおりで、新しい分岐は明示CLI flag時だけ実行する。

実Calendar初回実行で、private read共通3秒timeoutがURLSessionを取消し、Calendar取得を`URLError -999`で失敗させる過剰制限を検出した。Calendar get / listだけ15秒・30 calls/minへ分離し、Timerなどローカルreadは3秒を維持した。別エージェントは15秒上限、非同期待機、固定診断、個人情報非出力、他Capability非波及を再レビューした。Broker timeoutと取消由来`-999`の診断優先順位も修正し、最終P0 / P1 / P2すべて0件となった。

残るP2既知制約はkeyring-only Codex loginである。初回実装はowner-onlyのfile-backed `auth.json`を専用profileへsymlinkするため、元`CODEX_HOME`にfileがない環境ではroute canary通過後もproduction `account/read`がsigned-outになる。現在の環境は`~/.codex/auth.json` 0600、symlink先一致、`account.type=chatgpt`をreadback済みで、当面の動作阻害ではない。一般公開対応には専用profileの`account/login/start`または同等のChatGPT login flowが必要である。

## 検証とreadback

- `swift build -Xswiftc -warnings-as-errors`: PASS
- `swift run --skip-build HoverPocket --verify-voice-foundation`: PASS
- `swift run --skip-build HoverPocket --verify-codex-app-server`: foundationとinstalled readinessがともにPASS
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
- Calendar gate commit `a836856b570e7f949ab9081080c462d1ca6ce326`のDraft PR #39は、Router [33291040507](https://github.com/shotaro311/hover-pocket/actions/runs/33291040507)、macOS [33291041914](https://github.com/shotaro311/hover-pocket/actions/runs/33291041914)、Windows [33291041972](https://github.com/shotaro311/hover-pocket/actions/runs/33291041972)、3OS contract / compare [33291041947](https://github.com/shotaro311/hover-pocket/actions/runs/33291041947)、transition [33291041883](https://github.com/shotaro311/hover-pocket/actions/runs/33291041883)、release readback [33291041901](https://github.com/shotaro311/hover-pocket/actions/runs/33291041901)が成功。11成功・8 gate skip・失敗0・pending 0、Draft / OPEN / MERGEABLE / CLEAN、remote parity 0 / 0をreadback
- 実装commit `dc734a95f30e847cb70c705df8d67728178a578f`のDraft PR #39: Router [33289398813](https://github.com/shotaro311/hover-pocket/actions/runs/33289398813)、macOS [33289399447](https://github.com/shotaro311/hover-pocket/actions/runs/33289399447)、Windows [33289399448](https://github.com/shotaro311/hover-pocket/actions/runs/33289399448)、3OS contract / compare [33289399439](https://github.com/shotaro311/hover-pocket/actions/runs/33289399439)、transition [33289399443](https://github.com/shotaro311/hover-pocket/actions/runs/33289399443)、release readback [33289399458](https://github.com/shotaro311/hover-pocket/actions/runs/33289399458)が成功。公開成果物を必要とする8 gateは意図どおりskip、失敗0・pending 0。PRはDraft / OPEN / MERGEABLE。

## 未完了gate

- 全candidateが非Ready、ChatGPT.app未導入、同梱Codexが将来非互換、keyring-only loginの場合の導入 / 更新 / login UX。
- transcriptの実受信とroot-scoped session cardのlive readback。
- 起動中の隔離E2EアプリでVoiceを明示ONにし、物理マイク取得、remote audio再生、transcript、Timer start、承認、実行後readbackを人手確認する。人の発話と「話せた・聞こえた」確認は自動化・偽装しない。
- Calendar readはproduction accountと同じ署名・Keychain条件の隔離candidateで完了した。Calendar createは外部書き込みのため、予定内容を明示した承認と実行後readbackを別gateとして残す。
- 上記の実音声往復とCalendar / Timerを10回反復する。
- CPU / RSS、mic clickからattachedまでのp95、snapshot publishes/sec、Expanded RPC/sec、stop RPC/session=1の計測。
- keyring-only Codex login向けの専用ChatGPT login flowと、file-backed loginからの移行readback。
- Draft PRのCIと人手レビュー。merge、release、既存notarized build 583の差し替えは未実施。
