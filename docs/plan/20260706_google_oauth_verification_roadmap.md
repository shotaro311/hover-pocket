---
project_slug: hover-pocket
target: Google OAuth 審査(一般配布)ロードマップ / 判断材料
created: 2026-07-06
updated_by: claude (architect)
status: decision-material
related:
  - windows/src/HoverPocket.Shell/Services/GoogleOAuthService.cs
  - docs/plan/20260706_windows_phase2_plan.md
---

# Google OAuth 審査ロードマップ(判断材料)

一般配布で非開発者に「普通のアプリ」として使ってもらう場合に必要な作業の全体像。
この文書は判断材料であり、着手指示ではない。

## 0. 結論(先に)

- HoverPocket が使うのは **sensitive スコープ**(`calendar.events` / `calendar.readonly`)。
  一般公開アプリは Google の **sensitive scope verification(審査)が必要**。
- ただし **restricted スコープ(Gmail/Drive 等)ではない**ため、
  **有料の第三者セキュリティ評価(CASA)は不要**。審査自体は無料。
- 審査は「単体の申請作業」ではなく、下記 3 点セット:
  1. アプリへの client_id 同梱(実装変更)
  2. プライバシーポリシー等の公開ページ整備
  3. Google Cloud Console からの審査申請
- 審査申請の主体は**プロジェクトオーナー(松本)本人**。Claude は代理申請できない。
  Claude は実装変更・ドラフト作成・手順ガイドを担当する。

## 1. 未審査のままだと何が起きるか(一般配布での体験)

- 同意画面の前に「このアプリは Google で確認されていません」警告が出る
  (非開発者は「詳細 → 続行」を自力で押しにくく、離脱・不信の原因)。
- 新規 100 ユーザー上限。
- (Testing 状態に留めた場合は追加で)テストユーザー登録制 + refresh token が 7 日で失効し、
  毎週再ログインが必要。→ 配布には不適。

審査を通すと上記がすべて解消し、通常アプリの同意体験になる。

## 2. 審査に出す前に必要な実装変更

### 2.1 client_id 同梱方式への切り替え(必須・Claude 担当可)

現状: 各ユーザーが自分で Google Cloud の Desktop クライアントを作り
`%APPDATA%\HoverPocket\oauth.json` に配置する開発者向け方式。

一般配布: **開発者(松本)のプロジェクトの client_id をアプリに同梱**し、
ユーザーは Google ログインするだけにする。

注意点(Codex ワーカーへ指示する際の設計事項):
- Desktop client の client_secret は「秘密」だが、Google の native app OAuth では
  secret を完全機密にはできない前提(PKCE で保護)。secret をリポジトリ平文に置かず、
  ビルド時埋め込み or 難読化 or 配布物内に留める方針を決める。
- 既存の「oauth.json をユーザー配置」経路は開発者向けフォールバックとして残してよい。
- 見積り: Codex ワーカー 1 タスク(実装 + `--verify` 更新)。

### 2.2 スコープ最小化の検討(審査を軽くする)

- 現状 `calendar.events` + `calendar.readonly` の 2 つ。
- 審査では「なぜそのスコープが必要か」を説明する。`calendar.readonly` は
  カレンダー一覧取得のために入っているが、`calendar.events` だけで要件を満たせるなら
  1 スコープに減らすと審査の説明・通過が楽になる。
- 実装確認タスク(Claude/Codex): readonly を外して機能が成立するか検証。
  → 減らせるなら審査前に対応。

## 3. 審査申請に必要な公開物(松本が用意、Claude がドラフト可)

- **プライバシーポリシーの公開 URL**(必須)。取得データ(カレンダー予定)、用途、
  第三者提供の有無、保存先(ローカルのみ)、削除方法を明記。
  → Claude がアプリの実挙動に基づきドラフト作成可。公開(ホスティング)は松本。
- **アプリのホームページ URL**(必須)。GitHub Pages / リポジトリ README でも可の場合あり。
- **ドメイン所有権の確認**(Search Console 等)。上記 URL のドメインが対象。
- **スコープ利用理由の説明文**(Claude がドラフト可)。
- 場合により **デモ動画**(OAuth 同意 → 機能利用の流れ)。松本が録画、Claude が段取り提示。

## 4. 役割分担

| 作業 | 主体 |
|---|---|
| client_id 同梱の実装変更 | Claude(Codex ワーカー) |
| スコープ最小化の実装確認 | Claude(Codex ワーカー) |
| プライバシーポリシー草案 | Claude ドラフト → 松本が確認・公開 |
| スコープ理由説明文の草案 | Claude ドラフト → 松本が確認 |
| ホームページ/ポリシーの公開(ホスティング) | 松本 |
| ドメイン所有権確認 | 松本 |
| Google Cloud Console での審査申請・やり取り | 松本(オーナー本人) |
| デモ動画の録画 | 松本(Claude が段取り) |

## 5. 所要期間の目安

- 実装変更(client_id 同梱 + スコープ確認): 半日〜1 日(Codex ワーカー)。
- ポリシー等の整備: 松本の作業次第(数時間〜数日)。
- Google の審査: 提出後 **数日〜数週間**(sensitive scope。やり取りが発生すると延びる)。
  restricted ではないので CASA(有料・長期)は不要。

## 6. 推奨する進め方(段階分け)

1. **今 → 身近な配布**: Production・未審査のまま家族友人に配り、バグ・使い勝手を固める
   (100 人枠・警告ありでも実用上は回る)。今のユーザー配置方式のままでよい。
2. **一般配布を決断した時点**: 本ロードマップの 2〜4 を実行して審査申請。
   実装変更を配布前に入れておくことで、審査通過と同時に一般配布へ移行できる。

## 7. 一次情報(2026-07-06 時点、要点)

- sensitive/restricted のみ審査必須(非 sensitive は brand verification のみ):
  https://support.google.com/cloud/answer/13463073
- 未審査アプリ: 警告画面 + 新規 100 ユーザー上限:
  https://support.google.com/cloud/answer/7454865
- Testing: テストユーザー 100 人・refresh token 7 日失効:
  https://support.google.com/cloud/answer/15549945
- sensitive scope verification(審査要件):
  https://developers.google.com/identity/protocols/oauth2/production-readiness/sensitive-scope-verification
