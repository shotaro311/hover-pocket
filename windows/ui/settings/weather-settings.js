export function createWeatherSettings(root, request, onState) {
  let state;
  let busy = false;
  let searchRevision = 0;
  root.innerHTML = `<h2 data-title></h2><p data-location></p><div class="weather-settings-row"><input data-query type="search" maxlength="120"><button type="button" data-search></button><button type="button" data-current></button></div><p class="settings-note" data-privacy></p><div class="weather-results" data-results></div><label class="select-row"><span data-region-label></span><select data-regions></select></label><label class="select-row settings-spaced-row"><span data-unit-label></span><select data-unit></select></label><p class="settings-status" role="status"></p>`;
  const find = name => root.querySelector(`[data-${name}]`);
  const status = root.querySelector("[role=status]");
  const text = (ja, en) => state?.settings.language === "en" ? en : ja;
  find("search").onclick = search;
  find("query").onkeydown = event => { if (event.key === "Enter") { event.preventDefault(); void search(); } };
  find("current").onclick = () => act("weather.useCurrentLocation");
  find("regions").onchange = () => {
    const region = state.weatherRegions.find(item => item.id === find("regions").value);
    if (region) void act("weather.setLocation", { location: region.location });
  };
  find("unit").onchange = () => act("weather.setUnit", { unit: find("unit").value });

  async function act(method, params) {
    if (busy) return;
    setBusy(true);
    status.textContent = text("処理中…", "Working…");
    try {
      onState(await request(method, params));
      status.textContent = text("保存済み", "Saved");
    } catch {
      status.textContent = method === "weather.useCurrentLocation"
        ? text("現在地を取得できません。Windowsの位置情報設定を確認するか、都市・都道府県を選択してください。", "Location unavailable. Check Windows location settings or select a city or prefecture.")
        : text("変更を保存できません。再試行してください。", "Could not save changes. Please retry.");
      render(state);
    } finally { setBusy(false); }
  }

  async function search() {
    if (busy) return;
    const query = find("query").value.trim();
    if (query.length < 2) { status.textContent = text("2文字以上で検索してください。", "Enter at least 2 characters."); return; }
    const revision = ++searchRevision;
    setBusy(true);
    find("results").replaceChildren();
    status.textContent = text("検索中…", "Searching…");
    try {
      const locations = await request("weather.search", { query });
      if (revision !== searchRevision) return;
      for (const location of locations) {
        const button = document.createElement("button");
        button.type = "button";
        button.textContent = [location.name, location.administrativeArea, location.country].filter(Boolean).join(" · ");
        button.onclick = () => act("weather.setLocation", { location });
        find("results").append(button);
      }
      status.textContent = locations.length ? text("表示する地点を選んでください。", "Select a location.") : text("該当する地点がありません。", "No matching location.");
    } catch {
      status.textContent = text("検索できません。通信を確認して再試行してください。", "Search unavailable. Check your connection and retry.");
    } finally { if (revision === searchRevision) setBusy(false); }
  }

  function setBusy(value) {
    busy = value;
    root.querySelectorAll("button, input, select").forEach(node => { node.disabled = value; });
  }

  function render(nextState) {
    state = nextState;
    find("title").textContent = text("カレンダーの天気", "Calendar weather");
    const location = state.settings.weatherLocation;
    const region = state.weatherRegions?.find(item => item.id === location?.legacyRegionID);
    find("location").textContent = location?.source === "currentLocation" ? text("現在地", "Current location")
      : region ? text(`${region.japaneseName} · ${region.cityJapanese}`, `${region.englishName} · ${region.cityEnglish}`)
      : [location?.name, location?.country].filter(Boolean).join(" · ");
    find("query").placeholder = text("都市名・郵便番号（世界対応）", "City or postal code (worldwide)");
    find("query").setAttribute("aria-label", find("query").placeholder);
    find("search").textContent = text("検索", "Search");
    find("current").textContent = text("現在地を使用", "Use current location");
    find("privacy").textContent = text("現在地はボタンを押した時だけ取得します。選択地点の座標をOpen-Meteoへ送信して予報を取得します。", "Location is requested only when you press the button. The selected coordinates are sent to Open-Meteo for forecasts.");
    find("region-label").textContent = text("都道府県から選択", "Japanese prefecture");
    fillOptions(find("regions"), [{ id: "", title: text("選択してください", "Choose a prefecture") }, ...(state.weatherRegions ?? []).map(item => ({ id: item.id, title: text(item.japaneseName, item.englishName) }))], location?.legacyRegionID ?? "");
    find("unit-label").textContent = text("温度単位", "Temperature unit");
    fillOptions(find("unit"), [{ id: "automatic", title: text("自動", "Auto") }, { id: "celsius", title: "℃" }, { id: "fahrenheit", title: "℉" }], state.settings.weatherTemperatureUnit);
    setBusy(busy);
  }
  return { render };
}

function fillOptions(select, values, selected) {
  select.replaceChildren(...values.map(value => {
    const option = document.createElement("option");
    option.value = value.id;
    option.textContent = value.title;
    return option;
  }));
  select.value = selected;
}
