# HoverPocket AI-native AN3-B3A Realtime BYOK provider

## 目的

Codex app-serverに正のtool allowlistがない現状でも、一般配布で安全にVoice Laneを使えるOpenAI Realtime BYOK providerを追加する。Windowsの既存WebView WebRTC経路をHost-owned Realtime sessionへ接続し、モデルへ見せるtoolをCapability Registry由来のHoverPocket Capabilityだけへ限定する。

## 現行監査

- exact base: `b95ef1681510781a38ccbb0b95cbf51384faa594`
- worktree: `/Users/shotaro/code/share/hover-menu-preview-ai-native-an3b3-realtime-provider`
- branch: `codex/ai-native-an3b3-realtime-provider`
- installed Codex: `codex-cli 0.145.0`
- `thread/start`には`dynamicTools`があるが、ambient built-in toolを0へ固定するpositive policyは生成schemaで確認できない。
- 既存Codex providerは互換probeを弱めず、production開始前にfail closedとする。

## AN3-B3A scope

- provider選択は明示式・既定OFF。
- API keyはmacOS Keychain / Windows Credential Managerだけに保存し、WebView、JSON、ログ、監査、fixtureへ返さない。
- Windows Hostが`/v1/realtime/calls`へSDPとsession設定を送り、Registry由来のCalendar read/create、Timer startだけをfunction toolとして公開する。
- function callはCapability Brokerへだけ流し、write承認と実行後ID/state readbackを維持する。
- macOSは共通provider設定、Keychain、adapter seam、transport未実装時の明示fail-closedまでを実装する。実音声transportはAN3-B3Bで行う。

## ChatGPT Pro委譲

- 最初のrun `20260824-050727-...`はsource context 1.8MBがOracleの1MB/file制限により外部送信前に停止した。
- 停止後にsource contextを再生成したため、bridge通知のstate hashと現在stateが一致せず、`claim-synthesis`はfail-closedした。このdeliveryから成果物を適用せず、`mark-done`せず、同runを再利用していない。
- 新run: `20260824-051101-hoverpocket-an3-b3a-realtime-byok-windows-vertical-slice-patch`
- source context: 45 files / 974,060 characters / SHA-256 `f1a51b249249020e473d5e71b955341afb8b9e3374d8803144ad22101bba9063`
- transport: GPT-5.6 Sol / Node 24.19.0 / ChatGPT Pro Orchestrator Project / required-return bridge
- dry-runでbase、source hash、Project、Node、bridgeを確認し、送信後status `running`をreadbackした。

## 公式Realtime契約

- Windows WebViewは既存WebRTC peer、microphone、remote audio、`oai-events` data channelだけを所有する。標準OpenAI API keyを受け取らない。
- Windows HostがWebViewのSDP offerとHost所有session設定をmultipartの`sdp` / `session`として`POST /v1/realtime/calls`へ送り、返却SDP answerだけをWebViewへ渡す。
- Realtimeへ公開するfunction schemaは`type / name / description / parameters`で構成する。Codex app-server向けの`inputSchema`をそのまま送らず、Registry descriptorからRealtime用の有限schemaへ変換する。
- sessionのtoolはHostが許可したfunctionだけに固定する。Realtime側で実行されるMCP / Connectorをsessionへ追加せず、shell、filesystem、任意native codeも公開しない。
- function callは`call_id`、tool name、JSON arguments、provider generation、conversation rootをHostで束縛する。引数と出力に上限を設け、未知tool、重複call、stale generation、別rootからの応答をfail closedにする。
- Broker receiptは同じ`call_id`の`conversation.item.create`へ`function_call_output`として返し、その後に`response.create`を送る。失敗時も内部エラーやcredentialを露出しない有限なHost-owned出力へ正規化する。
- `OpenAI-Safety-Identifier`を採用する場合は、Hostだけが生成するプライバシー保護済みの安定識別子とし、メールアドレス等の直接識別子やWebView由来の任意値を送らない。
- model IDはUI入力をそのまま受理せず、アプリ所有のallowlistから選択する。deprecated aliasは採用しない。初期候補は費用とtool reasoningを優先して`gpt-realtime-2.1-mini`とし、AN3-B3Bの実機比較で音声品質重視の`gpt-realtime-1.5`も評価する。

## 受入前baseline

| 検証 | 結果 |
|---|---|
| `swift build -Xswiftc -warnings-as-errors` | 成功。初回依存buildを含め580.25秒 |
| `python3 script/verify_voice_foundation.py` | Voice geometry / state / root scope / default-off / legacy negative / Windows origin / AN3-B2 Broker slice、42件成功 |
| `python3 script/verify_pocket_contracts.py` | 15 schema / 71 fixture、全一致 |
| `node --check windows/ui/js/app.js` | 成功 |
| `node --check windows/ui/settings/settings.js` | 成功 |
| `git diff --check b95ef168...HEAD` | 成功。差分は進捗記録だけ |

## patch受入マトリクス

| 境界 | exact baseの状態 | AN3-B3Aで必要な証拠 |
|---|---|---|
| provider | production compositionはCodex app-serverだけ。正のtool policy不在時はfail closed | Realtime BYOKを明示選択でき、既定OFF。provider切替は旧transport停止完了後だけ新transportを開始する |
| tool surface | `CodexVoiceCapabilityRuntime`はCalendar listとTimer startだけを明示公開 | Realtime sessionのfunction定義がRegistry内の許可済みCalendar list/create・Timer startと一致し、未知tool、MCP、shell、filesystemを拒否する |
| Calendar create | Registry / Broker handlerは存在するがVoice runtimeには未接続 | Host-owned承認、plan digest binding、`calendar.events.write`、実行後`eventRef / eventId` readbackまでを一つのreceiptで確認する |
| Timer start | VoiceからBroker、native承認、timer ID/state readbackまで実装済み | Realtime providerでも同じruntimeを再利用し、承認・取消・idempotencyを迂回しない |
| WebRTC data channel | WebViewが`oai-events`を作成するが、Realtime function eventの処理は未実装 | call ID / name / arguments / generationを検証してHostへ中継し、Broker結果だけを`function_call_output`として同じcallへ返す |
| Realtime session creation | Host-owned `/v1/realtime/calls`交換は未実装 | WebViewのSDP offerとHost-owned sessionをmultipart `sdp / session`で送信し、標準API keyと任意のsafety identifierをHostから外へ出さず、SDP answerだけをWebViewへ返す |
| Realtime schema変換 | Codex dynamic toolは`inputSchema`を使う | Registryの有限descriptorからRealtime functionの`parameters`へ明示変換し、unknown keyword、過大schema、任意tool injectionを拒否する |
| function result | Realtime call outputのHost relayは未実装 | 同じ`call_id`へ`conversation.item.create(function_call_output)`を返した後だけ`response.create`し、重複、別root、stale generation、過大outputを拒否する |
| model policy | Realtime model設定は未実装 | app-owned allowlistだけを使用し、任意UI値とdeprecated aliasを拒否する。初期候補をoffline verifierへ固定する |
| credential | Realtime API key用storeは未実装 | keyはKeychain / Credential Managerだけに保存し、WebView、state、log、error、fixtureへ値を返さない。UI readbackは有無だけ |
| lifecycle | Voice OFF、hide、stop、crash、restartのCodex transport teardown verifierは成功 | Realtime peer / data channel / local track / remote audio / pending callを同じgenerationで閉じ、stale eventを受理しない |
| macOS | provider-neutral adapterとfake verifierだけでproduction audioなし | provider ID、Keychain、adapter seam、未実装時fail-closedを追加し、実音声transportはAN3-B3Bと明示する |

## 次の受入gate

1. bridge通知をdelivery ID / state hashでclaimする。
2. receipt、exact base、patch hash、allowed pathを検証する。
3. patch適用後、Swift warnings-as-errors、Voice contract、Broker/Capability、JavaScript構文をローカル検証する。
4. Draft PRでWindows Release buildとoffline Realtime verifierを通す。
5. API key秘匿、正のtool surface、OFF/no-key fail-closed、承認/readbackを独立reviewする。

AN3-B3Aの合格後も、macOS実音声transport、両OS実端末の音声一往復、正式Windows署名release/rollback、人手stack mergeは未完了gateとして残る。

## GitHub stack readback

- 2026-08-24の再確認で、Draft PR #31はhead `b95ef1681510781a38ccbb0b95cbf51384faa594`、base `codex/ai-native-core-ga-legacy-path-removal`、`MERGEABLE / CLEAN`を維持していた。
- PR #31のWindows、macOS、Ubuntu / macOS / Windows contract、cross-OS比較、PR Routerの7チェックはすべて成功していた。stack PR #25〜#31の未解決review threadは0件だった。
- PR #29の公開release readbackでは、deterministic metadataとWindows Authenticode verifier syntaxは成功しているが、実際の公開release取得、timestamped Authenticode、Windows package identity、macOS署名・notarization・Gatekeeperは`SKIPPED`である。
- PR #25のinstall/update/rollback transitionも、macOS package transitionとWindows install/update/rollback/reinstallが`SKIPPED`である。したがってstackの緑色はAN8の正式配布・rollback完了を証明しない。
- AN3-B3Aのローカルbranchにはremote/upstreamがなく、Pro patch適用・ローカル受入後までDraft PRを作成しない。
