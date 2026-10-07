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

- 0.2.13 / Mac build679の配布を準備中。本番アプリと公開フィードは現時点では0.2.12のまま。公開後、署名・公証・両OSの個別フィード・配布物と、設定/素材/チャット/Clipboardの保持を読み戻す。
- 古い文書・RAW・保護/破損ファイルはOSやコーデックにより表示できない場合がある。文書は文字の抽出であり、元の組版や図表の再現は対象外。詳細は[使い方](../../docs/usage/library-previews.md)。
- ローカル検証証拠: Windows/Mac worktreeの artifacts/library-media-20261007/。Macのビルド/署名済みヘルパーはsystem frameworksのみに依存する。追加PGP検証はgpg import段階で失敗し、PGP検証済みとは扱っていない。固定SHA256の検証は両OSで成功。
