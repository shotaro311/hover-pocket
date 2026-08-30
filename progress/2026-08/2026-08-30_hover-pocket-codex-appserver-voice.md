# 2026-08-30 HoverPocket macOS Codex app-server Voice

## 結論

macOS Voice Laneの標準providerをCodex app-serverへ接続した。これはOpenAI APIキーを使うRealtime BYOK経路ではなく、ローカルCodexのログイン状態とapp-serverを使う経路である。Capabilityの正本は引き続きHoverPocketのRegistry / Brokerで、CodexはCalendar read/createとTimer startだけを同じBroker経由で実行する。

実装基盤と決定論的検証は通った。現在インストール済みのCodex `0.145.0`は、実際のResponses requestへHost指定tool以外の`update_plan`も含めるため、installed readinessは`codex_broker_only_tool_route_mismatch`でBLOCKEDとなる。隔離した公式Codex `0.149.0` exact binaryは同じ実route canaryを通過したが、system installは変更しておらず、実音声が動作済みとは扱わない。

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

## 独立レビュー

別エージェントへ、安全対策が正常動作や性能を損なっていないかをread-onlyレビューさせた。初回P1はinstalled readiness表示、binary pin、subprocess timeout、WebRTC timeout / cancel、切断状態、stop重複、stdout順序の7件で、すべて局所修正した。さらにambient要求の入力順隔離、pending / current / 旧clientのidentity + generation分離、隔離後の再起動禁止まで再レビューし、最終結果はP0 / P1とも0件だった。

Broker限定policy、read-only sandbox、approval never、空workspace roots、root / generation / call / tool照合、非永続WebView、CSP、trusted custom scheme、5秒microphone armingは、過剰安全ではなくCapability境界に必要なため維持した。ambient分類とquarantineだけをstdout consumerで短く順序処理し、通常tool本体はその後にTask化するため、危険な要求の追い越しと長時間toolによるstdout停止を同時に避ける。

専用app-server profileとroute canaryの追加差分も別エージェントが再レビューした。API key accountをChatGPT loginとして誤受入れするP1と、一過性timeout / loopback / transport失敗をアプリ終了までcacheするP2を検出し、ChatGPT account限定と決定論的結果だけのcacheへ修正した。最終P0 / P1は0件。route canaryは公式0.149で0.27〜0.65秒、Voice設定時の初回1回だけでmic開始hot pathには入らず、app-server常駐も会話状態保持と次回高速起動のため妥当と評価された。

残るP2既知制約はkeyring-only Codex loginである。初回実装はowner-onlyのfile-backed `auth.json`を専用profileへsymlinkするため、元`CODEX_HOME`にfileがない環境ではroute canary通過後もproduction `account/read`がsigned-outになる。現在の環境は`~/.codex/auth.json` 0600、symlink先一致、`account.type=chatgpt`をreadback済みで、当面の動作阻害ではない。一般公開対応には専用profileの`account/login/start`または同等のChatGPT login flowが必要である。

## 検証とreadback

- `swift build -Xswiftc -warnings-as-errors`: PASS
- `swift run --skip-build HoverPocket --verify-voice-foundation`: PASS
- `swift run --skip-build HoverPocket --verify-codex-app-server`: foundation PASS、installed readiness BLOCKEDを明示
- installed Codex `0.145.0`の`--require-codex-app-server-ready`: exit 2、`codex_broker_only_tool_route_mismatch`
- 隔離した公式Codex `0.149.0` exact binaryの`--require-codex-app-server-ready`: PASS。初回route canaryは約0.65秒、同一processの2回目はcacheを利用
- 公式Codex `0.149.0`のproduction profile readback: `account.type=chatgpt`、voice 19件。API keyは使用していない
- `swift run --skip-build HoverPocket --verify-capabilities`: PASS、20 handler
- `swift run --skip-build HoverPocket --verify-broker`: PASS、21 descriptor / 20 handler
- `python3 script/verify_voice_foundation.py`: PASS、42 cases。app-server request admissionの順序、client quarantine、lifecycle / generation分離、probe timeout / executable pinも静的回帰で確認
- `python3 script/verify_pocket_contracts.py`: PASS、15 schema / 71 fixture
- `git diff --check`: PASS
- 隔離E2E app bundle: build PASS、executable存在、`codesign --verify --deep --strict` PASS、microphone purpose stringにCodex app-serverを含むことをreadback。bundleは実行せずTrashへ移動した。

## 未完了gate

- route canaryを通る対応Codexの正式なsystem installまたは配布物への同梱方針。
- 対応versionでのthread / SDP / transcript実接続。account / voicesは公式Codex `0.149.0`のproduction profileでreadback済み。
- 物理マイク取得、remote audio再生、Calendar read/create、Timer start、承認、実行後readbackの10回反復。
- CPU / RSS、mic clickからattachedまでのp95、snapshot publishes/sec、Expanded RPC/sec、stop RPC/session=1の計測。
- keyring-only Codex login向けの専用ChatGPT login flowと、file-backed loginからの移行readback。
- Draft PRのCIと人手レビュー。merge、release、既存notarized build 583の差し替えは未実施。
