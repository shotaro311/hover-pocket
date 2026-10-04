import { on } from "../../js/bridge.js";
import { assetTranslator, translateAssetTree } from "./locale.js";

export function renderAssetsProvider({ container, request, state }) {
  const english = state?.settings?.language === "en", t = assetTranslator(english ? "en" : "ja");
  let disposed = false, page = null, generation = 0, previewGeneration = 0, queryTimer, selectionReady = false;
  let query = { text: "", view: "recent", offset: 0, limit: 100 }, selection = new Set(), anchor = null;
  let selectedAsset = null, preview = null, fullscreen = false, organizer = false, zoom = 1, pdfPage = 1, composing = false, dragging = false, editingImage = false, dragIds = [], droppedInTrash = false;
  const thumbnails = new Map(), pendingThumbs = new Set();
  const root = document.createElement("section"); root.className = "assets-root";
  root.innerHTML = `<div class="assets-toolbar"><button data-action="sidebar" aria-label="分類を表示">☰</button><input class="assets-search" type="search" placeholder="素材の名前・タグを検索" aria-label="素材を検索"><button data-action="add">＋ ファイル</button><button data-action="folder">フォルダ</button><button data-action="clipboard" title="コピーした画像・ファイルを保存">貼り付け</button><button data-action="organizer" title="広い画面で整理する">整理</button></div>
    <div class="assets-body"><aside class="assets-sidebar" aria-label="分類"></aside><div class="assets-main"><div class="assets-summary" role="status"></div><div class="assets-scroll" tabindex="0" role="listbox" aria-label="素材" aria-multiselectable="true"><div class="assets-spacer-top"></div><div class="assets-grid"></div><div class="assets-spacer-bottom"></div></div><div class="assets-selection"></div></div><section class="assets-preview" hidden aria-label="素材プレビュー"><div class="assets-preview-toolbar"><button data-action="endPreview" aria-label="一覧へ戻る">← 一覧</button><span class="assets-preview-name"></span><button data-action="zoomOut" aria-label="縮小">−</button><button data-action="zoomFit">フィット</button><button data-action="zoomIn" aria-label="拡大">＋</button><button data-action="fullscreen" aria-label="全画面を切り替え">⛶</button></div><div class="assets-media"></div><div class="assets-preview-bottom"></div></section></div><div class="assets-status" role="status"></div>`;
  const trashDrop = document.createElement("div"); trashDrop.className = "assets-trash-drop"; trashDrop.hidden = true; trashDrop.setAttribute("role", "status");
  trashDrop.innerHTML = `<span class="assets-trash-icon" aria-hidden="true">⌫</span><div><strong>${english ? "Drop to move to trash" : "ここにドロップしてゴミ箱へ"}</strong><small>${english ? "You can undo this after dropping" : "あとから「元に戻す」で復元できます"}</small></div>`;
  root.append(trashDrop);
  container.replaceChildren(root);
  translateAssetTree(root, t);
  root.classList.toggle("is-organizer", !!state?.organizer);
  const details = document.createElement("aside"); details.className = "assets-detail"; details.setAttribute("aria-label", "素材の詳細"); root.querySelector(".assets-body").append(details);
  const find = selector => root.querySelector(selector), scroll = find(".assets-scroll"), grid = find(".assets-grid"), media = find(".assets-media");
  const report = message => { if (!disposed) find(".assets-status").textContent = t(message); };
  const run = async (method, params) => { try { return await request(method, params); } catch (error) { report(error.message); return null; } };
  const button = (text, action, title = text) => { const el = document.createElement("button"); el.type = "button"; el.textContent = t(text); el.title = t(title); el.onclick = action; return el; };
  const input = find("input");
  const currentFolderId = () => {
    const ids = [...new Set([...(query.folderIds || []), ...(query.folderId ? [query.folderId] : [])])];
    return ids.length === 1 ? ids[0] : null;
  };
  find(".assets-toolbar").append(button(english ? "Capture" : "撮影・収録", () => run("assets.capture", { folderId: currentFolderId() })));
  input.addEventListener("compositionstart", () => { composing = true; clearTimeout(queryTimer); });
  input.addEventListener("compositionend", () => { composing = false; query.text = input.value; resetQuery(); });
  input.addEventListener("input", () => { if (composing) return; clearTimeout(queryTimer); queryTimer = setTimeout(() => { query.text = input.value; resetQuery(); }, 150); });
  input.addEventListener("keydown", event => { if (event.key === "Enter" && !event.isComposing) { clearTimeout(queryTimer); query.text = input.value; resetQuery(); } });
  let columns = 3, rowsInWindow = 7, startRow = 0;
  function resetQuery() { scroll.scrollTop = 0; query.offset = 0; void refresh(); }
  async function refresh() {
    const current = ++generation, filter = { ...query };
    selectionReady = false; renderSelection(); renderDetails();
    const result = await run("assets.query", filter);
    if (!result || disposed || current !== generation) return;
    const visibleIds = new Set(result.items.map(asset => asset.id));
    const matches = await Promise.all([...selection].filter(id => !visibleIds.has(id)).map(async id =>
      [id, await run("assets.matches", { id, query: filter })]));
    if (disposed || current !== generation) return;
    for (const [id, match] of matches) if (!match?.matches) selection.delete(id);
    if (anchor && !selection.has(anchor)) anchor = null;
    const previous = selectedAsset;
    selectedAsset = result.items.find(a => a.id === previous?.id && selection.has(a.id))
      || (selection.has(previous?.id) ? previous : result.items.find(a => selection.has(a.id))) || null;
    page = result;
    if (preview && !selection.has(preview.id)) {
      await endPreview();
      if (disposed || current !== generation) return;
    }
    selectionReady = true;
    const conditions = [query.kind, query.createdAfter && new Date(query.createdAfter).toLocaleDateString(), query.createdBefore && "< " + new Date(query.createdBefore).toLocaleDateString(), ...[...(query.folderIds||[]),...(query.tagIds||[])].map(id=>[...result.folders,...result.tags].find(c=>c.id===id)?.name)].filter(Boolean);
    find(".assets-summary").textContent = `${result.total.toLocaleString()}${english ? " items" : "件"}${conditions.length ? " · " + conditions.join(" / ") : ""}`;
    renderSidebar(); renderGrid(); renderSelection(); renderDetails();
  }
  function renderSidebar() {
    const sidebar = find(".assets-sidebar"); sidebar.replaceChildren();
    for (const [view, name] of [["recent", "最近の素材"], ["favorites", "★ お気に入り"], ["uncategorized", "未分類"], ["trash", "ゴミ箱"]]) {
      const el = button(name, () => { query = { ...query, view, folderId: null, tagId: null, folderIds:[], tagIds:[] }; resetQuery(); }); el.classList.toggle("is-selected", query.view === view && !query.folderId && !query.tagId && !query.folderIds?.length && !query.tagIds?.length); sidebar.append(el);
    }
    if (query.view === "trash") sidebar.append(button("ゴミ箱を空にする…", async () => { const result = await run("assets.emptyTrash"); if (result?.removed !== undefined) report(`${result.removed}件をWindowsのゴミ箱へ移しました。移せなかった原本は保持されています。`); await refresh(); }));
    const heading = name => { const el = document.createElement("h3"); el.textContent = t(name); sidebar.append(el); };
    heading("フォルダ");
    for (const c of page.folders) { const el = button(c.name, event => filterCategory("folder", c.id, event)); el.classList.toggle("is-selected", query.folderId === c.id || query.folderIds?.includes(c.id)); el.style.paddingLeft = c.parentId ? "24px" : "10px"; el.oncontextmenu = event => { event.preventDefault(); editCategory(c); }; sidebar.append(el); }
    sidebar.append(button("＋ フォルダ", () => category("folder")));
    heading("タグ"); for (const c of page.tags) { const el = button("# " + c.name, event => filterCategory("tag", c.id, event)); el.classList.toggle("is-selected", query.tagId === c.id || query.tagIds?.includes(c.id)); el.oncontextmenu = event => { event.preventDefault(); editCategory(c); }; sidebar.append(el); }
    sidebar.append(button("＋ タグ", () => category("tag")));
    heading("保存した検索"); for (const saved of page.searches) sidebar.append(button(saved.name, () => { query = { ...saved.filter, offset: 0, limit: 100 }; input.value = query.text; resetQuery(); }));
    sidebar.append(button("現在の検索を保存", async () => { const name = await ask("検索の名前"); if (name) { await run("assets.saveSearch", { name, filter: query }); await refresh(); } }));
    heading("ライブラリ");
    sidebar.append(button("DBの復旧…", async () => {
      const snapshots = await run("assets.databaseSnapshots"); if (!snapshots) return;
      const dialog = document.createElement("dialog"); dialog.className = "assets-dialog";
      const title = document.createElement("h3"); title.textContent = "DBのスナップショットを選択"; dialog.append(title);
      for (const name of snapshots) dialog.append(button(name, async () => { const result = await run("assets.restoreDatabase", {name}); dialog.close(); if (result?.ok) { report("DBを復元しました。未登録の原本は復旧操作で戻せます。"); await refresh(); } }));
      dialog.append(button("閉じる", () => dialog.close())); root.append(dialog); dialog.addEventListener("close", () => dialog.remove()); dialog.showModal();
    }));
    sidebar.append(button("バックアップを保存", () => backup("export")), button("バックアップを復元", () => backup("restore")), button("未登録の原本を復旧", async () => { const result = await run("assets.recover"); if (result) report(`${result.recovered}件を復旧しました。`); }), button("外部コピーを整理…", async () => { const result = await run("assets.cleanCopies"); if (result?.removed !== undefined) report(`${result.removed}件の作業コピーをゴミ箱へ移しました。`); }));
  }
  async function backup(mode) { report(mode === "export" ? "バックアップを保存中…" : "バックアップを検証・復元中…"); const result = await run("assets.backup", {mode}); if (result?.ok) { report(mode === "export" ? (result.excludedPending ? `${t("バックアップを保存しました。")} ${result.excludedPending}${english ? " pending imports excluded." : "件の未確定項目を除外しました。"}` : "バックアップを保存しました。") : "バックアップを復元しました。"); await refresh(); } else if (result?.cancelled) report("取り消しました。"); }
  function filterCategory(type, id, event) {
    const key = type + "Ids", single = type + "Id", ids = new Set(query[key] || (query[single] ? [query[single]] : []));
    if (event?.ctrlKey || event?.metaKey) { if (ids.has(id)) ids.delete(id); else ids.add(id); } else { ids.clear(); ids.add(id); }
    query = {...query, view:"recent", [key]:[...ids], [single]:null}; resetQuery();
  }
  function renderDetails() {
    details.replaceChildren(); if (!selectionReady || !selectedAsset || !selection.size) { details.textContent = t("素材を選ぶと詳細が表示されます。"); return; }
    const heading = document.createElement("h3"); heading.textContent = selectedAsset.name; details.append(heading);
    const metadata = document.createElement("p"); metadata.textContent = `${selectedAsset.extension.toUpperCase() || "FILE"} · ${bytes(selectedAsset.sizeBytes)}\n${new Date(selectedAsset.createdAt).toLocaleString()}${selectedAsset.internetOrigin ? "\nインターネット由来" : ""}`; details.append(metadata);
    for (const category of [...page.folders, ...page.tags].filter(c => [...selectedAsset.folderIds, ...selectedAsset.tagIds].includes(c.id))) details.append(button(`${page.tags.includes(category) ? "# " : "▸ "}${category.name} ×`, () => update("unclassify", category.id), "この分類を外す"));
    details.append(button("分類を追加", classify), button("OSで開く", () => run("assets.copy", {id:selectedAsset.id, mode:"open"})), button("元に戻す", () => run("assets.undo").then(refresh)));
  }
  function filters() {
    const dialog = document.createElement("dialog"); dialog.className = "assets-dialog";
    const heading = document.createElement("h3"); heading.textContent = t("検索条件"); dialog.append(heading);
    const kind = document.createElement("select"); for (const [value,label] of [["","すべての種類"],["image","画像"],["video","動画"],["pdf","PDF"],["other","その他"]]) { const option = document.createElement("option"); option.value=value; option.textContent=t(label); kind.append(option); } kind.value=query.kind||"";
    const from = document.createElement("input"), to = document.createElement("input"); from.type=to.type="date";
    const localDate = value => { if (!value) return ""; const date = new Date(value); return `${date.getFullYear()}-${String(date.getMonth()+1).padStart(2,"0")}-${String(date.getDate()).padStart(2,"0")}`; };
    from.value = localDate(query.createdAfter); if (query.createdBefore) { const date = new Date(query.createdBefore); date.setDate(date.getDate()-1); to.value = localDate(date.toISOString()); }
    for (const [title,control] of [["種類",kind],["取り込み日：開始",from],["取り込み日：終了（この日を含む）",to]]) { const label=document.createElement("label"); label.textContent=t(title); label.append(control); dialog.append(label); }
    const summary = document.createElement("p"); summary.textContent = [...(query.folderIds||[]), ...(query.tagIds||[])].map(id=>[...page.folders,...page.tags].find(c=>c.id===id)?.name).filter(Boolean).join(" / ") || "分類・タグは一覧のCtrlクリックで複数指定できます。"; dialog.append(summary);
    const utc = (value, next=false) => { if (!value) return null; const parts=value.split("-").map(Number); const date=new Date(parts[0],parts[1]-1,parts[2]); if (next) date.setDate(date.getDate()+1); return date.toISOString(); };
    dialog.append(button("適用", () => { query = {...query,kind:kind.value||null,createdAfter:utc(from.value),createdBefore:utc(to.value,true)}; dialog.close(); resetQuery(); }), button("条件を解除", () => { query={text:"",view:"recent",offset:0,limit:100}; input.value=""; dialog.close(); resetQuery(); }), button("閉じる",()=>dialog.close()));
    root.append(dialog); dialog.addEventListener("close",()=>dialog.remove()); dialog.showModal();
  }
  find(".assets-toolbar").append(button("絞り込み", filters));
  function renderGrid() {
    if (!page || preview || disposed || dragging) return;
    columns = Math.max(1, Math.floor(scroll.clientWidth / 132)); rowsInWindow = Math.ceil(scroll.clientHeight / 152) + 3;
    startRow = Math.max(0, Math.floor(scroll.scrollTop / 152) - 1);
    const wanted = startRow * columns;
    if (wanted < query.offset || wanted + rowsInWindow * columns > query.offset + page.items.length && query.offset + page.items.length < page.total) {
      query.offset = wanted; query.limit = Math.min(200, Math.max(100, rowsInWindow * columns)); void refresh(); return;
    }
    const items = page.items.slice(Math.max(0, wanted - query.offset), Math.max(0, wanted - query.offset) + rowsInWindow * columns);
    find(".assets-spacer-top").style.height = `${startRow * 152}px`;
    find(".assets-spacer-bottom").style.height = `${Math.max(0, Math.ceil(page.total / columns) - startRow - Math.ceil(items.length / columns)) * 152}px`;
    grid.style.gridTemplateColumns = `repeat(${columns},minmax(0,1fr))`; grid.replaceChildren();
    for (const asset of items) {
      const card = document.createElement("div"); card.className = "assets-card"; card.dataset.assetId = asset.id; card.setAttribute("role", "option"); card.setAttribute("aria-selected", selection.has(asset.id)); card.tabIndex = -1; card.draggable = true;
      const image = document.createElement("img"); image.alt = ""; image.draggable = false; image.decoding = "async";
      const placeholder = document.createElement("span"); placeholder.className = "assets-kind"; placeholder.textContent = asset.kind === "pdf" ? "PDF" : asset.kind === "video" ? "▶" : asset.kind === "image" ? "▧" : asset.extension.toUpperCase() || "FILE";
      const title = document.createElement("span"); title.className = "assets-card-name"; title.textContent = (asset.favorite ? "★ " : "") + asset.name; title.title = asset.name;
      const size = document.createElement("small"); size.textContent = bytes(asset.sizeBytes);
      card.append(placeholder, image, title, size); grid.append(card);
      if (thumbnails.has(asset.id)) image.src = thumbnails.get(asset.id);
      else if (asset.kind !== "other" && !pendingThumbs.has(asset.id)) {
        pendingThumbs.add(asset.id);
        // The visible window bounds the number of requests and decoded images.
        void run("assets.thumbnail", { id: asset.id }).then(frame => {
          pendingThumbs.delete(asset.id); if (disposed || !frame?.dataUrl) return;
          thumbnails.set(asset.id, frame.dataUrl); while (thumbnails.size > 150) thumbnails.delete(thumbnails.keys().next().value);
          const visible = Array.from(grid.children).find(el => el.dataset.assetId === asset.id); if (visible) visible.querySelector("img").src = frame.dataUrl;
        });
      }
      card.onclick = event => select(asset, event);
      card.ondblclick = () => { void openPreview(asset); };
      card.ondragstart = event => { event.preventDefault(); void dragAsset(asset); };
    }
  }
  async function dragAsset(asset) {
    if (dragging || !selectionReady) return;
    const ids = selection.has(asset.id) ? [...selection] : [asset.id];
    dragIds = ids; droppedInTrash = false;
    dragging = true; trashDrop.hidden = query.view === "trash"; root.classList.add("is-dragging");
    try {
      await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
      if (disposed) return;
      const rect = trashDrop.getBoundingClientRect();
      const result = await run("assets.copy", { id: asset.id, ids, mode: "drag", trashBounds: trashDrop.hidden ? null : {x:rect.x,y:rect.y,width:rect.width,height:rect.height} });
      let trashed = 0;
      if (result?.ok && (result.droppedInTrash || droppedInTrash)) { const moved = await run("assets.update", {ids,operation:"trash"}); if (moved?.ok) trashed=ids.length; }
      if (trashed) report(english ? `${trashed} moved to trash. Ctrl+Z to undo.` : `${trashed}件をゴミ箱へ移しました。Ctrl+Zで元に戻せます。`);
    } finally {
      dragging = false; dragIds = []; droppedInTrash = false; trashDrop.hidden = true; trashDrop.classList.remove("is-targeted"); root.classList.remove("is-dragging");
      if (!disposed) await refresh();
    }
  }
  const overTrash = event => {
    if (!dragging || !dragIds.length || trashDrop.hidden) return false;
    const rect = trashDrop.getBoundingClientRect();
    return event.clientX >= rect.left && event.clientX <= rect.right && event.clientY >= rect.top && event.clientY <= rect.bottom;
  };
  const updateDragTarget = event => {
    if (!dragging) return;
    event.preventDefault(); const over = overTrash(event); trashDrop.classList.toggle("is-targeted", over);
    if (event.dataTransfer) event.dataTransfer.dropEffect = over ? "move" : "none";
  };
  root.addEventListener("dragenter", updateDragTarget); root.addEventListener("dragover", updateDragTarget);
  root.addEventListener("dragleave", event => { if (!root.contains(event.relatedTarget)) trashDrop.classList.remove("is-targeted"); });
  root.addEventListener("drop", event => {
    if (!dragging) return;
    event.preventDefault(); droppedInTrash = overTrash(event);
  });
  function select(asset, event = {}) {
    if (!selectionReady) return;
    if (event.shiftKey && anchor) {
      const first = page.items.findIndex(a => a.id === anchor), last = page.items.findIndex(a => a.id === asset.id);
      for (const item of page.items.slice(Math.max(0, Math.min(first, last)), Math.max(first, last) + 1)) selection.add(item.id);
    } else if (event.ctrlKey || event.metaKey) { if (selection.has(asset.id)) selection.delete(asset.id); else selection.add(asset.id); anchor = asset.id; }
    else { selection = new Set([asset.id]); anchor = asset.id; }
    selectedAsset = asset; renderGrid(); renderSelection(); renderDetails(); scroll.focus();
  }
  function renderSelection() {
    const tools = find(".assets-selection"); tools.replaceChildren(); if (!selectionReady || !selection.size || !selectedAsset) return;
    const status = document.createElement("span"); status.textContent = `${selection.size}${english ? " selected" : "件選択"}`; tools.append(status);
    tools.append(button("プレビュー", () => openPreview(selectedAsset)), button("★", () => update("favorite")), button("分類", classify), button("名前", async () => { const name = await ask("素材の名前", selectedAsset.name); if (name) await update("rename", name); }), button("コピー", () => run("assets.copy", { id: selectedAsset.id, ids:[...selection] })), button("保存先…", () => run("assets.copy", { id: selectedAsset.id, mode: "save" })), button(query.view === "trash" ? "復元" : "ゴミ箱", () => update(query.view === "trash" ? "restore" : "trash")), button("元に戻す", () => run("assets.undo").then(refresh)));
  }
  async function update(operation, value) { if (!selectionReady || !selection.size) return; await run("assets.update", { ids: [...selection], operation, value }); await refresh(); }
  async function category(type) { const name = await ask(type === "folder" ? "フォルダ名" : "タグ名"); if (name) { await run("assets.category", { type, name, parentId: type === "folder" ? currentFolderId() : null }); await refresh(); } }
  function editCategory(category) {
    const dialog = document.createElement("dialog"); dialog.className = "assets-dialog";
    const title = document.createElement("h3"); title.textContent = category.name; dialog.append(title);
    dialog.append(button("名前を変更", async () => { dialog.close(); const name = await ask("分類の名前", category.name); if (name) await run("assets.categoryUpdate", { id: category.id, operation: "rename", name }); await refresh(); }), button("分類を削除（原本を保持）", async () => { await run("assets.categoryUpdate", { id: category.id, operation: "delete" }); query.folderId = null; query.tagId = null; dialog.close(); await refresh(); }));
    if (page.folders.includes(category)) {
      dialog.append(button("最上位へ移動", async () => { await run("assets.categoryUpdate", { id: category.id, operation: "move", parentId: null }); dialog.close(); await refresh(); }));
      for (const folder of page.folders.filter(c => c.id !== category.id)) dialog.append(button(`「${folder.name}」へ移動`, async () => { await run("assets.categoryUpdate", { id: category.id, operation: "move", parentId: folder.id }); dialog.close(); await refresh(); }));
    }
    dialog.append(button("閉じる", () => dialog.close())); dialog.addEventListener("close", () => dialog.remove()); root.append(dialog); dialog.showModal();
  }
  async function classify() {
    const dialog = document.createElement("dialog"); dialog.className = "assets-dialog";
    const title = document.createElement("h3"); title.textContent = "選択した素材へ分類を追加"; dialog.append(title);
    for (const c of [...page.folders, ...page.tags]) {
      const row=document.createElement("div"); row.className="assets-classification-row";
      row.append(button((page.tags.includes(c) ? "# " : "▸ ") + c.name,async()=>{await update("classify",c.id);dialog.close();}),button(english?"Remove":"外す",async()=>{await update("unclassify",c.id);dialog.close();})); dialog.append(row);
    }
    dialog.append(button("閉じる", () => dialog.close())); root.append(dialog); dialog.addEventListener("close", () => dialog.remove()); dialog.showModal();
  }
  async function ask(title, initial = "") {
    return new Promise(resolve => {
      const dialog = document.createElement("dialog"); dialog.className = "assets-dialog"; const label = document.createElement("label"); label.textContent = t(title);
      const field = document.createElement("input"); field.value = initial; label.append(field); dialog.append(label);
      const finish = value => { dialog.close(); dialog.remove(); resolve(value); };
      dialog.append(button("保存", () => finish(field.value.trim())), button("キャンセル", () => finish(null))); dialog.addEventListener("cancel", event => { event.preventDefault(); finish(null); });
      field.onkeydown = event => { if (event.key === "Enter" && !event.isComposing) finish(field.value.trim()); }; root.append(dialog); dialog.showModal(); field.focus(); field.select();
    });
  }
  async function openPreview(asset, requestedPage = 1) {
    void run("assets.visibility", {visible:false});
    const current = ++previewGeneration; const same = preview?.id === asset.id;
    preview = { id: asset.id, kind: asset.kind };
    const transition = await run("assets.transition");
    if (disposed || current !== previewGeneration) { await run("assets.transition", { cancel: transition?.revision || 0 }); return; }
    let layoutApplied = false;
    try {
    if (!same) { stopMedia(); zoom = 1; fullscreen = false; }
    selectedAsset = asset; selection = new Set([asset.id]); pdfPage = requestedPage;
    find(".assets-preview").hidden = false; root.classList.add("has-preview");
    find(".assets-preview-name").textContent = asset.name;
    if (!same) { media.replaceChildren(); const thumb = thumbnails.get(asset.id); if (thumb) { const image = document.createElement("img"); image.src = thumb; media.append(image); } else media.textContent = t("プレビューを読み込み中…"); }
    const result = await run("assets.preview", { id: asset.id, page: requestedPage });
    if (!result || result.cancelled || disposed || current !== previewGeneration) return;
    preview = result;
    if (result.error && result.kind === "video") report(result.error);
    if (result.error && result.kind !== "video") { media.textContent = result.error; }
    else if (result.kind === "video") {
      let video = media.querySelector("video");
      if (!video) { video = document.createElement("video"); video.controls = true; video.preload = "metadata"; video.autoplay = false; video.playsInline = true; video.src = result.videoUrl; if (result.dataUrl) video.poster = result.dataUrl; video.onerror = () => report("この動画は再生できません。原本は保存されています。Windowsのメディア機能と形式を確認してください。"); media.replaceChildren(video); }
    } else if (result.dataUrl) { const image = document.createElement("img"); image.src = result.dataUrl; image.alt = asset.name; image.draggable = false; media.replaceChildren(image); }
    else media.textContent = t("この形式はプレビューに対応していません。コピー・保存先から原本を取り出せます。");
    const content = media.querySelector("img,video");
    if (content && result.width > 0 && result.height > 0 && result.kind !== "pdf") { const ratio = devicePixelRatio || 1; content.style.maxWidth = `min(100%,${result.width / ratio}px)`; content.style.maxHeight = `min(100%,${result.height / ratio}px)`; }
    const footer = find(".assets-preview-bottom"); footer.replaceChildren();
    if (result.kind === "pdf" && !result.error) {
      footer.append(button("‹ 前", () => { if (pdfPage > 1) void openPreview(asset, pdfPage - 1); }));
      const field = document.createElement("input"); field.type = "number"; field.min = 1; field.max = result.pages; field.value = pdfPage; field.setAttribute("aria-label", "PDFのページ番号"); field.onchange = () => { const number = Math.max(1, Math.min(result.pages, Number(field.value) || 1)); void openPreview(asset, number); };
      const count = document.createElement("span"); count.textContent = `/ ${result.pages}`; footer.append(field, count, button("次 ›", () => { if (pdfPage < result.pages) void openPreview(asset, pdfPage + 1); }));
    }
    if (asset.kind === "image" && !asset.trashed) {
      const edit = button(english ? "Edit image" : "画像を編集", async () => {
        if (editingImage) return; editingImage = true; edit.disabled = true;
        try {
          const saved = await run("assets.editImage", {id:asset.id});
          if (saved?.ok) { report(english ? "Edited image saved. Original preserved." : "編集画像を保存しました。元画像も残っています。"); await refresh(); }
        } finally { editingImage = false; edit.disabled = false; }
      });
      edit.className = "assets-edit-image"; footer.append(edit);
    }
    footer.append(button("ファイルをコピー", () => run("assets.copy", { id: asset.id })), button("保存先…", () => run("assets.copy", { id: asset.id, mode: "save" })));
    applyZoom();
    const readyImage = media.querySelector("img");
    if (readyImage) await readyImage.decode().catch(() => {});
    if (disposed || current !== previewGeneration) return;
    await run("assets.layout", { fullscreen });
    layoutApplied = true;
    await run("panel.beginTextInput");
    } finally { if (!layoutApplied) await run("assets.transition", { cancel: transition?.revision || 0 }); }
  }
  function stopMedia() { const video = media.querySelector("video"); if (video) { video.pause(); video.removeAttribute("src"); video.load(); } }
  async function endPreview() {
    const current = ++previewGeneration;
    const transition = await run("assets.transition");
    if (disposed || current !== previewGeneration) { await run("assets.transition", { cancel: transition?.revision || 0 }); return; }
    stopMedia(); preview = null; fullscreen = false; zoom = 1;
    media.replaceChildren(); find(".assets-preview").hidden = true; root.classList.remove("has-preview", "is-fullscreen"); document.body.classList.remove("assets-fullscreen");
    await run("assets.endPreview"); await run("panel.endTextInput"); if (organizer) await run("assets.organizer");
    await run("assets.visibility", {visible:true}); renderGrid(); renderSelection(); renderDetails();
  }
  function applyZoom() { const image = media.querySelector("img"); if (image) { image.style.transform = `scale(${zoom})`; media.classList.toggle("is-zoomed", zoom > 1); } }
  async function toggleFullscreen() { if (!preview) return; fullscreen = !fullscreen; root.classList.toggle("is-fullscreen", fullscreen); if (!organizer) document.body.classList.toggle("assets-fullscreen", fullscreen); await run("assets.layout", { fullscreen }); }
  const actions = {
    sidebar: () => root.classList.toggle("show-sidebar"), add: () => run("assets.pick"), folder: () => run("assets.pick", { kind: "folder" }), clipboard: () => run("assets.clipboard"),
    organizer: () => run("assets.openOrganizer"), capture: () => run("assets.capture", { folderId: currentFolderId() }),
    endPreview, fullscreen: toggleFullscreen, zoomIn: () => { zoom = Math.min(8, zoom * 1.25); applyZoom(); }, zoomOut: () => { zoom = Math.max(.25, zoom / 1.25); applyZoom(); }, zoomFit: () => { zoom = 1; applyZoom(); }
  };
  root.addEventListener("click", event => { const action = event.target.closest("[data-action]")?.dataset.action; if (action) void actions[action]?.(); });
  root.addEventListener("contextmenu", event => { if (!event.target.closest('[data-action="add"]')) return; event.preventDefault(); void run("assets.pick", { kind: "folder" }); });
  scroll.addEventListener("scroll", () => renderGrid(), { passive: true });
  const observer = new ResizeObserver(() => renderGrid()); observer.observe(scroll);
  const keydown = event => {
    if (event.isComposing || event.keyCode === 229 || root.querySelector("dialog[open]") || dragging || editingImage) return;
    if (event.repeat && [" ", "Escape", "F11"].includes(event.key)) { event.preventDefault(); return; }
    if (event.key === " " && event.target.closest("button,a,select,video")) return;
    const editing = event.target.closest("input,textarea,[contenteditable='true']");
    if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "f") { event.preventDefault(); input.focus(); return; }
    if (event.key === "F11" && preview) { event.preventDefault(); void toggleFullscreen(); }
    else if (event.key === "Escape") { event.preventDefault(); if (fullscreen) void toggleFullscreen(); else if (preview) void endPreview(); else if (organizer) void actions.organizer(); }
    else if (editing) return;
    else if (event.key === " " && preview) { event.preventDefault(); const video = media.querySelector("video"); if (video) { if (video.paused) void video.play().catch(error=>report(error.message)); else video.pause(); } else void endPreview(); }
    else if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "z") { event.preventDefault(); void run("assets.undo").then(refresh); }
    else if (event.key === " " && selectedAsset && !preview) { event.preventDefault(); void openPreview(selectedAsset); }
    else if (event.key.startsWith("Arrow") && !preview && page?.items.length) {
      event.preventDefault(); const current = Math.max(0, page.items.findIndex(a => a.id === selectedAsset?.id));
      const delta = { ArrowRight: 1, ArrowLeft: -1, ArrowDown: columns, ArrowUp: -columns }[event.key]; select(page.items[Math.max(0, Math.min(page.items.length - 1, current + delta))], event);
    }
  };
  document.addEventListener("keydown", keydown);
  let pan = null;
  media.addEventListener("pointerdown", event => { if (zoom <= 1 || !media.querySelector("img")) return; pan = { x: event.clientX, y: event.clientY, left: media.scrollLeft, top: media.scrollTop }; media.setPointerCapture(event.pointerId); });
  media.addEventListener("pointermove", event => { if (pan) { media.scrollLeft = pan.left - event.clientX + pan.x; media.scrollTop = pan.top - event.clientY + pan.y; } });
  media.addEventListener("pointerup", () => { pan = null; });
  const visibilityChanged = () => { if (document.hidden) { stopMedia(); void run("assets.visibility",{visible:false}); } else if (!preview) void run("assets.visibility",{visible:true}).then(refresh); };
  document.addEventListener("visibilitychange",visibilityChanged);
  let eventTimer;
  const showImportProgress = progress => {
    const reasons = (progress.skipReasons || []).map(reason=>`${reason.key} ${reason.value}`).join(" / ");
    report(english ? `${progress.busy ? "Saving… " : "Saved "}${progress.completed}, duplicates ${progress.duplicates}, skipped ${progress.skipped||0}, failed ${progress.failed}${progress.error?" · "+progress.error:""}` : `${progress.busy ? "保存中… " : "保存完了 "}${progress.completed}件、重複 ${progress.duplicates}件${progress.restoreAvailable ? `（ゴミ箱 ${progress.restoreAvailable}件）` : ""}${progress.skipped ? `、スキップ ${progress.skipped}件（${reasons}）` : ""}${progress.failed ? `、失敗 ${progress.failed}件。${progress.error||""}ファイルを選び直して再試行できます。` : ""}`);
    for (const control of root.querySelectorAll('[data-action="add"],[data-action="folder"],[data-action="clipboard"]')) control.disabled=progress.busy;
    if (progress.busy) root.querySelector(".assets-restore-available")?.remove();
    if (progress.busy && !root.querySelector(".assets-cancel")) { const el = button("取り消す", () => run("assets.cancelImport")); el.className = "assets-cancel"; find(".assets-toolbar").append(el); }
    else if (!progress.busy) { root.querySelector(".assets-cancel")?.remove(); void refresh(); }
  };
  const unsubscribers = [on("assets.trashHover", payload => trashDrop.classList.toggle("is-targeted", !!payload.hovered)), on("assets.dragPreparing", () => report(english ? "Preparing files for drag… You can release the mouse while waiting." : "外へ渡すファイルを準備しています。大きい素材はマウスを離して待てます。")), on("assets.dragReady", () => report(english ? "Ready. Drag the same selection again." : "準備できました。同じ素材をもう一度ドラッグしてください。")), on("assets.dropUnsupported", payload => report(payload.message)), on("assets.changed", () => { clearTimeout(eventTimer); eventTimer = setTimeout(() => { if (!preview && !dragging && !document.hidden) void refresh(); }, 150); }), on("assets.importChanged",showImportProgress), on("assets.restoreAvailable", result=>{
    root.querySelector(".assets-restore-available")?.remove();
    const control = button(english ? `Restore ${result.ids.length} from trash` : `ゴミ箱の素材を復元（${result.ids.length}件）`,async()=>{const restored=await run("assets.update",{ids:result.ids,operation:"restore"});if(restored?.ok){control.remove();await refresh();}}); control.className="assets-restore-available";find(".assets-toolbar").append(control);
  }), on("panel.closed", () => { stopMedia(); void run("assets.visibility", {visible:false}); }), on("panel.opened", () => { void run("assets.visibility", {visible:true}).then(refresh); }), on("assets.previewEnded", () => { if (preview) { ++previewGeneration; stopMedia(); preview = null; fullscreen = false; find(".assets-preview").hidden = true; root.classList.remove("has-preview", "is-fullscreen"); document.body.classList.remove("assets-fullscreen"); void run("panel.endTextInput"); void run("assets.visibility",{visible:!document.hidden}).then(()=>renderGrid()); } })];
  void run("assets.status").then(status => { if (status?.warning) report(status.warning); });
  void run("assets.visibility", {visible:true});
  void run("assets.importState").then(progress=>{if(progress&&(progress.busy||progress.completed||progress.failed||progress.duplicates))showImportProgress(progress);});
  void refresh();
  return { refresh, dispose() { document.body.classList.remove("assets-fullscreen"); disposed = true; ++generation; ++previewGeneration; clearTimeout(queryTimer); clearTimeout(eventTimer); observer.disconnect(); document.removeEventListener("keydown", keydown); document.removeEventListener("visibilitychange",visibilityChanged); unsubscribers.forEach(unsubscribe => unsubscribe()); stopMedia(); void request("assets.visibility", {visible:false}).catch(() => {}); void request("assets.endPreview").catch(() => {}); thumbnails.clear(); } };
}

function bytes(value) { return value < 1024 ? `${value} B` : value < 1024 * 1024 ? `${(value / 1024).toFixed(1)} KB` : `${(value / (1024 * 1024)).toFixed(1)} MB`; }
