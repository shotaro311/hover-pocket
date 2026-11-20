# Windows 0.2.23 本番配信

実施日: 2026-11-20 JST。実施: Claude（Opus 5.5）。ユーザーの「修正できたら本番反映しておいてね」と、Codexの3回目の確認のあとに配信する指示（「Check a 3rd time, then release」）による。

## 内容

- AI Usageへのホバー切り替えで画面が点滅し続ける不具合の修正（[記録](2026-11-20_hover-pocket-ai-usage-hover-flicker.md)）。
- 動画アイコンの範囲録画と、録画中のヘッダーの停止ボタン（[記録](2026-11-20_hover-pocket-region-recording-stop-button.md)）。
- 一括ゴミ箱、「ゴミ箱を空にする」の見直し、この端末の同期をやめる機能（[記録](2026-11-20_hover-pocket-asset-trash.md)）。

## レビュー

Codex（gpt-6.2-astra / high、読み取り専用）で6回。3回目まではユーザーの指示、4回目以降は、本人の環境の原因が同期の共有フォルダだと分かり、同期の解除を足したための追加。6回目の指摘（解除の後始末で、保護ファイルを確かめられない・リンクのとき）の直しは、Codexの確認を受けていない。ハッシュを確かめてからWindowsのごみ箱へ移すまでの数ミリ秒の差し替えは、残る危険として扱う。

## 配信

- コミット `aa6c3f1`（点滅）、`b0d5bc3`（0.2.23本体）、`5087804`（0.2.21・0.2.22の配信記録）をmainへpushし、Verify WindowsとVerify Pocket Contractsが成功。
- 配布物は `publish_release.ps1`（beta区分）で作った。Google OAuthの値はインストール済み0.2.22のDLLのメタデータから読み取りだけで取り出し、同じプロセスの環境変数で渡した（ログに値が含まれないことを確認）。manifestは `embedded-and-verified` / `unsigned`、版は `0.2.23`、チェックサム7件一致。完全版のパッケージに今回の変更（範囲録画の切り替え、同期の解除、点滅の修正、停止ボタン）が入っていることを確かめた。
- [Windows 0.2.23](https://github.com/shotaro311/hover-pocket/releases/tag/win-v0.2.23) を下書きで作り、8配布物の大きさとSHA-256の一致を確かめてから `--latest=false` で公開した。タグは `5087804`。公開後の `verify_release_readback.py --windows-tag win-v0.2.23 --windows-signing-gate beta --json` は99項目合格。macOSの `macos-latest/appcast.xml` のSHA-256は公開前後で一致、GitHub Latestは `v0.2.19-781` のまま。完全版のパッケージのSHA-256は `212A8E5C162A993857ADF9F5DADA5CE7642E35F02B56AFA76D5F626C6029976F`。

## このPCへの適用

- 利用者データとインストール済み0.2.22を `artifacts/release-0.2.23-20261120/` へ退避（790.6MB、素材DBの整合性ok、Git管理外）。
- 録画中でないことを確かめ（直近の録画の一時ファイルなし）、公開先から取り直した完全版がフィードの大きさ・SHA-256・SHA-1と一致することを確かめた。`Update.exe apply --waitPid 59644 --package ...` を起動してから0.2.22（PID 59644）だけを終了した。Update.exeはexit 0。
- 0.2.23（PID 69840）で起動。インストール先の534ファイル（dll・js・css・html）は公開物と一致。診断ログは `process.start`、`shell.ready` だけ。
- データ: 素材（114件、原本、DB）、付箋、タイマー、天気は更新前と一致。設定は「最後に開いたツール」だけが変わった（パネルの操作による）。クリップボードはファイル数・名前が同じで、時刻だけが再起動で更新。
- インストール済み版の `--verify ai-usage` 229項目合格。

## 残り

- 同期の解除: 本人が本番の設定から解除した（2026-11-20）。ライブラリを読み取りだけで確かめ、同期の設定・履歴は空、`sync-configured` は削除済み、素材114件（ゴミ箱6件）はそのまま、整合性ok。解除後の「ゴミ箱を空にする」は本人の操作で確かめる（6件はWindowsのごみ箱へ移る）。
- 本番で実際に範囲を選んで録画し、保存された動画と、ヘッダーの停止ボタンを手で確かめること。
- macOS版の素材画面は従来のまま。macOS版の「ゴミ箱を空にする」に同じ同期の問題があるかは見ていない。
