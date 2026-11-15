---
project_slug: hover-menu-preview
date: 2026-08-10
status: implemented; verified; local-debug-ready
---

# Windows Timer alert crash fix

## 症状

インストール済みWindows版0.2.5が、Timerの終了時に予告なく終了する。Windowsイベントログには2026-08-08 14:09と2026-08-09 23:10の2回、同じ例外経路が残っていた。以前のGraphics Capture停止競合による`0xC00000FD`とは別のクラッシュである。

## 原因

- `TimerStore`の満了確認は`System.Threading.Timer`のThreadPool threadで動く。
- `TimerBridgeHandlers.OnAlertFired`がそのthreadのまま`BridgeDispatcher.PostEventAsync("timer.alert", ...)`を呼ぶ。
- `PanelWindow`が登録したbridge callbackは、WPF WebView2の`CoreWebView2.PostWebMessageAsJson`へ直接アクセスしていた。
- WPF / WebView2は作成元のUI threadからのみアクセスできるため、未処理の`System.InvalidOperationException`「このオブジェクトは別のスレッドに所有されている」が発生し、プロセス全体が終了した。

イベントログのstackは`TimerStore.CheckExpired` → `TimerBridgeHandlers.OnAlertFired` → `BridgeDispatcher.PostEventAsync` → `PanelWindow.InitializeWebViewAsync`内callback → `WebView2.CoreWebView2`で一致した。

## 修正

- `PanelWindow`のbridge callbackを`PostBridgeJsonAsync`へ集約した。
- UI thread外からの送信は`PanelWindow.Dispatcher.InvokeAsync`でUI threadへ切り替えてからWebView2へ渡す。
- panelが閉じた後、別のWebViewへ差し替わった後、dispatcher shutdown中は送信をno-opにし、終了処理との競合を避ける。
- 実WebView2の`--verify ui`へ、ThreadPoolからbridge eventを送り、UI threadへの切り替えが完了する回帰ケースを追加した。この経路は修正前の実装では同じ所有thread例外になる。

## 検証

- Debug build: exit 0、warnings 0、errors 0。
- Release build: exit 0、warnings 0、errors 0。
- Debug全13 verifier（`shell` / `display` / `controls` / `ui` / `settings` / `updater` / `calendar` / `ui-model` / `sticky` / `clipboard` / `calc` / `timer` / `ailane`）: すべてexit 0。
- Release `timer` / `ui-model` / 実WebView2 `ui`: すべてexit 0。
- 修正後の検証時間帯に、Application logのHoverPocket `Application Error` / `.NET Runtime` eventは0件。
- `git diff --check`: exit 0。working treeのCRLF正規化warningのみ。
- 修正版Debugを期待する`bin/Debug/net10.0-windows10.0.22621.0/HoverPocket.Shell.exe`から1 processで起動し、ProductVersion `0.2.5+48697d1...`、`Responding=True`をreadbackした。

## 状態と残件

- インストール済み0.2.5（ProductVersion `0.2.5+1277173...`）は上書きしていない。公開release / Windows feedも変更していない。
- current local `main`は`origin/main`に対してahead 4 / behind 7であり、公開用commitへまとめる際は既存差分を保った統合が必要。
- 配布済みアプリへ恒久反映するには、versionを更新したWindows専用releaseを作り、公開・feed readback・実update applyを別途行う。
