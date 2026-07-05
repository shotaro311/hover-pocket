---
project_slug: hover-pocket
target: Windows Phase 1 W5 Calculator + Timer
date: 2026-07-05
worker: codex-w5
status: integrated-verified
---

# Windows Phase 1 W5 作業ログ

## 実装

- Calculator:
  - `windows/src/HoverPocket.Shell/Providers/Calculator/CalculatorEngine.cs`
    - 四則演算、小数、符号反転、% 、Backspace、AC、0 除算 Error、Error からの次入力復帰を C# 側に実装。
    - `CalculatorSnapshot` で `display` / `hasError` / `canCopy` を返す形にした。
  - `CalculatorVerifier.cs`
    - `--verify calc` 用に、四則、小数、% 、符号反転、0除算 Error、Error 復帰、Backspace、AC、Error 中 copy 無効を検証。
  - `CalculatorBridgeHandlers.cs`
    - `calculator.getState`、`calculator.press`、`calculator.copy` の handler 登録クラスを provider 領域内に用意。
  - `windows/ui/providers/calculator/`
    - 演算子表示 `÷ × − +`、`0` 2列幅、数字/演算子/Enter/Escape/Backspace/Ctrl+C 入力対応の Web UI を追加。

- Timer:
  - `windows/src/HoverPocket.Shell/Providers/Timer/TimerStore.cs`
    - 既定保存先を `%APPDATA%\HoverPocket\timer\` に設定。
    - 通常タイマー既定 10 分、Pomodoro work 25 分 / rest 5 分、実行中最大 2、pin preset 最大 4 を実装。
    - 残り時間は `EndAtUtc` ベースで計算し、pause/resume は残り秒と新しい絶対終了時刻で管理。
    - 復元時に期限切れ済みの実行中 timer を破棄。
    - 音あり timer 終了時は `SystemSounds.Exclamation` の単純ループ再生を開始し、`stopAlert` で停止。
  - `TimerVerifier.cs`
    - `--verify timer` 用に default、start/pause/resume/stop、最大2、永続化/復元、期限切れ破棄、絶対時刻計算、Pomodoro work→rest 遷移、音ループ開始を検証。
  - `TimerBridgeHandlers.cs`
    - `timer.getState`、`timer.updateDraft`、`timer.start`、`timer.pause`、`timer.resume`、`timer.stop`、`timer.stopAlert`、`timer.pinPreset`、`timer.removePinnedPreset`、`timer.togglePin` の handler 登録クラスを provider 領域内に用意。
  - `windows/ui/providers/timer/`
    - 通常タイマー/Pomodoro 入力カード、title、color、sound toggle、直接入力 + range 調整、running/pinned/alert 表示を追加。

- 共有ファイルの最小追記:
  - `ProviderRegistry.cs`: Calculator/Timer の placeholder 文言を実体 provider 文言へ更新。
  - `StartupOptions.cs` / `App.xaml.cs`: `--verify calc` と `--verify timer` 分岐を追加。W6/W7 の `sticky/settings/ailane` 分岐は保持。
  - `windows/ui/js/app.js`: Calculator/Timer renderer を provider map に登録。W6/W7 の sticky/AI lane/settings 変更は保持。

## 検証

- `dotnet build .\windows\HoverPocket.Windows.sln`
  - exit code 0
  - 警告 0 / エラー 0
- `dotnet run --project .\windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify calc`
  - exit code 0
- `dotnet run --project .\windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify timer`
  - exit code 0
- `dotnet run --project .\windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify ui-model`
  - exit code 0
- `node --check windows\ui\js\app.js`
  - exit code 0
- `node --check windows\ui\providers\calculator\calculator.js`
  - exit code 0
- `node --check windows\ui\providers\timer\timer.js`
  - exit code 0
- `git diff --check`
  - exit code 0

## 未完了 / アーキテクト判断待ち

- `CalculatorBridgeHandlers` と `TimerBridgeHandlers` は provider 領域内に用意したが、`PanelBridgeController.Attach()` からの登録呼び出しは未実施。
  - 理由: `PanelBridgeController` は Bridge 共通基盤であり、W5 のファイル領域契約では変更禁止。
  - 影響: Web UI は `calculator.*` / `timer.*` bridge method を呼ぶ実装だが、共通 Bridge に登録されるまでは実 UI 操作時に unknown method になる。
- Timer 終了時の「パネル自動表示 + Timer provider を開く + ハンドル/ミニバーのハイライト」は未接続。
  - provider 側では `TimerStore.AlertFired` と `timer.alert` event payload を用意した。
  - 実際の自動表示、provider 選択、AccessSurface/handle highlight は `HoverShellController`、`PanelBridgeController`、`AccessSurfaceWindow` など共通シェル変更が必要なため、契約どおり未変更。
- WebView2 実表示検証は計画書 A4 の通り Codex sandbox では未実施。通常 desktop session でのアーキテクト実行待ち。

## 統合ターン追記

- アーキテクト指示により、このターンに限って共有基盤変更制限が解除されたため、上記の未接続だった bridge / shell 統合を実施。
- `CalculatorBridgeHandlers` / `TimerBridgeHandlers` を `PanelBridgeController.Attach()` に登録。
  - `ui-model` verifier に `calculator.press` と `timer.getState` の dispatch 確認を追加。
  - Timer 永続化先は `PanelBridgeController` 生成時に `UserSettingsStore.RootDirectory\timer` を渡す形にし、通常実行では `%APPDATA%\HoverPocket\timer\`、verify では一時ディレクトリを使うようにした。
- Timer 終了時連携を追加。
  - `TimerBridgeHandlers` が `AlertFired` / `AlertChanged` を shell に伝播。
  - `HoverShellController` が alert fired 時に Timer provider を選択し、パネルを自動表示。
  - `AccessSurfaceWindow` に静的ハイライト API を追加し、Timer color に応じてミニバーを強調表示。アニメーションを使わないため Reduce Motion 相当では静的 fallback になる。
  - alert active 中は pointer outside の自動 close delay でパネルを閉じない。
  - `timer.stopAlert` / alert 対象 timer stop 時にハイライトを解除。
- 統合ビルドで報告されていた W5 compile error 3件は現状コード上で解消済み。
  - `CalculatorBridgeHandlers.cs`: `System.Windows.Clipboard.SetText` を明示。
  - `CalculatorEngine.cs`: `StartsWith("-")` により `char` / `string` 不一致を解消。
- 統合回帰で `--verify ailane` が `14時` を `4時` と解釈して失敗したため、設計判断不要の明白な回帰として `AiLaneCommandInterpreter` の時刻抽出を最小修正。
  - `14時` など 2 桁時刻を優先して読む regex に変更。

## 統合ターン検証

- `dotnet build windows\HoverPocket.Windows.sln --nologo`
  - exit code 0
  - 警告 0 / エラー 0
- `dotnet run --no-build --project windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify shell`
  - exit code 0
- `dotnet run --no-build --project windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify display`
  - exit code 0
- `dotnet run --no-build --project windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify ui-model`
  - exit code 0
- `dotnet run --no-build --project windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify calc`
  - exit code 0
- `dotnet run --no-build --project windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify timer`
  - exit code 0
- `dotnet run --no-build --project windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify sticky`
  - exit code 0
- `dotnet run --no-build --project windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify settings`
  - exit code 0
- `dotnet run --no-build --project windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify ailane`
  - exit code 0
- `node --check windows\ui\js\app.js`
  - exit code 0
- `node --check windows\ui\providers\calculator\calculator.js`
  - exit code 0
- `node --check windows\ui\providers\timer\timer.js`
  - exit code 0
- `node --check windows\ui\ailane\ailane.js`
  - exit code 0
- `git diff --check`
  - exit code 0

補足:

- `ailane` 再検証の初回は、同時に走らせた `dotnet build` と `dotnet run` が同じ `obj\Debug\net10.0-windows\HoverPocket.Shell.dll` を触って file lock になった。30 秒待機後、ビルド済み成果物に対して `--no-build` で再実行し exit code 0 を確認。
- `--verify ui` と Settings ウィンドウ実起動を含む WebView2 実行系検証は、計画書 A4 の通り通常 desktop session でのアーキテクト実行待ち。
