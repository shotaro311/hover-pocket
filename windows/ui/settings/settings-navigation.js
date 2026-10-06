export function createSettingsNavigation(request) {
  const categories = [
    ["general", "一般", "General", "◉"], ["appearance", "表示", "Appearance", "▣"],
    ["library", "素材と同期", "Library & Sync", "▧"], ["capture", "撮影", "Capture", "◎"],
    ["ai", "AI", "AI", "✦"], ["advanced", "詳細", "Advanced", "☷"]
  ];
  const paths = {
    general: 'M9 3h6l1 3 3 1 2 5-2 5-3 1-1 3H9l-1-3-3-1-2-5 2-5 3-1z M16 12a4 4 0 1 1-8 0 4 4 0 0 1 8 0',
    appearance: 'M3 4h18v13H3z M8 21h8 M12 17v4',
    library: 'M6 3h15v15H6z M3 6v15h15 M6 15l5-5 4 4 3-3 3 3 M16 7h.01',
    capture: 'M3 7h5l2-3h4l2 3h5v13H3z M16 13a4 4 0 1 1-8 0 4 4 0 0 1 8 0',
    ai: 'M12 3l2.5 6.5L21 12l-6.5 2.5L12 21l-2.5-6.5L3 12l6.5-2.5z',
    advanced: 'M3 6h4 M11 6h10 M3 12h10 M17 12h4 M3 18h4 M11 18h10 M7 4h4v4H7z M13 10h4v4h-4z M7 16h4v4H7z'
  };
  const nav = document.querySelector("[data-settings-nav]");
  const cards = [...document.querySelectorAll("[data-settings-category]")];
  const search = document.querySelector("[data-settings-search]");
  const title = document.querySelector("[data-category-title]");
  const empty = document.querySelector("[data-settings-empty]");
  let category = "general", english = false;
  for (const [id, ja, en, symbol] of categories) {
    const button = document.createElement("button"); button.type = "button"; button.dataset.category = id;
    const icon = document.createElement("span"); const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg"); svg.setAttribute("viewBox", "0 0 24 24"); svg.setAttribute("width", "19"); svg.setAttribute("height", "19");
    const path = document.createElementNS(svg.namespaceURI, "path"); path.setAttribute("d", paths[id]); path.setAttribute("fill", "none"); path.setAttribute("stroke", "currentColor"); path.setAttribute("stroke-width", "1.6"); path.setAttribute("stroke-linejoin", "round"); path.setAttribute("stroke-linecap", "round"); svg.append(path); icon.append(svg); icon.setAttribute("aria-hidden", "true");
    const label = document.createElement("span"); label.textContent = ja; button.append(icon, label);
    button.onclick = () => { category = id; search.value = ""; paint(); document.querySelector(".settings-content").scrollTop = 0; };
    nav.append(button);
  }
  function paint() {
    const query = search.value.trim().toLocaleLowerCase(); let count = 0;
    nav.querySelectorAll("button").forEach((button, index) => {
      button.lastChild.textContent = categories[index][english ? 2 : 1];
      button.setAttribute("aria-current", !query && category === button.dataset.category ? "page" : "false");
    });
    title.textContent = query ? (english ? "Search results" : "検索結果") : categories.find(c => c[0] === category)[english ? 2 : 1];
    for (const card of cards) {
      const label = categories.find(c => c[0] === card.dataset.settingsCategory).slice(1, 3).join(" ");
      card.hidden = query ? !(label + " " + card.textContent).toLocaleLowerCase().includes(query) : card.dataset.settingsCategory !== category;
      if (!card.hidden) count++;
    }
    empty.hidden = count > 0; empty.textContent = english ? "No matching settings." : "一致する設定はありません。";
  }
  search.oninput = paint;
  nav.onkeydown = event => {
    if (!["ArrowDown", "ArrowUp", "Home", "End"].includes(event.key)) return;
    const buttons = [...nav.querySelectorAll("button")], current = buttons.indexOf(document.activeElement);
    const index = event.key === "Home" ? 0 : event.key === "End" ? buttons.length - 1 : (current + (event.key === "ArrowDown" ? 1 : -1) + buttons.length) % buttons.length;
    event.preventDefault(); buttons[index].focus(); buttons[index].click();
  };
  document.querySelector("[data-capture-settings]").onclick = async event => {
    event.currentTarget.disabled = true;
    try { await request("settings.openCapture"); }
    catch { document.querySelector("[data-capture-status]").textContent = english ? "Capture settings are unavailable." : "撮影の設定を開けませんでした。"; }
    finally { document.querySelector("[data-capture-settings]").disabled = false; }
  };
  return { render(language) {
    english = language === "en";
    document.querySelector("[data-settings-label]").textContent = english ? "Settings" : "設定";
    nav.setAttribute("aria-label", english ? "Settings categories" : "設定カテゴリ");
    search.placeholder = english ? "Search settings" : "設定を検索"; search.setAttribute("aria-label", search.placeholder);
    document.querySelectorAll("[data-details-label]").forEach(n => n.textContent = english ? "Learn more" : "詳しく見る");
    document.querySelector("[data-weather-details-label]").textContent = english ? "Weather settings" : "天気の設定";
    document.querySelector("[data-generation-setup-label]").textContent = english ? "Generation setup" : "生成環境の設定";
    document.querySelector("[data-capture-heading]").textContent = english ? "Screenshots & recording" : "スクリーンショットと収録";
    document.querySelector("[data-capture-note]").textContent = english ? "Choose where to save captures and how long to show notifications." : "保存先や撮影後の通知を設定できます。";
    document.querySelector("[data-capture-settings]").textContent = english ? "Open capture settings" : "撮影の設定を開く";
    paint();
  } };
}
