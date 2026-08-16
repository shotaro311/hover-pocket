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
  let disposed = false;
  initializeState(surface.initialState, state);
  initializeDefaults(surface.renderModel.root, inputs, state);
  draw();
  void load();

  async function load() {
    setHostStatus("今日の予定を読み込んでいます…", "neutral");
    try {
      const payload = await context.request("pocketApp.load", {
        appId: surface.appId,
        surfaceId: surface.surfaceId,
      });
      if (disposed) return;
      for (const result of payload.queryResults ?? []) {
        queryResults.set(result.query, result.output);
      }
      const stateUpdates = initializeQuerySelections(surface.renderModel.root, inputs, state, queryResults);
      draw();
      for (const update of stateUpdates) {
        await persistState(update.binding, update.value);
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
          try {
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
        });
        input.addEventListener("change", async () => {
          await persistBoundState(node.value, valueFor(node.value, inputs, state));
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
        return pickerNode(node, inputs, state, refreshButtons, persistState);
      case "calendarEventPicker":
        return calendarPickerNode(node, inputs, state, queryResults, refreshButtons, persistState);
      case "durationPicker":
        return durationNode(node, inputs, state);
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
      setHostStatus("選択を保存できませんでした。", "error");
      return false;
    }
  }

  async function persistBoundState(binding, value) {
    if (!binding?.startsWith("$state.")) return true;
    return persistState(binding, value);
  }

  return {
    refresh: load,
    dispose() {
      disposed = true;
    },
  };
}

function initializeState(initialState, state) {
  for (const [key, value] of Object.entries(initialState ?? {})) {
    if (key && ["string", "boolean", "number"].includes(typeof value)) state.set(key, value);
  }
}

function initializeDefaults(node, inputs, state) {
  if (node.type === "durationPicker" && !inputs.has(bindingName(node.value))) {
    setBinding(node.value, Number(node.default ?? node.min), inputs, state);
  } else if (["textField", "picker"].includes(node.type) && valueFor(node.value, inputs, state) == null) {
    setBinding(node.value, "", inputs, state);
  } else if (node.type === "toggle" && valueFor(node.value, inputs, state) == null) {
    setBinding(node.value, false, inputs, state);
  }
  for (const child of node.children ?? []) initializeDefaults(child, inputs, state);
}

function initializeQuerySelections(node, inputs, state, queryResults) {
  const updates = [];
  if (node.type === "calendarEventPicker") {
    const events = queryResults.get(node.items?.query)?.events ?? [];
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
  const events = queryResults.get(node.items?.query)?.events ?? [];
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

function durationNode(node, inputs, state) {
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
  input.addEventListener("change", update);
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
    && Object.keys(resolved).length > 0
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
      mode: "quiet",
    },
    workflowInputs: {
      startFocus: ["durationSeconds", "purpose", "selectedEventRef"],
    },
    renderModel: {
      root: {
        type: "stack", axis: "vertical", spacing: 12, children: [
          { type: "text", style: "title", value: "Today Focus" },
          { type: "calendarEventPicker", items: { query: "calendar.events.list@1", arguments: {} }, selection: "$state.selectedEventRef", titleTarget: "$input.purpose" },
          { type: "durationPicker", value: "$input.durationSeconds", min: 60, max: 14400, default: 1500 },
          { type: "textField", label: "Purpose", value: "$input.purpose", maxLength: 80 },
          { type: "textField", label: "Note", value: "$state.note", maxLength: 80 },
          { type: "toggle", label: "Enabled", value: "$state.enabled" },
          { type: "picker", label: "Mode", value: "$state.mode", options: [
            { label: "Quiet", value: "quiet" },
            { label: "Active", value: "active" },
          ] },
          { type: "button", label: "Start focus", workflow: "startFocus" },
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
  let stateBoundControlsPersisted = false;
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
      const provider = renderPocketSurfaceProvider({
        container: host,
        state: { pocketSurface: model },
        request: async (method, params) => {
          if (method === "pocketApp.load") {
            return { queryResults: [{ query: "calendar.events.list@1", output: { events: [{ eventRef: "event:1", safeTitle: "Focus", start: "2026-08-15T01:00:00Z", end: "2026-08-15T02:00:00Z" }] } }] };
          }
          if (method === "pocketApp.updateState") {
            persistedState.set(params?.key, params?.value);
            return { saved: true };
          }
          if (method === "pocketApp.invokeWorkflow") {
            stateWorkflowInputForwarded ||= params?.workflowId === "startFocus"
              && params?.inputs?.selectedEventRef === "event:1"
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
        stateNote.dispatchEvent(new Event("change", { bubbles: true }));
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
      host.querySelector(".hp-pocket-primary")?.click();
      await nextLayout();
      stateBoundControlsPersisted ||= persistedState.get("note") === "After"
        && persistedState.get("enabled") === true
        && persistedState.get("mode") === "active";
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
        selection: host.querySelector("select")?.value === "event:1",
        duration: host.querySelector(".hp-pocket-duration input")?.value === "1500",
        purpose: host.querySelector(".hp-pocket-field input")?.value === "Focus",
        statePersisted: persistedState.get("selectedEventRef") === "event:1",
        approvalHostOwned: !host.querySelector("[data-approval], .hp-pocket-approval"),
      };
      provider?.dispose?.();
      host.remove();
    }
  }

  return {
    ...baseline,
    stateWorkflowInputForwarded,
    stateBoundControlsPersisted,
    layoutMatrix: layoutMatrix && layoutCases === panelCases.length * textCases.length,
  };
}

function nextLayout() {
  return new Promise((resolve) => {
    window.requestAnimationFrame(() => window.requestAnimationFrame(resolve));
  });
}
