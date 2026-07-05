---
project_slug: hover-pocket
target: Windows Phase 1 W7 Settings + AI command lane
date: 2026-07-05
worker: codex-w7
status: implemented-build-blocked-by-w5
---

# Windows Phase 1 W7 作業ログ

## 実装

- Settings Phase 1 対象を `UserSettings` / bridge / WebView2 Settings window に接続。
  - UI language: `ja` / `en`
  - Panel size: `small` / `medium` / `large`
  - Panel text size: `small` / `medium` / `large`
  - Provider switching: `click` / `hover`
  - Provider visibility/order
  - Start with Windows: 既定オフ
- Settings window は通常の WPF `Window` として追加し、`windows/ui/settings/index.html` を WebView2 で表示。
- Settings を開く経路をパネルの settings button と tray menu に接続。開く前に hover panel を閉じる。
- Start with Windows は Microsoft Learn の Run / RunOnce registry key 説明に沿って、HKCU `Software\Microsoft\Windows\CurrentVersion\Run` の `HoverPocket` 値で登録/解除する実装にした。
- `--verify settings` 分岐と dry-run 用 `InMemoryStartupRegistrationService` を追加。
- AI command lane をパネル下部固定 132px の DOM として接続。
  - `今日の予定` など read 系は Phase 2 Calendar 接続予定の案内を返す。
  - `明日14時 打ち合わせ` など create 系は承認カードを返す。
  - 承認カードは title/start/end/all-day/location/notes/calendar を省略せず表示するモデルにした。
  - 承認しても Phase 1 では実行せず、Phase 2 接続予定の結果を返す。
  - 承認/却下/失敗を `%APPDATA%\HoverPocket\auditlog\ailane-YYYYMMDD.jsonl` へ記録する。command text/title/location/notes などの個人情報は書かず、action type、decision、field keys、reason だけを記録する。
- `--verify ailane` 分岐を追加。
- パネル表示時は `panel.opened` event で AI lane input focus を試みる。NOACTIVATE panel のため OS レベルで実フォーカスを奪えるかは WebView2 実行系検証待ち。

## 変更ファイル

- `windows/src/HoverPocket.Shell/Configuration/UserSettings.cs`
- `windows/src/HoverPocket.Shell/Configuration/UserSettingsStore.cs`
- `windows/src/HoverPocket.Shell/Settings/*`
- `windows/src/HoverPocket.Shell/Providers/AiLane/*`
- `windows/src/HoverPocket.Shell/Bridge/PanelBridgeController.cs`
- `windows/src/HoverPocket.Shell/Windows/HoverShellController.cs`
- `windows/src/HoverPocket.Shell/Services/TrayIconService.cs`
- `windows/src/HoverPocket.Shell/StartupOptions.cs`
- `windows/src/HoverPocket.Shell/App.xaml.cs`
- `windows/ui/index.html`
- `windows/ui/js/app.js`
- `windows/ui/js/i18n.js`
- `windows/ui/ailane/ailane.js`
- `windows/ui/settings/*`
- `windows/ui/styles.css`

## 検証

- `node --check windows\ui\js\app.js`: exit 0
- `node --check windows\ui\ailane\ailane.js`: exit 0
- `node --check windows\ui\settings\settings.js`: exit 0
- `node --check windows\ui\js\i18n.js`: exit 0
- `dotnet build windows\HoverPocket.Windows.sln`: exit 1
  - W7 側の `Path` using 漏れ修正後、W7 ファイル起因の compile error は表示されていない。
  - 残エラーは W5 領域:
    - `windows/src/HoverPocket.Shell/Providers/Calculator/CalculatorBridgeHandlers.cs(34,9)`: `Clipboard` が `System.Windows.Forms.Clipboard` と `System.Windows.Clipboard` であいまい。
    - `windows/src/HoverPocket.Shell/Providers/Calculator/CalculatorEngine.cs(205,56)`: `char` から `string` へ変換不可。
    - `windows/src/HoverPocket.Shell/Providers/Calculator/CalculatorEngine.cs(230,38)`: `char` から `string` へ変換不可。
- `dotnet run --project windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify settings`: exit 1
  - 上記 Calculator compile error により verifier 実行前に停止。
- `dotnet run --project windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify ailane`: exit 1
  - 上記 Calculator compile error により verifier 実行前に停止。
- `dotnet run --project windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify ui-model`: exit 1
  - 上記 Calculator compile error により verifier 実行前に停止。

## 未検証

- `--verify settings` の runtime 結果。
- `--verify ailane` の runtime 結果。
- `--verify ui-model` の runtime 結果。
- Settings window の WebView2 実起動と panel close 動作。
- NOACTIVATE panel 内の AI lane input focus が実操作で期待通り入るか。

## アーキテクト実行待ち

- 計画 A4 に従い、WebView2 実行系検証は通常 desktop session でのアーキテクト実行待ち。
- W5 Calculator compile error 解消後に、`dotnet build`、`--verify settings`、`--verify ailane`、`--verify ui-model` を再実行する必要がある。

## 追加タスク追記: Sticky Notes Undo toast Settings 露出

- requirements §5 の `Sticky Notes undo toast: 表示 / 非表示` を Settings window に追加。
  - `windows/ui/settings/index.html` に Sticky Notes section と checkbox を追加。
  - `windows/ui/settings/settings.js` で `sticky.getState` から `preferences.showUndoToast` を読み、変更時に `sticky.setUndoToastVisible` を呼ぶようにした。
  - `windows/ui/js/i18n.js` に ja/en 文言を追加。
- 正本判断:
  - Undo toast 設定は W6 の `StickyNotesStore` / `%APPDATA%\HoverPocket\sticky\settings.json` が正本。
  - `UserSettings` へは項目追加しない。Settings は Sticky bridge の薄い操作 UI として接続し、二重管理を避けた。
- Sticky Notes grid size 判断:
  - W6 が provider 内 UI の S/M/L ボタンと `sticky.setGridSize`、Sticky 専用 `settings.json` 永続化を実装済み。
  - requirements §5 の露出は provider 内で完結しているため、Settings window には追加しない。
- 実ユーザーデータ保護:
  - `PanelBridgeController` の Sticky store を `settingsStore.RootDirectory\sticky` に揃え、verifier の temporary root が Sticky preferences も隔離するようにした。通常 app では従来と同じ `%APPDATA%\HoverPocket\sticky`。

## 追加タスク検証

- `node --check windows\ui\settings\settings.js`: exit 0
- `node --check windows\ui\js\i18n.js`: exit 0
- `node --check windows\ui\js\app.js`: exit 0
- `node --check windows\ui\ailane\ailane.js`: exit 0
- `dotnet build windows\HoverPocket.Windows.sln`: exit 0 / 警告 0
- `dotnet run --project windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify settings`: exit 0
- `dotnet run --project windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify sticky`: exit 0
- `dotnet run --project windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify ui-model`: exit 0
- `dotnet run --project windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify ailane`: exit 0
- `git diff --check`: exit 0。CRLF 変換警告のみ。

## 追加タスク後の未検証

- WebView2 実行系での Settings window 操作確認は、計画 A4 に従いアーキテクト通常 desktop session 実行待ち。
- Settings からの Undo toast toggle 実 UI 操作は WebView2 実行系検証待ち。非 UI verifier では bridge 経由の読み書きと永続化を検証済み。
