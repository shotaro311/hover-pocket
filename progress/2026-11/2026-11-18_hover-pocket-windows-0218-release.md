# Windows 0.2.18 本番配信

実施日: 2026-11-18 JST。実施: Claude（Opus 5.5）。ユーザーの「本番反映して」の指示による。

## 内容

- AI使用状況パネル「AI Usage」の追加（Codex・Claude・Gemini・Museの5時間枠・1週間枠・モデル別の枠）。設計・検証・レビューは[実装の記録](2026-11-18_hover-pocket-ai-usage-panel.md)。
- Codex（gpt-6.2-astra / high）の読み取り専用レビューを2回行い、指摘をすべて直した。共通ルール上は2回目で指摘が残ったため「レビュー未完了」だったが、ユーザーが3回目は不要と判断し、配信を指示した。2回目のあとの修正はCodexの確認を受けていない。

## コミットとCI

- `0934780`（AI Usageの追加）をmainへpushしたところ、mainのWindows CIが失敗した（[実行](https://github.com/shotaro311/hover-pocket/actions/runs/44227058125)）。原因は `script/verify_voice_foundation.py` の契約チェック。`PanelBridgeController.cs` の中で最初に現れる設定画面用の分岐を目印に、音声の経路がパネル専用の範囲にあるかを調べており、`app.ready` の登録に足した同じ書き方の分岐で目印がずれた。動作の不具合ではない。この検査は手元で流していなかった。
- 分岐を `MarkSurfaceReady`（部分クラス）へ移した `d0a088b` をpushした。手元でCIと同じビルド（Release、警告をエラーにするDebug）と検証12種類が合格したあと、mainの [Windows CI](https://github.com/shotaro311/hover-pocket/actions/runs/44228181783) も成功した。
- 契約検査のワークフローのmacOSのジョブは、開始直後に取り消された。0.2.16・0.2.17のpushでも同じで、今回の変更とは関係しない。

## 公開

- 配布物は `publish_release.ps1`（beta区分）で `d0a088b` から作った（最初に `0934780` から作ったものは使っていない）。Google OAuthの値は、インストール済み0.2.17のDLLのメタデータから読み取りだけで取り出し、同じプロセスの環境変数で渡した。値は表示・保存していない（ログにも出ていないことを確認）。FFmpegは照合済みのキャッシュを使った。manifestは `embedded-and-verified` / `unsigned`、版は `0.2.18+d0a088b`、チェックサムは7件とも一致。
- [Windows 0.2.18](https://github.com/shotaro311/hover-pocket/releases/tag/win-v0.2.18) を下書きで作成し、8配布物のサイズとSHA-256が手元とすべて一致したことを確かめてから `--latest=false` で公開した。タグは `d0a088b` を指す。完全版のパッケージは180,090,728 bytes、SHA-256 `EF4B27C6F39A039879DE343165428B26E9817CF4015702745902061CC7393191`。
- 公開後の `verify_release_readback.py --windows-tag win-v0.2.18 --windows-signing-gate beta --json` は99項目で合格（全配布物を取り直して照合）。macOSの `macos-latest/appcast.xml` のSHA-256は公開前後で一致し、GitHub Latestは `v0.2.17-683` のまま。
- 更新・ロールバックCI（旧版→新版のインストール・更新・復帰）は今回は実行していない。

## このPCへの適用

- 更新前に、設定などの利用者データ（WebView2のキャッシュを除く）、素材ライブラリ（77件。DBはSQLiteのバックアップ機能で取得し、整合性ok）、インストール済み0.2.17の一式を `artifacts/release-0.2.18-20261118/` へ退避した（約710MB、Git管理外）。データの記録は同じ場所の `data_snapshot.py` で取った。
- 公開先から取得した完全版のパッケージが、フィードのSHA-256と一致することを確認した。`Update.exe apply --waitPid 3080 --package ...` を起動してから0.2.17（PID 3080）だけを終了した。Update.exeはexit 0で、0.2.18を適用して再起動した。
- 更新後: PID 65200 が `current\HoverPocket.Shell.exe` から起動して応答中。ProductVersionは `0.2.18+d0a088b`、ルートの起動用exeとアンインストール情報も0.2.18。インストールされたDLLは公開物と一致。自動起動の登録はインストール版を指したまま。診断ログは `process.start`、`shell.ready` の2件で、例外はない。
- データは、設定（新しい項目を除く）・付箋・タイマー・天気・素材77件とDBの全テーブル・カレンダーのログインが更新前と一致した。クリップボード履歴は文字30件・画像20件ともIDと順序が同じで、先頭の画像1件の保存時刻だけが再起動時刻に変わった（起動時に、いまのクリップボードの画像を既存の重複処理で読み直したため）。
- インストール済み0.2.18の `--verify ai-usage` は92項目で合格。Debug専用の `--verify ai-usage-live` は配布版では受け付けず、通常起動として既存のアプリへ引き継いで終わることを確認した。

## 残り

- 本番アプリでのサインイン（設定の「AI」→「AI使用状況」）。開発用の確認で使ったサインインは本番と別の保存場所なので引き継がれない。Codexは本番のチャット用ログインが無効のため［ChatGPTにログイン］が要る。
- 公開サイトのプライバシーポリシー（「連携している第三者AIサービスはありません」など。Codexのチャットの時点から実態と合っていない）の改訂の判断。
- macOS版のAI Usage。
- 次の版の候補（ユーザーと相談中）: Colabのcompute units残高（読み取りを確認済み）、ClaudeのConsoleのAPIクレジット、Codex/OpenAIのクレジット残高。
- FFmpegの取得元の恒久対策（前回から継続）。
