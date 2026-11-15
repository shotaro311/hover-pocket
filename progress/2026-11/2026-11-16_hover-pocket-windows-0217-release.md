# Windows 0.2.17 本番配信

実施日: 2026-11-16 JST。実施: Claude（Opus 5.5）。ユーザーの「確認して配信」の指示による。

## 内容

- 0.2.16のレビュー（別のClaude、読み取り専用）で見つかった重大1件・要修正4件と、2回目の確認で見つかった要修正1件の修正。詳細は[レビューと修正の記録](2026-11-16_hover-pocket-windows-review.md)。
- 配信前に、同じレビュー役が最後の修正を確認し、「0.2.17は出してよい。重大・要修正は残っていない」と判断した（コードを読んだ範囲での判断。ビルドと検証はClaudeの手元で合格済み）。

## コミットと公開

- `5d5a3f2` をmainへpushした。READMEのWindows版ダウンロードは0.2.17を指す（公開までの数分間はリンク切れだった）。
- mainの [Windows CI](https://github.com/shotaro311/hover-pocket/actions/runs/43739442695) は成功した。
- 配布物は `publish_release.ps1`（beta区分）で作成した。OAuthの値は、インストール済み0.2.16のメタデータから、0.2.16と同じ方法で引き継いだ。FFmpegは、照合済みのキャッシュ（`artifacts/media-tools-windows-AMD64/`）を使った。版は `0.2.17+5d5a3f2`、manifestは `embedded-and-verified` / `unsigned`、チェックサムは7件とも一致した。
- [Windows 0.2.17](https://github.com/shotaro311/hover-pocket/releases/tag/win-v0.2.17) を `--latest=false` で公開した。下書きでアップロードした8配布物のサイズとSHA-256は、手元とすべて一致した。完全版のパッケージは180,026,455 bytes、SHA-256 `06B31B56B9B15FBFDB7093E9AF50C4D1E34F69F3046DBDD2FFADFE35C3611E3F`。

## 公開後の検証

- `verify_release_readback.py --windows-tag win-v0.2.17 --windows-signing-gate beta` は合格した（Windowsの全配布物を取り直して照合し、macOS側も別に検証）。
- macOSのappcastは公開前後で一致した。GitHub Latestは `v0.2.17-683` のまま。
- [更新・ロールバックCI](https://github.com/shotaro311/hover-pocket/actions/runs/43740269833)（win-v0.2.16→win-v0.2.17、未署名beta許可）で、Windowsのインストール・更新・旧版への復帰・再インストールが成功した。macOSの実行と署名済みMSIの段階は省略した（前回と同じ）。

## このPCへの適用

- 更新前にデータを記録し、0.2.16一式・素材・設定などを `artifacts/release-0.2.17-20261116/` へ退避した。公開先から取得したパッケージは、フィードのSHA-256と一致した。
- `Update.exe apply --waitPid 95180 --package ...` を起動してから0.2.16（PID 95180）だけを終了した。Update.exeはexit 0。
- 更新後: PID 38092 が `current` から起動して応答中。ProductVersionは `0.2.17+5d5a3f2`、ルートの起動用exeとアンインストール情報も0.2.17。インストールされたDLLは公開物と一致した。
- 診断ログは `process.start`、`shell.ready` の2件で、例外はない。自動起動の登録は正しいままで、修復は不要だった。
- データは更新前後で一致した。
- インストール済み0.2.17の `--verify controls --change-brightness`（対象 HSJ1600）はexit 0。サブで書き込み2回と元の値への復帰を読み戻しまで確認し、差し替え時の待ちのテストも32msで合格した。
- 試験開始時の明るさは、メイン57%・サブ62%だった（11月15日夜の54%・73%から変わっていた）。メインへの実際の書き込みはしておらず、サブは試験開始時の62%へ戻した。ユーザー自身の操作と判断した。

## 残り

- 別の会社のAI（Codex）によるレビューは行っていない。
- FFmpegの取得元の恒久対策（照合済みのアーカイブは、Git管理外の `artifacts/media-tools-windows-AMD64/` とゴミ箱の中だけにある）。
- Windowsの「設定 → アプリ → スタートアップ」でHoverPocketがオフの可能性。
- 実機での、省電力から戻った直後の再検出の確認。
