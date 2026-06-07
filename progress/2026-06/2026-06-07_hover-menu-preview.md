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
- Google Calendar provider に日付クリックで詳細日を固定する動きを追加。
- 日別詳細ペインに予定追加、編集、削除の UI を追加。
- 編集フォームで title、開始/終了、終日、location、notes を変更できるようにした。
- `GoogleCalendarEventOccurrence` に Google 側 event ID、書き込み可能状態、notes を保持するようにした。
- Calendar API client に event 作成、部分更新、削除を追加。
- OAuth scope を `calendar.events.readonly` から `calendar.events` へ変更し、古い read-only credential は `needsReconnect` として扱うようにした。
- Settings / Calendar 接続画面に再接続表示を追加。
- preview panel が TextField / DatePicker の入力を受けられるよう、preview 用 `NSPanel` の key focus を許可した。

## 検証

- `swift build`: 成功。
- `./script/check_google_calendar_setup.sh`: 成功。
- `git diff --check`: 成功。
- `./script/build_and_run.sh --verify`: 成功、`HoverMenuPreview launched` を確認。
- 2026-06-07 追加実装後: `swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。起動後 `CPU 0.0%` を確認。
- Clipboard drag 修正後: `swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。

## 未完了 / 注意

- 実 Google アカウントでの write scope 追加同意は、OAuth callback 待ちで停止したため未完了。アプリ側は `needsReconnect` を表示し、再接続後に書き込み API を使う。
- 実カレンダーへの一時イベント作成・削除テストは、追加同意完了後に実行する。
- クリップボードの自動検証は、ユーザーの現在の clipboard 内容を壊す可能性があるため未実施。手動でテキスト/画像 copy、再コピー、Codex chat 欄など外部アプリへの drag/drop を確認する。
