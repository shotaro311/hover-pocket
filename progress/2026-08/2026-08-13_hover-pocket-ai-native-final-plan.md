---
project_slug: hover-menu-preview
date: 2026-08-13
status: plan-approved; ui-contract-approved; implementation-not-started
updated_by: codex
---

# HoverPocket AIネイティブ化 最終実装プラン

## 実施範囲

- 計画作成だけを実施した。
- ユーザーが最終アーキテクチャ案とCompact / ExpandedのVoice Lane UIを承認したため、計画と正本要件を同期した。
- コード実装、branch作成、worktree追加、commit、push、PR更新、releaseは行っていない。
- 正本要件、計画、progress、採用UI画像だけを変更した。

## 再確認した正本と実コード

- `progress/progress.md`
- `docs/requirement/requirements.md`
- `main`のmacOS `PocketProvider`、Provider Registry、Store、旧AI Lane、Approval、Audit、Calendar Tool。
- `main`のWindows Provider Registry、Bridge、各Provider Controller / Store、旧AI Lane、WebView renderer。
- `origin/feature/codex-voice-lane`のapp-server client、coordinator、layout、settings、verifier、CI、計画、進捗ログ。
- `product-compass-reports/2026-06-15-hoverpocket-ai-pocket.html`と既存AIアーキテクチャレポート。
- MulmoClaudeのMANIFESTと4本のarchitecture paper。
- OpenAI公式のCodex app-server、Realtime、MCP / Connectors資料。

## Git readback

- checkoutは`main`、HEAD `61330e82f6979a47190f5e7ed03053a8cea6ec2f`。
- `origin/main`も同じSHAで、開始時worktreeはcleanだった。
- `git worktree list --porcelain`ではmainの1件だけ。Voice Lane用worktreeは現在ない。
- Voice branchは`374aa6a39b5860ebfb6cd944a62f08106c72cff4`。
- `origin/main...origin/feature/codex-voice-lane`はmain側12 / Voice側40 commit、merge-baseは`bb8f06ab103dba594d62dbef94f3b6a19a60a8fa`。
- Draft PR #6はOpen / MERGEABLE。CIは成功済みだが、production UI、microphone、WebRTC、Capability接続、実音声E2Eが未達のため、完成・マージ可能とは判定していない。
- 旧`feature/ai-native-phase1`はmainより123 commit古く、ahead 0。再開対象にしない。

## 主要判断

- `PocketProvider`をAI APIへ拡張せず、`PocketSurface`と`PocketCapability`へ分離する。
- `CapabilityRegistry`を単一正本、`CapabilityBroker`を唯一の実行入口とする。
- Voice、Text、既存UI、Pocket App、MCPは同じBrokerを通す。
- Pocket Appは有限DSLで表現し、Codexはdraft生成、Hostはvalidate / permission / execute / readback / rollbackを担当する。
- MCPは内部正本ではなく外部Adapterとする。
- 最初の縦断はToday Focus Pocketとし、Calendar read、Timer start、Sticky upsert、write approval、readbackを両OSで通す。
- Today Focusとは別に、Calendar createの実音声・承認・event ID readbackをVoice MVP gateへ含める。
- arbitrary native code hot installは本番要件にしない。
- 既存Windows基盤roadmapを`W0〜W4`、AI-native実装を`AN0〜AN8`へnamespace化し、同じPhase番号が別作業を指す曖昧さを解消した。

## 確定したVoice Lane UI契約

- Voice LaneはProviderではなくHost所有の全Provider共通bottom rowとする。
- Voice機能はdefault-off。明示enable後の既定はCompact、自動listenは別opt-inとする。
- Compactは視覚的な`Codex Voice`タイトルを置かず、短い波形より会話1〜2行を優先する。明示expand controlだけで展開する。
- Expandedはパネル上端、幅、Header、Provider矩形を維持し、外枠の下端だけを伸ばす。左はcurrent transcript、右は現在root配下のcurrent / child / descendant session cardsとする。
- Provider圧縮、Provider overlay、fullscreen、全過去会話browser、New / Delete / Archive session管理は採用しない。
- mute、hover close、Voice session終了を分離し、hover closeだけでchild taskをcancelしない。
- approval / receiptはHost-owned Voice Laneへ表示し、生成Pocket Appに描画させない。

採用画像:

- `docs/plan/assets/20260813-ai-native/voice-lane-compact.png`
  - 1475×1067。
  - SHA-256 `1e9f25663eec799e143a6a26a60f8b625da0c31140498f5a1d81ed8efe658792`。
- `docs/plan/assets/20260813-ai-native/voice-lane-expanded.png`
  - 1254×1254。
  - SHA-256 `79a0b371be2c8e5f72005552a4baaab637551c4a409205c28fe24d9ab3d4ea7f`。

画像はピクセル完全一致の仕様ではなく、文章化したUI契約の視覚的受け入れ基準として扱う。

## 成果物

- `docs/plan/20260813_PLAN1.md`
  - 最終アーキテクチャ図。
  - component責務と主要schema例。
  - 現行コードからの段階移行。
  - macOS / Windows共通契約とOS固有実装。
  - Voice Lane統合、権限、sandbox、lifecycle、audit / readback。
  - Phase依存関係、完了条件、検証、Git / worktree / PR計画。
  - 推奨案、代替案、採用しない案、未決定事項。
- `docs/requirement/requirements.md`
  - Legacy AI command laneとCodex Voice Laneを分離。
  - Shell bottom row、Compact / Expanded、下方向拡張、session card、Capability / Broker要件を追加。
- `docs/plan/assets/20260813-ai-native/`
  - 承認済みCompact / Expanded UI画像。

## 次のgate

実装開始指示後、最初のPRはrequirements、ADR、versioned JSON contracts、Voice UI contract、採用画像、fixturesだけに限定する。Capability handlerやVoice実装は、その契約がreview / mergeされるまで開始しない。

## 計画書readback

- 必須セクション22項目の存在確認: `plan_required_sections=ok`。
- Markdown code fenceは42個で対応が取れ、conflict markerと行末空白は0件。
- `../../AGENTS.md`と`../requirement/requirements.md`の相対参照先が存在する。
- tracked差分の`git diff --check`はexit 0。
- 2026-08-13のMacは`codex-cli 0.145.0`。Voice branch計画のWindows `0.144.3`を現行前提にせず、対象OSでschemaを再生成する計画にした。
- 最終差分は計画書、requirements、日別progress、`progress/progress.md`、採用画像2件で、source code差分はない。
