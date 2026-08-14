---
project_slug: hover-menu-preview
date: 2026-08-12
status: completed
updated_by: codex
---

# Cross-platform Multiple Stopwatches and Timer UI

## 対象

- macOSのストップウォッチを複数追加できるようにする。
- Windowsへ、macOSと同じ「実行中」1列リストと「新しく追加」3カードのTimer UIを展開する。
- ストップウォッチ、タイマー、ポモドーロをアイコン形状でも識別できるようにする。
- 両OSの検証後、macOS SparkleとWindows Velopackを別channelで公開する。

## 実装

- macOSの単一ストップウォッチstateを、名前、色、経過時間、開始日時を個別に持つ`RunningStopwatch`配列へ移行した。開始、一時停止、再開、停止をID単位で扱い、最大4件まで同時実行できる。
- Windowsへ`StopwatchPreset`と複数`RunningStopwatch`を追加し、bridgeをID単位のstart / pause / resume / stopへ更新した。実行中ストップウォッチはアプリ稼働中だけ保持し、draftは既存Timer / Pomodoro設定とともに保存する。
- Windowsのカウントダウン上限を2件から4件へ揃え、ストップウォッチ4件とは別枠で扱う。
- Windows Timerを、上段のコンパクトな1列リストと下段の3追加カードへ再構成した。カードは「名前を設定（任意）」、左上アイコンの4色メニュー、直接入力、時間rail、sound、start、pinを維持する。
- 種類アイコンをストップウォッチ、砂時計、ターゲットへ分けた。Windows実行中タイマーのpin操作も維持した。
- Windows 0.2.7へ版上げし、Windows runnerでRelease buildとtimer / ui-model / updater / WebView UIを確認するworkflowを追加した。
- README、Windows README、requirementsを両OS共通仕様へ同期し、公開ダウンロード導線をWindows 0.2.7へ切り替えた。

## 検証

- macOS `swift build`: 成功。
- macOS `--verify-timer --render-timer-preview`: defaults、旧draft migration、複数ストップウォッチ、カウントダウン4件、5件目拒否、アイコン非重複、3カード横並び、compact metricsがすべて成功。
- macOS `--verify-panel-layout`: 112 cases、Small `520x372`からExtra Large `760x546`まで成功。
- `./script/build_and_run.sh --verify`: Apple Development署名済みappを生成し、通常起動に成功。製品bundle内`--verify-timer`と`codesign --verify --deep --strict`も成功。
- Windows `dotnet build --configuration Release -p:EnableWindowsTargeting=true`: .NET 10 SDKでwarnings 0 / errors 0。
- Windows JavaScript syntax checkと`git diff --check`: 成功。
- in-app browserでWindows Timerを600x430と520x372で描画し、ストップウォッチ2件 + カウントダウン4件、実行中pin 4件、追加カード3件、placeholder 3件を確認した。両サイズともsection overlapと横overflowはなく、カード高188px、必要な範囲だけ縦スクロールする。
- 「配信テスト」とorangeを指定した3件目のストップウォッチ追加に成功し、console warning / errorは0件。
- Windows旧`drafts.json`からTimer / Pomodoro設定を維持したままStopwatch draftを補う移行テストと、4件開始 + 5件目拒否のテストを追加した。
- GitHub ActionsのWindows runnerでRelease build、timer / ui-model / updater / WebView UIを含む全工程が成功した。最終runは[`31572544363`](https://github.com/shotaro311/hover-pocket/actions/runs/31572544363)。

## 配信状態

- 共通source commit `fefc4c6`を`origin/main`へpushした。
- macOSをGitHub Latest [`v0.1.0-168`](https://github.com/shotaro311/hover-pocket/releases/tag/v0.1.0-168)へ公開した。Apple公証submission `bae039ba-df8b-4215-93a5-6be3b51b83cb`は`Accepted`で、staple、Developer ID署名、Gatekeeper、公開ZIPの再取得とSHA-256一致を確認した。`macos-latest` appcastはbuild 168とversioned ZIPを返す。
- `/Applications/HoverPocket.app`を公開版`0.1.0 (168)`へ再インストールし、旧build 161は`~/.Trash/HoverPocket-before-build-168.app`へ退避した。インストール後の署名、公証staple、Gatekeeper、公開ZIP展開物との実行ファイルSHA-256一致、通常起動を確認した。
- Windowsを専用release [`win-v0.2.7`](https://github.com/shotaro311/hover-pocket/releases/tag/win-v0.2.7)へ`latest=false`で公開した。release targetは`fefc4c6`、8 assetの公開URL再取得、GitHub digest、ローカル生成物のsize / SHA-256一致、`SHA256SUMS-win.txt`、manifest、`releases.win.json`を確認した。
- Windows公開後もGitHub LatestはmacOS `v0.1.0-168`、macOS appcast SHA-256は`bcf3a215...986d72`のままで、Windows feedは0.2.7 full packageを返す。Windows 0.2.xは方針どおりAuthenticode未署名。
- 配布サイトをCloudflare Worker version `1522796a-4b37-4740-b926-196dd07ce836`へ公開した。正規ドメインと旧aliasはHTTP 200でWindows 0.2.7 Setupリンクを返し、公開HTML SHA-256 `3df416a9...97dc9`はローカル`site/index.html`と一致した。GitHub Pages run [`31573675904`](https://github.com/shotaro311/hover-pocket/actions/runs/31573675904)も成功した。
