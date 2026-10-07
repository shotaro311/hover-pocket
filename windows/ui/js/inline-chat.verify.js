import { createInlineChat } from "./inline-chat.js";

export async function verifyChatUx() {
  const host = document.createElement("div"); host.style.cssText = "position:fixed;inset:0;width:520px;height:300px;background:#111;z-index:99999"; document.body.append(host);
  const calls = [], listeners = new Map();
  let rejectState = false;
  const state = {busy:false,expanded:true,messages:[],history:[],draft:"残しておく下書き",models:[],errorCode:"chat_disconnected"};
  const chat = createInlineChat({container:host,on:(name,handler)=>listeners.set(name,handler),request:async(method,params)=>{
    calls.push({method,params});
    if(method === "chat.getState" && rejectState) throw Error("Synthetic connection failure");
    return method.startsWith("chat.") ? state : {opened:true};
  }});
  const wait = () => new Promise(resolve=>setTimeout(resolve,30));
  const check = (condition,name)=>{if(!condition)throw Error(name);};
  try {
    await wait();
    const recover = host.querySelector("[data-chat-recover]"), input = host.querySelector("[data-chat-draft]");
    check(!recover.hidden && host.querySelector(".hp-chat-status").title.includes("会話を確認"),"uncertain response explains checking the conversation before sending again");
    recover.click(); await wait();
    check(calls.some(call=>call.method === "settings.open") && !calls.some(call=>call.method === "chat.send"),"recovery opens settings without resending a request");
    check(input.value === state.draft,"recovery preserves the draft");
    rejectState = true; listeners.get("panel.opened")(); await wait();
    check(!recover.hidden && recover.textContent.length>0 && input.value === state.draft,"bridge failure retains a readable recovery action and draft");
    rejectState = false; state.errorCode = null; listeners.get("chat.stateChanged")(state);
    check(recover.hidden && !host.querySelector(".hp-chat-empty").hidden,"ready empty chat explains available actions without an error");
    state.models=[{model:"fixture",displayName:"Test model",defaultReasoningEffort:"medium",efforts:["medium","high"]}];state.model="fixture";state.effort="medium";listeners.get("chat.stateChanged")(state);
    check(host.querySelector("[data-chat-effort]").textContent === "推論: 標準","reasoning labels are readable and preserve protocol values");
    const effort=host.querySelector("[data-chat-effort]"); effort.click(); await wait();
    check(calls.some(call=>call.method==="chat.menu" && call.params.open),"opening choices reports menu interaction, not input focus");
    const popup=host.querySelector(".hp-chat-choice-menu"), rect=popup.getBoundingClientRect();
    check(rect.left>=0 && rect.top>=0 && rect.right<=innerWidth && rect.bottom<=innerHeight,"choices stay inside the smallest viewport");
    document.activeElement.dispatchEvent(new KeyboardEvent("keydown",{key:"End",bubbles:true,cancelable:true}));
    check(document.activeElement.dataset.choiceValue==="high","keyboard navigation reaches the last reasoning choice");
    document.activeElement.click(); await wait();
    check(popup.hidden && calls.some(call=>call.method==="chat.configure" && call.params.effort==="high"),"keyboard choice preserves the reasoning protocol value");
    const holds=calls.filter(call=>call.method==="chat.menu");check(holds.at(-1).params.open===false,"selection releases interaction even while the button remains focused");
    chat.updateLanguage("en");check(host.querySelector(".hp-chat-empty").textContent.includes("organize"),"empty chat guidance supports English");
    return {ok:true};
  } catch(error) { return {ok:false,error:error.message}; }
  finally { chat.dispose(); host.remove(); }
}
