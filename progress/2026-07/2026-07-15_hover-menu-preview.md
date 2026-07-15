# 2026-07-15 HoverPocket Google OAuth Review Remediation

## Summary

- Google OAuth verification reviewerから届いた独自ドメインとAI/ML Limited Useの追加要求へ対応した。
- 公式サイトの正本URLを `s-original.com` 配下へ変更し、Search Console所有確認、Google Auth Platform設定、審査メールへの訂正連絡まで完了して各外部stateをreadbackした。

## Completed Work

- `site/index.html` から現行公開UIに存在しないAI lane表記を除去し、Mirror / Controlsの現行機能へ更新した。
- `site/privacy.html` を2026-07-15付へ更新し、次を日本語・英語で明記した。
  - 第三者AIサービス連携はない。
  - Google Workspace / Photosデータを第三者AIへ転送しない。
  - Googleユーザーデータを基盤モデル・汎用モデル等の作成、学習、改善に使用しない。
  - 実験的macOSコードのApple Foundation Models処理は対応端末内だけで行い、Appleやモデル提供者へGoogleデータを送信しない。
  - Windowsの実験的コマンド解釈は外部AI APIを使わない決定的ローカル処理である。
- Cloudflare Worker static assets設定 `wrangler.jsonc` にcustom domain `hoverpocket.s-original.com` を追加し、`hoverpocket.shotaromatsumoto.com` は審査中の旧リンクを壊さない移行用aliasとして維持した。
- `site/index.html` と `site/privacy.html` のcanonical URLを `https://hoverpocket.s-original.com/` 配下へ更新した。
- Search ConsoleでURL-prefix property `https://hoverpocket.s-original.com/` をHTMLファイル方式で自動確認した。
- Google Auth Platform project `hoverpocket` の設定を次へ更新した。
  - Homepage: `https://hoverpocket.s-original.com/`
  - Privacy policy: `https://hoverpocket.s-original.com/privacy`
  - Authorized domain: `s-original.com`
- Google OAuth verificationスレッドへ、最終canonical URLが `s-original.com` 配下であることを英語で訂正連絡した。

## Changed Files

- `.gitignore`
- `site/index.html`
- `site/privacy.html`
- `wrangler.jsonc`
- `progress/progress.md`
- `progress/2026-07/2026-07-15_hover-menu-preview.md`

## Verification and Readback

- `wrangler deploy --dry-run`: static assets 3 filesを検出し成功。
- Cloudflare Worker deployment: version ID `2adf40b8-1adc-4a27-9ed8-42061995c5f2`。
- 公開GET readback:
  - `https://hoverpocket.s-original.com/` がHTTP 200。
  - Privacy policyは `/privacy.html` から `/privacy` へredirect後HTTP 200。
  - `site/index.html` と公開homepageのSHA-256一致。
  - `site/privacy.html` と公開privacy policyのSHA-256一致。
- Search Console readback:
  - Account: `shotaro.matsu0311@gmail.com`。
  - `https://hoverpocket.s-original.com/` の所有権をHTMLファイルで自動確認。
  - property overviewへ遷移できることを確認。
- Google Auth Platform readback:
  - homepage、privacy policy、authorized domainを再読込し、新値が保存されていることを確認。
  - Verification Centerは「ブランディングとデータアクセスは現在審査中」。
- Gmail readback:
  - URL訂正の送信message ID `19f65d9ac9d51760`、thread ID `19f658cbca0ca966`、`SENT` labelを取得。
  - Gmail connectorで対象account、送信本文、新URL、AI integrationなしの記載を確認。

## Decisions

- Google審査用の正本URLは `hoverpocket.s-original.com` とする。
- `hoverpocket.shotaromatsumoto.com` は移行用aliasとして当面維持するが、canonicalおよびGoogle Auth Platformには使わない。
- 現行公開版の第三者AIサービス一覧は `None` とする。
- experimental AI codeは現行UIで無効であり、macOSは端末内Apple Foundation Models、Windowsは外部モデルを使わない決定的parserとして説明する。

## Blocker / Risk

- 審査対応は提出済み。Google側の再審査結果待ち。
- 審査担当者が追加資料やデモ動画を求めた場合は、同じthreadで対応する。

## Next Handoff

- Automation `hoverpocket-oauth` で新しい審査返信を監視する。
- Googleから追加要求が届いた場合は、message / thread IDで重複を避け、本文全体を読んで対応する。
