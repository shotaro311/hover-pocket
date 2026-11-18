# Windows 0.2.19 本番配信

実施日: 2026-11-18 JST。実施: Claude（Opus 5.5）。ユーザーの「確かめずに配信」の指示による（Claude APIの実データでの確認は行わずに配信）。

## 内容

- AI Usageの残高（Claude ConsoleのAPIクレジット、Codexのクレジット、Colabのコンピューティング ユニット）と、共通のChatGPTログインでチャットの「ログインが必要です」がすぐ消える修正。詳細は[作業記録](2026-11-18_hover-pocket-ai-usage-balances.md)。
- Codex（gpt-6.2-astra / high）の読み取り専用レビューを2回行い、指摘をすべて直した。共通ルール上は「レビュー未完了」で、ユーザーが3回目は不要と判断した。2回目のあとの修正はCodexの確認を受けていない。

## コミットとCI

- `1816925` をmainへpushした。push前に手元で、CIと同じビルド（Release、警告をエラーにするDebug）、静的な契約チェック、検証13種類が合格した。mainの [Windows CI](https://github.com/shotaro311/hover-pocket/actions/runs/44247199804) も成功した。
- 公開リポジトリに入る記録と検証用の値から、ユーザーのアカウントの実際の残高を取り除いた。

## 公開

- 配布物は `publish_release.ps1`（beta区分）で作った。Google OAuthの値はインストール済み0.2.18のDLLのメタデータから読み取りだけで取り出し、同じプロセスの環境変数で渡した（ログに値が出ていないことを確認）。manifestは `embedded-and-verified` / `unsigned`、版は `0.2.19+1816925`、チェックサムは7件とも一致。
- [Windows 0.2.19](https://github.com/shotaro311/hover-pocket/releases/tag/win-v0.2.19) を下書きで作り、8配布物のサイズとSHA-256が手元とすべて一致したことを確かめてから `--latest=false` で公開した。タグは `1816925` を指す。完全版のパッケージは180,108,212 bytes、SHA-256 `07D52ADFE67052D14C341B2BB9B3676AFD38E061C8E086CE8AF13F3899739EEE`。
- 公開後の `verify_release_readback.py --windows-tag win-v0.2.19 --windows-signing-gate beta --json` は99項目で合格。macOSの `macos-latest/appcast.xml` のSHA-256は公開前後で一致し、GitHub Latestは `v0.2.17-683` のまま。更新・ロールバックCIは今回も実行していない。

## このPCへの適用

- 更新前に、設定などの利用者データ（WebView2の保存場所を除く）、素材ライブラリ（78件。DBはSQLiteのバックアップ機能で取得し、整合性ok）、インストール済み0.2.18の一式を `artifacts/release-0.2.19-20261118/` へ退避した（約717MB、Git管理外）。
- 公開先から取得した完全版のパッケージが、フィードのSHA-256と一致することを確認した。`Update.exe apply --waitPid 65200 --package ...` を起動してから0.2.18（PID 65200）だけを終了した。Update.exeはexit 0で、0.2.19を適用して再起動した。
- 更新後: PID 54740 が `current\HoverPocket.Shell.exe` から起動して応答中。ProductVersionは `0.2.19+1816925`、ルートの起動用exeとアンインストール情報も0.2.19。インストールされたDLLは公開物と一致。自動起動の登録はインストール版を指したまま。診断ログは `process.start`、`shell.ready` の2件で、例外はない。
- データは、設定（新しい項目を除く）・付箋・タイマー・天気・素材78件とDBの全テーブル・カレンダーのログインが更新前と一致した。クリップボード履歴は文字30件・画像20件ともIDと順序が同じで、文字1件の保存時刻だけが再起動時刻に変わった（起動時に、いまのクリップボードを既存の重複処理で読み直したため）。
- インストール済み0.2.19の `--verify ai-usage` は136項目で合格。

## 残り

- 本番アプリでのClaude Consoleのサインインと、APIクレジットの実データでの確認（ユーザーの判断で未確認のまま配信）。
- 本番アプリでのチャットの表示の確認（チャット用のChatGPTログインは12:20に有効になっている）。
- 公開サイトのプライバシーポリシーの改訂の判断、macOS版のAI Usage、FFmpegの取得元の恒久対策（前回から継続）。
