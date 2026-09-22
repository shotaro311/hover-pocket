export function renderWeather(root, context) {
  let disposed = false;
  let revision = 0;
  const english = context.state.settings.language === "en";
  const text = (ja, en) => english ? en : ja;
  root.className = "hp-weather";
  root.setAttribute("aria-label", text("天気予報", "Weather forecast"));
  root.innerHTML = `<div class="hp-weather-content"></div><footer class="hp-weather-footer"><span role="status"></span><button type="button" data-retry></button><button type="button" data-credit>Open-Meteo</button></footer>`;
  const content = root.querySelector(".hp-weather-content");
  const status = root.querySelector("[role=status]");
  const retry = root.querySelector("[data-retry]");
  retry.textContent = text("更新", "Refresh");
  retry.onclick = () => void refresh(true);
  root.querySelector("[data-credit]").onclick = () => void context.request("weather.openAttribution").catch(() => {});
  void refresh(false);

  async function refresh(force) {
    const requestRevision = ++revision;
    retry.disabled = true;
    status.textContent = text("天気を取得しています…", "Loading weather…");
    try {
      const state = await context.request("weather.getForecast", { force });
      if (disposed || requestRevision !== revision) return;
      content.replaceChildren();
      const forecast = state.forecast;
      const location = state.location;
      const region = context.state.weatherRegions?.find(item => item.id === location.legacyRegionID);
      const name = location.source === "currentLocation" ? text("現在地", "Current location")
        : region ? text(region.cityJapanese, region.cityEnglish) : location.name;
      if (forecast?.days?.length === 8) {
        const today = document.createElement("div");
        today.className = "hp-weather-today";
        today.append(label(name, "hp-weather-location"), symbol(forecast.currentWeatherCode));
        today.append(label(`${Math.round(forecast.currentTemperature)}${state.temperatureScale === "fahrenheit" ? "℉" : "℃"}`, "hp-weather-temperature"));
        today.append(label(condition(forecast.currentWeatherCode, english).title, "hp-weather-condition"));
        today.append(label(temperatures(forecast.days[0]), "hp-weather-range"));
        today.append(label(`☂ ${forecast.days[0].precipitationProbability}%`, "hp-weather-rain"));
        const week = document.createElement("div");
        week.className = "hp-weather-week";
        for (const [index, day] of forecast.days.slice(1).entries()) {
          const card = document.createElement("div");
          card.className = "hp-weather-day";
          card.style.setProperty("--weather-delay", `${index * 55 + 100}ms`);
          // Forecast dates belong to the selected location, not the computer's time zone.
          const date = new Date(`${day.date}T12:00:00Z`);
          card.append(label(new Intl.DateTimeFormat(english ? "en-US" : "ja-JP", { weekday: "short", timeZone: "UTC" }).format(date)));
          card.append(symbol(day.weatherCode), label(temperatures(day)), label(`${day.precipitationProbability}%`, "hp-weather-rain"));
          week.append(card);
        }
        content.append(today, week);
        status.textContent = state.isStale ? text("保存済み予報を表示中", "Showing saved forecast")
          : state.error === "cache_unavailable" ? text("予報を保存できません", "Forecast could not be saved") : "";
        status.title = new Date(forecast.fetchedAt).toLocaleString(english ? "en-US" : "ja-JP");
      } else {
        content.append(label(name, "hp-weather-location"));
        status.textContent = text("天気を取得できません。再試行してください。", "Weather unavailable. Please retry.");
      }
    } catch {
      if (!disposed && requestRevision === revision)
        status.textContent = text("天気を取得できません。再試行してください。", "Weather unavailable. Please retry.");
    } finally {
      if (!disposed && requestRevision === revision) retry.disabled = false;
    }
  }

  function symbol(code) {
    const value = condition(code, english);
    const node = label(value.symbol, "hp-weather-symbol");
    node.title = value.title;
    node.setAttribute("aria-label", value.title);
    return node;
  }
  return { refresh: () => refresh(false), dispose: () => { disposed = true; revision++; } };
}

function label(value, className = "") {
  const node = document.createElement("span");
  node.className = className;
  node.textContent = value;
  return node;
}

function temperatures(day) {
  return `${Math.round(day.highTemperature)}° / ${Math.round(day.lowTemperature)}°`;
}

export function condition(code, english) {
  const value = code === 0 ? ["☀", "晴れ", "Clear"]
    : [1, 2].includes(code) ? ["🌤", "晴れ時々くもり", "Partly cloudy"]
    : code === 3 ? ["☁", "くもり", "Cloudy"]
    : [45, 48].includes(code) ? ["🌫", "霧", "Fog"]
    : [51, 53, 55].includes(code) ? ["🌦", "霧雨", "Drizzle"]
    : [56, 57, 66, 67].includes(code) ? ["🌧", "凍雨", "Freezing rain"]
    : [61, 63, 65].includes(code) ? ["🌧", "雨", "Rain"]
    : [71, 73, 75, 77, 85, 86].includes(code) ? ["❄", "雪", "Snow"]
    : [80, 81, 82].includes(code) ? ["🌦", "にわか雨", "Showers"]
    : [95, 96, 99].includes(code) ? ["⛈", "雷雨", "Thunderstorm"]
    : ["?", "天気不明", "Unknown"];
  return { symbol: value[0], title: value[english ? 2 : 1] };
}
