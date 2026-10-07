# 2026-10-07 ライブラリの自動保存・プレビュー・ホバー収納

## 変更

- 両OSの設定 → ライブラリに、コピーした画像の自動保存を追加。初期状態はオフ。オン以降の変更通知だけを取り込み、同一内容・ゴミ箱内の重複を避け、オフ後も素材を保持する。Windowsのプライベートモードに従い、Clipboardを非表示にした場合は画像監視のためにテキスト履歴を再開しない。
- 拡張子のプレビュー判定を共有JSONへ集約。保存済みのKindと同期/バックアップv1契約を維持し、旧HEICも画像として表示する。本文抜粋・全文、PDFページ、WebP/HEIC/AVIF、Office/OpenDocument/EPUBの文字表示を追加。HTMLは文字として表示する。
- 両OSへ固定SHA256のFFmpegと対応ソース・ライセンスを同梱し、OSが再生できない動画/音声の互換コピーとポスターを生成。原本は変更しない。入力・時間・出力・キャッシュに上限を設け、ネットワークとプレイリスト入力を禁止する。
- ライブラリのホバー収納を修正。Windowsはサイズ変更の補助ウィンドウを保持理由から除外。Macは検索入力にフォーカスが残っていても収納し、ダイアログ保持とプレビュー終了の競合を防ぐ。保存・編集・ドラッグ中の保持は維持する。

## 検証

- Windows: Core 120 / Sync 102 / 音声基盤42項目、全UI ui-full-3が成功。Releaseビルドは警告/エラー0。release-media-final/verify.logで44ファイル、64KiB以下のサムネイル、原本hash、設定の初期オフ/オン/重複/プライベート/オフ後保持、実ブラウザ19種のdecode/seek、本文の安全な表示とホバー収納が成功。
- Mac: mac-media-2.logで201項目、mac-ui-6.logで97項目が成功。44ファイル、実WebKit19種のdecode/seek、本文・ダイアログ・画像編集・PDF2ページ・動画シーク、20回のアニメーション開閉と検索入力後の収納を検証した。
- Macの全体回帰検査は既存の画面収録権限でlibrary-voiceがscreen_capture_permission_requiredとなった。保存/UI/再開/同期/接続/チャットは通過。残りのpersonal-tools42、voice-only23、capabilities、broker、panel-layout128＋160、clipboard、timer、panel-soak100回が成功。diff checkとcodesign strictも成功。OSの画面収録許可はこの変更では操作していない。
- 独立worktreeを使用し、元チェックアウトの既存変更を保持。MacはCodexのPC Operator接続から実行し、SSHは使用していない。

## 配布と残る確認

- [PR #50](https://github.com/shotaro311/hover-pocket/pull/50)をmainへ統合（e713195141743bcfddd67fd0cbab0d9562ea9867）。[Windows 0.2.13](https://github.com/shotaro311/hover-pocket/releases/tag/win-v0.2.13)と[Mac 0.2.13 / build679](https://github.com/shotaro311/hover-pocket/releases/tag/v0.2.13-679)を公開し、各OS専用のフィードを更新した。Windowsはbeta署名条件を維持。Windows側のソース変更はe980436以降なく、配布DLLの版は0.2.13+e980436191753320fb9168027cd0e45eba7dcf57。
- Windowsは公開nupkgとローカル検証済みnupkgのSHA256一致を確認して更新。PID43020で応答し、公開DLL・FFmpeg・DLL群との一致、設定・自動起動・素材22件・原本・DB内容・チャット・Clipboard本文と画像の保持を確認した。履歴ファイルの並び等は通常の起動処理で変わり、内容hashは一致した。証拠はstartup-readback.json、更新前のアプリとデータはstartup-backup-*へ保持。
- Macは公開ZIPと公証済みZIPのSHA256一致を確認し、署名・stapler・Gatekeeperを検査して/Applicationsへ適用。PID68202で起動。公開本体とFFmpeg、設定・素材22件・原本・DB・チャットが一致。Clipboardの画像20件は一致、テキストは既存1件の最新への移動を確認し、本文とお気に入りを保持した。更新前のアプリ・データはstartup-backupとinstalled-old-moved.appに保持。証拠はinstall-receipt.jsonとstartup-resolved-readback.json。
- 公開フィード・配布物99項目が成功（public-readback.json）。[独立readback CI](https://github.com/shotaro311/hover-pocket/actions/runs/37621152890)で両OSの配布物、WindowsパッケージID、Macの署名・公証・Gatekeeperが成功。[更新・復元CI](https://github.com/shotaro311/hover-pocket/actions/runs/37621148225)も両OSで成功。正式署名向けWindows Authenticodeと未配布のCodex sandbox MSIは、今回のbeta配布条件に従ってスキップした。
- 古い文書・RAW・保護/破損ファイルはOSやコーデックにより表示できない場合がある。文書は文字の抽出であり、元の組版や図表の再現は対象外。詳細は[使い方](../../docs/usage/library-previews.md)。
- ローカル検証証拠: Windows/Mac worktreeの artifacts/library-media-20261007/。Macのビルド/署名済みヘルパーはsystem frameworksのみに依存する。追加PGP検証はgpg import段階で失敗し、PGP検証済みとは扱っていない。固定SHA256の検証は両OSで成功。

## 配布候補での追加検査

- 最終ソース02e390eのWindows/Mac CIが成功（37619452579 / 37619452586）。Windowsは配布パッケージのメディア検査とnative-interaction-finalでフォルダ移動・Undo・復元も成功。途中のWindowsネイティブドラッグ検査は1回タイムアウトし、同じソースでCI再実行と実機の対象検査が通過した。
- MacのFFmpegをアプリと同じ最低OS14で再ビルド。LC_BUILD_VERSIONのminos14.0を確認。旧ビルドが実行ホストの27を要求した問題を修正し、設定変更時にはcleanする。実macOS14での起動は未検証。最終のminimum-os-libraryは201項目、minimum-os-ui-retryは97項目が成功。先行UI検査の1回はプレビュー操作途中でタイムアウトし、同じ配布候補の再実行でPDF・動画・全画面・20回のホバー開閉まで成功した。
- 最終公証はAccepted（8f6a904c-cc6e-489a-ab56-9ec419c5ebfb）。当初はMacOSフォルダへのライセンス類の配置で公証が拒否され、実行ファイルだけをMacOSへ、資料をResourcesへ移して解決した。検証コードのSwift並行処理エラーとテスト素材/JavaScript戻り値も修正した。
