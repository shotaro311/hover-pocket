# 2026-07-15 HoverPocket Google OAuth Review Remediation

## Summary

- Google OAuth verification reviewerから届いた独自ドメインとAI/ML Limited Useの追加要求へ対応した。
- 公式サイト、Search Console所有確認、Google Auth Platform設定、審査メール返信まで完了し、各外部stateをreadbackした。

## Completed Work

- `site/index.html` から現行公開UIに存在しないAI lane表記を除去し、Mirror / Controlsの現行機能へ更新した。
- `site/privacy.html` を2026-07-15付へ更新し、次を日本語・英語で明記した。
  - 第三者AIサービス連携はない。
  - Google Workspace / Photosデータを第三者AIへ転送しない。
  - Googleユーザーデータを基盤モデル・汎用モデル等の作成、学習、改善に使用しない。
  - 実験的macOSコードのApple Foundation Models処理は対応端末内だけで行い、Appleやモデル提供者へGoogleデータを送信しない。
  - Windowsの実験的コマンド解釈は外部AI APIを使わない決定的ローカル処理である。
- Cloudflare Worker static assets設定 `wrangler.jsonc` を追加し、Worker `hoverpocket-site` をcustom domain `hoverpocket.shotaromatsumoto.com` へ配信した。
- Search ConsoleでURL-prefix property `https://hoverpocket.shotaromatsumoto.com/` をHTMLファイル方式で自動確認した。
- Google Auth Platform project `hoverpocket` の設定を次へ更新した。
  - Homepage: `https://hoverpocket.shotaromatsumoto.com/`
  - Privacy policy: `https://hoverpocket.shotaromatsumoto.com/privacy`
  - Authorized domain: `shotaromatsumoto.com`
- Google OAuth verificationスレッドへ、独自ドメイン移行、所有確認、AIサービス一覧、Limited Use遵守内容を英語で返信した。

## Changed Files

- `.gitignore`
- `site/index.html`
- `site/privacy.html`
- `wrangler.jsonc`
- `progress/progress.md`
- `progress/2026-07/2026-07-15_hover-menu-preview.md`

## Verification and Readback

- `wrangler deploy --dry-run`: static assets 3 filesを検出し成功。
- Cloudflare Worker deployment: version ID `9c333d3a-ebcb-4ce3-be36-ceab409b7ed0`。
- 公開GET readback:
  - Homepage HTTP 200。
  - Privacy policyは `/privacy.html` から `/privacy` へredirect後HTTP 200。
  - `site/index.html` と公開homepageのSHA-256一致。
  - `site/privacy.html` と公開privacy policyのSHA-256一致。
- Search Console readback:
  - Account: `shotaro.matsu0311@gmail.com`。
  - `https://hoverpocket.shotaromatsumoto.com/` の所有権をHTMLファイルで自動確認。
  - property overviewへ遷移できることを確認。
- Google Auth Platform readback:
  - homepage、privacy policy、authorized domainを再読込し、新値が保存されていることを確認。
  - Verification Centerは「ブランディングとデータアクセスは現在審査中」。
- Gmail readback:
  - 送信message ID `19f65ca35f1d977d`、thread ID `19f658cbca0ca966`、`SENT` labelを取得。
  - Gmail画面で対象account、送信本文、新URL、AI integrationなしの記載を確認。

## Decisions

- Google審査用の正本URLは `hoverpocket.shotaromatsumoto.com` とする。
- 現行公開版の第三者AIサービス一覧は `None` とする。
- experimental AI codeは現行UIで無効であり、macOSは端末内Apple Foundation Models、Windowsは外部モデルを使わない決定的parserとして説明する。

## Blocker / Risk

- 審査対応は提出済み。Google側の再審査結果待ち。
- 審査担当者が追加資料やデモ動画を求めた場合は、同じthreadで対応する。

## Next Handoff

- Automation `hoverpocket-oauth` で新しい審査返信を監視する。
- Googleから追加要求が届いた場合は、message / thread IDで重複を避け、本文全体を読んで対応する。
