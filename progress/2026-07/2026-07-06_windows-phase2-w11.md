---
project_slug: hover-pocket
date: 2026-07-06
worker: W11
status: completed
---

# Windows Phase 2 W11 - Velopack updater and release packaging

## Scope

- Implemented Windows auto-update and release packaging with Velopack 1.2.0, following the current Velopack docs for startup integration, GitHub Releases feeds, update manager APIs, local file feeds, and `vpk pack`.
- Kept GitHub Release creation/upload, push, commit, real update download/apply/restart, and WebView2 runtime UI verification out of scope per contract.

## Implementation

- Added `Velopack` NuGet package and set `HoverPocket.Shell` version to `0.2.0`.
- Moved Velopack startup integration to `HoverPocket.Shell.Program.Main`, before WPF app startup. `--verify` and `--second-instance-probe` skip `VelopackApp.Build().Run()` so verifier and second-instance paths remain isolated.
- Added `UpdaterService` for GitHub Releases feed `https://github.com/shotaro311/hover-pocket`, manual update checks, startup background checks, download progress status, and explicit confirmation before download and before apply/restart.
- Added `UpdaterVerifier` with a local folder feed dry-run for both no-update and update-available cases. It does not download or apply updates.
- Wired `Check for Updates` into the tray menu and Settings WebView bridge. Added `AutoCheckForUpdates` to user settings with default `true`.
- Added `windows/script/publish_release.ps1` to run `dotnet publish` for `win-x64` self-contained output, run `vpk pack`, list generated assets, and print a `gh release upload` command example without executing upload.
- Documented unsigned Phase 2 Windows builds and possible SmartScreen warnings in `windows/README.md`. Signing credentials remain outside Git/log/progress/README.

## Verification

- `dotnet build .\windows\HoverPocket.Windows.sln --nologo --source %TEMP%\hoverpocket-velopack-nuget --source https://api.nuget.org/v3/index.json --ignore-failed-sources`: exit 0, warnings 0, errors 0.
- `dotnet HoverPocket.Shell.dll --verify updater`: exit 0. Local feed dry-run covered `no-update` and `update-available`.
- `dotnet HoverPocket.Shell.dll --verify ui-model`: exit 0.
- `dotnet HoverPocket.Shell.dll --verify settings`: exit 0.
- `dotnet HoverPocket.Shell.dll --verify ailane`: exit 0.
- `dotnet HoverPocket.Shell.dll --verify sticky`: exit 0.
- `dotnet HoverPocket.Shell.dll --verify calc`: exit 0.
- `dotnet HoverPocket.Shell.dll --verify timer`: exit 0.
- `dotnet HoverPocket.Shell.dll --verify display`: exit 0.
- `dotnet HoverPocket.Shell.dll --verify clipboard`: exit 0.
- `dotnet HoverPocket.Shell.dll --verify calendar`: exit 0.
- `HoverPocket.Shell.exe --verify shell` via `start /wait`: exit 0.
- `node --check windows\ui\js\i18n.js`, `node --check windows\ui\settings\settings.js`, and `node --check windows\ui\js\app.js`: exit 0.
- `windows/script/publish_release.ps1 -VpkPath <temp vpk.exe> -NuGetSource %TEMP%\hoverpocket-velopack-nuget`: exit 0.

## Release dry-run assets

Generated under `dist/windows/releases/0.2.0/`:

- `assets.win.json` - 214 bytes
- `HoverPocketWin-0.2.0-full.nupkg` - 78,735,857 bytes
- `HoverPocketWin-win-Portable.zip` - 78,734,826 bytes
- `HoverPocketWin-win-Setup.exe` - 83,197,425 bytes
- `RELEASES` - 84 bytes
- `releases.win.json` - 262 bytes

The final `vpk pack` run verified `VelopackApp.Run()` in `HoverPocket.Shell.Program.Main`. It also warned that no signing parameters were provided; this is expected for Phase 2 unsigned Windows packaging.

## Notes

- NuGet TLS access to `api.nuget.org` was unreliable in this sandbox. Velopack/vpk nupkgs were fetched into `%TEMP%` by the Node/local-source workaround. Self-contained publish also required .NET 10.0.9 runtime pack nupkgs in the same temp source; those were copied from the existing global NuGet cache into `%TEMP%`. No NuGet workaround nupkg was placed in the workspace.
- The generated Velopack release artifacts intentionally include a `.nupkg` under ignored `dist/windows/releases/0.2.0/` because that file is one of the upload assets.
- Real GitHub Releases download/apply/restart and WebView2 UI operation are architect/user desktop-session follow-ups.
