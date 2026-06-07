---
project_slug: hover-menu-preview
date: 2026-06-07
updated_by: codex
status: active
---

# 2026-06-07 hover-menu-preview

## 実施内容

- Clipboard provider を追加し、テキスト履歴を左、画像履歴を右に表示する UI を実装。
- `NSPasteboard.general.changeCount` の軽量 polling で clipboard 変更を検出し、テキスト最大30件、画像最大20件を保存するようにした。
- 画像履歴を `Application Support/HoverMenuPreview/Clipboard` 配下に PNG として保存し、metadata を `history.json` に保存するようにした。
- テキスト/画像履歴のクリック再コピーと、外部アプリへの drag item provider を追加。
- Provider 表示順、表示/非表示、最後に開いた panel を使うかどうか、default panel を `AppSettings` に永続化。
- Settings に Panels セクションを追加し、表示する provider と default panel を選べるようにした。
- panel header の provider icon に Ctrl-click context menu を追加し、表示中 icon の順番を Move Left / Move Right で変更できるようにした。
- Clipboard の drag 開始直後に hover panel を一時的に隠し、Codex など drop 先アプリの入力欄を panel が邪魔しないようにした。
- 画像 drag payload を `public.png` data だけでなく file URL 起点の `NSItemProvider` に変更し、ファイル drop を期待する入力欄への互換性を高めた。
- Mirror provider に A案ベースの compact microphone check row を追加。ミラー下に1行で mic icon、`Mic Check`、12本バー式レベルメーター、入力名、一時録音/再生 button を表示。
- `MirrorMicrophoneModel` を追加し、Mirror microphone row 表示中は `AVAudioEngine` で入力レベルを自動計測するようにした。panel 非表示、Mirror inactive、設定OFFで microphone monitor は停止。
- microphone row の button は一時録音用に変更。`録音 -> 停止 -> 再生 -> 再生完了後にメモリから削除` の流れにし、audio file は作成しない。
- Settings の Mirror セクションに `Show microphone test under mirror` toggle を追加。
- generated app `Info.plist` に `NSMicrophoneUsageDescription` を追加。
- Google Calendar provider に日付クリックで詳細日を固定する動きを追加。
- 日別詳細ペインに予定追加、編集、削除の UI を追加。
- 編集フォームで title、開始/終了、終日、location、notes を変更できるようにした。
- `GoogleCalendarEventOccurrence` に Google 側 event ID、書き込み可能状態、notes を保持するようにした。
- Calendar API client に event 作成、部分更新、削除を追加。
- OAuth scope を `calendar.events.readonly` から `calendar.events` へ変更し、古い read-only credential は `needsReconnect` として扱うようにした。
- Settings / Calendar 接続画面に再接続表示を追加。
- preview panel が TextField / DatePicker の入力を受けられるよう、preview 用 `NSPanel` の key focus を許可した。
- アプリ名を `ノッチポッケ` に決定し、SwiftPM package / executable / generated app bundle の公開名を `NotchPokke` へ変更。bundle 表示名は `ノッチポッケ` にした。
- README を公開リポジトリ向けに更新し、Google OAuth client ID / secret は `.env.local` でローカル管理して source control に含めない前提を明記した。
- GitHub public repository `shotaro311/notch-pokke` を作成し、`main` を push した。
- README を日本語中心へ全面更新し、概要、機能、実行方法、Google Calendar 設定、表示先、実装メモ、ノッチサイズ、注意事項を日本語で読めるようにした。

## 検証

- `swift build`: 成功。
- `./script/check_google_calendar_setup.sh`: 成功。
- `git diff --check`: 成功。
- `./script/build_and_run.sh --verify`: 成功、`HoverMenuPreview launched` を確認。
- 2026-06-07 追加実装後: `swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。起動後 `CPU 0.0%` を確認。
- Clipboard drag 修正後: `swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- Mirror microphone check 追加後: `swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。`NSMicrophoneUsageDescription` の bundle 注入、起動後 `CPU 0.0%` を確認。
- Mirror microphone permission crash 修正後: `~/Library/Logs/DiagnosticReports/HoverMenuPreview-2026-06-07-160921.ips` を確認し、`MirrorMicrophoneModel.startEngine()` の `AVAudioEngine` tap closure が CoreAudio realtime queue 上で MainActor assert に当たっていたことを特定。
- Mirror microphone permission crash 修正後: `swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- Mirror microphone permission crash 修正後: 実機で microphone permission 許可直後に crash report が増えないこと、`BUG IN CLIENT` / `Assertion failed` が再発しないことを確認。
- Mirror microphone check 通常操作: panel を開いた状態で Start / Stop を座標操作し、`AVAudioEngine` start / stop と `setPlayState Started` / `Stopped Input` を unified log で確認。停止後 CPU は `0.3%` まで低下。
- Mirror microphone meter 無反応対策: input tap の format を `inputFormat(forBus:)` から `outputFormat(forBus:)` へ変更し、RMS 直線倍率ではなく dBFS ベースの正規化に変更。小さめの会話音量でも meter に出やすくした。
- Mirror microphone meter 無反応対策後: `swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- Mirror microphone auto-monitor / temp recording 実装後: `swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- Mirror microphone auto-monitor / temp recording 実装後: button 押下なしで `microphone tap format` と `AVAudioEngine start` が出ることを unified log で確認。panel 表示中は mic engine が維持され、panel 非表示で stop する。
- Mirror microphone temp recording: 座標操作で `recording started -> stopped -> playback started -> playback finished and cleared` を unified log で確認。crash report は増加なし。
- Mirror microphone button 操作後に panel が閉じない問題を修正。SwiftUI `onHover` の exit 取りこぼしを補うため、preview 表示中のみ window controller 側で mouse location を短周期監視し、hover region 外なら close を schedule するようにした。
- Mirror microphone button の反応改善として、preview open animation 中の `ignoresMouseEvents` を 0.06秒後に解除し、録音ボタンの hit area を 20pt から 30pt に拡大。
- Mirror microphone button / close 修正後: `swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。録音ボタン押下後に画面外へ移動し、`microphone temp recording started` の直後に `AVAudioEngine stop` と `camera session stopped` が出ること、panel が画面から消えることを確認。
- `ノッチポッケ` rename / GitHub 公開準備後: `swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。generated app bundle は `NotchPokke.app`、process は `NotchPokke` で起動することを確認。`.env.local` は ignore 済みで、公開対象 tracked files に実OAuth値やtokenがないことを確認。
- GitHub 公開後: `gh repo view shotaro311/notch-pokke` で visibility `PUBLIC`、default branch `main`、URL `https://github.com/shotaro311/notch-pokke` を確認。
- README 日本語対応後: `git diff --check` 成功。

## 未完了 / 注意

- 実 Google アカウントでの write scope 追加同意は、OAuth callback 待ちで停止したため未完了。アプリ側は `needsReconnect` を表示し、再接続後に書き込み API を使う。
- 実カレンダーへの一時イベント作成・削除テストは、追加同意完了後に実行する。
- クリップボードの自動検証は、ユーザーの現在の clipboard 内容を壊す可能性があるため未実施。手動でテキスト/画像 copy、再コピー、Codex chat 欄など外部アプリへの drag/drop を確認する。
- 再ビルド後の ad-hoc 署名では camera / microphone permission prompt が再表示されることがある。配布時は安定した署名で確認する。
- 公開 GitHub repository には `.env.local`、OAuth client secret、token 類を含めない。
