# 2026-08-20 HoverPocket AI-native AN3-A Voice Lane Foundation

## 結論

AN3を一度に実音声まで有効化せず、まず両OSのHost-owned Voice Laneとapp-server lifecycleをdefault-offで実装した。現時点では承認済みCompact / Expanded UI、root-scoped session表示、パネル非表示時のmute、失敗時のprocess cleanup、Settings surfaceからの会話データ隔離までを受入対象とする。microphone、WebRTC、実Codex Realtime、Capability tool実行はまだproductionで起動しない。

## Git / 土台

- worktree: `/Users/shotaro/code/share/hover-menu-preview-ai-native-an3a`
- branch: `codex/ai-native-an3-voice-foundation`
- 初期base: `0c121f1a9bf2e0bfc2eb7fcd54da3e7f69423ee6`
- AN3-A実装commit: `2b678c0`
- AN5-C最新head `eb08ebaee12bd9178d4b0f1664f1b29ddd6c6807`の2コミットをmerge済み
- PR: [#19](https://github.com/shotaro311/hover-pocket/pull/19)
- 最終source head: `77af78f608b342c9d1069f8ab069440e6d54e8a5`
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
- 起動途中candidateをCoordinator所有Task / cancellationとして追跡し、Voice OFFは破棄完了後にだけDisabledを返す。app-serverのteardown awaitはWPF dispatcherを捕捉しない。
- candidate切断とReady昇格の競合は、generation / current client確認とReady snapshot更新を同じlock内で行い、失効candidateがfailed stateをReadyで上書きしない。
- legacy AI command lane verifierとVoice verifierを分け、旧renderer / routeがmountされないnegative regressionを維持する。

### 表示言語

- macOS Voice Laneのplaceholder、接続 / activity status、会話role、session status、空表示、button、accessibility文言を`AppSettings.appLanguage`へ接続した。
- 日本語既定時に英語が混在せず、英語選択時は英語へ切り替わる回帰をSwift verifierへ追加した。Compactの視覚タイトルなし契約は維持する。

## ChatGPT Pro回収

- skill: `chatgpt-pro-orchestrator` 0.7.2
- run: `20260820-170946-an5-c-exact-head-0c121f1pr-6voicean3-aoshost-owned-voice-lane-foundationdefault-offcompact-expandedroot-scoped-cardslifecycle-state-machinedeterministic-testschanges-patch`
- generation 2 delivery: `return-1624b849f10726e95b63d0eecb8feaf6`
- delivery ID / state hash / receipt / baseをclaim後にだけ成果物を評価した。
- 返却artifactは再生成後も旧内容だったため、Skillのisolated recovery手順に従い、Codexがローカルで不足実装と修正を完了した。
- 最終受入後、delivery `return-1624b849f10726e95b63d0eecb8feaf6`を`processed`へmark-doneし、state hash `5798362c23de242d8c5324aa8b7b68ce535e2120779f162617c9c23d45e886f0`をreadbackした。

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
- 最終追加修正後も`swift build -Xswiftc -warnings-as-errors`、`--verify-voice-foundation`、`--verify-panel-layout` 128件、Voice contract 42件、Pocket contract 13 schema / 60 fixture、Windows JavaScript syntax、`git diff --check`が成功した。

注記:

- 誤った未定義flag `--verify-capability-broker`を一度実行して通常アプリが起動したため、対象processを終了した。正しい`--verify-broker`で再実行し成功した。
- ローカルMacにはWindows用.NET SDKがないため、Windows Release build、Settings、Voice、rendered WebView回帰はGitHub Actionsを完了gateとする。

## Security review

初回exact working-tree scan `2e66ad14-b483-4468-ba95-5855a02cff88`は29 / 29 review item、reportable finding 0件でsealed completeとなった。その後の境界レビューで将来adapter有効化前に必要な4点を検出し、AN3-A内で修正した。

1. macOSの保持NSPanelを`orderOut`する経路を共通detach / muteへ接続。
2. Windows Settings surfaceへVoice transcript / sessionを配信しない。
3. Windows app-server initialize失敗 / crash後もprocess ownerを確実にdispose。
4. Windows app-serverの受信行をallocation前に上限判定。

修正後のincremental reviewでは、権限拡張、Settings surfaceへの会話データ流出、raw secret / path出力、生成SurfaceからのHost receipt偽装、process / candidate残留につながる新しい経路は見つからなかった。追加差分はcleanup、atomic promotion、localizationに限定される。

## PR / CI 最終readback

- Windows Verify: [32372769351](https://github.com/shotaro311/hover-pocket/actions/runs/32372769351) 成功。Release build、Voice foundation、Settings、rendered WebView、既存回帰を含む。
- macOS Verify: [32372769330](https://github.com/shotaro311/hover-pocket/actions/runs/32372769330) 成功。
- 3OS contract / byte比較: [32372769256](https://github.com/shotaro311/hover-pocket/actions/runs/32372769256) 成功。
- PR Router: [32372766956](https://github.com/shotaro311/hover-pocket/actions/runs/32372766956) 成功。
- PR #19はhead `77af78f`、`CLEAN`、remote head一致、未解決review thread 0件である。

## 未完了 / 次のgate

1. PR #18を人手で先にmergeし、PR #19のbase / CIを再確認してからmergeする。
2. 両OS実機でCompact / Expanded、下方向拡張、全Provider共通lane、日本語 / 英語、hide時muteを目視確認する。
3. AN3-BでWindows実機のinstalled Codex schema / account / capability probeを行う。
4. 明示クリックからのmicrophone permission、WebRTC 1往復、safe closeを実装する。
5. Agent Tool AdapterをCapabilityBrokerへ接続し、Calendar read / createとTimer startを承認・readback付きで実音声検証する。
6. Windows合格後にmacOS実音声parityへ進む。
