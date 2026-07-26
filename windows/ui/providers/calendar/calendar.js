const styleHref = "./providers/calendar/calendar.css";

let cachedState = null;
let loadingMonth = "";

export function renderCalendarProvider(context) {
  ensureStyle(styleHref);
  let disposed = false;
  let detailMode = "browse";
  const root = document.createElement("section");
  root.className = "hp-calendar";
  root.innerHTML = `
    <div class="hp-calendar-schedule" data-schedule>
      <section class="hp-calendar-month-pane" data-month-pane>
        <header class="hp-calendar-month-header">
          <button type="button" data-prev aria-label="${localize(context.state, "前の月", "Previous month")}">‹</button>
          <strong data-month></strong>
          <button type="button" data-next aria-label="${localize(context.state, "次の月", "Next month")}">›</button>
        </header>
        <div class="hp-calendar-grid" data-grid></div>
        <div class="hp-calendar-load-status" data-load-status></div>
      </section>
      <div class="hp-calendar-divider" aria-hidden="true"></div>
      <aside class="hp-calendar-detail" data-detail></aside>
    </div>
    <section class="hp-calendar-connection" data-connection hidden>
      <div class="hp-calendar-connection-icon" aria-hidden="true">▣</div>
      <strong data-connection-title></strong>
      <p data-connection-message></p>
      <button type="button" data-auth></button>
      <div data-setup></div>
    </section>
  `;
  context.container.append(root);

  const scheduleEl = root.querySelector("[data-schedule]");
  const connectionEl = root.querySelector("[data-connection]");
  const monthEl = root.querySelector("[data-month]");
  const gridEl = root.querySelector("[data-grid]");
  const detailEl = root.querySelector("[data-detail]");
  const loadStatusEl = root.querySelector("[data-load-status]");
  const connectionTitleEl = root.querySelector("[data-connection-title]");
  const connectionMessageEl = root.querySelector("[data-connection-message]");
  const authButton = root.querySelector("[data-auth]");
  const setupEl = root.querySelector("[data-setup]");
  setDetailMode("browse");

  root.querySelector("[data-prev]").addEventListener("click", () => shiftMonth(-1));
  root.querySelector("[data-next]").addEventListener("click", () => shiftMonth(1));
  authButton.addEventListener("click", () => {
    const method = cachedState?.connectionStatus === "signed_in" ? "calendar.signOut" : "calendar.signIn";
    authButton.disabled = true;
    context.request(method)
      .then((state) => {
        if (disposed) {
          return;
        }
        cachedState = state;
        draw(state);
        maybeLoadMonth();
      })
      .catch(() => {
        authButton.disabled = false;
      });
  });

  root.__verifyEditorStability = async () => {
    const base = cachedState ?? emptyState();
    const start = new Date(base.selectedDate ?? new Date());
    start.setHours(10, 0, 0, 0);
    const end = new Date(start.getTime() + 60 * 60 * 1000);
    setDetailMode("editor");
    detailEl.replaceChildren(editor({
      calendarId: base.sources?.find((source) => source.canWrite)?.id ?? "verify",
      eventId: null,
      title: "",
      location: "",
      notes: "",
      start: start.toISOString(),
      end: end.toISOString(),
      isAllDay: false,
    }, null));
    await new Promise((resolve) => window.setTimeout(resolve, 50));
    const form = detailEl.querySelector(".hp-calendar-editor");
    gridEl.querySelector(".hp-calendar-day")?.dispatchEvent(new MouseEvent("mouseleave"));
    const stable = Boolean(form && form === detailEl.querySelector(".hp-calendar-editor"));
    form?.querySelector("[data-cancel]")?.click();
    return stable;
  };

  draw(cachedState ?? emptyState());
  context.request("calendar.getState")
    .then((state) => {
      if (disposed) {
        return;
      }
      cachedState = state;
      draw(state);
      maybeLoadMonth();
    })
    .catch(() => draw(emptyState(localize(context.state, "カレンダーを読み込めません。", "Calendar bridge unavailable"))));

  return {
    refresh() {
      return context.request("calendar.getState").then((state) => {
        if (!disposed) {
          cachedState = state;
          draw(state);
          maybeLoadMonth();
        }
      });
    },
    dispose() {
      disposed = true;
      void context.request("panel.endTextInput").catch(() => {});
    },
  };

  function maybeLoadMonth() {
    if (cachedState?.connectionStatus !== "signed_in") {
      return;
    }
    const monthKey = monthId(cachedState.monthAnchor);
    if (cachedState.loadStatus === "loaded" && loadingMonth === monthKey) {
      return;
    }
    if (loadingMonth === `loading:${monthKey}`) {
      return;
    }
    loadingMonth = `loading:${monthKey}`;
    context.request("calendar.loadMonth", { month: cachedState.monthAnchor })
      .then((state) => {
        if (disposed) {
          return;
        }
        cachedState = state;
        loadingMonth = monthId(state.monthAnchor);
        draw(state);
      })
      .catch(() => {
        loadingMonth = "";
      });
  }

  function shiftMonth(offset) {
    const current = new Date(cachedState?.monthAnchor ?? new Date());
    current.setMonth(current.getMonth() + offset, 1);
    context.request("calendar.loadMonth", { month: current.toISOString() }).then((state) => {
      if (disposed) {
        return;
      }
      cachedState = state;
      loadingMonth = monthId(state.monthAnchor);
      draw(state);
    });
  }

  function draw(state) {
    const showsSchedule = ["signed_in", "needs_reconnect", "restoring"].includes(state.connectionStatus);
    if (!showsSchedule) {
      setDetailMode("browse");
    }
    root.dataset.status = state.connectionStatus;
    scheduleEl.hidden = !showsSchedule;
    connectionEl.hidden = showsSchedule;
    monthEl.textContent = monthLabel(state.monthAnchor);
    loadStatusEl.textContent = state.loadStatus === "loading" ? localize(context.state, "読み込み中…", "Loading…") : "";
    drawGrid(state);
    if (detailMode === "browse") {
      drawDetail(state);
    }
    drawConnection(state);
  }

  function drawConnection(state) {
    const language = document.documentElement.lang === "en" ? "en" : "ja";
    const missing = state.connectionStatus === "missing_configuration";
    connectionTitleEl.textContent = missing
      ? (language === "en" ? "OAuth setup required" : "OAuth 設定が必要です")
      : "Google Calendar";
    connectionMessageEl.textContent = state.message ?? "";
    authButton.disabled = state.connectionStatus === "signing_in" || state.loadStatus === "loading" || missing;
    authButton.textContent = state.connectionStatus === "signing_in"
      ? (language === "en" ? "Connecting…" : "接続中…")
      : (language === "en" ? "Connect" : "接続");
    setupEl.replaceChildren();
    if (missing) {
      setupEl.append(setupCard(state));
    }
  }

  function drawGrid(state) {
    gridEl.replaceChildren();
    for (const weekday of weekdayLabels()) {
      const label = document.createElement("div");
      label.className = "hp-calendar-weekday";
      label.textContent = weekday;
      gridEl.append(label);
    }

    for (const cell of state.dayCells ?? []) {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "hp-calendar-day";
      button.classList.toggle("is-outside", !cell.isInDisplayedMonth);
      button.classList.toggle("is-today", Boolean(cell.isToday));
      button.classList.toggle("is-selected", Boolean(cell.isSelected));
      button.title = dayLabel(cell.date);

      const dayNumber = document.createElement("span");
      dayNumber.className = "hp-calendar-day-number";
      dayNumber.textContent = String(cell.dayNumber);
      const dots = document.createElement("span");
      dots.className = "hp-calendar-event-dots";
      for (const event of (cell.events ?? []).slice(0, 3)) {
        const dot = document.createElement("i");
        dot.style.setProperty("--calendar-color", normalizeColor(event.calendarColorHex));
        dots.append(dot);
      }
      button.append(dayNumber, dots);
      button.addEventListener("mouseenter", () => {
        if (detailMode === "browse") {
          drawDayDetail(cell.date, cell.events ?? [], state);
        }
      });
      button.addEventListener("mouseleave", () => {
        if (detailMode === "browse") {
          drawDetail(cachedState ?? state);
        }
      });
      button.addEventListener("click", () => {
        context.request("calendar.selectDate", { date: cell.date }).then((next) => {
          if (!disposed) {
            cachedState = next;
            draw(next);
          }
        });
      });
      button.addEventListener("dblclick", () => openNewEditor(cell.date));
      gridEl.append(button);
    }
  }

  function drawDetail(state) {
    drawDayDetail(
      state.selectedDate ?? new Date().toISOString(),
      state.selectedEvents ?? [],
      state,
    );
  }

  function drawDayDetail(date, events, state) {
    if (detailMode !== "browse") {
      return;
    }
    detailEl.replaceChildren();
    const header = document.createElement("header");
    header.className = "hp-calendar-detail-header";
    const heading = document.createElement("div");
    heading.innerHTML = `
      <strong>${escapeHtml(dayLabel(date))}</strong>
      <span>${escapeHtml(updatedLabel(state.updatedAt))}</span>
    `;
    const add = iconButton("+", localize(context.state, "予定を追加", "New event"));
    add.disabled = state.connectionStatus !== "signed_in" || !(state.sources ?? []).some((source) => source.canWrite);
    add.addEventListener("click", () => openNewEditor(date));
    header.append(heading, add);
    detailEl.append(header);

    if (state.message && state.connectionStatus === "needs_reconnect") {
      const notice = document.createElement("div");
      notice.className = "hp-calendar-notice";
      notice.textContent = state.message;
      detailEl.append(notice);
    }

    const eventList = document.createElement("div");
    eventList.className = "hp-calendar-events";
    if (!events.length) {
      const empty = document.createElement("div");
      empty.className = "hp-calendar-empty";
      empty.innerHTML = `<span aria-hidden="true">▧</span><strong>${localize(context.state, "予定なし", "No events")}</strong>`;
      eventList.append(empty);
    } else {
      for (const event of events) {
        eventList.append(eventRow(event));
      }
    }
    detailEl.append(eventList);

    const footer = document.createElement("footer");
    footer.className = "hp-calendar-detail-footer";
    const status = document.createElement("span");
    status.textContent = state.loadStatus === "failed" ? state.message ?? "" : "";
    const disconnect = document.createElement("button");
    disconnect.type = "button";
    disconnect.textContent = document.documentElement.lang === "en" ? "Disconnect" : "接続解除";
    disconnect.addEventListener("click", () => authButton.click());
    footer.append(status, disconnect);
    detailEl.append(footer);
  }

  function eventRow(event) {
    const row = document.createElement("button");
    row.type = "button";
    row.className = `hp-calendar-event${event.calendarCanWrite ? "" : " is-readonly"}`;
    row.style.setProperty("--calendar-color", normalizeColor(event.calendarColorHex));
    row.innerHTML = `
      <i aria-hidden="true"></i>
      <span>
        <b>${escapeHtml(event.title ?? localize(context.state, "予定あり", "Busy"))}</b>
        <small>${event.isAllDay ? localize(context.state, "終日", "All-day") : `${timeLabel(event.start)}–${timeLabel(event.end)}`}</small>
      </span>
    `;
    row.disabled = !event.calendarCanWrite;
    row.addEventListener("click", () => openEditor(event));
    return row;
  }

  function openNewEditor(date) {
    if (cachedState?.connectionStatus !== "signed_in") {
      return;
    }
    setDetailMode("editor");
    context.request("calendar.createDefaultDraft", { date }).then((result) => {
      if (!disposed && result?.draft) {
        detailEl.replaceChildren(editor(result.draft, null));
      }
    }).catch(() => {
      setDetailMode("browse");
      drawDetail(cachedState ?? emptyState());
    });
  }

  function openEditor(event) {
    if (!event.calendarCanWrite) {
      return;
    }
    setDetailMode("editor");
    const draft = {
      calendarId: event.calendarId,
      eventId: event.googleEventId,
      title: event.title,
      location: event.location ?? "",
      notes: event.notes ?? "",
      start: event.start,
      end: event.end,
      isAllDay: event.isAllDay,
    };
    detailEl.replaceChildren(editor(draft, event));
  }

  function editor(draft, event) {
    const form = document.createElement("form");
    form.className = "hp-calendar-editor";
    const canWrite = event?.calendarCanWrite !== false;
    form.innerHTML = `
      <header><strong>${event ? localize(context.state, "予定を編集", "Edit event") : localize(context.state, "予定を追加", "New event")}</strong></header>
      <input data-title value="${escapeAttribute(draft.title ?? "")}" placeholder="${localize(context.state, "タイトル", "Title")}" ${canWrite ? "" : "disabled"}>
      <select data-calendar ${canWrite && !event ? "" : "disabled"}></select>
      <label><input data-allday type="checkbox" ${draft.isAllDay ? "checked" : ""} ${canWrite ? "" : "disabled"}> ${localize(context.state, "終日", "All-day")}</label>
      <input data-start type="datetime-local" value="${toLocalInput(draft.start)}" ${canWrite ? "" : "disabled"}>
      <input data-end type="datetime-local" value="${toLocalInput(draft.end)}" ${canWrite ? "" : "disabled"}>
      <input data-location value="${escapeAttribute(draft.location ?? "")}" placeholder="${localize(context.state, "場所", "Location")}" ${canWrite ? "" : "disabled"}>
      <textarea data-notes placeholder="${localize(context.state, "メモ", "Notes")}" ${canWrite ? "" : "disabled"}>${escapeHtml(draft.notes ?? "")}</textarea>
      <div class="hp-calendar-editor-actions">
        <button type="submit" ${canWrite ? "" : "disabled"}>${localize(context.state, "保存", "Save")}</button>
        ${event ? `<button type="button" data-delete ${canWrite ? "" : "disabled"}>${localize(context.state, "削除", "Delete")}</button>` : ""}
        <button type="button" data-cancel>${localize(context.state, "キャンセル", "Cancel")}</button>
      </div>
    `;
    const calendarSelect = form.querySelector("[data-calendar]");
    for (const source of cachedState?.sources ?? []) {
      if (!source.canWrite && !event) {
        continue;
      }
      const option = document.createElement("option");
      option.value = source.id;
      option.textContent = source.title;
      option.disabled = !source.canWrite;
      option.selected = source.id === draft.calendarId;
      calendarSelect.append(option);
    }
    queueMicrotask(() => {
      const titleInput = form.querySelector("[data-title]");
      void context.request("panel.beginTextInput")
        .catch(() => null)
        .then(() => titleInput?.focus({ preventScroll: true }));
    });
    form.addEventListener("submit", (submitEvent) => {
      submitEvent.preventDefault();
      const nextDraft = readDraft(form, draft);
      const method = nextDraft.eventId ? "calendar.updateEvent" : "calendar.createEvent";
      context.request(method, { draft: nextDraft }).then((state) => {
        if (!disposed) {
          cachedState = state;
          setDetailMode("browse");
          void context.request("panel.endTextInput").catch(() => {});
          draw(state);
        }
      });
    });
    form.querySelector("[data-cancel]").addEventListener("click", () => {
      void context.request("panel.endTextInput").catch(() => {});
      setDetailMode("browse");
      drawDetail(cachedState ?? emptyState());
    });
    const deleteButton = form.querySelector("[data-delete]");
    if (deleteButton) {
      deleteButton.addEventListener("click", () => {
        if (!confirm(localize(context.state, "この予定を削除しますか？", "Delete this event?"))) {
          return;
        }
        context.request("calendar.deleteEvent", {
          calendarId: draft.calendarId,
          eventId: draft.eventId,
        }).then((state) => {
          if (!disposed) {
            cachedState = state;
            setDetailMode("browse");
            void context.request("panel.endTextInput").catch(() => {});
            draw(state);
          }
        });
      });
    }
    return form;
  }

  function setDetailMode(mode) {
    detailMode = mode;
    root.dataset.detailMode = mode;
  }

  function readDraft(form, previous) {
    return {
      calendarId: form.querySelector("[data-calendar]").value || previous.calendarId,
      eventId: previous.eventId ?? null,
      title: form.querySelector("[data-title]").value,
      location: form.querySelector("[data-location]").value,
      notes: form.querySelector("[data-notes]").value,
      start: fromLocalInput(form.querySelector("[data-start]").value),
      end: fromLocalInput(form.querySelector("[data-end]").value),
      isAllDay: form.querySelector("[data-allday]").checked,
    };
  }

  function setupCard(state) {
    const card = document.createElement("div");
    card.className = "hp-calendar-setup";
    const language = document.documentElement.lang === "en" ? "en" : "ja";
    const steps = language === "en" ? state.setup?.en : state.setup?.ja;
    card.innerHTML = `
      <code>${escapeHtml(state.setup?.path ?? "")}</code>
      <ol>${(steps ?? []).map((step) => `<li>${escapeHtml(step)}</li>`).join("")}</ol>
    `;
    return card;
  }
}

function emptyState(message = "") {
  const today = new Date();
  const start = new Date(today.getFullYear(), today.getMonth(), 1);
  const first = new Date(start);
  first.setDate(start.getDate() - start.getDay());
  return {
    connectionStatus: "signed_out",
    loadStatus: "idle",
    message,
    monthAnchor: start.toISOString(),
    selectedDate: today.toISOString(),
    updatedAt: null,
    dayCells: Array.from({ length: 42 }, (_, index) => {
      const date = new Date(first);
      date.setDate(first.getDate() + index);
      return {
        id: date.toISOString().slice(0, 10),
        date: date.toISOString(),
        dayNumber: date.getDate(),
        isInDisplayedMonth: date.getMonth() === start.getMonth(),
        isToday: date.toDateString() === today.toDateString(),
        isSelected: date.toDateString() === today.toDateString(),
        events: [],
      };
    }),
    selectedEvents: [],
    sources: [],
  };
}

function iconButton(text, label) {
  const button = document.createElement("button");
  button.type = "button";
  button.className = "hp-calendar-icon-button";
  button.textContent = text;
  button.title = label;
  button.setAttribute("aria-label", label);
  return button;
}

function weekdayLabels() {
  return document.documentElement.lang === "en"
    ? ["S", "M", "T", "W", "T", "F", "S"]
    : ["日", "月", "火", "水", "木", "金", "土"];
}

function monthLabel(value) {
  return new Date(value).toLocaleDateString(locale(), { year: "numeric", month: "long" });
}

function dayLabel(value) {
  return new Date(value).toLocaleDateString(locale(), { month: "short", day: "numeric", weekday: "long" });
}

function updatedLabel(value) {
  if (!value) {
    return document.documentElement.lang === "en" ? "Not loaded" : "未読み込み";
  }
  const prefix = document.documentElement.lang === "en" ? "Updated" : "更新";
  return `${prefix} ${timeLabel(value)}`;
}

function timeLabel(value) {
  return new Date(value).toLocaleTimeString(locale(), { hour: "2-digit", minute: "2-digit" });
}

function locale() {
  return document.documentElement.lang === "en" ? "en-US" : "ja-JP";
}

function localize(state, ja, en) {
  return state?.settings?.language === "en" || document.documentElement.lang === "en" ? en : ja;
}

function toLocalInput(value) {
  const date = new Date(value);
  date.setMinutes(date.getMinutes() - date.getTimezoneOffset());
  return date.toISOString().slice(0, 16);
}

function fromLocalInput(value) {
  return new Date(value).toISOString();
}

function monthId(value) {
  return new Date(value).toISOString().slice(0, 7);
}

function normalizeColor(value) {
  const color = String(value ?? "").trim();
  const normalized = color.startsWith("#") ? color : `#${color}`;
  return /^#[0-9a-f]{6}$/i.test(normalized) ? normalized : "#63d6b5";
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function escapeAttribute(value) {
  return escapeHtml(value).replaceAll("'", "&#39;");
}

function ensureStyle(href) {
  if (document.querySelector(`link[href="${href}"]`)) {
    return;
  }
  const link = document.createElement("link");
  link.rel = "stylesheet";
  link.href = href;
  document.head.append(link);
}
