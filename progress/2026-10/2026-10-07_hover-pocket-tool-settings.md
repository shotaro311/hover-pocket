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

0.2.12 / Mac build678の本番反映を準備中。最終ソースでの追加検証・公開・導入後のreadbackはこの記録へ追記する。Windowsの本番生成は従来から実行条件が未充足のため未検証。Macの範囲収録のOS許可待ちは従来の未完了事項として維持する。
