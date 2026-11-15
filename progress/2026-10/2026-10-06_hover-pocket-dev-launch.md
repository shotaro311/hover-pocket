# Windows開発アプリの起動

- ユーザーの動作確認依頼により、2026-10-06 13:16:36 JSTに検証済みの開発アプリを通常起動した。
- 実行パス: `C:\Users\shotaro\.codex\worktrees\windows-refactor-20261005\hover-pocket\artifacts\pairing-settings-final-build\HoverPocket.Shell.exe`。
- ProductVersion: `0.2.10+0fbb8ce9cf2f0d1705c324fdf95ce317dcc96839`。PID93500。起動直前にHoverPocketプロセスが0件であることを確認した。
- 起動後の実プロセスパス一致、1プロセス、Responding=trueを確認。診断ログのprocess.startとshell.ready（13:16:37 JST）、例外なしをreadbackした。
- Windows operational preflightはサンドボックス内のCIM権限不足で失敗し、承認経路で再実行して成功。CODEX_HOME未設定は既定パスへのfallbackで解決。snapshotはTempへ保存した。
- 起動は依頼範囲内として追加確認せず実行。公開・インストール更新・自動起動設定変更は行っていない。画面の手操作による機能確認はユーザーがこれから行う。
