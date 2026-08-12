---
project_slug: hover-menu-preview
date: 2026-08-12
status: completed
updated_by: codex
---

# macOS Build 161 / Windows 0.2.6 Public Release

## 対象

- source commit: `f0172f2be69b5a3bf711046bd0d77b6d088b5942`
- macOS: `0.1.0 (161)`
- Windows: `0.2.6`公開ベータ
- 配信機能: メディア再生速度、再生元画面の前面表示、Timerストップウォッチ

## macOS公開

- GitHub Latest: `https://github.com/shotaro311/hover-pocket/releases/tag/v0.1.0-161`
- macOS専用feed: `https://github.com/shotaro311/hover-pocket/releases/tag/macos-latest`
- tag target: `f0172f2be69b5a3bf711046bd0d77b6d088b5942`
- Apple公証submission: `0747f85d-9124-4602-bf48-bb49ba26fd96`
- 公証status: `Accepted`
- 公開versioned / manual install ZIP SHA-256: `f49811508e46d47dbbf2c37ae25e721d554105fd357242146185c2e44b6b0801`
- appcast SHA-256: `401e5a385a38edd337758915b421d502f08fde661ceaef2c280f977456f04cab`
- appcast readback: `sparkle:version=161`、`sparkle:shortVersionString=0.1.0`、versioned ZIP URL、EdDSA署名あり。
- 公開ZIPを匿名URLから再取得し、ローカルZIPとhash / sizeが一致した。展開後appは`0.1.0 (161)`、Developer ID Application、runtime flag、timestamp、staple、`codesign --verify --deep --strict`、Gatekeeper `Notarized Developer ID`に合格した。

## Windows公開

- Release: `https://github.com/shotaro311/hover-pocket/releases/tag/win-v0.2.6`
- target: `f0172f2be69b5a3bf711046bd0d77b6d088b5942`
- `--latest=false`相当で公開し、GitHub LatestはmacOS `v0.1.0-161`のまま維持した。
- `release-manifest.win.json`: `version=0.2.6`、`runtime=win-x64`、`updateChannel=win`、`updateFeed=releases.win.json`、`oauthMetadata=embedded-and-verified`、`authenticode=unsigned`。
- Windows 0.2.x公開ベータの方針どおり、Setup / exeはAuthenticode未署名。Release notesと公式サイトでMicrosoft Defender SmartScreen警告の可能性を明記した。

### 公開asset

| asset | bytes | SHA-256 |
|---|---:|---|
| `assets.win.json` | 214 | `2ec6d6f0aaf91131c3f109ea65d0b5cc966b7b6b94b293155f2f9df5b7624f18` |
| `HoverPocketWin-0.2.6-full.nupkg` | 85,920,102 | `5c23ba851825678a9199de6d526c8fdd285d9d7bdb556c2043e03255e93b36e0` |
| `HoverPocketWin-win-Portable.zip` | 85,919,071 | `6da8cf832e14a6719f2317fec102d44a80b8dc88c613b40e476a3d97acc198f9` |
| `HoverPocketWin-win-Setup.exe` | 90,381,670 | `46438786b3227212c27e9bb32d97793e3dd154881225f7cf93e0e91ad88858e8` |
| `release-manifest.win.json` | 278 | `7057560dc04410b3eb25b77926e7fdc3d0d6e6b07141ca6c483ff21a5e0af166` |
| `RELEASES` | 84 | `93c912b80b5d2ad1560e7794c2542c76d4d79d36debd0e9e9439385640b3e8a0` |
| `releases.win.json` | 262 | `3b717a7e42c2445b4d11427db975b4edf68b0e178cf6c64f91f7567a6bef42c8` |
| `SHA256SUMS-win.txt` | 631 | `4e4f62c399dc00cd6a84ff15cea404217673be93b0403185ebcc9000b14bc631` |

- 8 assetを公開download URLから再取得し、GitHub API digest、ローカル生成物、HTTP取得物のsize / SHA-256三者一致を確認した。
- `releases.win.json`は`HoverPocketWin`、version `0.2.6`、type `Full`、`HoverPocketWin-0.2.6-full.nupkg`を返した。

## Windows検証と更新適用

- 元のWindows repoは`main...origin/main [ahead 4, behind 7]`かつ既存dirtyだったため、checkout / pull / stash / resetせず前後不変で保全した。
- Windows実機のfresh cloneをsource commitへdetached checkoutし、Release buildを実行した。
- `--verify controls / ui-model / ui / timer / updater / settings / shell / display / release-config`: すべてpass。
- 更新適用後に`controls / timer / updater / release-config`を再実行し、すべてexit 0。
- `git diff --check`: exit 0。fresh cloneのtracked file変更、commit、branch pushなし。
- 既存インストール0.2.5を確認し、公開feedのfull packageを既存`Update.exe`経由で適用した。
- 更新後process: `%LOCALAPPDATA%\\HoverPocketWin\\current\\HoverPocket.Shell.exe`
- 更新後ProductVersion: `0.2.6+f0172f2be69b5a3bf711046bd0d77b6d088b5942`
- ARP: `DisplayVersion=0.2.6`、`InstallLocation=%LOCALAPPDATA%\\HoverPocketWin`
- 実ブラウザYouTubeでの「− / ＋」速度変更、サムネイル前面化、アプリ内MessageBoxのYes / Download / Restart手動クリックは、無関係なウィンドウへ入力する危険を避けて未確認。決定的Controls verifier、UI verifier、Timer verifier、公開packageのVelopack適用readbackで代替した。

## 公式サイト

- `npx wrangler deploy --dry-run`: static assets 3件、成功。
- Cloudflare Worker `hoverpocket-site` version: `3132a282-07ca-426b-a127-04a1009c995c`
- `https://hoverpocket.s-original.com/`: HTTP 200、Windows 0.2.6 Setup直リンクあり。
- `https://hoverpocket.shotaromatsumoto.com/`: HTTP 200、同じWindows 0.2.6 Setup直リンクあり。
- ローカル`site/index.html`、正規ドメイン、旧aliasの本文SHA-256はすべて`652f7ea62e8dfd74a693f99218fe90ea23f78b1abf1826c85be63f73904936ad`で一致した。
- privacy pageはHTTP 200、canonicalは`https://hoverpocket.s-original.com/privacy`を維持した。

## OS別feed分離readback

- Windows公開前後のmacOS appcast SHA-256は`401e5a385a38edd337758915b421d502f08fde661ceaef2c280f977456f04cab`で不変。
- Windows公開後のGitHub Latestは`v0.1.0-161`。
- macOS tagとWindows tagはいずれも同じsource commitを指し、各OS専用feedを使用している。
