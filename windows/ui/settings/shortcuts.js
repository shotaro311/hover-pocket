export function createShortcutSettings(request) {
  const root = document.querySelector("[data-shortcuts]"), status = document.querySelector("[data-shortcuts-status]"), save = document.querySelector("[data-shortcuts-save]");
  const labels = {panel:["パネルを開く・閉じる","Toggle panel"],chat:["チャット入力へ移動","Focus chat"],voice:["音声会話を開始・終了","Toggle voice conversation"],library:["素材ライブラリを開く","Open library"],settings:["設定を開く","Open Settings"],screenshot:["スクリーンショット","Screenshot"],recording:["画面収録を開始・停止","Toggle screen recording"],regionRecording:["範囲収録を開始・停止","Toggle region recording"]};
  let loading=false,initialized=false,english=false;
  save.onclick=async()=>{
    save.disabled=true; status.textContent="";
    try { const shortcuts={}; for(const input of root.querySelectorAll("input")) shortcuts[input.dataset.shortcut]=input.value.trim(); await request("settings.setShortcuts",{shortcuts});status.textContent=english?"Saved. Shortcuts are active.":"保存しました。ショートカットは有効です。"; }
    catch(error){status.textContent=error.message||String(error);}
    finally{save.disabled=false;}
  };
  return { async render(language){
    english=language==="en"; document.querySelector("[data-shortcuts-help]").textContent=english?"Click a field and press a key combination with Ctrl or Alt. Delete disables the action.":"欄をクリックしてCtrlまたはAltを含むキーを押してください。Deleteで無効にできます。"; save.textContent=english?"Save":"保存";document.querySelector("[data-shortcuts-heading]").textContent=english?"Keyboard shortcuts":"ショートカットキー";
    if(!initialized&&!loading){loading=true;try{const bindings=await request("settings.getShortcuts");for(const[key,value]of Object.entries(bindings)){const row=document.createElement("label");row.className="toggle-row";const name=document.createElement("span");name.dataset.shortcutLabel=key;const input=document.createElement("input");input.type="text";input.dataset.shortcut=key;input.value=value;input.style.width="170px";input.placeholder=english?"Click and press keys":"クリックしてキーを押す";
      input.addEventListener("focus",()=>void request("settings.captureShortcut",{active:true}).catch(error=>status.textContent=error.message));
      input.addEventListener("blur",()=>void request("settings.captureShortcut",{active:false}).catch(error=>status.textContent=error.message));
      input.addEventListener("keydown",event=>{if(event.key==="Tab")return;if(event.key==="Backspace"||event.key==="Delete"){event.preventDefault();input.value="";return;}if(["Control","Shift","Alt","Meta"].includes(event.key))return;event.preventDefault();if(!event.ctrlKey&&!event.altKey){status.textContent=english?"Combine Ctrl or Alt with a key.":"CtrlまたはAltとキーを組み合わせてください。";return;}const modifiers=[event.ctrlKey?"Ctrl":null,event.altKey?"Alt":null,event.shiftKey?"Shift":null,event.metaKey?"Win":null].filter(Boolean);const key=event.code.startsWith("Key")?event.code.slice(3):event.code.startsWith("Digit")?"D"+event.code.slice(5):event.key===" "?"Space":event.key;input.value=[...modifiers,key].join("+");status.textContent="";});row.append(name,input);root.append(row);}initialized=true;}catch(error){status.textContent=error.message||String(error);}finally{loading=false;}}
    for(const label of root.querySelectorAll("[data-shortcut-label]")){const value=labels[label.dataset.shortcutLabel];label.textContent=value?.[english?1:0]||label.dataset.shortcutLabel;}
  }};
}
