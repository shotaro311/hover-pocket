# 2026-08-30 HoverPocket macOS Codex app-server Voice

## 結論

macOS Voice Laneの標準providerをCodex app-serverへ接続した。これはOpenAI APIキーを使うRealtime BYOK経路ではなく、ローカルCodexのログイン状態とapp-serverを使う経路である。Capabilityの正本は引き続きHoverPocketのRegistry / Brokerで、CodexはCalendar read/createとTimer startだけを同じBroker経由で実行する。

実装基盤と決定論的検証は通ったが、現在インストール済みのCodex `0.145.0`にはBroker限定の正のtool policyを示す`dynamicToolsOnly`がない。そのためinstalled readinessは意図どおりBLOCKEDであり、実音声が動作済みとは扱わない。

## 実装

- Codex app-server JSON-RPC client、account / voice確認、root thread、Realtime WebRTC SDP、transcript、root-scoped child session cardをmacOS Hostへ接続した。
- app-server dynamic toolは既存Capability Runtimeから生成し、Calendar read/create、Timer startを既存Broker、承認、監査、readbackへ委譲した。
- installed Codex schemaを起動前に生成・検証し、`dynamicToolsOnly` boolean propertyがないversionはprocess起動前に停止する。
- probe対象の実行ファイルURLとsize / mtime / inode由来identityを保持し、spawn直前と再起動ごとに同一性を検査する。PATHの再解決で別binaryへ切り替わらない。
- version subprocessは5秒、schema subprocessは15秒、WebView readyは2秒、Voice開始全体は30秒で有限化した。
- WebRTC切断はserver Realtime stopとVoice Laneのdisconnected状態へ接続した。stop RPCはsingle-flightで共有し、provider切替、grant変更、失敗cleanupの重複を抑止した。
- app-server stdout / stderr chunkはstreamごとのserial queueから単一AsyncStream consumerへ渡し、stdout notificationも順番に処理する。
- transcript publishは67ms単位、root card timestampは固定、Expanded child session pollは接続中だけ3秒ごと、最新16件、thread/read最大4並列に制限した。
- Settingsは`Off / Codex app-server（推奨） / Realtime BYOK`の順とし、BYOKは明示選択時だけ利用し自動fallbackしない。

## 独立レビュー

別エージェントへ、安全対策が正常動作や性能を損なっていないかをread-onlyレビューさせた。初回P1はinstalled readiness表示、binary pin、subprocess timeout、WebRTC timeout / cancel、切断状態、stop重複、stdout順序の7件で、すべて局所修正した。さらにambient要求の入力順隔離、pending / current / 旧clientのidentity + generation分離、隔離後の再起動禁止まで再レビューし、最終結果はP0 / P1とも0件だった。

Broker限定policy、read-only sandbox、approval never、空workspace roots、root / generation / call / tool照合、非永続WebView、CSP、trusted custom scheme、5秒microphone armingは、過剰安全ではなくCapability境界に必要なため維持した。ambient分類とquarantineだけをstdout consumerで短く順序処理し、通常tool本体はその後にTask化するため、危険な要求の追い越しと長時間toolによるstdout停止を同時に避ける。

## 検証とreadback

- `swift build -Xswiftc -warnings-as-errors`: PASS
- `swift run --skip-build HoverPocket --verify-voice-foundation`: PASS
- `swift run --skip-build HoverPocket --verify-codex-app-server`: foundation PASS、installed readiness BLOCKEDを明示
- `swift run --skip-build HoverPocket --require-codex-app-server-ready`: exit 2、`codex_broker_only_tool_policy_missing`
- `swift run --skip-build HoverPocket --verify-capabilities`: PASS、20 handler
- `swift run --skip-build HoverPocket --verify-broker`: PASS、21 descriptor / 20 handler
- `python3 script/verify_voice_foundation.py`: PASS、42 cases。app-server request admissionの順序、client quarantine、lifecycle / generation分離、probe timeout / executable pinも静的回帰で確認
- `python3 script/verify_pocket_contracts.py`: PASS、15 schema / 71 fixture
- `git diff --check`: PASS
- 隔離E2E app bundle: build PASS、executable存在、`codesign --verify --deep --strict` PASS、microphone purpose stringにCodex app-serverを含むことをreadback。bundleは実行せずTrashへ移動した。

## 未完了gate

- Broker限定tool policyを持つ対応Codexの用意と公式仕様照合。
- 対応versionでのaccount / voices / thread / SDP / transcript実接続。
- 物理マイク取得、remote audio再生、Calendar read/create、Timer start、承認、実行後readbackの10回反復。
- CPU / RSS、mic clickからattachedまでのp95、snapshot publishes/sec、Expanded RPC/sec、stop RPC/session=1の計測。
- Draft PRのCIと人手レビュー。merge、release、既存notarized build 583の差し替えは未実施。
