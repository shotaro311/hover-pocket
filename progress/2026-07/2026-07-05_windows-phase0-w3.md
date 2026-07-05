---
project_slug: hover-pocket
task: windows-phase0-w3
date: 2026-07-05
worker: codex-w3
status: completed-with-environment-failures
---

# Windows Phase 0 W3 candidate C risk spikes

## 実施内容

- `windows/spikes/HoverPocket.Spikes.sln` を作成し、本体 `windows/HoverPocket.Windows.sln` とは分離した。
- `S1.WebView2NoActivate` を追加。WPF borderless/topmost window、`WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW`、`WM_MOUSEACTIVATE -> MA_NOACTIVATE`、rounded Win32 region、WebView2 transparent background、HTML dark rounded panel、hover postMessage + 0.12s polling を実装。
- `S1 --verify` は `baseline-opaque`、`noactivate-opaque`、`noactivate-transparent-rounded` の3ケースで WebView2 baseline と NOACTIVATE/transparent case を切り分けるようにした。
- `S2.ClipboardDragOut` を追加。`AddClipboardFormatListener` / `WM_CLIPBOARDUPDATE`、text/image memory history、PNG 正規化、`UnicodeText` / `Bitmap` / `FileDrop` drag payload を実装。
- `S3.WebView2Camera` を追加。WebView2 virtual host mapping、HTML `getUserMedia({ video: true, audio: false })`、左右反転 video、`CoreWebView2.PermissionRequested` camera allow、script stop/window close stop を実装。
- findings を `docs/report/20260705-windows-candidate-c-spike-findings.md` に記録した。
- `windows/src/` は読み取りのみ。変更していない。

## 参照した公式情報

- NuGet `Microsoft.Web.WebView2 1.0.4022.49`
- Microsoft Learn: WebView2 WPF setup / versioning / `DefaultBackgroundColor` / `PermissionRequested`
- Microsoft Learn: `AddClipboardFormatListener` / `WM_CLIPBOARDUPDATE`
- Microsoft Learn: WPF `Clipboard` / drag-and-drop overview

## 検証結果

- `dotnet restore windows\spikes\HoverPocket.Spikes.sln --source <temp local nupkg source>`
  - exit code: 0
  - 補足: この sandbox では NuGet/curl の HTTPS が Schannel `SEC_E_NO_CREDENTIALS` 系で失敗したため、公式 version 確認後に Node/OpenSSL で一時取得した nupkg を local source にした。workspace に nupkg は残していない。
- `dotnet build windows\spikes\HoverPocket.Spikes.sln --no-restore`
  - exit code: 0
  - warnings: 0
  - errors: 0
- `dotnet build windows\spikes\S2.ClipboardDragOut\S2.ClipboardDragOut.csproj --no-restore`
  - exit code: 0
  - warnings: 0
  - errors: 0
- `dotnet run --project windows\spikes\S2.ClipboardDragOut\S2.ClipboardDragOut.csproj --no-build -- --verify`
  - exit code: 0
  - `listener.text=True`
  - `listener.image=True`
  - `drag.unicodeText=True`
  - `drag.bitmap=True`
  - `drag.fileDrop=True`
  - `image.pngFileExists=True`
- `dotnet run --project windows\spikes\S1.WebView2NoActivate\S1.WebView2NoActivate.csproj --no-build -- --verify`
  - exit code: 1
  - WebView2 Runtime: `150.0.4078.48`
  - `baseline-opaque`: `RenderProcessExited:LaunchFailed`, `GpuProcessExited:Crashed`
  - `noactivate-opaque`: `RenderProcessExited:LaunchFailed`, `GpuProcessExited:Crashed`
  - `noactivate-transparent-rounded`: NOACTIVATE/TOOLWINDOW/transparent は設定されたが `RenderProcessExited:LaunchFailed`, `GpuProcessExited:Crashed`
- `dotnet run --project windows\spikes\S3.WebView2Camera\S3.WebView2Camera.csproj --no-build -- --verify`
  - exit code: 1
  - WebView2 Runtime: `150.0.4078.48`
  - `page.href=timeout`
  - `RenderProcessExited:LaunchFailed`, `GpuProcessExited:Crashed`, `BrowserProcessExited:Unexpected`

## 判定

- S1: fail。現環境では WebView2 baseline から render process 起動失敗。NOACTIVATE 固有の可否は未確定。
- S2: 条件付き pass。Clipboard listener、PNG 正規化、drag payload 形式は自動検証成功。外部 app への実 drop は未手動確認。
- S3: fail。WebView2 page ready まで到達せず、camera permission / getUserMedia / release は未検証。

## 未実施・未検証事項

- S1 の実クリック時 focus 奪取有無は未手動確認。
- S1 の WebView2 正常描画は未確認。現環境では baseline も失敗。
- S2 の Notepad / Explorer 等への実 drag/drop は未手動確認。
- S3 の camera presence、Windows privacy deny、window close 後の camera release は未確認。

## 判断メモ

- WebView2 `DefaultBackgroundColor` は公式仕様上、完全透明(alpha 0)または不透明(alpha 255)のみ。半透明 alpha は不可。角丸・透過風は host HWND region と HTML 側描画の組み合わせで作る前提にした。
- `PermissionRequested` は camera request に対して `State=Allow`、`SavesInProfile=false`、`Handled=true` とした。ただし現環境では page が ready にならず、イベント発火まで未到達。
- 候補Cは、WebView2 render process が正常起動する通常 Windows desktop session で S1/S3 を再検証するまで確定しない。
