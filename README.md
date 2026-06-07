# Hover Menu Preview

macOS hover prototype. It places a small black pill at the top of the screen and opens a dark preview panel when the mouse hovers over the text.

## Run

```bash
./script/build_and_run.sh
```

Use `./script/build_and_run.sh --verify` to build, launch, and confirm the process exists.

## Current features

The app currently ships with built-in `Mirror`, `Calendar`, and `Clipboard` providers.

- Hover the notch handle to open the preview panel.
- The app preconfigures the camera session when access is already granted, but starts the Mac camera only while the mirror preview is active.
- The camera preview is horizontally mirrored so it behaves like a real mirror.
- Closing the panel stops the camera session.
- The first use may show the macOS camera permission prompt.

Calendar:

- Hover a date to preview that day's events.
- Click a date to pin that day's schedule in the detail pane.
- Add events from writable calendars.
- Edit event title, time, all-day state, location, and notes.
- Delete events from writable calendars.

Clipboard:

- Text clipboard history appears in the left column.
- Image clipboard history appears in the right column.
- Click an item to copy it back to the clipboard.
- Drag text or image items into another app.
- Images are stored locally under Application Support.

Panel settings:

- Show or hide built-in providers from Settings.
- Choose whether the last used panel should reopen by default.
- Control-click a provider icon in the panel header to move it left or right.

## Project path

```text
/Users/shotaro/code/share/hover-menu-preview
```

## Implementation note

SwiftUI's `MenuBarExtra` is mainly click-driven and only appears in the standard right-side menu bar area. This prototype uses AppKit `NSPanel` windows plus SwiftUI hover handlers so the trigger can sit at the top center like the reference recording.

## Architecture note

The app is now structured as a notch shell with provider-hosted content. The current visible content is intentionally not a sessions/usage demo anymore; real features should be added as providers.

```text
Sources/HoverMenuPreview/
  App/         app delegate and launch wiring
  Windowing/   NSPanel creation, notch geometry, hover close, animation timing
  State/       panel visibility and provider selection/loading state
  Models/      plugin IDs, manifests, permissions, snapshots, preview content
  Providers/   NotchProvider protocol and ProviderRegistry
  Views/       pill, panel shell, plugin host, shared controls
  Support/     reusable shapes and small helpers
```

Keep `Windowing` responsible for AppKit windows, screen/notch measurements, and open/close animation. Provider implementations should not touch `NSPanel`, `NSApp`, or screen coordinates.

Add future features by implementing `NotchProvider`, registering them in `ProviderRegistry`, and rendering through `PluginHostView`. Start with compiled-in providers. If external plugins are needed later, prefer helper process / XPC / JSON-RPC returning `manifest + snapshot`, while the app keeps control of rendering and permissions.

## Google Calendar provider

The Calendar provider uses Google's installed app OAuth flow with a loopback redirect and PKCE. No Google token or client secret is stored in source control.

Create a local `.env.local` from `.env.example`:

```bash
GOOGLE_CLIENT_ID="YOUR_DESKTOP_OAUTH_CLIENT_ID.apps.googleusercontent.com"
GOOGLE_CLIENT_SECRET="YOUR_DESKTOP_OAUTH_CLIENT_SECRET"
GOOGLE_OAUTH_CHROME_PROFILE="Default"
```

To create the OAuth client in the active `gcloud` project:

```bash
./script/open_google_oauth_console.sh
```

In Google Auth Platform, create a client with application type `Desktop app`.
Use the generated client ID and client secret in `.env.local`. Set
`GOOGLE_OAUTH_CHROME_PROFILE` when OAuth should open a specific Chrome profile
instead of the default browser.

Then run:

```bash
./script/check_google_calendar_setup.sh
./script/build_and_run.sh --verify
./script/verify_google_calendar.sh
```

`script/build_and_run.sh` injects the configured OAuth values into the generated app `Info.plist`. If `GOOGLE_CLIENT_ID` is missing, the Calendar provider still loads and shows a configuration-required state.
`script/verify_google_calendar.sh` uses the same OAuth, Calendar API, and day-detail filtering code as the app, and prints only counts/ranges rather than event details.

## Display placement

Display placement is a user setting:

- `Auto`: use the display under the pointer, then keep the panel on that display while it is open.
- `Main`: always use the primary macOS display.
- `Sub`: use a secondary display when one is connected, and fall back to the primary display otherwise.

Only screens with a real `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` gap use the notch-attached layout. Screens without a detected notch use a small top-center handle instead of a fake 185pt notch.

## Notch sizing note

macOS screen layout values are in points, not physical pixels. On the current built-in Retina display, the measured notch-related values were:

```text
safeAreaInsets.top = 32pt
backingScaleFactor = 2.0
1px = 0.5pt
```

So a true 1-pixel compensation would be `safeAreaInsets.top + 0.5pt`. In this prototype, `33pt` looked visually correct, which means the chosen adjustment is `safeAreaInsets.top + 1pt`, or +2 physical pixels on a 2x Retina screen.

Keep this as a visual fit correction, not a universal notch rule. If the app later needs to adapt across Mac models and external displays, compute from `NSScreen.safeAreaInsets.top`, `backingScaleFactor`, and `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` instead of hard-coding the height.

The current prototype uses `auxiliaryTopLeftArea` and `auxiliaryTopRightArea` to derive the horizontal notch span. On the current built-in display, the measured notch span is:

```text
notch x = 663pt ... 848pt
notch width = 185pt
left handle width = 54pt
pill frame = x: 609pt, width: 239pt
```

This makes the visible left handle end exactly at the notch left edge, while the black base continues behind the notch.
