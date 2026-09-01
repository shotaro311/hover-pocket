# HoverPocket AI-native AN3-B3B macOS Realtime Voice

## 目的

AN3-B3Aでfail-closedにしていたmacOS Voice adapterを、明示マイク操作、Host-owned credential、Capability Broker、実行後readbackを維持したproduction OpenAI Realtime transportへ置き換える。

## 実装範囲

- Voice Lane有効化とマイク開始を分離し、接続はパネルの明示操作後だけ開始する。
- API keyはmacOS Keychainからnative ephemeral `URLSession`へだけ渡す。WebView、transcript、監査ログ、fixtureには渡さない。
- 非永続・非inspectable WebViewにmicrophone、WebRTC peer、remote audio、`oai-events` data channelを閉じ込める。
- Hostが`POST /v1/realtime/calls`へmultipart `sdp` / `session`を送り、bounded SDP answerだけをWebViewへ戻す。
- Realtime tool surfaceはCalendar list/createとTimer startの3件だけに固定し、共有Capability Registry / Brokerへ接続する。
- Calendar createとTimer startはnative sheetで毎回承認し、Broker receiptのverified readbackだけをRealtimeへ返す。
- Voice laneのcompact / expanded UI、transcript、root-scoped session card、mute、end、再試行を実transportへ接続する。

## 安全境界

- provider / Voice / Calendar grantは既定OFF。Calendar grantはSettingsで説明付き確認後だけ有効化する。
- microphone permissionはtrusted main frame、exact origin、明示start generation、microphone-onlyへ限定する。
- navigationとnew windowを拒否し、非永続data store、CSP、非inspectable WebViewを使う。
- SDP、event、arguments、function output、remembered call、transcriptを有限上限へ固定する。
- tool name、call ID、root session、generationをHostで照合し、unknown / stale / oversized入力をfail closedにする。
- 承認は同時1件、拒否を含め60秒3件までとし、Voice終了時にnative sheetと実行Taskを取消する。
- Calendar grant取消とcredential変更はactive adapterを停止して再構築し、session tool surfaceも更新する。
- Calendar / Timerタイトルは改行、tab、余分な空白を除いてからplanと承認表示へ同じ値を渡す。
- function event / tool result / mute / teardown異常時はdisconnected表示だけで終えず、media closeとpage resetへ進む。

## セキュリティ検証

Codex Security差分scan:

- scan ID: `5670016c-fea6-463c-a42b-6e9aea700b55`
- content digest: `codex-security-snapshot/v1:sha256:132204cb32be3b101551e91650a465e0231242eadc4d826a36c447069fd9a81e`
- 結果: Low 5件、High / Critical 0件、coverage partial
- deferred: WebContent異常時に物理microphone trackが必ず停止することの動的証拠

修正と再照合:

| Finding | 結果 | 証拠 |
|---|---|---|
| microphone用途説明に外部送信先がない | fixed | `NSMicrophoneUsageDescription`へOpenAI Realtimeを明記し、静的契約で固定 |
| 承認回数制限・取消がない | fixed | `VoiceApprovalCoordinator`、同時1件、拒否込み3件/分、session取消の実行回帰 |
| 承認文面へ改行を注入できる | fixed | `VoiceApprovalText.singleLine`と改行/tab回帰 |
| function failureでmedia closeしない | fixed | `failTransport -> reportTransportFailure -> closeSession`とclose回数readback |
| Calendar grant取消がactive requestへ反映されない | fixed | Settings observer、adapter再構築、session取消、provider書込み前取消回帰 |

セキュリティscan測定値はtotal 14,002,204 tokens、input 13,938,202、cached input 13,477,632、output 64,002、reasoning output 21,146だった。TAC statusは`not_granted`で、scan実行を妨げないadvisoryとして扱った。

## ローカル検証

| 検証 | 結果 |
|---|---|
| `swift build -Xswiftc -warnings-as-errors` | 成功 |
| `.build/debug/HoverPocket --verify-voice-foundation` | 成功 |
| `python3 script/verify_voice_foundation.py` | AN3-B3B security gateを含め成功 |
| `.build/debug/HoverPocket --verify-capabilities` | 20 handler成功 |
| `.build/debug/HoverPocket --verify-broker` | 21 descriptor / 20 handler、negative 12件成功 |
| Pocket App / Pocket Surface | package、lifecycle、generation、migration、health、backup、negative成功 |
| Panel layout / Timer | layout 128件、Timer全件成功 |
| `python3 script/verify_pocket_contracts.py` | 15 schema / 71 fixture成功 |
| `git diff --check` | 成功 |
| `swift test -Xswiftc -warnings-as-errors` | Tests targetがないため`no tests found`。製品内verifierを実行済み |

## ChatGPT Pro回収境界

- run: `20260824-200003-hoverpocket-an3-b3bexact-base-16090d7macosproduction-openai-realtime-byok-webrtchostremote-audiodata-channelcapability-brokercalendar-timerchanges-patch`
- recoveryは同一sessionだけで行い、同じpromptを再送していない。
- recovery budgetがterminal-blockedへ到達し、適用可能artifactは得られなかった。Codexがexact baseの隔離worktreeで実装、検証、security remediationを完遂した。

## GitHub readback

- branch: `codex/ai-native-an3b3b-macos-realtime`
- implementation commit: `a0140fa065ca12be33587ec645f1ac3578ad9b59`
- Draft PR: [#38](https://github.com/shotaro311/hover-pocket/pull/38)
- base: `codex/ai-native-an3b3-realtime-provider`
- Windows: [32919662223](https://github.com/shotaro311/hover-pocket/actions/runs/32919662223) SUCCESS
- macOS: [32919662200](https://github.com/shotaro311/hover-pocket/actions/runs/32919662200) SUCCESS
- Router: [32919662240](https://github.com/shotaro311/hover-pocket/actions/runs/32919662240) SUCCESS
- PR: `Draft / OPEN / MERGEABLE / CLEAN`
- review / comment: 0 / 0
- remote parity: `0 / 0`

## 未完了gate

1. 実API keyと実マイクで、日本語発話、input transcript、remote audioを一往復する。
2. Calendar read、Calendar create承認 / 拒否 / readback、Timer start承認 / 拒否 / readbackを実データで確認する。
3. mute / end / panel hide / provider switch / Calendar grant取消 / API key削除で物理microphone trackが止まることを確認する。
4. WebContent process異常を注入し、JavaScript teardown失敗時のpage reset後も物理capture indicatorが消えることを確認する。
5. stacked Draft PRを人手レビューし、順序どおりにmergeする。自動mergeとReady化は行わない。
