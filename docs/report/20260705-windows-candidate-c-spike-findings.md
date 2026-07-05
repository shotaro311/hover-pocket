---
project_slug: hover-pocket
date: 2026-07-05
worker: codex-w3
scope: Windows Phase 0 candidate C risk spikes
status: completed-with-environment-failures
---

# Windows Candidate C Spike Findings

## 結論

候補C(C#/.NET + WPF native shell + WebView2 UI)は、現時点では最終確定しない。

理由は、S1 と S3 の両方で WebView2 Runtime は検出できたものの、通常の WPF WebView2 baseline から `RenderProcessExited:LaunchFailed` / `GpuProcessExited:Crashed` が発生し、WebView2 の描画・DOM 実行・getUserMedia まで到達しなかったため。これは NOACTIVATE 固有の失敗とは断定できないが、候補Cの採用条件である WebView2 UI 基盤をこの検証環境では証明できなかった。

S2 の Clipboard listener / PNG 正規化 / drag payload 生成は自動検証で成功した。外部アプリへの実ドロップは未手動確認のため条件付き pass。

## 実装成果物

- `windows/spikes/HoverPocket.Spikes.sln`
- `windows/spikes/S1.WebView2NoActivate/`
- `windows/spikes/S2.ClipboardDragOut/`
- `windows/spikes/S3.WebView2Camera/`

## 参照した公式情報

- WebView2 WPF SDK package: https://www.nuget.org/packages/Microsoft.Web.WebView2/1.0.4022.49
- WebView2 WPF setup: https://learn.microsoft.com/en-us/microsoft-edge/webview2/get-started/wpf
- WebView2 SDK versioning / Release SDK + Evergreen Runtime: https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/versioning
- WebView2 `DefaultBackgroundColor`: https://learn.microsoft.com/en-us/microsoft-edge/webview2/reference/winrt/microsoft_web_webview2_core/corewebview2controller
- WebView2 `PermissionRequested` args: https://learn.microsoft.com/en-us/microsoft-edge/webview2/reference/winrt/microsoft_web_webview2_core/corewebview2permissionrequestedeventargs
- Win32 `AddClipboardFormatListener`: https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-addclipboardformatlistener
- Win32 `WM_CLIPBOARDUPDATE`: https://learn.microsoft.com/en-us/windows/win32/dataxchg/wm-clipboardupdate
- WPF Clipboard API: https://learn.microsoft.com/en-us/dotnet/api/system.windows.clipboard
- WPF drag/drop overview: https://learn.microsoft.com/en-us/dotnet/desktop/wpf/advanced/drag-and-drop-overview

## 検証環境メモ

- .NET SDK: `10.0.301`
- WebView2 NuGet: `Microsoft.Web.WebView2 1.0.4022.49`
- WebView2 Runtime detected by API: `150.0.4078.48`
- `dotnet restore` / `curl` は sandbox の Schannel で `SEC_E_NO_CREDENTIALS` 相当の TLS エラーになったため、公式 NuGet version 確認後、検証時だけ Node/OpenSSL 経由で一時取得した nupkg を local package source として restore した。workspace には nupkg を残していない。

## S1: WebView2 x NOACTIVATE 透過オーバーレイ

判定: fail(候補C確定には使えない。WebView2 baseline failure のため NOACTIVATE 固有判定は未確定)

実装:

- WPF borderless/topmost window。
- `WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW`、`WM_MOUSEACTIVATE -> MA_NOACTIVATE`。
- rounded Win32 region による角丸 clipping。
- `WebView2.DefaultBackgroundColor = Transparent`。
- HTML 側は透明 body + 暗色角丸 panel。
- hover は WebView DOM mouse enter/leave postMessage と host 側 0.12s polling を併用。
- `--verify` は `baseline-opaque`、`noactivate-opaque`、`noactivate-transparent-rounded` の3ケースを順番に検証。

自動検証結果:

- `dotnet run --project windows\spikes\S1.WebView2NoActivate\S1.WebView2NoActivate.csproj --no-build -- --verify`
- exit code: `1`
- runtime: `150.0.4078.48`
- `baseline-opaque`: fail。`RenderProcessExited:LaunchFailed`, `GpuProcessExited:Crashed`
- `noactivate-opaque`: fail。`RenderProcessExited:LaunchFailed`, `GpuProcessExited:Crashed`
- `noactivate-transparent-rounded`: fail。NOACTIVATE / TOOLWINDOW / transparent 設定自体は入ったが、WebView2 render process が起動失敗。

観察事実:

- 通常の WPF WebView2 baseline でも DOM probe が `null` になり、WebView2 render process が起動しない。
- NOACTIVATE style と transparent background の code path は設定できている。
- `DefaultBackgroundColor` の公式仕様では、透明は alpha `0` の完全透明のみ対応。半透明 alpha は非対応。したがって、角丸/半透明風の見た目は host window region と HTML の不透明/疑似半透明描画を組み合わせる必要がある。

制約事項:

- 現環境では WebView2 baseline が失敗するため、「NOACTIVATE 内で正常描画できるか」「クリック時にフォーカスを奪わないか」は未証明。
- click focus は自動化していない。手動確認が必要。
- GPU 無効化(`--disable-gpu`)と独立 user data folder 指定でも render process 起動失敗は解消しなかった。

候補C採用への影響:

- 採用保留。少なくとも別の通常 Windows desktop session で S1 baseline が通ることを確認してから、NOACTIVATE transparent rounded case を再判定する必要がある。

手動確認手順:

1. `dotnet run --project windows\spikes\S1.WebView2NoActivate\S1.WebView2NoActivate.csproj`
2. 暗色角丸 panel が描画されるか確認する。
3. Notepad など別アプリを foreground にした状態で panel をクリックし、foreground が奪われるか確認する。
4. panel 内外の mouse hover が host polling / WebView DOM postMessage と干渉しないか確認する。

## S2: クリップボード監視 + 外部ドラッグアウト

判定: 条件付き pass

実装:

- `AddClipboardFormatListener` + `WM_CLIPBOARDUPDATE` で text/image copy を検知。
- text は memory history 最大 30 件相当、image は memory history 最大 20 件相当。
- image は `PngBitmapEncoder` で PNG bytes へ正規化し、検証用に temp PNG file も作成。
- drag payload:
  - text: `DataFormats.UnicodeText`
  - image: `DataFormats.Bitmap` と `DataFormats.FileDrop`(PNG path)

自動検証結果:

- `dotnet build windows\spikes\S2.ClipboardDragOut\S2.ClipboardDragOut.csproj --no-restore`
- exit code: `0`
- warnings: `0`
- `dotnet run --project windows\spikes\S2.ClipboardDragOut\S2.ClipboardDragOut.csproj --no-build -- --verify`
- exit code: `0`
- `listener.text=True`
- `listener.image=True`
- `drag.unicodeText=True`
- `drag.bitmap=True`
- `drag.fileDrop=True`
- `image.pngFileExists=True`

観察事実:

- text と image の clipboard change は listener 経由で取得できた。
- image は PNG bytes として正規化できた。
- drag data object は text / bitmap / file drop の形式を持つ。

制約事項:

- Notepad / Explorer / browser 等への実ドロップは未手動確認。`DoDragDrop` を開始する UI は実装済みだが、自動 verifier では外部 app drop まで行っていない。
- 管理者/通常ユーザー境界、clipboard lock、巨大画像、HTML/RTF/file clipboard は未検証。
- requirements の永続保存(`history.json` / PNG 保存)は製品実装範囲であり、今回 spike は memory + temp PNG に限定。

候補C採用への影響:

- Clipboard / drag out は WPF + Win32 interop で実現可能性が高い。候補Cの阻害要因ではない。

手動確認手順:

1. `dotnet run --project windows\spikes\S2.ClipboardDragOut\S2.ClipboardDragOut.csproj`
2. Notepad などで text を copy し、history に追加されることを確認する。
3. Snipping Tool 等で image を copy し、history に追加されることを確認する。
4. `Drag Latest Item` から text を Notepad へ、image を Explorer または画像を受け取れる app へ drop する。
5. drag 中に HoverPocket 側 panel が drop target を覆わないよう、製品実装では drag start 時に panel を一時 hide する。

## S3: WebView2 getUserMedia カメラ

判定: fail(現環境では WebView2 page が ready にならず、camera 権限・起動・停止まで未到達)

実装:

- WPF WebView2 内で `https://hoverpocket-camera-spike.local/index.html` を virtual host mapping で配信。
- HTML は `navigator.mediaDevices.getUserMedia({ video: true, audio: false })` を呼び、`video { transform: scaleX(-1) }` で左右反転表示。
- `CoreWebView2.PermissionRequested` で `Camera` を `Allow`、`SavesInProfile=false`、`Handled=true` に設定。
- stop button / window close で `MediaStreamTrack.stop()` を呼ぶ。

自動検証結果:

- `dotnet run --project windows\spikes\S3.WebView2Camera\S3.WebView2Camera.csproj --no-build -- --verify`
- exit code: `1`
- runtime: `150.0.4078.48`
- `page.secureContext=False`
- `page.hasMediaDevices=False`
- `page.href=timeout`
- process failures: `RenderProcessExited:LaunchFailed`, `GpuProcessExited:Crashed`, `BrowserProcessExited:Unexpected`

観察事実:

- WebView2 Runtime は検出できるが、page ready message が返らない。
- `PermissionRequested` の camera flow まで到達していないため、Windows privacy deny/no camera の挙動は未検証。

制約事項:

- camera presence、Windows privacy deny、window close 後の camera release は未検証。
- S1 と同じ WebView2 render process 起動問題が先に出ている。

候補C採用への影響:

- Mirror provider を WebView2 UI 内 getUserMedia で実装する案は、現環境では採用可否を判断できない。WebView2 baseline が通る環境で再実行し、camera permission / stop の証跡が必要。

手動確認手順:

1. WebView2 render process が起動する通常 desktop session で `dotnet run --project windows\spikes\S3.WebView2Camera\S3.WebView2Camera.csproj` を実行する。
2. `Start camera` を押し、左右反転映像が表示されることを確認する。
3. `Stop camera` と window close で camera LED / privacy indicator が消えることを確認する。
4. Windows Settings で camera access を拒否し、`NotAllowedError` 等が UI に表示され crash しないことを確認する。

## 全体 build / run 証跡

- `dotnet restore windows\spikes\HoverPocket.Spikes.sln --source <temp local nupkg source>`
  - exit code: `0`
- `dotnet build windows\spikes\HoverPocket.Spikes.sln --no-restore`
  - exit code: `0`
  - warnings: `0`
  - errors: `0`
- S1 `--verify`
  - exit code: `1`
- S2 `--verify`
  - exit code: `0`
- S3 `--verify`
  - exit code: `1`

## 次の推奨判断

候補Cは、S1 と S3 を WebView2 render process が正常起動する通常 Windows user session で再検証するまで確定しない。

再検証で `baseline-opaque` が fail のままなら、WebView2 UI を前提にした候補Cは危険。`baseline-opaque` が pass し、`noactivate-transparent-rounded` だけ fail する場合は、preview panel を入力可能な通常 window とし、access surface だけ NOACTIVATE に分離する設計へ寄せる。両方 pass する場合のみ、候補Cを Phase 1 の第一候補として進められる。

## アーキテクト再検証(2026-07-05、通常デスクトップセッション)

W3 の S1/S3 fail は Codex sandbox(制限付きプロセス)内での実行が原因という仮説を立て、
アーキテクト(Claude)が sandbox 外の通常セッションで同一バイナリを再実行した。

### S1 再判定: pass(候補C確定条件を満たす)

- `dotnet run --project windows\spikes\S1.WebView2NoActivate -- --verify`: exit code `0`
- `baseline-opaque`: pass(processFailures なし)
- `noactivate-opaque`: pass。`initialized=True`、script 実行成功、NOACTIVATE/TOOLWINDOW
  style 維持、`foregroundUnchanged=True`
- `noactivate-transparent-rounded`: pass。`transparent=True` 含め全項目成立
- 残る手動確認: click focus の実ポインター操作のみ

### S3 再判定: WebView2 基盤は pass、カメラフローは環境要因で未検証

- `dotnet run --project windows\spikes\S3.WebView2Camera -- --verify`: exit code `2`
- WebView2 側はすべて正常: `page.secureContext=True`、`page.hasMediaDevices=True`、
  virtual host ページロード成功、processFailures なし
- fail 理由は `NotFoundError: Requested device not found`。`Get-PnpDevice -Class Camera` で
  この PC にカメラデバイスが物理的に存在しないことを確認済み(環境要因)
- `PermissionRequested` 発火(`cameraRequests=0`)を含むカメラフローは、カメラ搭載機での
  再検証項目として持ち越す

### 原因の切り分け

W3 実行時の `RenderProcessExited:LaunchFailed` / `GpuProcessExited:Crashed` は、Codex の
sandbox 内では WebView2 の子プロセス(renderer/GPU)起動が阻害されるためと確定。
同一バイナリが通常セッションでは全ケース起動することから、製品環境の制約ではない。
教訓: WebView2 を含む spike の自動検証は sandbox 外で実行する運用にする。

### 最終判定

- S1 pass + S2 条件付き pass + S3 基盤 pass により、**候補C(C#/.NET + WPF native shell +
  WebView2 UI)を Phase 1 の技術スタックとして採用確定**とする。
- 持ち越し検証: S2 外部アプリへの実ドロップ(手動)、S3 カメラフロー(カメラ搭載機)、
  S1 click focus(手動)。いずれも採用判断を覆すリスクは低いと評価。
