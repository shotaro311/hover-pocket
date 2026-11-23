# Windows 0.2.24 本番配信

実施日: 2026-11-23 JST。実施: Claude（Opus 5.5）。ユーザーの「本番反映もお願い」と、レビュー未完了を伝えたうえでの「このまま配信する」による。

## 内容

- ディスプレイのコントラスト調整（[作業記録](2026-11-23_hover-pocket-windows-display-contrast.md)）。

## レビュー

Codex（gpt-6.2-astra / high、読み取り専用）で2回。2回目で要修正が残り「レビュー未完了」。そのあとClaudeが4件を直した（Codexの確認前）。明るさにも以前からある競合2件と、設定保存の同期書き込みは、判断して残した。詳細は作業記録。

## 配信

- コミット `28c6d5b` をmainへpushし、Verify WindowsとVerify Pocket Contractsが成功。push前に、CIと同じ検査一式（ビルド2種、`node --check`、設定の生成先、契約チェック、`--verify` の capabilities・broker・pocket-surface・timer・ui-model・settings・ailane・voice・updater・controls・ui・voice-e2e-isolation）を手元で流し、すべて合格した。
- 配布物は `publish_release.ps1`（beta区分）で作った。Google OAuthの値はインストール済み0.2.23のDLLのメタデータから読み取りだけで取り出し、同じプロセスの環境変数で渡した（ログに値が含まれないことを確認）。manifestは `embedded-and-verified` / `unsigned`、版は `0.2.24`、チェックサム7件一致。完全版のパッケージの `controls.js` はソースと一致し、DLLに新しい設定が入っていることを確かめた。
- [Windows 0.2.24](https://github.com/shotaro311/hover-pocket/releases/tag/win-v0.2.24) を下書きで作り、8配布物の大きさとSHA-256の一致を確かめてから `--latest=false` で公開した。タグは `28c6d5b`。公開後の `verify_release_readback.py --windows-tag win-v0.2.24 --windows-signing-gate beta --json` は99項目合格。macOSの `macos-latest/appcast.xml` のSHA-256は公開前後で一致、GitHub Latestは `v0.2.19-781` のまま。完全版のパッケージのSHA-256は `EEF103B1F364ED27CEADC1F843EA5A7F3D5A5BB64A2DE0CA838C7FA88B76DAAE`。

## このPCへの適用

- 利用者データとインストール済み0.2.23を `artifacts/release-0.2.24-20261123/` へ退避（666.1MB、素材DBの整合性ok、Git管理外）。
- 録画中でないことを確かめ（ffmpegのプロセスなし）、公開先から取り直した完全版がフィードの大きさ・SHA-256・SHA-1と一致することを確かめた。`Update.exe apply --waitPid 72816 --package ...` を起動してから0.2.23（PID 72816）だけを終了した。Update.exeはexit 0。
- 0.2.24（PID 2332）で起動。インストール先と完全版の539ファイル（dll・js・css・html・exe）を比べ、アプリ本体はすべて一致した。違ったのはVelopackがインストール時に置き換える `HoverPocket.Shell_ExecutionStub.exe` と `Squirrel.exe` の2つ。診断ログは `process.start`、`shell.ready` だけ。
- データ: 素材（原本、DBの全テーブル）、設定（新しい項目を除く）、OAuth、付箋、タイマー、天気は更新前と一致。クリップボードはファイル名と件数（文字30件・画像20件）が同じで、先頭の文字1件の時刻だけが再起動で更新された。
- インストール済み版の `--verify controls` が合格（実機の2台を読み取りで確認）。

## 残り

- 本番アプリのパネルで「◐ コントラスト」を押し、バーで実際にコントラストが変わるかを本人の操作で確かめる（開発版の実機検証では2台とも変更と復元ができた）。
- macOS版は範囲外。
