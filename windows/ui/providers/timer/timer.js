const styleHref = "./providers/timer/timer.css";
const colors = ["blue", "green", "orange", "pink"];
let tickHandle = 0;

/**
 * @param {{ container: Element, request: (method: string, params?: unknown) => Promise<any> }} context
 */
export function renderTimerProvider(context) {
  ensureStyle(styleHref);
  clearInterval(tickHandle);
  const root = document.createElement("section");
  root.className = "hp-timer";
  root.innerHTML = `<div class="hp-timer-stack" data-stack></div>`;
  context.container.append(root);
  load();

  async function load() {
    try {
      draw(await context.request("timer.getState"));
    } catch (error) {
      root.querySelector("[data-stack]").innerHTML = `<div class="hp-timer-empty">Timer bridge unavailable</div>`;
    }
  }

  /**
   * @param {any} state
   */
  function draw(state) {
    if (!root.isConnected) {
      return;
    }

    root.querySelector("[data-stack]").replaceChildren(
      runningSection(state),
      pinnedSection(state),
      entryCard("timer", state.draftTimer, state.canStartTimer),
      entryCard("pomodoro", state.draftPomodoro, state.canStartTimer),
    );

    tickHandle = window.setInterval(() => updateRemaining(root), 1000);
    updateRemaining(root);
  }

  /**
   * @param {any} state
   */
  function runningSection(state) {
    const section = sectionShell("Running");
    if (state.activeAlert) {
      section.body.append(alertRow(state.activeAlert));
    }
    if (!state.runningTimers?.length && !state.activeAlert) {
      section.body.append(emptyRow("No running timers"));
    } else {
      for (const timer of state.runningTimers ?? []) {
        section.body.append(runningRow(timer));
      }
    }
    return section.root;
  }

  /**
   * @param {any} state
   */
  function pinnedSection(state) {
    const section = sectionShell("Pinned");
    const presets = state.pinnedPresets ?? [];
    if (!presets.length) {
      section.body.append(emptyRow("No pinned presets"));
      return section.root;
    }

    for (const preset of presets) {
      const row = document.createElement("div");
      row.className = `hp-timer-pinned is-${preset.color}`;
      row.innerHTML = `
        <div>
          <strong>${escapeHtml(preset.title || (preset.isPomodoro ? "Pomodoro" : "Timer"))}</strong>
          <span>${escapeHtml(presetText(preset))}</span>
        </div>
        <button type="button" data-start>▶</button>
        <button type="button" data-remove>⌫</button>
      `;
      row.querySelector("[data-start]").addEventListener("click", () => mutate("timer.start", {
        preset,
        pinnedPresetId: preset.id,
      }));
      row.querySelector("[data-remove]").addEventListener("click", () => mutate("timer.removePinnedPreset", { id: preset.id }));
      section.body.append(row);
    }

    return section.root;
  }

  /**
   * @param {any} timer
   */
  function runningRow(timer) {
    const row = document.createElement("div");
    row.className = `hp-timer-running is-${timer.color}${timer.isPaused ? " is-paused" : ""}`;
    row.dataset.endAt = timer.endAtUtc;
    row.dataset.pausedRemaining = timer.pausedRemainingSeconds ?? "";
    row.dataset.phaseDuration = timer.phaseDurationSeconds;
    row.innerHTML = `
      <div class="hp-timer-ring"><span data-progress></span></div>
      <div class="hp-timer-main">
        <strong>${escapeHtml(timer.title || (timer.isPomodoro ? "Pomodoro" : "Timer"))}</strong>
        <span><b data-remaining>${timeText(timer.remainingSeconds)}</b>${timer.isPomodoro ? ` · ${phaseText(timer)}` : ""}</span>
      </div>
      <button type="button" data-pause>${timer.isPaused ? "▶" : "Ⅱ"}</button>
      <button type="button" data-stop>■</button>
      <button type="button" data-pin>${timer.pinnedPresetId ? "◆" : "◇"}</button>
    `;
    row.querySelector("[data-pause]").addEventListener("click", () => mutate(timer.isPaused ? "timer.resume" : "timer.pause", { id: timer.id }));
    row.querySelector("[data-stop]").addEventListener("click", () => mutate("timer.stop", { id: timer.id }));
    row.querySelector("[data-pin]").addEventListener("click", () => mutate("timer.togglePin", { id: timer.id }));
    return row;
  }

  /**
   * @param {any} alert
   */
  function alertRow(alert) {
    const row = document.createElement("div");
    row.className = `hp-timer-alert is-${alert.color}`;
    row.innerHTML = `
      <div>
        <strong>${escapeHtml(alert.title || "Finished")}</strong>
        <span>Finished</span>
      </div>
      <button type="button" data-stop-alert>Stop</button>
    `;
    row.querySelector("[data-stop-alert]").addEventListener("click", () => mutate("timer.stopAlert"));
    return row;
  }

  /**
   * @param {"timer" | "pomodoro"} kind
   * @param {any} preset
   * @param {boolean} canStart
   */
  function entryCard(kind, preset, canStart) {
    const card = sectionShell(kind === "pomodoro" ? "Pomodoro" : "Timer");
    const form = document.createElement("div");
    form.className = `hp-timer-entry is-${preset.color}${kind === "pomodoro" ? " is-pomodoro" : ""}`;
    form.innerHTML = `
      <div class="hp-timer-entry-head">
        <div class="hp-timer-colors">${colors.map((color) => `<button class="is-${color}" type="button" data-color="${color}" aria-label="${color}"></button>`).join("")}</div>
        <input data-title type="text" value="${escapeAttribute(preset.title ?? "")}" placeholder="Title">
        <button type="button" data-sound>${preset.soundEnabled ? "♪" : "×"}</button>
      </div>
      <div class="hp-timer-duration-row">
        ${kind === "pomodoro"
          ? `${durationEditor("work", preset.workDurationSeconds)}${durationEditor("rest", preset.restDurationSeconds)}`
          : durationEditor("duration", preset.durationSeconds)}
        <button class="hp-timer-start" type="button" data-start ${canStart ? "" : "disabled"}>▶</button>
        <button class="hp-timer-pin" type="button" data-pin>◆</button>
      </div>
    `;
    for (const colorButton of form.querySelectorAll("[data-color]")) {
      colorButton.toggleAttribute("aria-pressed", colorButton.dataset.color === preset.color);
      colorButton.addEventListener("click", () => updatePreset({ color: colorButton.dataset.color }));
    }
    form.querySelector("[data-title]").addEventListener("change", (event) => updatePreset({ title: event.target.value }));
    form.querySelector("[data-sound]").addEventListener("click", () => updatePreset({ soundEnabled: !preset.soundEnabled }));
    form.querySelector("[data-start]").addEventListener("click", () => mutate("timer.start", { preset }));
    form.querySelector("[data-pin]").addEventListener("click", () => mutate("timer.pinPreset", { preset }));
    for (const input of form.querySelectorAll("[data-duration-field]")) {
      input.addEventListener("change", () => updatePreset(readDurationPatch(form, kind)));
    }
    for (const rail of form.querySelectorAll("[data-duration-rail]")) {
      rail.addEventListener("input", () => updatePreset(readDurationPatch(form, kind)));
    }
    card.body.append(form);
    return card.root;

    /**
     * @param {Partial<any>} patch
     */
    function updatePreset(patch) {
      const next = { ...preset, ...patch };
      mutate("timer.updateDraft", { kind, preset: next });
    }
  }

  /**
   * @param {string} method
   * @param {unknown=} params
   */
  async function mutate(method, params = undefined) {
    const next = await context.request(method, params);
    draw(next);
  }
}

function updateRemaining(root) {
  const now = Date.now();
  for (const row of root.querySelectorAll(".hp-timer-running")) {
    const pausedRaw = row.dataset.pausedRemaining ?? "";
    const phaseDuration = Number(row.dataset.phaseDuration) || 1;
    const end = Date.parse(row.dataset.endAt ?? "");
    const remaining = pausedRaw !== "" ? Number(pausedRaw) : Math.max(0, (end - now) / 1000);
    row.querySelector("[data-remaining]").textContent = timeText(remaining);
    row.querySelector("[data-progress]").style.transform = `scaleX(${Math.max(0, Math.min(1, 1 - remaining / phaseDuration))})`;
  }
}

function sectionShell(title) {
  const root = document.createElement("section");
  root.className = "hp-timer-section";
  root.innerHTML = `<h2>${title}</h2><div class="hp-timer-section-body"></div>`;
  return { root, body: root.querySelector(".hp-timer-section-body") };
}

function emptyRow(message) {
  const row = document.createElement("div");
  row.className = "hp-timer-empty";
  row.textContent = message;
  return row;
}

function durationEditor(name, value) {
  const total = Math.max(0, Math.round(value ?? 0));
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const seconds = total % 60;
  return `
    <div class="hp-timer-duration" data-duration="${name}">
      <input data-duration-field="hours" inputmode="numeric" value="${pad(hours)}" aria-label="${name} hours">
      <span>:</span>
      <input data-duration-field="minutes" inputmode="numeric" value="${pad(minutes)}" aria-label="${name} minutes">
      <span>:</span>
      <input data-duration-field="seconds" inputmode="numeric" value="${pad(seconds)}" aria-label="${name} seconds">
      <input data-duration-rail type="range" min="0" max="86399" step="60" value="${total}" aria-label="${name} adjustment">
    </div>
  `;
}

function readDurationPatch(form, kind) {
  const patch = {};
  for (const group of form.querySelectorAll("[data-duration]")) {
    const name = group.dataset.duration;
    const rail = group.querySelector("[data-duration-rail]");
    let seconds = Number(rail.value);
    if (document.activeElement !== rail) {
      const hours = Number(group.querySelector('[data-duration-field="hours"]').value) || 0;
      const minutes = Number(group.querySelector('[data-duration-field="minutes"]').value) || 0;
      const secs = Number(group.querySelector('[data-duration-field="seconds"]').value) || 0;
      seconds = Math.max(0, Math.min(86399, hours * 3600 + minutes * 60 + secs));
      rail.value = String(seconds);
    }
    if (kind === "pomodoro" && name === "work") {
      patch.workDurationSeconds = seconds;
    } else if (kind === "pomodoro" && name === "rest") {
      patch.restDurationSeconds = seconds;
    } else {
      patch.durationSeconds = seconds;
    }
  }
  return patch;
}

function presetText(preset) {
  if (preset.isPomodoro) {
    return `${timeText(preset.workDurationSeconds)} / ${timeText(preset.restDurationSeconds)}`;
  }
  return timeText(preset.durationSeconds);
}

function phaseText(timer) {
  return `${timer.phase === "work" ? "Work" : "Rest"} ${timer.completedWorkCycles + (timer.phase === "work" ? 1 : 0)}`;
}

function timeText(seconds) {
  const total = Math.max(0, Math.round(seconds ?? 0));
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const secs = total % 60;
  return hours > 0 ? `${hours}:${pad(minutes)}:${pad(secs)}` : `${pad(minutes)}:${pad(secs)}`;
}

function pad(value) {
  return String(Math.max(0, Math.min(99, value))).padStart(2, "0");
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
