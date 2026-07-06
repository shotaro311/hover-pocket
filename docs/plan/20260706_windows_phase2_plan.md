---
project_slug: hover-pocket
target: Windows Phase 2 (bugfix + Clipboard + Google Calendar + updater)
created: 2026-07-06
updated_by: claude (architect)
status: active
related:
  - docs/requirement/requirements.md
  - docs/plan/20260705_windows_phase1_plan.md
---

# Windows 版 Phase 2 実装計画(バグ修正 + Clipboard + Calendar + 更新配信)

## 0. 背景

Phase 1 のユーザー手動 E2E で不具合 2 件が報告された。並行して、Phase 2 スコープ
(Clipboard / Google Calendar)と、更新配信(requirements Phase 4 の前倒し)を実装する。

## 1. バグ修正(最優先)

### B1(W8): hover 開閉の不安定

ユーザー報告の症状:

- hover でパネルは開くが、開いたパネルが**左右に動く**。
- hover を外しても**パネルが閉じない**。

調査観点(仮説、W8 が実証すること):

- パネルの anchor 再計算がポーリングごとに走り、カーソル位置に追従して振動している可能性。
- close 判定領域(DIPs)とカーソル座標(物理 px)の変換不整合(W2 の DPI 層)。
- W5 統合(Timer ハイライト)や W4(WebView2 ホスト)による HoverShellController の
  リグレッション。
- 再現・修正の証跡として、カーソル座標・判定領域・close 判定のトレースを
  `HOVERPOCKET_VERIFY_LOG` 併用で取れる診断モードを追加してよい。

完了条件: `--verify shell` 拡張(開いたパネルの位置が安定していること、外側カーソル
シミュレーションで close すること)+ 既存 verify の回帰。最終の体感確認はユーザー。

### B2(W6 resume): 付箋のゴミ箱ドロップでアーカイブされない

- ドラッグ中の下部ゴミ箱ドロップ(requirements 4.5)が機能していない。
- WebView2 内 DOM ドラッグとゴミ箱領域の hit 判定、drop イベントの preventDefault 漏れ等を疑う。
- `--verify sticky` にアーカイブ遷移の検査を追加し、UI 側は node --check +
  ユーザー手動確認。

## 2. W9: Clipboard provider(requirements 4.4)

- 監視は `AddClipboardFormatListener`(S2 spike で実証済み)。イベント駆動を基本とし、
  0.75s ポーリングは補助に留める。
- text 最大 30 / image 最大 20。image は PNG 正規化 + ハッシュ重複抑制。
- 保存: `%APPDATA%\HoverPocket\clipboard\`(`history.json` + 個別 PNG)。
- provider 有効時のみ監視。Private mode(Settings トグル + provider 内ボタン)で一時停止。
- 履歴クリックで再コピー。外部ドラッグは C# `DoDragDrop`(W6/S2 の方式。text=UnicodeText、
  image=Bitmap+FileDrop)。ドラッグ開始時にパネルを一時 hide(R-SHELL-004)。
- 履歴の全消去操作。機密性の注意書きを Settings に表示(R-DATA-003)。
- `--verify clipboard`: 履歴 CRUD、上限、PNG 正規化/重複抑制、永続化/復元、private mode。

## 3. W10: Google Calendar provider(requirements 4.3)

- OAuth: **Desktop app クライアント + loopback redirect + PKCE**(要件 §13 の第一候補)。
  クライアント ID/secret はリポジトリに置かず、`%APPDATA%\HoverPocket\oauth.json`
  (ユーザー配置)から読む。未配置時は provider 内に設定手順を表示。
- refresh token は Windows Credential Manager(`Windows.Security.Credentials.PasswordVault`
  または CredWrite。現行公式ドキュメントで選定)に保存。token をログ・ファイルに出さない。
- Google Calendar API v3(REST 直叩き。Google SDK への依存は増やさない):
  カレンダー一覧、42 セル月グリッド、日付 hover プレビュー、クリック固定、
  予定の追加/編集/削除(削除前確認)、read-only カレンダーは編集不可。
- 認証確認中も空グリッドを先に描画(R: 操作感)。ネットワーク断で他 provider に影響させない。
- AI lane 接続: 既存 deterministic スタブの Calendar read/create を実 Calendar 呼び出しへ
  接続する(承認フローは従来どおり必須。Calendar 未接続時は従来の案内)。
- `--verify calendar`: OAuth URL/PKCE 生成、token 保存(モック)、イベント CRUD の
  リクエスト構築、月グリッドモデル(42 セル、月境界)をネットワークなしで検査。
- 実アカウント E2E はユーザーの OAuth クライアント配置後に実施(アーキテクト+ユーザー)。

## 4. W11: 更新配信(requirements Phase 4 の前倒し)

- 方式: **Velopack + GitHub Releases**。
  理由: Sparkle(macOS 版が使用)相当の実績ある OSS updater で、GitHub Releases を
  フィードにでき、mac と同一リポジトリの Release で配信を一元化できる。
- 実装:
  - `HoverPocket.Shell` に Velopack 統合(起動時 `VelopackApp.Build().Run()`、
    Settings/トレイの `Check for Updates` を実接続、ダウンロード→適用→再起動)。
  - パッキング/配信スクリプト `windows/script/publish_release.ps1`
    (`dotnet publish` → `vpk pack` → GitHub Release へのアセットアップロード手順。
    アップロード自体は gh CLI で人間/アーキテクトが実行)。
  - Windows アセット命名は mac の Sparkle アセットと衝突させない
    (例: `HoverPocketWin-x64-<version>.nupkg` / `-Setup.exe`)。
  - バージョンは `windows/` 配下の csproj で管理し、mac のビルド番号と独立。
- 署名は Phase 2 では行わない(SmartScreen 警告が出ることを README に明記。
  署名証明書は将来の Phase 4 で判断)。
- `--verify updater`: ローカルフィード(ファイル URL)に対する更新チェックの dry-run。
  実ダウンロード適用はアーキテクト/ユーザー確認。

## 5. ファイル領域契約

- W8: `Windows/`(HoverShellController、PanelWindow、AccessSurfaceWindow)、`Display/`。
  他 provider ファイルは触らない。
- W6(resume): `Providers/Sticky*`、`windows/ui/providers/sticky/` のみ。
- W9: `Providers/Clipboard*`、`windows/ui/providers/clipboard/`。
- W10: `Providers/Calendar*`、`Services/GoogleOAuth*`、`windows/ui/providers/calendar/`。
- W11: `Services/Updater*`、`windows/script/`、csproj の Velopack 追加、
  `TrayIconService` / Settings の Check for Updates 接続(最小差分)。
- 共有ファイル(ProviderRegistry、app.js、StartupOptions、PanelBridgeController、
  UserSettings)は自分の登録・分岐・設定項目の**最小追記のみ**。編集直前に再読込。
- W8 と W9〜W11 は並行するため、`dotnet build` の file lock は 30〜60 秒待って再試行。

## 6. 受け入れ

- B1/B2: ユーザー手動 E2E で症状消失。
- W9/W10: 各 `--verify` exit 0 + 全体回帰(shell/display/ui-model/ui 含む)。
- W11: ローカルフィード dry-run 成功 + 実際の GitHub Release への配信リハーサル
  (バージョン +1 を配信し、旧バージョンから更新できること)をアーキテクトが確認。
