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
    const sections = [runningSection(state), addSection(state)];
    if (state.pinnedPresets?.length) {
      sections.push(pinnedSection(state));
    }
    root.querySelector("[data-stack]").replaceChildren(...sections);

    tickHandle = window.setInterval(() => updateClocks(root), 50);
    updateClocks(root);
  }

  /**
   * @param {any} state
   */
  function runningSection(state) {
    const section = sectionShell(tx(context.state, "実行中", "Running"), "running");
    if (state.activeAlert) {
      section.body.append(alertRow(state.activeAlert));
    }
    for (const stopwatch of state.runningStopwatches ?? []) {
      section.body.append(stopwatchRow(stopwatch));
    }
    if (!state.runningTimers?.length && !state.runningStopwatches?.length && !state.activeAlert) {
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
  function stopwatchRow(stopwatch) {
    const row = document.createElement("div");
    row.className = `hp-stopwatch-row is-${stopwatch.color}`;
    row.dataset.stopwatch = "";
    row.dataset.accumulated = String(stopwatch.accumulatedSeconds ?? 0);
    row.dataset.startedAt = stopwatch.startedAtUtc ?? "";
    const isRunning = Boolean(stopwatch.isRunning);
    const elapsed = Number(stopwatch.elapsedSeconds) || 0;
    row.innerHTML = `
      ${typeIcon("stopwatch")}
      <strong class="hp-timer-kind">${tx(context.state, "ストップウォッチ", "Stopwatch")}</strong>
      <span class="hp-timer-divider" aria-hidden="true"></span>
      <span class="hp-timer-name">${escapeHtml(stopwatch.title || tx(context.state, "名前なし", "Untitled"))}</span>
      <b class="hp-stopwatch-time" data-stopwatch-elapsed>${stopwatchTimeText(elapsed)}</b>
      <button type="button" data-stopwatch-toggle title="${isRunning ? tx(context.state, "一時停止", "Pause") : tx(context.state, "再開", "Resume")}" aria-label="${isRunning ? tx(context.state, "一時停止", "Pause") : tx(context.state, "再開", "Resume")}">${isRunning ? "Ⅱ" : "▶"}</button>
      <button type="button" data-stopwatch-stop title="${tx(context.state, "停止", "Stop")}" aria-label="${tx(context.state, "停止", "Stop")}">■</button>
    `;
    row.querySelector("[data-stopwatch-toggle]").addEventListener("click", () => mutate(isRunning ? "timer.pauseStopwatch" : "timer.resumeStopwatch", { id: stopwatch.id }));
    row.querySelector("[data-stopwatch-stop]").addEventListener("click", () => mutate("timer.stopStopwatch", { id: stopwatch.id }));
    return row;
  }

  /**
   * @param {any} state
   */
  function addSection(state) {
    const section = sectionShell(tx(context.state, "新しく追加", "Add new"), "add");
    const grid = document.createElement("div");
    grid.className = "hp-timer-add-grid";
    grid.append(
      stopwatchEntryCard(state.draftStopwatch, state.canStartStopwatch),
      entryCard("timer", state.draftTimer, state.canStartTimer),
      entryCard("pomodoro", state.draftPomodoro, state.canStartTimer),
    );
    section.body.append(grid);
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
      ${typeIcon(timer.isPomodoro ? "pomodoro" : "timer")}
      <strong class="hp-timer-kind">${timer.isPomodoro ? tx(context.state, "ポモドーロ", "Pomodoro") : tx(context.state, "タイマー", "Timer")}</strong>
      <span class="hp-timer-divider" aria-hidden="true"></span>
      <span class="hp-timer-name">${escapeHtml(timer.title || tx(context.state, "名前なし", "Untitled"))}</span>
      ${timer.isPomodoro ? `<span class="hp-timer-phase">${phaseText(timer, context.state)}</span>` : ""}
      <b class="hp-timer-time" data-remaining>${timeText(timer.remainingSeconds)}</b>
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
   * @param {any} preset
   * @param {boolean} canStart
   */
  function stopwatchEntryCard(preset, canStart) {
    const form = document.createElement("div");
    form.className = `hp-timer-entry is-stopwatch is-${preset.color}`;
    form.innerHTML = `
      <div class="hp-timer-entry-head">
        ${colorMenu("stopwatch", preset.color)}
        <strong>${tx(context.state, "ストップウォッチ", "Stopwatch")}</strong>
      </div>
      <input data-title type="text" maxlength="40" value="${escapeAttribute(preset.title ?? "")}" placeholder="${tx(context.state, "名前を設定（任意）", "Set a name (optional)")}">
      <div class="hp-stopwatch-preview">00:00.00</div>
      <div class="hp-timer-entry-actions">
        <button class="hp-timer-reset" type="button" data-reset title="${tx(context.state, "リセット", "Reset")}">↺</button>
        <button class="hp-timer-start" type="button" data-start title="${tx(context.state, "開始", "Start")}" ${canStart ? "" : "disabled"}><span aria-hidden="true">▶</span>${tx(context.state, "開始", "Start")}</button>
      </div>
    `;
    bindColorMenu(form, (color) => updatePreset({ color }));
    form.querySelector("[data-title]").addEventListener("input", (event) => {
      preset.title = event.target.value;
    });
    form.querySelector("[data-title]").addEventListener("change", (event) => updatePreset({ title: event.target.value }));
    form.querySelector("[data-reset]").addEventListener("click", () => mutate("timer.updateStopwatchDraft", { preset: { title: "", color: "blue" } }));
    form.querySelector("[data-start]").addEventListener("click", () => mutate("timer.startStopwatch", {
      preset: {
        ...preset,
        title: form.querySelector("[data-title]").value,
      },
    }));
    return form;

    function updatePreset(patch) {
      mutate("timer.updateStopwatchDraft", { preset: { ...preset, ...patch } });
    }
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
    const form = document.createElement("div");
    form.className = `hp-timer-entry is-${kind} is-${preset.color}`;
    const hasDuration = kind === "pomodoro"
      ? Number(preset.workDurationSeconds) > 0
      : Number(preset.durationSeconds) > 0;
    const canStartPreset = canStart && hasDuration;
    form.innerHTML = `
      <div class="hp-timer-entry-head">
        ${colorMenu(kind, preset.color)}
        <strong>${kind === "pomodoro" ? tx(context.state, "ポモドーロ", "Pomodoro") : tx(context.state, "タイマー", "Timer")}</strong>
        <button type="button" data-sound title="${tx(context.state, "通知音", "Alert sound")}">${preset.soundEnabled ? "♪" : "×"}</button>
      </div>
      <input data-title type="text" maxlength="40" value="${escapeAttribute(preset.title ?? "")}" placeholder="${tx(context.state, "名前を設定（任意）", "Set a name (optional)")}">
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
    bindColorMenu(form, (color) => updatePreset({ color }));
    form.querySelector("[data-title]").addEventListener("input", (event) => {
      preset.title = event.target.value;
    });
    form.querySelector("[data-title]").addEventListener("change", (event) => updatePreset({ title: event.target.value }));
    form.querySelector("[data-sound]").addEventListener("click", () => updatePreset({ soundEnabled: !preset.soundEnabled }));
    form.querySelector("[data-start]").addEventListener("click", () => mutate("timer.start", {
      preset: livePreset(),
    }));
    form.querySelector("[data-pin]").addEventListener("click", () => mutate("timer.pinPreset", {
      preset: livePreset(),
    }));
    for (const input of form.querySelectorAll("[data-duration-field]")) {
      input.addEventListener("change", () => updatePreset(readDurationPatch(form, kind)));
    }
    for (const rail of form.querySelectorAll("[data-duration-rail]")) {
      rail.addEventListener("input", () => syncDurationFieldsFromRail(rail.closest("[data-duration]")));
      rail.addEventListener("change", () => updatePreset(readDurationPatch(form, kind)));
    }
    return form;

    /**
     * @param {Partial<any>} patch
     */
    function updatePreset(patch) {
      const next = { ...preset, ...patch };
      mutate("timer.updateDraft", { kind, preset: next });
    }

    function livePreset() {
      return {
        ...preset,
        title: form.querySelector("[data-title]").value,
        ...readDurationPatch(form, kind),
      };
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

function updateClocks(root) {
  const now = Date.now();
  for (const row of root.querySelectorAll(".hp-timer-running")) {
    const pausedRaw = row.dataset.pausedRemaining ?? "";
    const end = Date.parse(row.dataset.endAt ?? "");
    const remaining = pausedRaw !== "" ? Number(pausedRaw) : Math.max(0, (end - now) / 1000);
    row.querySelector("[data-remaining]").textContent = timeText(remaining);
  }

  for (const stopwatch of root.querySelectorAll("[data-stopwatch]")) {
    const accumulated = Math.max(0, Number(stopwatch.dataset.accumulated) || 0);
    const startedAt = Date.parse(stopwatch.dataset.startedAt ?? "");
    const elapsed = accumulated + (Number.isFinite(startedAt) ? Math.max(0, now - startedAt) / 1000 : 0);
    stopwatch.querySelector("[data-stopwatch-elapsed]").textContent = stopwatchTimeText(elapsed);
  }
}

function colorMenu(kind, selectedColor) {
  return `
    <div class="hp-timer-color-menu">
      <button class="hp-timer-color-trigger" type="button" data-color-trigger aria-label="${colorName(selectedColor, null)}">
        ${typeIcon(kind)}<span aria-hidden="true">⌄</span>
      </button>
      <div class="hp-timer-color-popover" data-color-popover hidden>
        ${colors.map((color) => `<button class="is-${color}" type="button" data-color="${color}" aria-label="${colorName(color, null)}" ${color === selectedColor ? "aria-pressed=\"true\"" : ""}></button>`).join("")}
      </div>
    </div>
  `;
}

function bindColorMenu(root, onSelect) {
  const popover = root.querySelector("[data-color-popover]");
  root.querySelector("[data-color-trigger]")?.addEventListener("click", () => {
    popover.hidden = !popover.hidden;
  });
  for (const button of root.querySelectorAll("[data-color]")) {
    button.addEventListener("click", () => onSelect(button.dataset.color));
  }
}

function typeIcon(kind) {
  const symbols = {
    stopwatch: "⏱",
    timer: "⌛",
    pomodoro: "◎",
  };
  return `<span class="hp-timer-type-icon is-${kind}" aria-hidden="true">${symbols[kind] ?? "◷"}</span>`;
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

function stopwatchTimeText(seconds) {
  const totalHundredths = Math.max(0, Math.floor((Number(seconds) || 0) * 100));
  const hours = Math.floor(totalHundredths / 360000);
  const minutes = Math.floor((totalHundredths % 360000) / 6000);
  const secs = Math.floor((totalHundredths % 6000) / 100);
  const hundredths = totalHundredths % 100;
  return `${pad(hours)}:${pad(minutes)}:${pad(secs)}.${pad(hundredths)}`;
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
