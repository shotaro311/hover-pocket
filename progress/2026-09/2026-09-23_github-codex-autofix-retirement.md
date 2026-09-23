# GitHub Codex Autofix の廃止

2026-09-23、ユーザーの指示で GitHub PR の定期自動修正を廃止した。

- Mac の Codex Automation `github-codex-autofix` と `github-codex-autofix-c0183541a270` を削除。両定義の不在を確認した。
- GitHub Actions `Codex PR Router` を無効化し、`.github/workflows/codex-pr-router.yml` を削除して main `baca5f6` へ push。GitHub Contents API は 404、workflow API は `deleted` を返した。
- 専用ラベル7件を削除。ラベル一覧と PR #39 で不在を確認した。
- Mac の補助プラグイン、repo 設定、Obsidian Wiki 手順をゴミ箱へ移し、Codex の専用 trust 設定を削除。設定ファイルの TOML 解析が成功した。
- Wiki 手順の削除は Obsidian Vault main `9a66bb1` へ同期し、`dirty_after: false` と push 成功を確認した。
- Windows 側の Automation `github-codex-autofix-windows` も削除結果と定義ディレクトリ不在を確認。専用プラグイン・repo 設定・同梱メタデータをゴミ箱へ移し、Codex の専用 trust 設定を削除。TOML 解析と対象パス不在、残る Automation に参照がないことを Windows 側で確認した。
- Windows の Codex 保存済みプロジェクト一覧には、削除済みフォルダを指す表示項目が残る。実行設定ではなく、利用可能な削除ツールもないため未削除。

Mac の既存 `progress/progress.md`、`progress/2026-09/`、`progress/evidence/`、`output/` にあった変更・未追跡ファイルは保持した。
