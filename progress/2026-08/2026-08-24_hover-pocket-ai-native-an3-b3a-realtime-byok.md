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

## 次の受入gate

1. bridge通知をdelivery ID / state hashでclaimする。
2. receipt、exact base、patch hash、allowed pathを検証する。
3. patch適用後、Swift warnings-as-errors、Voice contract、Broker/Capability、JavaScript構文をローカル検証する。
4. Draft PRでWindows Release buildとoffline Realtime verifierを通す。
5. API key秘匿、正のtool surface、OFF/no-key fail-closed、承認/readbackを独立reviewする。

AN3-B3Aの合格後も、macOS実音声transport、両OS実端末の音声一往復、正式Windows署名release/rollback、人手stack mergeは未完了gateとして残る。
