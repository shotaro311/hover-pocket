---
project_slug: hover-pocket
date: 2026-07-05
worker: codex-w4
scope: Windows Phase 1 W4 WebView2 integration base
status: implemented-with-architect-ui-verify-pending-after-fix
---

# Windows Phase 1 W4 作業ログ

## 実施内容

- `PanelWindow` に WebView2 host を追加。`DefaultBackgroundColor=Transparent`、`SetVirtualHostNameToFolderMapping("app.hoverpocket.local", windows/ui)`、`PostWebMessageAsJson` / `WebMessageReceived` を使う構成にした。
- S1 spike の NOACTIVATE 方針を製品側へ反映。`WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW` 維持に加え、`WM_MOUSEACTIVATE -> MA_NOACTIVATE`、host HWND の rounded region clipping を追加した。
- `windows/ui/` に bundler なしの静的 asset 骨格を追加。`index.html`、`styles.css`、ES modules `js/bridge.js` / `js/app.js`、placeholder provider module を配置した。
- CSS custom properties で暗色コンパクトパネルの基礎 theme を定義。header 54px、AI lane 132px、panel S/M/L は 520x372 / 600x430 / 680x488 の Provider 領域 + AI lane 加算で扱う。
- C# `Bridge/` に dispatcher と panel bridge controller を追加。JS 側 `bridge.js` と `{id, method, params}` request、response、`state.changed` event の双方向基盤を実装した。
- C# `Providers/ProviderRegistry` に placeholder provider 3 枠(`calculator` / `timer` / `sticky`)を登録。provider 切替で header title と body が同じ C# state から同期更新される。
- `%APPDATA%\HoverPocket\settings.json` 用の `UserSettingsStore` を追加。panel size、text size、provider order、visibility、switching mode、language を保持し、破損 JSON は既定値へ復帰する。
- `--verify ui` と WebView2 非依存の `--verify ui-model` を追加。`shell` / `display` verifier では WebView2 を起動せず、一時 settings store を使うようにして sandbox 検証を分離した。

## 検証結果

- `dotnet build windows\HoverPocket.Windows.sln`
  - exit code: `0`
  - warnings: `0`
  - errors: `0`
- `HoverPocket.Shell.exe --verify ui-model`
  - exit code: `0`
  - `PASS ui-model verify: settings, provider registry, bridge dispatcher`
- `HoverPocket.Shell.exe --verify shell`
  - exit code: `0`
  - `PASS shell verify: windows=11, cycles=25`
- `HoverPocket.Shell.exe --verify display`
  - exit code: `0`
  - `PASS display verify: monitors=1, current_surfaces=1`
  - monitor: `monitor-0-10001`, primary `True`, bounds `0,0 5120x2160`, dpi `144x144`
- `dotnet run --project windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify ui`
  - exit code: `1`
  - WinExe stdout は空だったため、同一 built exe を同期起動して詳細確認した。
- `HoverPocket.Shell.exe --verify ui`
  - exit code: `1`
  - `FAIL ui verify`
  - error: `COMException: 致命的なエラーです。 (0x8000FFFF (E_UNEXPECTED))`
- `git diff --check -- windows progress docs/plan`
  - exit code: `0`
  - 空白エラーなし。改行コード警告のみ。

## アーキテクト実行待ち項目

- `--verify ui` は WebView2 初期化で `COMException E_UNEXPECTED` になった。計画書 A4 の sandbox 内 WebView2 renderer 起動制約に該当するため、リトライせずアーキテクトの通常 desktop session 実行待ち。
- アーキテクト側では `HoverPocket.Shell.exe --verify ui` または `dotnet run --project windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify ui` を実行し、WebView2 初期化、bridge round-trip、provider switch、settings read/write の pass を確認する。

## 判断メモ

- WebView2 公式 docs で `SetVirtualHostNameToFolderMapping`、`PostWebMessageAsJson`、`WebMessageReceived`、`CoreWebView2Environment` user data folder、`DefaultBackgroundColor` を確認した。
- 公式 docs には `.local` host の navigation delay 注意があるが、計画書 A1 が `https://app.hoverpocket.local/` を固定しているため今回は計画書を優先した。通常 session の `--verify ui` で遅延が出る場合は host 名変更をアーキテクト判断に戻す。
- shell/display verifier は Phase 0 の非 WebView2 検証として維持するため、WebView2 lazy init を `enablePanelWebView` で分岐した。
- `%APPDATA%` への sandbox 書き込みが denied になるため、verify 系は一時 settings store を使用する。製品通常起動は `%APPDATA%\HoverPocket\settings.json` を使う。

## 差し戻し対応(2026-07-05)

### 差し戻し内容

- アーキテクト通常 desktop session の `--verify ui` が exit code `1` で fail。
- error: `JsonException: The JSON value could not be converted to System.String. Path: $ | LineNumber: 0 | BytePositionInLine: 1.`
- 推定箇所: `PanelWindow.RunWebVerifyScriptAsync()` の `JsonSerializer.Deserialize<string>(resultJson)`。

### 修正内容

- WebView2 公式 docs で `ExecuteScriptAsync` の戻り値が「JavaScript 評価結果を JSON encoded string として返す」仕様であることを再確認した。
- `RunWebVerifyScriptAsync()` から `JsonSerializer.Deserialize<string>(resultJson)` の二重エンコード前提を削除した。
- JS verifier は `window.__hoverPocketVerify.run()` を開始し、完了結果を `window.__hoverPocketVerifyResult`、エラーを `window.__hoverPocketVerifyError` に格納する方式に変更した。
- C# 側は `ExecuteScriptAsync("window.__hoverPocketVerifyResult")` の戻り値を `UiWebVerifyResult` として直接 deserialize する。これにより、JS object と C# decode が 1 段の JSON に揃う。
- 同種点検: `ExecuteScriptAsync` 使用箇所は `PanelWindow.cs` のみ。ready check は boolean JSON を直接比較し、error は string/null、verify result は object/null として扱う。`Deserialize<string>` の二重エンコード前提は残っていない。
- アーキテクト追加の `Verification/VerifyConsole.cs` の `HOVERPOCKET_VERIFY_LOG` ファイルログ出力は維持した。

### 再検証結果

- `dotnet build windows\HoverPocket.Windows.sln`
  - exit code: `0`
  - warnings: `0`
  - errors: `0`
- `dotnet run --project windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify shell`
  - exit code: `0`
  - log: `PASS shell verify: windows=11, cycles=25`
- `dotnet run --project windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify display`
  - exit code: `0`
  - log: `PASS display verify: monitors=1, current_surfaces=1`
  - monitor: `monitor-0-10001`, primary `True`, bounds `0,0 5120x2160`, dpi `144x144`
- `dotnet run --project windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify ui-model`
  - exit code: `0`
  - log: `PASS ui-model verify: settings, provider registry, bridge dispatcher`

### アーキテクト実行待ち

- 修正後の `--verify ui` は sandbox 内では再実行していない。計画書 A4 に従い、通常 desktop session でのアーキテクト再実行待ち。
- 再実行対象: `dotnet run --project windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify ui`
