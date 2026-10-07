# 2026-10-06 モデル選択が「自動」から変わらない問題

## 原因と変更

- Windowsの実マウス操作で再現。選択肢へmouse downが届くが、その途中のfocusout処理がメニューを閉じ、mouse upとclickが背後の入力欄へ抜けていた。選択処理が呼ばれず、表示も設定も「自動」のままになる。
- `windows/ui/js/chat-choice-menu.js`で、メニュー内のフォーカス移動は閉じず、移動先がまだ確定していない場合は次のイベント処理で確認する。選択、Esc、外側クリック、ウィンドウのフォーカス解除後は従来通り閉じる。
- 前回の選択検査はDOMのclickを直接呼んでいたため、mouse downからmouse upの間に起こる問題を見逃した。モデル／推論の検査を実マウス入力へ置き換え、再表示後の名称と次のturn/start要求への反映も検査する。
- Macの製品処理には今回変更なし。既存のメニュー操作から設定を更新する処理と、設定を作り直した際のモデル／推論の復元、不正な選択の拒否を検査へ追加した。

## 検証とreadback

- Windows Debugビルド成功、警告0・エラー0。修正前の実クリックは失敗し、修正後の会話検査39項目は成功。
- 実マウスでFixture Model／推論: 高を選択し、ホバー収納後の再表示と次の送信要求でfixture-model／highを確認。検査用settings.jsonも別に読み、同じ値を確認した。
- 会話のIME、下書き、返信、停止、履歴、メニュー取消・ホバー収納、Small／Extra Largeのメニュー範囲、サイズ変更も同じ会話検査で成功。前回通った全UI検査は今回再実行していない。
- MacのDebugビルドと会話検査33項目が成功。今回はSwiftUIメニューの実マウス操作を再検査していない。
- Windowsの旧開発アプリ90728をトレイの終了操作で閉じ、修正版56640を起動。`Responding=true`、診断ログの`process.start`と`shell.ready`をreadbackした。起動先は`artifacts/model-choice-build/HoverPocket.Shell.exe`。
- Macは開発版675／PID67480が引き続き起動中。今回、Macアプリの再配布・再起動は行っていない。

## 根拠

- `artifacts/model-choice-evidence/native-before.log`、`native-trace.log`: 修正前の実クリックとイベント順序。
- `artifacts/model-choice-evidence/native-final.log`: 修正後の実クリック、再表示、送信要求と39項目。
- `artifacts/model-choice-evidence/build-final.log`、`restart.log`: Windowsビルドと起動確認。
- `artifacts/model-choice-evidence/mac-chat.log`: Macの選択／保存を含む33項目。

変更は既存の独立worktreeへ未コミットで保持。元checkoutの未完了作業を維持し、公開版・mainは更新していない。Macの画面収録許可待ちは前回から継続。
