# 2026-10-04 Windows 0.2.9 本番配信

ユーザーがlocal.15の改善を確認し、「いったんこれで本番反映して」と依頼。確認済みのWindows機能とちらつき修正を0.2.9へまとめ、Windows専用のwin-v0.2.9とwin channelへ配信する。既存の0.2.x公開ベータ・未署名方針を維持する。

## 配信前の確認

- 作業ツリーはDownloads/hover-pocket-windows-liquid-20261002。元のdirty checkoutは保持。
- 公開中Windowsはwin-v0.2.8。GitHub LatestはmacOS v0.1.0-644で、macos-latest/appcast.xmlの内容を配信前に保存した。
- 通常起動中は確認済みlocal.15（PID33248）。自動起動はLocalAppData/HoverPocketWin/current/HoverPocket.Shell.exeを指すが、インストール済みは0.2.9-local.2。公開成果物の検証後にここを更新する。
- ユーザーによる操作確認に加え、local.15は初回を含む6回の拡大録画、縮小・途中取消、素材UI回帰、Release/Debug、JS17ファイルで検証済み。詳細は[ちらつき修正記録](2026-10-04_hover-pocket-claude-opening.md)。

## 成果物と公開

- 確認済みのlocal.14/local.15と配布準備を`84aaf8a`へコミット。`win-v0.2.9`と配布バイナリのsource revisionはこのコミット。後続の`5eb30e0`・`8d843e4`は検証専用2ファイルだけの修正で、製品の表示処理は同一。
- `publish_release.ps1 -WindowsSigningGate beta`で0.2.9を作成。通常のRelease/未署名ベータ、win channel。local.15にはOAuth metadataが入っていなかったため、インストール済みlocal.2の値をメモリ上で引き継いだ。公開用バイナリで値の一致を確認し、値はログやコミットに保存していない。
- 配布先: [Windows 0.2.9](https://github.com/shotaro311/hover-pocket/releases/tag/win-v0.2.9)。8 assets、full package SHA256は`631dc937aa1cd4d769fe729f7283477b5c157fef13c33aafa905dd5dcc0f5ec5`。Setup・Portable・更新パッケージ・feed・manifest・checksumsを公開した。
- [PR #42](https://github.com/shotaro311/hover-pocket/pull/42)を`3965a84`でmainへ統合。公開日時は2026-10-04 18:40:05 JST。`--latest=false`でmacOSのLatestを維持した。

## 検証

- パッケージ内DLLと公開用DLLの一致、7個のchecksum対象、GitHubへアップロードした8 assetsのdigestが一致。
- 配布用バイナリで素材UIを検証。H.264 fixtureあり・なしの両方が成功。プレビュー・PDF・画像編集・元ファイル保持・ドラッグ削除と取り消し・空フォルダ取り込みなどを確認。
- 最初のWindows CIは、ファイル取り込み後に空フォルダ作成を待たない検査と、OS側のアニメーション無効を考慮しない検査で失敗。後者の診断は`before=0, after=1, visible_before=False, system_animation=False, reduce_motion=False`。検査を実際のOS設定に合わせ、60/120 Hzのspring位置・速度維持の検査も追加した。
- 修正後の[Windows CI](https://github.com/shotaro311/hover-pocket/actions/runs/37192608221)と[3 OSの契約比較](https://github.com/shotaro311/hover-pocket/actions/runs/37192608225)が成功。ローカルの100回開閉は実施していない。
- `verify_release_readback.py --windows-tag win-v0.2.9 --windows-signing-gate beta`が成功。公開された8ファイルをダウンロードし、feed・SHA1/SHA256・サイズを検証。macOS ZIP・appcast・Sparkle署名も独立して検証した。
- [隔離環境の更新・ロールバックCI](https://github.com/shotaro311/hover-pocket/actions/runs/37192907557)が成功。0.2.8→0.2.9、0.2.8へ戻す、再更新、アンインストール、再インストールとユーザーデータ保持を確認。receiptは`status=passed`, `userDataPreserved=true`, `signingMode=explicit-beta`。
- macOS appcastの配信前後SHA256は同一（`8895a8f8df93be5cdd62aa1e841e027a5472aa6ba21c8c5395137ca2a0696ebc`）、GitHub Latestは`v0.1.0-644`のまま。

## この端末の適用とreadback

- local.15は18:23:02 JSTに`tray.quit`→`application.exit`→`process.exit`が記録され、適用直前は本体プロセスなし。稼働中のキャプチャ・未完了import/purgeがないことを再確認した。
- 設定・撮影設定・SQLite backup・旧インストール先をバックアップ後、公開先から取得したfull packageを既存Update.exeで適用。2026-10-04 18:40:45 JSTに`%LOCALAPPDATA%/HoverPocketWin/current/HoverPocket.Shell.exe`から起動（PID26176）。
- インストール済みProductVersionは`0.2.9+84aaf8a29e62847e42f6eb7d1ca0bf48cc93bd1b`、Windowsのアンインストール情報は`0.2.9`。自動起動は同じ正規インストール先を維持。
- 設定・撮影設定のハッシュ不変。素材7件、pending imports/purges 0、schema 1、quick_check ok。DB全体の論理内容SHA256も前後一致。`process.start`と` shell.ready`を記録し、起動時例外なし。
- 作業元checkoutの既存dirty変更を保持。実行・検証・バックアップの根拠はDownloads作業ツリー内の`artifacts/release-0.2.9-20261004/`に保持した。
