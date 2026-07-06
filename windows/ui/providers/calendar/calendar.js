const styleHref = "./providers/calendar/calendar.css";

let cachedState = null;
let loadingMonth = "";

export function renderCalendarProvider(context) {
  ensureStyle(styleHref);
  const root = document.createElement("section");
  root.className = "hp-calendar";
  root.innerHTML = `
    <header class="hp-calendar-toolbar">
      <button type="button" data-prev aria-label="Previous month">‹</button>
      <strong data-month></strong>
      <button type="button" data-next aria-label="Next month">›</button>
      <span data-status></span>
      <button type="button" data-auth></button>
    </header>
    <div class="hp-calendar-body">
      <section class="hp-calendar-grid" data-grid></section>
      <aside class="hp-calendar-side" data-side></aside>
    </div>
  `;
  context.container.append(root);

  const monthEl = root.querySelector("[data-month]");
  const statusEl = root.querySelector("[data-status]");
  const authButton = root.querySelector("[data-auth]");
  const gridEl = root.querySelector("[data-grid]");
  const sideEl = root.querySelector("[data-side]");

  root.querySelector("[data-prev]").addEventListener("click", () => shiftMonth(-1));
  root.querySelector("[data-next]").addEventListener("click", () => shiftMonth(1));
  authButton.addEventListener("click", () => {
    const method = cachedState?.connectionStatus === "signed_in" ? "calendar.signOut" : "calendar.signIn";
    authButton.disabled = true;
    context.request(method).then((state) => {
      cachedState = state;
      draw(state);
      maybeLoadMonth();
    }).catch(() => {
      authButton.disabled = false;
    });
  });

  draw(cachedState ?? emptyState());
  context.request("calendar.getState").then((state) => {
    cachedState = state;
    draw(state);
    maybeLoadMonth();
  }).catch(() => draw(emptyState("Calendar bridge unavailable")));

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
    context.request("calendar.loadMonth", { month: cachedState.monthAnchor }).then((state) => {
      cachedState = state;
      loadingMonth = monthId(state.monthAnchor);
      draw(state);
    }).catch(() => {
      loadingMonth = "";
    });
  }

  function shiftMonth(offset) {
    const current = new Date(cachedState?.monthAnchor ?? new Date());
    current.setMonth(current.getMonth() + offset, 1);
    context.request("calendar.loadMonth", { month: current.toISOString() }).then((state) => {
      cachedState = state;
      loadingMonth = monthId(state.monthAnchor);
      draw(state);
    });
  }

  function draw(state) {
    monthEl.textContent = monthLabel(state.monthAnchor);
    statusEl.textContent = state.message ?? "";
    authButton.disabled = state.connectionStatus === "signing_in" || state.loadStatus === "loading";
    authButton.textContent = state.connectionStatus === "signed_in" ? "Disconnect" : "Connect";
    root.dataset.status = state.connectionStatus;
    drawGrid(state);
    drawSide(state);
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
      button.classList.toggle("has-events", Boolean(cell.events?.length));
      button.innerHTML = `
        <span>${cell.dayNumber}</span>
        <i>${cell.events?.length ? cell.events.length : ""}</i>
      `;
      button.addEventListener("mouseenter", () => drawPreview(cell));
      button.addEventListener("mouseleave", () => drawSide(cachedState ?? state));
      button.addEventListener("click", () => {
        context.request("calendar.selectDate", { date: cell.date }).then((next) => {
          cachedState = next;
          draw(next);
        });
      });
      button.addEventListener("dblclick", () => openNewEditor(cell.date));
      gridEl.append(button);
    }
  }

  function drawSide(state) {
    sideEl.replaceChildren();
    if (state.connectionStatus === "missing_configuration") {
      sideEl.append(setupCard(state));
      return;
    }

    const selectedDate = state.selectedDate ?? new Date().toISOString();
    const title = document.createElement("div");
    title.className = "hp-calendar-side-title";
    title.textContent = dayLabel(selectedDate);
    sideEl.append(title);

    const events = state.selectedEvents ?? [];
    if (!events.length) {
      const empty = document.createElement("div");
      empty.className = "hp-calendar-empty";
      empty.textContent = "No events";
      sideEl.append(empty);
    } else {
      for (const event of events) {
        sideEl.append(eventRow(event));
      }
    }

    const add = document.createElement("button");
    add.className = "hp-calendar-add";
    add.type = "button";
    add.textContent = "+";
    add.title = "New event";
    add.setAttribute("aria-label", "New event");
    add.disabled = state.connectionStatus !== "signed_in";
    add.addEventListener("click", () => openNewEditor(selectedDate));
    sideEl.append(add);
  }

  function drawPreview(cell) {
    sideEl.replaceChildren();
    const title = document.createElement("div");
    title.className = "hp-calendar-side-title";
    title.textContent = dayLabel(cell.date);
    sideEl.append(title);
    if (!cell.events?.length) {
      const empty = document.createElement("div");
      empty.className = "hp-calendar-empty";
      empty.textContent = "No events";
      sideEl.append(empty);
      return;
    }
    for (const event of cell.events) {
      sideEl.append(eventRow(event));
    }
  }

  function eventRow(event) {
    const row = document.createElement("button");
    row.type = "button";
    row.className = `hp-calendar-event${event.calendarCanWrite ? "" : " is-readonly"}`;
    row.innerHTML = `
      <b>${escapeHtml(event.title ?? "Busy")}</b>
      <span>${event.isAllDay ? "All-day" : `${timeLabel(event.start)}-${timeLabel(event.end)}`}</span>
    `;
    row.addEventListener("click", () => openEditor(event));
    return row;
  }

  function openNewEditor(date) {
    context.request("calendar.createDefaultDraft", { date }).then((result) => {
      if (result?.draft) {
        sideEl.replaceChildren(editor(result.draft, null));
      }
    });
  }

  function openEditor(event) {
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
    sideEl.replaceChildren(editor(draft, event));
  }

  function editor(draft, event) {
    const form = document.createElement("form");
    form.className = "hp-calendar-editor";
    const canWrite = event?.calendarCanWrite !== false;
    form.innerHTML = `
      <input data-title value="${escapeAttribute(draft.title ?? "")}" placeholder="Title" ${canWrite ? "" : "disabled"}>
      <select data-calendar ${canWrite && !event ? "" : "disabled"}></select>
      <label><input data-allday type="checkbox" ${draft.isAllDay ? "checked" : ""} ${canWrite ? "" : "disabled"}> All-day</label>
      <input data-start type="datetime-local" value="${toLocalInput(draft.start)}" ${canWrite ? "" : "disabled"}>
      <input data-end type="datetime-local" value="${toLocalInput(draft.end)}" ${canWrite ? "" : "disabled"}>
      <input data-location value="${escapeAttribute(draft.location ?? "")}" placeholder="Location" ${canWrite ? "" : "disabled"}>
      <textarea data-notes placeholder="Notes" ${canWrite ? "" : "disabled"}>${escapeHtml(draft.notes ?? "")}</textarea>
      <div>
        <button type="submit" ${canWrite ? "" : "disabled"}>Save</button>
        ${event ? `<button type="button" data-delete ${canWrite ? "" : "disabled"}>Delete</button>` : ""}
        <button type="button" data-cancel>Cancel</button>
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
    form.addEventListener("submit", (submitEvent) => {
      submitEvent.preventDefault();
      const nextDraft = readDraft(form, draft);
      const method = nextDraft.eventId ? "calendar.updateEvent" : "calendar.createEvent";
      context.request(method, { draft: nextDraft }).then((state) => {
        cachedState = state;
        draw(state);
      });
    });
    form.querySelector("[data-cancel]").addEventListener("click", () => drawSide(cachedState ?? emptyState()));
    const deleteButton = form.querySelector("[data-delete]");
    if (deleteButton) {
      deleteButton.addEventListener("click", () => {
        if (!confirm("Delete this event?")) {
          return;
        }
        context.request("calendar.deleteEvent", {
          calendarId: draft.calendarId,
          eventId: draft.eventId,
        }).then((state) => {
          cachedState = state;
          draw(state);
        });
      });
    }
    return form;
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
      <strong>${language === "en" ? "OAuth setup required" : "OAuth 設定が必要です"}</strong>
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

function weekdayLabels() {
  return ["S", "M", "T", "W", "T", "F", "S"];
}

function monthLabel(value) {
  return new Date(value).toLocaleDateString(undefined, { year: "numeric", month: "short" });
}

function dayLabel(value) {
  return new Date(value).toLocaleDateString(undefined, { month: "short", day: "numeric", weekday: "short" });
}

function timeLabel(value) {
  return new Date(value).toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" });
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
