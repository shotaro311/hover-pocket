---
project_slug: hover-pocket
date: 2026-07-05
worker: codex-w6
scope: Windows Phase 1 W6 Sticky Notes provider
status: implemented-non-webview-verified
---

# Windows Phase 1 W6 Sticky Notes

## 実装

- `windows/src/HoverPocket.Shell/Providers/Sticky/` を追加。
  - `StickyNoteItem`: `title`、`body`、`color`、`createdAt`、`updatedAt`、`archivedAt`、`sortIndex`。
  - `StickyNotesStore`: `%APPDATA%\HoverPocket\sticky\notes.json` と `settings.json` に JSON 永続化。
  - CRUD、並び替え、archive/delete、直前 archive/delete の Undo、空新規付箋 discard、破損 JSON 既定値復帰を実装。
  - Sticky 固有設定として `gridSize` と `showUndoToast` を保存。
- `StickyBridgeController` を追加し、Web UI から以下を呼べるようにした。
  - `sticky.getState`
  - `sticky.create`
  - `sticky.update`
  - `sticky.archive`
  - `sticky.delete`
  - `sticky.discard`
  - `sticky.undo`
  - `sticky.move`
  - `sticky.setGridSize`
  - `sticky.setUndoToastVisible`
  - `sticky.startExternalDrag`
- `windows/ui/providers/sticky/` を追加。
  - ボードグリッド S/M/L。
  - inline editor。
  - 色スウォッチ。ヘッダー色はダブルクリックでその色の新規付箋を作成。
  - `Control+Enter` で編集確定。
  - 空の新規付箋は通常確定時に discard。
  - HTML5 drag/drop による並び替え。
  - 右クリックメニューで編集、色変更、アーカイブ、削除。
  - ドラッグ中の下部 drop zone でアーカイブ。
  - archive/delete 後の Undo toast。
- 共有ファイルの追記。
  - `ProviderRegistry.cs`: sticky descriptor を実装済み説明へ更新。
  - `StartupOptions.cs` / `App.xaml.cs`: `--verify sticky` 分岐を追加。
  - `windows/ui/js/app.js`: W5 の renderer map に `sticky: renderStickyProvider` を追加。
  - `PanelBridgeController.cs`: sticky bridge handler 登録を追加。provider 固有 bridge 登録として扱った。

## 外部ドラッグ方式

- WebView2 内の通常 drag を外部アプリへ安定して渡すのは Phase 1 では難しい前提で、S2 findings に従い C# 側 `DragDrop.DoDragDrop` を使う方式にした。
- UI ではカード右上の外部ドラッグハンドルの `pointerdown` で `sticky.startExternalDrag` を呼び、C# 側が本文優先の Unicode text `DataObject` を作って `System.Windows.DragDrop.DoDragDrop(..., Copy)` を開始する。
- 制約:
  - ドラッグ開始は mouse/pointer down 起点である必要がある。click 起点にはしない。
  - WebView2 の postMessage 経由なので、通常 WebView2 実行環境での手動確認はアーキテクト通常 desktop session 待ち。
  - 本文が空の場合は title を fallback にする。

## 検証

- `node --check .\windows\ui\providers\sticky\sticky.js`: exit code 0。
- `node --check .\windows\ui\js\app.js`: exit code 0。
- `dotnet build .\windows\HoverPocket.Windows.sln`: exit code 0、警告 0。
  - 途中で `StickyBridgeController.cs` の WPF/WinForms `DragDropEffects` ambiguity が出たため、W6 側で WPF alias を明示して修正済み。
  - 一時的に W5/W7 並行作業ファイルの compile error でも止まったが、再実行時点では解消済み。
- `dotnet run --project .\windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify sticky`: exit code 0。
  - `PASS sticky verify: CRUD, reorder, archive/delete undo, blank discard, persistence, corrupt JSON recovery`
- `dotnet run --project .\windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify ui-model`: exit code 0。
  - `PASS ui-model verify: settings, provider registry, bridge dispatcher`
- `node --check .\windows\ui\providers\sticky\sticky.js`: exit code 0。
- `node --check .\windows\ui\js\app.js`: exit code 0。
- `git diff --check`: exit code 0。CRLF 変換警告のみ。

## 未検証・待ち

- WebView2 実行系での Sticky UI 操作確認。
- 外部ドラッグの実アプリ drop 確認。
- Undo toast 表示/非表示は Sticky 専用 `settings.json` と bridge method まで実装。W7 Settings UI への露出は W7/アーキテクトの共有設定画面側作業待ち。
