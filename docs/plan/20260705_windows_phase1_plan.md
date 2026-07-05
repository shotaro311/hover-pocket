---
project_slug: hover-pocket
target: Windows Phase 1 (low OS-dependency providers)
created: 2026-07-05
updated_by: claude (architect)
status: active
related:
  - docs/requirement/requirements.md
  - docs/plan/20260705_windows_phase0_spike_plan.md
  - docs/report/20260705-windows-candidate-c-spike-findings.md
---

# Windows 版 Phase 1 実装計画

## 0. 前提

- 技術スタックは候補C(C#/.NET 10 + WPF native shell + WebView2 UI)で**確定済み**。
- Phase 0 の成果(HoverPocket.Shell のトレイ/ミニバー/hover 開閉/Main-Sub-All/mixed DPI)の
  上に、パネル内 UI と低 OS 依存 provider を実装する。
- Phase 1 スコープ(requirements 9. Phase 1): Calculator、Timer、Sticky Notes、Settings、
  AI command lane の UI + deterministic calendar planning の枠。

## 1. アーキテクチャ決定(アーキテクト固定事項)

### A1: パネル UI は WebView2 + 静的アセット(ビルドステップなし)

- `windows/ui/` に素の HTML/CSS/ES modules(JSDoc で型注釈)を置き、
  `SetVirtualHostNameToFolderMapping` で `https://app.hoverpocket.local/` として配信する。
- **Phase 1 では npm / bundler を導入しない。** 理由: Codex sandbox のネットワーク制約
  (Schannel TLS 問題)を避け、供給網依存を最小化し、WebView2 は ES modules を
  そのまま実行できるため。TS + Vite への移行は Phase 2 以降で再検討する。
- WebView2 設定は S1 spike の実証結果を踏襲: `DefaultBackgroundColor=Transparent`、
  NOACTIVATE パネル内ホスト、角丸は host region + HTML 側描画の併用。

### A2: C# がデータと OS を所有し、Web UI は表示と入力に徹する

- 通信は WebView2 WebMessage の JSON envelope `{ id, method, params }`(双方向)。
  C# 側は `Bridge/` にディスパッチャを置き、provider ごとのハンドラに振り分ける。
- 永続化は C# 側のみ(R-DATA-001): `%APPDATA%\HoverPocket\` 配下に
  `settings.json` / `sticky/` / `timer/`。JSON 破損時は既定値へ復帰。
- Web UI はローカルストレージ等に状態を持たない(表示キャッシュを除く)。

### A3: AI command lane は UI と承認フローのみ(Phase 1)

- パネル下部固定高さ 132px。deterministic なコマンド解釈スタブ(C#)を置き、
  `今日の予定` 等の Phase 1 パターンは「Calendar 未接続」の案内を返す。
- 承認 UI の枠(提案カード + 承認/却下)は実装する。LLM/Calendar 接続は Phase 2。

### A4: 検証の運用ルール(Phase 0 の教訓)

- **WebView2 を起動する検証は Codex sandbox 内では実行不可**(renderer 起動失敗)。
  ワーカーは build と非 WebView2 検証まで sandbox 内で行い、WebView2 依存の
  `--verify ui` 等は「アーキテクト実行待ち」として progress に明記する。
  アーキテクト(Claude)が sandbox 外で実行して合否判定する。

## 2. ワーカー分割(DAG)

```
W4: WebView2 統合基盤(先行・単独)
 ├─ W5: Calculator + Timer     (W4 完了後、並行可)
 ├─ W6: Sticky Notes           (W4 完了後、並行可)
 └─ W7: Settings + AI lane 枠  (W4 完了後、並行可)
```

### W4: WebView2 統合基盤

- PanelWindow に WebView2 をホスト(透過・NOACTIVATE、S1 の実装を参考)。
- `windows/ui/` の骨格: app shell、暗色テーマ(CSS custom properties、requirements の
  寸法値: header 54、AI lane 132、panel S/M/L)、provider コンテナ。
- Bridge 基盤(C# ディスパッチャ + JS 側 `bridge.js`、request/response/event)。
- Provider header: provider 名、サイズ切替、provider アイコン列、設定アイコン
  (Click/Hover 切替は設定値で分岐。R-UX-003)。
- Provider registry(C#)と空 provider 3 枠(placeholder 表示)。
- 設定ストア `settings.json`(panel size / text size / provider order・visibility /
  switching mode / language の器。UI は W7)。
- `--verify ui`(bridge round-trip、provider 切替、設定読み書き)。sandbox 内では
  build + 静的検証まで、WebView2 実行はアーキテクト実行待ちにする。

### W5: Calculator + Timer(requirements 4.7 / 4.6)

- Calculator: 四則演算・小数・±・%・BS・AC・コピー、キーボード入力、`Error` 処理。
  計算ロジックは C# 側 `CalculatorEngine` に置き、ユニットテスト相当の
  `--verify calc` を持つ(UI なしで検証可能にする)。
- Timer: 通常/ポモドーロ、preset ピン留め最大4、同時実行最大2、絶対終了時刻ベース、
  終了時パネル自動表示 + ハイライト。状態は `timer/` に永続化。`--verify timer`。

### W6: Sticky Notes(requirements 4.5)

- ボードグリッド、inline editor、色、並び替え、archive/delete + Undo、
  外部ドラッグ(S2 の実装を流用)、`sticky/` 永続化。`--verify sticky`。

### W7: Settings + AI command lane 枠(requirements 5. / 4.8)

- Settings ウィンドウ(WebView2、通常のアクティブ化可能ウィンドウ): Phase 1 対象は
  言語 JA/EN、パネルサイズ、文字サイズ、provider 切替方式/表示/順序、
  Windows 起動時実行(既定オフ)。
- AI lane: 入力欄、deterministic スタブ応答、承認 UI 枠、audit log(JSONL)。

## 3. ファイル領域契約(並行時の衝突防止)

- W5: `windows/src/HoverPocket.Shell/Providers/Calculator*`, `Providers/Timer*`,
  `windows/ui/providers/calculator/`, `windows/ui/providers/timer/`
- W6: `.../Providers/Sticky*`, `windows/ui/providers/sticky/`
- W7: `.../Settings*`, `.../AiLane*`, `windows/ui/settings/`, `windows/ui/ailane/`
- 共有ファイル(ProviderRegistry への登録等)は「登録1行の追記のみ可」とし、
  それ以外の共通基盤変更が必要ならアーキテクトへ報告して停止する。

## 4. 受け入れ条件(Phase 1 完了判定)

- パネル内で 3 provider + AI lane が切り替わり、閉→開で状態が保持される。
- 再起動後に Sticky/Timer/設定が復元される(R-UX-003 受け入れ条件)。
- `dotnet build` 警告 0、全 `--verify *` が exit 0(WebView2 系はアーキテクト実行)。
- アイドル時に camera/mic/クリップボード監視等が動かない(Phase 1 は該当なしを確認)。
