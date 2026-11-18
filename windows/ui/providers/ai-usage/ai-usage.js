import { on } from "../../js/bridge.js";

const SERVICE_MARKS = { codex: "Cx", claude: "Cl", gemini: "Ge", muse: "Mu" };

/**
 * Lists each AI service's usage windows (five-hour, weekly, model-scoped weekly) as bars.
 * Data comes from C# through `aiUsage.getState` and `aiUsage.changed`; sign-in lives in Settings.
 * @param {{ container: HTMLElement, state: any, request: (method: string, params?: any) => Promise<any> }} context
 */
export function renderAiUsageProvider({ container, state, request }) {
  const english = state?.settings?.language === "en";
  const tx = (ja, en) => (english ? en : ja);
  const root = document.createElement("div");
  root.className = "hp-usage";
  container.append(root);
  let usage = null;
  let disposed = false;

  const offChanged = on("aiUsage.changed", (payload) => { usage = payload; paint(); });
  // Times move on without new data; update them in place so buttons under the pointer are not rebuilt.
  const clock = window.setInterval(tick, 30_000);
  void request("aiUsage.getState", { refresh: true }).then((payload) => { usage = payload; paint(); }).catch(() => paint(true));

  function paint(failed = false) {
    if (disposed) return;
    const services = (usage?.services ?? []).filter((service) => service.visible);
    if (!usage) {
      root.replaceChildren(message(failed
        ? tx("使用状況を読み込めませんでした。", "Could not load usage.")
        : tx("読み込み中…", "Loading…")));
      return;
    }
    if (services.length === 0) {
      const empty = message(tx("表示するサービスがありません。設定のAIで選べます。", "No services shown. Choose them in Settings › AI."));
      empty.append(settingsButton(tx("設定を開く", "Open Settings")));
      root.replaceChildren(empty);
      return;
    }
    const grid = document.createElement("div");
    grid.className = "hp-usage-grid";
    grid.dataset.count = String(services.length);
    for (const service of services) grid.append(card(service));
    root.replaceChildren(grid);
  }

  function card(service) {
    const article = document.createElement("article");
    article.className = "hp-usage-card";
    article.dataset.service = service.id;
    article.dataset.status = service.status;

    const head = document.createElement("header");
    head.className = "hp-usage-head";
    const mark = document.createElement("span");
    mark.className = "hp-usage-mark";
    mark.textContent = SERVICE_MARKS[service.id] ?? service.name.slice(0, 2);
    mark.setAttribute("aria-hidden", "true");
    const name = document.createElement("h2");
    name.className = "hp-usage-name";
    name.textContent = service.name;
    head.append(mark, name);
    if (service.plan) {
      const plan = document.createElement("span");
      plan.className = "hp-usage-plan";
      plan.textContent = service.plan;
      head.append(plan);
    }
    const meta = document.createElement("span");
    meta.className = "hp-usage-meta";
    meta.textContent = metaText(service);
    if (service.stale || service.status === "error") meta.classList.add("is-warning");
    head.append(meta);
    article.append(head);

    if (service.status === "signedOut") {
      const body = message(service.signIn === "codex"
        ? tx("ChatGPTにログインしていません。", "Not signed in to ChatGPT.")
        : tx("サインインしていません。", "Not signed in."));
      body.append(settingsButton(tx("設定でサインイン", "Sign in from Settings")));
      article.append(body);
      return article;
    }

    if (service.windows.length > 0) {
      const list = document.createElement("ul");
      list.className = "hp-usage-rows";
      for (const limit of service.windows) {
        const item = row(limit, service.stale);
        if (item) list.append(item);
      }
      article.append(list);
    }

    if (service.status === "error") {
      const error = document.createElement("p");
      error.className = "hp-usage-error";
      error.textContent = (service.stale ? tx("前回の値を表示中。", "Showing the last reading. ") : "") + errorText(service.errorCode);
      article.append(error);
    } else if (service.windows.length === 0) {
      article.append(message(service.refreshing || service.status === "idle"
        ? tx("読み込み中…", "Loading…")
        : tx("表示できる枠がありません。", "No usage windows reported.")));
    }
    return article;
  }

  function row(limit, stale) {
    const raw = typeof limit.usedPercent === "number" ? limit.usedPercent : NaN;
    if (!Number.isFinite(raw) || raw < 0) return null;
    const used = Math.min(100, raw);
    const item = document.createElement("li");
    item.className = "hp-usage-row";
    item.dataset.kind = limit.kind ?? "";
    item.dataset.minutes = String(limit.windowMinutes ?? "");
    item.dataset.resetsAt = limit.resetsAt ?? "";
    item.dataset.level = used >= 90 ? "high" : used >= 80 ? "warn" : "normal";
    if (stale) item.classList.add("is-stale");

    const top = document.createElement("div");
    top.className = "hp-usage-row-top";
    const label = document.createElement("span");
    label.className = "hp-usage-label";
    label.textContent = windowLabel(limit);
    const value = document.createElement("span");
    value.className = "hp-usage-value";
    value.textContent = `${formatPercent(used)}%`;
    top.append(label, value);

    const bar = document.createElement("div");
    bar.className = "hp-usage-bar";
    bar.setAttribute("role", "meter");
    bar.setAttribute("aria-valuemin", "0");
    bar.setAttribute("aria-valuemax", "100");
    bar.setAttribute("aria-valuenow", String(used));
    bar.setAttribute("aria-label", `${label.textContent} ${value.textContent}`);
    const fill = document.createElement("span");
    fill.className = "hp-usage-fill";
    fill.style.width = `${used}%`;
    bar.append(fill);
    const pace = document.createElement("span");
    pace.className = "hp-usage-pace";
    bar.append(pace);

    const reset = document.createElement("div");
    reset.className = "hp-usage-reset";
    item.append(top, bar, reset);
    updateTimes(item);
    return item;
  }

  function updateTimes(item) {
    const limit = { kind: item.dataset.kind, windowMinutes: Number(item.dataset.minutes) || null, resetsAt: item.dataset.resetsAt || null };
    const elapsed = elapsedPercent(limit);
    const pace = item.querySelector(".hp-usage-pace");
    pace.hidden = elapsed === null;
    if (elapsed !== null) {
      pace.style.left = `${elapsed}%`;
      pace.title = tx(`時間の経過 ${Math.round(elapsed)}%`, `${Math.round(elapsed)}% of the window elapsed`);
    }
    item.querySelector(".hp-usage-reset").textContent = resetText(limit, elapsed);
  }

  function tick() {
    if (!disposed) root.querySelectorAll(".hp-usage-row").forEach(updateTimes);
  }

  function windowLabel(limit) {
    const minutes = Number(limit.windowMinutes) || 0;
    let base;
    if (limit.kind === "session" && (minutes === 300 || minutes === 0)) base = tx("5時間", "5-hour");
    else if (limit.kind === "weekly") base = tx("1週間", "Weekly");
    else if (minutes >= 1440 && minutes % 1440 === 0) base = tx(`${minutes / 1440}日`, `${minutes / 1440}-day`);
    else if (minutes >= 60) base = tx(`${Math.round(minutes / 60)}時間`, `${Math.round(minutes / 60)}-hour`);
    else base = tx("枠", "Window");
    return limit.model ? `${limit.model} · ${base}` : base;
  }

  function elapsedPercent(limit) {
    const minutes = Number(limit.windowMinutes) || 0;
    const resetsAt = limit.resetsAt ? Date.parse(limit.resetsAt) : NaN;
    if (!minutes || Number.isNaN(resetsAt)) return null;
    const remaining = resetsAt - Date.now();
    if (remaining <= 0 || remaining > minutes * 60_000) return null;
    return Math.max(0, Math.min(100, 100 - (remaining / (minutes * 60_000)) * 100));
  }

  function resetText(limit, elapsed) {
    const resetsAt = limit.resetsAt ? Date.parse(limit.resetsAt) : NaN;
    if (Number.isNaN(resetsAt)) return tx("リセット時刻は不明", "Reset time unknown");
    const remaining = resetsAt - Date.now();
    let text;
    if (remaining <= 0) text = tx("リセット済み（次の更新で反映）", "Reset (updates on next refresh)");
    else if (remaining < 24 * 3_600_000) {
      const total = Math.max(1, Math.ceil(remaining / 60_000));
      const hours = Math.floor(total / 60);
      const minutes = total % 60;
      text = hours === 0
        ? tx(`あと${minutes}分でリセット`, `Resets in ${minutes}m`)
        : minutes === 0
          ? tx(`あと${hours}時間でリセット`, `Resets in ${hours}h`)
          : tx(`あと${hours}時間${minutes}分でリセット`, `Resets in ${hours}h ${minutes}m`);
    } else {
      const totalHours = Math.floor(remaining / 3_600_000);
      const days = Math.floor(totalHours / 24);
      const hours = totalHours % 24;
      const formatted = new Intl.DateTimeFormat(english ? "en-US" : "ja-JP", {
        month: "numeric", day: "numeric", weekday: "short", hour: "2-digit", minute: "2-digit"
      }).format(new Date(resetsAt));
      const left = hours === 0 ? tx(`${days}日`, `${days}d`) : tx(`${days}日${hours}時間`, `${days}d ${hours}h`);
      text = tx(`あと${left}でリセット（${formatted}）`, `Resets in ${left} (${formatted})`);
    }
    if (elapsed !== null && limit.kind === "weekly") text += tx(` · 経過${Math.round(elapsed)}%`, ` · ${Math.round(elapsed)}% elapsed`);
    return text;
  }

  function metaText(service) {
    if (service.refreshing) return tx("更新中…", "Updating…");
    if (!service.fetchedAt) return "";
    const time = new Intl.DateTimeFormat(english ? "en-US" : "ja-JP", { hour: "2-digit", minute: "2-digit" })
      .format(new Date(service.fetchedAt));
    return service.stale ? tx(`${time} の値`, `As of ${time}`) : tx(`${time} 更新`, `Updated ${time}`);
  }

  function errorText(code) {
    switch (code) {
      case "codexMissing": return tx("Codexが見つかりません。Codexアプリを入れると表示できます。", "Codex was not found. Install the Codex app to show it.");
      case "changed": return tx("使用状況の応答を読み取れませんでした（サービス側の変更の可能性があります）。", "Could not read the usage response (the service may have changed).");
      case "timeout": return tx("時間内に応答がありませんでした。", "The service did not respond in time.");
      case "blocked": return tx("確認画面で止まりました。設定のサインイン画面を開き直してください。", "Stopped at a verification page. Open the sign-in window in Settings again.");
      case "unavailable": return tx("いまは取得できません。少し待って更新してください。", "Usage is unavailable right now. Try again later.");
      default: return tx("接続できませんでした。", "Could not connect.");
    }
  }

  function formatPercent(value) {
    return Number.isInteger(value) ? String(value) : value.toFixed(1);
  }

  function message(text) {
    const node = document.createElement("div");
    node.className = "hp-usage-message";
    const paragraph = document.createElement("p");
    paragraph.textContent = text;
    node.append(paragraph);
    return node;
  }

  function settingsButton(text) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "hp-usage-action";
    button.textContent = text;
    button.onclick = () => { void request("aiUsage.openSettings").catch(() => {}); };
    return button;
  }

  return {
    // Opening the panel reuses readings younger than two minutes; the header button always re-reads.
    refresh(options) {
      const call = options?.panelOpened ? request("aiUsage.getState", { refresh: true }) : request("aiUsage.refresh");
      return call.then((payload) => { usage = payload; paint(); }).catch(() => {});
    },
    dispose() {
      disposed = true;
      offChanged();
      window.clearInterval(clock);
    },
  };
}
