---
project_slug: hover-pocket
date: 2026-07-06
worker: codex-w6
scope: Sticky Notes drag-to-trash archive bugfix
status: verified-non-webview
---

# Windows Sticky Notes Drag-To-Trash Bugfix

## 原因

- `windows/ui/providers/sticky/sticky.js` の HTML5 drag/drop 中に `render()` を呼び、DOM 全体を差し替えていた。
- 特に以下が問題だった。
  - `dragstart` 後に `requestAnimationFrame(render)` で drag source と drop target を作り直していた。
  - trash drop zone は `draggingNoteId` がある時だけ DOM に追加される設計だった。
  - trash zone の `dragover` / `dragleave` でも毎回 `render()` していた。
- WebView2/Chromium の HTML5 DnD 中に drop target を再生成すると、hit 判定や `drop` 発火が不安定になる。実機では下部ゴミ箱領域へ drop しても archive bridge まで到達しない状態だったと判断した。

## 修正

- パネル内ドラッグと外部ドラッグの発動条件を明確に分離。
  - 付箋本体の HTML5 drag/drop はパネル内操作専用: 並び替えと下部ゴミ箱 archive。
  - 右上の外部ドラッグハンドルだけが `sticky.startExternalDrag` を呼び、C# `DoDragDrop` を開始する。
- trash drop zone を常設 DOM に変更。
  - 通常時は CSS の `opacity: 0` と `pointer-events: none` で非表示。
  - drag 中だけ `.is-visible` を付けて hit 可能にする。
- drag 中は `render()` で DOM を差し替えず、`.is-dragging`、`.is-drop-target`、`.is-visible`、`.is-targeted` の class 切替だけにした。
- trash drop 時は `sticky.archiveDropped` を呼ぶようにした。
  - `StickyNotesStore.ArchiveDroppedNote()` を追加。
  - `StickyBridgeController` に `sticky.archiveDropped` を追加。
  - `StickyVerifier` に drop archive 相当の archive/undo 検査を追加。

## 検証

- `node --check .\windows\ui\providers\sticky\sticky.js`: exit code 0。
- `dotnet run --project .\windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify sticky`: exit code 0。
  - `PASS sticky verify: CRUD, reorder, archive/drop/delete undo, blank discard, persistence, corrupt JSON recovery`
- `dotnet build .\windows\HoverPocket.Windows.sln --nologo`: exit code 0、警告 0。
- `dotnet run --project .\windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -- --verify ui-model`: exit code 0。
  - `PASS ui-model verify: settings, provider registry, bridge dispatcher`
- `git diff --check`: exit code 0。CRLF 変換警告のみ。

## ユーザー確認待ち

- 実機 WebView2 UI で、付箋本体をドラッグして下部ゴミ箱領域に drop すると archive され、Undo toast が出ること。
- 外部ドラッグは右上の外部ドラッグハンドルからだけ発動し、付箋本体ドラッグによるパネル内ゴミ箱 drop と競合しないこと。
