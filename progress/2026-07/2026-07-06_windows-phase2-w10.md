---
project_slug: hover-pocket
date: 2026-07-06
worker: W10
task: Windows Phase 2 Google Calendar provider
status: implemented; verified; real-account-e2e-pending
---

# Windows Phase 2 W10: Google Calendar Provider

## Scope

- Implemented a Windows Google Calendar provider under `Providers/Calendar/` and `windows/ui/providers/calendar/`.
- Added Desktop-app OAuth with OS default browser, loopback redirect on `127.0.0.1:<ephemeral port>`, and PKCE S256.
- Read OAuth client configuration from user-managed `%APPDATA%\HoverPocket\oauth.json`.
- Stored refresh tokens in Windows Credential Manager through Win32 generic credentials. Access tokens stay in memory only.
- Added Calendar API v3 REST direct calls for calendar list, month event list, event create, event update, and event delete.
- Added the month UI model and renderer: 42-cell grid, today/selected/has-event state, hover preview, click selection, double-click default 09:00-10:00 draft, edit, delete with confirmation, and read-only calendar guards.
- Connected the AI lane calendar read/create actions to the real Calendar store while preserving the existing approval flow and unauthenticated guidance.
- Fixed the Calendar verifier loopback check to avoid WPF UI-thread deadlock during async `HttpClient` verification.
- Changed read-only create/update/delete guards to return provider failure state instead of leaking bridge exceptions, and added offline verifier coverage for read-only create rejection.

## Official-doc decisions

- Google OAuth follows the installed/native app guidance: use the system browser, a loopback redirect URI, and PKCE S256.
- Scopes are `https://www.googleapis.com/auth/calendar.events` plus `https://www.googleapis.com/auth/calendar.readonly`.
  - `calendar.events` is needed for event CRUD.
  - `calendar.readonly` is used for calendar list and read-only calendar metadata.
  - Full calendar account scopes were not used.
- Credential storage uses Win32 `CredWrite` / `CredRead` / `CredDelete` generic credentials instead of `PasswordVault`, because W10 requires Windows Credential Manager verification with a real write/read/delete verification entry.

## User setup

No client ID or client secret was committed or logged.

Expected file:

```json
{
  "installed": {
    "client_id": "YOUR_DESKTOP_CLIENT_ID",
    "client_secret": "YOUR_DESKTOP_CLIENT_SECRET"
  }
}
```

Alternative flat shape is also accepted:

```json
{
  "client_id": "YOUR_DESKTOP_CLIENT_ID",
  "client_secret": "YOUR_DESKTOP_CLIENT_SECRET"
}
```

Place the file at `%APPDATA%\HoverPocket\oauth.json`.

## Verification

- `dotnet build windows\HoverPocket.Windows.sln --nologo -p:NuGetAudit=false`
  - Exit code: 0
  - Warnings: 0
  - Errors: 0
- `windows\src\HoverPocket.Shell\bin\Debug\net10.0-windows\HoverPocket.Shell.exe --verify calendar`
  - Exit code: 0
  - Covered OAuth authorization URL and PKCE generation, loopback listener, Credential Manager verification write/read/delete, Calendar API CRUD request construction, offline month-grid model checks, and read-only guard checks.
- `windows\src\HoverPocket.Shell\bin\Debug\net10.0-windows\HoverPocket.Shell.exe --verify ailane`
  - Exit code: 0
- `windows\src\HoverPocket.Shell\bin\Debug\net10.0-windows\HoverPocket.Shell.exe --verify ui-model`
  - Exit code: 0
- `node --check windows\ui\providers\calendar\calendar.js`
  - Exit code: 0
- `node --check windows\ui\js\app.js`
  - Exit code: 0
- `node --check windows\ui\js\i18n.js`
  - Exit code: 0

Note: a plain `dotnet build windows\HoverPocket.Windows.sln --nologo` previously completed but emitted NuGet warning `NU1900` because `https://api.nuget.org/v3/index.json` could not be loaded for package vulnerability data. The warning-free build above used `NuGetAudit=false` after restore to keep W10 validation independent from the transient audit feed.

## Pending

- Real Google account E2E is pending architect/user setup of `%APPDATA%\HoverPocket\oauth.json`.
- WebView2 runtime interaction verification is pending architect desktop-session execution.

## E2E checklist after oauth.json placement

1. Open HoverPocket and select Calendar.
2. Use the provider setup card to connect Google Calendar.
3. Confirm the OS default browser opens, Google consent completes, and the loopback page reports completion.
4. Confirm the Calendar provider shows the month grid immediately and then loads events in the background.
5. Double-click a writable day to create a 09:00-10:00 event, edit it, then delete it after the confirmation dialog.
6. Confirm read-only calendars cannot be edited or deleted.
7. In the AI lane, read a day calendar summary, then create an event through the approval card and confirm the audit flow remains intact.
