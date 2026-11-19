import { on } from "../../js/bridge.js";

const COLUMNS = ["session", "weekly", "other"];
const COLORS = { blue: "#5aa9ff", green: "#5fd08a", yellow: "#f5c35b", red: "#ff7c7c" };
const SVG_NS = "http://www.w3.org/2000/svg";
const MOVE_KEYS = { ArrowUp: -1, ArrowLeft: -1, ArrowDown: 1, ArrowRight: 1 };

export function aiUsageSectionTitle(orderKey, english) {
  if (orderKey === "balanceOrder") return english ? "Credits and balances" : "クレジット・残高";
  return english ? "Plan limits" : "サブスクの利用枠";
}

export function aiUsageBalanceName(service, english) {
  if (service.id === "codex") return english ? "Codex credits" : "Codex クレジット";
  return service.name;
}

export function aiUsageSectionServices(usage, orderKey, forPanel = false) {
  const byId = new Map((usage?.services ?? []).map((service) => [service.id, service]));
  return (usage?.[orderKey] ?? [...byId.keys()]).map((id) => byId.get(id)).filter((service) => {
    if (!service || (forPanel && !service.visible)) return false;
    const balanceOnly = service.id === "claude-api" || service.id === "colab";
    if (orderKey === "balanceOrder") {
      return service.balances?.length || balanceOnly ||
        (service.id === "codex" && (!forPanel || service.status !== "ok"));
    }
    return !balanceOnly && (!forPanel || service.windows.length || service.status !== "ok");
  });
}

function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function button(className, text, action) {
  const node = element("button", className, text);
  node.type = "button";
  node.onclick = action;
  return node;
}

function svgElement(tag, attributes = {}) {
  const node = document.createElementNS(SVG_NS, tag);
  for (const [name, value] of Object.entries(attributes)) node.setAttribute(name, value);
  return node;
}

function point(radius, percent) {
  const radians = (135 + percent * 2.7) * Math.PI / 180;
  return [58 + radius * Math.cos(radians), 54 + radius * Math.sin(radians)];
}

function arc(radius, start, end, attributes) {
  return svgElement("path", {
    d: `M ${point(radius, start).join(" ")} A ${radius} ${radius} 0 ${end - start > 200 / 3 ? 1 : 0} 1 ${point(radius, end).join(" ")}`,
    ...attributes,
  });
}

function radialLine(percent, inner, outer, attributes) {
  const [x1, y1] = point(inner, percent);
  const [x2, y2] = point(outer, percent);
  return svgElement("line", { x1, y1, x2, y2, ...attributes });
}

function columnFor(limit) {
  if (!limit.model && limit.kind === "session" && limit.windowMinutes === 300) return "session";
  if (!limit.model && limit.kind === "weekly") return "weekly";
  return "other";
}

function remaining(limit) {
  return limit.state !== "unreadable" && Number.isFinite(limit.usedPercent) && limit.usedPercent >= 0
    ? 100 - Math.min(100, limit.usedPercent) : null;
}

function colorFor(value) {
  return COLORS[value >= 70 ? "blue" : value >= 50 ? "green" : value >= 25 ? "yellow" : "red"];
}

function formatPercent(value) {
  return Number.isInteger(value) ? String(value) : value.toFixed(1);
}

/** Shows the saved readings as a table or as gauges. Acquisition stays on the existing bridge path. */
export function renderAiUsageProvider({ container, state, request, iconSvg }) {
  const english = state?.settings?.language === "en";
  const tx = (ja, en) => (english ? en : ja);
  const names = { session: tx("5時間", "5-hour"), weekly: tx("1週間", "Weekly"), other: tx("別枠", "Other") };
  const root = element("div", "hp-usage");
  const header = element("header", "hp-usage-header");
  const title = element("h2", "", "AI Usage");
  const modes = element("div", "hp-size-switch");
  modes.setAttribute("role", "group");
  modes.setAttribute("aria-label", tx("表示の種類", "View"));
  const listMode = button("hp-size-button", tx("一覧", "List"), () => void save({ view: "list" }));
  const meterMode = button("hp-size-button", tx("メーター", "Meter"), () => void save({ view: "meter" }));
  listMode.dataset.view = "list";
  meterMode.dataset.view = "meter";
  modes.append(listMode, meterMode);
  const updated = element("span", "hp-usage-updated");
  updated.setAttribute("role", "status");
  const refreshButton = button("hp-icon-button hp-usage-refresh", "", () => void refresh());
  refreshButton.innerHTML = iconSvg("refresh");
  refreshButton.title = tx("更新", "Refresh");
  refreshButton.setAttribute("aria-label", refreshButton.title);
  header.append(title, modes, updated, refreshButton);
  const saveError = element("p", "hp-usage-error hp-usage-save-error");
  saveError.setAttribute("role", "status");
  saveError.hidden = true;
  const body = element("div", "hp-usage-body");
  root.append(header, saveError, body);
  container.append(root);

  let usage = null;
  let disposed = false;
  let saving = false;
  let drag = null;
  let deferredPaint = false;
  let paintedExpired = "";
  let expiryTimer = 0;
  const timeFormat = new Intl.DateTimeFormat(english ? "en-US" : "ja-JP", {
    hour: "2-digit", minute: "2-digit", hourCycle: "h23",
  });
  const columnEntries = (service, column) => service.windows.filter((limit) => columnFor(limit) === column);
  const isExpired = (service) => service.status === "ok" && Date.now() >= Date.parse(service.freshUntil);
  const expiredIds = () => (usage?.services ?? []).filter((service) => service.visible && isExpired(service)).map((service) => service.id).join(",");

  const offChanged = on("aiUsage.changed", accept);
  const clock = window.setInterval(tick, 30_000);
  paint();
  void request("aiUsage.getState", { refresh: true }).then(accept).catch(() => paint(true));

  function numberText(text) {
    const parts = text.split(/(\d+(?::\d+)?)/);
    return parts.map((part, index) => index % 2 ? element("span", "hp-usage-numeric", part) : part);
  }

  function accept(payload) {
    usage = payload;
    if (!saving) paint();
  }

  async function refresh(options) {
    const call = options?.panelOpened ? request("aiUsage.getState", { refresh: true }) : request("aiUsage.refresh");
    await call.then(accept).catch(() => {});
  }

  async function save(params) {
    if (saving || drag || !usage) return;
    saving = true;
    saveError.hidden = true;
    try {
      accept(await request("aiUsage.setPresentation", params));
    } catch {
      saveError.textContent = tx("変更を保存できませんでした。", "Could not save the change.");
      saveError.hidden = false;
    } finally {
      saving = false;
      paint();
    }
  }

  function paint(failed = false) {
    if (disposed) return;
    if (drag) {
      deferredPaint = true;
      return;
    }
    deferredPaint = false;
    paintedExpired = expiredIds();
    window.clearTimeout(expiryTimer);
    const next = Math.min(...(usage?.services ?? [])
      .filter((service) => service.visible && service.status === "ok" && !isExpired(service))
      .map((service) => Date.parse(service.freshUntil))
      .filter(Number.isFinite));
    if (Number.isFinite(next)) expiryTimer = window.setTimeout(() => paint(), Math.max(0, next - Date.now()) + 50);

    const services = (usage?.services ?? []).filter((service) => service.visible);
    const withFreshness = (service) => isExpired(service) ? { ...service, status: "error", stale: true, errorCode: "stale" } : service;
    const view = usage?.view === "meter" ? "meter" : "list";
    listMode.setAttribute("aria-pressed", String(view === "list"));
    meterMode.setAttribute("aria-pressed", String(view === "meter"));
    listMode.disabled = meterMode.disabled = !usage;
    const latest = services.filter((service) => service.status === "ok" && !isExpired(service))
      .map((service) => Date.parse(service.fetchedAt)).filter(Number.isFinite);
    updated.replaceChildren();
    if (services.some((service) => service.refreshing)) updated.textContent = tx("更新中…", "Updating…");
    else if (latest.length) {
      const time = timeFormat.format(Math.max(...latest));
      updated.append(...numberText(tx(`${time} 更新`, `Updated ${time}`)));
    }

    const focused = body.contains(document.activeElement) ? document.activeElement.dataset.focus : null;
    const scrollTop = body.scrollTop;
    if (!usage) {
      body.replaceChildren(element("p", "hp-usage-message", failed
        ? tx("使用状況を読み込めませんでした。", "Could not load usage.")
        : tx("読み込み中…", "Loading…")));
    } else if (!services.length) {
      const empty = element("div", "hp-usage-message", tx("表示するサービスがありません。設定のAIで選べます。", "No services shown. Choose them in Settings › AI."));
      empty.append(settingsButton());
      body.replaceChildren(empty);
    } else {
      const plans = aiUsageSectionServices(usage, "order", true).map(withFreshness);
      const balances = aiUsageSectionServices(usage, "balanceOrder", true).map(withFreshness);
      body.replaceChildren();
      if (plans.length) body.append(usageSection("order", view === "meter" ? meterView(plans) : listView(plans, usage.sort)));
      if (balances.length) body.append(usageSection("balanceOrder", balanceView(balances)));
    }
    body.scrollTop = scrollTop;
    if (focused) {
      const target = [...body.querySelectorAll("[data-focus]")].find((node) => node.dataset.focus === focused);
      (target ?? body.querySelector("[data-sort-column]"))?.focus({ preventScroll: true });
    }
  }

  function usageSection(orderKey, content) {
    const section = element("section", "hp-usage-section");
    section.dataset.section = orderKey;
    section.append(element("h3", "hp-usage-section-title", aiUsageSectionTitle(orderKey, english)), content);
    return section;
  }

  function listView(services, sort) {
    const table = element("table", "hp-usage-table hp-usage-list");
    table.setAttribute("aria-label", "AI Usage");
    const columns = element("colgroup");
    if (!sort) columns.append(element("col", "hp-usage-handle-column"));
    columns.append(element("col", "hp-usage-name-column"));
    for (const column of COLUMNS) columns.append(element("col", `hp-usage-${column}-column`));
    const head = element("thead");
    const headings = element("tr");
    if (!sort) headings.append(element("td"));
    const name = element("th");
    name.scope = "col";
    if (sort) {
      const reset = button("hp-usage-sort-reset", tx("自分の順に戻す", "Back to my order"), () => void save({ sort: null }));
      reset.dataset.focus = "sort-reset";
      name.append(reset);
    } else {
      name.textContent = tx("残り", "Left");
    }
    headings.append(name);
    for (const column of COLUMNS) {
      const th = element("th");
      th.scope = "col";
      const direction = sort?.column === column ? sort.direction : null;
      if (direction) th.setAttribute("aria-sort", direction === "asc" ? "ascending" : "descending");
      const toggle = button("hp-usage-sort", names[column], () => void save({
        sort: { column, direction: direction === "asc" ? "desc" : "asc" },
      }));
      toggle.dataset.sortColumn = column;
      toggle.dataset.focus = column;
      const arrow = element("span", "hp-usage-sort-arrow", direction === "asc" ? "↑" : direction === "desc" ? "↓" : "↕");
      arrow.setAttribute("aria-hidden", "true");
      toggle.append(arrow);
      th.append(toggle);
      headings.append(th);
    }
    head.append(headings);
    const ordered = sort ? sortedServices(services, sort) : services;
    table.append(columns, head);
    for (const service of ordered) {
      const group = element("tbody", "hp-usage-service");
      setService(group, service);
      const row = element("tr");
      if (!sort) {
        const slot = element("td");
        slot.append(handle(group, service.name, "order"));
        row.append(slot);
      }
      const label = element("th");
      label.scope = "row";
      label.append(serviceName(service));
      row.append(label);
      const showReason = service.status === "error" && (service.stale || !service.windows.length);
      const status = showReason ? null : serviceMessage(service, service.windows.length);
      if (status || (showReason && !service.windows.length)) {
        const cell = element("td");
        cell.colSpan = COLUMNS.length;
        if (status) cell.append(status);
        row.append(cell);
      } else {
        for (const column of COLUMNS) {
          const cell = element("td");
          cell.dataset.column = column;
          const limits = columnEntries(service, column);
          if (!limits.length) cell.append(element("span", "hp-usage-placeholder", "—"));
          for (const limit of limits) cell.append(listLimit(service, limit, column));
          row.append(cell);
        }
      }
      group.append(row);
      if (showReason) {
        const details = element("tr", "hp-usage-reason-row");
        const spacer = element("td");
        spacer.colSpan = sort ? 1 : 2;
        const cell = element("td");
        cell.colSpan = COLUMNS.length;
        cell.append(reason(service));
        details.append(spacer, cell);
        group.append(details);
      }
      table.append(group);
    }
    return table;
  }

  function sortedServices(services, sort) {
    function value(service) {
      return Math.min(...columnEntries(service, sort.column).map((limit) => remaining(limit) ?? Infinity));
    }
    return services.map((service) => ({ service, value: value(service) })).sort((a, b) => {
      if (a.value === b.value) return 0;
      if (!Number.isFinite(a.value)) return 1;
      if (!Number.isFinite(b.value)) return -1;
      return (a.value - b.value) * (sort.direction === "asc" ? 1 : -1);
    }).map(({ service }) => service);
  }

  function setService(node, service) {
    node.dataset.service = service.id;
    node.dataset.status = service.status;
    node.classList.toggle("is-stale", Boolean(service.stale));
  }

  function serviceName(service, balanceName) {
    const line = element("div", balanceName ? "hp-usage-balance-heading" : "hp-usage-service-name");
    line.append(element("span", balanceName ? "hp-usage-balance-label" : "", balanceName ?? service.name));
    const fetched = Date.parse(service.fetchedAt);
    if (service.stale && Number.isFinite(fetched)) {
      const time = timeFormat.format(fetched);
      const stamp = element("span", "hp-usage-old");
      stamp.append(...numberText(tx(`${time} の値`, `As of ${time}`)));
      line.append(stamp);
    }
    return line;
  }

  function reason(service) {
    const keepsLast = service.stale && service.errorCode !== "stale" && service.errorCode !== "noValues";
    const text = (keepsLast ? tx("前回の値を表示中。", "Showing the last reading. ") : "") + errorText(service.errorCode);
    const node = element("p", "hp-usage-error", text);
    node.title = text;
    return node;
  }

  function serviceMessage(service, hasValues) {
    if (service.status === "signedOut") {
      const shared = usage.services.find((item) => item.id === service.sharedWith)?.name;
      const text = shared
        ? tx(`${shared}のサインインを使います。サインインしていません。`, `Uses the ${shared} sign-in, which is signed out.`)
        : tx("サインインしていません", "Not signed in");
      const node = element("div", "hp-usage-message");
      node.append(element("span", "", text), settingsButton());
      return node;
    }
    if (hasValues) return null;
    if (service.status === "error") return service.stale ? null : reason(service);
    return element("p", "hp-usage-message", service.refreshing || service.status === "idle"
      ? tx("読み込み中…", "Loading…")
      : tx("表示できる枠がありません。", "No usage windows reported."));
  }

  function settingsButton() {
    return button("hp-usage-action", tx("設定を開く", "Open Settings"),
      () => { void request("aiUsage.openSettings").catch(() => {}); });
  }

  function reorderItems(parent) {
    return [...parent.children].filter((item) => item.matches(".hp-usage-service"));
  }

  function saveOrder(orderKey, items, baseOrder = usage[orderKey]) {
    const ids = items.map((item) => item.dataset.service);
    const rendered = new Set(ids);
    let i = 0;
    const next = baseOrder.map((id) => rendered.has(id) ? ids[i++] : id);
    if (next.some((id, index) => id !== baseOrder[index])) void save({ [orderKey]: next });
    else if (deferredPaint) paint();
  }

  function handle(item, name, orderKey) {
    const grip = element("button", "hp-usage-handle", "⠿");
    grip.type = "button";
    grip.title = tx(`${name}を移動`, `Move ${name}`);
    grip.setAttribute("aria-label", grip.title);
    grip.dataset.focus = `${orderKey}:${item.dataset.service}`;
    grip.onpointerdown = (event) => {
      if (drag || saving || !event.isPrimary || event.button !== 0) return;
      try {
        grip.setPointerCapture(event.pointerId);
      } catch (error) {
        if (error.name === "NotFoundError") return;
        throw error;
      }
      grip.focus({ preventScroll: true });
      const items = reorderItems(item.parentElement);
      drag = { item, grip, items, orderKey, pointerId: event.pointerId, order: usage[orderKey],
        x: event.clientX, y: event.clientY };
      item.classList.add("is-dragging");
      event.preventDefault();
    };
    grip.onpointermove = (event) => {
      if (drag?.grip !== grip || drag.pointerId !== event.pointerId) return;
      const { clientX: x, clientY: y } = event;
      const dx = x - drag.x;
      const dy = y - drag.y;
      drag.x = x;
      drag.y = y;
      if (!dx && !dy) return;
      const over = document.elementFromPoint(x, y)?.closest(".hp-usage-service");
      if (!over || over === item || over.parentElement !== item.parentElement) return;

      const items = reorderItems(item.parentElement);
      const from = items.indexOf(item);
      const to = items.indexOf(over);
      const rect = over.getBoundingClientRect();
      const source = item.getBoundingClientRect();
      const sameRow = rect.top < source.bottom && rect.bottom > source.top;
      const direction = sameRow ? dx : dy;
      if ((to - from) * direction <= 0) return;

      // Move the siblings instead of disconnecting the handle that owns pointer capture.
      moveItem(item, items, to);
    };
    grip.onpointerup = (event) => {
      if (drag?.grip !== grip || drag.pointerId !== event.pointerId) return;
      const hit = document.elementFromPoint(event.clientX, event.clientY);
      const section = hit?.closest(".hp-usage-section");
      finishDrag(Boolean(hit?.closest(".hp-panel")) && (!section || section.dataset.section === orderKey));
    };
    grip.onpointercancel = grip.onlostpointercapture = (event) => {
      if (drag?.grip === grip && drag.pointerId === event.pointerId) finishDrag(false);
    };
    grip.onblur = () => {
      if (drag?.grip === grip) finishDrag(false);
    };
    grip.onkeydown = (event) => {
      if (event.key === "Escape" && drag?.grip === grip) {
        event.preventDefault();
        event.stopPropagation();
        finishDrag(false);
        return;
      }
      const offset = MOVE_KEYS[event.key];
      if (typeof offset !== "number" || drag || saving) return;
      event.preventDefault();
      const items = reorderItems(item.parentElement);
      const from = items.indexOf(item);
      const to = from + offset;
      if (to < 0 || to >= items.length) return;
      moveItem(item, items, to);
      grip.scrollIntoView({ block: "nearest" });
      saveOrder(orderKey, reorderItems(item.parentElement));
    };
    return grip;
  }

  function moveItem(item, items, to) {
    const from = items.indexOf(item);
    if (from < to) {
      for (const sibling of items.slice(from + 1, to + 1)) item.before(sibling);
    } else {
      for (const sibling of items.slice(to, from).reverse()) item.after(sibling);
    }
  }

  function finishDrag(commit) {
    if (!drag) return;
    const { item, grip, pointerId, items, order, orderKey } = drag;
    drag = null;
    if (grip.hasPointerCapture(pointerId)) grip.releasePointerCapture(pointerId);
    item.classList.remove("is-dragging");
    if (!item.parentElement) return;
    const current = reorderItems(item.parentElement);
    if (commit && usage[orderKey].every((id, i) => id === order[i])) {
      saveOrder(orderKey, current, order);
    } else {
      moveItem(item, current, items.indexOf(item));
      if (deferredPaint) paint();
    }
  }

  function windowName(limit) {
    const column = columnFor(limit);
    if (column !== "other") return names[column];
    const minutes = Number(limit.windowMinutes) || 0;
    if (minutes >= 1440 && minutes % 1440 === 0) return tx(`${minutes / 1440}日`, `${minutes / 1440}-day`);
    if (minutes >= 60 && minutes % 60 === 0) return tx(`${minutes / 60}時間`, `${minutes / 60}-hour`);
    return minutes > 0 ? tx(`${minutes}分`, `${minutes}-minute`) : tx("枠", "Window");
  }

  function repeatedWindowDuration(service, limit) {
    if (!limit.model || !service.windows.some((other) => other !== limit && other.model === limit.model)) return "";
    if (limit.windowMinutes === 10080) return tx("1週間", "1 week");
    if (limit.windowMinutes === 300) return tx("5時間", "5 hours");
    return windowName(limit);
  }

  function windowLabel(service, limit) {
    const label = element("span", "hp-usage-limit-name");
    const duration = repeatedWindowDuration(service, limit);
    if (duration) {
      label.append(element("span", "hp-usage-window-model", limit.model),
        element("span", "hp-usage-window-duration", ` ${duration}`));
    } else {
      label.textContent = limit.model || windowName(limit);
    }
    label.title = label.textContent;
    return label;
  }

  function listLimit(service, limit, column) {
    const node = element("div", "hp-usage-limit");
    const line = element("div", "hp-usage-limit-top");
    const left = element("span", "hp-usage-limit-left");
    const label = windowLabel(service, limit);
    if (column === "other") left.append(label);
    line.append(left);
    node.append(line);
    const value = remaining(limit);
    if (value === null) {
      left.append(element("span", "hp-usage-unavailable", tx("取得できません", "Unavailable")));
      return node;
    }
    node.style.setProperty("--usage-color", colorFor(value));
    const number = element("span", "hp-usage-value");
    number.append(element("span", "hp-usage-numeric", formatPercent(value)), element("span", "hp-usage-percent-sign", "%"));
    left.append(number);
    line.append(resetLabel(limit));
    const bar = element("div", "hp-usage-bar");
    bar.setAttribute("role", "meter");
    bar.setAttribute("aria-valuemin", "0");
    bar.setAttribute("aria-valuemax", "100");
    bar.setAttribute("aria-valuenow", String(value));
    bar.setAttribute("aria-label", label.title);
    const fill = element("span", "hp-usage-fill");
    fill.style.width = `${value}%`;
    bar.append(fill);
    left.append(bar);
    return node;
  }

  function meterView(services) {
    const cards = element("div", "hp-usage-meter-grid");
    for (const service of services) {
      const card = element("article", "hp-usage-card hp-usage-service");
      setService(card, service);
      const head = element("header");
      head.append(handle(card, service.name, "order"), serviceName(service));
      card.append(head);
      if (service.stale && service.status === "error") card.append(reason(service));
      const status = serviceMessage(service, service.windows.length);
      if (status) card.append(status);
      const meters = element("div", "hp-usage-meters");
      for (const column of COLUMNS) {
        for (const limit of columnEntries(service, column)) meters.append(meter(service, limit));
      }
      if (meters.childElementCount) card.append(meters);
      cards.append(card);
    }
    return cards;
  }

  function meter(service, limit) {
    const node = element("div", "hp-usage-meter");
    const label = element("span", "hp-usage-limit-name", limit.model || windowName(limit));
    const duration = repeatedWindowDuration(service, limit);
    const name = duration ? `${label.textContent} ${duration}` : label.textContent;
    const value = remaining(limit);
    const svg = svgElement("svg", { width: 116, height: 100, viewBox: "0 0 116 100", "aria-hidden": "true", fill: "none" });
    svg.append(arc(46, 0, 100, { stroke: "#161b22", "stroke-width": 5 }));
    if (value !== null) {
      const bands = [[0, 25, COLORS.red], [25, 50, COLORS.yellow], [50, 70, COLORS.green], [70, 100, COLORS.blue]];
      for (const [start, end, color] of bands) {
        svg.append(arc(51, start + Number(start !== 0) * 0.6, end - Number(end !== 100) * 0.6, {
          stroke: color, "stroke-width": 1.6, opacity: 0.45,
        }));
      }
    }
    for (let i = 0; i <= 100; i += 5) {
      const major = i % 25 === 0;
      svg.append(radialLine(i, major ? 37.5 : 39.5, 42, { stroke: major ? "#8a94a6" : "#343b46" }));
    }
    const center = element("div", "hp-usage-meter-center");
    center.append(element("span", "hp-usage-meter-caption", tx("残り", "left")));
    const number = element("span", "hp-usage-meter-number", value === null ? "—" : undefined);
    if (value !== null) {
      const color = colorFor(value);
      number.style.color = color;
      number.append(element("span", "hp-usage-numeric", formatPercent(value)), element("span", "hp-usage-percent-sign", "%"));
      if (value > 0) svg.append(arc(46, 0, value, {
        class: "hp-usage-meter-value", stroke: color, "stroke-width": 5, "stroke-dasharray": "2.6 1.3",
      }));
      svg.append(radialLine(value, 37, 52, {
        class: "hp-usage-needle", stroke: "white", "stroke-width": 2, "stroke-linecap": "round",
      }));
    }
    center.append(number);
    const foot = element("div", "hp-usage-meter-foot");
    foot.append(label);
    const reset = value === null ? null : resetLabel(limit);
    if (duration || reset?.textContent) {
      const detail = element("div", "hp-usage-meter-detail", duration);
      if (reset?.textContent) {
        if (duration) detail.append(" · ");
        detail.append(reset);
      }
      foot.append(detail);
    }
    node.title = value === null ? tx(`${name} 取得できません`, `${name} unavailable`) : name;
    node.append(svg, center, foot);
    node.setAttribute("role", "img");
    node.dataset.label = name;
    node.dataset.percent = value === null ? "" : `${formatPercent(value)}%`;
    updateMeterName(node);
    return node;
  }

  function resetLabel(limit) {
    const label = element("span", "hp-usage-reset");
    const date = new Date(limit.resetsAt ?? NaN);
    if (!Number.isNaN(date.getTime())) {
      label.dataset.resetsAt = date.toISOString();
      const day = new Intl.DateTimeFormat(english ? "en-US" : "ja-JP", { weekday: "short" }).format(date);
      const monthDay = new Intl.DateTimeFormat(english ? "en-US" : "ja-JP", { month: "numeric", day: "numeric" }).format(date);
      const time = timeFormat.format(date);
      label.title = tx(`${monthDay}(${day}) ${time}にリセット`, `Resets ${day} ${monthDay} ${time}`);
      updateReset(label);
    }
    return label;
  }

  function updateReset(label) {
    const remainingMs = Date.parse(label.dataset.resetsAt) - Date.now();
    if (remainingMs <= 0) {
      label.textContent = tx("リセット済み", "Reset");
      return;
    }
    if (remainingMs < 86_400_000) {
      const total = Math.min(1439, Math.ceil(remainingMs / 60_000));
      label.replaceChildren(...numberText(`${Math.floor(total / 60)}:${String(total % 60).padStart(2, "0")}`));
      return;
    }
    const total = Math.floor(remainingMs / 3_600_000);
    const days = Math.floor(total / 24);
    const hours = total % 24;
    label.replaceChildren(...numberText(hours ? tx(`${days}日${hours}時間`, `${days}d ${hours}h`) : tx(`${days}日`, `${days}d`)));
  }

  function updateMeterName(node) {
    const { label, percent } = node.dataset;
    const reset = node.querySelector(".hp-usage-reset")?.textContent;
    const value = percent ? tx(`残り${percent}`, `${percent} left`) : tx("取得できません", "Unavailable");
    const resetText = reset === tx("リセット済み", "Reset") ? reset : tx(`あと${reset}でリセット`, `resets in ${reset}`);
    node.setAttribute("aria-label", `${label} ${value}${reset ? tx(`、${resetText}`, `, ${resetText}`) : ""}`);
  }

  function tick() {
    if (disposed) return;
    if (usage && expiredIds() !== paintedExpired) paint();
    body.querySelectorAll("[data-resets-at]").forEach(updateReset);
    body.querySelectorAll(".hp-usage-meter").forEach(updateMeterName);
    body.querySelectorAll("[data-expires-at]").forEach(updateExpiry);
  }

  function balancesFor(service) {
    const balances = (service.balances ?? []).filter((balance) => balance.state || (Number.isFinite(balance.amount) && balance.amount >= 0));
    if (service.id !== "claude-api") return balances;
    const amounts = balances.filter((balance) => !balance.state);
    if (!amounts.length) return balances;
    const expiresAt = amounts.map((balance) => balance.expiresAt).filter(Boolean).sort((a, b) => Date.parse(a) - Date.parse(b))[0];
    return [{ unit: "usd", amount: amounts.reduce((total, balance) => total + balance.amount, 0), expiresAt, breakdown: balances }];
  }

  function balanceAmount(balance) {
    if (balance.state === "unlimited") return tx("無制限", "Unlimited");
    if (balance.state === "unreadable") return tx("読み取れません", "Unreadable");
    return formatAmount(balance.amount, balance.unit);
  }

  function balanceView(services) {
    const cards = element("div", "hp-usage-balance-grid");
    for (const service of services) {
      const card = element("article", "hp-usage-card hp-usage-balance hp-usage-service");
      setService(card, service);
      const name = aiUsageBalanceName(service, english);
      const head = element("header");
      head.append(handle(card, name, "balanceOrder"), serviceName(service, name));
      card.append(head);
      const balances = balancesFor(service);
      for (const balance of balances) card.append(balanceDisplay(balance));
      if (service.id === "codex" && balances.length) card.append(element("span", "hp-usage-balance-detail",
        tx("サブスクの枠を超えた分に使う", "Used after plan limits")));
      if (service.stale && service.status === "error") card.append(reason(service));
      const status = serviceMessage(service, balances.length);
      if (status) card.append(status);
      cards.append(card);
    }
    return cards;
  }

  function balanceDisplay(balance) {
    const box = element("div", "hp-usage-balance-reading");
    const amount = element("span", "hp-usage-balance-amount");
    if (balance.state) amount.textContent = balanceAmount(balance);
    else {
      amount.append(element("span", "hp-usage-numeric", balanceAmount(balance)));
      const unit = { credits: "CR", units: "CU" }[balance.unit];
      if (unit) amount.append(" ", element("span", "hp-usage-balance-unit", unit));
    }
    box.append(amount);
    if (balance.breakdown) {
      box.title = balance.breakdown.map((item) => {
        const label = item.kind === "purchasedCredit" ? tx("購入したクレジット", "Purchased credits")
          : item.label || tx("プラン特典のクレジット", "Plan credits");
        const expires = expiryText(item.expiresAt, true);
        return [label, balanceAmount(item), expires].filter(Boolean).join(" · ");
      }).join("\n");
    }
    if (!balance.state && balance.unit === "units") box.append(element("span", "hp-usage-balance-detail", computeDetail(balance)));
    if (balance.expiresAt) {
      const detail = element("span", "hp-usage-balance-detail");
      detail.dataset.expiresAt = balance.expiresAt;
      updateExpiry(detail);
      box.append(detail);
    }
    return box;
  }

  function updateExpiry(node) {
    node.textContent = expiryText(node.dataset.expiresAt, false);
  }

  function expiryText(expiresAt, detailed) {
    const expires = Date.parse(expiresAt);
    if (!Number.isFinite(expires)) return "";
    const date = new Intl.DateTimeFormat(english ? "en-US" : "ja-JP", { month: "numeric", day: "numeric" }).format(expires);
    const remaining = expires - Date.now();
    if (remaining <= 0) return tx(`${date}に失効`, `Expired ${date}`);
    const days = Math.ceil(remaining / 86_400_000);
    return detailed ? tx(`${date}まで（あと${days}日）`, `Until ${date} (${days} days)`) : tx(`${date}まで`, `Until ${date}`);
  }

  function computeDetail(balance) {
    const { amount, perHour } = balance;
    if (!Number.isFinite(perHour)) return tx("消費量は不明", "Rate unknown");
    if (perHour === 0) return tx("いまは消費していません", "Not consuming now");
    const hours = Math.floor(amount / perHour);
    return tx(`消費 ${formatRate(perHour)}/時間 · 約${hours}時間分`, `${formatRate(perHour)}/hour · about ${hours} hours left`);
  }

  // A positive amount below the shown precision reads "<0.1" or "<$0.01", never zero.
  function formatAmount(amount, unit) {
    const locale = english ? "en-US" : "ja-JP";
    if (unit === "usd") {
      if (amount > 0 && amount < 0.01) return "<$0.01";
      return new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" }).format(amount);
    }
    if (unit === "units") {
      if (amount > 0 && amount < 0.1) return "<0.1";
      return new Intl.NumberFormat(locale, { minimumFractionDigits: 1, maximumFractionDigits: 1 }).format(amount);
    }
    if (amount > 0 && amount < 0.01) return "<0.01";
    return new Intl.NumberFormat(locale, { maximumFractionDigits: 2 }).format(amount);
  }

  function formatRate(perHour) {
    if (perHour > 0 && perHour < 0.01) return "<0.01";
    return new Intl.NumberFormat(english ? "en-US" : "ja-JP", { maximumFractionDigits: 2 }).format(perHour);
  }

  function errorText(code) {
    switch (code) {
      case "codexMissing": return tx("Codexが見つかりません。Codexアプリを入れると表示できます。", "Codex was not found. Install the Codex app to show it.");
      case "changed": return tx("使用状況の応答を読み取れませんでした（サービス側の変更の可能性があります）。", "Could not read the usage response (the service may have changed).");
      case "timeout": return tx("時間内に応答がありませんでした。", "The service did not respond in time.");
      case "blocked": return tx("確認画面で止まりました。設定のサインイン画面を開き直してください。", "Stopped at a verification page. Open the sign-in window in Settings again.");
      case "unavailable": return tx("いまは取得できません。少し待って更新してください。", "Usage is unavailable right now. Try again later.");
      case "noAccess": return tx("このアカウントでは請求情報を見る権限がありません。", "This account cannot view billing.");
      case "ambiguous": return tx("Consoleの組織が複数あり、どれかを特定できません。", "Several Console organizations; cannot tell which one.");
      case "peerMissing": return tx("Gemini Peerを起動すると最新の値を取得できます。", "Start Gemini Peer to get the latest values.");
      case "peerFailed": return tx("Gemini Peerが利用枠を読み直せませんでした。agyのログインとステータス表示の設定を確認してください。", "Gemini Peer could not re-read the limits. Check the agy sign-in and status line setup.");
      case "stale": return tx("古い値です（読み直せていません）。少し待って更新してください。", "This reading is old and was not renewed. Try again shortly.");
      case "noSnapshot": return tx("Gemini Peerにまだ利用枠の記録がありません。少し待って更新してください。", "Gemini Peer has no reading yet. Try again shortly.");
      case "noValues": return tx("記録に利用枠の値がありませんでした。少し待って更新してください。", "The reading had no values. Try again shortly.");
      default: return tx("接続できませんでした。", "Could not connect.");
    }
  }

  return {
    refresh,
    dispose() {
      disposed = true;
      finishDrag(false);
      offChanged();
      window.clearInterval(clock);
      window.clearTimeout(expiryTimer);
    },
  };
}
