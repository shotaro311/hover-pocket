# HoverPocket 作業フォルダー整理

実施日: 2026-10-19 JST

ユーザーが画像で示した `C:\Users\shotaro\code\shared` のHoverPocket関連10フォルダーを確認し、本体 `hover-pocket` へ履歴をまとめた。不要フォルダーの整理は依頼範囲として追加確認なしで実施した。

## 結果

- 本体以外の9フォルダーをWindowsのゴミ箱へ移動した。恒久削除は行っていない。
- 対象は `hover-pocket-ai-native-final-integration`、`hover-pocket-an3-integrated-e2e`、`hover-pocket-an3-win-e2e`、`hover-pocket-settings-sandbox-*` の4個、`hover-pocket-voice`、`hover-pocket-windows-stabilization-20260928`。
- 全9個で未コミット変更と通常の未追跡ファイルが0件。ignoredファイルはbin/obj内のビルド生成物のみ。対象パスを使用するプロセスがないことを確認した。
- 独立していたAN3リポジトリは `an3-all-history.bundle` に全参照と統合検証HEADを保存し、2個のHEADを本体へ取り込んだ。
- 全9個のHEADは本体の `refs/heads/codex/archive-20261019/*` に保持した。作業コードのmergeや本体の更新は行っていない。
- 本体全参照の `hover-pocket-all-history.bundle`、SHA-256と元パスを含む `manifest.json`、整理前の本体status、旧worktree登録7個を `artifacts/folder-cleanup-20261019/` に保存した。このローカルバックアップは `.git/info/exclude` で除外した。
- 画像外の `.codex/worktrees`、Temp、本体内の既存worktreeは保持した。

## 検証とreadback

- 両bundleの `git bundle verify` が成功。保存後のSHA-256も一致した。
- 全9個のarchive参照が整理前HEADと一致し、本体bundleにも含まれることを確認した。
- 本体HEAD `48697d12b756a3a2eb5ef46efe67b5a2a813afc6` は変わっていない。
- 記録追記前に、本体の元の変更6ファイルをSHA-256で照合し、全件一致した。その後、今回の記録としてprogressだけを追記した。
- 同じ階層の `hover-pocket*` は本体1個のみ。`git worktree list` は保持対象6個で、`git worktree prune --dry-run --verbose --expire now` の出力は空だった。
- アプリの実装とインストール状態を変更していないため、ビルドとUIテストは実施していない。

## 作業中の修正

- 補助PowerShellの関数名がGitコマンドと衝突したため、今回の補助プロセスだけを停止し、`git.exe` の明示呼び出しへ修正した。フォルダー変更前だった。
- ゴミ箱移動後、Git pruneの診断が標準エラーに出るため、補助スクリプトの件数検査で停止した。旧登録を対象7個に限定してバックアップへ移し、不要登録が残らないことを別途検証した。補助スクリプトは再実行禁止のガード付きで記録として保存した。

## 追加指示によるバックアップ削除

ユーザーから「復元用バックアップは不要。こちらが明示削除指示した際はバックアップ不用」と指示されたため、上記で作成した `artifacts/folder-cleanup-20261019/` 全体をゴミ箱へ移動し、`refs/heads/codex/archive-20261019/*` の保存用参照9個と専用の `.git/info/exclude` 設定を削除した。削除前に各参照が作成時のHEADから変わっていないことを確認し、削除後にフォルダーと参照が残っていないことを確認した。既存ブランチと本体の作業ファイルは保持した。今後、明示的な削除指示時は追加バックアップを作成しない。
