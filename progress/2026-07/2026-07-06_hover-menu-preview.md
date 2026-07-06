# 2026-07-06: Cross-platform agent read gate

## Mac Calculator History and Feed Split

### 目的

- macOS / Windows release の `latest` 衝突を避けるため、macOS distribution build の Sparkle feed を `macos-latest` へ分離する。
- M2 MacBook Air などノッチ機で、パネルが右側から左へスライドするように見える挙動を抑え、ノッチ中心から展開する動きに戻す。
- Calculator に履歴、履歴数値クリック、履歴時点への復元、Shift 入力を含むキーボード演算子対応を追加する。

### 変更

- `script/package_zip.sh`
  - distribution build の既定 `SUFeedURL` を `https://github.com/shotaro311/hover-pocket/releases/download/macos-latest/appcast.xml` へ変更。
- `script/publish_github_release.sh`
  - versioned macOS release は GitHub Latest に明示設定し、旧 build 98 など `latest/download/appcast.xml` を見る既存ユーザーを維持。
  - `macos-latest` release へ `HoverPocket-macOS-app.zip` と `appcast.xml` を同期する処理を追加。
- `Sources/HoverPocket/Windowing/PanelGeometry.swift`
  - preview frame の中心を `notchProfile.centerX` に合わせ、collapsed preview と expanded preview の中心を揃えた。
- `Sources/HoverPocket/State/CalculatorStore.swift`
  - `HistoryEntry` と計算状態 snapshot を追加。
  - 計算結果、percent、chain calculation を履歴へ記録。
  - 履歴数値の入力反映と履歴時点への復元を追加。
- `Sources/HoverPocket/Views/CalculatorView.swift`
  - display と keypad の間に compact history を追加。
  - 履歴数値ボタンと戻るアイコンを追加。
  - `event.characters` を優先し、`+`、`*`、`%`、`×`、`÷` など Shift / symbolic 入力を拾うよう補強。
- `Sources/HoverPocket/App/CalculatorVerificationCommand.swift`
  - 履歴作成、数値反映、restore 後の継続計算を verify に追加。
- `README.md`
  - macOS 専用 feed、Calculator 履歴、restore 操作を反映。

### 検証

- `swift build`: 成功。
- `bash -n script/package_zip.sh script/publish_github_release.sh script/generate_appcast.sh script/notarize_release.sh script/build_and_run.sh`: 成功。
- `.build/debug/HoverPocket --verify-calculator`: 成功。`calculator_display=25`、`calculator_history_count=1`。
- `.build/debug/HoverPocket --verify-calculator --calculator-sequence '12+3=+4='`: 成功。`calculator_display=19`、`calculator_history_count=2`。
- `.build/debug/HoverPocket --verify-calculator --calculator-sequence '20%+2='`: 成功。`calculator_display=2.2`、`calculator_history_count=2`。
- `.build/debug/HoverPocket --verify-calculator --calculator-sequence '7/0='`: 成功。`calculator_display=Error`。
- `git diff --check`: 成功。
- `./script/build_and_run.sh --verify`: 成功。`HoverPocket launched`。
- `APP_BUILD=$(git rev-list --count HEAD) PUBLISH_DRY_RUN=1 PUBLISH_PREPARE_RELEASE=1 PUBLISH_REQUIRE_NOTARIZED=0 ./script/publish_github_release.sh`: 成功。build `111` の dry-run artifact を生成。
- dry-run artifact readback:
  - `dist/HoverPocket.app` の `SUFeedURL` は `https://github.com/shotaro311/hover-pocket/releases/download/macos-latest/appcast.xml`。
  - `dist/releases/appcast.xml` の `sparkle:version` は `111`、enclosure は versioned release `v0.1.0-111`。

### 配信

- `APP_VERSION=0.1.0 NOTARYTOOL_PROFILE=hover-pocket ./script/publish_github_release.sh`: 成功。
- `notary_submission_id=70397200-f50b-4dfb-a0b1-2a51821f7904`、`notary_status=Accepted`。
- GitHub Release:
  - versioned: `https://github.com/shotaro311/hover-pocket/releases/tag/v0.1.0-112`
  - stable macOS feed: `https://github.com/shotaro311/hover-pocket/releases/tag/macos-latest`
- `gh release view v0.1.0-112`: `appcast.xml`、`HoverPocket-0.1.0-112.zip`、`HoverPocket-0.1.0-112.zip.sha256`、`HoverPocket-macOS-app.zip` を確認。
- `gh release view macos-latest`: `appcast.xml` と `HoverPocket-macOS-app.zip` を確認。
- `gh release view`: latest release が `v0.1.0-112` であることを確認し、旧 build の `latest/download/appcast.xml` 経路を維持。
- `curl https://github.com/shotaro311/hover-pocket/releases/download/macos-latest/appcast.xml`: `sparkle:version=112`、versioned ZIP enclosure、edSignature を確認。
- `curl https://github.com/shotaro311/hover-pocket/releases/latest/download/appcast.xml`: `sparkle:version=112` を確認。
- stable ZIP readback:
  - remote asset digest と local SHA256 は `b13fda6a78544fb27c5cb03f1ad67ccd060bfb3028bcd08643d8fca49df86eb2` で一致。
  - ZIP top-level は `HoverPocket.app/`。
  - extracted app の `CFBundleVersion` は `112`。
  - extracted app の `SUFeedURL` は `https://github.com/shotaro311/hover-pocket/releases/download/macos-latest/appcast.xml`。
  - extracted app で `codesign --verify --deep --strict --verbose=2`、`xcrun stapler validate`、`spctl --assess --type execute --verbose=2` が成功。

## Cross-platform agent read gate

## 目的

- Mac / Windows の 2 バージョン運用で、他の AI エージェントが作業前に同じ正本を読むようにする。
- 新しい `product.md` ルールは増やさず、既存の開発 docs ルールへ寄せる。

## 変更

- project root に `AGENTS.md` を追加。
  - 必読入口を `progress/progress.md` と `docs/requirement/requirements.md` に固定。
  - macOS 作業時は `README.md` / `script/`、Windows 作業時は `windows/README.md` / `windows/script/` を追加確認するよう明記。
  - macOS / Windows が GitHub Releases の `latest` を共有しない方針を明記。
- `docs/requirement/requirements.md` に `1.4 Mac / Windows 横断ワークフロー` を追加。
  - OS 別担当、共通仕様の置き場所、release feed 分離、readback 完了条件を requirements の正本に統合。
- `progress/progress.md` の先頭に今回のドキュメント更新を追記。

## 検証

- `git diff --check`: 成功。
