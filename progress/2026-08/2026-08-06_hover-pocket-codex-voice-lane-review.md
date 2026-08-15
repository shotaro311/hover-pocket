---
project_slug: hover-menu-preview
date: 2026-08-06
status: foundation-implemented; draft-pr; real-voice-not-tested
---

# Codex Voice Lane ブランチ整理・基盤実装レビュー

## GitHub整理

- 古いDraft PR #3 `feat: AI Native化 Phase 1 — AIコマンドパレットとCalendar Tool基盤` は、後続の `main` に内容が取り込まれ、head branchが `main` より先行していないことを確認した。
- PR #3へsupersededの理由をコメントし、未マージのままcloseした。
- `feature/codex-voice-lane` は、Windows 0.2.5公開後の最新 `main` `bb8f06ab103dba594d62dbef94f3b6a19a60a8fa` を親にして履歴を再構成した。
- Draft PR #6を、以後の実装・レビュー面として作成した。
- 古いremote branch 5本はすべて `main` に対するaheadが0であることを再確認した。GitHub connectorにgit ref削除操作がないため、削除前再検証付きの `windows/script/cleanup_merged_remote_branches.ps1` を追加した。

## 公式仕様の再確認

`openai/codex` の現行 `codex-rs/app-server/README.md` と照合し、結果を `docs/report/20260806-codex-app-server-upstream-verification.md` に記録した。

- stdio transportはnewline-delimited JSONで、wire上の `jsonrpc` headerは省略される。
- connectionごとに `initialize` response後の `initialized` notificationが必要。
- installed Codex自身からTypeScript型とJSON Schemaを生成できる。
- overloadはRPC code `-32001`で、bounded exponential backoff + jitterが必要。
- 現行公式資料では `v2 + WebRTC` は非対応であり、Realtime version / transportを固定値で決めない。
- 対象PCのinstalled Codexから生成したschemaと実接続結果を最終的な互換性の正本とする。

## Critical 3件への対応

### 1. Panel / WebView2からsession寿命を分離

`CodexVoiceCoordinator`基盤を追加した。

- app-server client所有
- availability / session / mute / transport状態
- root thread ID
- memory-only transcript ring buffer
- transient UI detach後もthread / transcript / app-server processを保持
- subscriber failure isolation
- 未実装のserver requestはfail closed

現時点では本番 `PanelWindow` / `HoverShellController` / WebView2 UIへ接続していない。基盤の存在を機能完成として扱わない。

### 2. 専用app-server client

`CodexAppServerClient`を追加した。

- `.exe` / `.cmd` / `.bat` / `.ps1` のCodex CLI解決
- stdin / stdout / stderr分離
- JSONL reader / writer
- request ID相関、response / error / notification / server request分離
- initialize → initialized handshake
- timeout / cancellation
- malformed line隔離
- unknown response / unhandled request診断
- server-to-client request response
- `-32001`のidempotent request限定retry
- graceful shutdownとprocess tree cleanup

UI用 `BridgeDispatcher` はapp-server transportとして流用していない。

### 3. 動的lane layout

`VoiceLaneLayoutState`と動的metricsを追加した。

- disabled: 0
- compact: 64
- expanded: Small 190 / Medium 220 / Large 250

既存 `PanelSizeCatalog.Get(panelSize)` はdisabled geometryを維持する。`DisplayLayoutService`は明示的にlayout stateを受け取れる。small / high-DPI displayでのclampをVerifierへ追加した。

## Default-off保証

`UserSettings`へ次を追加した。

- `CodexVoiceEnabled`: default false
- `CodexVoiceLayoutMode`: default Compact
- `EffectiveVoiceLaneLayout`: disabledを優先

既存または新規settingsを読み込んだだけでは、Codex process起動、microphone permission、global hotkey、panel height増加は発生しない。設定UIにはまだ公開していない。

## 検証基盤

GitHub Actions `Voice Lane Windows CI`を追加した。

- PowerShell script parse
- `git diff --check`
- .NET restore
- Debug / Release build with warnings as errors
- Windows UI JavaScript syntax check
- 既存deterministic verifier
- `voice-lane-layout`
- `codex-app-server-protocol`
- `codex-voice-coordinator`

実Codexや利用枠を消費せずprotocolを検査するため、同じWindows executable内に検証専用fake app-serverを追加した。initialize、notification、server request、overload retry、malformed JSON isolationを往復検証する。

## Windows実機用スクリプト

- `windows/script/verify_voice_lane_foundation.ps1`
  - CI相当のbuild / syntax / deterministic verifierを実行
  - `-RunCodexReadOnlyProbe`でinstalled Codexのread-only probeを追加
- `windows/script/phase0_codex_app_server_probe.ps1`
  - version / path / schema / initialize / account read / rate limits / list voicesを確認
  - model generation、Realtime session開始、外部書き込みは行わない
  - raw stdout / stderrは既定で削除し、安全なsummaryだけ残す
- `windows/script/cleanup_merged_remote_branches.ps1`
  - dry-runが既定
  - remote branchのahead=0を再確認したものだけ `-Execute` で削除

## 未実装・未実測

- production `App`でのcoordinator所有とfeature enable lifecycle
- `PanelWindow` / `HoverShellController`へのdynamic lane geometry接続
- WebView2 Voice Lane UI
- microphone permission policy / `getUserMedia`
- `RTCPeerConnection` offer / answer / remote audio / waveform
- 実Codexで利用可能なRealtime version / transport
- 接続レイテンシ、session上限、mute時transport、rate limit変化
- ChatGPT / Codex Desktop側のthread可視性と遷移
- global mute hotkey
- approval / user-input server request UI
- child session cards
- real voice E2E

## マージ方針

- PR #6はDraftを維持する。
- real Phase 0 / 0.5、microphone、WebRTC、1往復の実音声E2Eが揃うまでmergeしない。
- feature offの既存利用者へ影響する変更やrelease操作は行わない。
- Windows 0.2.5、macOS appcast、公開release資産は変更していない。