---
project_slug: hover-menu-preview
date: 2026-07-29
platform: windows
status: completed
---

# Windows Start Menu Shortcut Repair

## 依頼

スタートメニューにあるHoverPocketのショートカットを、インストール済み最新版へ変更する。

## 変更前

- `HoverPocket.lnk`
  - target: `C:\Users\shotaro\AppData\Local\HoverPocketWin\current\HoverPocket.Shell.exe`
  - ProductVersion: `0.2.3+7bfbee4ed54ed989b1ad470fd4420b0d8efeda13`
- `HoverPocket.Shell.lnk`
  - target: `C:\Users\shotaro\code\shared\hover-pocket\windows\src\HoverPocket.Shell\bin\Debug\net10.0-windows\HoverPocket.Shell.exe`
  - ProductVersion: `0.2.1+817b7c314751a4654018e01c22ca38b14ca65a61`

## 実施内容

`HoverPocket.Shell.lnk`のtarget、working directory、iconを、既存の正規ショートカットと同じインストール済み0.2.3へ変更した。重複ショートカットは削除していない。起動中のDebug 0.2.1プロセスは終了・再起動していない。

その後の整理依頼に基づき、Git管理外の
`C:\Users\shotaro\code\shared\hover-pocket\windows\src\HoverPocket.Shell\bin\Debug`
をWindowsのゴミ箱へ移した。削除前は76ファイル、34,244,026 bytesで、Git管理ファイルは0件だった。

## Readback

- 対象ショートカット2件のtarget:
  `C:\Users\shotaro\AppData\Local\HoverPocketWin\current\HoverPocket.Shell.exe`
- target存在: `true`
- ProductVersion:
  `0.2.3+7bfbee4ed54ed989b1ad470fd4420b0d8efeda13`
- `HoverPocket.Shell.lnk` working directory:
  `C:\Users\shotaro\AppData\Local\HoverPocketWin\current`
- `HoverPocket.Shell.lnk` icon:
  `C:\Users\shotaro\AppData\Local\HoverPocketWin\current\HoverPocket.Shell.exe,0`
- 古いDebugフォルダ存在: `false`
- 親 `windows\src\HoverPocket.Shell\bin` 存在: `true`
- 実行中アプリ:
  `C:\Users\shotaro\AppData\Local\HoverPocketWin\current\HoverPocket.Shell.exe`
- 実行中ProductVersion:
  `0.2.3+7bfbee4ed54ed989b1ad470fd4420b0d8efeda13`

## Git整理

- `git fetch --prune origin`で、ローカル`main`が`origin/main`より7コミット古いことを確認した。
- 今回の記録コミットだけを`origin/main`の`386b572`へrebaseし、競合なく完了した。
- `git diff --check`はエラーなし、worktreeとindexはclean。
- 最終状態は`HEAD...origin/main = 1 0`。ローカル`main`はリモート最新をすべて含み、今回の記録1コミットだけahead。外部書き込みに当たるpushは行っていない。
