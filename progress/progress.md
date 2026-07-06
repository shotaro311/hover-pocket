---
project_slug: hover-menu-preview
updated: 2026-07-06
updated_by: codex
status: active
---

## 2026-07-06 Mac Sparkle Update Popup Foregrounding

- Updated macOS Sparkle integration so manual update checks from Settings, the menu bar, or the provider header activate HoverPocket and bring Sparkle update/status windows to the front.
- The foregrounding window is bounded to user-initiated checks only; the launch-time update probe still updates the in-panel badge/status without stealing focus.
- Verification passed: `swift build`, `git diff --check`, and `./script/build_and_run.sh --verify`. Details: `progress/2026-07/2026-07-06_hover-menu-preview.md`.

## 2026-07-06 OAuth Public Verification Console Execution

- Enabled GitHub Pages for `site/` through `.github/workflows/pages.yml`, manually dispatched the workflow after Pages creation, and verified public readback for `https://shotaro311.github.io/hover-pocket/`, `privacy.html`, and `googlea0eda7d7223f8019.html`.
- Completed Search Console ownership verification for both `https://shotaro311.github.io/hover-pocket/` and the root `https://shotaro311.github.io/`. Created the auxiliary public repo `shotaro311/shotaro311.github.io` so the root verification file can remain available.
- Kept the existing Google Cloud project `hoverpocket`: project is active, `shotaro.matsu0311@gmail.com` is a project owner, and no separate Google Cloud project is needed for this app.
- Updated Google Auth Platform: Branding has `HoverPocket`, support/contact email, privacy URL, authorized domain `shotaro311.github.io`, and root homepage URL `https://shotaro311.github.io/` because the original `/hover-pocket/` homepage failed Google's branding ownership check. Audience is External / In production. Data Access is saved with `calendar.calendarlist.readonly` and `calendar.events` only.
- Reached `Prepare for verification`. Final submit remains blocked by Google's required YouTube demo video field; the scope reason text is prepared but cannot be saved in the form until a YouTube video URL is supplied. Details: `progress/2026-07/2026-07-06_hover-menu-preview.md`.

## 2026-07-06 Mac Calculator History and macOS Feed Split

- Updated macOS release packaging so distribution builds embed the macOS-only Sparkle feed `https://github.com/shotaro311/hover-pocket/releases/download/macos-latest/appcast.xml`. `publish_github_release.sh` now marks versioned macOS releases as GitHub Latest for old builds that still read `latest/download/appcast.xml`, and also syncs `HoverPocket-macOS-app.zip` / `appcast.xml` to the stable `macos-latest` release.
- Fixed notch-origin panel expansion by centering the final preview frame on the detected notch center instead of always using screen midpoint. This keeps the collapsed and expanded panel center aligned on notched MacBooks.
- Added Calculator history on macOS: result history rows, result click-to-input, and per-row restore to the captured calculation state. Keyboard handling now reads shifted characters such as `+`, `*`, `%`, and symbolic `×` / `÷`.
- Verification passed: `swift build`, `bash -n` for release scripts, `.build/debug/HoverPocket --verify-calculator` plus chain / percent / divide-by-zero sequences, `git diff --check`, and `./script/build_and_run.sh --verify`. Non-notarized dry-run packaging generated build `111` artifacts with the new `SUFeedURL`.
- Released build `112` as notarized/stapled macOS ZIP. `notarytool` submission `70397200-f50b-4dfb-a0b1-2a51821f7904` returned `Accepted`; versioned release `v0.1.0-112` and stable macOS feed release `macos-latest` are published. Remote readback confirmed `macos-latest/appcast.xml` and legacy `latest/download/appcast.xml` both report `sparkle:version=112`, the stable ZIP SHA256 is `b13fda6a78544fb27c5cb03f1ad67ccd060bfb3028bcd08643d8fca49df86eb2`, extracted app `CFBundleVersion=112`, `SUFeedURL=https://github.com/shotaro311/hover-pocket/releases/download/macos-latest/appcast.xml`, and `codesign` / `stapler validate` / `spctl` all pass.

## 2026-07-06 Windows Calculator History and Feed Separation

- Implemented Windows Calculator keyboard normalization for normal keys, shifted operator input, and numpad-equivalent tokens on both the WebView key handler and C# engine boundary.
- Added Calculator history to the Windows bridge/UI. History is stored chronologically in the C# engine; clicking a history result puts that value into the current input, and the restore button restores display plus accumulator, pending operation, entering-new-value flag, last operation, and last operand.
- Explicitly pinned Windows updates to Velopack channel `win` / `releases.win.json`, added updater verifier metadata checks, and updated Windows release packaging docs/script output so Windows releases use `win-v...` tags with `--latest=false` and read back Windows feed separately from the macOS `macos-latest` appcast.
- Verification completed: `dotnet build windows\HoverPocket.Windows.sln --nologo -p:NuGetAudit=false`, `dotnet run --project windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify calc`, `--verify ui-model`, `--verify updater`, `node --check windows/ui/providers/calculator/calculator.js`, Windows feed readback for `win-v0.2.1/releases.win.json`, macOS appcast readback for `macos-latest/appcast.xml`, and `git diff --check`. Details: `progress/2026-07/2026-07-06_windows-calc-history-feed.md`.
- Windows-side commit `e4dcaf3` was pushed to `origin/main` after rebasing on the macOS build `112` log. Final Windows status was clean.

## 2026-07-06 Cross-platform Agent Read Gate

- Added root `AGENTS.md` so Codex and other repo-aware AI agents have a mandatory entrypoint before implementation. It points agents to `progress/progress.md`, `docs/requirement/requirements.md`, and the OS-specific README/script files.
- Added `docs/requirement/requirements.md` section `1.4 Mac / Windows 横断ワークフロー` to keep the existing docs structure instead of introducing a separate `product.md`. It defines OS ownership, shared-spec flow, release feed separation, and readback completion gates.

## 2026-07-06 W14 OAuth Public Pages and User Steps

- Added GitHub Pages-ready static pages under `site/`: `index.html` for the app homepage and `privacy.html` for the Japanese/English privacy policy. The policy reflects the current Windows behavior: Google refresh tokens in Windows Credential Manager, local app data under `%APPDATA%\HoverPocket`, Clipboard Private mode and Clear, Sticky Notes delete/archive distinction, AI lane minimal audit metadata with 90-day pruning, and GitHub Releases as the update source.
- Added `docs/report/20260706-oauth-scope-justification.md` using W13's final scopes: `calendar.events` plus `calendar.calendarlist.readonly`. Legacy `calendar.readonly` is documented only as an accepted existing-token compatibility case, not as a new Cloud Console scope.
- Added `docs/plan/20260706-google-cloud-console-steps.md` with user-run steps for GitHub Pages, Search Console ownership verification, Google Auth Platform Branding/Audience/Data Access, and Prepare for verification. Recommended Pages path is GitHub Actions deploying `site/` because branch publishing supports only `/` or `/docs`. Details: `progress/2026-07/2026-07-06_oauth-docs-w14.md`.

## 2026-07-06 W13 Windows OAuth Review Prep

- Changed Windows Google OAuth configuration loading to prefer build-time embedded `AssemblyMetadata`, then `%APPDATA%\HoverPocket\oauth.json`, then the existing missing-configuration state. `publish_release.ps1` now passes `HOVERPOCKET_GOOGLE_CLIENT_ID` / `HOVERPOCKET_GOOGLE_CLIENT_SECRET` to `dotnet publish` as MSBuild properties without printing values, and `.gitignore` excludes build outputs and local secret JSON.
- Google official Calendar API docs confirm `calendar.events` alone cannot call CalendarList.list. Requested scopes are minimized from `calendar.events` + `calendar.readonly` to `calendar.events` + `calendar.calendarlist.readonly`; legacy stored credentials with `calendar.readonly` remain accepted because Google still authorizes CalendarList.list with that broader scope.
- Verification: `dotnet build windows\HoverPocket.Windows.sln --nologo -p:NuGetAudit=false`, `--verify calendar`, `--verify ui-model`, dummy embedded-property `--verify calendar`, final normal rebuild, and `git diff --check` all completed with exit code 0 and build warnings 0. WebView2 `--verify ui` remains architect desktop-session follow-up. Details: `progress/2026-07/2026-07-06_windows-oauth-w13.md`.

## 2026-07-06 W12 Windows Security Review Fixes

- Fixed security review F-1/F-2/F-3 for the Windows build. DevTools and default WebView2 context menus now enable only in Debug builds or with explicit `--devtools`; Release without the flag disables both. Panel and Settings WebView2 now block navigation outside their virtual hosts and route external `http(s)` URLs to the OS default browser while suppressing all `NewWindowRequested` popups.
- Minimized AI lane audit JSONL to `timestamp` / `action` / `actionType` / `result` / `eventId` / `calendarId`, removed action id, field keys, title, location, notes, command text, and free-form failure reason text, and added 90-day write-time pruning for old daily audit files.
- Verification: `dotnet build windows\HoverPocket.Windows.sln --nologo -p:NuGetAudit=false`, `dotnet build windows\HoverPocket.Windows.sln --nologo -c Release -p:NuGetAudit=false`, `--verify ailane`, `ui-model`, `settings`, `shell`, Release `--verify settings`, and `git diff --check` completed with exit code 0 and build warnings 0. `--verify ui` remains architect desktop-session follow-up because this sandbox cannot launch the WebView2 renderer. Details: `progress/2026-07/2026-07-06_windows-security-w12.md`.

## 2026-07-06 W11 Velopack Windows Updates

- Implemented Windows Phase 2 W11 Velopack updater and release packaging: `VelopackApp.Build().Run()` now runs from `Program.Main` except verify/probe paths, updater checks GitHub Releases `shotaro311/hover-pocket`, tray and Settings `Check for Updates` are wired, startup auto-check defaults on and is non-blocking, and `--verify updater` covers local-folder no-update/update-available dry-runs.
- Added `windows/script/publish_release.ps1` for `dotnet publish` self-contained `win-x64` plus `vpk pack`, generated `HoverPocketWin-*` assets, and printed a `gh release upload` command example without uploading. README documents unsigned Phase 2 SmartScreen warnings and keeps signing credentials out of Git/log/progress/README.
- Verification: `dotnet build` completed with warnings 0/errors 0; `--verify updater`, `ui-model`, `settings`, `ailane`, `sticky`, `calc`, `timer`, `display`, `clipboard`, `calendar`, and exe-based `shell` all completed with exit code 0; JS syntax checks completed with exit code 0; publish dry-run generated the Windows Velopack assets under `dist/windows/releases/0.2.0/`. Real GitHub update apply/restart and WebView2 runtime checks remain architect/user follow-up. Details: `progress/2026-07/2026-07-06_windows-phase2-w11.md`.

## 2026-07-06 W9 Clipboard Provider

- Implemented Windows Phase 2 Clipboard provider: `AddClipboardFormatListener` / `WM_CLIPBOARDUPDATE` monitoring while provider visibility is ON, text 30 / image 20 history limits, PNG normalization, SHA-256 image deduplication, `%APPDATA%\HoverPocket\clipboard\history.json` + PNG persistence, corrupt JSON fallback, private mode, click-to-copy, clear all, and C# `DoDragDrop` external drag payloads.
- Added Clipboard WebView UI under `windows/ui/providers/clipboard/` with text/image history lists, private mode status/button, clear action, copy-on-click, and mouse-down drag handles. Settings now exposes Clipboard private mode plus the ja/en confidentiality note.
- Shared files were limited to provider registration, bridge registration, `--verify clipboard`, panel hide notification for external drag, Settings/app/i18n wiring, and ui-model coverage.
- Verification: `node --check` for `app.js` / `settings.js` / `clipboard.js`, `dotnet build windows\HoverPocket.Windows.sln --nologo -p:NuGetAudit=false`, `--verify clipboard`, `--verify ui-model`, and `git diff --check` completed with exit code 0. Initial plain build hit an existing `HoverPocket.Shell` file lock, then succeeded after the required wait; plain NuGet audit emitted `NU1900` while `api.nuget.org` was unreachable.
- WebView2 hands-on Clipboard UI, long-running real clipboard listener, and external app drop remain architect desktop-session confirmation. Details: `progress/2026-07/2026-07-06_windows-phase2-w9.md`.

## 2026-07-06 W10 Google Calendar Provider

- Implemented Windows Phase 2 Google Calendar provider: Desktop-app OAuth with loopback redirect + PKCE S256, external `%APPDATA%\HoverPocket\oauth.json` client configuration, refresh-token storage in Windows Credential Manager, in-memory access tokens only, Calendar API v3 REST calendar/event read and CRUD, 42-cell month grid UI, read-only calendar guards, and AI lane calendar read/create connection through the existing approval flow.
- Scope choice is `calendar.events` plus `calendar.readonly`: event CRUD requires `calendar.events`, while calendar list/read-only metadata requires `calendar.readonly`; this keeps the Windows provider narrower than full calendar account access.
- Credential storage choice is Win32 `CredWrite` / `CredRead` / `CredDelete` generic credentials instead of `PasswordVault`, because the task requires Windows Credential Manager verification and direct cleanup of verification entries.
- Verification: `dotnet build windows\HoverPocket.Windows.sln --nologo -p:NuGetAudit=false`, `--verify calendar`, `--verify ailane`, `--verify ui-model`, JS syntax checks, and `git diff --check` completed with exit code 0. The previous default-output file lock cleared and the standard build now passes with warnings 0 / errors 0.
- Real Google account E2E is waiting for architect/user after placing `%APPDATA%\HoverPocket\oauth.json`. Details: `progress/2026-07/2026-07-06_windows-phase2-w10.md`.

## 2026-07-06 W8 Hover Open/Close Stability

- Fixed the hover controller path so an already-visible panel no longer re-opens or re-anchors from cursor polling, and display resync preserves the display chosen when the panel opened.
- Unified close detection around the active access-surface/panel physical rectangles inflated by +4 DIPs converted per monitor scale, with optional `HOVERPOCKET_HOVER_TRACE` file tracing.
- Extended `--verify shell` with simulated pointer checks for stable panel `Left/Top` while moving inside the panel and close after simulated pointer leaves the active hover region.
- Verification: `dotnet build windows\HoverPocket.Windows.sln --nologo --no-restore`, expanded `--verify shell`, and existing `--verify display` / `ui-model` / `calc` / `timer` / `sticky` / `settings` / `ailane` all completed with exit code 0. `--verify shell` reported `stable_position=true` and `outside_close=true`. Real mouse feel remains user-confirmation pending. Details: `progress/2026-07/2026-07-06_windows-bugfix-w8.md`.

## 2026-07-06 W6 Sticky Trash Drop Bugfix

- Fixed Sticky Notes bottom trash drop archiving. The cause was re-rendering the board/trash DOM during Chromium/WebView2 HTML5 drag, which could replace the active drop target before `drop` fired.
- Separated internal panel drag from external drag: note body/card drag now handles reorder and trash archive inside the panel, while external app drag remains on the dedicated top-right export handle through C# `DoDragDrop`.
- Added `sticky.archiveDropped` and `StickyNotesStore.ArchiveDroppedNote()` so `--verify sticky` covers the trash-drop archive state transition plus undo.
- Verification: `node --check windows/ui/providers/sticky/sticky.js`, `dotnet build windows\HoverPocket.Windows.sln --nologo`, `--verify sticky`, `--verify ui-model`, and `git diff --check` completed with exit code 0. WebView2 hands-on drag/drop remains user/architect desktop-session confirmation.

## 2026-07-05 W5 Integration Turn

- Resolved the Windows Phase 1 integration blockers from W5: Calculator/Timer bridge handlers are now registered from `PanelBridgeController.Attach()`, Timer alerts now select the Timer provider, open the panel automatically, and statically highlight the access mini-bar.
- Fixed the self-evident AI lane verifier regression where `14時` was parsed as `4時`.
- `dotnet build windows\HoverPocket.Windows.sln --nologo` completed with exit code 0, warning 0, error 0.
- Final verify exit codes: `shell=0`, `display=0`, `ui-model=0`, `calc=0`, `timer=0`, `sticky=0`, `settings=0`, `ailane=0`.
- WebView2 runtime checks (`--verify ui`, Settings actual window launch) remain architect desktop-session verification items.

## 2026-07-05 W7 Settings + AI command lane

- Implemented Windows Phase 1 W7 Settings and AI command lane frame: Settings window, HKCU Run key service, settings verifier, deterministic AI stub, approval flow, audit JSONL, and AI lane UI.
- W7 JS syntax checks passed with exit code 0 for app.js, ailane.js, settings.js, and i18n.js.
- dotnet build and --verify settings / --verify ailane / --verify ui-model stopped before runtime because W5 Calculator has 3 compile errors. See progress/2026-07/2026-07-05_windows-phase1-w7.md.
- Follow-up: exposed Sticky Notes Undo toast in Settings using the Sticky store as source of truth. Grid size remains provider-local because W6 already exposes S/M/L there. dotnet build and --verify settings / sticky / ui-model / ailane are now exit code 0.

# Project Progress: ホバーポケット

## 概要

- `ホバーポケット` は、macOS 画面上部へホバーすると、ミラー、Controls、Google Calendar、Clipboard 履歴、Sticky Notes を素早く開ける macOS app。
- `/Users/shotaro/Documents/Codex/.../outputs/hover-menu-preview` で作成した prototype を、開発継続用に `/Users/shotaro/code/share/hover-menu-preview` へ移行済み。

## 最新の検証済み状態

- 2026-07-05: Windows Phase 1 W5 Calculator + Timer provider を実装し、統合ターンで共有基盤への接続まで完了。`Providers/Calculator/` に C# `CalculatorEngine` / bridge handler / verifier、`Providers/Timer/` に `%APPDATA%\HoverPocket\timer\` 永続化の Timer store / bridge handler / verifier、`windows/ui/providers/calculator/` と `windows/ui/providers/timer/` に Web UI を追加。`PanelBridgeController.Attach()` へ Calculator/Timer bridge handlers を登録し、Timer 終了時のパネル自動表示・Timer provider 選択・ミニバーハイライトを追加。`dotnet build windows\HoverPocket.Windows.sln --nologo` は exit code 0 / 警告 0、`--verify shell` / `display` / `ui-model` / `calc` / `timer` / `sticky` / `settings` / `ailane` はすべて exit code 0。WebView2 実行系検証はアーキテクト通常 desktop session 実行待ち。詳細は `progress/2026-07/2026-07-05_windows-phase1-w5.md`。
- 2026-07-05: Windows Phase 1 W6 Sticky Notes provider を実装。`Providers/Sticky/` に C# model/store/bridge/verifier、`windows/ui/providers/sticky/` にボードグリッド、inline editor、色、S/M/L、drag reorder、下部 archive drop、右クリックメニュー、Undo toast、C# `DoDragDrop` 起点の外部ドラッグ入口を追加。共有ファイルは sticky descriptor、`--verify sticky` 分岐、app.js renderer 登録、sticky bridge handler 登録のみ追記。`dotnet build windows\HoverPocket.Windows.sln` は exit code 0 / 警告 0、`--verify sticky` と `--verify ui-model` は exit code 0、JS 構文チェックと `git diff --check` も exit code 0。WebView2 実行系の Sticky UI 操作確認と外部ドラッグ実アプリ drop はアーキテクト通常 desktop session 実行待ち。詳細は `progress/2026-07/2026-07-05_windows-phase1-w6.md`。
- 2026-07-05: Windows Phase 1 W4 差し戻し対応。アーキテクト通常 desktop session の `--verify ui` で発覚した `ExecuteScriptAsync` 戻り値 decode バグを修正。`RunWebVerifyScriptAsync()` の `Deserialize<string>` 二重エンコード前提を削除し、JS 側の verify 結果を `window.__hoverPocketVerifyResult` に置いたうえで C# が `UiWebVerifyResult` として直接 deserialize する形へ統一。同種点検で `ExecuteScriptAsync` 使用箇所は `PanelWindow.cs` のみ、二重エンコード前提は残っていない。アーキテクト追加の `VerifyConsole` `HOVERPOCKET_VERIFY_LOG` は維持。`dotnet build windows\HoverPocket.Windows.sln` は exit code 0 / 警告 0、`--verify shell` / `--verify display` / `--verify ui-model` は exit code 0。修正後の `--verify ui` はアーキテクト通常 desktop session 実行待ち。詳細は `progress/2026-07/2026-07-05_windows-phase1-w4.md`。
- 2026-07-05: Windows Phase 1 W4 WebView2 統合基盤を実装。`PanelWindow` に WebView2 host(透明背景、virtual host mapping、NOACTIVATE/TOOLWINDOW、`WM_MOUSEACTIVATE -> MA_NOACTIVATE`、rounded HWND region)を追加し、`windows/ui/` に bundler なしの HTML/CSS/ES modules、C# `Bridge/` dispatcher、JS `bridge.js`、provider header、placeholder provider registry 3枠、`%APPDATA%\HoverPocket\settings.json` store、`--verify ui` / `--verify ui-model` を追加。`dotnet build windows\HoverPocket.Windows.sln` は exit code 0 / 警告 0。`HoverPocket.Shell.exe --verify ui-model`、`--verify shell`、`--verify display` は exit code 0。`--verify ui` は sandbox 内 WebView2 初期化で `COMException E_UNEXPECTED` のため exit code 1、計画書 A4 に従いアーキテクト通常 desktop session 実行待ち。詳細は `progress/2026-07/2026-07-05_windows-phase1-w4.md`。
- 2026-07-05: Windows Phase 0 W3 candidate C risk spikes を `windows/spikes/HoverPocket.Spikes.sln` として本体 sln から分離して追加。S1 WebView2 x NOACTIVATE transparent overlay、S2 Clipboard listener + PNG 正規化 + drag payload、S3 WebView2 getUserMedia camera を実装。`dotnet build windows\spikes\HoverPocket.Spikes.sln --no-restore` は exit code 0 / 警告 0。S2 `--verify` は exit code 0。S1/S3 は WebView2 Runtime `150.0.4078.48` を検出したが、baseline から `RenderProcessExited:LaunchFailed` / `GpuProcessExited:Crashed` で exit code 1。候補Cは未確定、通常 desktop session での S1/S3 再検証が必要。詳細は `docs/report/20260705-windows-candidate-c-spike-findings.md` と `progress/2026-07/2026-07-05_windows-phase0-w3.md`。
- 2026-07-05: Windows Phase 0 W2 multi-monitor / mixed DPI 対応を追加。`--display-placement <main|sub|all>`、`ShellSettings`、`DisplayLayoutService`、複数 access surface、`Sub` のサブなし fallback、`WM_DISPLAYCHANGE` / `WM_DPICHANGED` / display settings / sleep resume hook による再同期、`--verify display` を実装。現在の検証環境は monitor count `1`。`dotnet build windows\HoverPocket.Windows.sln`、`dotnet run --project windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify shell`、`dotnet run --project windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify display` はすべて exit code 0、build 警告 0。追加で `--display-placement sub --verify display` と `--display-placement all --verify display` も exit code 0。実マルチモニター / mixed DPI / display hotplug / sleep wake 実機手動確認は未実施。
- 2026-07-05: Windows Phase 0 W1 shell spike を追加。`windows/HoverPocket.Windows.sln` + WPF `HoverPocket.Shell` で tray、top-edge access surface、NOACTIVATE panel、hover open/close、多重起動防止、Per-Monitor V2 manifest、`--verify shell` を実装。`dotnet build .\windows\HoverPocket.Windows.sln` と `dotnet run --project .\windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify shell` はどちらも exit code 0、警告 0。手動 hover E2E は未検証。
- 移行元 prototype は `./script/build_and_run.sh --verify` 成功済み。
- 移行先 `/Users/shotaro/code/share/hover-menu-preview` で `./script/build_and_run.sh --verify` 成功済み。
- 2026-06-03: 上部 pill の 5pt top inset を削除し、`CGWindowListCopyWindowInfo` で `Y = 0` を確認済み。
- 2026-06-03: preview panel の opening animation を追加し、`optionOnScreenOnly` の frame sampling で `h=199 -> 267 -> 297 -> 308 -> 312` への拡大を確認済み。
- 2026-06-03: pill を top corners square / bottom corners rounded の top-docked shape に変更し、window 切り出しで確認済み。
- 2026-06-03: pill height を 33pt に伸ばし、下端の細い隙間を抑えたことを切り出し画像と window frame で確認済み。
- 2026-06-03: notch sizing と `33pt = safeAreaInsets.top + 1pt` の設計メモを `README.md` に記録済み。
- 2026-06-03: 二段階の `neck / elastic overshoot` animation はもっさり見えたため撤回し、直前の `source -> final` のシンプルなノッチ中央 morphing に戻したことを確認済み。
- 2026-06-03: preview close animation を open と同じ `0.32s` にし、timing curve も open の逆カーブにして、開く動きの逆再生として閉じることを frame sampling で確認済み。
- 2026-06-03: top pill の text / session count 表示を消し、ノッチ左側の小さい `arrow.right` handle だけを表示する状態に変更済み。
- 2026-06-03: `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` から実ノッチ幅を取り、left handle 右端をノッチ左端へ揃えて、ノッチ裏まで黒い UI base を敷くように変更済み。
- 2026-06-03: top pill の shadow を無効化し、上端 `3pt` を黒で overfill して、上部の細いスリット状の抜けを埋めたことをピクセル検査で確認済み。
- 2026-06-03: 左上 handle のラウンド形状変更は意図と違ったため撤回し、元の連続した黒ベース形状へ戻したことを確認済み。
- 2026-06-03: `main.swift` の単一ファイル構成を App / Windowing / State / Models / Providers / Views / Support に分割し、今後の追加機能を `NotchProvider` として差し込む土台へ変更。デモ用 sessions / usage 表示は削除済み。
- 2026-06-03: Display placement 設定を追加。`Auto / Main / Sub` で表示先を選べるようにし、ノッチなし画面では fake notch ではなく top-center handle に切り替えるよう変更済み。
- 2026-06-04: Built-in `Mirror` provider を追加し、panel active 中だけ Mac camera を起動する鏡機能を実装。`swift build`、`./script/build_and_run.sh --verify`、`NSCameraUsageDescription`、hover 後 panel onscreen を確認済み。
- 2026-06-04: Mirror hover 時の crash を修正。原因は camera session start と preview layer attach の race。preview layer 常駐化、4秒 warm grace、`vga640x480` preset、OSLog を追加。hover stress 後も process 生存、該当例外なし、close 後 CPU 0% を確認済み。
- 2026-06-04: Mirror close 時の点滅 / 残像対策として、close animation 中は content を維持し、window `orderOut` 後に `contentVisible=false` にする順序へ変更。open / close window state と crash 例外なしを確認済み。
- 2026-06-04: Mirror の軽快化として、見た目の animation は維持したまま、`contentVisible` と provider active state を分離。camera access 許可済みなら app launch 時に session 構成だけ prewarm し、`startRunning()` は hover active 時だけに限定。`.eventDriven` provider の panel open refresh も skip するように変更。`swift build`、`./script/build_and_run.sh --verify`、hover in/out metadata、crash 例外なしを確認済み。
- 2026-06-04: Mirror 表示のカクつき / ちらつき対策を追加。camera preview layer の layout 時に暗黙 Core Animation を無効化し、開閉 animation 中だけ preview window shadow を切るように変更。閉じかけからの再 hover では collapsed frame へ戻さず、現在の frame / alpha から開き直す。live camera への SwiftUI blur も削除。`swift build`、`./script/build_and_run.sh --verify`、idle CPU 0%、crash 例外なしを確認済み。
- 2026-06-04: Mirror が UI 枠より遅れて表示される問題を修正。preview window animation 開始前に `contentVisible=true` を非アニメーションで反映し、ミラー映像が枠の clip と同時に広がるように変更。`swift build`、`./script/build_and_run.sh --verify`、open/close metadata、idle CPU 0%、crash 例外なしを確認済み。
- 2026-06-04: close 時にカメラ映像の残像が残る問題を抑えるため、close animation 開始時点で `providerActive=false` にし、panel 本体より先に camera preview を fade out するように変更。camera preview fade は `0.12s -> 0.06s` に短縮。`swift build`、`./script/build_and_run.sh --verify`、open/close metadata、idle CPU 0%、crash 例外なしを確認済み。
- 2026-06-04: 繰り返し open / close 後にもっさりする体感への処理系対策を追加。close fallback reset task を単一管理して古い task を cancel、`contentVisible` / `providerActive` / camera status の同値 publish を抑制、同一 provider 選択を no-op 化、close delay task の参照を実行後に解放。25 cycle stress 後も pill window 1枚へ復帰し、warm grace 後 CPU 0.0%、crash 例外なしを確認済み。
- 2026-06-04: `GoogleCalendarProvider` を追加。Google installed app OAuth の loopback redirect + PKCE、Keychain token保存、Calendar API `calendarList.list` / `events.list`、月グリッド + 日付hover詳細UI、Settings の connect / disconnect 導線を実装。`swift build`、`./script/build_and_run.sh --verify`、dummy OAuth値の `Info.plist` 注入、loopback socket port確保、callback早着対策、setup check、crash 例外なしを確認済み。gcloud / Calendar API は設定済み。`gcloud iam oauth-clients` と既存gcloud tokenではCalendar OAuth検証に使えないことも確認済み。実Googleアカウント取得には OAuth desktop client ID 設定が必要。
- 2026-06-04: `shotaro.matsu0311@gmail.com` のChrome `Default` profileで Google Auth Platform の Desktop OAuth client を作成し、`.env.local` に client ID / secret を保存。実OAuth consent、Keychain保存、Calendar API取得まで検証済み。`./script/verify_google_calendar.sh --force-google-sign-in` は `calendar_sources=5`、`events_in_visible_grid=53`、`days_with_events=37`、`today_events=3`。保存済み認証での再取得も `used_login_flow=false` で成功。`./script/build_and_run.sh --verify`、`git diff --check`、起動後 `CPU 0.0%`、直近crash例外なしを確認済み。
- 2026-06-07: Google Calendar の日付クリック詳細固定、予定追加、編集、削除 UI と Calendar API 書き込み処理を追加。OAuth scope を `calendar.events` に変更し、古い read-only credential は再接続が必要な状態として扱うようにした。`swift build`、`./script/check_google_calendar_setup.sh`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。実Googleアカウントの write scope 追加同意は OAuth callback 待ちで未完了。
- 2026-06-07: Clipboard provider を追加。テキスト/画像 clipboard 履歴、画像の Application Support 保存、クリック再コピー、外部アプリへの drag/drop provider を実装。provider の表示/非表示、順番、最後に開いた panel / default panel 設定を追加。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。起動後 CPU 0.0% を確認。
- 2026-06-07: Codex chat 欄への画像 drag/drop が効かない報告を受け、drag 開始直後に hover panel を一時非表示にし、画像 drag payload を file URL 起点の `NSItemProvider` に変更。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- 2026-06-07: Mirror provider に A案ベースの compact microphone check row を追加。設定で表示/非表示を切替可能。Mirror microphone row 表示中は `AVAudioEngine` で meter を自動起動し、panel 非表示/非active/設定OFFで停止。button は一時録音用に変更し、`録音 -> 停止 -> 再生 -> 再生完了後にメモリから削除` の流れにした。audio file は作成しない。`NSMicrophoneUsageDescription` を generated app bundle に追加。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- 2026-06-07: 一時的なアプリ名で GitHub public repository へ push。現在の正式名称は `ホバーポケット` / `HoverPocket`。
- 2026-06-07: README を日本語中心へ全面更新。概要、機能、実行方法、Google Calendar 設定、表示先、実装メモ、ノッチサイズ、注意事項を日本語で読めるようにした。
- 2026-06-08: パネルを開いたまま provider アイコンを切り替えると機能だけ切り替わりアイコン選択状態が更新されない問題を修正。ヘッダーを `ProviderStore` 監視の `ProviderHeaderView` に分離。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- 2026-06-08: GitHub Actions `Codex PR Router` を追加。PR作成/更新/レビュー時に変更ファイルを分類し、Mac worker 向け origin / autofix / human merge / docs-only auto-merge safe ラベルを付ける。trusted author の docs-only PR だけ auto-merge 有効化を試みる。
- 2026-06-08: `github-codex-autofix` plugin を Mac / Windows 両方へ配置。Mac / Windows Codex Automation を毎日 10:00 / 12:00 / 15:00 / 18:00 / 21:00 に設定し、対象PRがない場合は軽量チェックだけで終了する運用にした。
- 2026-06-08: 実PR `#1` で `Codex PR Router` のラベル付与、Mac helper の対象PR検出、claim / release、Windows helper の Mac向けPR除外を確認。`.github/*.md` の docs-only 誤判定も修正し、Mac / Windows plugin へ反映済み。
- 2026-06-08: PR `#2` で表示領域サイズを `小 / 中 / 大` の3段階に切り替える機能を追加。Settings とパネル見出し右側の `小 中 大` ボタンから変更でき、表示中のパネルはイージング付きで `456 x 326pt / 520 x 372pt / 600 x 430pt` にリサイズされることを実ウィンドウフレームで確認済み。
- 2026-06-08: PR `#2` の追加修正として、ヘッダーのサイズ表示を現在サイズ1文字だけに変更。サイズ変更時は上端 `Y = 33` を維持することを実ウィンドウフレームで確認。今後のPR作成運用も Mac / Windows ともに Draft ではなく Ready PR 前提へ変更済み。
- 2026-06-09: 上部ヘッダー右端の電源アイコンを廃止し、provider アイコン群と設定ボタンの間に薄い縦線の仕切りを追加。Settings で `Icon switching` を `Click / Hover` から選べるようにし、`Hover` ではアイコンにポインタを重ねた時点で provider が切り替わる。追加でヘッダーUIを `ProviderHeaderView.swift` へ分離し、`ProviderStore` の設定監視を provider 構成関連に限定。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- 2026-06-09: Google OAuth の Keychain 許可ダイアログが毎回出る問題を調査し、Calendar Store 初期化時の Keychain 読み込みを廃止。Calendar を開く / Connect を押すタイミングまで認証確認を遅延。`script/build_and_run.sh` で利用可能な `Apple Development` 署名IDを自動検出して app bundle を安定署名するよう変更。`codesign` で ad-hoc ではなく Apple Development 署名を確認済み。
- 2026-06-09: アプリ名を正式名称の `ホバーポケット` / `HoverPocket` へ変更。SwiftPM package / executable / generated app bundle / README / OAuth callback page / permission descriptions を更新。source path を `Sources/HoverPocket` へ移し、provider protocol を `PocketProvider` に改名。旧保存先からの Keychain service と Clipboard 保存先の移行は維持。GitHub repository slug と local `origin` は `shotaro311/hover-pocket` へ変更済み。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。generated app bundle は `HoverPocket.app`、bundle ID は `local.codex.hover-pocket`。
- 2026-06-09: MIT License を `LICENSE` として追加し、README に `License` セクションを追加。ソースコードは MIT License、`ホバーポケット` / `HoverPocket` の名称・ロゴ・ブランド表示の商標的利用は別扱いであることを明記。`git diff --check` 成功。
- 2026-06-10: AI native Phase 1 MVP を `feature/ai-native-phase1` で実装。Apple Foundation Models provider、`PocketAction` / `ToolResult` / `IntentPlan` / `ApprovalGate` / `AuditLog`、Calendar read/write tool、下段 command palette lane、構造化 action 由来の承認 UI、解釈候補 fallback UI を追加。`swift build` 成功。Ollama、Codex harness、Clipboard Tool、マルチステップ自律実行、チャット履歴は未実装。
- 2026-06-10: AI native Phase 1 の review fix として、ApprovalCard が全 `approvalFields` を表示するよう修正。`PocketAction.requiresApproval` を `kind` 由来の computed property に変更し、Calendar write は常に承認必須にした。`swift build` 成功。
- 2026-06-15: AI command palette の自動フォーカス、Apple Foundation Models `@Generable` structured output 経路、Calendar write 承認 summary、Calendar editor の手入力/ドラッグ調整対応日時入力、日付セルのダブルクリック新規予定起動を追加。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。Computer Use では hover panel を開くイベント再現ができず、実画面確認は未完了。
- 2026-06-15: Product Compass レポートを生成し、6/22 の伊勢田さん向け検証を「Calendar を開かず予定を見る・追加する」に絞った。AI command deterministic fallback は `今日の予定`、`明日14時 打ち合わせ`、`金曜 デザイン納期`、`来週月曜10時 撮影 場所: 天神` を安定して扱う方向へ強化。承認 summary は場所/メモも先に見える形へ調整し、6/22 観察チェックリストを追加。
- 2026-06-15: ZIP配布検証用に `script/package_zip.sh` を追加。Developer ID Application 署名、hardened runtime、versioned Info.plist、OAuth secret 非埋め込みで `dist/releases/HoverPocket-0.1.0-30.zip` を作成し、ZIP展開後の起動確認まで成功。notarization は未実施のため一般配布前に必要。
- 2026-06-15: Sparkle 2.9.3 を導入し、Settings に `Check for Updates` を追加。GitHub Releases latest appcast URL と Sparkle EdDSA 公開鍵を app bundle に注入し、`script/generate_appcast.sh` / `script/publish_github_release.sh` で ZIP / SHA256 / appcast を配信できる土台を追加。初期配布では delta update を無効化し、フルZIP更新だけを appcast に載せる。
- 2026-06-15: Sparkle 更新確認の公開前エラーを修正。ローカル開発ビルドでは未公開の GitHub appcast URL を自動注入せず、配布ビルドでも手動更新確認前に appcast 取得可否を確認して、404 では Sparkle 汎用エラーではなく Settings の状態表示に留める。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify`、`./script/package_zip.sh` 成功。
- 2026-06-15: Calendar 日時セグメントの数値調整UIは A案のインライン目盛りバーを採用。フォーカス中の数値に黄色枠を出し、直下に目盛り付きルーラーと黄色ノブを表示して、バー自体も左右ドラッグで調整できるようにした。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- 2026-06-15: Calendar 日時セグメントの調整バーが小さく操作しづらかったため、目盛り幅、バー高さ、ノブサイズ、ドラッグ判定領域を拡大。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- 2026-06-15: Calendar 調整バー表示時に日時フィールドの横位置が崩れないよう、バーの横幅を通常レイアウト計算から外してオーバーレイ表示へ変更。ドラッグ中のノブは連続移動にし、バー上のマウススクロールでも日時を調整できるようにした。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- 2026-06-15: Calendar 調整バーは選択数字の直下へ移動させず、日時入力レーン内の固定位置に1つだけ表示する仕様へ変更。対象数字は黄色枠で示す。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- 2026-06-15: Calendar 表示初期のラグ対策として、保存済みGoogle認証の確認中でもCalendar本体を先に表示する `restoring` 状態を追加。予定データ取得前でも空の日付グリッドを即描画し、Google Calendar取得は背後で更新するようにした。空グリッドの月単位キャッシュと DateFormatter 生成削減も実施。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- 2026-06-15: Google Cloud に HoverPocket 専用 project / OAuth consent app を作成し、Google Calendar API を有効化。`shotaro.matsu0311@gmail.com` を test user に追加し、iOS OAuth client + custom URL scheme + PKCE + `ASWebAuthenticationSession` のネイティブ認証フローへ変更。生成 app bundle には iOS OAuth client ID / URL scheme のみ入り、Desktop OAuth client secret は通常入らない。`./script/verify_google_calendar.sh --force-google-sign-in` と保存済み credential 再取得が成功。
- 2026-06-19: 決定アプリアイコンを `Resources/AppIcon.png` として追加し、`script/build_and_run.sh` で `AppIcon.icns` を生成して `CFBundleIconFile=AppIcon` を app bundle に入れるようにした。Mirror は4秒遅延停止と再ホバー起動が競合しても、古い停止完了後に active intent が残っていれば自動再起動するよう修正。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。実マウス移動の hover open / close 5サイクルで毎回 preview が開き、最後の再openも成功。
- 2026-06-19: 一般配布向けに `script/notarize_release.sh` を追加。ZIP作成、notarytool submit/wait、staple、spctl検証、staple後の再ZIP、SHA256 / appcast 再生成を1コマンド化した。`publish_github_release.sh` も既定で notarization を通し、既存ZIP利用時は展開後に `stapler validate` / `spctl` で未notarized ZIPを拒否する。`bash -n` と認証情報未設定時の安全な停止は確認済み。
- 2026-06-20: `hover-pocket` notarytool Keychain profile を作成し、`NOTARYTOOL_PROFILE=hover-pocket ./script/notarize_release.sh` で Apple notarization を実行。submission `dd941d6b-7078-4d6a-94a7-c5a0f8697637` は `Accepted`。`dist/HoverPocket.app` と `dist/releases/HoverPocket-0.1.0-41.zip` 展開後 app の両方で `codesign --verify --deep --strict`、`stapler validate`、`spctl --assess --type execute` 成功。ZIP SHA256 は `362a6fcea234f3faf8b19eb5df625b48594eb573fc3fb5f79a765ff8ffd0986e`。
- 2026-06-20: Sticky Notes drag UX を改善。並び替え中の JSON 保存をドロップ完了時へ寄せ、ホバーウィンドウ外へ出た時点だけ外部ドラッグ閉じ処理を走らせるようにした。空タイトル/本文の新規付箋は確定時に破棄し、ドラッグ中の下部ゴミ箱ドロップでアーカイブできるようにした。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- 2026-06-20: top pill の handle icon を Settings から `B / C / None` で選べるようにした。ノッチに合わせた pill / preview の geometry は変更せず、中央アイコン描画だけを差し替える構成。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- 2026-06-20: top pill のノッチ横 handle area を Settings から表示/非表示に切り替えられるようにした。実ノッチありのときだけ横 handle 幅を外せるようにし、ノッチ本体の黒い領域と preview center は維持する。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- 2026-06-20: 最新コミット `1744fe3` を build `45` として配布。`APP_VERSION=0.1.0 APP_BUILD=45 NOTARYTOOL_PROFILE=hover-pocket ./script/publish_github_release.sh` により notarization/staple、ZIP再生成、GitHub Release `v0.1.0-45` 公開、latest appcast 公開まで完了。remote ZIP の SHA256、Sparkle EdDSA署名、展開後 app の `codesign` / `stapler validate` / `spctl`、build 41 から Settings > Check for Updates 経由で build 45 へ更新されることを確認済み。
- 2026-06-20: README と AI architecture report を現在の `ホバーポケット` / `HoverPocket`、Sticky Notes、AI command lane、notarized GitHub Release、Sparkle 更新済みの状態へ同期。`publish_github_release.sh` の既定 release notes も初回配布向け文言から一般 release 文言へ更新。
- 2026-06-20: GitHub Release の自動生成 Source code ZIP とアプリ配布ZIPの誤認対策として、README に一般ユーザー向け download `HoverPocket-macOS-app.zip` を明記。`publish_github_release.sh` も app-only の alias asset を upload するようにした。ZIP 作成は `ditto --norsrc --keepParent` に切り替え、公開ZIPのトップレベルは `HoverPocket.app` のみにした。
- 2026-06-20: Google OAuth credential は Data Protection Keychain 保存を試したが `errSecMissingEntitlement (-34018)` で保存できないため通常 Keychain に戻した。旧Keychain項目は認証UIなしで読める場合だけ移行し、読めない/重複する古い項目はログイン後の新credentialで上書きする。menu bar status item、Camera / Microphone permission off 時の System Settings CTA、Calendar の Google login CTA も追加。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify`、`./script/verify_google_calendar.sh` 成功。
- 2026-06-20: Camera Privacy 設定で許可した直後にMirrorが復帰しない問題に対応。Camera Settings を開いた後の permission recovery polling と、アプリ復帰時の authorization status 再確認で、許可済みに変わったらその場で camera session を開始するようにした。
- 2026-06-20: コミット `e1b5a5e` を build `53` として配布。notarytool submission `d309c2db-47e2-4db1-b880-73787671cc96` は `Accepted`。staple後に `HoverPocket-0.1.0-53.zip` / `HoverPocket-macOS-app.zip` / appcast を GitHub Release `v0.1.0-53` へ公開し、latest download ZIP のトップレベルが `HoverPocket.app` のみ、SHA256 が `4243fb02dd1eb16ea4deb6d60d50dd2e31c2bbdd0419ef22cc68ce65f32cda0e` であることを確認。
- 2026-06-20: コミット `8a4489d` を build `51` として配布。notarytool submission `17e76b3f-36d5-4caf-b714-474ec42854aa` は `Accepted`。staple後に `HoverPocket-0.1.0-51.zip` / `HoverPocket-macOS-app.zip` / appcast を GitHub Release `v0.1.0-51` へ公開し、latest download ZIP のトップレベルが `HoverPocket.app` のみ、SHA256 が `ca9c21fe9f8be9e4d7517227504e3d72b1a0c71c6285f372a40817cac00cd96b` であることを確認。
- 2026-06-21: UI 言語設定を追加。既定は日本語で、Settings から `日本語` / `English` を切り替え可能。Settings、Calendar、Mirror、Clipboard、Sticky Notes、provider header、status bar menu、AI command lane の主要固定文言を言語設定へ接続。Provider header の機能アイコンを drag & drop で並べ替え可能にした。build `59` を notarized/stapled ZIP として GitHub Release `v0.1.0-59` に公開し、latest appcast が build `59` を指すことを確認済み。
- 2026-06-21: サブディスプレイ向けに控えめなミニバー起点と表示先 `すべて` を追加。サブディスプレイから開いた場合に Mirror provider を非表示にする設定を追加し、既定オフにした。Sparkle の probing update check で更新が見つかった場合だけ、ホバーウィンドウ上部に青い更新アイコンを表示し、クリックで更新 UI を開けるようにした。build `61` を notarized/stapled ZIP として GitHub Release `v0.1.0-61` に公開し、latest appcast が build `61` を指すことを確認済み。
- 2026-06-21: 表示先の `自動` モードを廃止し、既存保存値が `automatic` の場合は `メイン` に移行するようにした。`すべて` 選択時は全ディスプレイの起点ウィンドウを同期時に即前面化し、ノッチなし画面のミニバー反応領域を 520 x 64pt へ拡大。透明ヒット領域全体で開くようにして、上端や横方向からの高速 hover 取りこぼしを減らした。build `63` を notarized/stapled ZIP として GitHub Release `v0.1.0-63` に公開し、latest appcast が build `63` を指すことを確認済み。
- 2026-06-21: ノッチなし画面のミニバー縦ヒット領域を 8pt に縮小し、早く開きすぎる挙動を抑えた。更新アイコン押下後はホバーウィンドウを閉じて Sparkle 更新 UI を見やすくした。Settings を `表示 / 起点表示 / パネル / 機能` へ整理し、メインノッチ左のアイコンエリアはオフ時に横エリア自体を描画しないようにした。build `65` を notarized/stapled ZIP として GitHub Release `v0.1.0-65` に公開し、latest appcast が build `65` を指すことを確認済み。
- 2026-06-22: Controls provider のディスプレイ/サウンド/メディア UI を整列し、外部ディスプレイの DDC/CI VCP `0x10` 輝度制御、YouTube などのブラウザ active tab fallback 認識、倍速ボタンの丸アイコン配置を追加。外部ディスプレイは DDC/CI を先に試し、`DisplayServices` が成功扱いを返して DDC を迂回する問題を修正した。build `73` を notarized/stapled ZIP として GitHub Release `v0.1.0-73` に公開し、latest appcast が build `73` を指すことを確認済み。
- 2026-06-30: Controls のメディア倍速ボタンが UI を止め、倍速操作の成否が UI / 診断で判別できない問題を修正。AppleScript / MediaRemote 操作は background task で実行し、refresh 時は対象ブラウザタブの実 `video.playbackRate` を読み戻す。Dia は `focus browserTab` 経路で対象動画タブへ fallback 操作を当てるが、`--enable-applescript-javascript` なしでは exact `1.1x` を外部から設定できないため、未確認の目標値を反映済みとして表示しない。`--verify-media --set-playback-rate 1.1` は `media_playback_rate_verified=false` / `media_verify=failed` を返し、実反映できない状態を成功扱いしないことを確認。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- 2026-06-30: コミット `ac4eb0b` を build `81` として配信。notarytool submission `88f7efe9-b3ab-460e-8a94-fed9fd3e1352` は `Accepted`。staple後に `HoverPocket-0.1.0-81.zip` / `HoverPocket-macOS-app.zip` / appcast を GitHub Release `v0.1.0-81` へ公開し、latest appcast が build `81` を指すことを確認。公開ZIPの top-level は `HoverPocket.app` のみ、SHA256 は `2d1d7fe8bf434263eedcf84675679b67bdfe547214fce2204353618a77854316`。公開ZIP展開後の `codesign` / `stapler validate` / `spctl` も成功。
- 2026-07-01: Calendar の小サイズ表示で固定幅セルと余白が詳細ペインを押し出す問題を修正。小サイズでは calendar grid / padding / spacing / font を縮小し、月表示は minimumScaleFactor を持たせた。Controls の画面収録サムネイルは受動表示時に `CGRequestScreenCaptureAccess()` を呼ばず、許可済みなら live preview、未許可なら artwork / placeholder へ fallback するよう変更。ScreenCaptureKit 設定では audio / microphone capture を明示 false にした。メディア操作は play/pause と倍速を pending state 付きの直列タスクにし、操作中の stale refresh と連打を抑制。Dia の JavaScript 不可経路では JS readback timeout を避け、YouTube shortcut の 0.25 刻みを UI で `1.25x` のように表示できるようにした。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify`、`--verify-media`、`--set-playback-rate 1.25 -> 1.0` 成功。
- 2026-07-01: コミット `72d8ff9` を build `83` として配信。notarytool submission `5bd53681-39cb-4821-8167-ca7bc4e74241` は `Accepted`。staple後に `HoverPocket-0.1.0-83.zip` / `HoverPocket-macOS-app.zip` / appcast を GitHub Release `v0.1.0-83` へ公開し、latest appcast が build `83` を指すことを確認。公開ZIPの top-level は `HoverPocket.app` のみ、SHA256 は `cb7062eb9a8ce00b65fba56de8e9eb08a1a2c735ec47205310ff7db781ae4dae`。公開ZIP展開後の `codesign` / `stapler validate` / `spctl` も成功。
- 2026-07-02: Sticky Notes の title/body を入力中に毎キー永続化していた経路を止め、編集終了時に first responder を外して draft を保存する流れへ変更。付箋を開く際は app を activate し、標準 Edit menu の cut/copy/paste/select all/undo/redo を app main menu に追加して macOS の通常テキスト操作が responder chain で届くようにした。色変更、archive、delete、外側クリック、別付箋切替では編集中 draft を先に確定する。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify`、`codesign --verify --deep --strict --verbose=2 dist/HoverPocket.app` 成功。
- 2026-07-02: コミット `126e05e` を build `85` として配信。notarytool submission `cb67081a-54d3-44ca-b961-ce6e728b2451` は `Accepted`。staple後に `HoverPocket-0.1.0-85.zip` / `HoverPocket-macOS-app.zip` / appcast を GitHub Release `v0.1.0-85` へ公開し、latest appcast が build `85` を指すことを確認。公開ZIPの top-level は `HoverPocket.app` のみ、SHA256 は `56da2b0b609af0cd33edea1efae4afbcbf060632359ae38396ec5da4d347362f`。公開ZIP展開後の `codesign` / `stapler validate` / `spctl` も成功。
- 2026-07-03: Calculator provider を追加し、ProviderRegistry に日本語 title `電卓` として登録。四則演算、小数、符号反転、パーセント、バックスペース、AC、コピー、キーボード入力、0除算時の `Error` 表示に対応。パネル preview size は `small=520x372`、`medium=600x430`、`large=680x488` へ拡大し、ホバーパネル内の可読テキスト用に `文字サイズ` 設定を追加。Google Calendar、Clipboard、Controls、Sticky Notes、Timer、Calculator、AI command lane の主要テキストへ適用。`swift build`、calculator verify 2系統、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- 2026-07-03: コミット `af86e29` を build `96` として配信。notarytool submission `e6e801d1-7a43-4d98-8b99-3804482bd322` は `Accepted`。staple後に `HoverPocket-0.1.0-96.zip` / `HoverPocket-macOS-app.zip` / appcast を GitHub Release `v0.1.0-96` へ公開し、latest appcast が build `96` を指すことを確認。公開ZIPの top-level は `HoverPocket.app` のみ、SHA256 は `179917a6294b91cae94471fc97c8b6fae8d4d0d07247f78664c22a7106ad08e9`。公開ZIP展開後の `codesign` / `stapler validate` / `spctl` も成功。
- 2026-07-04: コミット `f02ab81` を build `98` として配信。notarytool submission `1fa7ad28-14be-4234-b455-cbafbdcaf5d1` は `Accepted`。staple後に `HoverPocket-0.1.0-98.zip` / `HoverPocket-macOS-app.zip` / appcast を GitHub Release `v0.1.0-98` へ公開し、latest appcast が build `98` を指すことを確認。公開ZIPの top-level は `HoverPocket.app` のみ、SHA256 は `33efbaf3e32d1f59b382b21b390c29376bf6a4ef35ab253f354e2c3166baeb0e`。公開ZIPを再取得し、展開後の `codesign` / `stapler validate` / `spctl` も成功。
- 2026-06-29: Google OAuth を Chrome profile override なしの OS 既定ブラウザ起動へ統一し、native/custom URL scheme flow は `AppDelegate` の `kAEGetURL` callback で待機処理へ渡す形に変更。Calendar token 失効や scope 不足を再接続扱いにする改善、外部モニター音量の DDC/CI VCP `0x62` 対応、クラムシェル外部カメラなし時の Mirror 非表示を追加。README / `.env.example` / `script/build_and_run.sh` から旧 Chrome override 説明と `GoogleOAuthChrome*` Info.plist 注入を削除。`swift build`、`git diff --check`、`./script/verify_google_calendar.sh` 成功。Apple Developer Program License Agreement 同意後、`script/notarize_release.sh` の notarytool 事前検証を補正し、build `79` を notarized/stapled ZIP として GitHub Release `v0.1.0-79` に公開。latest appcast が build `79` を指すことを確認済み。

## 進行中

- Codex: `ホバーポケット` / `HoverPocket` として GitHub public repository `shotaro311/hover-pocket` へ公開済み。`Mirror`、`Controls`、`Calculator`、`Calendar`、`Clipboard`、`Sticky Notes` の built-in provider が有効。Controls は明るさ表示/調整、最小/最大輝度トグル、CoreAudio 音量/ミュート、MediaRemote bridge による Now Playing サムネイル/再生位置/再生制御/再生速度調整を持つ。MediaRemote が空の場合はブラウザの active tab title / URL で YouTube などを fallback 認識する。再生/停止と倍速操作は pending state 付きの background task で直列化し、操作中の stale refresh と連打を抑える。倍速は対象 media URL / title に一致するブラウザタブまたは MediaRemote へ反映し、確認できた実 `playbackRate` または YouTube shortcut の既知段階を表示へ反映する。画面収録サムネイルは未許可時に自動 permission request を出さず、許可済みの場合だけ ScreenCaptureKit preview を使う。外部ディスプレイは DDC/CI を先に試し、DDC が使えない場合だけ DisplayServices とソフト輝度 fallback を使う。Calendar は Google iOS OAuth client + custom URL scheme + PKCE + OS 既定ブラウザで実アカウント接続、予定取得、追加、編集、削除まで実装済み。Google OAuth credential は通常 Keychain に保存し、開発版と配布版で Keychain service suffix を分離する。パネル preview size は `small=520x372`、`medium=600x430`、`large=680x488`。Settings の `文字サイズ` で hover panel の主要可読テキストを小/中/大に切り替え可能。Sticky Notes は inline editor、title optional、drag reorder、外部 drag text payload、下部ゴミ箱 drop archive、S/M/L grid、Undo toast 設定に対応し、入力中 draft は外側クリック/別付箋切替/操作実行時に確定する。標準 Edit menu 経由の cut/copy/paste/select all/undo/redo も使える。AI native Phase 1 として Apple Foundation Models provider、Calendar read/write tool、ApprovalGate、AuditLog、下段 command lane、fallback candidates を実装済み。UI は Settings で `日本語` / `English` を切り替え可能で、既定は日本語。Provider header の機能アイコンは drag & drop で並べ替え可能。上部 handle は `B / C / None` とメインノッチ左アイコンエリア表示/非表示を Settings から選択可能で、非表示時は横エリア自体を描画しない。表示先は `メイン / サブ / すべて` で、ノッチなし画面は縦ヒット 8pt の控えめなミニバー起点を使う。サブディスプレイから開いた場合の Mirror 表示は Settings から制御でき、既定は非表示。macOS menu bar status item から設定 / 更新確認 / 終了を実行可能。更新がある場合はホバーウィンドウ上部にも青い更新アイコンを表示し、押下後はホバーウィンドウを閉じる。Camera / Microphone permission off 時は System Settings へのCTA、Calendar未接続時はGoogle login CTAを表示する。Camera Settings で許可後はpermission recovery pollingとアプリ復帰検知でMirrorを再起動する。配布版は hardened runtime 用の camera / audio-input entitlements 入り。build `98` は notarized/stapled ZIP として GitHub Release `v0.1.0-98` に公開済みで、latest appcast も build `98` を指している。

## 次アクション

- 別Macまたは quarantine 付きダウンロードで、GitHub Release ZIP の初回起動時 Gatekeeper UX を確認する。
- Mirror の初回 permission UX と表示品質をユーザー実機で確認する。
- Clipboard provider の text/image drag/drop を、Finder / Slack / browser input など複数アプリで手動確認する。
- Apple Foundation Models の実機可用性を macOS 26 / Apple Intelligence 環境で確認する。
- AI command lane の手動 UX 確認を行い、曖昧入力時の候補表示と Calendar write 承認導線を確認する。
- 2026-06-22: 伊勢田さんに Calendar Pocket 検証を行い、`progress/2026-06/2026-06-22_calendar-pocket-validation.md` の観察項目に沿って記録する。
- アプリ化の次要件を決める: 終了/自動起動、Google OAuth consent screen、正式 installer、今後追加する provider。
- 次の本物のレビューコメント付きPRで、Codex Automation がレビュー内容を読んで修正commitを積むところまで確認する。

## Blocker / Risk

- Developer ID 署名、notarization 済み ZIP、GitHub Release、Sparkle appcast は整備済み。LaunchAgent、自動起動、正式 installer は未実装。
- 初回 camera permission はユーザー操作が必要。
- 自動検証では顔が写る映像確認は避けている。ユーザー側で mirror 映像の見え方確認が必要。
- 機密情報や token は含めていない。
- `.env.local` には Google OAuth 設定値が入るため、値を出力せず、repo に含めない。配布用 app bundle へは iOS OAuth client ID / URL scheme のみ注入し、Desktop OAuth client secret は通常入れない。
- Google OAuth consent screen が Testing の場合、登録済み test user のみログイン可能。一般公開には Google OAuth app verification が必要になる可能性がある。
- 現在の公開ZIP成果物 `dist/releases/HoverPocket-0.1.0-98.zip` は Developer ID Application 署名と notarization/staple 済みで、GitHub Release `v0.1.0-98` に公開済み。latest appcast も build `98` を指す。一般ユーザー向けには同じ app-only payload を分かりやすい `HoverPocket-macOS-app.zip` として案内し、公開URLから再取得したZIPのトップレベルが `HoverPocket.app` のみであることを確認済み。SHA256 は `33efbaf3e32d1f59b382b21b390c29376bf6a4ef35ab253f354e2c3166baeb0e`。
- Sparkle秘密鍵は macOS Keychain の `hover-pocket` アカウントにある。秘密鍵ファイルをGitに書き出さない。
- App Store Connect の有料アプリ契約と EU DSA の trader compliance は未完了表示が残るが、今回の Developer ID notarization / Sparkle 配信は成功済み。
- Dia では AppleScript 経由の JavaScript 実行が `--enable-applescript-javascript` なしでは拒否されるため、倍速変更は YouTube shortcut / MediaRemote fallback 経路になり、0.25 刻みで反映される場合がある。
- 旧 Keychain の Google OAuth item が現在の署名で読めない場合は、Keychainパスワードダイアログを出さずに未接続扱いへ落とす。Google再ログイン後は通常 Keychain に新credentialを保存する。credentialはローカルMacのKeychainに保存され、app bundle / ZIP / repo には含めない。
- Calendar event 書き込みには `calendar.events` scope が必要。既存の read-only token では再接続が必要。
- AI native Phase 1 の Apple Foundation Models provider は SDK / OS が未対応の場合、deterministic fallback で候補生成する。モデル本体の実行確認は対応OSで別途必要。
- Clipboard history は機密テキストも拾えるため、今後は除外ルール、保存期間設定、private mode を追加する余地がある。
- Microphone meter は Mirror microphone row 表示中に自動起動する。初回 permission prompt は手動操作が必要。
- 再ビルド後の ad-hoc 署名では camera / microphone permission prompt が再表示されることがある。配布時は安定した署名で確認する。

## 引き継ぎ

- Project root: `/Users/shotaro/code/share/hover-menu-preview`
- GitHub: `https://github.com/shotaro311/hover-pocket`
- Run: `./script/build_and_run.sh --verify`
- Product name: `ホバーポケット` / `HoverPocket`
- UI source: `Sources/HoverPocket/Views/`
- Windowing source: `Sources/HoverPocket/Windowing/`
- Provider source: `Sources/HoverPocket/Providers/`

## 重要パス

- Project root: `.`

## 詳細ログ

- [2026-07-04](2026-07/2026-07-04_hover-menu-preview.md)
- [2026-07-03](2026-07/2026-07-03_hover-menu-preview.md)
- [2026-07-02](2026-07/2026-07-02_hover-menu-preview.md)
- [2026-07-01](2026-07/2026-07-01_hover-menu-preview.md)
- [2026-06-30](2026-06/2026-06-30_hover-menu-preview.md)
- [2026-06-29](2026-06/2026-06-29_hover-menu-preview.md)
- [2026-06-23](2026-06/2026-06-23_hover-menu-preview.md)
- [2026-06-22](2026-06/2026-06-22_hover-menu-preview.md)
- [2026-06-21](2026-06/2026-06-21_hover-menu-preview.md)
- [2026-06-20](2026-06/2026-06-20_hover-menu-preview.md)
- [2026-06-19](2026-06/2026-06-19_hover-menu-preview.md)
- [2026-06-15](2026-06/2026-06-15_hover-menu-preview.md)
- [2026-06-10](2026-06/2026-06-10_hover-menu-preview.md)
- [2026-06-09](2026-06/2026-06-09_hover-menu-preview.md)
- [2026-06-08](2026-06/2026-06-08_hover-menu-preview.md)
- [2026-06-07](2026-06/2026-06-07_hover-menu-preview.md)
- [2026-06-04](2026-06/2026-06-04_hover-menu-preview.md)
- [2026-06-03](2026-06/2026-06-03_hover-menu-preview.md)
- [2026-06-02](2026-06/2026-06-02_hover-menu-preview.md)

## 旧進捗ソース

- 一時成果物: `/Users/shotaro/Documents/Codex/2026-06-02/files-mentioned-by-the-user-2026/outputs/hover-menu-preview`

## 移行検証後の削除候補

- [cleanup-candidates.md](cleanup-candidates.md)

## 最近の更新

- 2026-07-05: Windows 版要件定義を `docs/requirement/requirements.md` に作成。既存 macOS 版の README / progress / Swift source から HoverPocket の本質、Provider 機能、開閉操作感、Settings、保存/権限、配布更新を抽出し、3 つのサブエージェントで macOS 体験、Windows OS 代替、受け入れテスト/失敗モードを分担調査。Windows App SDK、WebView2、Tauri、Google OAuth、Microsoft Win32/Windows API の一次情報を確認し、技術選定は固定せず `top-edge overlay / tray / mixed DPI / Clipboard drag-drop / camera permission` の spike を Phase 0 とする方針にした。`git diff --check` 成功。Windows 環境では `swift` 未導入のため build は未実行。
- 2026-07-05: Windows 側の作業準備として `C:\Users\shotaro\code\shared\hover-pocket` へ public repo `shotaro311/hover-pocket` を clone。HEAD は `0cd6ec1`、origin は `https://github.com/shotaro311/hover-pocket.git`、GitHub latest release は `v0.1.0-98`。Windows 環境では Bash は利用可能だが `swift` が PATH 上になく、`swift build` / `./script/build_and_run.sh --verify` は未実行。`git diff --check` と `git status -sb` は成功。現行構成は SwiftPM macOS 14+ の AppKit/SwiftUI/Sparkle/MediaRemote 依存が強いため、Windows 対応はまず domain/state と OS integration/UI shell の分離から始める。
- 2026-07-04: Calculator UI を整理。電卓本体の最大幅を 430pt に制限し、大きいパネルでキーが横に伸びすぎないようにした。表示エリア内の重複タイトルを削除し、コピーは右上の `doc.on.doc` アイコン1つに統一。バックスペースは表示エリア右上へ移動。キーパッドを `Grid` 化して `0` の2列幅、演算子、`=` の配置崩れを防ぎ、演算子表記を `÷` / `×` / `−` に変更。`swift build`、calculator verify 2系統、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- 2026-07-04: build `98` を notarized/stapled ZIP として GitHub Release `v0.1.0-98` に公開。latest appcast は build `98`、公開 `HoverPocket-macOS-app.zip` の top-level は `HoverPocket.app` のみ、SHA256 は `33efbaf3e32d1f59b382b21b390c29376bf6a4ef35ab253f354e2c3166baeb0e`。公開ZIP再取得後の `codesign` / `stapler validate` / `spctl` 成功。
- 2026-07-03: Calculator provider を追加し、ProviderRegistry に日本語 title `電卓` として登録。四則演算、小数、符号反転、パーセント、バックスペース、AC、コピー、キーボード入力、0除算時の `Error` 表示に対応。パネル preview size は `small=520x372`、`medium=600x430`、`large=680x488` へ拡大し、ホバーパネル内の可読テキスト用に `文字サイズ` 設定を追加。Google Calendar、Clipboard、Controls、Sticky Notes、Timer、Calculator、AI command lane の主要テキストへ適用。`swift build`、calculator verify 2系統、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- 2026-07-03: build `96` を notarized/stapled ZIP として GitHub Release `v0.1.0-96` に公開。latest appcast は build `96`、公開 `HoverPocket-macOS-app.zip` の top-level は `HoverPocket.app` のみ、SHA256 は `179917a6294b91cae94471fc97c8b6fae8d4d0d07247f78664c22a7106ad08e9`。公開ZIP展開後の `codesign` / `stapler validate` / `spctl` 成功。
- 2026-07-02: Sticky Notes の入力中毎キー保存を止め、外側クリック/別付箋切替/色変更/archive/delete で編集中 draft を確定する流れへ変更。app main menu に標準 Edit menu を追加し、付箋編集開始時に app を activate して、cut/copy/paste/select all/undo/redo が通常の macOS テキスト操作として届くようにした。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify`、`codesign --verify --deep --strict --verbose=2 dist/HoverPocket.app` 成功。
- 2026-07-02: build `85` を notarized/stapled ZIP として GitHub Release `v0.1.0-85` に公開。latest appcast は build `85`、公開 `HoverPocket-macOS-app.zip` の top-level は `HoverPocket.app` のみ、SHA256 は `56da2b0b609af0cd33edea1efae4afbcbf060632359ae38396ec5da4d347362f`。公開ZIP展開後の `codesign` / `stapler validate` / `spctl` 成功。
- 2026-07-01: Calendar 小サイズ UI 崩れ、画面収録/システムオーディオ権限の再要求、Controls メディア操作のラグ/倍速不安定を修正。build `83` を notarized/stapled ZIP として GitHub Release `v0.1.0-83` に公開し、latest appcast が build `83` を指すことを確認。
- 2026-06-30: Controls のメディア倍速ボタンを非同期化し、クリック時の UI フリーズと未確認の倍速成功表示を修正。対象 media URL / title に一致するブラウザタブへ操作し、refresh 時は実 `playbackRate` を読み戻す。Dia は `focus browserTab` 経路へ分岐するが、AppleScript JS 実行が拒否されるため exact `1.1x` は未対応として検出する。`--verify-media --set-playback-rate 1.1` が `media_verify=failed` を返すこと、`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- 2026-06-30: build `81` を notarized/stapled ZIP として GitHub Release `v0.1.0-81` に公開。latest appcast は build `81`、公開 `HoverPocket-macOS-app.zip` の top-level は `HoverPocket.app` のみ、SHA256 は `2d1d7fe8bf434263eedcf84675679b67bdfe547214fce2204353618a77854316`。公開ZIP展開後の `codesign` / `stapler validate` / `spctl` 成功。
- 2026-06-29: Google OAuth を native/custom URL scheme と legacy/loopback の両方で OS 既定ブラウザ起動へ統一し、AppDelegate の `kAEGetURL` callback 受け渡しを追加。古い Chrome profile override 設定は README / `.env.example` / build script から削除。Calendar token/reconnect、外部モニター音量 DDC/CI VCP `0x62`、クラムシェル外部カメラなし Mirror 非表示も progress に記録。`swift build`、`git diff --check`、`./script/verify_google_calendar.sh` 成功。Apple Developer Program License Agreement 同意後、build `79` を notarized/stapled ZIP として GitHub Release `v0.1.0-79` に公開。latest appcast は build `79` を指す。
- 2026-06-23: ハンドルアイコン `なし` 選択時に、ノッチ横の黒いハンドル背景も描画しないようにした。表示判定と access window のジオメトリを `showNotchSideHandleArea && pillHandleIconStyle != .none` に揃え、設定変更直後に再同期されるようにした。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- 2026-06-22: Controls のメディア表示に live video preview を追加。MediaRemote / JXA の再生情報にブラウザタブ URL と表示中 window id を合成し、ScreenCaptureKit で小さい映像枠を継続更新する。YouTube 判定は実動画URLだけに絞り、ブラウザタブ列挙 / JS 操作は timeout 付きにした。倍速操作は browser media tab へ試し、失敗時は YouTube keyboard fallback へ落とす。UI には現在速度 `1.0x` ピルを追加。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify`、`--verify-media`、`--set-playback-rate 1.1 -> 1.0` が成功。build local verified、未リリース。
- 2026-06-22: Controls のメディア認識が YouTube で空になる問題を再修正。配布署名済み app から直接 `MRNowPlayingRequest` を読むと `Operation not permitted` になるため、JXA 経由の MediaRemote 取得を先に使い、既存 `MRMediaRemoteGetNowPlayingInfo` と browser tab fallback を後続にした。`--verify-media` 診断を追加し、生成済み `dist/HoverPocket.app` で YouTube の title / source / duration / progress が取れること、検証時間帯に `Operation not permitted` が出ないことを確認。build `74` local verified、未リリース。
- 2026-06-22: YouTube が Controls で認識されない報告に対応。MediaRemote が空の場合だけ Chrome / Safari / Edge / Arc の active tab title / URL を Apple Events で読む fallback を追加し、YouTube などをメディアとして表示するようにした。倍速ボタンは独立カプセルをやめ、10秒戻し / 再生停止 / 10秒送りの横に同じ丸アイコンボタンで配置。build `71` を notarized/stapled ZIP として GitHub Release `v0.1.0-71` に公開し、latest appcast は build `71` を指す。
- 2026-06-22: Controls provider のレイアウトを修正し、ディスプレイ / サウンド / メディアのバー幅と右端アクション位置を揃えた。ディスプレイ名はアイコン hover tooltip へ移動し、見出しアイコンを削除。外部ディスプレイは Apple Silicon の DDC/CI VCP `0x10` で明るさ取得/設定を試し、内蔵ディスプレイ最小輝度は 5% にした。MediaRemote の認識条件を広げ、再生速度 `-0.1 / +0.1` と冒頭へ戻る操作を追加。build `69` を notarized/stapled ZIP として GitHub Release `v0.1.0-69` に公開し、latest appcast は build `69` を指す。
- 2026-06-21: Controls provider を追加。A案の縦積みコンパクトレイアウトで Displays / Volume / Now Playing をまとめ、Header は既存 `ProviderHeaderView` に任せる構成にした。内蔵ディスプレイの明るさ取得、CoreAudio 音量/ミュート、MediaRemote symbol 存在確認、`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` が成功。build `67` を notarized/stapled ZIP として GitHub Release `v0.1.0-67` に公開し、latest appcast は build `67` を指す。
- 2026-06-21: ノッチなし画面のミニバー縦ヒット領域を 8pt に縮小し、早く開きすぎる挙動を抑えた。更新アイコン押下後はホバーウィンドウを閉じて Sparkle 更新 UI を見やすくした。Settings を `表示 / 起点表示 / パネル / 機能` へ整理し、メインノッチ左のアイコンエリアはオフ時に横エリア自体を描画しないようにした。build `65` を notarized/stapled ZIP として GitHub Release `v0.1.0-65` に公開し、latest appcast は build `65` を指す。
- 2026-06-21: 表示先の `自動` モードを廃止し、Settings は `メイン / サブ / すべて` の3択にした。`すべて` 選択時に全ディスプレイの起点ウィンドウを即時前面化し、ノッチなし画面のミニバー反応領域を 520 x 64pt へ拡大して、上端や横方向からの hover 取りこぼしを減らした。build `63` を notarized/stapled ZIP として GitHub Release `v0.1.0-63` に公開し、latest appcast は build `63` を指す。
- 2026-06-21: サブディスプレイ向けに、ノッチなし画面だけ控えめなミニバー起点を使う `すべて` 表示を追加。サブディスプレイから開いた際に Mirror provider を表示するかどうかを Settings で切り替え可能にし、既定はオフ。更新がある場合はホバーウィンドウ上部に青い更新アイコンを表示し、クリックで Sparkle 更新 UI を開く。build `61` を notarized/stapled ZIP として GitHub Release `v0.1.0-61` に公開し、latest appcast は build `61` を指す。
- 2026-06-21: UI 言語設定を追加し、既定日本語 / English 切り替えに対応。Settings、Calendar、Mirror、Clipboard、Sticky Notes、provider header、status bar menu、AI command lane の主要固定文言を言語設定へ接続。Provider header の機能アイコンを drag & drop で並べ替え可能にした。build `59` を notarized/stapled ZIP として GitHub Release `v0.1.0-59` に公開し、latest appcast は build `59` を指す。
- 2026-06-20: 配布版でMirrorが映らない問題に対応。原因は Developer ID + hardened runtime の app bundle に `com.apple.security.device.camera` / `com.apple.security.device.audio-input` entitlements が入っていなかったこと。`Resources/HoverPocket.entitlements` を追加し、codesign 時に適用するよう変更。`--verify-camera` 診断も追加し、build `57` を notarized/stapled ZIP として GitHub Release `v0.1.0-57` に公開。latest appcast は build `57` を指す。
- 2026-06-20: Keychain password prompt 再発に対応。Google OAuth Keychain service を開発版 `development` と配布版 `release` に分離し、旧 `local.codex.hover-pocket.google-oauth` は自動読み取りしないようにした。Camera permission 復帰も AppDelegate 側で再確認するよう補強し、build `55` を notarized/stapled ZIP として GitHub Release `v0.1.0-55` に公開。latest appcast は build `55` を指す。
- 2026-06-20: build `53` を notarized/stapled ZIP として GitHub Release `v0.1.0-53` に公開。latest `HoverPocket-macOS-app.zip` と appcast が build `53` を指すことを確認。
- 2026-06-20: Camera permission 許可後にMirrorが復帰しない問題と、Googleログイン後にリンクされない問題を修正。Google側は Data Protection Keychain の `-34018` が原因だったため通常 Keychain 保存へ戻し、`./script/verify_google_calendar.sh` で Calendar API 到達まで確認。
- 2026-06-20: build `51` を notarized/stapled ZIP として GitHub Release `v0.1.0-51` に公開。latest `HoverPocket-macOS-app.zip` と appcast が build `51` を指すことを確認。
- 2026-06-20: Google OAuth Keychain の起動時パスワードダイアログ対策として Data Protection Keychain 保存へ移行。menu bar status item、Camera / Microphone privacy settings CTA、Calendar Google login CTA を追加。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- 2026-06-20: README と AI architecture report を最新状態へ同期。README は `ホバーポケット` / `HoverPocket` の名称、Sticky Notes、AI command lane、notarized GitHub Release、Sparkle 更新済みの状態へ更新し、古い「notarization 未整備」記述を削除。
- 2026-06-20: GitHub Release の Source code ZIP 誤認対策として、README と release upload script に `HoverPocket-macOS-app.zip` の app-only download 導線を追加。配布ZIPは `__MACOSX` を含まない形式へ差し替え、公開URLからの再ダウンロードでもトップレベルが `HoverPocket.app` のみであることを確認。
- 2026-06-20: top pill の handle icon を `B / C / None` から選択可能にした。ノッチに合わせた pill geometry は変更せず、Settings の `Handle icon` から切り替える。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- 2026-06-20: top pill のノッチ横 handle area を Settings から表示/非表示にできるようにした。非表示時もノッチ本体側の黒い領域と preview center は維持する。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- 2026-06-20: Sticky Notes のドラッグ改善として、並び替え中の保存頻度を下げ、外部ドラッグ閉じ判定をホバーウィンドウ外へ出た時点へ変更。空の新規付箋は確定時に破棄し、ドラッグ中の下部ゴミ箱ドロップでアーカイブできるようにした。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- 2026-06-20: Sticky Notes UI をリファクタリング。`StickyNotesView.swift` を root state / action / layout に絞り、カード/ヘッダー/色スウォッチ/Undo toast などを `StickyNoteComponents.swift`、drop delegate を `StickyNoteDropDelegates.swift` へ分離。`swift build` 成功。
- 2026-06-20: Sticky Notes の追加修正として、drag reorder 後の薄い表示残り対策、Ctrl+Enter確定、付箋外クリックで一覧へ戻る挙動、別付箋クリック時のリアルタイム保存付き編集切替、色ダブルクリック新規作成、付箋グリッドサイズ `S/M/L` 切替を実装。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- 2026-06-20: Sticky Notes の Board Grid UI を追加。hover archive、フル幅に拡大する inline editor、color swatches、context menu、drag reorder、外部 drag text payload、undo toast を `StickyNotesView.swift` に実装し、`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- 2026-06-20: Sticky Notes の model / store / provider / Settings toggle を追加。Application Support `HoverPocket/StickyNotes/notes.json` への JSON 永続化、archive/delete undo、provider registry 接続を実装し、`swift build` と `git diff --check` 成功。
- 2026-06-20: Apple notarization を実行し、`HoverPocket-0.1.0-41.zip` を notarized/stapled ZIP として再生成。app 本体と ZIP 展開後 app の両方で Gatekeeper accepted を確認。
- 2026-06-19: 決定アプリアイコンを app bundle に反映し、Mirror camera の遅延停止/再起動競合を修正。実マウス移動の hover open / close 5サイクルで preview 再open を確認。
- 2026-06-07: Calendar provider に日付クリック固定、予定追加、編集、削除 UI / API を追加。OAuth scope は `calendar.events` に変更し、既存 read-only credential は再接続扱いにした。
- 2026-06-07: Clipboard provider と provider 表示/順番/default panel 設定を追加。
- 2026-06-07: Clipboard image drag の drop 互換性改善として、panel 一時非表示と file URL provider を追加。
- 2026-06-07: Mirror 下に compact microphone check row と Settings toggle を追加。
- 2026-06-07: Microphone permission 許可直後の crash を修正。CoreAudio tap closure を MainActor から分離し、権限待ち中に panel が閉じた場合は後から mic を起動しないようにした。
- 2026-06-07: Microphone meter 無反応対策として、input tap を `outputFormat(forBus:)` に変更し、dBFS ベースの感度へ調整。
- 2026-06-07: Microphone meter を Mirror 表示中に自動起動する仕様へ変更。右端 button は一時録音/停止/再生にし、再生完了後にメモリ上の録音を削除する。
- 2026-06-07: Microphone button 操作後に panel が閉じない問題を修正。preview 表示中だけ window controller 側で mouse location を監視して hover exit 取りこぼしを補完し、open animation 中の mouse event 無効時間を短縮。録音ボタンの hit area も 30pt に拡大。
- 2026-06-07: 一時的なアプリ名で SwiftPM package / executable / generated app bundle の公開名を更新。
- 2026-06-07: GitHub public repository `shotaro311/notch-pocket` を作成し、`main` を push。`gh repo view` で visibility `PUBLIC` を確認。
- 2026-06-07: README を日本語中心へ更新し、公開 GitHub のトップで概要と使い方が伝わる状態にした。
- 2026-06-08: provider アイコン切替時のヘッダー未更新バグを修正。`ProviderHeaderView` が `ProviderStore` を直接監視する構成に変更。
- 2026-06-08: `Codex PR Router` workflow を追加し、ハイブリッド自動修正運用の GitHub 側分類を導入。
- 2026-06-08: `github-codex-autofix` plugin を Mac / Windows に配置し、両環境で Codex Automation を設定。Windows 側は peer 経由で zip SHA 一致、script 存在、`list-targets` 対象なしを確認。
- 2026-06-08: 実PR `#1` で `Codex PR Router` のラベル付与、Mac helper の対象PR検出、claim / release、Windows helper の Mac向けPR除外を確認。検証PRはマージせず閉じ、テストブランチは削除済み。
- 2026-06-08: PR `#2` でパネル表示領域の `小 / 中 / 大` サイズ切替を追加。ヘッダーの `小 中 大` ボタンと Settings の `Panel size` picker から変更できる。
- 2026-06-08: PR `#2` のサイズボタンを現在サイズ1文字表示へ変更し、サイズ変更時の上端固定を確認。Mac / Windows のPR作成手順も Ready PR 前提へ更新。
- 2026-06-09: 上部ヘッダーの電源アイコンを廃止し、provider アイコン群と設定ボタンの間に薄い縦線の仕切りを追加。Settings の `Icon switching` で `Click / Hover` を選べるようにした。リファクタリングとして `ProviderHeaderView.swift` を分離し、`ProviderStore` の不要な設定変更再通知を減らした。
- 2026-06-09: Google OAuth Keychain 許可の毎回表示対策として、起動時の Keychain 読み込みを遅延し、開発ビルドの app bundle を Apple Development 署名に変更。
- 2026-06-09: アプリ名を正式名称の `ホバーポケット` / `HoverPocket` に変更し、README、SwiftPM product、build script、callback文言、progressを同期。source path は `Sources/HoverPocket`、provider protocol は `PocketProvider` へ更新。旧保存先から移行できる状態を維持。
- 2026-06-09: MIT License を追加し、README にライセンス欄を追加。GitHub 公開上のOSSライセンスを明確化。
- 2026-06-10: AI native Phase 1 MVP として、Apple Foundation Models provider、構造化 action / tool / approval / audit 基盤、Calendar read/write tool、下段 command palette lane、解釈候補 fallback UI を追加。`swift build` 成功。
- 2026-06-10: Review fix として ApprovalCard の全 approval field 表示と `requiresApproval` の computed 化を実施。`swift build` 成功。
- 2026-06-15: AI command palette 自動フォーカス、FoundationModels `@Generable` 経路、承認 summary、Calendar 日時手入力/ドラッグ調整、日付ダブルクリック新規予定起動を追加。`swift build` / `git diff --check` / `./script/build_and_run.sh --verify` 成功。
- 2026-06-04: Mirror close 時の点滅対策として、content 非表示化を window `orderOut` 後へ移動。
- 2026-06-04: Mirror の軽快化として、camera prewarm / provider active 分離 / eventDriven refresh skip を追加。見た目の animation は変更なし。
- 2026-06-04: Mirror のカクつき / ちらつき対策として、camera preview layer の暗黙 animation 無効化、animation 中 shadow off、閉じかけ再 hover の frame snap 防止、live camera への blur 削除を追加。
- 2026-06-04: Mirror が UI 枠より遅れて追従する問題に対応し、content reveal を window animation 完了後ではなく開始前へ移動。
- 2026-06-04: Mirror close 時の camera 残像対策として、close 開始時に provider active を落とし、camera preview fade を短縮。
- 2026-06-04: 繰り返し開閉時の処理系改善として、reset task 単一管理、同値 publish 抑制、camera active 重複通知抑制、provider select no-op を追加。
- 2026-06-04: `GoogleCalendarProvider`、Google OAuth loopback + PKCE、Keychain token保存、Calendar API client、月表示 + 日付hover詳細UI、Settings接続導線を追加。
- 2026-06-04: Google Calendar を実Googleアカウントで接続し、Calendar APIから予定取得できることを確認。
- 2026-06-04: Mirror の crash を修正し、preview layer 常駐化、4秒 warm grace、`vga640x480` preset で軽量化。
- 2026-06-04: Built-in `Mirror` provider を追加し、Mac camera の鏡プレビューを実装。
- 2026-06-03: 二段階の neck / overshoot animation を撤回し、直前の軽い morphing に戻した。
- 2026-06-03: preview close animation を open animation の逆再生に調整。
- 2026-06-03: top pill を文字なしの左側 arrow handle 表示へ変更。
- 2026-06-03: top pill の黒ベースを実ノッチ幅に合わせ、ノッチ裏の隙間を解消。
- 2026-06-03: top pill 上端のスリット状の抜けを黒 overfill で解消。
- 2026-06-03: 左上 handle のラウンド形状変更を撤回し、元の形へ復帰。
- 2026-06-03: Provider/Registry/Store の基盤を追加し、デモ用 sessions / usage 表示を削除。
- 2026-06-03: 設定ウィンドウを追加し、表示先を `Auto / Main / Sub` から選べるように変更。
- 2026-06-03: preview morphing を上部ノッチ中央から出て、上部ノッチ中央へ戻る動きに調整。
- 2026-06-03: notch sizing / point-pixel compensation の設計メモを README に追記。
- 2026-06-03: pill の下端の隙間を抑えるため、pill height を 33pt に調整。
- 2026-06-03: pill の上左右を丸めず、画面上面に接する top-docked design に調整。
- 2026-06-03: preview panel が pill 下端に接した小さいカプセルから液体的に広がる opening animation を追加。
- 2026-06-03: 上部 pill の位置を画面上端へ合わせ、余白 0pt に調整。
- 2026-06-02: Prototype app を `/Users/shotaro/code/share/hover-menu-preview` に移行し、開発用 Git repository と `.gitignore` を用意。
- 2026-06-02: 共通進捗管理を初期化。
