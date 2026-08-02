---
project_slug: hover-menu-preview
date: 2026-07-29
platform: windows
version: 0.2.4
status: release-candidate
---

# Windows 0.2.4 Release Candidate

## Scope

- パネルclose終盤に内容が細いバーへ圧縮されて横へ動くモーフィングを削除し、closeを即時非表示へ変更した。
- openとpanel resizeのモーフィングは維持した。
- 即時closeで露出したControlsライブプレビューのcancel / capture停止競合を修正した。
- Windows app version、updater dry-run、README、Windows README、Webサイトのダウンロード導線を0.2.4へ更新した。

## Source identity

- release source commit: `7a51fd7d6c546c8468a318a200ea671a544e92e1`
- ProductVersion: `0.2.4+7a51fd7d6c546c8468a318a200ea671a544e92e1`
- package version: `0.2.4`
- release tag: `win-v0.2.4`
- update channel / feed: `win` / `releases.win.json`

## Verification

- Debug / Release build: warnings 0 / errors 0。
- 両構成で`shell`、`display`、`ui`、`ui-model`、`sticky`、`clipboard`、`calc`、`timer`、`calendar`、`settings`、`ailane`、`updater`、`controls`がすべてexit 0。
- Release shellは25 cycle、`instant_close=true`、open animation 29 frames、最大frame gap 18.1ms。
- Windows UI JavaScript 12ファイルの`node --check`はすべてexit 0。
- self-contained publish実体の`release-config`はversion 0.2.4、Release構成、Google OAuth metadata一致、Windows channel `win`でexit 0。
- self-contained publish実体の`shell` / `ui`はexit 0。shellは25 cycle、`instant_close=true`、open animation 27 frames、最大frame gap 16.0ms。
- self-contained publish実体の`calendar-live`は既存credentialでCalendar 6件、event 91件をread-only取得し、予定内容は出力せず、作成・更新・削除も行っていない。

## Local assets

- `assets.win.json`: 214 bytes
- `HoverPocketWin-0.2.4-full.nupkg`: 85,914,444 bytes
- `HoverPocketWin-win-Portable.zip`: 85,913,413 bytes
- `HoverPocketWin-win-Setup.exe`: 90,376,012 bytes
- `release-manifest.win.json`: 278 bytes
- `RELEASES`: 84 bytes
- `releases.win.json`: 262 bytes
- `SHA256SUMS-win.txt`: 631 bytes

`SHA256SUMS-win.txt`の7対象はすべてローカル再計算と一致した。feedのNUPKG SHA-256も一致し、NUPKG / feed versionは0.2.4。portable ZIPには`current/HoverPocket.Shell.exe`と`current/sq.version`がある。

Setup SHA-256は`dea43a7753c49141c62f20bc5b81e7b9f85fcd97f17987d61f96b235b2814ef7`。0.2.x公開ベータ方針どおり、SetupとアプリはAuthenticode `NotSigned`。

## Pre-publication remote baseline

- 既存Windows releaseは`win-v0.2.3`、asset 8件、target `7bfbee4ed54ed989b1ad470fd4420b0d8efeda13`、draft / prereleaseともfalse。
- GitHub LatestはmacOS `v0.1.0-150`、asset 4件。
- `macos-latest/appcast.xml`はSparkle version 150、896 bytes、SHA-256 `0618463faabe19d7abf945e1963afd0475d5ae504848d3d61089b88ededa4ff1`。

## Publication gate

外部書き込みは未実施。公開時はlocal mainをpushし、source commit `7a51fd7d6c546c8468a318a200ea671a544e92e1`をtargetに`win-v0.2.4`を`--latest=false`で作成し、上記8 assetだけをuploadする。公開後に匿名URL、GitHub API digest、Windows feed、0.2.3からの実更新、macOS Latest / appcast不変をreadbackする。
