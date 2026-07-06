let bridgeRequest = null;
let containerEl = null;
let clipboardState = null;

/**
 * @param {{ container: HTMLElement, request: (method: string, params?: unknown) => Promise<unknown> }} options
 */
export function renderClipboardProvider(options) {
  containerEl = options.container;
  bridgeRequest = options.request;
  ensureStylesheet();

  if (!clipboardState) {
    renderLoading();
  }

  void refreshState();
}

export async function runClipboardUiVerify(request) {
  const state = await request("clipboard.getState");
  return {
    clipboardBridgeOk: Array.isArray(state?.textItems) && Array.isArray(state?.imageItems),
    clipboardPrivateMode: Boolean(state?.privateMode),
    clipboardMonitoringKnown: typeof state?.isMonitoring === "boolean",
  };
}

async function refreshState() {
  clipboardState = await send("clipboard.getState");
  render();
}

async function send(method, params = undefined) {
  if (!bridgeRequest) {
    throw new Error("Clipboard bridge is unavailable.");
  }

  return bridgeRequest(method, params);
}

async function updateState(method, params = undefined) {
  const result = await send(method, params);
  clipboardState = result?.state ?? result;
  render();
  return result;
}

function renderLoading() {
  if (!containerEl) {
    return;
  }

  containerEl.replaceChildren(element("div", { className: "clipboard-loading" }, "Loading clipboard history..."));
}

function render() {
  if (!containerEl || !clipboardState) {
    return;
  }

  const root = element("section", { className: "clipboard-root" });
  root.append(renderHeader());
  root.append(renderColumns());
  containerEl.replaceChildren(root);
}

function renderHeader() {
  const header = element("header", { className: "clipboard-header" });
  const status = clipboardState.privateMode
    ? "Private mode"
    : clipboardState.isMonitoring
      ? "Watching"
      : clipboardState.providerVisible
        ? "Paused"
        : "Provider hidden";
  header.append(
    element("div", { className: "clipboard-status" }, status),
    element("div", { className: "clipboard-count" }, `${clipboardState.textItems?.length ?? 0}/${clipboardState.textLimit} text`),
    element("div", { className: "clipboard-count" }, `${clipboardState.imageItems?.length ?? 0}/${clipboardState.imageLimit} image`),
    element("div", { className: "clipboard-spacer" }),
    renderTextButton(clipboardState.privateMode ? "Resume" : "Private", () => {
      void updateState("clipboard.setPrivateMode", { enabled: !clipboardState.privateMode });
    }, clipboardState.privateMode ? "is-active" : ""),
    renderIconButton("⌫", "Clear clipboard history", () => {
      void updateState("clipboard.clear");
    })
  );

  if (clipboardState.lastErrorMessage) {
    header.append(element("div", { className: "clipboard-error" }, clipboardState.lastErrorMessage));
  }

  return header;
}

function renderColumns() {
  const columns = element("div", { className: "clipboard-columns" });
  columns.append(renderTextColumn(), renderImageColumn());
  return columns;
}

function renderTextColumn() {
  const column = element("section", { className: "clipboard-column" });
  column.append(renderColumnTitle("Text", clipboardState.textItems?.length ?? 0));

  const items = clipboardState.textItems ?? [];
  if (items.length === 0) {
    column.append(renderEmpty("No text"));
    return column;
  }

  const list = element("div", { className: "clipboard-text-list" });
  for (const item of items) {
    list.append(renderTextItem(item));
  }
  column.append(list);
  return column;
}

function renderImageColumn() {
  const column = element("section", { className: "clipboard-column" });
  column.append(renderColumnTitle("Images", clipboardState.imageItems?.length ?? 0));

  const items = clipboardState.imageItems ?? [];
  if (items.length === 0) {
    column.append(renderEmpty("No images"));
    return column;
  }

  const grid = element("div", { className: "clipboard-image-grid" });
  for (const item of items) {
    grid.append(renderImageItem(item));
  }
  column.append(grid);
  return column;
}

function renderColumnTitle(title, count) {
  const row = element("div", { className: "clipboard-column-title" });
  row.append(element("span", {}, title), element("strong", {}, String(count)));
  return row;
}

function renderTextItem(item) {
  const row = element("article", {
    className: "clipboard-text-item",
    tabIndex: "0",
    title: "Copy text",
  });
  row.addEventListener("click", () => void updateState("clipboard.copyText", { id: item.id }));
  row.addEventListener("keydown", (event) => {
    if (event.key === "Enter") {
      event.preventDefault();
      void updateState("clipboard.copyText", { id: item.id });
    }
  });

  const preview = element("p", { className: "clipboard-text-preview" }, item.previewText ?? item.text ?? "");
  const meta = element("div", { className: "clipboard-meta" }, formatTime(item.createdAt));
  const drag = renderDragButton("↗", "Drag text to another app", () => {
    void send("clipboard.startExternalDrag", { kind: "text", id: item.id });
  });
  row.append(element("div", { className: "clipboard-text-main" }, preview, meta), drag);
  return row;
}

function renderImageItem(item) {
  const tile = element("article", {
    className: "clipboard-image-item",
    tabIndex: "0",
    title: "Copy image",
  });
  tile.addEventListener("click", () => void updateState("clipboard.copyImage", { id: item.id }));
  tile.addEventListener("keydown", (event) => {
    if (event.key === "Enter") {
      event.preventDefault();
      void updateState("clipboard.copyImage", { id: item.id });
    }
  });

  const preview = element("div", { className: "clipboard-image-preview" });
  if (item.dataUrl) {
    preview.append(element("img", { src: item.dataUrl, alt: `${item.width} by ${item.height}` }));
  } else {
    preview.append(element("span", {}, "Image"));
  }

  const meta = element("div", { className: "clipboard-image-meta" });
  meta.append(
    element("span", {}, `${item.width}x${item.height}`),
    renderDragButton("↗", "Drag image to another app", () => {
      void send("clipboard.startExternalDrag", { kind: "image", id: item.id });
    })
  );
  tile.append(preview, meta);
  return tile;
}

function renderEmpty(label) {
  return element("div", { className: "clipboard-empty" }, label);
}

function renderIconButton(text, label, onClick) {
  const button = element("button", {
    className: "clipboard-icon-button",
    type: "button",
    ariaLabel: label,
    title: label,
  }, text);
  button.addEventListener("click", (event) => {
    event.stopPropagation();
    onClick(event);
  });
  return button;
}

function renderTextButton(text, onClick, tone = "") {
  const button = element("button", {
    className: `clipboard-text-button ${tone}`.trim(),
    type: "button",
  }, text);
  button.addEventListener("click", (event) => {
    event.stopPropagation();
    onClick(event);
  });
  return button;
}

function renderDragButton(text, label, onDragStart) {
  const button = element("button", {
    className: "clipboard-drag-button",
    type: "button",
    ariaLabel: label,
    title: label,
  }, text);
  button.addEventListener("click", (event) => {
    event.stopPropagation();
  });
  button.addEventListener("pointerdown", (event) => {
    event.preventDefault();
    event.stopPropagation();
    onDragStart();
  });
  return button;
}

function formatTime(value) {
  if (!value) {
    return "";
  }

  return new Date(value).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
}

function ensureStylesheet() {
  if (document.querySelector("link[data-clipboard-css]")) {
    return;
  }

  const link = document.createElement("link");
  link.rel = "stylesheet";
  link.href = "./providers/clipboard/clipboard.css";
  link.dataset.clipboardCss = "true";
  document.head.append(link);
}

function element(tagName, props = {}, ...children) {
  const node = document.createElement(tagName);
  for (const [key, value] of Object.entries(props)) {
    if (value === undefined || value === null) {
      continue;
    }

    if (key === "className") {
      node.className = value;
    } else if (key === "ariaLabel") {
      node.setAttribute("aria-label", value);
    } else if (key === "tabIndex") {
      node.tabIndex = value;
    } else if (key in node) {
      node[key] = value;
    } else {
      node.setAttribute(key, value);
    }
  }

  for (const child of children) {
    node.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return node;
}
