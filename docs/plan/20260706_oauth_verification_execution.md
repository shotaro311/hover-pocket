---
project_slug: hover-pocket
target: OAuth 審査対応 実行計画
created: 2026-07-06
updated_by: claude (architect)
status: active
related:
  - docs/plan/20260706_google_oauth_verification_roadmap.md
  - windows/src/HoverPocket.Shell/Services/GoogleOAuthService.cs
---

# OAuth 審査対応 実行計画

ロードマップ(`20260706_google_oauth_verification_roadmap.md`)の実行。
Claude/Codex で進める部分と、ユーザー本人が行う部分を分ける。

## 役割分担(再掲・確定)

- Claude/Codex: 実装変更、スコープ検証、公開物のドラフト、手順書作成、公式仕様の確認。
- ユーザー本人(松本): Google Cloud Console の同意画面設定・スコープ登録・**審査申請の送信**、
  Search Console のドメイン所有権確認、GitHub Pages の公開設定の最終承認。
  理由: Google アカウント認証と不可逆な外部申請を伴うため、安全上 Codex に自動実行させない。

## W13(コード): client_id 同梱 + スコープ最小化

### A. client_id 同梱方式

現状: `GoogleOAuthConfiguration.Load()` は `%APPDATA%\HoverPocket\oauth.json` のみから読む
(開発者向け。非開発者に Cloud Console 作業を強いる)。

変更方針(アーキテクト確定):
- **解決順序**: (1) ビルド時に埋め込んだ client_id/secret → (2) `oauth.json`(上級者・
  開発者向けフォールバック)→ (3) どちらもなければ従来どおり設定案内。
- **埋め込み方法**: MSBuild プロパティ `GoogleOAuthClientId` / `GoogleOAuthClientSecret` を
  受け取り、生成コード or `AssemblyMetadata` 経由で定数化。**ソースには実値を置かない**
  (空既定)。`publish_release.ps1` が環境変数 `HOVERPOCKET_GOOGLE_CLIENT_ID` /
  `HOVERPOCKET_GOOGLE_CLIENT_SECRET` から渡す。
- **OSS 安全**: リポジトリに実値を含めない(`.gitignore` + 空既定)。desktop client の
  secret は Google 設計上「完全機密ではない」が、平文リポジトリ直書きは避ける。
- token/secret をログ・progress に出さない(既存方針を維持)。

### B. スコープ最小化の検証

- 現状 `calendar.events` + `calendar.readonly`。`readonly` はカレンダー一覧
  (CalendarList.list)取得のために入っている。
- Codex が **Google 公式仕様(CalendarList API の必要スコープ)を確認**し、
  `calendar.events` だけで要件(複数カレンダー選択・予定 CRUD)を満たせるか判定する。
  - 満たせる → `readonly` を外して 1 スコープにする(審査が軽くなる)。
  - 満たせない → `readonly` を残し、「なぜ必要か」の審査説明文に根拠を書く。
  機能要件(requirements 4.3)を優先し、無理に外さない。

### 検証

- `dotnet build`(警告0)、`--verify calendar` / `ui-model` の exit 0。
- 埋め込みなしビルドで従来の oauth.json フォールバックが働くこと、埋め込みありで
  oauth.json 不要になることを `--verify` で検査(実値は使わずダミーで経路確認)。

## W14(ドキュメント): 公開物と手順書

`site/` に GitHub Pages 用の静的ページを作る(日英)。

- `site/index.html`: アプリのホームページ(概要、機能、ダウンロード、スクショ枠、
  問い合わせ先)。審査の「アプリのホームページ URL」要件を満たす。
- `site/privacy.html`: プライバシーポリシー。**アプリの実挙動に基づく**内容:
  取得データ(Google カレンダーの予定)、用途(パネル内表示・作成/編集)、
  第三者提供なし、保存先(ローカルのみ: Credential Manager / `%APPDATA%`)、
  クリップボード履歴・付箋のローカル保存、削除方法、更新の配信元(GitHub)。
- `docs/report/20260706-oauth-scope-justification.md`: 審査で使うスコープ理由説明文
  (使用スコープごとに「何のために・どの機能で」)。
- `docs/plan/20260706-google-cloud-console-steps.md`: **ユーザーが実施する手順書**。
  Cloud Console の OAuth 同意画面設定 → スコープ登録 → テスト → 審査申請、
  Search Console でのドメイン確認、GitHub Pages 公開設定を、画面順にステップ化。

Codex はブラウザ/web で **GitHub Pages の現行公開要件と Google 審査の現行必須項目を
公式確認**してから手順書に反映する。実際の Cloud Console 操作・申請送信はしない
(ユーザー作業として手順書化するに留める)。

## ファイル領域契約

- W13: `Services/GoogleOAuth*`、`Providers/Calendar*`(scope 参照箇所のみ)、
  `HoverPocket.Shell.csproj`、`windows/script/publish_release.ps1`、`.gitignore`、
  `Verification/`(calendar/oauth 分岐)、`progress/`。
- W14: `site/`、`docs/`、`progress/`。
- 両者はファイルが重ならないため並行実行可。

## 完了後(ユーザー承認が要る段階)

1. GitHub Pages を有効化して `site/` を公開(公開設定は最終的にユーザー承認)。
2. ユーザーが Cloud Console 手順書に沿って同意画面・スコープ・審査申請を実施。
3. client_id を取得したら、`publish_release.ps1` に環境変数で渡してリリースビルド。
