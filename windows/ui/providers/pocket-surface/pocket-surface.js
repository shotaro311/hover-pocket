const styleHref = "./providers/pocket-surface/pocket-surface.css";

/**
 * @param {{ container: Element, state: any, request: (method: string, params?: unknown) => Promise<any> }} context
 */
export function renderPocketSurfaceProvider(context) {
  ensureStyle(styleHref);
  const surface = context.state.pocketSurface;
  const root = document.createElement("section");
  root.className = "hp-pocket-surface";
  context.container.append(root);
  if (!surface?.renderModel?.root) {
    root.append(statusNode("Today Focusを準備できませんでした。", "error"));
    return;
  }

  const inputs = new Map();
  const state = new Map();
  const queryResults = new Map();
  const pendingTextState = new Map();
  const textStateTimers = new Map();
  const statePersistenceTails = new Map();
  let disposed = false;
  let stateFlushTask = null;
  let loadTask = Promise.resolve();
  let transitionHoldCount = 0;
  initializeState(surface.initialState, state);
  const defaultStateUpdates = initializeDefaults(surface.renderModel.root, inputs, state);
  draw();
  for (const update of defaultStateUpdates) void persistBoundState(update.binding, update.value);
  void refresh();

  function refresh() {
    if (transitionHoldCount > 0 || disposed) return loadTask;
    const next = loadTask.then(load);
    loadTask = next.catch(() => {});
    return next;
  }

  async function load() {
    setHostStatus("今日の予定を読み込んでいます…", "neutral");
    try {
      const payload = await context.request("pocketApp.load", {
        appId: surface.appId,
        surfaceId: surface.surfaceId,
      });
      if (disposed) return;
      queryResults.clear();
      for (const result of payload.queryResults ?? []) {
        queryResults.set(queryBindingKey(result.query, result.arguments), result.output);
      }
      const stateUpdates = initializeQuerySelections(surface.renderModel.root, inputs, state, queryResults);
      draw();
      for (const update of stateUpdates) {
        await persistBoundState(update.binding, update.value);
      }
    } catch {
      setHostStatus("今日の予定を読み込めませんでした。", "error");
    }
  }

  function draw() {
    if (disposed) return;
    root.replaceChildren(renderNode(surface.renderModel.root), hostStatusShell());
  }

  function renderNode(node) {
    switch (node.type) {
      case "stack": {
        const element = document.createElement("div");
        element.className = `hp-pocket-stack is-${node.axis}`;
        element.style.gap = `${Number(node.spacing) || 0}px`;
        element.append(...(node.children ?? []).map(renderNode));
        return element;
      }
      case "grid": {
        const element = document.createElement("div");
        element.className = "hp-pocket-grid";
        element.style.gridTemplateColumns = `repeat(${Math.max(1, Number(node.columns) || 1)}, minmax(0, 1fr))`;
        element.style.gap = `${Number(node.gap) || 0}px`;
        element.append(...(node.children ?? []).map(renderNode));
        return element;
      }
      case "text": {
        const element = document.createElement(node.style === "title" ? "h1" : "p");
        element.className = `hp-pocket-text is-${node.style}`;
        element.textContent = sanitizeVisibleText(node.value ?? "");
        return element;
      }
      case "image": {
        const element = document.createElement("div");
        element.className = "hp-pocket-image";
        element.setAttribute("role", "img");
        element.setAttribute("aria-label", sanitizeVisibleText(node.alt ?? "Image"));
        element.textContent = "▧";
        return element;
      }
      case "button": {
        const button = document.createElement("button");
        button.className = "hp-pocket-primary";
        button.type = "button";
        button.dataset.workflow = node.workflow ?? "";
        button.textContent = sanitizeVisibleText(node.label ?? "Run");
        button.disabled = !canInvoke(node.workflow, surface.workflowInputs, inputs, state);
        button.addEventListener("click", async () => {
          button.disabled = true;
          setHostStatus("確認を待っています…", "neutral");
          let transitionStarted = false;
          try {
            transitionStarted = true;
            const saved = await beginStateTransition();
            if (!saved) {
              setHostStatus("入力内容を保存できないため、処理を開始しませんでした。", "error");
              return;
            }
            const receipt = await context.request("pocketApp.invokeWorkflow", {
              appId: surface.appId,
              workflowId: node.workflow,
              inputs: resolvedWorkflowInputs(node.workflow, surface.workflowInputs, inputs, state),
            });
            const succeeded = receipt.status === "succeeded" && receipt.readbackVerified;
            setHostStatus(
              succeeded
                ? (typeof receipt.summary === "string" ? receipt.summary : "変更を反映して確認しました。")
                : receipt.status === "rejected"
                  ? "変更をキャンセルしました。"
                  : "処理結果を確認できませんでした。",
              succeeded ? "success" : "neutral",
            );
          } catch {
            setHostStatus("処理を完了できませんでした。", "error");
          } finally {
            if (transitionStarted) releaseStateTransition();
            button.disabled = !canInvoke(node.workflow, surface.workflowInputs, inputs, state);
          }
        });
        return button;
      }
      case "textField": {
        const field = document.createElement("label");
        field.className = "hp-pocket-field";
        const label = document.createElement("span");
        label.textContent = sanitizeVisibleText(node.label ?? "Text");
        const input = document.createElement("input");
        input.type = "text";
        input.maxLength = Math.max(1, Number(node.maxLength) || 1000);
        input.dataset.binding = node.value ?? "";
        input.value = stringValue(valueFor(node.value, inputs, state));
        input.addEventListener("input", () => {
          setBinding(node.value, truncateUnicodeScalars(sanitizeVisibleText(input.value), input.maxLength), inputs, state);
          refreshButtons();
          scheduleBoundStatePersistence(node.value, valueFor(node.value, inputs, state));
        });
        input.addEventListener("change", async () => {
          await flushBoundState(node.value);
        });
        field.append(label, input);
        return field;
      }
      case "toggle": {
        const label = document.createElement("label");
        label.className = "hp-pocket-toggle";
        const input = document.createElement("input");
        input.type = "checkbox";
        input.dataset.binding = node.value ?? "";
        input.checked = Boolean(valueFor(node.value, inputs, state));
        input.addEventListener("change", async () => {
          setBinding(node.value, input.checked, inputs, state);
          refreshButtons();
          await persistBoundState(node.value, input.checked);
        });
        const text = document.createElement("span");
        text.textContent = sanitizeVisibleText(node.label ?? "Toggle");
        label.append(input, text);
        return label;
      }
      case "picker":
        return pickerNode(node, inputs, state, refreshButtons, persistBoundState);
      case "calendarEventPicker":
        return calendarPickerNode(node, inputs, state, queryResults, refreshButtons, persistBoundState);
      case "durationPicker":
        return durationNode(node, inputs, state, refreshButtons, persistBoundState);
      case "status":
        return statusNode(node.value ?? "", node.tone ?? "neutral");
      default:
        return document.createTextNode("");
    }
  }

  function refreshButtons() {
    for (const button of root.querySelectorAll(".hp-pocket-primary")) {
      button.disabled = !canInvoke(button.dataset.workflow, surface.workflowInputs, inputs, state);
    }
  }

  function hostStatusShell() {
    const element = document.createElement("div");
    element.className = "hp-pocket-host-status";
    element.hidden = true;
    return element;
  }

  function setHostStatus(text, tone) {
    let element = root.querySelector(".hp-pocket-host-status");
    if (!element) {
      element = hostStatusShell();
      root.append(element);
    }
    element.hidden = !text;
    element.className = `hp-pocket-host-status is-${tone}`;
    element.textContent = sanitizeVisibleText(text);
  }

  async function persistState(binding, value) {
    try {
      await context.request("pocketApp.updateState", {
        appId: surface.appId,
        key: bindingName(binding),
        value,
      });
      return true;
    } catch {
      if (!disposed) setHostStatus("選択を保存できませんでした。", "error");
      return false;
    }
  }

  async function persistBoundState(binding, value) {
    if (!binding?.startsWith("$state.")) return true;
    const key = bindingName(binding);
    pendingTextState.set(key, { binding, value, promise: null });
    return flushBoundState(binding);
  }

  function scheduleBoundStatePersistence(binding, value) {
    if (!binding?.startsWith("$state.")) return;
    const key = bindingName(binding);
    pendingTextState.set(key, { binding, value, promise: null });
    clearTimeout(textStateTimers.get(key));
    textStateTimers.set(key, setTimeout(() => {
      textStateTimers.delete(key);
      void flushBoundState(binding);
    }, 180));
  }

  function queueStatePersistence(pending) {
    const key = bindingName(pending.binding);
    const previous = statePersistenceTails.get(key) ?? Promise.resolve(true);
    const next = previous
      .then(() => persistState(pending.binding, pending.value))
      .then((saved) => {
        if (pendingTextState.get(key) === pending) {
          if (saved) pendingTextState.delete(key);
          else pending.promise = null;
        }
        return saved;
      });
    pending.promise = next;
    statePersistenceTails.set(key, next);
    void next.then(() => {
      if (statePersistenceTails.get(key) === next) statePersistenceTails.delete(key);
    });
    return next;
  }

  function flushBoundState(binding) {
    if (!binding?.startsWith("$state.")) return Promise.resolve(true);
    const key = bindingName(binding);
    clearTimeout(textStateTimers.get(key));
    textStateTimers.delete(key);
    const pending = pendingTextState.get(key);
    if (!pending) return statePersistenceTails.get(key) ?? Promise.resolve(true);
    if (pending.promise) return pending.promise;
    return queueStatePersistence(pending);
  }

  async function flushPendingTextState() {
    const pending = [...pendingTextState.values()];
    const pendingFlushes = pending.map((item) => flushBoundState(item.binding));
    const activeWrites = [...statePersistenceTails.values()];
    const results = await Promise.all([...new Set([...pendingFlushes, ...activeWrites])]);
    return results.every((result) => result !== false);
  }

  function flushStateWrites() {
    if (stateFlushTask) return stateFlushTask;
    stateFlushTask = loadTask.then(flushPendingTextState).finally(() => {
      stateFlushTask = null;
    });
    return stateFlushTask;
  }

  async function flushPendingState() {
    const wasInert = root.inert;
    root.inert = true;
    const saved = await flushStateWrites();
    if (!disposed && transitionHoldCount === 0) root.inert = wasInert;
    return saved;
  }

  async function beginStateTransition() {
    transitionHoldCount += 1;
    root.inert = true;
    return await flushStateWrites();
  }

  function releaseStateTransition() {
    transitionHoldCount = Math.max(0, transitionHoldCount - 1);
    if (!disposed && transitionHoldCount === 0) root.inert = false;
  }

  return {
    refresh,
    flushPendingState,
    beginStateTransition,
    releaseStateTransition,
    async dispose() {
      const saved = await flushPendingState();
      if (!saved) return false;
      disposed = true;
      root.inert = true;
      return true;
    },
  };
}

function initializeState(initialState, state) {
  for (const [key, value] of Object.entries(initialState ?? {})) {
    if (key && ["string", "boolean", "number"].includes(typeof value)) state.set(key, value);
  }
}

function initializeDefaults(node, inputs, state) {
  const updates = [];
  const applyDefault = (binding, value) => {
    setBinding(binding, value, inputs, state);
    if (binding?.startsWith("$state.")) updates.push({ binding, value });
  };
  if (node.type === "durationPicker" && valueFor(node.value, inputs, state) == null) {
    applyDefault(node.value, Number(node.default ?? node.min));
  } else if (node.type === "textField" && valueFor(node.value, inputs, state) == null) {
    applyDefault(node.value, "");
  } else if (node.type === "picker") {
    const values = (node.options ?? []).map((option) => option.value);
    if (!values.includes(valueFor(node.value, inputs, state)) && values.length > 0) {
      applyDefault(node.value, values[0]);
    }
  } else if (node.type === "toggle" && valueFor(node.value, inputs, state) == null) {
    applyDefault(node.value, false);
  }
  for (const child of node.children ?? []) updates.push(...initializeDefaults(child, inputs, state));
  return updates;
}

function initializeQuerySelections(node, inputs, state, queryResults) {
  const updates = [];
  if (node.type === "calendarEventPicker") {
    const events = queryResults.get(queryBindingKey(node.items?.query, node.items?.arguments))?.events ?? [];
    const persisted = stringValue(valueFor(node.selection, inputs, state));
    const selected = events.find((event) => event.eventRef === persisted) ?? events[0];
    if (selected) {
      setBinding(node.selection, selected.eventRef, inputs, state);
      if (persisted !== selected.eventRef) updates.push({ binding: node.selection, value: selected.eventRef });
      if (node.titleTarget) setBinding(node.titleTarget, sanitizeVisibleText(selected.safeTitle ?? ""), inputs, state);
    }
  }
  for (const child of node.children ?? []) {
    updates.push(...initializeQuerySelections(child, inputs, state, queryResults));
  }
  return updates;
}

function calendarPickerNode(node, inputs, state, queryResults, onChange, persistState) {
  const field = document.createElement("label");
  field.className = "hp-pocket-calendar-field";
  const label = document.createElement("span");
  label.textContent = "集中する予定";
  const select = document.createElement("select");
  select.dataset.binding = node.selection ?? "";
  const events = queryResults.get(queryBindingKey(node.items?.query, node.items?.arguments))?.events ?? [];
  if (!events.length) {
    const option = document.createElement("option");
    option.textContent = "今日の予定はありません";
    option.value = "";
    select.append(option);
    select.disabled = true;
  } else {
    for (const event of events) {
      const option = document.createElement("option");
      option.value = event.eventRef;
      option.textContent = [sanitizeVisibleText(event.safeTitle ?? ""), timeRange(event.start, event.end)]
        .filter(Boolean).join("  ");
      select.append(option);
    }
    select.value = stringValue(valueFor(node.selection, inputs, state));
    select.addEventListener("change", async () => {
      setBinding(node.selection, select.value, inputs, state);
      const selected = events.find((event) => event.eventRef === select.value);
      if (node.titleTarget && selected) {
        setBinding(node.titleTarget, sanitizeVisibleText(selected.safeTitle ?? ""), inputs, state);
        const purpose = [...(field.closest(".hp-pocket-surface")?.querySelectorAll(".hp-pocket-field input") ?? [])]
          .find((input) => input.dataset.binding === node.titleTarget);
        if (purpose) purpose.value = stringValue(valueFor(node.titleTarget, inputs, state));
      }
      onChange();
      await persistState(node.selection, select.value);
    });
  }
  field.append(label, select);
  return field;
}

function durationNode(node, inputs, state, onChange, persistState) {
  const field = document.createElement("label");
  field.className = "hp-pocket-duration";
  const label = document.createElement("span");
  label.textContent = "フォーカスタイマー";
  const input = document.createElement("input");
  input.type = "number";
  input.min = String(Math.max(1, Number(node.min) || 60));
  input.max = String(Math.max(Number(input.min), Number(node.max) || 86400));
  input.step = "60";
  input.value = String(Number(valueFor(node.value, inputs, state)) || Number(node.default) || Number(node.min));
  const unit = document.createElement("b");
  const update = () => {
    const seconds = Math.max(Number(input.min), Math.min(Number(input.max), Number(input.value) || Number(input.min)));
    input.value = String(seconds);
    setBinding(node.value, seconds, inputs, state);
    unit.textContent = `${Math.max(1, Math.floor(seconds / 60))}分`;
  };
  input.addEventListener("change", async () => {
    update();
    onChange();
    await persistState(node.value, Number(input.value));
  });
  update();
  field.append(label, input, unit);
  return field;
}

function pickerNode(node, inputs, state, onChange, persistState) {
  const field = document.createElement("label");
  field.className = "hp-pocket-field";
  const label = document.createElement("span");
  label.textContent = sanitizeVisibleText(node.label ?? "Select");
  const select = document.createElement("select");
  select.dataset.binding = node.value ?? "";
  for (const item of node.options ?? []) {
    const option = document.createElement("option");
    option.value = item.value;
    option.textContent = sanitizeVisibleText(item.label ?? "");
    select.append(option);
  }
  select.value = stringValue(valueFor(node.value, inputs, state));
  select.addEventListener("change", async () => {
    setBinding(node.value, select.value, inputs, state);
    onChange();
    if (node.value?.startsWith("$state.")) {
      await persistState(node.value, select.value);
    }
  });
  field.append(label, select);
  return field;
}

function statusNode(text, tone) {
  const element = document.createElement("div");
  element.className = `hp-pocket-status is-${tone}`;
  element.textContent = sanitizeVisibleText(text);
  return element;
}

function valueFor(binding, inputs, state) {
  if (binding?.startsWith("$input.")) return inputs.get(bindingName(binding));
  if (binding?.startsWith("$state.")) return state.get(bindingName(binding));
  return undefined;
}

function setBinding(binding, value, inputs, state) {
  if (binding?.startsWith("$input.")) inputs.set(bindingName(binding), value);
  if (binding?.startsWith("$state.")) state.set(bindingName(binding), value);
}

function bindingName(binding) {
  return String(binding ?? "").split(".").slice(1).join(".");
}

function queryBindingKey(query, argumentsValue) {
  return `${String(query ?? "")}\n${JSON.stringify(canonicalJson(argumentsValue ?? {}))}`;
}

function canonicalJson(value) {
  if (Array.isArray(value)) return value.map(canonicalJson);
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.keys(value).sort().map((key) => [key, canonicalJson(value[key])]));
  }
  return value;
}

function stringValue(value) {
  return typeof value === "string" ? value : "";
}

function resolvedWorkflowInputs(workflow, workflowInputs, inputs, state) {
  const names = workflowInputs?.[workflow];
  if (!Array.isArray(names)) return null;
  return Object.fromEntries(names.map((name) => [
    name,
    inputs.has(name) ? inputs.get(name) : state.get(name),
  ]));
}

function canInvoke(workflow, workflowInputs, inputs, state) {
  const resolved = resolvedWorkflowInputs(workflow, workflowInputs, inputs, state);
  return Boolean(workflow)
    && resolved !== null
    && Object.values(resolved).every((value) => (
      typeof value === "string" ? value.length > 0 : value !== null && value !== undefined
    ));
}

function timeRange(start, end) {
  const from = new Date(start ?? "");
  const to = new Date(end ?? "");
  if (Number.isNaN(from.valueOf()) || Number.isNaN(to.valueOf())) return "";
  const format = new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit" });
  return `${format.format(from)}–${format.format(to)}`;
}

function sanitizeVisibleText(value) {
  return String(value ?? "")
    .replace(/[\u0000-\u001f\u007f-\u009f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function truncateUnicodeScalars(value, maximum) {
  return Array.from(String(value ?? "")).slice(0, Math.max(0, Number(maximum) || 0)).join("");
}

function ensureStyle(href) {
  if ([...document.styleSheets].some((sheet) => sheet.href?.endsWith(href.replace("./", "/")))) return;
  const link = document.createElement("link");
  link.rel = "stylesheet";
  link.href = href;
  document.head.append(link);
}

export async function runPocketSurfaceUiVerify() {
  const model = {
    appId: "local.example.today-focus",
    surfaceId: "main",
    initialState: {
      note: "Before",
      enabled: false,
      mode: "removed",
      focusSeconds: 600,
    },
    workflowInputs: {
      startFocus: ["durationSeconds", "purpose", "selectedEventRef"],
      runLiteral: [],
    },
    renderModel: {
      root: {
        type: "stack", axis: "vertical", spacing: 12, children: [
          { type: "text", style: "title", value: "Today Focus" },
          { type: "calendarEventPicker", items: { query: "calendar.events.list@1", arguments: { timeZone: "UTC" } }, selection: "$state.selectedEventRef", titleTarget: "$input.purpose" },
          { type: "calendarEventPicker", items: { query: "calendar.events.list@1", arguments: { timeZone: "Asia/Tokyo" } }, selection: "$state.secondaryEventRef" },
          { type: "durationPicker", value: "$input.durationSeconds", min: 60, max: 14400, default: 1500 },
          { type: "durationPicker", value: "$state.focusSeconds", min: 60, max: 14400, default: 900 },
          { type: "textField", label: "Purpose", value: "$input.purpose", maxLength: 80 },
          { type: "textField", label: "Note", value: "$state.note", maxLength: 80 },
          { type: "toggle", label: "Enabled", value: "$state.enabled" },
          { type: "picker", label: "Mode", value: "$state.mode", options: [
            { label: "Quiet", value: "quiet" },
            { label: "Active", value: "active" },
          ] },
          { type: "button", label: "Start focus", workflow: "startFocus" },
          { type: "button", label: "Run literal", workflow: "runLiteral" },
        ],
      },
    },
  };
  const panelCases = [
    { name: "small", width: 520, height: 318 },
    { name: "medium", width: 600, height: 376 },
    { name: "large", width: 680, height: 434 },
  ];
  const textCases = [
    { name: "small", scale: 1 },
    { name: "medium", scale: 1.12 },
    { name: "large", scale: 1.24 },
  ];
  let baseline;
  let stateWorkflowInputForwarded = false;
  let inputlessWorkflowInvoked = false;
  let stateBoundControlsPersisted = false;
  let pickerNormalizationPersisted = false;
  let failedStateWriteRetried = false;
  let workflowBlockedOnStateWriteFailure = true;
  let stateTransitionBoundary = false;
  let layoutMatrix = true;
  let layoutCases = 0;

  for (const panelCase of panelCases) {
    for (const textCase of textCases) {
      const host = document.createElement("div");
      host.dataset.panelSize = panelCase.name;
      host.dataset.textSize = textCase.name;
      host.style.cssText = `position:fixed;left:-10000px;top:0;width:${panelCase.width}px;height:${panelCase.height}px;--hp-text-scale:${textCase.scale}`;
      document.body.append(host);
      const persistedState = new Map();
      let loadCalls = 0;
      let noteWriteAttempts = 0;
      let startFocusInvocationCount = 0;
      const provider = renderPocketSurfaceProvider({
        container: host,
        state: { pocketSurface: model },
        request: async (method, params) => {
          if (method === "pocketApp.load") {
            loadCalls += 1;
            return { queryResults: [
              { query: "calendar.events.list@1", arguments: { timeZone: "UTC" }, output: { events: [{ eventRef: "event:utc", safeTitle: "Focus", start: "2026-08-15T01:00:00Z", end: "2026-08-15T02:00:00Z" }] } },
              { query: "calendar.events.list@1", arguments: { timeZone: "Asia/Tokyo" }, output: { events: [{ eventRef: "event:jst", safeTitle: "Secondary", start: "2026-08-15T03:00:00Z", end: "2026-08-15T04:00:00Z" }] } },
            ] };
          }
          if (method === "pocketApp.updateState") {
            if (params?.key === "note") {
              noteWriteAttempts += 1;
              if (noteWriteAttempts === 1) throw new Error("fixture_state_write_failed");
            }
            pickerNormalizationPersisted ||= params?.key === "mode" && params?.value === "quiet";
            persistedState.set(params?.key, params?.value);
            return { saved: true };
          }
          if (method === "pocketApp.invokeWorkflow") {
            if (params?.workflowId === "startFocus") startFocusInvocationCount += 1;
            inputlessWorkflowInvoked ||= params?.workflowId === "runLiteral"
              && Object.keys(params?.inputs ?? {}).length === 0;
            stateWorkflowInputForwarded ||= params?.workflowId === "startFocus"
              && params?.inputs?.selectedEventRef === "event:utc"
              && params?.inputs?.purpose === "Focus"
              && params?.inputs?.durationSeconds === 1500
              && Object.keys(params.inputs).sort().join(",") === "durationSeconds,purpose,selectedEventRef";
            return { status: "succeeded", readbackVerified: true, summary: "Verified" };
          }
          throw new Error("unexpected_method");
        },
      });
      await nextLayout();
      const stateNote = host.querySelector('input[data-binding="$state.note"]');
      if (stateNote) {
        stateNote.value = "After";
        stateNote.dispatchEvent(new Event("input", { bubbles: true }));
      }
      const stateToggle = host.querySelector('input[data-binding="$state.enabled"]');
      if (stateToggle) {
        stateToggle.checked = true;
        stateToggle.dispatchEvent(new Event("change", { bubbles: true }));
      }
      const statePicker = host.querySelector('select[data-binding="$state.mode"]');
      if (statePicker) {
        statePicker.value = "active";
        statePicker.dispatchEvent(new Event("change", { bubbles: true }));
      }
      const stateDuration = [...host.querySelectorAll(".hp-pocket-duration input")]
        .find((input) => input.value === "600");
      if (stateDuration) {
        stateDuration.value = "1200";
        stateDuration.dispatchEvent(new Event("change", { bubbles: true }));
      }
      const startFocusButton = host.querySelector('[data-workflow="startFocus"]');
      startFocusButton?.click();
      await nextLayout();
      workflowBlockedOnStateWriteFailure &&= startFocusInvocationCount === 0
        && noteWriteAttempts === 1;
      startFocusButton?.click();
      await nextLayout();
      host.querySelector('[data-workflow="runLiteral"]')?.click();
      await nextLayout();
      const surface = host.querySelector(".hp-pocket-surface");
      const surfaceRect = surface?.getBoundingClientRect();
      const controlsFit = [...host.querySelectorAll("input, select, button")].every((control) => {
        const rect = control.getBoundingClientRect();
        return surfaceRect && rect.left >= surfaceRect.left - 1 && rect.right <= surfaceRect.right + 1;
      });
      layoutCases += 1;
      layoutMatrix &&= Boolean(
        surface
        && surfaceRect
        && surfaceRect.width > 0
        && surfaceRect.height > 0
        && surface.scrollWidth <= surface.clientWidth + 1
        && controlsFit,
      );
      baseline ??= {
        rendered: Boolean(host.querySelector(".hp-pocket-surface .hp-pocket-text.is-title")),
        selection: host.querySelector('select[data-binding="$state.selectedEventRef"]')?.value === "event:utc"
          && host.querySelector('select[data-binding="$state.secondaryEventRef"]')?.value === "event:jst",
        duration: host.querySelector(".hp-pocket-duration input")?.value === "1500",
        purpose: host.querySelector(".hp-pocket-field input")?.value === "Focus",
        statePersisted: persistedState.get("selectedEventRef") === "event:utc"
          && persistedState.get("secondaryEventRef") === "event:jst",
        approvalHostOwned: !host.querySelector("[data-approval], .hp-pocket-approval"),
      };
      const firstPostWorkflowFlush = await provider?.flushPendingState?.();
      const secondPostWorkflowFlush = await provider?.flushPendingState?.();
      failedStateWriteRetried ||= firstPostWorkflowFlush !== false
        && secondPostWorkflowFlush !== false
        && noteWriteAttempts === 2
        && persistedState.get("note") === "After";
      const loadsBeforeTransition = loadCalls;
      const firstTransitionSaved = await provider?.beginStateTransition?.();
      const secondTransitionSaved = await provider?.beginStateTransition?.();
      const inertDuringTransition = surface?.inert === true;
      await provider?.refresh?.();
      const refreshBlockedDuringTransition = loadCalls === loadsBeforeTransition;
      provider?.releaseStateTransition?.();
      const overlappingTransitionStillHeld = surface?.inert === true;
      provider?.releaseStateTransition?.();
      const interactionRestored = surface?.inert === false;
      await provider?.refresh?.();
      stateTransitionBoundary ||= firstTransitionSaved !== false
        && secondTransitionSaved !== false
        && inertDuringTransition
        && refreshBlockedDuringTransition
        && overlappingTransitionStillHeld
        && interactionRestored
        && loadCalls === loadsBeforeTransition + 1;
      const flushed = await provider?.flushPendingState?.();
      const disposalSaved = await provider?.dispose?.();
      await nextLayout();
      stateBoundControlsPersisted ||= flushed !== false
        && disposalSaved !== false
        && pickerNormalizationPersisted
        && persistedState.get("note") === "After"
        && persistedState.get("enabled") === true
        && persistedState.get("mode") === "active"
        && persistedState.get("focusSeconds") === 1200;
      host.remove();
    }
  }

  return {
    ...baseline,
    stateWorkflowInputForwarded: stateWorkflowInputForwarded && inputlessWorkflowInvoked,
    stateBoundControlsPersisted,
    failedStateWriteRetried,
    workflowBlockedOnStateWriteFailure,
    stateTransitionBoundary,
    layoutMatrix: layoutMatrix && layoutCases === panelCases.length * textCases.length,
  };
}

function nextLayout() {
  return new Promise((resolve) => {
    window.requestAnimationFrame(() => window.requestAnimationFrame(resolve));
  });
}
