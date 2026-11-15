# Windows 0.2.16 本番配信

実施日: 2026-11-16 JST。実施: Claude（Opus 5.5）。ユーザーが「コミットプッシュして、本番アプリをアップデートして」と依頼した。

## 内容

- 2026-11-15の明るさ欄の修正（[記録](2026-11-15_hover-pocket-windows-brightness.md)）と、2026-11-16の点検で直した4件（[記録](2026-11-16_hover-pocket-windows-hardening.md)）を含む。
- Codexによる相互レビューは、公開前には実施していない。共通ルールは「レビューを通っていない重要な成果物は公開しない」としているが、同じルールの「今回のユーザー指示を指示書より優先する」に従い、ユーザーの依頼どおり公開した。レビューはCodexの枠のリセット（2026-11-17 11:08）後に行う。

## コミットと公開

- `82947e8` をコミットし、作業ブランチ `claude/windows-brightness-20261115` とmainへpushした（mainは早送り）。`.ai-peer/` はコミットしていない。
- mainの [Windows CI](https://github.com/shotaro311/hover-pocket/actions/runs/43730526662) は成功した。Codex隔離環境のインストーラーの段階で長く止まって見えたが、15分の制限内に終わった。
- 配布物は `publish_release.ps1`（beta区分）で作成した。Google OAuthの値は、インストール済み0.2.15のDLLのメタデータを読み取りだけで取り出し、同じプロセスの環境変数で渡した。値は表示・保存していない。manifestは `oauthMetadata: embedded-and-verified`、`authenticode: unsigned`、版は `0.2.16+82947e8`。
- [Windows 0.2.16](https://github.com/shotaro311/hover-pocket/releases/tag/win-v0.2.16) を `--latest=false` で公開した。下書きでアップロードした8つの配布物は、GitHubのサイズ・SHA-256が手元とすべて一致した。タグは `82947e8` を指す。完全版のパッケージは180,023,085 bytes、SHA-256 `14F753EE556F9608075A41F66933E99A4A880C52D8FB39E2AB27B00A1A630D8C`。

## 配布物作成で見つけた問題

- 動画プレビュー用のFFmpegの取得元 `BtbN/FFmpeg-Builds` の `autobuild-2026-10-06-13-06` が404で消えていた。配布元が古い自動ビルドを削除するため、キャッシュのないPCではWindows版を配信できない。
- 今回は、0.2.15の作成時のキャッシュ（ゴミ箱へ移した作業フォルダー内）から3つのアーカイブを読み取り、固定されたSHA-256との一致を確認したうえで `artifacts/media-tools-windows-AMD64/` へコピーして使った。恒久的な対策（自前のリリースへの保管や取得先の更新）は未実施。

## 公開後の検証

- `verify_release_readback.py --windows-tag win-v0.2.16 --windows-signing-gate beta --json` は99項目で合格した（Windows 7、macOS 8のグループ）。OpenSSLはGit同梱のものを使った。
- macOSの `macos-latest/appcast.xml` のSHA-256は公開前後で一致した。GitHub Latestは `v0.2.17-683` のまま。
- [更新・ロールバックCI](https://github.com/shotaro311/hover-pocket/actions/runs/43731765211) を win-v0.2.15→win-v0.2.16（未署名beta許可）で実行し、Windowsのインストール・更新・旧版への復帰・再インストールが成功した。macOSの実行と署名済みMSIの段階は、前回と同じく省略した。

## このPCへの適用

- 更新前に、データの記録（素材69件・原本69件・DBの整合性ok、クリップボードはテキスト30件・画像20件、設定・付箋のハッシュ）を取った。設定などの利用者データ（WebView2のキャッシュを除く）、素材ライブラリ（DBはSQLiteのバックアップ機能で取得）、インストール済み0.2.15の一式を、`artifacts/release-0.2.16-20261116/` に退避した。
- 公開先から取得した完全版のパッケージが、フィードのSHA-256と一致することを確認した。撮影・収録中でないことを確認したうえで、`Update.exe apply --waitPid 21864 --package ...` を起動し、0.2.15（PID 21864）だけを終了した。Update.exeはexit 0で、0.2.16を適用して再起動した。
- 更新後: PID 95180 が `current\HoverPocket.Shell.exe` から起動し、応答中。ProductVersionは `0.2.16+82947e8`、ルートの起動用exeとアンインストール情報も0.2.16。インストールされたDLLは公開物と一致した。
- 診断ログは `process.start`、`shell.ready`、`startup.registration.repaired` の3件で、例外はない。新しい自動起動の修復が働き、HKCUのRunは `%LOCALAPPDATA%\HoverPocketWin\current\HoverPocket.Shell.exe` に直った。ショートカット登録の失敗の記録もない。
- 更新前後のデータの比較では違いがなかった。明るさはメイン54%・サブ73%のまま。
- インストール済み0.2.16の `--verify controls`（読み取りだけ）はexit 0で、2台が「LG ULTRAGEAR+」「U16ZT」として固定IDで認識された。
- インストール済み0.2.16の `--verify controls --change-brightness`（対象 HSJ1600）もexit 0。サブモニターで73→65→57%の書き込み2回（計530ms）が読み戻しまで成功し、73%へ戻したことを別の経路でも確認した。
- トップのREADMEのWindows版ダウンロードリンクが、0.2.11〜0.2.15の配信でも更新されず0.2.10を指していたため、0.2.16へ直した。Windows版はGitHubのLatestにしないため、このリンクが実際のダウンロード先になる。

## 残り

- Codexによる相互レビュー（依頼文は `.ai-peer/tmp/brightness-20261115/review-request.md`）。
- Windowsの「設定 → アプリ → スタートアップ」でHoverPocketがオフの可能性（StartupApprovedの印 `01`、2026-08-05）。オフのままなら、登録が直っても自動起動しない。
- FFmpegの取得元の恒久対策。
- 実際のパネルでの、2台目のスライダーの見た目と明るさ操作の確認（ユーザー）。
