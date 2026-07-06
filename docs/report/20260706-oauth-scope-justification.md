---
project_slug: hover-pocket
target: Google OAuth scope justification for verification
created: 2026-07-06
updated_by: codex-w14
status: draft-for-review
related:
  - docs/plan/20260706_oauth_verification_execution.md
  - docs/plan/20260706_google_oauth_verification_roadmap.md
  - windows/src/HoverPocket.Shell/Services/GoogleOAuthService.cs
  - windows/src/HoverPocket.Shell/Providers/Calendar/GoogleCalendarApiClient.cs
---

# Google OAuth スコープ理由説明

## 前提

- W13 の最終進捗ファイル `progress/2026-07/2026-07-06_windows-oauth-w13.md` を確認した。
- Windows 実装の新規要求スコープは次の2つに最小化済みである。
  - `https://www.googleapis.com/auth/calendar.events`
  - `https://www.googleapis.com/auth/calendar.calendarlist.readonly`
- 旧 `https://www.googleapis.com/auth/calendar.readonly` を持つ保存済み token は、既存ユーザー互換のために受け入れる。新規の OAuth 同意画面へ登録するスコープではない。

## 公式仕様で確認した範囲

- Google Calendar API のスコープ一覧では、`calendar.events` は「すべてのカレンダーの予定を表示および編集する」スコープとして説明されている。
- `Events: insert` の認可スコープには `calendar.events` が含まれている。
- `CalendarList: list` の認可スコープには `calendar.readonly`、`calendar`、`calendar.calendarlist`、`calendar.calendarlist.readonly` が含まれており、`calendar.events` は含まれていない。
- W13 は CalendarList 用に、広い `calendar.readonly` ではなく、より用途が限定された `calendar.calendarlist.readonly` を採用した。
- Google の sensitive scope verification では、機能に必要な最小権限だけを要求し、受け取った Google API データをアプリ内表示・プライバシーポリシーで説明した用途に限定する必要がある。

## 提出用サマリ

HoverPocket is a desktop utility panel. Its Google Calendar integration is visible to the user in the Calendar panel and AI lane. The app uses Google Calendar data only to show the user's calendar events inside the panel and to create, edit, or delete calendar events after explicit user action or approval. HoverPocket stores the Google refresh token in Windows Credential Manager, keeps access tokens in memory only, and does not sell, transfer, or use Google Calendar data for advertising.

## Scope: `https://www.googleapis.com/auth/calendar.events`

### どの機能で使うか

- Calendar パネルの月表示、日付ホバー/選択時の予定表示。
- Calendar パネルからの予定作成、編集、削除。
- AI lane で自然文から作成されたカレンダー操作候補を、ユーザーが承認した後に実行する処理。

### なぜ必要か

HoverPocket needs to read and modify calendar events that the signed-in user can access. The Calendar panel displays events for selected dates and lets the user create, edit, and delete events on writable calendars. The AI lane can prepare a calendar action from a short natural-language command, but the action is executed only after user approval. The `calendar.events` scope is required because event creation and event changes cannot be performed with a read-only event scope.

### 審査フォーム向け文面

HoverPocket requests `https://www.googleapis.com/auth/calendar.events` to display the user's calendar events in the app's Calendar panel and to let the user create, edit, or delete events from that panel. The same scope is used when the AI lane prepares a calendar action; HoverPocket shows an approval card and performs the event operation only after the user confirms it. The app does not use this data for advertising, analytics, resale, or any background purpose outside the visible Calendar and AI-lane features.

## Scope: `https://www.googleapis.com/auth/calendar.calendarlist.readonly`

### どの機能で使うか

- Google Calendar のカレンダー一覧取得。
- 各カレンダーの ID、表示名、選択状態、primary 状態、アクセス権限を読み、表示対象と書き込み可否を判断する処理。

### なぜ必要か

The current Windows implementation calls the CalendarList API to discover which calendars the user has and what access role the user has for each calendar. This is needed so HoverPocket can show events from the user's selected calendars and avoid offering create, edit, or delete controls on calendars that are read-only for that user. The `CalendarList: list` endpoint does not list `calendar.events` as an allowed authorization scope, so HoverPocket requests `calendar.calendarlist.readonly`, the narrower calendar-list read scope, for this feature.

### 審査フォーム向け文面

HoverPocket requests `https://www.googleapis.com/auth/calendar.calendarlist.readonly` to read the user's list of subscribed calendars and calendar-list metadata, including calendar IDs, display names, selected/primary status, and access roles. HoverPocket uses this information to show the correct calendars in the Calendar panel and to prevent event editing controls on calendars where the signed-in user does not have write access. HoverPocket does not use this scope to download event contents, run a background service, advertise, sell data, or transfer data to third parties.

## 旧 `calendar.readonly` 互換注記

W13 以前に接続したユーザーの保存済み credential は、`calendar.readonly` を含む場合がある。
Google Calendar API 上では `calendar.readonly` でも CalendarList.list を呼べるため、Windows 実装は既存 token を互換的に受け入れる。
ただし、Google Cloud Console の Data Access に新規登録するスコープは `calendar.events` と `calendar.calendarlist.readonly` の2つだけにする。

## 提出前チェック

- Google Cloud Console の Data Access には `calendar.readonly` を追加しない。
- アプリのデモ動画や申請文面では、CalendarList 取得を「カレンダー一覧・アクセス権確認のため」と説明し、予定本文の読み取り目的として説明しない。
- もし将来 `CalendarList.list` を使わない設計へ変える場合は、この文書と Cloud Console の scope 登録を再確認する。

## 公式参照

- Google Calendar API scopes: https://developers.google.com/workspace/calendar/api/auth
- Events: insert authorization scopes: https://developers.google.com/workspace/calendar/api/v3/reference/events/insert
- CalendarList: list authorization scopes: https://developers.google.com/workspace/calendar/api/v3/reference/calendarList/list
- Sensitive scope verification: https://developers.google.com/identity/protocols/oauth2/production-readiness/sensitive-scope-verification
- Google API Services User Data Policy: https://developers.google.com/terms/api-services-user-data-policy
