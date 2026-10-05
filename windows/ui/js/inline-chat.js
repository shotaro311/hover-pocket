export function createInlineChat({ container, request, on }) {
  const root = document.createElement("div"); root.className = "hp-chat-lane";
  root.innerHTML = `<div class="hp-chat-thread" hidden><div class="hp-chat-messages" tabindex="0"></div></div>
    <div class="hp-chat-compose"><textarea data-chat-draft rows="1" maxlength="16000" spellcheck="false"></textarea><button type="button" data-chat-send></button></div>
    <div class="hp-chat-tools"><button type="button" data-chat-expand></button><button type="button" data-chat-new>＋</button><select data-chat-history></select><button type="button" data-chat-dictation disabled></button><span class="hp-chat-status" role="status"></span><button type="button" data-chat-login></button><button type="button" data-chat-hide>⌃</button></div>`;
  container.append(root);
  const find = name => root.querySelector(`[data-chat-${name}]`);
  const draft = find("draft"), send = find("send"), expand = find("expand"), history = find("history"), create = find("new"), login = find("login"), hide = find("hide");
  const messages = root.querySelector(".hp-chat-messages"), thread = root.querySelector(".hp-chat-thread"), status = root.querySelector(".hp-chat-status");
  let state = { busy: false, expanded: false, messages: [], history: [], draft: "" }, english = false, composing = false, lastComposition = -Infinity, switching = false, sending = false, initialized = false;
  const views = new Map();
  const text = (ja, en) => english ? en : ja;
  const title = (element, value) => { element.title = value; element.setAttribute("aria-label", value); };
  const fail = () => { status.textContent = text("接続を確認できません。下書きは保持しています。", "Connection unavailable. Your draft is kept."); };
  async function action(method, params) { try { const next = await request(method, params); if (next?.messages) render(next); return next; } catch { fail(); return null; } }
  function draftChanged() { void request("chat.draft", { text: draft.value }).catch(fail); controls(); }
  async function submit() {
    if (composing || switching || sending || state.busy || !draft.value.trim()) return;
    sending = true;
    const value = draft.value; draft.value = ""; controls();
    const accepted = await action("chat.send", { text: value });
    sending = false; controls();
    if (!accepted && !draft.value) { draft.value = value; draftChanged(); }
  }
  draft.addEventListener("input", draftChanged);
  draft.addEventListener("compositionstart", () => { composing = true; });
  draft.addEventListener("compositionend", () => { composing = false; lastComposition = performance.now(); draftChanged(); });
  draft.addEventListener("keydown", event => {
    if (event.key !== "Enter" || event.shiftKey) return;
    if (composing || event.isComposing || event.keyCode === 229 || performance.now() - lastComposition < 120) return;
    event.preventDefault(); if (!event.repeat) void submit();
  });
  root.addEventListener("focusin", () => void request("chat.focus", { focused: true }).catch(fail));
  root.addEventListener("focusout", () => queueMicrotask(() => {
    if (!root.contains(document.activeElement)) void request("chat.focus", { focused: false }).catch(fail);
  }));
  async function hidePanel() {
    try { await request("chat.draft", { text: draft.value }); draft.blur(); await action("chat.hidePanel"); }
    catch { fail(); }
  }
  root.addEventListener("keydown", event => {
    // Keep library Delete/Undo/preview shortcuts out of the composer and transcript.
    event.stopPropagation();
    if (event.key === "Escape" && !composing && !event.isComposing && event.keyCode !== 229) {
      event.preventDefault(); void hidePanel();
    }
  });
  send.onclick = () => void (state.busy ? action("chat.stop") : submit());
  expand.onclick = () => void action("chat.expand", { expanded: !state.expanded });
  async function switchThread(method, params) {
    if (state.busy || switching) return;
    switching = true;
    try { await request("chat.draft", { text: draft.value }); await action(method, params); draft.value = state.draft || ""; }
    catch { fail(); }
    finally { switching = false; controls(); }
  }
  create.onclick = () => void switchThread("chat.new");
  history.onchange = () => { if (history.value) void switchThread("chat.select", { threadId: history.value }); };
  login.onclick = () => void action("chat.login");
  hide.onclick = () => void hidePanel();
  on("chat.stateChanged", render);
  on("chat.focusInput", () => draft.focus({ preventScroll: true }));
  on("panel.closed", () => { draft.blur(); });
  on("panel.opened", () => void action("chat.getState"));
  void action("chat.getState");

  function controls() {
    send.textContent = state.busy ? "■" : "↑";
    title(send, text(state.busy ? "応答を停止" : "送信", state.busy ? "Stop response" : "Send"));
    send.disabled = !state.busy && (!draft.value.trim() || switching || sending);
    create.disabled = history.disabled = login.disabled = state.busy || switching;
  }
  function render(next) {
    if (!next) return;
    const previous = state;
    state = next;
    if (!initialized || previous.draftVersion !== next.draftVersion || (!root.contains(document.activeElement) && !composing) ||
        (previous.busy && !next.busy && !draft.value)) draft.value = next.draft || "";
    initialized = true;
    root.dataset.expanded = String(state.expanded);
    document.documentElement.style.setProperty("--hp-chat-height", `${state.expanded ? 242 : 82}px`);
    thread.hidden = !state.expanded;
    expand.textContent = text(state.expanded ? "会話をたたむ" : "会話", state.expanded ? "Collapse" : "Chat");
    expand.setAttribute("aria-expanded", String(state.expanded));
    title(expand, text("会話の表示を切り替える", "Toggle conversation"));
    title(create, text("新しい会話", "New conversation")); title(history, text("会話履歴", "Conversation history"));
    title(hide, text("パネルを収納（会話を保持）", "Hide panel and keep conversation"));
    find("dictation").textContent = text("音声入力", "Dictation");
    title(find("dictation"), text("音声入力のみの接続は現在のChatGPTログインでは利用できません。音声会話は波形から開始できます。", "Dictation-only is unavailable with the current ChatGPT sign-in. Use the waveform for voice conversation."));
    title(messages, text("返信（選択してコピーできます）", "Messages — select text to copy"));
    title(draft, text("メッセージを入力", "Message"));
    draft.placeholder = text("メッセージを入力…", "Write a message…");
    draft.title = text("Enterで送信 · Shift+Enterで改行", "Enter to send · Shift+Enter for a new line");
    const atBottom = messages.scrollHeight - messages.scrollTop - messages.clientHeight < 36;
    const ids = new Set(state.messages.map(message => message.id));
    for (const [id, element] of views) if (!ids.has(id)) { element.remove(); views.delete(id); }
    for (const message of state.messages) {
      let element = views.get(message.id);
      if (!element) {
        element = document.createElement("p"); element.className = "hp-chat-message"; element.dataset.role = message.role;
        const label = document.createElement("small"), body = document.createElement("span"); element.append(label, body);
        messages.append(element); views.set(message.id, element);
      }
      element.firstChild.textContent = message.role === "user" ? text("あなた", "You") : "Codex";
      if (element.lastChild.textContent !== message.text) element.lastChild.textContent = message.text;
    }
    if (atBottom) messages.scrollTop = messages.scrollHeight;
    const historyKey = JSON.stringify([english, state.history.map(item => [item.threadId, item.createdAt])]);
    if (history.dataset.key !== historyKey) {
      history.replaceChildren(new Option(text("履歴", "History"), ""));
      for (const item of state.history) history.add(new Option(new Date(item.createdAt).toLocaleString(english ? "en-US" : "ja-JP"), item.threadId));
      history.dataset.key = historyKey;
    }
    history.value = state.threadId || "";
    login.textContent = text("ログイン", "Sign in"); login.hidden = state.errorCode !== "chat_sign_in_required";
    status.textContent = state.errorCode === "chat_sign_in_required" ? text("ログインが必要です", "Sign in to send")
      : state.errorCode === "chat_stopped" ? text("停止しました", "Stopped")
      : state.errorCode === "chat_tools_changed_start_new" ? text("新しい会話を開始してください", "Start a new conversation")
      : state.errorCode ? text("応答を確認できませんでした", "Response could not be confirmed")
      : state.busy ? text("返答中…", "Responding…") : text("Enterで送信", "Enter to send");
    status.title = state.errorCode ? text("実行済みの操作は保持されます。途中の返信を確認してください。", "Completed actions remain. Check the partial reply.") : status.textContent;
    controls();
  }
  return { updateLanguage(value) { english = value === "en"; render(state); }, focus() { draft.focus({ preventScroll: true }); } };
}
