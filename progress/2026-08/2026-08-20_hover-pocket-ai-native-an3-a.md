# 2026-08-20 HoverPocket AI-native AN3-A Voice Lane Foundation

## 結論

AN3を一度に実音声まで有効化せず、まず両OSのHost-owned Voice Laneとapp-server lifecycleをdefault-offで実装した。現時点では承認済みCompact / Expanded UI、root-scoped session表示、パネル非表示時のmute、失敗時のprocess cleanup、Settings surfaceからの会話データ隔離までを受入対象とする。microphone、WebRTC、実Codex Realtime、Capability tool実行はまだproductionで起動しない。

## Git / 土台

- worktree: `/Users/shotaro/code/share/hover-menu-preview-ai-native-an3a`
- branch: `codex/ai-native-an3-voice-foundation`
- 初期base: `0c121f1a9bf2e0bfc2eb7fcd54da3e7f69423ee6`
- AN3-A実装commit: `2b678c0`
- AN5-C最新head `eb08ebaee12bd9178d4b0f1664f1b29ddd6c6807`の2コミットをmerge済み
- mainへ直接変更せず、AN5-C PR #18上のstacked branchとして扱う

## 実装

### 共通契約

- `disabled / compact / expanded`の3状態だけを持つ。
- Voice LaneはProviderではなくShell最下段のHost-owned rowである。
- Compactは視覚タイトルなし、短い補助波形、会話優先、明示expand controlとする。
- Expandedは左transcript、右current root配下のsession cardとし、fullscreenを持たない。
- session / transcriptはmemory-only、件数・文字数・可視文字を制限する。
- production microphone / WebRTC / tools / MCP / realtime adapterはfixture上もfalseとする。

### macOS

- SwiftUI shellへVoice Laneを追加し、設定へdefault-offとCompact / Expanded選択を追加した。
- Voice Lane高さを既存Provider高さへ加算し、パネル上端とProvider領域を固定したまま下方向だけへ拡張する。
- hover close、Settings表示、外部drag、Reduce Motionを含む全`orderOut`経路を共通helperへ集約し、非表示前に`detachPanel()`でmuteする。
- application lifetimeのruntimeがUI再生成後もroot / transcript / child sessionを保持する。

### Windows

- PanelのHost DOM最下段へVoice Laneを追加し、Settingsからdefault-off / Compact / Expandedを設定できる。
- `PanelBridgeController`はVoice transcript / session stateをPanel surfaceだけへ返し、Settings stateは`voiceLane: null`とする。
- app-server JSONL clientは、受信行を固定bufferから読み、改行前に1 MiB上限を強制する。
- initialize失敗、取消、transport crash、feature OFFでcandidate / active clientとowner process treeを破棄する。
- legacy AI command lane verifierとVoice verifierを分け、旧renderer / routeがmountされないnegative regressionを維持する。

## ChatGPT Pro回収

- skill: `chatgpt-pro-orchestrator` 0.7.2
- run: `20260820-170946-an5-c-exact-head-0c121f1pr-6voicean3-aoshost-owned-voice-lane-foundationdefault-offcompact-expandedroot-scoped-cardslifecycle-state-machinedeterministic-testschanges-patch`
- generation 2 delivery: `return-1624b849f10726e95b63d0eecb8feaf6`
- delivery ID / state hash / receipt / baseをclaim後にだけ成果物を評価した。
- 返却artifactは再生成後も旧内容だったため、Skillのisolated recovery手順に従い、Codexがローカルで不足実装と修正を完了した。
- mark-doneはCIと最終受入後に実行する。

## ローカル検証

成功:

- `swift build -Xswiftc -warnings-as-errors`
- `HoverPocket --verify-voice-foundation`
- `HoverPocket --verify-panel-layout`: 128件
- `HoverPocket --verify-capabilities`: 14 handler
- `HoverPocket --verify-broker`
- `HoverPocket --verify-pocket-surface`
- `HoverPocket --verify-pocket-app`
- `HoverPocket --verify-timer`
- `python3 script/verify_pocket_contracts.py`: 13 schema / 60 fixture
- `python3 script/verify_voice_foundation.py`: 42 geometry / state件
- Windows panel / settings JavaScript syntax
- `node windows/script/verify_settings_generation_target.mjs`
- `git diff --check`
- `./script/build_and_run.sh --build-only`
- `codesign --verify --deep --strict dist/HoverPocket.app`
- 開発bundle `SUFeedURL`なし

注記:

- 誤った未定義flag `--verify-capability-broker`を一度実行して通常アプリが起動したため、対象processを終了した。正しい`--verify-broker`で再実行し成功した。
- ローカルMacにはWindows用.NET SDKがないため、Windows Release build、Settings、Voice、rendered WebView回帰はGitHub Actionsを完了gateとする。

## Security review

初回exact working-tree scan `2e66ad14-b483-4468-ba95-5855a02cff88`は29 / 29 review item、reportable finding 0件でsealed completeとなった。その後の境界レビューで将来adapter有効化前に必要な4点を検出し、AN3-A内で修正した。

1. macOSの保持NSPanelを`orderOut`する経路を共通detach / muteへ接続。
2. Windows Settings surfaceへVoice transcript / sessionを配信しない。
3. Windows app-server initialize失敗 / crash後もprocess ownerを確実にdispose。
4. Windows app-serverの受信行をallocation前に上限判定。

修正後のexact Security scanをPR完了条件に残す。

## 未完了 / 次のgate

1. Windows CIでRelease build、Voice verifier、Settings、rendered WebView、全既存回帰を成功させる。
2. 修正後exact Security scanを完了し、finding 0または修正済みをreadbackする。
3. stacked PRを作成し、review thread、mergeability、remote head、CIを確認する。
4. AN3-BでWindows実機のinstalled Codex schema / account / capability probeを行う。
5. 明示クリックからのmicrophone permission、WebRTC 1往復、safe closeを実装する。
6. Agent Tool AdapterをCapabilityBrokerへ接続し、Calendar read / createとTimer startを承認・readback付きで実音声検証する。
7. Windows合格後にmacOS実音声parityへ進む。
