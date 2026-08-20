---
project_slug: hover-pocket
phase: AN3-B2
date: 2026-08-21
status: local-verified; windows-ci-and-security-rescan-pending
branch: codex/ai-native-an3b2-voice-capability-broker
pr: 22
---

# AN3-B2 Voice Capability Security Remediation

## 対象

- Draft PR #22のWindows Voice Calendar read / Timer start → Capability Registry / Broker縦断。
- 修正前head: `c9be7e43f0e7580dfb7c20d9ceb141c668e5a8e1`。
- 修正前Security scan: `84b21db5-185f-4300-b813-3e150a52a11a`。

## 確認した問題

1. Codex app-serverの`dynamicTools`は正のallowlistではなく、ambient shell / MCP / app / plugin / extension等へ追加される。Realtimeの`background_agent`からdelegated turnへ到達するため、Capability Brokerを迂回できる。
2. Voice runtimeが`calendar.events.read`を自ら構築し、Google接続やMicrophoneと別のユーザー許可なしに予定名 / 時刻をCodexへ返せる。
3. Timer承認はnative dialog表示前にsingle-flight / rate limitがなく、停止時にqueued dialog自体を取り消せない。

## 採用した修正

### Broker限定tool policy

- `thread/start`へ`environments=[]`とHost-only policy fieldを送る。ただしこれはdefense in depthであり、単独の安全証拠にしない。
- installed schemaに正のtool policyがない場合はapp-server開始前に`installed_broker_only_tool_policy_missing`で停止する。
- policy fieldが将来追加されても、公式仕様とWindows adversarial E2Eを別途承認するまで`BrokerOnlyToolPolicyProductionApproved=false`を維持し、`installed_broker_only_tool_policy_not_approved`で停止する。
- 2026-08-21の実測`codex-cli 0.145.0`は`dynamicTools` / `environments`を持つが`dynamicToolsOnly`を持たない。したがってproduction Voiceは安全に停止し、AN3-B2 PRはDraftのままとする。

### Calendar Host grant

- `VoiceCalendarAccessGranted`を既定OFFで追加した。
- Settings surfaceだけがnative default-No approvalを経て付与できる。Panel surfaceから同routeは呼べない。
- 許可前はCalendar toolをdefinitionへ含めず、呼出しを受けてもProviderへ到達する前に`permission_denied`を返す。
- grantは再起動後も保持し、Settingsから取り消せる。変更時はactive Voiceを停止し、tool definitionを再構成する。

### Timer approval

- custom Host-owned WPF dialogへexact title / durationを表示し、Enter / Escapeを含む既定判断をキャンセルにした。
- 同時promptは1件、開始promptは1分3件までとし、拒否もrate limitへ含める。
- cancellation tokenでqueued dispatcher operationをabortし、表示中dialogを閉じる。
- rate limit / cancellation / presenter failure時は未使用Broker approvalをrejectする。
- Voice停止またはroot失効後はresult replyを送らない。

## ローカル検証

- `swift build -Xswiftc -warnings-as-errors`: PASS。
- macOS `--verify-voice-foundation`: PASS。
- macOS `--verify-panel-layout`: 128 cases PASS。
- macOS `--verify-capabilities`: 14 handlers PASS。
- macOS `--verify-broker`: PASS。
- macOS `--verify-pocket-surface`: 15 negative cases PASS。
- macOS `--verify-pocket-app`: package 18 negative / lifecycle / generation PASS。
- macOS `--verify-timer`: PASS。
- `python3 script/verify_voice_foundation.py`: 42 cases PASS。
- `python3 script/verify_pocket_contracts.py`: 13 schemas / 60 fixtures PASS。
- Settings generation target: PASS。
- Windows UI JavaScript syntaxと`git diff --check`: PASS。

## 残りの受け入れゲート

- Windows Release compile warnings 0 / errors 0。
- Windows Voice verifierでCalendar grant、Timer single-flight / rate limit / cancellation、停止後reply 0件を確認する。
- Settings、rendered WebView、Capability、Broker、既存Provider回帰を同じheadで通す。
- 修正後exact diffをSecurity scanし、3 findingが再現しないことを確認する。
- PR #22の新規Codex review、未解決thread、mergeability、remote head、CIをreadbackする。
- 実Codex Voice E2Eは正のBroker-only tool policyが公式に提供・検証されるまで実行せず、Draftを維持する。
