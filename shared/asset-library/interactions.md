# Library interactions v1 (2026-10-05)

Mac owns the shared assets UI; each OS implements its native bridge. No database migration: assets and memberships remain schema version 1.

- `assets.copy {id,ids,mode:"drag",dropTargets:[{kind,folderId?,bounds:{x,y,width,height}}],trashBounds?}`. Bounds are viewport CSS pixels. Supported kinds: `folder`, `trash`, `favorite`, `unfiled`. Native result: `{ok,droppedInTrash?,dropTarget?:{kind,folderId?}}`. Cancellation returns no destination. Native accepts internal targets only for its active source session.
- `assets.dragMoved {x,y}` native event; `assets.dragTargetHover {dropTarget}` optional event. JS highlights/scrolls the sidebar and updates clipped rectangles through `assets.dragTargets {dropTargets}`. Never accept the last hover alone as proof of a drop.
- `assets.update {operation:"organize",ids,sourceFolderId:null|string,destination:{kind,folderId?}}` atomically validates every ID and folder. Missing targets reject the whole operation. Result `{ok:true,undoToken}`.
- Folder A to B removes only A, preserving other memberships and tags. All/search/multiple-folder views pass null and add B. Trash to folder restores and adds B, preserving old memberships. Favorite restores and sets true; unfiled restores and removes only folder memberships; trash sets soft trash. IDs/original bytes remain unchanged.
- `assets.update {operation:"undoOrganize",undoToken}` restores the snapshot once; later edits or state conflicts reject stale undo. Existing `assets.undo` remains the ordinary undo action.
- `assets.capture {kind:"cameraPhoto"|"cameraVideo"|"audio",folderId:null|string}` opens native device/save UI. Recording requires explicit start. Existing screenshot/recording kinds remain supported. Closing library does not stop an active capture.
- External import copies source files, image data, file promises/virtual files, and direct media URLs. It must never ingest the app's own internal drag or claim web pages/streaming video are downloadable. A native top-edge overlay offers destination folders and import/error feedback.

- `assets.preview` may return `audioUrl` for supported audio extensions while keeping persisted `kind:other`. Video keeps `videoUrl`. The shared player never autoplays, pauses on hiding, and removes its source on preview close.
- Windows organizer publishes `window.hpLibrary.showAsset(id) -> Promise<boolean>`; it resolves `assets.get {id}` and uses the same preview implementation as Mac `openAsset(asset)`.

## 構造と互換性

新しいorganize/undo/capture要求と音声preview結果のJSON構造は[interactions.schema.json](interactions.schema.json)、代表入力と不正入力は[fixtures/interactions-v1.json](fixtures/interactions-v1.json)を参照。IDは空でないopaque文字列、`sourceFolderId`の省略/nullは元フォルダ指定なし、`folderId`の省略/nullは未分類。Undo tokenはHost発行の一度だけ使える文字列。DOMとnativeの両方で実dropした宛先だけを返し、hover終了やキャンセルでは移動しない。

DB版1・原本・バックアップ形式は変更しないためmigrationは不要。旧アプリへ戻しても分類/ゴミ箱状態と原本は読める。新しいbridge操作は旧Hostでは未対応エラーとなるため、画面とHostは同一成果物で配る。旧版で音声previewを開けなくても原本の取り出しは可能。
