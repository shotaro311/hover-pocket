---
project_slug: hover-menu-preview
date: 2026-07-06
actor: codex
scope: windows-build124-parity
---

# Windows build 124 parity follow-up

## Summary

- Audited macOS build 124 Clipboard / Calculator changes against the Windows implementation.
- Added Windows Clipboard favorites, `Text` / `Images` / `Favorites` tabs, favorite-preserving clear, explicit favorite deletion, full preview, and copy-icon behavior.
- Added Windows Calculator JIS keyboard parity for `;` as `+` and `:` as `×`, continuous expression evaluation with operator precedence, expression display, and a clear-history bridge/UI action.
- Removed the AI command lane from the normal Windows panel UI and set the visible panel metrics to exclude the AI lane height.
- No Windows release was created. Windows update feed / updater implementation was not changed, and the existing `--verify updater` still passed.

## Readback

- Clipboard persistence remains `%APPDATA%\HoverPocket\clipboard\history.json` plus image PNG files.
- Legacy Clipboard history without `favorite` fields is treated as `favorite=false`.
- Regular Clipboard clear removes only non-favorite text/images and deletes only non-favorite image files.
- Favorites tab deletion removes the explicit favorite entry; image deletion also removes the saved PNG file.
- Calculator verifier covers `5;6:2=` -> `17` and `6+5+9/2+3-5=` -> `13.5`.
- AI lane backend and verifier remain available for deferred work, but the normal panel no longer renders the lane.

## Verification

- `node --check windows\ui\providers\clipboard\clipboard.js`: exit code 0.
- `node --check windows\ui\providers\calculator\calculator.js`: exit code 0.
- `node --check windows\ui\js\app.js`: exit code 0.
- `dotnet build windows\HoverPocket.Windows.sln --nologo -p:NuGetAudit=false`: exit code 0, warnings 0, errors 0.
- `dotnet run --no-build --project windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify calc`: exit code 0.
- `dotnet run --no-build --project windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify clipboard`: exit code 0.
- `dotnet run --no-build --project windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify ui-model`: exit code 0.
- `dotnet run --no-build --project windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify updater`: exit code 0.
- `git diff --check`: exit code 0.

Note: an initial parallel `dotnet run` verification attempt hit transient `obj\Debug` file locks. The build had already succeeded, so the verifiers were rerun sequentially with `--no-build` and passed.

## Not Done

- Windows installer/feed publication was not performed.
- Hands-on WebView2 UI confirmation for Clipboard preview/favorites and Calculator panel layout remains a Windows desktop-session follow-up.
