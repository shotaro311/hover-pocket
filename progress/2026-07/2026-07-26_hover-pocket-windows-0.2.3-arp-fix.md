# HoverPocket Windows 0.2.3 ARP DisplayVersion Repair Candidate

## Scope

- 対象branch: `codex/windows-0.2.3-arp-fix`
- base: `f2959ca77122e6781e4e9549b8e13db860bdc2b0`
- 0.2.2実update後、実行ファイルとVelopack packageは0.2.2へ更新された一方、HKCUのARP `DisplayVersion`が0.2.1に残った事象を0.2.3候補で修正する。
- GitHub Release作成、asset upload、インストール済み0.2.2の更新は対象外。

## Implementation

- Windows assembly/package versionとUpdaterVerifierのcurrent/nextを0.2.2→0.2.3へ更新した。
- `VelopackApp.Build().Run()`から戻った通常processだけで`VelopackLocator.Current`を参照し、実インストールかつportableでない場合にARP補正を行う。
- 対象はHKCU `Software\Microsoft\Windows\CurrentVersion\Uninstall\HoverPocketWin`の既存keyだけ。Registry64/Registry32を確認し、`InstallLocation`と`RootAppDir`が一致した場合だけ`DisplayVersion`を現在versionへ更新する。
- keyなし、portable、非インストール、app id不一致、path mismatch、例外では起動を止めずno-op/logとした。verifyとsecond-instance probeではproduction ARP補正を呼ばない。
- internal helperへregistry base path、app id、install root、versionを渡せるようにし、UpdaterVerifierのGUID付き一時test keyで次を確認した。
  - stale 0.2.2→current 0.2.3
  - path mismatch時のno-op
  - `InstallLocation`と追加sentinel valueの維持
  - test key cleanup
- README、Windows README、siteのWindows導線と表記を0.2.3候補へ更新した。公開サイトへのdeployは行っていない。

## Verification

- Debug build: exit 0、warnings 0、errors 0。
- Release build: exit 0、warnings 0、errors 0。
- Windows UIの全12 JavaScript: `node --check` exit 0。
- `git diff --check`: exit 0。
- Debug verifier: `shell`、`display`、`ui-model`、`settings`、`sticky`、`clipboard`、`calc`、`timer`、`calendar`、`controls`、`updater`、`ui`がすべてexit 0。
- Release verifier: `settings`、`calendar`、`controls`、`updater`、`ui`、`shell`がすべてexit 0。
- Debug / ReleaseのUpdaterVerifierでARP regression 4項目がすべて`ok`、test key残数0。

## 0.2.3 candidate readback

- `publish_release.ps1`: exit 0。OAuth値はprocess内だけで注入し、値を出力していない。
- `release-config`: version 0.2.3、configuration Release、OAuth metadata present-and-matched、Windows channel win、exit 0。
- feed: full asset 1件、version 0.2.3、`HoverPocketWin-0.2.3-full.nupkg`。
- nupkg / Portable内部version: 0.2.3。
- manifest: version 0.2.3、runtime `win-x64`、channel `win`、OAuth metadata `embedded-and-verified`、Authenticode `unsigned`。
- `SHA256SUMS-win.txt`: 対象7件、全件一致。
- Setup Authenticode: `NotSigned`。0.2.x公開ベータの既存方針どおり。

| Asset | Bytes | SHA-256 |
| --- | ---: | --- |
| `assets.win.json` | 214 | `f160c44ce75c990e54e441859579c57b93a360dded288e01176d1eb364886ead` |
| `HoverPocketWin-0.2.3-full.nupkg` | 85,914,133 | `51ea8d120928ddb8573246631a88060ebb9ad9830b03148758065637bbdc101b` |
| `HoverPocketWin-win-Portable.zip` | 85,913,102 | `b2dae76042c87e6de9e64cc5ebde8818d918bb1efa15f90557f6a8b51629ba84` |
| `HoverPocketWin-win-Setup.exe` | 90,375,701 | `efb4fa479ab8174fc7923fd268b0b32700f77115c0ee7a024bdedf1405b09e1b` |
| `release-manifest.win.json` | 278 | `c3160d13b90bb8b009ffcf8982c5af99624ec90446b9c79f38e8b8a780902d49` |
| `RELEASES` | 84 | `f08e629ae1b08521b391bdedc69d4df39497414f0dd05a989af31b2976edfba4` |
| `releases.win.json` | 262 | `1498747a3b717c642c3d5f572f257169bf8971c6cf687fb8b8b066d6dade36b8` |
| `SHA256SUMS-win.txt` | 631 | `6c4e2c80b7fffd06a669d3d0230cc590c35c0046369bdf95d08c7b0cb2ef8412` |

## Preserved baseline and remaining gate

- インストール済み`current`は0.2.2、ARP `DisplayVersion`は0.2.1のまま保持した。candidateによる上書き、Setup実行、registry手動補正は行っていない。
- GitHub Release、tag、公開asset、macOS Latest/appcastは変更していない。
- 残るrelease gateは、0.2.3公開後の実0.2.2→0.2.3 update apply/restartで、実行ファイル、process、uninstall entryが0.2.3へ揃い、他ARP valueが維持されることのreadback。
