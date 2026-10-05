# Library interactions v1 (2026-10-05)

Mac owns the shared assets UI; each OS implements its native bridge. No database migration: assets and memberships remain schema version 1.

- `assets.copy {id,ids,mode:"drag",dropTargets:[{kind,folderId?,bounds:{x,y,width,height}}],trashBounds?}`. Bounds are viewport CSS pixels. Supported kinds: `folder`, `trash`, `favorite`, `unfiled`. Native result: `{ok,droppedInTrash?,dropTarget?:{kind,folderId?}}`. Cancellation returns no destination. Native accepts internal targets only for its active source session.
- `assets.dragMoved {x,y}` native event; `assets.dragTargetHover {dropTarget}` optional event. JS highlights/scrolls the sidebar and updates clipped rectangles through `assets.dragTargets {dropTargets}`. Never accept the last hover alone as proof of a drop.
- `assets.update {operation:"organize",ids,sourceFolderId:null|string,destination:{kind,folderId?}}` atomically validates every ID and folder. Missing targets reject the whole operation. Result `{ok:true,undoToken}`.
- Folder A to B removes only A, preserving other memberships and tags. All/search/multiple-folder views pass null and add B. Trash to folder restores and adds B, preserving old memberships. Favorite restores and sets true; unfiled restores and removes only folder memberships; trash sets soft trash. IDs/original bytes remain unchanged.
- `assets.update {operation:"undoOrganize",undoToken}` restores the snapshot once; later edits or state conflicts reject stale undo. Existing `assets.undo` remains the ordinary undo action.
- `assets.capture {kind:"cameraPhoto"|"cameraVideo"|"audio",folderId:null|string}` opens native device/save UI. Recording requires explicit start. Existing screenshot/recording kinds remain supported. Closing library does not stop an active capture.
- External import copies source files, image data, file promises/virtual files, and direct media URLs. It must never ingest the app's own internal drag or claim web pages/streaming video are downloadable. A native top-edge overlay offers destination folders and import/error feedback.
