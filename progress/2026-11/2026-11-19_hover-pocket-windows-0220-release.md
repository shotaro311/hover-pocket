# Windows 0.2.20 本番配信

実施日: 2026-11-19 JST。実施: Claude（Opus 5.5）。ユーザーの「本番にも反映しておいて」と、3回目のレビューを行わない「このまま」の判断による。

## 内容

- AI UsageにAntigravity CLI（agy）の利用枠の欄を追加。詳細は[作業記録](2026-11-19_hover-pocket-ai-usage-antigravity.md)。
- Codex（gpt-6.2-astra / high）の読み取り専用レビューを2回行い、指摘をすべて直した。共通ルール上は「レビュー未完了」で、2回目のあとの修正はCodexの確認を受けていない。ユーザーは3回目なしで本番化すると判断した。

## コミットとCI

- `eb386d9` をmainへpushした。push前に手元で、CIと同じビルド（Release、警告をエラーにするDebug）、静的な契約チェック、検証14種類（`--verify ai-usage` 187項目を含む）が合格した。mainの [Verify Windows](https://github.com/shotaro311/hover-pocket/actions/runs/44457774486) と [Verify Pocket Contracts](https://github.com/shotaro311/hover-pocket/actions/runs/44457774418) はどちらも成功した。

## 公開

- 配布物は `publish_release.ps1`（beta区分）で作った。Google OAuthの値はインストール済み0.2.19のDLLのメタデータから読み取りだけで取り出し、同じプロセスの環境変数で渡した（ログに値が含まれないことを確認）。FFmpegは照合済みのキャッシュを使った。manifestは `embedded-and-verified` / `unsigned`、版は `0.2.20`、チェックサムは7件とも一致。
- [Windows 0.2.20](https://github.com/shotaro311/hover-pocket/releases/tag/win-v0.2.20) を下書きで作り、8配布物のサイズとSHA-256が手元とすべて一致したことを確かめてから `--latest=false` で公開した。タグは `eb386d9` を指す。完全版のパッケージは180,122,896 bytes、SHA-256 `7BD07EAB9A389F341663AB6E38DBF001BF8F3080EEBA9CC76A988070B21277B7`。
- 公開後の `verify_release_readback.py --windows-tag win-v0.2.20 --windows-signing-gate beta --json` は99項目で合格。macOSの `macos-latest/appcast.xml` のSHA-256は公開前後で一致し、GitHub Latestは `v0.2.18-771` のまま。更新・ロールバックCIは今回も実行していない。

## このPCへの適用

- 更新前に、設定などの利用者データ（WebView2の保存場所を除く）、素材ライブラリ（86件。DBはSQLiteのバックアップ機能で取得し、整合性ok）、インストール済み0.2.19の一式を `artifacts/release-0.2.20-20261119/` へ退避した（約733MB、Git管理外）。素材ライブラリの `writer.lock`（起動中のアプリが持つ空のロックファイル）は退避の対象から外した。
- 公開先から取得した完全版のパッケージが、フィードのサイズとSHA-256に一致することを確認した。`Update.exe apply --waitPid 54740 --package ...` を起動してから0.2.19（PID 54740）だけを終了した。Update.exeはexit 0で、0.2.20を適用して再起動した。
- 更新後: PID 28936 が `current\HoverPocket.Shell.exe` から起動して応答中。ProductVersionは `0.2.20+eb386d9`、ルートの起動用exeとアンインストール情報も0.2.20。インストールされたDLLは公開パッケージの中身と一致。自動起動の登録はインストール版を指したまま。診断ログは `process.start`、`shell.ready` の2件で、例外はない。
- データは、設定（新しい項目を除く）・付箋・タイマー・天気・素材とDBの全テーブル・カレンダーのログインが更新前と一致した。クリップボード履歴は文字30件・画像20件ともIDと順序が同じで、先頭の文字1件の保存時刻だけが再起動時刻に変わった（前回までと同じ、起動時の読み直し）。
- インストール済み0.2.20の `--verify ai-usage` は187項目で合格。
- 実際の画面: 本番アプリのパネルでAI Usageを開き、7つのカードの中に「Antigravity」が出ることを確かめた。保存値が古かったため、パネルを開いた時点でGemini Peerの読み直しが動き、カードには読み直した時刻（「HH:mm 更新」）、モデル名、5時間・1週間の使用率とリセットまでの時間が出た。値はGemini Peerの応答と一致した（値は記録しない）。自動操作のマウスでは上端からパネルが開かなかったため、2つ目のプロセスの起動（既存のアプリにパネルの表示を頼む、通常の起動の動作）でパネルを開いた。

## 残り

- macOS版のAntigravity欄（範囲外）。
- CIで `--verify ai-usage` を流すこと（レビューの提案、未対応）。
- 公開サイトのプライバシーポリシーの改訂の判断、FFmpegの取得元の恒久対策（前回から継続）。
