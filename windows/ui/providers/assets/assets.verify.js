import { renderAssetsProvider } from "./assets.js";

export async function verifyAssetSelection() {
  const host = document.createElement("div");
  host.style.cssText = "position:fixed;inset:0;width:900px;height:600px;z-index:99999;background:#111";
  document.body.append(host);
  const a = { id:"a", name:"visible.txt", extension:"txt", kind:"other", sizeBytes:5, createdAt:"2026-10-03T00:00:00Z", favorite:true, folderIds:["folder-a"], tagIds:[] };
  const rows = [a, { ...a, id:"b", name:"hidden.txt", favorite:false }, ...Array.from({length:218}, (_,i) => ({...a,id:`item-${i}`,favorite:false}))];
  const calls = [], checks = [];
  let releaseMatch = null, delayMatch = false, failMatch = false, releaseDrag = null;
  const matches = (row, query) => query.view !== "favorites" || row.favorite;
  const request = async (method, params) => {
    calls.push({method,params:structuredClone(params)});
    if (method === "assets.query") {
      const items = rows.filter(row => matches(row,params));
      return {items:items.slice(params.offset,params.offset+params.limit),total:items.length,
        folders:[{id:"folder-a",name:"Fixture A",parentId:null},{id:"folder-b",name:"Fixture B",parentId:null}],tags:[],searches:[]};
    }
    if (method === "assets.matches") {
      if (delayMatch) await new Promise(resolve => { releaseMatch = resolve; });
      if (failMatch) throw Error("Synthetic query failure");
      return {matches:matches(rows.find(row => row.id === params.id),params.query)};
    }
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
    button(".assets-sidebar","Fixture A").click(); await wait(60);
    button(".assets-toolbar","撮影・収録").click();
    check(last("assets.capture").folderId === "folder-a", "single folder capture handoff");
    button(".assets-sidebar","Fixture B").dispatchEvent(new MouseEvent("click",{ctrlKey:true,bubbles:true})); await wait(60);
    button(".assets-toolbar","撮影・収録").click();
    check(last("assets.capture").folderId === null, "multiple folders do not choose an arbitrary capture target");
    await clickView("最近の素材"); button(".assets-toolbar","撮影・収録").click();
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
    card("a").click();
    const space = repeat => host.querySelector(".assets-root").dispatchEvent(new KeyboardEvent("keydown",{key:" ",repeat,bubbles:true,cancelable:true}));
    const beforePreview=calls.filter(call=>call.method==="assets.preview").length;
    space(false); for(let i=0;i<20;i++) space(true); await wait(60);
    check(!host.querySelector(".assets-preview").hidden && calls.filter(call=>call.method==="assets.preview").length===beforePreview+1,"Space autorepeat opens only once and stays open");
    check(!!host.querySelector(".assets-edit-image"),"image preview exposes annotation editor");
    host.querySelector(".assets-edit-image").click(); await wait(30);
    check(last("assets.editImage").id==="a","preview editor uses selected asset ID");
    space(false); for(let i=0;i<20;i++) space(true); await wait(60);
    check(host.querySelector(".assets-preview").hidden,"Space autorepeat closes once without reopening");
    card("a").dispatchEvent(new MouseEvent("dblclick",{bubbles:true})); await wait(60);
    check(!host.querySelector(".assets-preview").hidden,"double click opens image preview");
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
