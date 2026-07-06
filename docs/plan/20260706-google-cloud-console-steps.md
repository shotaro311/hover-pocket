---
project_slug: hover-pocket
target: Google Cloud Console / Search Console / GitHub Pages user steps
created: 2026-07-06
updated_by: codex-w14
status: draft-for-user-action
related:
  - site/index.html
  - site/privacy.html
  - docs/report/20260706-oauth-scope-justification.md
---

# OAuth 審査に向けたユーザー実施手順

## 0. この手順書の位置づけ

この手順は、松本さん本人が実施する外部サービス操作を画面順にまとめたものです。
Codex は実際の Google Cloud Console 操作、Search Console の所有権確認、審査申請送信、GitHub Pages 公開設定の最終承認を実行しません。

本タスクで用意済みのもの:

- `site/index.html`: OAuth 審査のホームページ URL として使う公開ページ。
- `site/privacy.html`: OAuth 審査のプライバシーポリシー URL として使う公開ページ。
- `docs/report/20260706-oauth-scope-justification.md`: Data Access / verification で使うスコープ理由説明。

事前にユーザーが用意するもの:

- Google Cloud プロジェクトのオーナーまたは編集者権限。
- OAuth のユーザーサポートメールと開発者連絡先メール。
- 公開後の GitHub Pages URL。既定候補は `https://shotaro311.github.io/hover-pocket/`。
- 必要に応じてデモ動画。Google が要求する場合、OAuth 同意画面、Calendar パネル表示、予定の作成/編集/削除、AI lane の承認フローを短く録画する。

## 1. GitHub Pages 公開設定

### 推奨案: GitHub Actions で `site/` を公開する

推奨は GitHub Actions で `site/` ディレクトリを Pages artifact としてデプロイする方法です。

理由:

- GitHub Pages のブランチ公開設定で選べるフォルダーは、公式ドキュメント上、選択したブランチの `/` または `/docs` だけです。今回の成果物は `site/` に置く指定なので、ブランチ公開だけでは `site/` を直接公開元にできません。
- `main` の `/docs` へ公開物を移す案は、審査用公開ページと内部計画・報告ドキュメントが混ざります。
- `gh-pages` ブランチ案は手動コピーや生成物の同期が増えます。
- GitHub Actions 案なら、リポジトリ内の `site/` をそのまま公開でき、OAuth 審査用ページと内部 `docs/` を分離できます。

### ユーザーがやること

1. GitHub で `shotaro311/hover-pocket` を開く。
2. `Settings` -> `Pages` を開く。
3. `Build and deployment` の `Source` を `GitHub Actions` にする。
4. 次の内容の workflow を `.github/workflows/pages.yml` として追加する。W14 の契約範囲外なので、このファイルは本タスクでは作成していない。

```yaml
name: Deploy OAuth pages

on:
  push:
    branches: ["main"]
    paths:
      - "site/**"
      - ".github/workflows/pages.yml"
  workflow_dispatch:

permissions:
  contents: read
  pages: write
  id-token: write

concurrency:
  group: "pages"
  cancel-in-progress: false

jobs:
  deploy:
    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v6
      - name: Setup Pages
        uses: actions/configure-pages@v5
      - name: Upload artifact
        uses: actions/upload-pages-artifact@v4
        with:
          path: "site"
      - name: Deploy to GitHub Pages
        id: deployment
        uses: actions/deploy-pages@v4
```

5. workflow を commit / push する。
6. `Actions` タブで `Deploy OAuth pages` が成功したことを確認する。
7. `Settings` -> `Pages` に表示される公開URLを開き、次を確認する。
   - ホームページ: `https://shotaro311.github.io/hover-pocket/`
   - プライバシーポリシー: `https://shotaro311.github.io/hover-pocket/privacy.html`
   - ホームページからプライバシーポリシーへリンクできること。
   - GitHub Releases と GitHub Issues への外部リンクが開けること。

### 事前に用意済みのもの

- `site/index.html`
- `site/privacy.html`

## 2. Search Console で所有権確認

Google OAuth 審査では、ホームページ URL とプライバシーポリシー URL のドメインが、Google 側で所有確認されている必要があります。

### GitHub Pages 既定ドメインを使う場合

GitHub Pages の既定URLを使う場合、DNS TXT レコードを追加できないため、Search Console の `URL-prefix` プロパティを使うのが現実的です。

ユーザーがやること:

1. Search Console を開く: https://search.google.com/search-console
2. `プロパティを追加` をクリックする。
3. `URL-prefix` を選ぶ。
4. 公開された Pages URL を入力する。例: `https://shotaro311.github.io/hover-pocket/`
5. 所有権確認方法を選ぶ。
   - 推奨: `HTML file upload`
   - 代替: `HTML tag`
6. `HTML file upload` の場合:
   - Search Console から `googleXXXXXXXXXXXX.html` のような確認ファイルをダウンロードする。
   - そのファイルを `site/` 直下に追加する。
   - GitHub Pages workflow を再実行または push で再デプロイする。
   - `https://shotaro311.github.io/hover-pocket/googleXXXXXXXXXXXX.html` がブラウザで開けることを確認する。
   - Search Console に戻って `Verify` をクリックする。
7. `HTML tag` の場合:
   - Search Console が提示する `<meta name="google-site-verification" ...>` を `site/index.html` の `<head>` 内に追加する。
   - 再デプロイ後、Search Console で `Verify` をクリックする。
8. 所有権確認に成功したら、OAuth 審査が終わるまで確認ファイルまたは meta tag を削除しない。

### カスタムドメインを使う場合

カスタムドメインを使う場合は、Search Console の `Domain` プロパティを追加し、ドメイン管理画面に Google の TXT レコードを追加します。Domain property は DNS 確認が必要です。

## 3. Google Cloud Console / Google Auth Platform 設定

### 3.1 プロジェクトと API

ユーザーがやること:

1. Google Cloud Console を開く: https://console.cloud.google.com/
2. HoverPocket 用の本番プロジェクトを選ぶ。開発・テスト用と本番公開用は分けるのが安全。
3. `APIs & Services` で Google Calendar API が有効であることを確認する。

事前に用意済みのもの:

- なし。これは Google Cloud 側の設定確認。

### 3.2 Branding / OAuth 同意画面

ユーザーがやること:

1. Google Cloud Console のメニューから `Google Auth platform` -> `Branding` を開く。
2. 未設定の場合は `Get Started` をクリックする。
3. `App Information` で以下を入力する。
   - App name: `HoverPocket`
   - User support email: 松本さんが監視できるメールアドレス
4. `Audience` で `External` を選ぶ。
5. `Contact Information` で Google からの審査連絡を受け取れるメールアドレスを入力する。
6. Google API Services User Data Policy を確認し、同意できる場合だけ同意して作成する。
7. Branding の `App Domain` に以下を入力する。
   - Application home page: GitHub Pages のホームページ URL
   - Application privacy policy: GitHub Pages の `privacy.html` URL
   - Terms of service: 未用意なら空欄のまま。Google Console が必須にした場合は別途 Terms ページを作成する。
8. `Authorized domains` に Pages のドメインを追加する。
   - GitHub Pages 既定URL例: `shotaro311.github.io`
   - カスタムドメインを使う場合: そのドメイン
9. App logo は任意。ロゴを登録する場合、ブランド審査の対象になる。未準備なら追加しない。

事前に用意済みのもの:

- `site/index.html`
- `site/privacy.html`

### 3.3 Audience / テストユーザー / 公開状態

ユーザーがやること:

1. `Google Auth platform` -> `Audience` を開く。
2. 開発・確認中は `Testing` のまま、松本さんの Google アカウントを `Test users` に追加する。
3. 一般配布に進める段階で `Publish app` を押して `In production` にする。
4. Sensitive scope の検証が完了するまでは、未確認アプリ警告が出る可能性があることを理解しておく。

注意:

- Testing 状態の refresh token は、Google の現在の説明では同意から7日で失効する。
- In production は任意の Google アカウントからアクセスできる状態だが、sensitive scope の検証が終わるまでは警告が出る可能性がある。

### 3.4 Data Access / スコープ登録

ユーザーがやること:

1. `Google Auth platform` -> `Data Access` を開く。
2. `Add or Remove Scopes` をクリックする。
3. 現在の Windows 実装に合わせて次のスコープを追加する。
   - `https://www.googleapis.com/auth/calendar.events`
   - `https://www.googleapis.com/auth/calendar.calendarlist.readonly`
4. 旧実装互換の `https://www.googleapis.com/auth/calendar.readonly` は Data Access に追加しない。これは既存保存済み token を受け入れるための互換処理であり、新規同意で要求する scope ではない。
5. `Save` する。

事前に用意済みのもの:

- `docs/report/20260706-oauth-scope-justification.md`

### 3.5 Prepare for verification / 審査申請

ユーザーがやること:

1. `Google Auth platform` または `OAuth consent screen` の最後のページで `Prepare for verification` を開く。
2. ホームページ URL とプライバシーポリシー URL が公開され、ログインなしで閲覧できることを確認する。
3. Search Console の所有権確認が完了していることを確認する。
4. スコープごとの利用理由に、`docs/report/20260706-oauth-scope-justification.md` の提出用文面を貼る。
5. Google がデモ動画を要求する場合は、以下が映る動画を提出する。
   - Google OAuth 同意画面。
   - HoverPocket の Calendar パネルで予定が表示される場面。
   - 予定の作成、編集、削除。
   - AI lane が候補を出し、ユーザー承認後に Calendar 操作を実行する場面。
6. 内容を確認し、松本さん本人が問題ないと判断した場合だけ送信する。

Codex がしないこと:

- Google Cloud Console へのログイン操作。
- 審査申請の送信。
- client_id / client_secret / token の記録。

## 4. 公式参照

- GitHub Pages publishing source: https://docs.github.com/en/pages/getting-started-with-github-pages/configuring-a-publishing-source-for-your-github-pages-site
- GitHub Pages custom workflows: https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages
- OAuth consent screen and scopes: https://developers.google.com/workspace/guides/configure-oauth-consent
- OAuth app branding / authorized domains: https://support.google.com/cloud/answer/15549049
- OAuth app verification overview: https://support.google.com/cloud/answer/13463073
- Verification requirements: https://support.google.com/cloud/answer/13464321
- Submitting your app for verification: https://support.google.com/cloud/answer/13461325
- App audience / testing / production: https://support.google.com/cloud/answer/15549945
- Search Console ownership verification: https://support.google.com/webmasters/answer/9008080
- Sensitive scope verification: https://developers.google.com/identity/protocols/oauth2/production-readiness/sensitive-scope-verification
