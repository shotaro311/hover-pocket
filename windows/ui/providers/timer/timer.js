const styleHref = "./providers/timer/timer.css";
const colors = ["blue", "green", "orange", "pink"];

/**
 * @param {{ container: Element, request: (method: string, params?: unknown) => Promise<any> }} context
 */
export function renderTimerProvider(context) {
  ensureStyle(styleHref);
  let tickHandle = 0;
  const root = document.createElement("section");
  root.className = "hp-timer";
  root.innerHTML = `<div class="hp-timer-stack" data-stack></div>`;
  context.container.append(root);
  load();

  async function load() {
    try {
      draw(await context.request("timer.getState"));
    } catch (error) {
      root.querySelector("[data-stack]").innerHTML = `<div class="hp-timer-empty">${tx(context.state, "タイマーを読み込めません。", "Timer bridge unavailable")}</div>`;
    }
  }

  /**
   * @param {any} state
   */
  function draw(state) {
    if (!root.isConnected) {
      return;
    }

    window.clearInterval(tickHandle);
    const sections = [runningSection(state)];
    if (state.pinnedPresets?.length) {
      sections.push(pinnedSection(state));
    }
    sections.push(
      entryCard("timer", state.draftTimer, state.canStartTimer),
      entryCard("pomodoro", state.draftPomodoro, state.canStartTimer),
    );
    root.querySelector("[data-stack]").replaceChildren(...sections);

    tickHandle = window.setInterval(() => updateRemaining(root), 1000);
    updateRemaining(root);
  }

  /**
   * @param {any} state
   */
  function runningSection(state) {
    const section = sectionShell(tx(context.state, "実行中", "Running"), "running");
    if (state.activeAlert) {
      section.body.append(alertRow(state.activeAlert));
    }
    if (!state.runningTimers?.length && !state.activeAlert) {
      section.body.append(emptyRow(tx(context.state, "実行中のタイマーはありません", "No running timers")));
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
    const section = sectionShell(tx(context.state, "プリセット", "Pinned"), "pinned");
    const presets = state.pinnedPresets ?? [];
    if (!presets.length) {
      section.body.append(emptyRow(tx(context.state, "保存したプリセットはありません", "No pinned presets")));
      return section.root;
    }

    for (const preset of presets) {
      const row = document.createElement("div");
      row.className = `hp-timer-pinned is-${preset.color}`;
      row.innerHTML = `
        <div>
          <strong>${escapeHtml(preset.title || (preset.isPomodoro ? tx(context.state, "ポモドーロ", "Pomodoro") : tx(context.state, "タイマー", "Timer")))}</strong>
          <span>${escapeHtml(presetText(preset))}</span>
        </div>
        <button type="button" data-start title="${tx(context.state, "開始", "Start")}" aria-label="${tx(context.state, "開始", "Start")}">▶</button>
        <button type="button" data-remove title="${tx(context.state, "削除", "Remove")}" aria-label="${tx(context.state, "削除", "Remove")}">⌫</button>
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
        <strong>${escapeHtml(timer.title || (timer.isPomodoro ? tx(context.state, "ポモドーロ", "Pomodoro") : tx(context.state, "タイマー", "Timer")))}</strong>
        <span><b data-remaining>${timeText(timer.remainingSeconds)}</b>${timer.isPomodoro ? ` · ${phaseText(timer, context.state)}` : ""}</span>
      </div>
      <button type="button" data-pause title="${timer.isPaused ? tx(context.state, "再開", "Resume") : tx(context.state, "一時停止", "Pause")}">${timer.isPaused ? "▶" : "Ⅱ"}</button>
      <button type="button" data-stop title="${tx(context.state, "停止", "Stop")}">■</button>
      <button type="button" data-pin title="${tx(context.state, "プリセットに保存", "Pin preset")}">${timer.pinnedPresetId ? "◆" : "◇"}</button>
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
        <strong>${escapeHtml(alert.title || tx(context.state, "完了", "Finished"))}</strong>
        <span>${tx(context.state, "タイマーが終了しました", "Finished")}</span>
      </div>
      <button type="button" data-stop-alert>${tx(context.state, "止める", "Stop")}</button>
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
    const card = sectionShell(
      kind === "pomodoro" ? tx(context.state, "ポモドーロ", "Pomodoro") : tx(context.state, "タイマー", "Timer"),
      kind,
    );
    const form = document.createElement("div");
    form.className = `hp-timer-entry is-${preset.color}${kind === "pomodoro" ? " is-pomodoro" : ""}`;
    const hasDuration = kind === "pomodoro"
      ? Number(preset.workDurationSeconds) > 0
      : Number(preset.durationSeconds) > 0;
    const canStartPreset = canStart && hasDuration;
    form.innerHTML = `
      <div class="hp-timer-entry-head">
        <div class="hp-timer-colors">${colors.map((color) => `<button class="is-${color}" type="button" data-color="${color}" aria-label="${colorName(color, context.state)}"></button>`).join("")}</div>
        <input data-title type="text" maxlength="40" value="${escapeAttribute(preset.title ?? "")}" placeholder="${tx(context.state, "タイトル", "Title")}">
        <button type="button" data-sound title="${tx(context.state, "通知音", "Alert sound")}">${preset.soundEnabled ? "♪" : "×"}</button>
      </div>
      <div class="hp-timer-entry-body">
        <div class="hp-timer-duration-grid">
          ${kind === "pomodoro"
            ? `${durationEditor("work", preset.workDurationSeconds, context.state)}${durationEditor("rest", preset.restDurationSeconds, context.state)}`
            : durationEditor("duration", preset.durationSeconds, context.state)}
        </div>
        <div class="hp-timer-entry-actions">
          <button class="hp-timer-start" type="button" data-start title="${tx(context.state, "開始", "Start")}" ${canStartPreset ? "" : "disabled"}><span aria-hidden="true">▶</span>${tx(context.state, "開始", "Start")}</button>
          <button class="hp-timer-pin" type="button" data-pin title="${tx(context.state, "プリセットに保存", "Pin preset")}" aria-label="${tx(context.state, "プリセットに保存", "Pin preset")}">◆</button>
        </div>
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
      rail.addEventListener("input", () => syncDurationFieldsFromRail(rail.closest("[data-duration]")));
      rail.addEventListener("change", () => updatePreset(readDurationPatch(form, kind)));
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

  return {
    refresh: load,
    dispose() {
      window.clearInterval(tickHandle);
    },
  };
}

function updateRemaining(root) {
  const now = Date.now();
  for (const row of root.querySelectorAll(".hp-timer-running")) {
    const pausedRaw = row.dataset.pausedRemaining ?? "";
    const phaseDuration = Number(row.dataset.phaseDuration) || 1;
    const end = Date.parse(row.dataset.endAt ?? "");
    const remaining = pausedRaw !== "" ? Number(pausedRaw) : Math.max(0, (end - now) / 1000);
    row.querySelector("[data-remaining]").textContent = timeText(remaining);
    const progress = Math.max(0, Math.min(1, 1 - remaining / phaseDuration));
    row.style.setProperty("--timer-progress", `${progress * 360}deg`);
    row.querySelector("[data-progress]").textContent = `${Math.round(progress * 100)}%`;
  }
}

function sectionShell(title, tone = "") {
  const root = document.createElement("section");
  root.className = `hp-timer-section${tone ? ` is-${tone}` : ""}`;
  root.innerHTML = `<h2>${title}</h2><div class="hp-timer-section-body"></div>`;
  return { root, body: root.querySelector(".hp-timer-section-body") };
}

function emptyRow(message) {
  const row = document.createElement("div");
  row.className = "hp-timer-empty";
  row.textContent = message;
  return row;
}

function durationEditor(name, value, state) {
  const total = Math.max(0, Math.round(value ?? 0));
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const seconds = total % 60;
  return `
    <div class="hp-timer-duration" data-duration="${name}">
      <strong class="hp-timer-duration-label">${durationLabel(name, state)}</strong>
      <input data-duration-field="hours" inputmode="numeric" value="${pad(hours)}" aria-label="${tx(state, "時間", "hours")}">
      <span>:</span>
      <input data-duration-field="minutes" inputmode="numeric" value="${pad(minutes)}" aria-label="${tx(state, "分", "minutes")}">
      <span>:</span>
      <input data-duration-field="seconds" inputmode="numeric" value="${pad(seconds)}" aria-label="${tx(state, "秒", "seconds")}">
      <input data-duration-rail type="range" min="0" max="86399" step="60" value="${total}" aria-label="${tx(state, "時間を調整", "Duration adjustment")}">
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

function syncDurationFieldsFromRail(group) {
  if (!group) {
    return;
  }
  const total = Math.max(0, Math.min(86399, Number(group.querySelector("[data-duration-rail]")?.value) || 0));
  group.querySelector('[data-duration-field="hours"]').value = pad(Math.floor(total / 3600));
  group.querySelector('[data-duration-field="minutes"]').value = pad(Math.floor((total % 3600) / 60));
  group.querySelector('[data-duration-field="seconds"]').value = pad(total % 60);
}

function presetText(preset) {
  if (preset.isPomodoro) {
    return `${timeText(preset.workDurationSeconds)} / ${timeText(preset.restDurationSeconds)}`;
  }
  return timeText(preset.durationSeconds);
}

function phaseText(timer, state) {
  return `${timer.phase === "work" ? tx(state, "集中", "Work") : tx(state, "休憩", "Rest")} ${timer.completedWorkCycles + (timer.phase === "work" ? 1 : 0)}`;
}

function durationLabel(name, state) {
  if (name === "work") {
    return tx(state, "集中", "Work");
  }
  if (name === "rest") {
    return tx(state, "休憩", "Rest");
  }
  return tx(state, "時間", "Duration");
}

function colorName(color, state) {
  const names = {
    blue: ["青", "Blue"],
    green: ["緑", "Green"],
    orange: ["オレンジ", "Orange"],
    pink: ["ピンク", "Pink"],
  };
  const value = names[color] ?? [color, color];
  return tx(state, value[0], value[1]);
}

function tx(state, ja, en) {
  return state?.settings?.language === "en" ? en : ja;
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
