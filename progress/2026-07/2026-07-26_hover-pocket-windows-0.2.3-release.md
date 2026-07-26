# HoverPocket Windows 0.2.3 Public Beta Release

## Release

- GitHub Release: https://github.com/shotaro311/hover-pocket/releases/tag/win-v0.2.3
- tag: `win-v0.2.3`
- target: `7bfbee4ed54ed989b1ad470fd4420b0d8efeda13`
- title: `HoverPocket Windows 0.2.3 Public Beta`
- `draft=false`、`prerelease=false`、`latest=false`。GitHub LatestはmacOS版から変更していない。
- Windows 11 x64向け公開ベータ、Authenticode未署名、SmartScreen警告の可能性、Setup / Portable、0.2.2からの更新、ARP表示version補正をRelease notesへ記載した。

## Build and candidate verification

- exact main `7bfbee4ed54ed989b1ad470fd4420b0d8efeda13`から生成した。
- Debug / Release build: exit 0、warnings 0、errors 0。
- Windows UI JavaScript 12件の`node --check`: 全件exit 0。
- `git diff --check`: exit 0。
- Release verifier: `settings=0`、`calendar=0`、`controls=0`、`updater=0`、`ui=0`、`shell=0`。
- UpdaterVerifierはARP stale→current、path mismatch no-op、他value維持、一時key cleanupをPASSした。
- process内だけで既存OAuth設定を注入して`publish_release.ps1`を実行した。値はログ、progress、Gitへ出していない。
- `release-config`: version 0.2.3、configuration Release、OAuth metadata `present-and-matched`、Windows channel `win`、exit 0。
- publish exe / PortableのProductVersionは`0.2.3+7bfbee4ed54ed989b1ad470fd4420b0d8efeda13`、nupkg内部versionは0.2.3。
- manifestは0.2.3、`win-x64`、channel `win`、OAuth metadata `embedded-and-verified`、Authenticode `unsigned`。
- Setup Authenticodeは`NotSigned`。`SHA256SUMS-win.txt`の対象7件は全件一致した。

## Published assets readback

GitHub API / `gh`と匿名の公開download URLを別経路で確認した。tag targetはexact main、assetは8件、GitHub APIのsize / digestはローカル成果物と全件一致した。公開URLからfeed、manifest、assets list、RELEASES、checksumを再取得し、大容量3 assetは公開URLのHTTP 200も確認した。

| Asset | Bytes | SHA-256 |
| --- | ---: | --- |
| `assets.win.json` | 214 | `48595fc54bbd048d105cfd80ba0e54562849c0bb4fb16a3fec6f8e6520f292e3` |
| `HoverPocketWin-0.2.3-full.nupkg` | 85,914,120 | `1a9714e16ee1dc4d4362cfa201af14fac126aeb00e764f8cab6a46dd763de1d1` |
| `HoverPocketWin-win-Portable.zip` | 85,913,089 | `5c799beb6b6247e12141fec15694a6f08a0c50cba055819daf9dbe492ba698fc` |
| `HoverPocketWin-win-Setup.exe` | 90,375,688 | `04955463ad92b10f150c009ddd2155f8477b5823e53a4e6fb995145e45fe1b22` |
| `release-manifest.win.json` | 278 | `c3160d13b90bb8b009ffcf8982c5af99624ec90446b9c79f38e8b8a780902d49` |
| `RELEASES` | 84 | `06bcca3741a74270a62e49079587f4d4d3488d448797444fdf4922e2d07a8cf5` |
| `releases.win.json` | 262 | `b2c23a36f80fb0d0c74b7c10010be38eadf64f1f40264cce827531e49c3b4111` |
| `SHA256SUMS-win.txt` | 631 | `34d744cc52c4111be6a3f91fc12f3df27acbba53e29b49e44aa1adf315123490` |

公開feedはfull asset 1件、version 0.2.3、package `HoverPocketWin-0.2.3-full.nupkg`。公開manifestとchecksum 7件もGitHub API digestおよびローカル成果物と一致した。

## 0.2.2 to 0.2.3 update E2E

開始時baseline:

- インストール済み`current`のFileVersionは0.2.2.0、ProductVersionは`0.2.2+f2959ca77122e6781e4e9549b8e13db860bdc2b0`。
- 実行中processはインストール先`current`の1件。
- HKCUの`HoverPocketWin` ARP `DisplayVersion`はRegistry64 / Registry32とも0.2.1。更新前の全12 valueを比較用に一時readbackした。

更新:

- Computer Useではパネル表示までは確認したが、untitled tool windowを安全に対象選択できず、Windows shellのwindow binding不一致も発生したためGUI入力を停止した。
- Setupによる上書きや手動registry補正は行わず、インストール済み0.2.2が使用するVelopack 1.2.0の`GithubSource` / `UpdateManager`を実install root、current package、channel `win`へ結び、0.2.3検出とfull package downloadを実行した。
- stagingされたnupkgは85,914,120 bytes、SHA-256は公開digestと一致した。
- 実インストールの`Update.exe apply`を0.2.2 PID待機で実行し、対象HoverPocket processだけを終了した。apply / restartはexit 0で、ログはpackage 0.2.3の適用、uninstall registry key書き込み、再起動、package apply成功を記録した。

更新後readback:

- `current` exe、root stub、実行process、locator metadataは0.2.3。ProductVersionは`0.2.3+7bfbee4ed54ed989b1ad470fd4420b0d8efeda13`。
- HKCU ARP `DisplayVersion`はRegistry64 / Registry32とも0.2.1→0.2.3。
- `InstallLocation`と静的ARP valueは更新前と一致した。Velopack applyがinstall metadataの`InstallDate`と`EstimatedSize`を更新した。
- 通常再起動processのself-healログは両viewとも`AlreadyCurrent`。この実updateではVelopackが既に0.2.3を書いていたため、self-heal自身は他valueを含めno-opだった。
- UpdaterVerifierの一時test key残数は0。
- 常駐processを一時終了してインストール済み0.2.3の実WebView2 `--verify ui`を排他的に実行し、Controls描画、provider切替、bridge/settings round-tripを含めてexit 0。その後、同じ`current`実体を再起動した。
- インストール済み0.2.3の`--verify controls`はexit 0。
- 再起動processの自動更新確認はremote 0.2.3に対してno update / up-to-date。
- インストール済み0.2.3の`--verify calendar-live`はexit 0。既存credentialでCalendar 6件、event 91件をread-only取得し、予定の作成・更新・削除は行っていない。

## macOS non-interference

- 公開前後ともGitHub Latestは`v0.1.0-131`、nameは`HoverPocket 0.1.0 (131)`。
- `macos-latest/appcast.xml`はSparkle version 131、896 bytes、SHA-256 `b66fe0cc0d65cef699992cf7998a35831c5d340cc59c9ce2474f599fe8e56655`で不変。

## Remaining boundary

- 公開asset、Velopack detect / download / apply / restart、post-update UI verifier、Calendar read-only、ARP readbackは完了した。
- Computer Useの安全停止により、アプリ内の確認ダイアログをマウスでYes選択するUXそのものは再現していない。更新本体は同じ公開feed / packageと実install rootのVelopack経路で完了し、Setup上書きやregistry手動変更は行っていない。
