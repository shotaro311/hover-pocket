# 2026-10-06 チャットの二重表示を防ぐ処理

## 調査結果と変更

- ユーザーの画像には、1回の入力「付箋を追加して」に対する同じ返答が2件表示されていた。
- Windowsの描画は返信IDごとの更新で、同じIDの通知では要素を増やさない。実接続でGPT-6.1 Sol／推論mediumと同じ入力を試した際は、修正前も返信1件であり、画像の症状の発生条件はまだ特定できていない。
- 同じターン内で同じ返信が別IDで確定すると2件追加される経路を、検査用通知で再現した。旧コードではこの検査が失敗した。今回の修正はこの経路に対する防止処理であり、画像の原因を断定するものではない。
- Windowsは同じターンの確定返信について、本文が完全一致する重複を1件へまとめる。確定済みの返信に遅れて届く文字列を追加せず、履歴の読み込みでも同じターンの重複をまとめる。別のターンで同じ回答が返る場合は残す。
- Macは途中の返信を受信IDごとに更新し、item/completedの本文で確定する。確定した本文の重複と遅延文字列を同じターン内で防ぐ。異なる返答と次のターンの同じ回答は残す。
- [公式のApp Server仕様](https://developers.openai.com/codex/app-server/)では、item/startedのIDはdeltaのitemIdに対応し、item/completedが確定状態となる。今回の実接続でもIDは一致していた。

## 検証

- Windows Debugビルド成功、警告0／エラー0。チャットコア25項目、実パネル40項目が成功。別IDでの確定、確定後の遅延通知、履歴の重複、別ターンの同じ回答を検査した。
- 実WebViewでも別IDで確定した際の返信要素が1件になり、入力中の下書きとカーソルが維持されることを確認。前回のモデル／推論の実クリック検査も成功。
- 修正後の実Codex接続で、日本語の通信確認と、新規会話から「付箋を追加して」を送信。返答と画面の返信要素が1件になり、取得画像も確認した。検査用の履歴・ライブラリを使用し、通常のライブラリへ操作していない。
- Mac Debugビルド、会話37項目とアプリ署名検証が成功。確定通知による本文の更新、重複・遅延通知、異なる本文、別ターン、保存後の履歴復元を検査した。今回、Macの実Codex返信と実マウス操作は再検査していない。
- 今回はチャットを対象に検証し、前回通った全UI検査は再実行していない。

## 起動とreadback

- Windows旧開発版56640をトレイから正常終了し、修正版57816を起動。Responding=true、process.startとshell.readyをreadback。起動先は`artifacts/duplicate-reply-build/HoverPocket.Shell.exe`。
- Mac旧開発版675／67480を正常終了し、開発版676／71460を起動。正しいbundleのプロセス、起動時刻、CFBundleVersion=676、codesign検証成功をreadbackした。
- 元checkoutと既存の未コミット変更を保持。今回も独立worktreeへ未コミットで保存し、公開版・mainは更新していない。Macの画面収録許可待ちは継続。

## 根拠

- `artifacts/duplicate-reply-evidence/core-before.log`: 旧コードで別IDの同じ返信が2件になる検査の失敗。
- `artifacts/duplicate-reply-evidence/core-final.log`、`panel-final.log`、`mac-chat.log`: 修正後の25／40／37項目。
- `artifacts/duplicate-reply-evidence/live-exact.log`: 修正前の同じ入力の実接続では再現せず。
- `artifacts/duplicate-reply-live-final/verify.log`、`inline-chat-live.png`: 修正後の実接続と表示。
- `artifacts/duplicate-reply-evidence/restart.log`、`mac-restart.log`: 両OSの開発アプリ起動確認。
