# Windows Calculator History and Feed Separation

Date: 2026-07-06
Actor: codex on Windows
Workspace: `C:\Users\shotaro\code\shared\hover-pocket`

## Scope

- Windows-only implementation under `windows/`.
- Shared progress updates under `progress/`.
- macOS `Sources/HoverPocket/` and macOS release scripts were not modified.

## Changes

- Calculator engine now keeps chronological history entries for successful binary calculations.
- Each history entry keeps an internal state snapshot containing display, error flag, accumulator, pending operation, entering-new-value flag, last operand, and last operation.
- Calculator bridge adds `calculator.useHistoryValue` and `calculator.restoreHistory`.
- Calculator UI renders compact history rows. Clicking a result puts that number into the current input. Clicking the right-side restore icon restores the captured engine state.
- Keyboard input now covers normal operator keys, shifted operator keys through browser `event.key`, and numpad-equivalent `event.code` values. The C# engine also accepts `Numpad0` through `Numpad9`, `NumpadAdd`, `NumpadSubtract`, `NumpadMultiply`, `NumpadDivide`, `NumpadDecimal`, `NumpadEnter`, and `NumpadEqual`.
- Windows updater now sets Velopack `ExplicitChannel = "win"` and verifies the feed file name `releases.win.json`.
- `windows/script/publish_release.ps1` now prints a Windows release creation command with `--latest=false`, Windows-only asset upload, and readback commands.
- `windows/README.md` now documents Windows `win-v...` release tags, `releases.win.json`, and separate macOS `macos-latest/appcast.xml` readback.

## Verification

- `git fetch origin; git pull --ff-only origin main`: exit 0. Fast-forwarded to `0c09f22`.
- `git status --short --branch`: exit 0. Clean at start after pull.
- Read required files: `AGENTS.md`, `progress/progress.md`, `docs/requirement/requirements.md`, `windows/README.md`.
- `dotnet build windows\HoverPocket.Windows.sln --nologo -p:NuGetAudit=false`: first attempt failed because existing workspace `HoverPocket.Shell` PID `72764` locked the Debug exe. The process path was verified under this workspace and stopped.
- `dotnet build windows\HoverPocket.Windows.sln --nologo -p:NuGetAudit=false`: exit 0, warnings 0, errors 0.
- `dotnet run --project windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify calc`: exit 0.
- `dotnet windows\src\HoverPocket.Shell\bin\Debug\net10.0-windows\HoverPocket.Shell.dll --verify calc`: exit 0, `PASS calc verify: arithmetic, keyboard tokens, history value input, restore, error, recovery, backspace, AC`.
- `dotnet run --project windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify ui-model`: exit 0.
- `dotnet run --project windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify updater`: exit 0.
- `dotnet windows\src\HoverPocket.Shell\bin\Debug\net10.0-windows\HoverPocket.Shell.dll --verify updater`: exit 0, local feed dry-run covered no-update and update-available.
- `node --check windows/ui/providers/calculator/calculator.js`: exit 0.
- Windows feed readback: `https://github.com/shotaro311/hover-pocket/releases/download/win-v0.2.1/releases.win.json` returned `HoverPocketWin` version `0.2.1`, type `Full`, file `HoverPocketWin-0.2.1-full.nupkg`.
- macOS appcast readback: `https://github.com/shotaro311/hover-pocket/releases/download/macos-latest/appcast.xml` returned build `112` and `HoverPocket-0.1.0-112.zip`.
- `gh release list --repo shotaro311/hover-pocket --limit 4` showed `macos-latest`, latest macOS `v0.1.0-112`, and Windows `win-v0.2.1` / `win-v0.2.0` as separate releases.
- `git diff --check`: exit 0.

## Final Integration

- After macOS build `112` progress was pushed as `6987f1a`, Windows Codex rebased on `origin/main` and preserved both the macOS release log and this Windows log.
- Commit `e4dcaf3706037ab58f49438e99488fca675eb5f8` (`Windows電卓履歴と更新フィード分離を追加`) was pushed to `origin/main`.
- Final Windows status was clean: `## main...origin/main`.
- Final rechecks after staging:
  - `git diff --check`: exit 0.
  - `git diff --cached --check`: exit 0.
  - `dotnet run --project windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify calc`: exit 0.
  - `dotnet run --project windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify updater`: exit 0.
  - `node --check windows/ui/providers/calculator/calculator.js`: exit 0.

## Not Completed

- No Windows release was created or uploaded in this turn.
- Real WebView2 hands-on clicking of Calculator history rows is not manually verified; covered by bridge/UI syntax and C# verifier.
- Real updater download/apply/restart is not executed; updater verification remains local-feed dry-run plus public feed readback.
