---
project_slug: hover-pocket
target: Windows Phase 2 W8 hover open/close stability
date: 2026-07-06
worker: codex-w8
status: automated-verified
---

# Windows Phase 2 W8 hover open/close stability

## Scope

- Changed only W8-allowed implementation areas: `Windows/`, `Display/`, and `Verification/`.
- Did not touch provider UI, Calendar, Clipboard, updater implementation, or git commit/push.

## Cause Analysis

- Code trace found that `HoverShellController.PollPointer()` re-entered `ShowPanelAsync()` while the panel was already visible but still opening because it checked `_panel.Opacity < 0.99`.
- That re-entry used the current pointer to resolve layout again, so an opening panel could restart its animation and re-anchor from a new cursor-derived layout.
- `ResyncDisplayLayout()` also replaced `_activeLayout` with `ResolveLayoutForPointer()` while the panel was visible, which violated the contract that the open display stays fixed until an explicit size/display resync.
- Close detection mixed the intent of "origin or panel rect" with live HWND lookup. The cursor position and HWND rect were both physical px, but the verifier had no way to force the same path deterministically, and the open animation race could keep the panel visible.
- While extending `--verify shell`, the first run reproduced a concrete movement failure: `panel stability` reported the panel moving from physical `(2351,14)` to `(2123,14)` while simulated pointer remained inside. That exposed a verifier/open race where the normal polling timer could fire a fire-and-forget open before the verify open awaited animation completion.

## Fix

- Stopped visible-panel re-open from polling. `PollPointer()` now only opens when the panel is not visible; while visible it only keeps open or starts the close delay.
- Stopped access-surface `MouseEnter` from re-opening/re-anchoring the panel while the panel is already visible.
- Preserved `_activeLayout` while the panel is visible. Display resync now rematches the previous display instead of resolving by current cursor position; size changes still reapply the new panel target for that same display.
- Unified hover-region checks to active layout physical rectangles: active access surface or active panel target, each inflated by `HoverToleranceDips` converted to physical px per monitor scale.
- Added `HOVERPOCKET_HOVER_TRACE` optional file tracing for pointer coordinate, active/access/panel rectangles, and open/close decisions. It is disabled by default.
- Added verify-only pointer simulation hooks so shell verification can exercise the same polling/close path without moving the real mouse.
- Paused normal polling during verify open/close helpers to avoid the polling timer racing deterministic verifier calls.

## Verification

- `dotnet build windows\HoverPocket.Windows.sln --nologo`: exit 0 before later parallel W10/W11 files entered the current tree. Warnings: NuGet vulnerability feed could not be read from `https://api.nuget.org/v3/index.json`.
- Extended `--verify shell` with:
  - stable panel `Left/Top` check while simulated pointer moves inside the panel;
  - simulated pointer outside active access/panel region causing close through the 0.06s delay path.
- `dotnet run --no-build --project windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify shell`: exit 1 before the verifier-open polling pause fix; failure evidence was the movement repro above plus outside close remaining visible.
- After the verifier-open polling pause fix, current full build is blocked by parallel W10/W11 work outside W8 scope:
  - `Services\GoogleOAuthService.cs`: missing `HttpClient`.
  - `Providers\Calendar\GoogleCalendarApiClient.cs`: missing `HttpRequestMessage`, `HttpMethod`, `StringContent`, etc.
  - `Services\UpdaterService.cs`: duplicate `UpdaterCheckResult.UpdateAvailable`, `Downloaded`, and `Applying`.
- NuGet HTTPS through Windows Schannel also failed with `SEC_E_NO_CREDENTIALS`; Python/OpenSSL could fetch NuGet, and a local temp source was used to restore W11 `Velopack`, but compile then stopped on the unrelated Calendar/Updater errors above.
- Because the current worktree does not build due to W8-out-of-scope files, the required final verify matrix (`shell`, `display`, `ui-model`, `calc`, `timer`, `sticky`, `settings`, `ailane`) is not complete yet.

## Continuation 2026-07-06

- Rechecked current worktree. W8 code markers remain present: no `Opacity < 0.99` re-open path, no old `IsInsideInflatedWindow` HWND live-rect helper, `HOVERPOCKET_HOVER_TRACE` is present, and `--verify shell` reports `stable_position=true, outside_close=true` on success path.
- `dotnet build windows\HoverPocket.Windows.sln --nologo --no-restore`: still exit 1 before W8 verification can run.
- Current blocking errors remain outside W8 scope:
  - `Services\UpdaterService.cs`: duplicate `UpdaterCheckResult.UpdateAvailable`, `Downloaded`, and `Applying`.
  - `Services\GoogleOAuthService.cs`: missing `HttpClient`.
  - `Providers\Calendar\GoogleCalendarApiClient.cs`: missing `HttpClient`, `HttpRequestMessage`, `HttpMethod`, `StringContent`.
- W8 did not edit those files because the task contract limits changes to `Windows/`, `Display/`, `Verification/`, and `progress/`.

## Final Verification

- After the parallel compile blockers cleared, `dotnet build windows\HoverPocket.Windows.sln --nologo --no-restore` completed with exit code 0, warnings 0, errors 0.
- A build retry was needed once because `HoverPocket.Shell.exe` was locked by a previous verifier process; after the required wait and cleanup, the retry passed.
- `dotnet run --no-build --project windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify shell`: exit code 0.
  - Evidence: `PASS shell verify: windows=11, cycles=25, stable_position=true, outside_close=true`.
- Existing verifier regression:
  - `--verify display`: exit code 0.
  - `--verify ui-model`: exit code 0.
  - `--verify calc`: exit code 0.
  - `--verify timer`: exit code 0.
  - `--verify sticky`: exit code 0.
  - `--verify settings`: exit code 0.
  - `--verify ailane`: exit code 0.
- `git diff --check -- windows\src\HoverPocket.Shell\Windows windows\src\HoverPocket.Shell\Display windows\src\HoverPocket.Shell\Verification progress`: exit code 0.
- WebView2 `--verify ui` remains architect-run, and real mouse hover feel remains user confirmation.

## User / Architect Confirmation Needed

- Real mouse feel remains unverified by W8 and should be checked by the user after the parallel Calendar/Updater build blockers are resolved and the verify matrix can run.
