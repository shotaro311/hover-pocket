# Windows 0.2.10 本番配信

ユーザーがスクショ通知と素材ライブラリの修正後に、コミット・プッシュ・本番アプリへの更新配信を依頼。

- 検証済み0.2.10-local.9のソースを専用worktreeへ切り出し、並行中の音声機能の変更と既存dirty checkoutを保持した。
- 素材の複数選択、プレビュー/インライン編集、名前変更、一覧の操作バー/右クリック/お気に入り、Deleteでのごみ箱移動、クリップボード読み込み改善、撮影画面での装飾とドラッグ可能な画像付き通知を含む。
- local.9は撮影/収録と素材UI全体がexit 0、JS45項目、実PNGドロップと原本保持、通知タイマー/設定を確認済み。配布版は0.2.10へ番号だけを変更する。
- Windowsの従来の0.2.x公開ベータ方針で配布する。Windows専用win-v0.2.10・win feedを使用し、macOS Latest/appcastを維持する。
- 配布用検証、GitHub公開、本番アプリ更新と保存データのreadbackを完了した。

- 専用worktreeの保存コア93項目が通過。Windowsのcore.autocrlfで共有fixtureのTXTが35→36 bytesに変わり、復元検査が正しく拒否したため、.gitattributesでハッシュ照合対象の原本fixtureを-textとし、Gitにある正確なバイトを保持するよう修正した。製品の原本検査は変更していない。

## コミットと配信

- 修正を`eba3774e2ffb872080d12dbcc3d284ca65743f69`へコミットし、`codex/windows-library-0.2.10`へプッシュ。[PR #43](https://github.com/shotaro311/hover-pocket/pull/43)を`97921493e938cd4a2971475305e062cb57405f0a`でmainへ統合した。
- [Windows 0.2.10](https://github.com/shotaro311/hover-pocket/releases/tag/win-v0.2.10)を2026-10-04 22:44:52 JSTに公開。win-v0.2.10のtarget/source revisionは`eba3774`。Windows専用win channel、従来どおりAuthenticode未署名の公開ベータ。
- インストール済みのOAuthメタデータをメモリ上で引き継ぎ、公開用DLLで一致を検証。値はログやコミットへ記録していない。
- 配布版の実装ソース225ファイルは検証済みlocal.9と一致。バージョンだけ0.2.10へ変更。7個のchecksum対象、Portable/full package内DLLとpublish DLL、アップロード8 assetsのGitHub SHA256 digest/sizeが一致。
- full packageは89,107,293 bytes、SHA256 `b6423c8d3932cd0cc8283037397176b80afbb24b6a8f40c669b1186eeec1f931`。

## 公開後の検証

- [Windows CI](https://github.com/shotaro311/hover-pocket/actions/runs/37206431976)が成功。Release/Debug、既存の契約・各機能・描画UI検査を通過。
- `verify_release_readback.py --windows-tag win-v0.2.10 --windows-signing-gate beta --json`は99検査でpassed。Windows全assetを再取得してfeed/SHA1/SHA256/sizeを検証し、macOS ZIPとSparkle署名も別経路で検証。
- 最初のreadbackはPATH上にOpenSSLがなくmacOS署名検証だけで停止。既存Git同梱のOpenSSLを当該プロセスのPATHへ追加して再実行し通過した。元の失敗結果も保持。
- macOS appcastの公開前後ハッシュは一致。GitHub Latestは`v0.1.0-644`のまま。
- [隔離環境の更新・ロールバックCI](https://github.com/shotaro311/hover-pocket/actions/runs/37206746300)が成功。0.2.9→0.2.10、旧版へ復帰、再更新、アンインストール/再インストールとユーザーデータ保持を確認。macOS実行と署名済みMSI実行のgateはスキップした。

## このPCへの適用

- 公開先から取得したfull packageが検証済みパッケージと一致することを確認。並行検証プロセスが終了し、撮影・取り込み待ちがないことを再確認した。
- 設定/撮影設定、SQLite backup、クリップボード、旧インストール一式を退避し、既存Update.exeで適用した。
- 22:45:38 JST、`%LOCALAPPDATA%/HoverPocketWin/current/HoverPocket.Shell.exe`からPID80956で通常起動。ProductVersionは`0.2.10+eba3774e2ffb872080d12dbcc3d284ca65743f69`、アンインストール情報は0.2.10。インストール済みDLLと公開用DLLのSHA256一致、shell.ready、応答、起動時例外0件を確認した。
- 設定2ファイルのハッシュ、素材13件とDB全内容の論理ハッシュ、クリップボード文字30件/画像20件の内容と画像バイト、自動起動先を保持。pending imports/purges 0、schema 1、quick_check ok。
- 証拠とバックアップはDownloads作業ツリーの`artifacts/release-0.2.10-20261004/`へ保持。`published-readback.json`、`startup-readback.json`、`installed-final.json`、`source-equivalence.json`、`draft-upload-readback.json`、各CIログを含む。元のdirty checkoutと並行中の音声機能は保持した。
