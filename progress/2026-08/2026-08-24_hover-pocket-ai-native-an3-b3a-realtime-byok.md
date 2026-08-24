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

## 実装と受入結果

- 正本run: `20260824-144554-hoverpocket-an3-b3a-realtime-byok-windows-vertical-slice-patch`
- Pro route: GPT-5.6 Sol / Pro / builder。開始 `2026-08-24T14:48:39+09:00`、terminal化 `2026-08-24T19:45:02+09:00`。
- artifact: `changes.patch`、187,716 bytes、SHA-256 `0b089aee0c4ebaab7e37274befe9fb99f3e2047137f9271cb7368313076ec952`。responseとの対応、standalone性、envelope除外を検証した。
- 適用先: recovery worktree `/Users/shotaro/code/share/hover-menu-preview-ai-native-an3b3-realtime-byok-recovered`。original dirty worktreeには触れていない。
- 実装commit: `c702627`。Windows build修正 `6e5226f`、設定契約更新 `44c6f67`、境界fixture修正 `16cc7a0`を積み、remote branch `codex/ai-native-an3b3-realtime-provider`へ反映した。
- 5件のlow security findingは局所修正した。Keychain削除readback、Windows Voice transition rollback、bounded SDP response、key削除のnative承認/readback、設定保存失敗時のfail-closed rollbackである。生成renderer侵害時のrevocation / media isolationはAN3-B3Bの設計課題として残す。

## ローカル検証

| 検証 | 結果 |
|---|---|
| `swift build -Xswiftc -warnings-as-errors` | 成功 |
| `swift run HoverPocket --verify-voice-foundation` | 成功 |
| `python3 script/verify_voice_foundation.py` | 42件成功 |
| `python3 script/verify_pocket_contracts.py` | 15 schema / 71 fixture成功 |
| `.build/debug/HoverPocket --verify-capabilities` | 20 handler成功 |
| `.build/debug/HoverPocket --verify-broker` | 21 descriptor / 20 handler、negative 12件成功 |
| Pocket Surface / Panel layout / Timer | Surface negative 15件、layout 128件、Timer全件成功 |
| Windows settings target / UI JavaScript / `git diff --check` | 成功 |

## GitHub readback

- Draft PR [#36](https://github.com/shotaro311/hover-pocket/pull/36): code head `16cc7a00071921b45a020a9fe9a6dc2004fc55b3`、base `codex/ai-native-an8-backup-restore-core`。最新headは受入記録だけを追加したdocs-only commitである。
- Windows [32717846919](https://github.com/shotaro311/hover-pocket/actions/runs/32717846919)でRelease build、Settings surface isolation、Voice foundation、Realtime BYOK offline verifierが成功した。
- macOS [32717846913](https://github.com/shotaro311/hover-pocket/actions/runs/32717846913)、3 OS contract / byte比較 [32717847153](https://github.com/shotaro311/hover-pocket/actions/runs/32717847153)、Router [32717844455](https://github.com/shotaro311/hover-pocket/actions/runs/32717844455)も成功し、7/7 greenである。
- code headと進捗同期後のdocs-only headで7/7 check成功を確認した。`MERGEABLE / CLEAN`、review / comment / unresolved thread 0件、remote parity `0 / 0`も別経路で確認した。

## Pro terminal receipt

- local verification `PASS`、受入条件7/7 `PASS`、release gate `ready_for_publish=true`をreadbackした。
- runを`done`へfinalizeし、delivery `return-db1915c1a504b221cd25feef9992e237`を`mark-done`した。
- terminal receiptはgeneration 1 / status `complete`、state SHA-256 `1f0721da...5770`、return bridge SHA-256 `d08b169c...0b23`、receipt SHA-256 `6404ac9f...f9c`である。

## AN3-B3Bへ残すgate

1. macOS production audio transportを実装し、既存のfail-closed adapter seamから置換する。
2. Windows実機でmicrophone permission、WebRTC接続、remote audio、Calendar read/create、Timer start、承認拒否、stop/restartを一往復検証する。
3. custom / generated rendererからmedia ownershipを分離し、native-owned audio transport、revocation、disposable isolated WebViewを確認する。
4. その後も正式Windows署名release / rollbackとstack PRの人手mergeはAN8の別gateとして維持する。

## GitHub stack readback

- 2026-08-24の再確認で、Draft PR #31はhead `b95ef1681510781a38ccbb0b95cbf51384faa594`、base `codex/ai-native-core-ga-legacy-path-removal`、`MERGEABLE / CLEAN`を維持していた。
- PR #31のWindows、macOS、Ubuntu / macOS / Windows contract、cross-OS比較、PR Routerの7チェックはすべて成功していた。stack PR #25〜#31の未解決review threadは0件だった。
- PR #29の公開release readbackでは、deterministic metadataとWindows Authenticode verifier syntaxは成功しているが、実際の公開release取得、timestamped Authenticode、Windows package identity、macOS署名・notarization・Gatekeeperは`SKIPPED`である。
- PR #25のinstall/update/rollback transitionも、macOS package transitionとWindows install/update/rollback/reinstallが`SKIPPED`である。したがってstackの緑色はAN8の正式配布・rollback完了を証明しない。
- AN3-B3AはDraft PR #36へ反映済みである。stackの正式merge、署名release、実機音声は上記の未完了gateを満たすまで行わない。
