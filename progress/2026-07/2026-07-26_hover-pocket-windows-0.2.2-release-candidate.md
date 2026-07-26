# HoverPocket Windows 0.2.2 Release Candidate Verification

## 結果

- 対象branch: `codex/windows-0.2.2-release`
- 開始SHA: `4873e1947f275bd3d2b4e4f81cda4bf24aeedcf4`
- release gate追加commit: `df4c6529ed46d2a621fa85b50ff00642b49b9829`
- push: 通常push済み。force / rebase / mergeなし。
- GitHub Release作成・asset upload: 未実施。

## Branch安全確認

- 開始時は`main`、worktreeはcleanだった。
- fetch後、remote branchをtrackingする新規ローカルbranchへswitchした。
- switch後のlocal / origin / GitHub SHAは開始SHAと一致した。
- ローカル`main`と`codex/windows-unpublished-recovery-20260726`は同じ既存SHAのまま動かしていない。

## Buildと静的検査

- Debug build: 初回exit 1。正本workspaceのDebug `HoverPocket.Shell.exe`が出力をlockしていたため、該当する1 processだけを終了した。
- Debug build再実行: exit 0、warnings 0、errors 0。
- Release build: exit 0、warnings 0、errors 0。
- `git diff --check`: exit 0。
- 全12 JavaScriptの`node --check`: exit 0、failure 0。

## Verifier

- Debug: `shell`、`display`、`ui-model`、`settings`、`sticky`、`clipboard`、`calc`、`timer`、`calendar`、`controls`、`updater`、`ui`がすべてexit 0。
- Release: `settings`、`calendar`、`controls`、`updater`、`ui`、`shell`がすべてexit 0。
- 実アカウントE2E用に`--verify calendar-live`を追加した。既存Credential Manager資格情報で当月をread-only取得し、予定内容を出さず件数だけを記録する。作成・更新・削除APIは呼ばない。

## Release候補

- `%APPDATA%\HoverPocket\oauth.json`はprocess内だけで読み、値を出さずに2つのOAuth環境変数へ設定した。処理終了時に元のprocess環境へ復元した。
- `windows\script\publish_release.ps1`: exit 0。
- `--verify release-config`: exit 0。version `0.2.2`、configuration `Release`、OAuth metadata matched、Windows channel `win`を確認した。
- 必須成果物:
  - `HoverPocketWin-win-Setup.exe`: 90,372,410 bytes
  - `HoverPocketWin-win-Portable.zip`: 85,909,811 bytes
  - `HoverPocketWin-0.2.2-full.nupkg`: 85,910,842 bytes
  - `releases.win.json`: 262 bytes
  - `release-manifest.win.json`: 278 bytes
  - `SHA256SUMS-win.txt`: 631 bytes
- feedはasset 1件、version `0.2.2`。
- manifestはversion `0.2.2`、channel `win`、feed `releases.win.json`、OAuth metadata `embedded-and-verified`、Authenticode `unsigned`。
- checksum 7件はすべて実ファイルと一致した。
- SetupとPortable内の実行ファイルはともに`NotSigned`で、manifestの未署名方針と一致した。

## Calendar Release候補E2E

- Portableから一時展開したRelease候補を独立processで2回起動した。
- 1回目: exit 0、Calendar 6件、event 91件。
- 2回目: exit 0、Calendar 6件、event 91件。
- 2回目も新規processでrefresh / readに成功した。予定内容、token、credential内容は出力していない。

## 0.2.1 baseline

- インストール済み実行ファイルは2件ともversion `0.2.1+817b7c314751a4654018e01c22ca38b14ca65a61`のまま。
- uninstall entryは1件、version `0.2.1`のまま。
- Setup実行、更新、削除、上書きは行っていない。

## 残るblocker

- `docs/requirement/requirements.md`には現行配布の署名必須記述があり、`windows/README.md`とmanifestの「0.2.xは未署名、1.0で署名必須」方針と不一致。正式公開前に正本方針の確定が必要。
- 0.2.1→0.2.2のVelopack update apply / restartは、0.2.2公開feedがまだ存在しないため未実施。インストール済み0.2.1を保持している。
- Release候補のTemp展開物は、安全確認済みパスへの再帰削除が端末ポリシーに実行前拒否されたため保持した。成果物やインストール状態への影響はない。
