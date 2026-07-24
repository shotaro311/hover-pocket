# 2026-07-17 HoverPocket Hover Panel Recovery

## Summary

- Investigated a running build 127 instance that no longer opened the panel on hover.
- Confirmed that the process and 520x12 top-edge access window still existed while the 680x488 preview stayed hidden.
- Restarting the unchanged public app restored hover behavior, pointing to stale runtime input/window state rather than OAuth or persisted settings.
- Added independent hover detection and automatic access-window recovery to prevent the same runtime state from persisting.

## Implementation

- Kept the existing SwiftUI `.onHover` path for immediate response.
- Added a 0.12-second AppKit access monitor that compares `NSEvent.mouseLocation` with every visible access-window frame and opens the matching display's preview when needed.
- Added a 2-second health check for expected display count, access style, visibility, and frame placement. An unhealthy access-window set is rebuilt automatically.
- Added recovery observers for:
  - macOS wake.
  - login session reactivation after screen lock or user switching.
  - display-parameter changes.
  - ordinary app activation as a lightweight health-check opportunity.
- System-transition recovery rebuilds immediately and retries after 0.45 and 1.4 seconds so it also covers delayed `NSScreen` stabilization.
- Added the internal `--verify-hover-recovery` launch argument. It disables only the original direct `.onHover` opening path, allowing the independent polling fallback to be verified in isolation.

## Verification

- `swift build`: passed.
- `.build/debug/HoverPocket --verify-panel-layout`: passed, 63 provider/layout cases.
- `.build/debug/HoverPocket --verify-calculator`: passed, result `25`, history count `1`.
- `.build/debug/HoverPocket --verify-clipboard`: passed, favorites and cleanup checks all green.
- `./script/build_and_run.sh --verify`: development bundle built, signed, and launched.
- `git diff --check`: passed.
- Polling-only GUI readback:
  - Before hover: access window onscreen, preview offscreen.
  - Cursor at screen point 1280,3: preview window `680x488` changed to onscreen even though direct SwiftUI hover opening was disabled.
  - Cursor restored: preview changed back to offscreen; access window remained onscreen.
- Normal GUI readback: `normal_preview_before=false`, `normal_preview_hover=true`, `normal_preview_after=false`.

## Release State

- No GitHub release, appcast update, notarization submission, or `/Applications` replacement was performed.
- Public build 127 remains unchanged.
- The verified development build is running from `dist/HoverPocket.app` for local confirmation.
- A public fix requires the normal next-build release flow: release build, Developer ID signing, notarization/stapling, GitHub Release upload, appcast update, and remote readback.
