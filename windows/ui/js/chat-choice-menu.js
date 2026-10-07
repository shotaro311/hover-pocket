// Keep choices inside the WebView viewport; native select popups escape the hover region.
export function createChatChoiceMenu(root, changed) {
  const popup = document.createElement("div");
  popup.className = "hp-chat-choice-menu"; popup.hidden = true; popup.setAttribute("role", "listbox");
  root.append(popup);
  let owner = null, choose = null;
  function close(restoreFocus = false) {
    if (!owner) return;
    const previous = owner; owner = null;
    popup.hidden = true; previous.setAttribute("aria-expanded", "false");
    changed(false);
    if (restoreFocus) previous.focus({preventScroll:true});
  }
  function position() {
    if (!owner) return;
    const rect = owner.getBoundingClientRect(), margin = 8;
    const above = rect.top - margin - 4, below = innerHeight - rect.bottom - margin - 4;
    popup.style.width = `${Math.min(300, innerWidth - margin * 2)}px`;
    popup.style.maxHeight = `${Math.max(0, Math.min(260, Math.max(above, below)))}px`;
    popup.style.left = `${Math.max(margin, Math.min(rect.left, innerWidth - popup.offsetWidth - margin))}px`;
    popup.style.top = `${above >= below ? rect.top - popup.offsetHeight - 4 : rect.bottom + 4}px`;
  }
  function update(button, items, selected, select) {
    if (owner !== button) return;
    const focused = popup.contains(document.activeElement) ? document.activeElement.dataset.choiceValue : null;
    choose = select; popup.replaceChildren();
    popup.setAttribute("aria-label", button.getAttribute("aria-label"));
    for (const item of items) {
      const option = document.createElement("button"); option.type = "button";
      option.setAttribute("role", "option"); option.setAttribute("aria-selected", String(item.value === selected));
      option.dataset.choiceValue = item.value; option.textContent = item.label; option.disabled = Boolean(item.disabled);
      option.onclick = () => { const selectChoice = choose; close(true); selectChoice(item.value); };
      popup.append(option);
    }
    position();
    const options = [...popup.querySelectorAll("button:not(:disabled)")];
    (options.find(item => item.dataset.choiceValue === (focused ?? selected)) || options[0])?.focus({preventScroll:true});
  }
  function open(button, items, selected, select) {
    if (owner === button) { close(true); return; }
    const alreadyOpen = Boolean(owner);
    if (owner) owner.setAttribute("aria-expanded", "false");
    owner = button; button.setAttribute("aria-expanded", "true"); popup.hidden = false;
    if (!alreadyOpen) changed(true);
    update(button, items, selected, select);
  }
  const outside = event => { if (owner && !popup.contains(event.target) && !owner.contains(event.target)) close(); };
  const blur = () => close();
  document.addEventListener("pointerdown", outside, true);
  window.addEventListener("blur", blur); window.addEventListener("resize", blur); window.addEventListener("pagehide", blur);
  // Browser mouse focus briefly passes through BODY before reaching the next option.
  popup.addEventListener("focusout", event => {
    if (event.relatedTarget && (popup.contains(event.relatedTarget) || event.relatedTarget === owner)) return;
    setTimeout(() => { if (owner && !popup.contains(document.activeElement) && document.activeElement !== owner) close(); }, 0);
  });
  root.addEventListener("keydown", event => {
    if (!owner) return;
    if (event.key === "Escape") { event.preventDefault(); close(true); return; }
    if (!["ArrowDown", "ArrowUp", "Home", "End"].includes(event.key)) return;
    event.preventDefault();
    const options = [...popup.querySelectorAll("button:not(:disabled)")], index = options.indexOf(document.activeElement);
    const next = event.key === "Home" ? 0 : event.key === "End" ? options.length - 1 : (index + (event.key === "ArrowUp" ? -1 : 1) + options.length) % options.length;
    options[next]?.focus({preventScroll:true});
  });
  return {open, update, close, dispose() { close(); document.removeEventListener("pointerdown", outside, true); window.removeEventListener("blur", blur); window.removeEventListener("resize", blur); window.removeEventListener("pagehide", blur); popup.remove(); }};
}
