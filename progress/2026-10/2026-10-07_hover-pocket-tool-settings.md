# 2026-10-07 起点表示の整理・Focus削除・生成モデル選択

## 依頼と実装

- 両OSから「起点表示」の設定、B/C/なしのアイコン、関連する保存設定を削除。上端のホバー・タップ、音声会話中の状態表示は維持する。
- Windowsの標準Today Focusは「削除（データ保持）」と復元に対応。削除状態を保存し、表示・呼び出しを拒否する。表示中の編集を保存できない場合は削除を保留する。タイマー機能全体は維持する。
- 両OSでCodexの利用可能モデルと、そのモデルが対応する推論を選択・保存できる。次の生成要求にモデルと推論を渡す。非対応の選択を拒否し、既定モデルへの自動切替をしない。Windowsの署名・Sandbox・APIキーに関する既存の実行条件は緩和していない。
- 原本のdirty checkoutを保持し、Windowsの既存作業用worktreeとMacの新規専用worktreeで作業。Mac実行はPC Operatorの接続を使用した。

## 検証

- Windows Debugビルド: 警告0、エラー0。設定・UIモデル・Pocket Surfaceと生成／ライフサイクル検証が成功。
- Windows設定画面: 狭い幅520でモデルと推論の保存、利用不可モデル／推論の拒否、Focus表示の削除、削除後の呼び出し拒否、復元・記録保持を確認。画面画像を目視し、横方向にはみ出さないことを確認。
- Windows生成要求: 選択モデル／推論のCLI引数とモデル定義への反映、変更時の要求識別子更新、既存のツール／権限制限が同一であることを検証。
- Mac開発ビルド、Pocket Appのパッケージ／生成／保存／復元検証、チャット、自由サイズ160条件が成功。モデル／推論の保存と要求識別子の検証を追加した。
- 最初のWindowsビルドで自動編集による余分な閉じ括弧が検出され、修正後に成功した。
- Windowsの復旧テストには、以前からチャット入力欄126pxを除外した古いサイズの期待値が残っていた。故障を入れる直前の実寸を独立して取得し、復旧後に同一寸法へ戻るかを比較する検証へ修正した。製品のサイズ処理は変更していない。
- 最初のWindows CIは、追加したSettings用登録位置がVoice静的検査の区切りに重なって失敗した。既存のSettings専用登録ブロックに統合し、検査と実画面の境界検証を再実行した。
- MacでGPT-6.1 Solを指定して2つのツール（標準の管理画面と独自HTML画面）を実生成し、パッケージ検証と各3項目のstaging検証に成功。既定Astraへの自動切替はなく、選択モデルで完了した。根拠は `live-sol-generation.log` と隔離した `PocketToolsLive-D14BCCB3-C79A-42FA-A3F5-ECE178294A0C`。
- 根拠: 各専用worktreeの `artifacts/tool-settings-20261007/`。Windowsの `settings-verify.log`、`settings-focus-verify.log`、`pocket-surface.log`、`ui-model.log`、`windows-settings.png`。Macの `build-tests.log`、`pocket-app.log`、`chat.log`、`panel-layout.log`。

## 反映状況

- [PR #49](https://github.com/shotaro311/hover-pocket/pull/49)をmain `7c862a2`へ統合した。配布ソースは `92094bbb15eeee73cb19c61e1dbedb0ca1e93f93`。
- [Windows 0.2.12](https://github.com/shotaro311/hover-pocket/releases/tag/win-v0.2.12)を公開・導入。本番PID22512が応答し、インストール登録と実アプリが0.2.12で一致。設定・自動起動・素材20件／DB論理hash・Clipboardは一致した。バックアップはWindows側 `artifacts/tool-settings-20261007/startup-backup-*`。
- [Mac 0.2.12 / build678](https://github.com/shotaro311/hover-pocket/releases/tag/v0.2.12-678)を署名・公証して公開。公証ID `6d7cbba4-7c34-40d0-9065-2a75a52f05ed` はAccepted。公開ZIPを再取得して手元の署名済みZIPとの一致を確認し、/Applicationsへ適用。本番PID16728の実行パスと署名、公開版との一致を確認した。
- Macの設定・素材20件／全DBテーブル・原本・チャット履歴は一致。Clipboardは画像20件が不変、テキスト30件のうち同じ本文の1件が起動時に最新へ移し直された。本文とお気に入り、残る29件は不変で、内容の削除はない。最初の厳密照合はID変更により失敗したが、旧IDと新IDの本文一致を独立して確認し、通常の並び替えとして最終照合 `startup-resolved-readback.json` が成功した。Mac側 `startup-backup` に以前のアプリ・設定・全ユーザーデータを保持した。
- 最終Windows／Mac CIと3 OSの契約比較が成功。Mac配布用アプリのツール・チャット・自由サイズ160条件も成功。Windowsは100回の開閉・復旧検証、保存失敗時のFocus削除保留、配布ビルドの設定／ツール／UIモデルが成功した。
- 両OSの公開フィード・資産99項目、MacのSparkle署名、各成果物hashと専用フィードを確認した。最初のWindows側検査はOpenSSLがPATHになく失敗し、既存のGit付属OpenSSLを検査プロセスのPATHに加えて再検査した。アプリや署名の変更はない。
- [更新・復元・再インストールCI](https://github.com/shotaro311/hover-pocket/actions/runs/37608085661)が両OSで成功。署名済みCodex Sandbox MSIの検証は今回配布していないため対象外。
- Windowsの本番生成は従来から実行条件が未充足のため未検証。Macの範囲収録のOS許可待ちは従来の未完了事項として維持する。

最終根拠はWindows側 `final-release-*.log`、`settings-registration-verify.log`、`settings-flush-verify.log`、`shell-corrected.log`、`startup-readback.json`、`public-readback-both-final.json`。Mac側は `live-sol-generation.log`、`release-*.log`、`notarize.log`、`publish.log`、`data-readback.json`、`startup-resolved-readback.json` と `installed-process-id.txt`。

最終CI: [Windows](https://github.com/shotaro311/hover-pocket/actions/runs/37607040501)、[Mac](https://github.com/shotaro311/hover-pocket/actions/runs/37607040488)、[契約比較](https://github.com/shotaro311/hover-pocket/actions/runs/37607040517)。
