# Windows 0.2.21・0.2.22 本番配信

実施日: 2026-11-19 JST。実施: Claude（Opus 5.5）。0.2.21はユーザーの「Release both」、0.2.22は「両方配信する」による。

## 0.2.21（AI Usageの作り替え）

- 内容: AI Usageを一覧とメーターの切り替えにした（[作業記録](2026-11-19_hover-pocket-ai-usage-layout.md)）。
- `4769417`（Windows）と `2e582f1`（macOSの変更をMacのブランチから載せたもの）をmainへpush。Verify WindowsとVerify Pocket Contractsは成功、Verify macOS Capabilitiesは、macOSの検証コードの大きなクロージャがCIのSwift 6.4で型推論の時間切れになり失敗した（Windowsの配布物には関係しない）。macOSの修正は0.2.22と一緒に入れた。
- [Windows 0.2.21](https://github.com/shotaro311/hover-pocket/releases/tag/win-v0.2.21) を下書きで作り、8配布物のサイズとSHA-256の一致を確かめてから `--latest=false` で公開した。タグは `2e582f1`。公開後の読み戻し99項目に合格、macOSの更新フィードは不変、GitHub Latestは `v0.2.18-771` のまま。
- このPCへの適用: 利用者データとインストール済み0.2.20を `artifacts/release-0.2.21-20261119/` へ退避（約740MB、Git管理外）し、`Update.exe apply --waitPid` のあと旧PIDだけを終了。0.2.21（PID 60560）で起動し、DLLは公開物と一致、データは更新前と一致（クリップボードの先頭1件の時刻だけが再起動で更新）。インストール済み版の `--verify ai-usage` 207項目合格。本番のパネルで一覧とメーターが実データで出ることを画面で確かめた。

## 0.2.22（セクション分け、数字の書体、並び替えの不具合）

- 内容: 「サブスクの利用枠」と「クレジット・残高」のセクション、Apple風の数字（同梱のInter 4.1）、ポインタ操作の並び替え（[作業記録](2026-11-19_hover-pocket-ai-usage-layout.md)の「0.2.21のあとの改訂」）。
- `b376e72`（Windows）と `89aac08`（macOS）をmainへpushし、Verify Windows、Verify macOS Capabilities、Verify Pocket Contractsの3つとも成功。
- 配布物は `publish_release.ps1`（beta区分）で作った。OAuthの値はインストール済みDLLのメタデータから読み取りだけで渡し、ログに含まれないことを確認。manifestは `embedded-and-verified` / `unsigned`、版は `0.2.22`、チェックサム7件一致。完全版のパッケージに `ui/fonts/InterVariable.woff2` と `ThirdParty/Inter-LICENSE.txt` が入っていることを確かめた。
- [Windows 0.2.22](https://github.com/shotaro311/hover-pocket/releases/tag/win-v0.2.22) を下書きで作り、8配布物の一致を確かめてから `--latest=false` で公開した。タグは `89aac08`。公開後の読み戻し99項目に合格、macOSの更新フィードは公開前後で一致、GitHub Latestは `v0.2.18-771` のまま。完全版のパッケージのSHA-256は `41EA7F2634A258BA359F2F4BBF5DFA4A4E93CF378257183E91513A6EFC68C17C`。
- このPCへの適用: 利用者データとインストール済み0.2.21を `artifacts/release-0.2.22-20261119/` へ退避（約743MB、素材DBの整合性ok）。公開先の完全版がフィードと一致することを確かめ、`Update.exe apply --waitPid 60560` のあと旧PIDだけを終了。0.2.22（PID 59644）で起動し、DLLと書体のファイルは公開物と一致、起動用exe・アンインストール情報・自動起動の登録も0.2.22。診断ログは `process.start`、`shell.ready` だけ。データは更新前と一致（クリップボードの先頭1件の時刻だけが再起動で更新）。インストール済み版の `--verify ai-usage` 226項目合格。
- 実画面: 本番のパネルで、2つのセクションとInterの数字が実データで出ることを確かめた。本番での実際のマウスによる並び替えは、Parsecが前面にあり本人がPCを使っていたため行っていない（同じコードの開発版で、実際のマウス入力による並び替えの検査に合格している）。

## 残り

- 本番での並び替えの手での確認（ユーザー）。
- macOS 0.2.19の配信（別に記録）。
- 0.2.21の画面確認のときに誤って撮った、別のアプリの会話が写った画像がWindowsのごみ箱にある（ユーザーに伝えた）。
