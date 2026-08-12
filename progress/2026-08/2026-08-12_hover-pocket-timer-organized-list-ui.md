---
project_slug: hover-menu-preview
date: 2026-08-12
status: completed
updated_by: codex
---

# macOS Timer Organized List UI

## 対象

- ユーザー確定のUI案をmacOS Timerへ実装する。
- 上段の設定済み／実行中項目を、複数追加できるコンパクトな1列リストにする。
- 上段と下段の設定UIを、別セクションとして認識できるよう整理する。
- ストップウォッチとTimerのアイコンを形から識別できるようにする。

## 実装

- 「実行中」を独立したgraphite surfaceで囲み、件数badgeを追加した。
- ストップウォッチ、Timer、Pomodoroを高さ38ptの横長1行カードへ統一した。種類、設定名、残り時間または経過時間、phase / cycle、pin、pause / resume、stopを同じ基準線へ配置した。
- macOSの実行中カウントダウン上限を2件から4件へ拡張し、ストップウォッチ1件とTimer 2件 + Pomodoro 2件を同時表示できるようにした。Windows版の上限と実装は変更していない。
- 下段へcyan accent lineと「新しく追加」見出しを置き、ストップウォッチ、Timer、Pomodoroの3カードを同じ高さ174ptで横並びにした。
- 3カードすべてへ「名前を設定（任意）」入力欄と、左上アイコンから開く4色メニューを追加した。従来の色ドット列は削除した。
- ストップウォッチ用draftへ名前と色を追加し、開始時に実行中stateへ引き継ぐようにした。既存`drafts.json`にstopwatch fieldがなくても既定値へ移行する。
- 種類アイコンを、ストップウォッチ=`stopwatch.fill`、Timer=`hourglass`、Pomodoro=`target`へ分けた。実行中リストと追加カードの両方で同じ形を使う。
- Timer / Pomodoroのsound、直接時間入力、調整rail、開始、リセット、pin、pause / resume、stop、Pomodoro cycle表示、alert停止を維持した。
- READMEとrequirementsをmacOS新仕様へ同期した。

## 検証

- `swift build`: 成功。
- `.build/debug/HoverPocket --verify-timer --render-timer-preview`: `timer_verify=ok`。
  - defaults / formatting / progress / lifecycle / pin / storage isolation /旧draft migration / stopwatch: すべて`ok`。
  - Timer 2件 + Pomodoro 2件、5件目の開始拒否: `timer_concurrency=ok`。
  - 3種類のSF Symbols非重複: `timer_icon_identity=ok`。
  - 3カード横並び: Small `157.3pt`、Medium `184.0pt`、Large `210.7pt`、Extra Large `237.3pt`、すべて`true`。
  - compact metrics: `runningCardHeight=38pt`、`runningCardSpacing=4pt`、`setupCardHeight=174pt`、`true`。
- `.build/debug/HoverPocket --verify-panel-layout`: 112 cases、4 panel sizes / text sizes / settings persistence、すべて成功。
- `dist/verification/timer-stopwatch-small-preview.png`: 5件の1行リストに横はみ出し、重なりなし。下段は縦スクロールで到達する。
- `dist/verification/timer-stopwatch-large-preview.png`: 上段と「新しく追加」の境界、3種類の色付きアイコン、入力欄を確認。下端操作は縦スクロールで到達する。
- `dist/verification/timer-stopwatch-extraLarge-preview.png`: 5件の1行リスト、section separator、3カード、全操作が同一画面内に収まることを目視確認した。
- `./script/build_and_run.sh --verify`: Apple Development署名済み`dist/HoverPocket.app`を生成し、通常起動を確認した。
- `codesign --verify --deep --strict --verbose=2 dist/HoverPocket.app`: valid on disk / satisfies Designated Requirement。
- 製品bundle内`--verify-timer`: すべて成功。
- 実行中process: `/Users/shotaro/code/share/hover-menu-preview/dist/HoverPocket.app/Contents/MacOS/HoverPocket`。
- `git diff --check`: 成功。

## 配信境界

- GitHub Release、macOS appcast、`/Applications/HoverPocket.app`、Windows版は変更していない。
