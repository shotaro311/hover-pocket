# 2026-07-06: Cross-platform agent read gate

## Mac Sparkle Update Popup Foregrounding

### 目的

- ユーザーがアップデート確認を実行したときに、Sparkle の更新ダイアログや進行状況ウィンドウが他アプリの背面へ回らないようにする。
- 起動後の自動 update probe では、作業中のウィンドウを奪わない。

### 変更

- `Sources/HoverPocket/Services/AppUpdater.swift`
  - `SPUStandardUserDriverDelegate` を接続し、Sparkle の標準 UI 表示前後を捕捉。
  - `checkForUpdates()` の手動実行時だけ foreground window を 12 秒間開き、`SUUpdateAlert` / `SUStatus` / `Sparkle` 由来ウィンドウを短い retry で前面化。
  - no-update などの modal alert では `NSApp.modalWindow` を fallback として前面化。
  - `refreshAvailableUpdateStatus()` の自動プローブでは前面化しない。
- `README.md`
  - 手動アップデート確認時は Sparkle UI を前面化し、自動プローブでは前面化しないことを追記。

### 検証

- `swift build`: 成功。
- `git diff --check`: 成功。
- `./script/build_and_run.sh --verify`: 成功。`HoverPocket launched`。

### 配信

- `APP_VERSION=0.1.0 NOTARYTOOL_PROFILE=hover-pocket ./script/publish_github_release.sh`: 成功。
- `notary_submission_id=715e3a67-4c6f-4bb7-94b5-5970fd6af407`、`notary_status=Accepted`。
- GitHub Release:
  - versioned: `https://github.com/shotaro311/hover-pocket/releases/tag/v0.1.0-117`
  - stable macOS feed: `https://github.com/shotaro311/hover-pocket/releases/tag/macos-latest`
- `gh release list --repo shotaro311/hover-pocket --limit 6`: `v0.1.0-117` が GitHub Latest。
- `gh release view v0.1.0-117`: `appcast.xml`、`HoverPocket-0.1.0-117.zip`、`HoverPocket-0.1.0-117.zip.sha256`、`HoverPocket-macOS-app.zip` を確認。
- `gh release view macos-latest`: `appcast.xml` と `HoverPocket-macOS-app.zip` を確認。
- `curl https://github.com/shotaro311/hover-pocket/releases/download/macos-latest/appcast.xml`: `sparkle:version=117`、versioned ZIP enclosure、edSignature を確認。
- `curl https://github.com/shotaro311/hover-pocket/releases/latest/download/appcast.xml`: `sparkle:version=117` を確認。
- stable ZIP readback:
  - remote asset digest と local SHA256 は `b3031f5cfac919a7eff91e3e7023fd96911725353a8a5e4aee9c1d89e6928dae` で一致。
  - ZIP top-level は `HoverPocket.app/`。
  - extracted app の `CFBundleVersion` は `117`。
  - extracted app の `SUFeedURL` は `https://github.com/shotaro311/hover-pocket/releases/download/macos-latest/appcast.xml`。
  - extracted app で `codesign --verify --deep --strict --verbose=2`、`xcrun stapler validate`、`spctl --assess --type execute --verbose=2` が成功。

### 未実施

- 既存 install 済みアプリから Sparkle UI を開き、更新ダイアログが前面化する実機操作確認は未実施。配信済み build `117` の appcast / ZIP / Gatekeeper readback までは完了。

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

## OAuth public verification console execution

## 目的

- Google OAuth sensitive-scope verification に向けて、GitHub Pages 公開、Search Console 所有権確認、Google Auth Platform の Branding / Audience / Data Access / Prepare for verification を実画面で進める。
- Google Cloud は専用プロジェクトを新規作成せず、既存 `hoverpocket` プロジェクトを使うべきか確認する。

## 実施

- `git pull --ff-only` で `site/` と OAuth docs を含む upstream を取り込んだ。
- `.github/workflows/pages.yml` を追加し、GitHub Actions から `site/` を Pages artifact として公開する構成にした。
- `gh api repos/shotaro311/hover-pocket/pages` で GitHub Pages を workflow publishing として有効化した。
- 初回 push-triggered Pages run は Pages site 未作成のため失敗したため、Pages 作成後に `gh workflow run pages.yml --ref main` を手動 dispatch した。
- Search Console 確認用に `site/googlea0eda7d7223f8019.html` を追加し、project site 側で `https://shotaro311.github.io/hover-pocket/googlea0eda7d7223f8019.html` を配信した。
- Search Console で `https://shotaro311.github.io/hover-pocket/` の所有権を HTML file 方式で自動確認した。
- Google Cloud project `hoverpocket` を確認した。`gcloud projects describe hoverpocket` は ACTIVE、`shotaro.matsu0311@gmail.com` は `roles/owner`。既存 OAuth client と同じ project で進める方が審査・設定の分散を避けられるため、専用 project は作らない判断にした。
- Google Auth Platform Branding を保存した。
  - App name: `HoverPocket`
  - User support email / developer contact: `shotaro.matsu0311@gmail.com`
  - Privacy policy URL: `https://shotaro311.github.io/hover-pocket/privacy.html`
  - Authorized domain: `shotaro311.github.io`
- Google Auth Platform Audience を External / In production に変更した。
- Google Auth Platform Data Access に以下 2 スコープだけを保存した。
  - `.../auth/calendar.calendarlist.readonly`
  - `.../auth/calendar.events`
- Google Auth Platform の Branding verification で `https://shotaro311.github.io/hover-pocket/` が registered website として認識されなかったため、補助 public repo `shotaro311/shotaro311.github.io` を作成し、root 直下に同じ Search Console 確認ファイルと `/hover-pocket/` への最小 redirect `index.html` を追加した。
- `https://shotaro311.github.io/googlea0eda7d7223f8019.html` が 200 で確認ファイルを返すことを確認し、Search Console で root property `https://shotaro311.github.io/` も HTML file 方式で自動確認した。
- Branding の homepage URL は Google の ownership check を通すため、`https://shotaro311.github.io/` に変更した。root は `https://shotaro311.github.io/hover-pocket/` へ即時 redirect する。
- Branding issue の追加確認を経由して `https://console.cloud.google.com/auth/verification/submit?authuser=1&project=hoverpocket` まで到達した。

## 検証

- Pages API readback:
  - `shotaro311/hover-pocket`: `html_url=https://shotaro311.github.io/hover-pocket/`, `build_type=workflow`
  - `shotaro311/shotaro311.github.io`: `html_url=https://shotaro311.github.io/`, `source=main:/`, `status=built`
- Public URL readback:
  - `https://shotaro311.github.io/hover-pocket/`: HTTP 200
  - `https://shotaro311.github.io/hover-pocket/privacy.html`: HTTP 200
  - `https://shotaro311.github.io/hover-pocket/googlea0eda7d7223f8019.html`: HTTP 200
  - `https://shotaro311.github.io/googlea0eda7d7223f8019.html`: HTTP 200
- Search Console readback:
  - `https://shotaro311.github.io/hover-pocket/`: verified property opens the Performance page and shows "データを処理しています"。
  - `https://shotaro311.github.io/`: verified property opens the Performance page and shows "データを処理しています"。
- GitHub Releases readback:
  - `gh release edit v0.1.0-98 --latest` を実行し、old appcast path `releases/latest/download/appcast.xml` が macOS appcast を返す状態に戻した。
  - その後、別作業の build 112 release により latest は `v0.1.0-112` へ更新済み。
- Data Access readback:
  - 再読込後も `.../auth/calendar.calendarlist.readonly` と `.../auth/calendar.events` が表示され、Save / 変更破棄は disabled。
- Audience readback:
  - `公開ステータス 本番環境`
  - `ユーザーの種類 外部`
- Prepare for verification readback:
  - Branding summary、Data Access summary、scope table が表示される。
  - Blocker: "1 つ以上のリクエストされたスコープに次のフィールドがありません: スコープの理由, デモ動画。"
  - Scope reason textarea は入力できるが、YouTube video URL が空のため Data Access editor の Save が disabled。

## 未完了 / ブロッカー

- Google のフォームが demo video を必須としているため、YouTube URL がない限り final submit はできない。
- 既存の repo / Downloads / Movies / Desktop から HoverPocket OAuth demo video は見つからなかった。
- `youtube_list_videos` は現 Google MCP token の YouTube scope 不足で `invalid_scope` になった。
- 次に進めるには、OAuth 同意画面、Calendar panel の予定表示、予定作成/編集/削除、AI lane の承認後 Calendar 操作が映る YouTube 動画 URL が必要。
