# HoverPocket macOS Build 155 Release

## 配信対象

- version: `0.1.0`
- build: `155`
- target commit: `274217e558d0d827ba892a831d6d0f7770f9e1ef`
- versioned release: `https://github.com/shotaro311/hover-pocket/releases/tag/v0.1.0-155`
- stable macOS feed release: `https://github.com/shotaro311/hover-pocket/releases/tag/macos-latest`
- Sparkle feed: `https://github.com/shotaro311/hover-pocket/releases/download/macos-latest/appcast.xml`

build 150以降の配信内容は、世界の都市・現在地対応の天気、Calendar保存ボタンの上部配置、Clipboardのテキスト/画像split表示、メディア再生速度の実DOM反映、パネル/文字のExtra Large、Timerの横並び・compact card UI。

## 配信前検証

- `main` / `origin/main`: `274217e558d0d827ba892a831d6d0f7770f9e1ef`で一致、ahead / behind `0 / 0`。
- `swift build`: 成功。
- `./script/build_and_run.sh --verify`: 成功。
- `--verify-panel-layout`: 112ケース、4 panel size / 4 text size、永続化を確認。
- `--verify-clipboard`: 成功。
- `--verify-timer`: lifecycle / pin / storage isolation / side-by-side / compactが成功。
- `--verify-calculator`: 成功。
- `--verify-weather --render-weather-preview`: Open-Meteo実API、世界検索、現在地model、7日予報、timezone、温度単位、legacy migration、offline cache、motion presetが成功。
- Developer ID Application証明書、`hover-pocket` notarytool profile、Sparkle `generate_appcast`を確認した。

## 署名・公証

- Developer ID: `Developer ID Application: Shotaro Matsumoto (N7VVPW44ZA)`。
- hardened runtime: 有効。
- entitlements: Apple Events automation、camera、audio input。
- notary submission: `b20ce703-0722-4e20-a0a1-0816cecf2eba`。
- Apple readback: `Accepted`、submission artifact `HoverPocket-0.1.0-155.zip`。
- `codesign --verify --deep --strict`: 成功。
- `xcrun stapler validate`: 成功。
- `spctl --assess --type execute`: `accepted / Notarized Developer ID`。
- ローカルappと最終ZIP展開後appの両方で同じ検証を通した。

## GitHub Release readback

### `v0.1.0-155`

- public / non-draft / non-prerelease / GitHub Latest。
- tag target: `274217e558d0d827ba892a831d6d0f7770f9e1ef`。
- assets: `appcast.xml`、`HoverPocket-0.1.0-155.zip`、`.zip.sha256`、`HoverPocket-macOS-app.zip`の4件。
- ZIP size: `6481453` bytes。
- GitHub asset digest: `sha256:a6965480b0e35892ea4a4bf2a943597ff2e8da994e22fbcb099c4113f299870b`。

### `macos-latest`

- assets: `appcast.xml`、`HoverPocket-macOS-app.zip`の2件。
- appcast digest: `sha256:c0aa1ec496b8e6ffdfc8a7c6a82e2a4d1871ef0e3952efa41653acdcb8f0da43`。
- manual install ZIP digest: `sha256:a6965480b0e35892ea4a4bf2a943597ff2e8da994e22fbcb099c4113f299870b`。

## 匿名公開URL readback

- versioned appcast / stable appcast / local appcastのSHA-256はすべて`c0aa1ec496b8e6ffdfc8a7c6a82e2a4d1871ef0e3952efa41653acdcb8f0da43`で一致。
- appcastは`sparkle:version=155`、`sparkle:shortVersionString=0.1.0`、versioned ZIP URL、length `6481453`、88文字のEdDSA署名を返した。
- versioned ZIP / stable manual install ZIP / local ZIP / 公開`.sha256`の値はすべて`a6965480b0e35892ea4a4bf2a943597ff2e8da994e22fbcb099c4113f299870b`で一致。
- ZIP top-levelは`HoverPocket.app`のみ。
- 展開後appは`CFBundleVersion=155`、`CFBundleShortVersionString=0.1.0`、`HoverPocketKeychainServiceSuffix=release`、macOS専用`SUFeedURL`。
- 展開後appもDeveloper ID署名、公証ticket、Gatekeeperへ合格した。

## 非変更範囲

- Windows release `win-v0.2.3`は8 asset、target commit `7bfbee4ed54ed989b1ad470fd4420b0d8efeda13`のまま不変。
- Windows feed / assetは変更していない。
