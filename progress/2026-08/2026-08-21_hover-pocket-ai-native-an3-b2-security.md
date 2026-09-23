---
project_slug: hover-pocket
phase: AN3-B2
date: 2026-08-21
status: pr-ci-green; security-rescan-complete; production-policy-blocked
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

## PR CI / Security readback

- source head `9705fe0`への主要修正Security scan `7e463a78-a2b0-4305-849e-f1418c495949`は15 / 15 review itemを完了し、reportable finding 0件でsealed completeとなった。
- 初回Windows CIはWPFの`Color` / `Brushes`型名衝突だけで失敗した。権限・承認・実行ロジックを変えず`WpfMedia`型へ明示したcommit `057d090`をpushした。
- compile-only差分 `9705fe0...057d090`のSecurity scan `ef74ba38-38cd-4df9-8fc7-a813566d1dac`は1 / 1 review itemを完了し、reportable finding 0件でsealed completeとなった。
- final source head `8e8a064`でWindows [32406234638](https://github.com/shotaro311/hover-pocket/actions/runs/32406234638)、macOS [32406234704](https://github.com/shotaro311/hover-pocket/actions/runs/32406234704)、3OS contract / compare [32406234731](https://github.com/shotaro311/hover-pocket/actions/runs/32406234731)、PR Router [32406231112](https://github.com/shotaro311/hover-pocket/actions/runs/32406231112)がすべて成功した。WindowsはRelease build、Voice、Settings、Broker、rendered WebView UIを含む全stepが成功した。
- PR #22はDraft、`MERGEABLE / CLEAN`、remote head一致、未解決review thread 0件である。

## Pre-activation hardening

- Codexへ返すCalendar結果からProvider内部`eventRef`を除去し、予定名・開始・終了だけをbounded / sanitized responseにした。内部Broker readbackではeventRefを維持するが、モデル境界へは渡さない。
- Voice有効化とCalendar grant変更を同じHost semaphoreで直列化した。権限取消時は設定保存より先にactive Voiceを`CancellationToken.None`で停止し、保存失敗時も旧Calendar tool処理を継続させない。
- `an3-b2-windows-capability-fixture.json`、Python契約、Windows native verifierへ、Provider識別子非送信、Host直列化、revoke-before-saveを固定した。ローカルでVoice contract 42件、Pocket contract 13 schema / 60 fixture、`git diff --check`が成功した。
- exact差分 `c6d7069...8e8a064`のSecurity scan `c5d44635-05a9-4081-9236-65937fbb289e`は5 / 5 review item、coverage complete、reportable finding 0件でsealed completeとなった。
- PR readbackはDraft、`MERGEABLE / CLEAN`、remote parity `0 / 0`、未解決review thread・review・commentはいずれも0件である。

## 残りの受け入れゲート

- 新規Codex reviewが追加された場合は、内容を確認して同じreadback gateを再実行する。
- Core Integration Gateの残差をlive監査し、公式positive Broker-only tool policyまたはBrokerだけを公開する専用最小runtimeの採否と受け入れ証拠を確定する。
- 実Codex Voice E2Eは正のBroker-only tool policyが公式に提供・検証されるまで実行せず、Draftを維持する。

## AN3-B1最終統合

- PR #21最終head `97099eaf2fa03d7f29ccf6eb9bdb652c6e748992`を通常mergeし、merge commit `b197f3a5ab582bce9c5705c2423778625bc58feb`へ統合した。履歴改変とforce pushは行っていない。
- 競合は`PanelBridgeController.cs`と`CodexVoiceCoordinator.cs`の2ファイルだけである。Host compositionはCapability Brokerから作る`CodexVoiceCapabilityRuntime`とVoice実runtimeの両方を接続し、初期runtime stateもHost geometryへ反映する。
- Voice設定変更はHost semaphoreで直列化したまま、OFF時はrequest取消の影響を受けずCoordinator停止を完了する。Coordinatorはactive tool requestを先に取消し、`Stopping`へ遷移してからrestart / startup / app-server / Realtimeを順序どおり停止する。Disposeも同じfeature transition gate内でtool取消とprocess teardownを完了する。
- ローカルではSwift warnings-as-errors build、macOS Voice / Panel layout 128件 / Capability 14 handler / Broker / Pocket Surface / Pocket App / Timer、Voice contract 42件、共通contract 13 schema / 60 fixture、Windows JavaScript syntax、Settings generation target、`git diff --check`が成功した。
- exact integration Security scan `95c5ee8a-8105-4bcf-97f7-d3bd3f10f02e`は16 / 16 review item、coverage complete、reportable finding 0件、sealed completeである。Codex 0.145.0のBroker-only policy不在によるproduction fail-closedは維持する。
- 統合headのWindows [32419442331](https://github.com/shotaro311/hover-pocket/actions/runs/32419442331)、macOS [32419442358](https://github.com/shotaro311/hover-pocket/actions/runs/32419442358)、3OS contract / compare [32419442324](https://github.com/shotaro311/hover-pocket/actions/runs/32419442324)、PR Router [32419439979](https://github.com/shotaro311/hover-pocket/actions/runs/32419439979)は全7 check成功。PR #22はDraft、未解決review thread 0件、`CLEAN / MERGEABLE`、remote parity `0 / 0`である。
