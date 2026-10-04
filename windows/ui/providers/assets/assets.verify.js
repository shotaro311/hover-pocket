import { renderAssetsProvider } from "./assets.js";

export async function verifyAssetSelection() {
  const host = document.createElement("div");
  host.style.cssText = "position:fixed;inset:0;width:900px;height:600px;z-index:99999;background:#111";
  document.body.append(host);
  const a = { id:"a", name:"visible.txt", extension:"txt", kind:"other", sizeBytes:5, createdAt:"2026-10-03T00:00:00Z", favorite:true, folderIds:["folder-a"], tagIds:[] };
  const rows = [a, { ...a, id:"b", name:"hidden.txt", favorite:false }, ...Array.from({length:218}, (_,i) => ({...a,id:`item-${i}`,favorite:false}))];
  const calls = [], checks = [];
  let releaseMatch = null, delayMatch = false, failMatch = false, releaseDrag = null;
  const matches = (row, query) => (query.view !== "favorites" || row.favorite) && (!query.kind || row.kind === query.kind) && (query.extension == null || row.extension === query.extension);
  const request = async (method, params) => {
    calls.push({method,params:structuredClone(params)});
    if (method === "assets.query") {
      const items = rows.filter(row => matches(row,params));
      return {items:items.slice(params.offset,params.offset+params.limit),total:items.length,
        folders:[{id:"folder-a",name:"Fixture A",parentId:null},{id:"folder-b",name:"Fixture B",parentId:null}],tags:[],searches:[],extensions:["txt","png","mp4"]};
    }
    if (method === "assets.selectionRange") {
      const items = rows.filter(row => matches(row,params.query));
      const first=items.findIndex(row=>row.id===params.anchorId), last=items.findIndex(row=>row.id===params.targetId);
      return {ids:first<0||last<0?[]:items.slice(Math.min(first,last),Math.max(first,last)+1).map(row=>row.id)};
    }
    if (method === "assets.matches") {
      if (delayMatch) await new Promise(resolve => { releaseMatch = resolve; });
      if (failMatch) throw Error("Synthetic query failure");
      return {matches:matches(rows.find(row => row.id === params.id),params.query)};
    }
    if (method === "assets.update" && params.operation === "favorite") for (const row of rows.filter(row => params.ids.includes(row.id))) row.favorite = !row.favorite;
    if (method === "assets.preview") return {id:params.id,kind:"image",width:1,height:1,dataUrl:"data:image/gif;base64,R0lGODlhAQABAAD/ACwAAAAAAQABAAACADs="};
    if (method === "assets.copy" && params.mode === "drag") { await new Promise(resolve => { releaseDrag=resolve; }); return {ok:true}; }
    if (method === "assets.importState") return {busy:false,completed:0,duplicates:0,skipped:0,failed:0};
    return {ok:true};
  };
  const provider = renderAssetsProvider({container:host,request,state:{settings:{language:"ja"}}});
  const wait = ms => new Promise(resolve => setTimeout(resolve,ms));
  const until = async condition => { const start=performance.now(); while(!condition()) { if(performance.now()-start>5000) throw Error("Fixture UI timeout"); await wait(10); } };
  const button = (area,text) => [...host.querySelectorAll(`${area} button`)].find(el=>el.textContent===text);
  const card = id => host.querySelector(`[data-asset-id="${id}"]`);
  const last = method => calls.filter(call=>call.method===method).at(-1)?.params;
  const check = (ok,name) => { if(!ok) throw Error(name); checks.push(name); };
  const clickView = async text => { button(".assets-sidebar",text).click(); await until(()=>card("a")); await wait(40); };
  try {
    await until(()=>card("a"));
    check(!host.querySelector("[data-action=folder]"),"library toolbar no longer shows folder import button");
    const format = host.querySelector(".assets-format"), sort = host.querySelector(".assets-sort-by"), slider = host.querySelector(".assets-thumbnail-size");
    check([format,sort].every(select => getComputedStyle(select).backgroundColor === "rgb(23, 26, 32)" && [...select.options].every(option => getComputedStyle(option).backgroundColor === "rgb(32, 36, 45)" && getComputedStyle(option).color === "rgb(229, 234, 244)")),"format and sort options have opaque dark backgrounds and readable text");
    format.value="ext:png"; format.dispatchEvent(new Event("change")); await wait(60);
    check(last("assets.query").extension==="png" && !host.querySelector(".assets-card"),"format selector filters the full library");
    format.value=""; format.dispatchEvent(new Event("change")); await until(()=>card("a"));
    sort.value="name"; sort.dispatchEvent(new Event("change")); await wait(60);
    host.querySelector("[data-action=sortDirection]").click(); await wait(60);
    check(last("assets.query").sortBy==="name" && last("assets.query").descending===false && last("assets.query").version===2,"sort key and direction reach the library query");
    const originalSize=slider.value, originalHeight=card("a").getBoundingClientRect().height;
    card("a").click(); slider.value="260"; slider.dispatchEvent(new Event("input")); await wait(60);
    check(card("a").getBoundingClientRect().height>originalHeight && card("a").getAttribute("aria-selected")==="true","thumbnail bar resizes cards while preserving selection");
    const rangeKey = new KeyboardEvent("keydown",{key:"ArrowRight",bubbles:true,cancelable:true}); slider.dispatchEvent(rangeKey);
    check(!rangeKey.defaultPrevented,"thumbnail slider keeps native keyboard controls");
    slider.value=originalSize; slider.dispatchEvent(new Event("input")); sort.value="created"; sort.dispatchEvent(new Event("change")); host.querySelector("[data-action=sortDirection]").click(); await wait(60);
    host.style.width="480px"; await wait(60);
    check(host.querySelector(".assets-toolbar").scrollWidth<=host.querySelector(".assets-toolbar").clientWidth+1,"toolbar fits narrow panels");
    host.style.width="900px"; await wait(60);
    host.querySelector("[data-action=recording]").click();
    check(last("assets.capture").kind==="recording" && last("assets.capture").folderId===null,"video icon directly dispatches recording");
    // Reset selection before the existing range and drag acceptance checks.
    await clickView("最近の素材");
    button(".assets-sidebar","Fixture A").click(); await wait(60);
    host.querySelector("[data-action=screenshot]").click();
    check(last("assets.capture").folderId === "folder-a" && last("assets.capture").kind === "screenshot", "single folder capture handoff");
    button(".assets-sidebar","Fixture B").dispatchEvent(new MouseEvent("click",{ctrlKey:true,bubbles:true})); await wait(60);
    host.querySelector("[data-action=screenshot]").click();
    check(last("assets.capture").folderId === null, "multiple folders do not choose an arbitrary capture target");
    await clickView("最近の素材"); host.querySelector("[data-action=screenshot]").click();
    check(last("assets.capture").folderId === null, "root capture clears destination");

    card("b").click(); card("a").dispatchEvent(new MouseEvent("click",{ctrlKey:true,bubbles:true}));
    const staleTrash = button(".assets-selection","ゴミ箱"); delayMatch=true;
    button(".assets-sidebar","★ お気に入り").click(); await until(()=>releaseMatch);
    staleTrash.click();
    check(!calls.some(call=>call.method==="assets.update"), "bulk actions wait for selection validation");
    delayMatch=false; releaseMatch(); releaseMatch=null;
    await until(()=>button(".assets-selection","ゴミ箱"));
    button(".assets-selection","ゴミ箱").click(); await wait(60);
    check(last("assets.update").ids.join() === "a", "hidden nonmatching selection removed from bulk mutation");

    await clickView("最近の素材"); card("a").click(); card("b").dispatchEvent(new MouseEvent("click",{ctrlKey:true,bubbles:true}));
    const menu=host.querySelector(".assets-context-menu"), footer=host.querySelector(".assets-footer");
    check(getComputedStyle(menu).display==="none" && footer.contains(host.querySelector(".assets-summary")) && host.querySelector(".assets-selected-count").textContent==="2件選択","selection actions stay hidden and counts live in the bottom footer");
    const rightClick=(id,x=innerWidth-2,y=innerHeight-2)=>card(id).dispatchEvent(new MouseEvent("contextmenu",{bubbles:true,cancelable:true,clientX:x,clientY:y}));
    rightClick("a"); await until(()=>menu.open);
    const menuBounds=menu.getBoundingClientRect();
    check(host.querySelectorAll('[aria-selected="true"]').length===2 && menuBounds.right<=innerWidth && menuBounds.bottom<=innerHeight,"right-click preserves multiple selection and keeps the menu within the viewport");
    button(".assets-selection","コピー").click(); await wait(30);
    check(!menu.open && last("assets.copy").ids.length===2 && last("assets.copy").id==="a","context copy acts on the preserved selection and closes the menu");
    rightClick("item-0"); await until(()=>menu.open);
    check(host.querySelectorAll('[aria-selected="true"]').length===1 && card("item-0").getAttribute("aria-selected")==="true","right-click on an unselected card targets only that card");
    menu.dispatchEvent(new Event("cancel",{cancelable:true}));
    check(!menu.open,"Escape cancels the context menu");
    rightClick("a",10,10); await until(()=>menu.open);
    menu.dispatchEvent(new PointerEvent("pointerdown",{clientX:0,clientY:0,bubbles:true}));
    check(!menu.open,"clicking outside dismisses the context menu");
    card("b").dispatchEvent(new MouseEvent("click",{ctrlKey:true,bubbles:true}));
    card("b").querySelector(".assets-card-favorite").click(); await wait(60);
    check(last("assets.update").ids.join()==="b" && rows[1].favorite && card("b").querySelector(".assets-card-favorite").getAttribute("aria-pressed")==="true" && host.querySelectorAll('[aria-selected="true"]').length===2 && host.querySelector(".assets-preview").hidden,"hover star favorites only its own card without changing selection or opening preview");
    card("b").querySelector(".assets-card-favorite").click(); await wait(60);
    check(!rows[1].favorite,"favorite star can remove the favorite again");
    card("a").click();
    card("item-3").dispatchEvent(new MouseEvent("click",{shiftKey:true,bubbles:true}));
    await until(()=>host.querySelector(".assets-selection").textContent.includes("6件選択"));
    check(host.querySelectorAll('[aria-selected="true"]').length===6,"Shift selects the inclusive range");
    card("b").dispatchEvent(new MouseEvent("click",{shiftKey:true,bubbles:true}));
    await until(()=>host.querySelector(".assets-selection").textContent.includes("2件選択"));
    check(card("item-3").getAttribute("aria-selected")==="false","Shift can shrink the same anchored range");
    card("item-3").dispatchEvent(new MouseEvent("click",{ctrlKey:true,bubbles:true}));
    card("item-5").dispatchEvent(new MouseEvent("click",{ctrlKey:true,shiftKey:true,bubbles:true}));
    await until(()=>host.querySelector(".assets-selection").textContent.includes("5件選択"));
    check(card("a").getAttribute("aria-selected")==="true" && card("item-4").getAttribute("aria-selected")==="true","Ctrl+Shift adds a range to the selection");

    const boxScroll=host.querySelector(".assets-scroll"), boxBounds=boxScroll.getBoundingClientRect(), secondBounds=card("b").getBoundingClientRect();
    const pointer=(type,x,y)=>boxScroll.dispatchEvent(new PointerEvent(type,{pointerId:4,button:0,buttons:type==="pointerup"?0:1,bubbles:true,cancelable:true,clientX:x,clientY:y}));
    pointer("pointerdown",boxBounds.left+2,boxBounds.top+2);
    pointer("pointermove",secondBounds.right-2,secondBounds.bottom-2); pointer("pointerup",secondBounds.right-2,secondBounds.bottom-2);
    check(host.querySelectorAll('[aria-selected="true"]').length===2 && card("a").getAttribute("aria-selected")==="true" && card("b").getAttribute("aria-selected")==="true" && host.querySelector(".assets-marquee").hidden,"blank-space drag selects intersecting cards and removes the rectangle");

    card("a").click(); boxScroll.scrollTop=boxScroll.scrollHeight-boxScroll.clientHeight; boxScroll.dispatchEvent(new Event("scroll"));
    await until(()=>last("assets.query").offset>100 && button(".assets-selection","ゴミ箱")); await wait(100);
    const rangeEnd=host.querySelector("[data-asset-id]"), expectedRange=rows.findIndex(row=>row.id===rangeEnd.dataset.assetId)+1;
    rangeEnd.dispatchEvent(new MouseEvent("click",{shiftKey:true,bubbles:true}));
    await until(()=>host.querySelector(".assets-selection").textContent.includes(`${expectedRange}件選択`));
    check(expectedRange>100,"Shift range includes unloaded virtual pages");

    await clickView("最近の素材"); card("b").click();
    const scroll = host.querySelector(".assets-scroll"); scroll.scrollTop=scroll.scrollHeight-scroll.clientHeight;
    scroll.dispatchEvent(new Event("scroll"));
    await until(()=>last("assets.query").offset>0 && host.querySelector(".assets-selection")?.textContent.includes("1件選択"));
    await wait(100);
    const next = host.querySelector("[data-asset-id]");
    check(next && next.dataset.assetId!=="b", "fixture reached another virtual page");
    next.dispatchEvent(new MouseEvent("click",{ctrlKey:true,bubbles:true}));
    button(".assets-selection","ゴミ箱").click(); await wait(60);
    check(last("assets.update").ids.includes("b") && last("assets.update").ids.length===2, "matching off-page selection retained");

    await clickView("最近の素材"); card("b").click(); card("a").dispatchEvent(new MouseEvent("click",{ctrlKey:true,bubbles:true}));
    failMatch=true; button(".assets-sidebar","★ お気に入り").click();
    await until(()=>host.querySelector(".assets-status").textContent.includes("Synthetic query failure")); await wait(40);
    button(".assets-selection","ゴミ箱").click(); await wait(60);
    check(last("assets.update").ids.join()==="a", "failed match cannot keep a hidden mutation target");
    failMatch=false; await clickView("最近の素材");
    a.kind="image"; await provider.refresh(); await until(()=>card("a"));
    card("b").click(); card("a").dispatchEvent(new MouseEvent("click",{ctrlKey:true,bubbles:true}));
    const deletesBefore=calls.filter(call=>call.method==="assets.update").length;
    host.querySelector(".assets-search").dispatchEvent(new KeyboardEvent("keydown",{key:"Delete",bubbles:true,cancelable:true})); await wait(30);
    check(calls.filter(call=>call.method==="assets.update").length===deletesBefore,"Delete in a search field does not trash selected assets");
    const deleteEvent=repeat=>host.querySelector(".assets-scroll").dispatchEvent(new KeyboardEvent("keydown",{key:"Delete",repeat,bubbles:true,cancelable:true}));
    deleteEvent(false); deleteEvent(false); for(let i=0;i<10;i++)deleteEvent(true); await wait(60);
    check(calls.filter(call=>call.method==="assets.update").length===deletesBefore+1 && last("assets.update").operation==="trash" && last("assets.update").ids.length===2,"Delete trashes multiple selected assets once while update is pending");
    await clickView("ゴミ箱"); const trashDeletes=calls.filter(call=>call.method==="assets.update").length; deleteEvent(false); await wait(30);
    check(calls.filter(call=>call.method==="assets.update").length===trashDeletes,"Delete inside trash never permanently deletes originals");
    await clickView("最近の素材");
    const sameCard=card("a"), sameName=sameCard.querySelector(".assets-card-name");
    card("a").click();
    await wait(80); host.querySelector(".assets-scroll").dispatchEvent(new Event("scroll")); await wait(40);
    check(sameCard===card("a") && sameName===card("a").querySelector(".assets-card-name"),"selection resize preserves native double-click targets");
    const renamesBefore=calls.filter(call=>call.method==="assets.update" && call.params.operation==="rename").length;
    sameName.dispatchEvent(new MouseEvent("dblclick",{bubbles:true})); await until(()=>host.querySelector("dialog[open] input"));
    const renameInput=host.querySelector("dialog[open] input");
    check(renameInput.value==="visible.txt" && renameInput.selectionEnd===7 && host.querySelector(".assets-preview").hidden,"filename double-click edits the name and preserves extension selection");
    host.querySelector("dialog[open]").dispatchEvent(new Event("cancel",{cancelable:true})); await wait(30);
    check(calls.filter(call=>call.method==="assets.update" && call.params.operation==="rename").length===renamesBefore,"cancelled rename leaves metadata unchanged");
    card("a").querySelector(".assets-card-name").dispatchEvent(new MouseEvent("dblclick",{bubbles:true})); await until(()=>host.querySelector("dialog[open] input"));
    const saveName=host.querySelector("dialog[open] input"); saveName.value="新しい名前.txt"; saveName.dispatchEvent(new KeyboardEvent("keydown",{key:"Enter",bubbles:true})); await wait(60);
    check(last("assets.update").operation==="rename" && last("assets.update").ids.join()==="a" && last("assets.update").value==="新しい名前.txt","filename rename updates only the clicked asset");
    const space = repeat => host.querySelector(".assets-root").dispatchEvent(new KeyboardEvent("keydown",{key:" ",repeat,bubbles:true,cancelable:true}));
    const beforePreview=calls.filter(call=>call.method==="assets.preview").length;
    space(false); for(let i=0;i<20;i++) space(true); await wait(60);
    check(!host.querySelector(".assets-preview").hidden && calls.filter(call=>call.method==="assets.preview").length===beforePreview+1,"Space autorepeat opens only once and stays open");
    check(!!host.querySelector(".assets-edit-image"),"image preview exposes annotation editor");
    host.querySelector(".assets-edit-image").click(); await wait(30);
    check(last("assets.editImage").id==="a","preview editor uses selected asset ID");
    space(false); for(let i=0;i<20;i++) space(true); await wait(60);
    check(host.querySelector(".assets-preview").hidden,"Space autorepeat closes once without reopening");
    card("a").querySelector("img").dispatchEvent(new MouseEvent("dblclick",{bubbles:true})); await wait(60);
    check(!host.querySelector(".assets-preview").hidden,"double click opens image preview");
    check(getComputedStyle(host.querySelector('.assets-toolbar')).display === 'none',"preview hides search/import toolbar");
    host.querySelector('.assets-media img').dispatchEvent(new MouseEvent('dblclick',{bubbles:true,cancelable:true})); await wait(60);
    check(host.querySelector('.assets-preview').hidden && getComputedStyle(host.querySelector('.assets-toolbar')).display !== 'none',"preview image double-click restores list and toolbar");
    card("a").querySelector("img").dispatchEvent(new MouseEvent("dblclick",{bubbles:true})); await wait(60);
    host.querySelector('[data-action="endPreview"]').click(); await wait(60);
    card("a").dispatchEvent(new DragEvent("dragstart",{bubbles:true,cancelable:true}));
    await until(()=>releaseDrag);
    const trash=host.querySelector(".assets-trash-drop"), bounds=trash.getBoundingClientRect();
    check(!trash.hidden && bounds.width>0 && last("assets.copy").ids.join()==="a","drag reveals a trash target for selected media");
    trash.dispatchEvent(new DragEvent("drop",{bubbles:true,cancelable:true,clientX:bounds.x+bounds.width/2,clientY:bounds.y+bounds.height/2}));
    releaseDrag(); releaseDrag=null; await wait(70);
    check(last("assets.update").ids.join()==="a" && last("assets.update").operation==="trash" && trash.hidden && host.querySelector(".assets-status").textContent.includes("Ctrl+Z"),"drop archives only the dragged IDs, cleans target and shows undo feedback");
    return {ok:true,checks};
  } catch(error) { return {ok:false,checks,error:error.stack}; }
  finally { delayMatch=false; releaseMatch?.(); releaseDrag?.(); provider.dispose(); host.remove(); }
}
