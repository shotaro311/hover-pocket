---
project_slug: hover-pocket
date: 2026-07-06
worker: codex-w12
status: verified
scope: Windows security review F-1/F-2/F-3
---

# Windows Security Review W12

## Scope

- Source review: `docs/report/20260706-windows-security-privacy-review.md`.
- Fixed F-1, F-2, F-3 only. F-4 and F-5 are documentation/backlog items outside this worker scope.
- WebView2 event behavior was checked against current Microsoft Learn pages before implementation:
  `NavigationStarting` can cancel top-level navigation, and `NewWindowRequested` can be suppressed with `Handled=true`.

## Changes

- F-1: Added `--devtools` to `StartupOptions` and routed it into Panel and Settings WebView creation.
  `WebViewSecurityPolicy.ShouldEnableBrowserDebugFeatures()` enables DevTools and default context menus only for Debug builds or explicit `--devtools`.
  Release without the flag resolves both settings to disabled.
- F-2: Added shared `WebViewSecurityPolicy` checks for Panel and Settings.
  `NavigationStarting` allows only the configured virtual host (`app.hoverpocket.local` or `settings.hoverpocket.local`), cancels other navigations, and opens external `http(s)` URLs with the OS default browser.
  `NewWindowRequested` always sets `Handled=true` and opens only external `http(s)` URLs in the default browser.
  `--verify settings` covers the host allowlist, external browser routing decision, and `--devtools` flag parsing.
- F-3: Replaced AI lane audit entries with minimized metadata only:
  `timestamp`, `action`, `actionType`, `result`, `eventId`, `calendarId`.
  The audit log no longer stores action id, field keys, command text, title, location, notes, or free-form failure reason text.
  Write-time pruning deletes `ailane-YYYYMMDD.jsonl` files older than 90 days.
  `--verify ailane` covers minimized fields, forbidden content/properties, and 90-day retention pruning.
- Updated `windows/README.md` with the `--devtools` behavior and AI lane audit log retention/schema.

## Verification

- `dotnet build windows\HoverPocket.Windows.sln --nologo -p:NuGetAudit=false`
  - exit 0
  - warnings 0 / errors 0
- `dotnet build windows\HoverPocket.Windows.sln --nologo -c Release -p:NuGetAudit=false`
  - exit 0
  - warnings 0 / errors 0
- `dotnet run --project windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj --no-build -- --verify ailane`
  - exit 0
- `dotnet run --project windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj --no-build -- --verify ui-model`
  - exit 0
- `dotnet run --project windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj --no-build -- --verify settings`
  - exit 0
- `dotnet run --project windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj --no-build -- --verify shell`
  - exit 0
- `dotnet run --project windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -c Release --no-build -- --verify settings`
  - exit 0
- `git diff --check`
  - exit 0

## Architect follow-up

- `--verify ui` remains pending for the architect's normal desktop session.
  This sandbox has the known WebView2 renderer startup limitation, so W12 did not use it as a completion gate.
