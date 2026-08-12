---
project_slug: hover-menu-preview
date: 2026-08-12
status: active
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
- README、Windows README、requirementsを両OS共通仕様へ同期した。公開ダウンロード導線は0.2.7公開後に切り替える。

## 検証

- macOS `swift build`: 成功。
- macOS `--verify-timer --render-timer-preview`: defaults、旧draft migration、複数ストップウォッチ、カウントダウン4件、5件目拒否、アイコン非重複、3カード横並び、compact metricsがすべて成功。
- macOS `--verify-panel-layout`: 112 cases、Small `520x372`からExtra Large `760x546`まで成功。
- `./script/build_and_run.sh --verify`: Apple Development署名済みappを生成し、通常起動に成功。製品bundle内`--verify-timer`と`codesign --verify --deep --strict`も成功。
- Windows `dotnet build --configuration Release -p:EnableWindowsTargeting=true`: .NET 10 SDKでwarnings 0 / errors 0。
- Windows JavaScript syntax checkと`git diff --check`: 成功。
- in-app browserでWindows Timerを600x430と520x372で描画し、ストップウォッチ2件 + カウントダウン4件、実行中pin 4件、追加カード3件、placeholder 3件を確認した。両サイズともsection overlapと横overflowはなく、カード高188px、必要な範囲だけ縦スクロールする。
- 「配信テスト」とorangeを指定した3件目のストップウォッチ追加に成功し、console warning / errorは0件。
- Windows旧`drafts.json`からTimer / Pomodoro設定を維持したままStopwatch draftを補う移行テストと、4件開始 + 5件目拒否のテストを追加した。Windows runnerでの実行待ち。

## 配信状態

- 実装とローカル検証は完了した。
- source commitのpush、Windows runner、macOS公証、GitHub Releases、各OS feedと公開成果物のreadbackは未実施。
