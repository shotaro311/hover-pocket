import { on } from "../../js/bridge.js";
import { assetTranslator, translateAssetTree } from "./locale.js";

export function renderAssetsProvider({ container, request, state }) {
  const english = state?.settings?.language === "en", t = assetTranslator(english ? "en" : "ja");
  const modifierLabel = state?.platform === "mac" ? "⌘" : "Ctrl", platformLabel = state?.platform === "mac" ? "macOS" : "Windows";
  let disposed = false, page = null, generation = 0, previewGeneration = 0, queryTimer, selectionReady = false;
  let query = { version: 2, text: "", view: "recent", offset: 0, limit: 100 }, selection = new Set(), anchor = null;
  let selectionRevision = 0, marquee = null, marqueeFrame = 0;
  let selectedAsset = null, preview = null, fullscreen = false, organizer = !!state?.organizer, zoom = 1, pdfPage = 1, composing = false, dragging = false, editingImage = false, dragIds = [], droppedInTrash = false;
  const thumbnails = new Map(), pendingThumbs = new Set();
  const root = document.createElement("section"); root.className = "assets-root";
  const icon = (name, size = 18) => `<svg width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${{
    menu:'<path d="M5 6h14M5 12h14M5 18h14"/>', search:'<circle cx="10.5" cy="10.5" r="6.5"/><path d="m16 16 4 4"/>',
    add:'<path d="M12 5v14M5 12h14"/>', folder:'<path d="M3 7V5h7l2 3h9v12H3Z"/>', paste:'<rect x="6" y="5" width="14" height="16" rx="2"/><path d="M9 5V3h8v2M3 8v10M10 11h6M10 15h6"/>',
    camera:'<path d="M3 7h4l2-3h6l2 3h4v13H3Z"/><circle cx="12" cy="13" r="4"/>', video:'<rect x="3" y="6" width="12" height="12" rx="2"/><path d="m15 10 6-4v12l-6-4"/>',
    organize:'<rect x="3" y="3" width="18" height="18" rx="2"/><path d="M9 3v18M9 9h12"/>', filter:'<path d="M4 7h16M4 17h16"/><circle cx="9" cy="7" r="2"/><circle cx="15" cy="17" r="2"/>', grid:'<rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/><rect x="14" y="14" width="7" height="7" rx="1"/>'
  }[name]}</svg>`;
  root.innerHTML = `<div class="assets-toolbar">
    <div class="assets-toolbar-primary">
      <button class="assets-icon-button" data-action="sidebar" title="分類を表示" aria-label="分類を表示">${icon("menu")}</button>
      <label class="assets-search-field">${icon("search")}<input class="assets-search" type="search" placeholder="素材の名前・タグを検索" aria-label="素材を検索"></label>
      <div class="assets-toolbar-actions">
        <button data-action="add" title="ファイルを取り込む">${icon("add")}<span>ファイル</span></button>
        <button class="assets-icon-button" data-action="clipboard" title="コピーした画像・ファイルを保存" aria-label="コピーした画像・ファイルを保存">${icon("paste")}</button>
        <span class="assets-toolbar-divider"></span>
        <button class="assets-icon-button assets-capture-button" data-action="screenshot" title="スクリーンショットを撮影" aria-label="スクリーンショットを撮影">${icon("camera")}</button>
        <button class="assets-icon-button assets-capture-button" data-action="recording" title="画面収録を開始・停止" aria-label="画面収録を開始・停止">${icon("video")}</button>
        <button class="assets-icon-button" data-action="organizer" title="広い画面で整理する" aria-label="広い画面で整理する">${icon("organize")}</button>
      </div>
    </div>
    <div class="assets-toolbar-filters">
      <select class="assets-format" aria-label="ファイル形式"></select>
      <div class="assets-sort-controls"><select class="assets-sort-by" aria-label="並び順"><option value="created">取り込み日</option><option value="name">名前</option><option value="size">ファイルサイズ</option></select><button class="assets-sort-direction" data-action="sortDirection" aria-label="降順"></button></div>
      <button class="assets-more-filters" data-action="filters" title="日付・検索条件" aria-label="日付・検索条件">${icon("filter")}</button>
      <label class="assets-thumbnail-control" title="一覧のサイズ">${icon("grid",12)}<input class="assets-thumbnail-size" type="range" min="100" max="260" step="4" value="124" aria-label="一覧のサイズ">${icon("grid",19)}</label>
    </div></div>
    <div class="assets-body"><aside class="assets-sidebar" aria-label="分類"></aside><div class="assets-main"><div class="assets-scroll" tabindex="0" role="listbox" aria-label="素材" aria-multiselectable="true"><div class="assets-spacer-top"></div><div class="assets-grid"></div><div class="assets-spacer-bottom"></div></div></div><section class="assets-preview" hidden aria-label="素材プレビュー"><div class="assets-preview-toolbar"><button data-action="endPreview" aria-label="一覧へ戻る">← 一覧</button><span class="assets-preview-name"></span><button data-action="zoomOut" aria-label="縮小">−</button><button data-action="zoomFit">フィット</button><button data-action="zoomIn" aria-label="拡大">＋</button><button data-action="fullscreen" aria-label="全画面を切り替え">⛶</button></div><div class="assets-media"></div><div class="assets-preview-bottom"></div></section></div><footer class="assets-footer"><span class="assets-summary" role="status"></span><span class="assets-selected-count" role="status"></span><span class="assets-status" role="status"></span></footer><dialog class="assets-selection assets-context-menu" aria-label="素材の操作"></dialog>`;
  const trashDrop = document.createElement("div"); trashDrop.className = "assets-trash-drop"; trashDrop.hidden = true; trashDrop.setAttribute("role", "status");
  trashDrop.innerHTML = `<span class="assets-trash-icon" aria-hidden="true">⌫</span><div><strong>${english ? "Drop to move to trash" : "ここにドロップしてゴミ箱へ"}</strong><small>${english ? "You can undo this after dropping" : "あとから「元に戻す」で復元できます"}</small></div>`;
  root.append(trashDrop);
  container.replaceChildren(root);
  translateAssetTree(root, t);
  root.classList.toggle("is-organizer", !!state?.organizer);
  const details = document.createElement("aside"); details.className = "assets-detail"; details.setAttribute("aria-label", "素材の詳細"); root.querySelector(".assets-body").append(details);
  const find = selector => root.querySelector(selector), scroll = find(".assets-scroll"), grid = find(".assets-grid"), media = find(".assets-media");
  const contextMenu = find(".assets-context-menu");
  function closeContextMenu() { if (contextMenu.open) contextMenu.close(); }
  contextMenu.addEventListener("cancel", event => { event.preventDefault(); closeContextMenu(); });
  contextMenu.addEventListener("pointerdown", event => { if (event.target === contextMenu) { const bounds = contextMenu.getBoundingClientRect(); if (event.clientX < bounds.left || event.clientX > bounds.right || event.clientY < bounds.top || event.clientY > bounds.bottom) closeContextMenu(); } });
  contextMenu.addEventListener("contextmenu", event => event.preventDefault());
  contextMenu.addEventListener("keydown", event => {
    const buttons = [...contextMenu.querySelectorAll("button:not(:disabled)")], index = buttons.indexOf(document.activeElement);
    if (!["ArrowDown", "ArrowUp", "Home", "End"].includes(event.key) || !buttons.length) return;
    event.preventDefault(); buttons[event.key === "Home" ? 0 : event.key === "End" ? buttons.length - 1 : (index + (event.key === "ArrowDown" ? 1 : -1) + buttons.length) % buttons.length].focus();
  });
  const selectionBox = document.createElement("div"); selectionBox.className = "assets-marquee"; selectionBox.hidden = true; scroll.append(selectionBox);
  scroll.title = english ? `Drag empty space to select. Shift-click selects a range; ${modifierLabel}-click adds or removes items.` : `空白をドラッグして範囲選択。Shift＋クリックで連続選択、${modifierLabel}＋クリックで追加・解除。`;
  const report = message => { if (!disposed) find(".assets-status").textContent = t(message); };
  const run = async (method, params) => { try { return await request(method, params); } catch (error) { report(error.message); return null; } };
  const button = (text, action, title = text) => { const el = document.createElement("button"); el.type = "button"; el.textContent = t(text); el.title = t(title); el.onclick = action; return el; };
  const input = find("input");
  const currentFolderId = () => {
    const ids = [...new Set([...(query.folderIds || []), ...(query.folderId ? [query.folderId] : [])])];
    return ids.length === 1 ? ids[0] : null;
  };
  let thumbnailSize = 124;
  try { const saved = Number(localStorage.getItem("hoverpocket.assets.thumbnailSize")); if (Number.isFinite(saved) && saved >= 100 && saved <= 260) thumbnailSize = saved; } catch { }
  const sizeBar = find(".assets-thumbnail-size"); sizeBar.value = thumbnailSize;
  function applyThumbnailSize() { root.style.setProperty("--asset-row-height", `${thumbnailSize + 28}px`); root.style.setProperty("--asset-image-height", `${thumbnailSize - 33}px`); sizeBar.setAttribute("aria-valuetext", `${thumbnailSize}px`); }
  applyThumbnailSize();
  sizeBar.addEventListener("input", () => { finishMarquee(); thumbnailSize = Number(sizeBar.value); applyThumbnailSize(); scroll.scrollTop = 0; renderGrid(); });
  sizeBar.addEventListener("change", () => { try { localStorage.setItem("hoverpocket.assets.thumbnailSize", String(thumbnailSize)); } catch { } });
  find(".assets-format").addEventListener("change", event => { const value = event.target.value; query.kind = value.startsWith("kind:") ? value.slice(5) : null; query.extension = value.startsWith("ext:") ? value.slice(4) : null; resetQuery(); });
  find(".assets-sort-by").addEventListener("change", event => { query.sortBy = event.target.value; resetQuery(); });
  function renderToolbar() {
    const format = find(".assets-format"), selected = query.extension != null ? "ext:" + query.extension : query.kind ? "kind:" + query.kind : "";
    const options = [["", "すべての形式"], ["kind:image", "画像"], ["kind:video", "動画"], ["kind:pdf", "PDF"], ["kind:other", "その他"]];
    for (const ext of [...new Set([...(page?.extensions || []), ...(query.extension != null ? [query.extension] : [])])].sort()) options.push(["ext:" + ext, ext ? ext.toUpperCase() : "拡張子なし"]);
    format.replaceChildren(...options.map(([value, text]) => { const option = document.createElement("option"); option.value = value; option.textContent = t(text); return option; })); format.value = selected;
    find(".assets-sort-by").value = query.sortBy || "created";
    const descending = query.descending !== false, direction = find(".assets-sort-direction");
    direction.textContent = (descending ? "↓ " : "↑ ") + t(descending ? "降順" : "昇順"); direction.title = t(descending ? "昇順に切り替え" : "降順に切り替え"); direction.setAttribute("aria-label", direction.title);
    find(".assets-more-filters").classList.toggle("is-active", !!(query.createdAfter || query.createdBefore));
  }
  renderToolbar();
  input.addEventListener("compositionstart", () => { composing = true; clearTimeout(queryTimer); });
  input.addEventListener("compositionend", () => { composing = false; query.text = input.value; resetQuery(); });
  input.addEventListener("input", () => { if (composing) return; clearTimeout(queryTimer); queryTimer = setTimeout(() => { query.text = input.value; resetQuery(); }, 150); });
  input.addEventListener("keydown", event => { if (event.key === "Enter" && !event.isComposing) { clearTimeout(queryTimer); query.text = input.value; resetQuery(); } });
  let columns = 3, rowsInWindow = 7, startRow = 0;
  function resetQuery() { query.version = 2; renderToolbar(); finishMarquee(); ++selectionRevision; anchor = null; scroll.scrollTop = 0; query.offset = 0; void refresh(); }
  async function refresh() {
    closeContextMenu();
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
    const conditions = [query.extension != null ? query.extension.toUpperCase() || t("拡張子なし") : query.kind && t(({image:"画像",video:"動画",pdf:"PDF",other:"その他"})[query.kind]), query.createdAfter && new Date(query.createdAfter).toLocaleDateString(), query.createdBefore && "< " + new Date(query.createdBefore).toLocaleDateString(), ...[...(query.folderIds||[]),...(query.tagIds||[])].map(id=>[...result.folders,...result.tags].find(c=>c.id===id)?.name)].filter(Boolean);
    find(".assets-summary").textContent = `${result.total.toLocaleString()}${english ? " items" : "件"}${conditions.length ? " · " + conditions.join(" / ") : ""}`;
    renderToolbar(); renderSidebar(); renderGrid(); renderSelection(); renderDetails();
  }
  function renderSidebar() {
    const sidebar = find(".assets-sidebar"); sidebar.replaceChildren();
    for (const [view, name] of [["recent", "最近の素材"], ["favorites", "★ お気に入り"], ["uncategorized", "未分類"], ["trash", "ゴミ箱"]]) {
      const el = button(name, () => { query = { ...query, view, folderId: null, tagId: null, folderIds:[], tagIds:[] }; resetQuery(); }); el.classList.toggle("is-selected", query.view === view && !query.folderId && !query.tagId && !query.folderIds?.length && !query.tagIds?.length); sidebar.append(el);
    }
    if (query.view === "trash") sidebar.append(button("ゴミ箱を空にする…", async () => { const result = await run("assets.emptyTrash"); if (result?.removed !== undefined) report(`${result.removed}件を${platformLabel}のゴミ箱へ移しました。移せなかった原本は保持されています。`); await refresh(); }));
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
    const from = document.createElement("input"), to = document.createElement("input"); from.type=to.type="date";
    const localDate = value => { if (!value) return ""; const date = new Date(value); return `${date.getFullYear()}-${String(date.getMonth()+1).padStart(2,"0")}-${String(date.getDate()).padStart(2,"0")}`; };
    from.value = localDate(query.createdAfter); if (query.createdBefore) { const date = new Date(query.createdBefore); date.setDate(date.getDate()-1); to.value = localDate(date.toISOString()); }
    for (const [title,control] of [["取り込み日：開始",from],["取り込み日：終了（この日を含む）",to]]) { const label=document.createElement("label"); label.textContent=t(title); label.append(control); dialog.append(label); }
    const summary = document.createElement("p"); summary.textContent = [...(query.folderIds||[]), ...(query.tagIds||[])].map(id=>[...page.folders,...page.tags].find(c=>c.id===id)?.name).filter(Boolean).join(" / ") || t("分類・タグは一覧のCtrlクリックで複数指定できます。").replace("Ctrl",modifierLabel); dialog.append(summary);
    const utc = (value, next=false) => { if (!value) return null; const parts=value.split("-").map(Number); const date=new Date(parts[0],parts[1]-1,parts[2]); if (next) date.setDate(date.getDate()+1); return date.toISOString(); };
    dialog.append(button("適用", () => { query = {...query,createdAfter:utc(from.value),createdBefore:utc(to.value,true)}; dialog.close(); resetQuery(); }), button("条件を解除", () => { query={text:"",view:"recent",offset:0,limit:100}; input.value=""; dialog.close(); resetQuery(); }), button("閉じる",()=>dialog.close()));
    root.append(dialog); dialog.addEventListener("close",()=>dialog.remove()); dialog.showModal();
  }

  function renderGrid() {
    if (!page || preview || disposed || dragging) return;
    const rowHeight = thumbnailSize + 28;
    columns = Math.max(1, Math.floor((scroll.clientWidth - 8) / (thumbnailSize + 8))); rowsInWindow = Math.ceil(scroll.clientHeight / rowHeight) + 3;
    startRow = Math.max(0, Math.floor(scroll.scrollTop / rowHeight) - 1);
    const wanted = startRow * columns;
    if (wanted < query.offset || wanted + rowsInWindow * columns > query.offset + page.items.length && query.offset + page.items.length < page.total) {
      query.offset = wanted; query.limit = Math.min(200, Math.max(100, rowsInWindow * columns)); void refresh(); return;
    }
    const items = page.items.slice(Math.max(0, wanted - query.offset), Math.max(0, wanted - query.offset) + rowsInWindow * columns);
    find(".assets-spacer-top").style.height = `${startRow * rowHeight}px`;
    find(".assets-spacer-bottom").style.height = `${Math.max(0, Math.ceil(page.total / columns) - startRow - Math.ceil(items.length / columns)) * rowHeight}px`;
    // Keep cards attached across selection and layout changes so the second native
    // click still targets the same element.
    const cards = new Map(Array.from(grid.children, card => [card.dataset.assetId, card]));
    const visibleIds = new Set(items.map(asset => asset.id));
    for (const [id, card] of cards) if (!visibleIds.has(id)) card.remove();
    grid.style.gridTemplateColumns = `repeat(${columns},minmax(0,1fr))`;
    let cardIndex = 0;
    for (const asset of items) {
      const card = cards.get(asset.id) ?? document.createElement("div"); card.className = "assets-card"; card.dataset.assetId = asset.id; card.setAttribute("role", "option"); card.setAttribute("aria-selected", selection.has(asset.id)); card.tabIndex = -1; card.draggable = true;
      if (!card.firstChild) card.innerHTML = '<span class="assets-kind"></span><img alt="" draggable="false" decoding="async"><span class="assets-card-name"></span><small></small><button class="assets-card-favorite" type="button" draggable="false"></button>';
      const image = card.querySelector("img");
      const placeholder = card.querySelector(".assets-kind"); placeholder.textContent = asset.kind === "pdf" ? "PDF" : asset.kind === "video" ? "▶" : asset.kind === "image" ? "▧" : asset.extension.toUpperCase() || "FILE";
      const title = card.querySelector(".assets-card-name"); title.textContent = asset.name; title.title = asset.name;
      const favorite = card.querySelector(".assets-card-favorite"); favorite.textContent = asset.favorite ? "★" : "☆"; favorite.setAttribute("aria-pressed", !!asset.favorite);
      favorite.title = t(asset.favorite ? "お気に入りから外す" : "お気に入りに追加"); favorite.setAttribute("aria-label", favorite.title);
      favorite.onclick = event => { event.stopPropagation(); void update("favorite", undefined, [asset.id]); };
      favorite.ondblclick = event => { event.preventDefault(); event.stopPropagation(); };
      favorite.onpointerdown = event => event.stopPropagation();
      card.querySelector("small").textContent = bytes(asset.sizeBytes);
      if (grid.children[cardIndex] !== card) grid.insertBefore(card, grid.children[cardIndex] ?? null);
      cardIndex++;
      if (image.getAttribute("src")) { /* keep the decoded thumbnail */ }
      else if (thumbnails.has(asset.id)) image.src = thumbnails.get(asset.id);
      else if (asset.kind !== "other" && !pendingThumbs.has(asset.id)) {
        pendingThumbs.add(asset.id);
        // The visible window bounds the number of requests and decoded images.
        void run("assets.thumbnail", { id: asset.id }).then(frame => {
          pendingThumbs.delete(asset.id); if (disposed || !frame?.dataUrl) return;
          thumbnails.set(asset.id, frame.dataUrl); while (thumbnails.size > 150) thumbnails.delete(thumbnails.keys().next().value);
          const visible = Array.from(grid.children).find(el => el.dataset.assetId === asset.id); if (visible) visible.querySelector("img").src = frame.dataUrl;
        });
      }
      card.onclick = event => { void select(asset, event); };
      card.oncontextmenu = event => { event.preventDefault(); void openContextMenu(asset, event.clientX, event.clientY); };
      card.ondblclick = event => {
        if (event.shiftKey || event.ctrlKey || event.metaKey || event.target.closest("button")) return;
        if (event.target.closest(".assets-card-name")) void renameAsset(asset);
        else void openPreview(asset);
      };
      card.ondragstart = event => { event.preventDefault(); if (!event.target.closest("button")) void dragAsset(asset); };
    }
    if (marquee) updateMarquee();
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
      if (trashed) report(english ? `${trashed} moved to trash. ${modifierLabel}+Z to undo.` : `${trashed}件をゴミ箱へ移しました。${modifierLabel}+Zで元に戻せます。`);
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
  async function select(asset, event = {}) {
    if (!selectionReady) return;
    const revision = ++selectionRevision, current = generation;
    if (event.shiftKey && anchor) {
      selectionReady = false; renderSelection();
      const range = await run("assets.selectionRange", { query: { ...query }, anchorId: anchor, targetId: asset.id });
      if (disposed || revision !== selectionRevision || current !== generation) return;
      selectionReady = true;
      if (!range?.ids?.length) { renderSelection(); return; }
      selection = new Set(event.ctrlKey || event.metaKey ? [...selection, ...range.ids] : range.ids);
    } else if (event.ctrlKey || event.metaKey) { if (selection.has(asset.id)) selection.delete(asset.id); else selection.add(asset.id); anchor = asset.id; }
    else { selection = new Set([asset.id]); anchor = asset.id; }
    selectedAsset = asset;
    // Keep the clicked card attached so the browser can deliver the second click and dblclick.
    paintSelection(); scroll.focus({ preventScroll: true });
  }
  function paintSelection() {
    for (const card of grid.children) card.setAttribute("aria-selected", selection.has(card.dataset.assetId));
    renderSelection(); renderDetails();
  }
  function updateMarquee() {
    if (!marquee || !page) return;
    const bounds = scroll.getBoundingClientRect();
    const x = Math.max(0, Math.min(scroll.clientWidth, marquee.clientX - bounds.left));
    const y = Math.max(0, Math.min(scroll.clientHeight, marquee.clientY - bounds.top)) + scroll.scrollTop;
    const box = { left: Math.min(marquee.x, x), top: Math.min(marquee.y, y), right: Math.max(marquee.x, x), bottom: Math.max(marquee.y, y) };
    Object.assign(selectionBox.style, { left: `${box.left}px`, top: `${box.top}px`, width: `${box.right - box.left}px`, height: `${box.bottom - box.top}px` });
    for (const card of grid.children) {
      const rect = card.getBoundingClientRect(), asset = page.items.find(item => item.id === card.dataset.assetId);
      if (asset) marquee.cards.set(asset.id, { asset, left: rect.left - bounds.left, right: rect.right - bounds.left, top: rect.top - bounds.top + scroll.scrollTop, bottom: rect.bottom - bounds.top + scroll.scrollTop });
    }
    const next = new Set(marquee.base);
    for (const [id, card] of marquee.cards) if (card.left < box.right && card.right > box.left && card.top < box.bottom && card.bottom > box.top) { next.add(id); selectedAsset = card.asset; }
    if (!next.has(selectedAsset?.id)) selectedAsset = page.items.find(asset => next.has(asset.id)) || [...marquee.cards.values()].find(card => next.has(card.asset.id))?.asset || null;
    if (next.size !== selection.size || [...next].some(id => !selection.has(id))) { selection = next; paintSelection(); }
  }
  function finishMarquee() {
    if (!marquee) return;
    const pointer = marquee.pointerId; marquee = null; cancelAnimationFrame(marqueeFrame); selectionBox.hidden = true;
    if (scroll.hasPointerCapture(pointer)) scroll.releasePointerCapture(pointer);
    anchor = selectedAsset?.id ?? null;
  }
  function scrollMarquee() {
    if (!marquee) return;
    const bounds = scroll.getBoundingClientRect();
    const delta = marquee.clientY < bounds.top + 28 ? -12 : marquee.clientY > bounds.bottom - 28 ? 12 : 0;
    if (delta) { scroll.scrollTop += delta; renderGrid(); updateMarquee(); }
    marqueeFrame = requestAnimationFrame(scrollMarquee);
  }
  scroll.addEventListener("pointerdown", event => {
    if (event.button !== 0 || !selectionReady || preview || dragging || event.target.closest(".assets-card")) return;
    const bounds = scroll.getBoundingClientRect();
    if (event.clientX - bounds.left >= scroll.clientWidth || event.clientY - bounds.top >= scroll.clientHeight) return;
    event.preventDefault(); ++selectionRevision;
    marquee = { pointerId: event.pointerId, x: event.clientX - bounds.left, y: event.clientY - bounds.top + scroll.scrollTop, clientX: event.clientX, clientY: event.clientY, base: event.ctrlKey || event.metaKey || event.shiftKey ? [...selection] : [], cards: new Map() };
    selectionBox.hidden = false; scroll.focus({ preventScroll: true });
    if (event.isTrusted) scroll.setPointerCapture(event.pointerId);
    updateMarquee(); marqueeFrame = requestAnimationFrame(scrollMarquee);
  });
  scroll.addEventListener("pointermove", event => { if (marquee && event.pointerId === marquee.pointerId) { marquee.clientX = event.clientX; marquee.clientY = event.clientY; updateMarquee(); } });
  scroll.addEventListener("pointerup", finishMarquee);
  scroll.addEventListener("pointercancel", finishMarquee);
  scroll.addEventListener("lostpointercapture", finishMarquee);
  async function openContextMenu(asset, x, y) {
    if (!selectionReady || preview || dragging || editingImage || root.querySelector("dialog[open]")) return;
    if (!selection.has(asset.id)) await select(asset);
    else { selectedAsset = asset; paintSelection(); }
    if (disposed || !selectionReady || !selection.has(asset.id)) return;
    contextMenu.style.left = "0px"; contextMenu.style.top = "0px"; contextMenu.showModal();
    const bounds = contextMenu.getBoundingClientRect();
    contextMenu.style.left = `${Math.max(8, Math.min(x, innerWidth - bounds.width - 8))}px`;
    contextMenu.style.top = `${Math.max(8, Math.min(y, innerHeight - bounds.height - 8))}px`;
  }
  function renderSelection() {
    const count = selection.size ? `${selection.size}${english ? " selected" : "件選択"}` : "";
    find(".assets-selected-count").textContent = count;
    const tools = contextMenu; tools.replaceChildren(); if (!selectionReady || !selection.size || !selectedAsset) { closeContextMenu(); return; }
    const status = document.createElement("span"); status.textContent = count; tools.append(status);
    const item = (text, action) => button(text, () => { closeContextMenu(); if (selectionReady && selection.size) void action(); });
    tools.append(item("プレビュー", () => openPreview(selectedAsset)), item("分類", classify), item("名前", () => renameAsset(selectedAsset)), item("コピー", () => run("assets.copy", { id: selectedAsset.id, ids:[...selection] })), item("保存先…", () => run("assets.copy", { id: selectedAsset.id, mode: "save" })), item(query.view === "trash" ? "復元" : "ゴミ箱", () => update(query.view === "trash" ? "restore" : "trash")), item("元に戻す", () => run("assets.undo").then(refresh)));
  }
  async function update(operation, value, ids = [...selection]) {
    if (!selectionReady || !ids.length) return;
    selectionReady = false; closeContextMenu(); renderSelection();
    const result = await run("assets.update", { ids, operation, value });
    if (result?.ok && operation === "trash") report(english ? `${ids.length} moved to trash. ${modifierLabel}+Z to undo.` : `${ids.length}件をゴミ箱へ移しました。${modifierLabel}+Zで元に戻せます。`);
    await refresh();
  }
  async function renameAsset(asset) {
    if (!selectionReady || root.querySelector("dialog[open]")) return;
    const name = await ask("素材の名前", asset.name, true);
    if (!name || name === asset.name || disposed) return;
    await run("assets.update", {ids:[asset.id], operation:"rename", value:name});
    await refresh();
  }
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
  async function ask(title, initial = "", selectStem = false) {
    return new Promise(resolve => {
      const dialog = document.createElement("dialog"); dialog.className = "assets-dialog"; const label = document.createElement("label"); label.textContent = t(title);
      const field = document.createElement("input"); field.value = initial; label.append(field); dialog.append(label);
      const finish = value => { dialog.close(); dialog.remove(); resolve(value); };
      dialog.append(button("保存", () => finish(field.value.trim())), button("キャンセル", () => finish(null))); dialog.addEventListener("cancel", event => { event.preventDefault(); finish(null); });
      field.onkeydown = event => { if (event.key === "Enter" && !event.isComposing) finish(field.value.trim()); }; root.append(dialog); dialog.showModal(); field.focus();
      if (selectStem && initial.lastIndexOf(".") > 0) field.setSelectionRange(0,initial.lastIndexOf(".")); else field.select();
    });
  }
  async function openPreview(asset, requestedPage = 1) {
    closeContextMenu();
    void run("assets.visibility", {visible:false});
    const current = ++previewGeneration; const same = preview?.id === asset.id;
    preview = { id: asset.id, kind: asset.kind };
    const transition = await run("assets.transition");
    if (disposed || current !== previewGeneration) { await run("assets.transition", { cancel: transition?.revision || 0 }); return; }
    let editButton = null;
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
      if (!video) { video = document.createElement("video"); video.controls = true; video.preload = "metadata"; video.autoplay = false; video.playsInline = true; video.src = result.videoUrl; if (result.dataUrl) video.poster = result.dataUrl; video.onerror = () => report(`この動画は再生できません。原本は保存されています。${platformLabel}のメディア機能と形式を確認してください。`); media.replaceChildren(video); }
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
        if (editingImage) return; editingImage = true; edit.disabled = true; root.setAttribute("aria-busy", "true");
        try {
          const saved = await run("assets.editImage", {id:asset.id});
          if (saved?.ok) { report(english ? "Edited image saved. Original preserved." : "編集画像を保存しました。元画像も残っています。"); await refresh(); if (!disposed && preview?.id === asset.id && saved.asset) await openPreview(saved.asset); }
        } finally { editingImage = false; edit.disabled = false; root.removeAttribute("aria-busy"); }
      });
      edit.className = "assets-edit-image"; edit.disabled = true; editButton = edit; footer.append(edit);
    }
    footer.append(button("ファイルをコピー", () => run("assets.copy", { id: asset.id })), button("保存先…", () => run("assets.copy", { id: asset.id, mode: "save" })));
    applyZoom();
    const readyImage = media.querySelector("img");
    if (readyImage) await readyImage.decode().catch(() => {});
    if (disposed || current !== previewGeneration) return;
    await run("assets.layout", { fullscreen });
    await run("panel.beginTextInput");
    if (editButton && !disposed && current === previewGeneration) editButton.disabled = false;
    } finally {
      // Same-size images may not start a resize. Release the preparation if no
      // native animation took ownership by advancing its revision.
      await run("assets.transition", { cancel: transition?.revision || 0 });
    }
  }
  function stopMedia() { const video = media.querySelector("video"); if (video) { video.pause(); video.removeAttribute("src"); video.load(); } }
  async function endPreview() {
    const current = ++previewGeneration;
    const transition = await run("assets.transition");
    if (disposed || current !== previewGeneration) { await run("assets.transition", { cancel: transition?.revision || 0 }); return; }
    try {
      resetPreviewUi();
      // Finish the grid before the panel resizes so the arrival snapshot matches the live page.
      await run("assets.visibility", {visible:true}); renderGrid(); renderSelection(); renderDetails();
      await run("assets.endPreview"); await run("panel.endTextInput"); if (organizer) await run("assets.organizer");
    } finally {
      // A quick cancellation can finish before the native preview starts. No resize
      // then takes ownership of this snapshot, so release that unchanged revision.
      await run("assets.transition", { cancel: transition?.revision || 0 });
    }
  }
  function resetPreviewUi() {
    ++previewGeneration; stopMedia(); preview = null; fullscreen = false; zoom = 1;
    if (document.fullscreenElement && root.contains(document.fullscreenElement)) void document.exitFullscreen().catch(() => {});
    media.replaceChildren(); find(".assets-preview").hidden = true; root.classList.remove("has-preview", "is-fullscreen"); document.body.classList.remove("assets-fullscreen");
    renderGrid(); renderSelection(); renderDetails();
  }
  function applyZoom() { const image = media.querySelector("img"); if (image) { image.style.transform = `scale(${zoom})`; media.classList.toggle("is-zoomed", zoom > 1); } }
  function showFullscreen(value) { fullscreen = value; root.classList.toggle("is-fullscreen", value); if (!organizer) document.body.classList.toggle("assets-fullscreen", value); }
  async function toggleFullscreen() {
    if (!preview) return;
    if (document.fullscreenElement && root.contains(document.fullscreenElement)) { await document.exitFullscreen(); return; }
    showFullscreen(!fullscreen); await run("assets.layout", { fullscreen });
  }
  const actions = {
    sidebar: () => root.classList.toggle("show-sidebar"), add: () => run("assets.pick"), folder: () => run("assets.pick", { kind: "folder" }), clipboard: () => run("assets.clipboard"),
    organizer: () => run("assets.openOrganizer"),
    screenshot: () => run("assets.capture", { kind:"screenshot", folderId: currentFolderId() }), recording: () => run("assets.capture", { kind:"recording", folderId: currentFolderId() }),
    filters, sortDirection: () => { query.descending = query.descending === false; resetQuery(); },
    endPreview, fullscreen: toggleFullscreen, zoomIn: () => { zoom = Math.min(8, zoom * 1.25); applyZoom(); }, zoomOut: () => { zoom = Math.max(.25, zoom / 1.25); applyZoom(); }, zoomFit: () => { zoom = 1; applyZoom(); }
  };
  root.addEventListener("click", event => { const action = event.target.closest("[data-action]")?.dataset.action; if (action) void actions[action]?.(); });
  root.addEventListener("contextmenu", event => { if (!event.target.closest('[data-action="add"]')) return; event.preventDefault(); void run("assets.pick", { kind: "folder" }); });
  scroll.addEventListener("scroll", () => renderGrid(), { passive: true });
  const observer = new ResizeObserver(() => renderGrid()); observer.observe(scroll);
  const keydown = event => {
    if (event.isComposing || event.keyCode === 229 || root.querySelector("dialog[open]") || dragging || editingImage) return;
    if (event.repeat && [" ", "Escape", "F11", "Delete"].includes(event.key) && !event.target.closest("input,textarea,[contenteditable='true']")) { event.preventDefault(); return; }
    if (event.key === " " && event.target.closest("button,a,select,video")) return;
    const editing = event.target.closest("input,textarea,select,[contenteditable='true']");
    if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "f") { event.preventDefault(); input.focus(); return; }
    if (event.key === "F11" && preview) { event.preventDefault(); void toggleFullscreen(); }
    else if (event.key === "Escape") { event.preventDefault(); if (fullscreen) void toggleFullscreen(); else if (preview) void endPreview(); else if (organizer) void actions.organizer(); }
    else if (editing) return;
    else if ((event.key === "ContextMenu" || event.shiftKey && event.key === "F10") && selectedAsset && !preview) {
      event.preventDefault(); const bounds = [...grid.children].find(card => card.dataset.assetId === selectedAsset.id)?.getBoundingClientRect() || scroll.getBoundingClientRect();
      void openContextMenu(selectedAsset, bounds.left + 12, bounds.top + 12);
    }
    else if (event.key === "Delete" && !preview && query.view !== "trash" && selection.size) { event.preventDefault(); void update("trash"); }
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
  media.addEventListener("dblclick", event => {
    if (editingImage || !preview || !["image", "video"].includes(preview.kind) || !event.target.matches("img,video")) return;
    event.preventDefault(); event.stopPropagation(); void endPreview();
  });
  media.addEventListener("pointerdown", event => { if (zoom <= 1 || !media.querySelector("img")) return; pan = { x: event.clientX, y: event.clientY, left: media.scrollLeft, top: media.scrollTop }; media.setPointerCapture(event.pointerId); });
  media.addEventListener("pointermove", event => { if (pan) { media.scrollLeft = pan.left - event.clientX + pan.x; media.scrollTop = pan.top - event.clientY + pan.y; } });
  media.addEventListener("pointerup", () => { pan = null; });
  // Occlusion can hide the WebView while its native window is still open. Keep the
  // source so returning to a paused video remains playable; panel.closed releases it.
  const visibilityChanged = () => { if (document.hidden) { media.querySelector("video")?.pause(); void run("assets.visibility",{visible:false}); } else void run("assets.visibility",{visible:true}).then(() => { if (!preview) return refresh(); }); };
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
  }), on("panel.closed", () => { closeContextMenu(); if (preview) resetPreviewUi(); finishMarquee(); void run("assets.visibility", {visible:false}); }), on("panel.opened", () => { void run("assets.visibility", {visible:true}).then(refresh); }), on("assets.fullscreenChanged", payload => { if (preview) showFullscreen(!!payload.fullscreen); }), on("assets.previewEnded", () => { if (preview) { resetPreviewUi(); void run("panel.endTextInput"); void run("assets.visibility",{visible:!document.hidden}).then(()=>renderGrid()); } })];
  void run("assets.status").then(status => { if (status?.warning) report(status.warning); });
  void run("assets.visibility", {visible:true});
  void run("assets.importState").then(progress=>{if(progress&&(progress.busy||progress.completed||progress.failed||progress.duplicates))showImportProgress(progress);});
  void refresh();
  return { refresh, dispose() { closeContextMenu(); finishMarquee(); ++selectionRevision; document.body.classList.remove("assets-fullscreen"); disposed = true; ++generation; ++previewGeneration; clearTimeout(queryTimer); clearTimeout(eventTimer); observer.disconnect(); document.removeEventListener("keydown", keydown); document.removeEventListener("visibilitychange",visibilityChanged); unsubscribers.forEach(unsubscribe => unsubscribe()); stopMedia(); void request("assets.visibility", {visible:false}).catch(() => {}); void request("assets.endPreview").catch(() => {}); thumbnails.clear(); } };
}

function bytes(value) { return value < 1024 ? `${value} B` : value < 1024 * 1024 ? `${(value / 1024).toFixed(1)} KB` : `${(value / (1024 * 1024)).toFixed(1)} MB`; }
