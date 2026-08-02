---
project_slug: hover-menu-preview
date: 2026-08-02
status: released; installed; verified
---

# HoverPocket Windows 0.2.5 Public Beta Release

## Release

- GitHub Release: https://github.com/shotaro311/hover-pocket/releases/tag/win-v0.2.5
- tag: `win-v0.2.5`
- source target: `12771730b82a103bdea050c7a4e3e143a7d25a57`
- title: `HoverPocket Windows 0.2.5 Public Beta`
- `draft=false`、`prerelease=false`、`latest=false`。Windows専用releaseとして公開し、GitHub LatestはmacOS `v0.1.0-155`のまま維持した。
- Release notesへCalendar time zone修正、panel即時close、Controls preview停止安定化、Windows 11 x64、0.2.3からの更新、未署名によるSmartScreen警告の可能性を記載した。

## Source integration and verification

- 公開直前に`origin/main`がmacOS build 155のcommit `2114fcb`まで進んでいたため、既存checkoutの未コミット`.serena/project.yml`を変更せず、一時worktreeの`codex/windows-0.2.5-release`へWindows変更を統合した。
- 統合commit `12771730b82a103bdea050c7a4e3e143a7d25a57`を`origin/main`へpushし、release tagとremote mainが同commitを指すことを公開時に確認した。
- Debug / Release buildはwarnings 0、errors 0。両構成の`calendar`を含む全13 verifierとWindows UI JavaScript 12ファイルの構文検査がすべてexit 0。
- self-contained Release実体の`release-config`、`shell`、`ui`、`calendar-live`がexit 0。`calendar-live`はCalendar 6件 / event 65件を読み取り専用で取得し、予定内容は出力していない。
- publish実体のProductVersionは`0.2.5+12771730b82a103bdea050c7a4e3e143a7d25a57`。NUPKG / feed / manifestは0.2.5、channel `win`、OAuth metadata `embedded-and-verified`。0.2.x方針どおりSetupとアプリはAuthenticode未署名。

## Published assets

GitHub Releaseへ次の8 assetだけを公開した。GitHub APIのsize / digest、匿名公開URLからストリーム取得したsize / SHA-256、ローカル成果物が全件一致した。`SHA256SUMS-win.txt`が対象とする7件も全件一致した。

| Asset | Bytes | SHA-256 |
| --- | ---: | --- |
| `assets.win.json` | 214 | `175f821a0c1c94132aec12708bd5592befb9e175332a7bf056edc07f31a77944` |
| `HoverPocketWin-0.2.5-full.nupkg` | 85,915,254 | `11186317ac5768fae122d34cb0afce67d5b459b5f3a7f58f59935bff7a4f04ef` |
| `HoverPocketWin-win-Portable.zip` | 85,914,222 | `b66c752f8080726385d22dd0496fd7dc97fc11117463b709c5ec4ff6041b65cf` |
| `HoverPocketWin-win-Setup.exe` | 90,376,822 | `44bc12ef36b7529a9fa93399ed4ab3dbdad470addde670e524a4fc865387ef62` |
| `release-manifest.win.json` | 278 | `d8a70d14fcbd0eca14c14bbb92efebad36c8bb52df6bd43bed4f456f8b7320da` |
| `RELEASES` | 84 | `c6263176a3b8d3735a11b3e5af0d9a5a55de4f207dc8234fef5bc401f69f8571` |
| `releases.win.json` | 262 | `cd86186f0ba355c7e95ce0165be5352538fc400a7b4840af1106f300e88073f2` |
| `SHA256SUMS-win.txt` | 631 | checksum対象7件一致 |

## Public route readback

- GitHub Pages workflow run `30745892827`はsource targetでsuccess。`https://shotaro311.github.io/hover-pocket/`がHTTP 200でWindows 0.2.5 Setup直リンクを返した。
- 公式ドメインはGitHub Pagesとは別のCloudflare Worker static assetsだったため、`wrangler 4.118.0 deploy --dry-run`で3 assetを検証後、Worker `hoverpocket-site` version `63985cec-d3a0-49dd-8aee-cf1cdea50e17`を再配信した。
- `https://hoverpocket.s-original.com/`と旧alias `https://hoverpocket.shotaromatsumoto.com/`は、通常URLとcache-bust URLの両方でHTTP 200、Windows 0.2.5 Setup直リンクを返した。privacyページはHTTP 200で、canonicalは引き続き`hoverpocket.s-original.com`を指す。

## Installed update readback

- このPCのインストール済み0.2.3を、公開したfull NUPKGと同一SHA-256のpackageからVelopack 1.2.0で0.2.5へ更新した。更新開始時に対象アプリprocessが0件であることを確認し、Setup上書きやregistry手動補正は行っていない。
- Velopackは別processへapplyを引き継ぐため呼び出し元PowerShellの`LASTEXITCODE`は空だったが、apply logの`Package version 0.2.5 applied successfully.`、Updater process終了、実体readbackを完了条件にした。
- `current/sq.version`は0.2.5 / channel `win` / `win-x64`。root stubとcurrent exeのProductVersionは`0.2.5+12771730b82a103bdea050c7a4e3e143a7d25a57`。
- HKCUのRegistry64 / Registry32 ARP `DisplayVersion`はともに0.2.5、`InstallLocation`は従来どおり`%LOCALAPPDATA%\HoverPocketWin`。
- インストール済み実体の`--verify calendar`、`--verify ui`、`--verify calendar-live`はすべてexit 0。通常起動後はcurrent exeの0.2.5 process 1件、`Responding=True`を確認した。
- 実予定の作成・編集・削除はGoogle Calendarへの外部書き込みになるため行っていない。time zone変換とrequest bodyは回帰verifier、実Google Calendar接続は読み取り専用verifierで確認した。

## macOS non-interference

- GitHub LatestはmacOS `v0.1.0-155`のまま。macOS専用`macos-latest/appcast.xml`はHTTP 200、896 bytes、Sparkle version 155、SHA-256 `c0aa1ec496b8e6ffdfc8a7c6a82e2a4d1871ef0e3952efa41653acdcb8f0da43`で公開前後不変。

## Local checkout boundary

- 元のcheckoutはHEAD `48697d1`、未コミットの既存`.serena/project.yml`だけを保持したまま変更していない。release作業と成果物・検証ログは一時worktree側へ分離した。
