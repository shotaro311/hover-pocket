import { createChatChoiceMenu } from "./chat-choice-menu.js";

const paths = {collapse:'m6 15 6-6 6 6',expand:'m6 9 6 6 6-6',sidebar:'M3 4h18v16H3zM9 4v16',new:'M12 5v14M5 12h14',send:'m6 11 6-6 6 6M12 5v15',stop:'M6 6h12v12H6z',voice:'M4 9v6M8 5v14M12 8v8M16 4v16M20 9v6',mic:'M9 6a3 3 0 0 1 6 0v6a3 3 0 0 1-6 0zM5 10v2a7 7 0 0 0 14 0v-2M12 19v3',muted:'m3 3 18 18M9 9v3a3 3 0 0 0 5 2M9 5a3 3 0 0 1 6 0v6M5 10v2a7 7 0 0 0 12 5M19 10v2M12 19v3'};
export const chatIcon = name => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="${paths[name]}"/></svg>`;
export function createInlineChat({ container, request, on, toggleVoice, toggleMute }) {
  const root = document.createElement("div"); root.className = "hp-chat-lane";
  root.innerHTML = `<header class="hp-chat-header"><button data-chat-sidebar>${chatIcon("sidebar")}</button><button data-chat-new>${chatIcon("new")}</button><span class="hp-chat-status" role="status"></span><button data-chat-login hidden></button><button data-chat-fold aria-expanded="true"></button></header>
    <div class="hp-chat-body" hidden><aside class="hp-chat-sidebar" hidden><div class="hp-chat-history"></div></aside><div class="hp-chat-thread"><div class="hp-chat-messages" tabindex="0"></div><div class="hp-chat-progress" role="status" hidden><span class="hp-chat-spinner"></span><span data-chat-progress></span></div></div></div>
    <div class="hp-chat-compose"><textarea data-chat-draft rows="1" maxlength="16000" spellcheck="false"></textarea><div class="hp-chat-tools"><button type="button" data-chat-model aria-haspopup="listbox" aria-expanded="false"></button><button type="button" data-chat-effort aria-haspopup="listbox" aria-expanded="false"></button><span class="hp-chat-spacer"></span><button data-chat-dictation disabled>${chatIcon("mic")}</button><button data-chat-voice>${chatIcon("voice")}</button><button data-chat-mute hidden>${chatIcon("mic")}</button><button data-chat-send>${chatIcon("send")}</button></div></div><div class="hp-chat-unavailable" role="status" hidden></div>`;
  container.append(root);
  const recover=document.createElement("button");recover.dataset.chatRecover="";recover.hidden=true;root.querySelector(".hp-chat-header").insertBefore(recover,root.querySelector("[data-chat-fold]"));
  const empty=document.createElement("p");empty.className="hp-chat-empty";root.querySelector(".hp-chat-messages").append(empty);
  const find = name => root.querySelector(`[data-chat-${name}]`);
  const draft=find("draft"),send=find("send"),create=find("new"),login=find("login"),model=find("model"),effort=find("effort");
  const history=root.querySelector(".hp-chat-history"),messages=root.querySelector(".hp-chat-messages"),status=root.querySelector(".hp-chat-status"),progress=root.querySelector(".hp-chat-progress"),unavailable=root.querySelector(".hp-chat-unavailable");
  let state={busy:false,expanded:false,messages:[],history:[],draft:"",models:[]},voice={},english=false,composing=false,lastComposition=-Infinity,switching=false,sending=false,initialized=false,catalogPending=false;
  const menu=createChatChoiceMenu(root,open=>void request("chat.menu",{open}).catch(fail));
  const views=new Map(),text=(ja,en)=>english?en:ja;
  const title=(element,value)=>{element.title=value;element.setAttribute("aria-label",value);};
  const fail=()=>{status.textContent=text("接続を確認できません。下書きは保持しています。","Connection unavailable. Your draft is kept.");if(state.folded&&state.busy)status.textContent=text(state.phase==="responding"?"返答中…":"考え中…",state.phase==="responding"?"Responding…":"Thinking…");
    status.title=status.textContent;recover.textContent=text("設定を開く","Settings");recover.hidden=false;};
  async function action(method,params){try{const next=await request(method,params);if(next?.messages)render(next);return next;}catch{fail();return null;}}
  function draftChanged(){void request("chat.draft",{text:draft.value}).catch(fail);controls();}
  async function submit(){
    if(composing||switching||sending||state.busy||!draft.value.trim())return;
    sending=true;const value=draft.value;draft.value="";controls();
    const accepted=await action("chat.send",{text:value});sending=false;controls();
    if(!accepted&&!draft.value){draft.value=value;draftChanged();}
  }
  draft.addEventListener("input",draftChanged);
  draft.addEventListener("compositionstart",()=>{composing=true;});
  draft.addEventListener("compositionend",()=>{composing=false;lastComposition=performance.now();draftChanged();});
  draft.addEventListener("keydown",event=>{
    if(event.key!=="Enter"||event.shiftKey)return;
    if(composing||event.isComposing||event.keyCode===229||performance.now()-lastComposition<120)return;
    event.preventDefault();if(!event.repeat)void submit();
  });
  root.addEventListener("focusin",()=>void request("chat.focus",{focused:true}).catch(fail));
  root.addEventListener("focusout",()=>queueMicrotask(()=>{if(!root.contains(document.activeElement))void request("chat.focus",{focused:false}).catch(fail);}));
  root.addEventListener("keydown",event=>{event.stopPropagation();if(event.key==="Escape"&&!event.defaultPrevented&&!composing&&!event.isComposing&&event.keyCode!==229){event.preventDefault();draft.blur();void action("chat.hidePanel");}});
  find("fold").onclick=()=>{menu.close();draft.blur();void action("chat.fold",{folded:!state.folded});};
  send.onclick=()=>void(state.busy?action("chat.stop"):submit());
  find("sidebar").onclick=()=>{const pane=root.querySelector(".hp-chat-sidebar");pane.hidden=!pane.hidden;find("sidebar").setAttribute("aria-expanded",String(!pane.hidden));if(state.folded)void action("chat.fold",{folded:false});if(!state.expanded)void action("chat.expand",{expanded:true});};
  async function switchThread(method,params){if(state.busy||switching)return;switching=true;try{await request("chat.draft",{text:draft.value});await action(method,params);draft.value=state.draft||"";}catch{fail();}finally{switching=false;controls();}}
  create.onclick=()=>void switchThread("chat.new");login.onclick=()=>void action("chat.login");find("voice").onclick=()=>toggleVoice?.();find("mute").onclick=()=>toggleMute?.();
  recover.onclick=()=>void action("settings.open");
  async function catalog(){if(catalogPending||state.busy||state.models?.length)return;catalogPending=true;controls();await action("chat.models");catalogPending=false;controls();}
  const effortNames={none:"なし",minimal:"最小",low:"低",medium:"標準",high:"高",xhigh:"より高",max:"最大",ultra:"最高"};
  const modelItems=()=>[{value:"",label:text("モデル: 自動","Model: Default")},...(state.models||[]).map(item=>({value:item.model,label:item.displayName||item.model})),...(catalogPending?[{value:"loading",label:text("モデルを確認中…","Loading models…"),disabled:true}]:[])];
  const effortItems=()=>{const values=state.models?.find(item=>item.model===state.model)?.efforts||[];return values.length?values.map(value=>({value,label:text(`推論: ${effortNames[value]||value}`,`Reasoning: ${value}`)})):[{value:"",label:text("推論: 自動","Reasoning: Default")}];};
  const chooseModel=value=>{const choice=state.models?.find(item=>item.model===value);void action("chat.configure",{model:choice?.model||"",effort:choice?.defaultReasoningEffort||""});};
  const chooseEffort=value=>void action("chat.configure",{model:state.model||"",effort:value});
  const refreshMenu=()=>{menu.update(model,modelItems(),state.model||"",chooseModel);menu.update(effort,effortItems(),state.effort||"",chooseEffort);};
  model.onclick=()=>{void catalog().then(refreshMenu);menu.open(model,modelItems(),state.model||"",chooseModel);};
  effort.onclick=()=>menu.open(effort,effortItems(),state.effort||"",chooseEffort);
  for(const button of [model,effort])button.addEventListener("keydown",event=>{if((event.key==="ArrowDown"||event.key==="ArrowUp")&&!button.disabled){event.preventDefault();button.click();}});
  on("chat.stateChanged",render);on("chat.focusInput",()=>draft.focus({preventScroll:true}));on("chat.toggleVoice",()=>toggleVoice?.());on("panel.closed",()=>{menu.close();draft.blur();});on("panel.opened",()=>void action("chat.getState"));void action("chat.getState");
  function controls(){
    send.innerHTML=chatIcon(state.busy?"stop":"send");title(send,text(state.busy?"応答を停止":"送信",state.busy?"Stop response":"Send"));send.disabled=!state.busy&&(!draft.value.trim()||switching||sending);
    if(state.busy||switching)menu.close();
    create.disabled=login.disabled=model.disabled=effort.disabled=state.busy||switching;effort.disabled||=!state.models?.length;
    recover.disabled=state.busy||switching;model.disabled||=catalogPending;model.setAttribute("aria-busy",String(catalogPending));
    title(model,catalogPending?text("モデルを確認中…","Loading models…"):text("モデルを選択","Choose model"));
    for(const button of history.querySelectorAll("button"))button.disabled=state.busy||switching;
  }
  function renderVoice(){
    const active=Boolean(voice.realtimeAttached||voice.starting),ready=voice.availability==="ready",start=find("voice"),mute=find("mute");
    start.innerHTML=chatIcon(active?"stop":"voice");start.disabled=voice.sessionStatus==="stopping"||(!active&&!ready);title(start,text(active?"音声会話を終了":"音声会話を開始",active?"End voice conversation":"Start voice conversation"));
    mute.hidden=!voice.realtimeAttached;mute.innerHTML=chatIcon(voice.muted?"muted":"mic");title(mute,text(voice.muted?"マイクのミュートを解除":"マイクをミュート",voice.muted?"Unmute microphone":"Mute microphone"));
    title(find("dictation"),text("現在のChatGPT接続では音声文字起こしを利用できません。","Dictation is unavailable with the current ChatGPT connection."));
    unavailable.textContent=!ready&&!active?text(`音声会話: ${voice.reason||"設定で音声会話を有効にしてください。"}`,`Voice: ${voice.reason||"Enable voice conversation in Settings."}`):"";unavailable.hidden=!unavailable.textContent;
    unavailable.title=unavailable.textContent;
  }
  function render(next){
    if(!next)return;const previous=state;state=next;
    if(!initialized||previous.draftVersion!==next.draftVersion||(!root.contains(document.activeElement)&&!composing)||(previous.busy&&!next.busy&&!draft.value))draft.value=next.draft||"";initialized=true;
    root.dataset.folded=String(Boolean(state.folded));
    const fold=find("fold");fold.innerHTML=chatIcon(state.folded?"expand":"collapse");fold.setAttribute("aria-expanded",String(!state.folded));title(fold,text(state.folded?"チャットを展開":"チャットを折りたたむ",state.folded?"Expand chat":"Collapse chat"));
    if(state.folded)menu.close();
    root.dataset.expanded=String(state.expanded);root.dataset.busy=String(Boolean(state.busy));document.documentElement.style.setProperty("--hp-chat-height",`${state.folded?42:state.expanded?300:126}px`);root.querySelector(".hp-chat-body").hidden=state.folded||!state.expanded;
    title(find("sidebar"),text("チャット履歴","Chat history"));title(create,text("新規チャット","New chat"));title(messages,text("返信（選択してコピーできます）","Messages — select text to copy"));title(draft,text("メッセージを入力","Message"));draft.placeholder=text("メッセージを入力…","Write a message…");draft.title=text("Enterで送信 · Shift+Enterで改行","Enter to send · Shift+Enter for a new line");
    const atBottom=messages.scrollHeight-messages.scrollTop-messages.clientHeight<36,ids=new Set(state.messages.map(message=>message.id));
    for(const[id,element]of views)if(!ids.has(id)){element.remove();views.delete(id);}
    for(const message of state.messages){let element=views.get(message.id);if(!element){element=document.createElement("p");element.className="hp-chat-message";element.dataset.role=message.role;element.append(document.createElement("small"),document.createElement("span"));messages.append(element);views.set(message.id,element);}element.firstChild.textContent=message.role==="user"?text("あなた","You"):"Codex";if(element.lastChild.textContent!==message.text)element.lastChild.textContent=message.text;}
    if(atBottom)messages.scrollTop=messages.scrollHeight;
    empty.hidden=state.messages.length>0||state.busy;empty.textContent=text("質問や素材の検索・整理を、ここから依頼できます。","Ask a question or find and organize your assets here.");
    const historyKey=JSON.stringify([english,state.threadId,state.history]);
    if(history.dataset.key!==historyKey){history.replaceChildren();for(const item of state.history){const button=document.createElement("button");button.textContent=new Date(item.createdAt).toLocaleString(english?"en-US":"ja-JP");button.title=button.textContent;button.setAttribute("aria-current",String(item.threadId===state.threadId));button.onclick=()=>void switchThread("chat.select",{threadId:item.threadId});history.append(button);}if(!history.childElementCount)history.textContent=text("会話履歴はまだありません","No conversations yet");history.dataset.key=historyKey;}
    const key=JSON.stringify([english,state.model,state.effort,state.models]);
    if(model.dataset.key!==key){model.textContent=modelItems().find(item=>item.value===(state.model||""))?.label||state.model||text("モデル: 自動","Model: Default");effort.textContent=effortItems().find(item=>item.value===(state.effort||""))?.label||text("推論: 自動","Reasoning: Default");model.dataset.key=key;refreshMenu();}
    title(model,text("モデルを選択","Choose model"));title(effort,text("推論の強さ","Reasoning effort"));login.textContent=text("ログイン","Sign in");login.hidden=state.errorCode!=="chat_sign_in_required";
    status.textContent=state.errorCode==="chat_sign_in_required"?text("ログインが必要です","Sign in to send"):state.errorCode==="chat_stopped"?text("停止しました","Stopped"):state.errorCode==="chat_tools_changed_start_new"?text("新しい会話を開始してください","Start a new conversation"):state.errorCode==="chat_models_unavailable"?text("モデルを取得できません。接続を確認してください。","Models unavailable. Check your connection."):state.errorCode==="chat_history_failed"?text("履歴を読み込めませんでした。会話は保持しています。","Could not load history. Conversations are kept."):state.errorCode?text("応答を確認できません。送信前に会話を確認してください。","Response could not be confirmed. Check the conversation before sending again."):"";
    status.title=status.textContent;recover.hidden=!state.errorCode||state.errorCode==="chat_stopped"||state.errorCode==="chat_tools_changed_start_new";recover.textContent=text("設定を開く","Settings");title(recover,text("AIの接続設定を確認","Check AI connection settings"));
    progress.hidden=!state.busy;find("progress").textContent=text(state.phase==="responding"?"返答中…":"考え中…",state.phase==="responding"?"Responding…":"Thinking…");controls();renderVoice();
  }
  return{dispose(){menu.dispose();},updateLanguage(value){english=value==="en";render(state);},updateVoice(lane,reason){voice={...lane,reason};renderVoice();},focus(){draft.focus({preventScroll:true});}};
}
