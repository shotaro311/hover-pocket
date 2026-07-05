---
project_slug: hover-pocket
target: Windows Phase 0 technical spike
created: 2026-07-05
updated_by: claude (architect)
status: active
related: docs/requirement/requirements.md
---

# Windows 版 Phase 0 技術検証(spike)計画

## 0. 体制

- アーキテクト: Claude(本計画の作成、タスク分割、レビュー、受け入れ判定)
- ワーカー: Codex(Codex Peer 経由。実装、テスト、検証、progress 記録)
- ワーカーは本計画と `docs/requirement/requirements.md` を正とし、逸脱が必要な場合は
  progress ログに理由を記録して停止する(勝手に仕様を変えない)。

## 1. 技術前提(spike で検証する仮説)

- 候補C: **C#/.NET 10 + WPF ネイティブシェル + WebView2 UI** を第一候補とする。
- Phase 0 では WebView2 を使わず、まずネイティブシェル(ウィンドウ制御)だけを検証する。
  WebView2 の埋め込み適合性(透明・NOACTIVATE ウィンドウとの相性)は W3 で検証する。
- この選定は Phase 0 の結果で覆してよい(Tauri v2 が代替)。Phase 1 着手前に確定する。
- **2026-07-05 確定: W1〜W3 完了とアーキテクト再検証(S1 全ケース pass)により候補Cを採用。**
  根拠: `docs/report/20260705-windows-candidate-c-spike-findings.md` のアーキテクト再検証章。

## 2. ディレクトリ契約

```
windows/
  HoverPocket.Windows.sln
  README.md                     # ビルド・実行・検証手順
  src/
    HoverPocket.Shell/          # WPF exe (net10.0-windows)
```

- Swift 側 (`Sources/`, `Package.swift`, `Resources/`) には一切手を入れない。
- ワーカーが変更してよいのは `windows/`、`progress/`、`docs/plan/` 配下のみ。
- git commit / push はワーカーは行わない(アーキテクトがレビュー後に実施)。

## 3. ワーカー分割

### W1: シェル spike(トレイ+上端オーバーレイ+hover 開閉)

Must:

- .NET 10 / WPF で `HoverPocket.Shell` を新規作成する。
- タスクトレイ常駐: アイコン + メニュー(`Open Panel` / `Quit`。`Settings` はプレースホルダ)。
  通常ウィンドウ・タスクバー表示は出さない。
- 上端ミニバー(access surface): プライマリモニター上端中央に、細い控えめなバーを常時表示。
  `WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW` + topmost + 枠なしで、フォーカスを奪わない。
- hover 開閉: 上端ホットゾーンにマウスが入ると空の暗色パネル(角丸、Medium: 600x430 DIPs、
  上端中央アンカー)が展開し、離れると閉じる。
  - open/close duration `0.22s`、close delay `0.06s`(requirements R-UX-002)。
  - hover 許容域は起点/パネル外周 +4px(R-SHELL-004)。
  - close 判定は 0.12s 間隔の polling で補助。
  - パネルも NOACTIVATE(Phase 0 では入力を受けない空パネルでよい)。
- 多重起動防止: named mutex。2 回目の起動は既存インスタンスへ通知して終了。
- Per-Monitor V2 DPI awareness を manifest で宣言する(マルチモニター対応自体は W2)。

検証(完了条件):

- `dotnet build` が警告なしで成功する。
- `--verify shell` スモークモード: 起動→ウィンドウスタイル(NOACTIVATE/TOOLWINDOW/topmost)
  検査→プログラム的に open/close を 25 回実行→ウィンドウ増殖なしを確認→exit 0/1。
- 手動 E2E(実際のマウス hover での開閉体感)は未検証として progress に明記し、
  ユーザー確認に回す。

### W2: マルチモニター + mixed DPI(W1 完了後)

- Main / Sub / All の表示先切り替え、mixed DPI での座標破綻なし、
  モニター接続/切断・解像度変更後の再計算(R-SHELL-002)。

### W3: リスク spike 3 点(W1 完了後、W2 と並行可)

- WebView2 を NOACTIVATE な透明 topmost ウィンドウへ埋め込めるか(合否が候補C確定の鍵)。
- クリップボード監視 + 画像/テキストの外部アプリへの drag out。
- WebView2 `getUserMedia` でのカメラ表示と権限フロー。

## 4. Phase 0 全体の受け入れ条件(requirements 9. Phase 0 より)

- 空パネルが上端から 0.22 秒前後で開閉する。
- トレイ常駐、多重起動防止、終了/再起動が安定している。
- Main/Sub/All の最小挙動が動く(W2)。
- フルスクリーン抑制の実現可否が判断できる(W2 以降で調査)。

## 5. ワーカー共通ルール

- 作業終了時に `progress/2026-07/` へ作業ログを追記する(実施内容、検証結果、未実施)。
- 検証していないものを「完了」と書かない。失敗・スキップは明示する。
- 秘密情報(トークン等)をコード・ログ・progress に出さない。
- 新規 API・ライブラリの採用時は公式ドキュメントの現行仕様を確認してから使う。
