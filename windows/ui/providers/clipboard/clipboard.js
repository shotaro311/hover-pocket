let bridgeRequest = null;
let containerEl = null;
let clipboardState = null;
let activeTab = "text";
let activePreview = null;

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
  const textItems = Array.isArray(state?.textItems) ? state.textItems : [];
  const imageItems = Array.isArray(state?.imageItems) ? state.imageItems : [];
  return {
    clipboardBridgeOk: Array.isArray(state?.textItems) && Array.isArray(state?.imageItems),
    clipboardFavoriteFieldOk: [...textItems, ...imageItems].every((item) => typeof item.favorite === "boolean"),
    clipboardPrivateMode: Boolean(state?.privateMode),
    clipboardMonitoringKnown: typeof state?.isMonitoring === "boolean",
  };
}

async function refreshState() {
  clipboardState = await send("clipboard.getState");
  validateViewState();
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
  validateViewState();
  render();
  return result;
}

function validateViewState() {
  if (!clipboardState) {
    activePreview = null;
    return;
  }

  if (activePreview && !findItem(activePreview.kind, activePreview.id)) {
    activePreview = null;
  }
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
  root.append(activePreview ? renderPreview(activePreview) : renderBrowser());
  containerEl.replaceChildren(root);
}

function renderHeader() {
  const header = element("header", { className: "clipboard-header" });
  const textItems = clipboardState.textItems ?? [];
  const imageItems = clipboardState.imageItems ?? [];
  const favoriteCount = getFavoriteItems().length;
  const status = clipboardState.privateMode
    ? "Private mode"
    : clipboardState.isMonitoring
      ? "Watching"
      : clipboardState.providerVisible
        ? "Paused"
        : "Provider hidden";
  header.append(
    element("div", { className: "clipboard-status" }, status),
    element("div", { className: "clipboard-count" }, `${textItems.length}/${clipboardState.textLimit} text`),
    element("div", { className: "clipboard-count" }, `${imageItems.length}/${clipboardState.imageLimit} image`),
    element("div", { className: "clipboard-count" }, `${favoriteCount} favorite`),
    element("div", { className: "clipboard-spacer" }),
    renderTextButton(clipboardState.privateMode ? "Resume" : "Private", () => {
      void updateState("clipboard.setPrivateMode", { enabled: !clipboardState.privateMode });
    }, clipboardState.privateMode ? "is-active" : ""),
    renderIconButton("⌫", "Clear non-favorite history", () => {
      activePreview = null;
      void updateState("clipboard.clear");
    })
  );

  if (clipboardState.lastErrorMessage) {
    header.append(element("div", { className: "clipboard-error" }, clipboardState.lastErrorMessage));
  }

  return header;
}

function renderBrowser() {
  const browser = element("div", { className: "clipboard-browser" });
  browser.append(renderTabs(), renderTabPanel());
  return browser;
}

function renderTabs() {
  const tabs = element("div", { className: "clipboard-tabs", role: "tablist" });
  for (const tab of [
    { id: "text", label: "Text", count: clipboardState.textItems?.length ?? 0 },
    { id: "images", label: "Images", count: clipboardState.imageItems?.length ?? 0 },
    { id: "favorites", label: "Favorites", count: getFavoriteItems().length },
  ]) {
    const button = element("button", {
      className: `clipboard-tab${activeTab === tab.id ? " is-active" : ""}`,
      type: "button",
      role: "tab",
      ariaSelected: String(activeTab === tab.id),
    }, tab.label, element("strong", {}, String(tab.count)));
    button.addEventListener("click", () => {
      activeTab = tab.id;
      activePreview = null;
      render();
    });
    tabs.append(button);
  }

  return tabs;
}

function renderTabPanel() {
  if (activeTab === "images") {
    return renderImagePanel(clipboardState.imageItems ?? [], false);
  }

  if (activeTab === "favorites") {
    return renderFavoritesPanel();
  }

  return renderTextPanel(clipboardState.textItems ?? [], false);
}

function renderTextPanel(items, showDelete) {
  const panel = element("section", { className: "clipboard-panel" });
  if (items.length === 0) {
    panel.append(renderEmpty("No text"));
    return panel;
  }

  const list = element("div", { className: "clipboard-text-list" });
  for (const item of items) {
    list.append(renderTextItem(item, showDelete));
  }
  panel.append(list);
  return panel;
}

function renderImagePanel(items, showDelete) {
  const panel = element("section", { className: "clipboard-panel" });
  if (items.length === 0) {
    panel.append(renderEmpty("No images"));
    return panel;
  }

  const grid = element("div", { className: "clipboard-image-grid" });
  for (const item of items) {
    grid.append(renderImageItem(item, showDelete));
  }
  panel.append(grid);
  return panel;
}

function renderFavoritesPanel() {
  const favorites = getFavoriteItems();
  const panel = element("section", { className: "clipboard-panel clipboard-favorites-panel" });
  if (favorites.length === 0) {
    panel.append(renderEmpty("No favorites"));
    return panel;
  }

  const list = element("div", { className: "clipboard-favorites-list" });
  for (const item of favorites) {
    list.append(item.kind === "text"
      ? renderTextItem(item, true)
      : renderImageItem(item, true));
  }
  panel.append(list);
  return panel;
}

function renderTextItem(item, showDelete) {
  const row = element("article", {
    className: `clipboard-text-item${item.favorite ? " is-favorite" : ""}`,
    tabIndex: "0",
    title: "Preview text",
  });
  row.addEventListener("click", () => togglePreview("text", item.id));
  row.addEventListener("keydown", (event) => {
    if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      togglePreview("text", item.id);
    }
  });

  const preview = element("p", { className: "clipboard-text-preview" }, item.previewText ?? item.text ?? "");
  const meta = element("div", { className: "clipboard-meta" }, formatTime(item.createdAt));
  row.append(
    element("div", { className: "clipboard-text-main" }, preview, meta),
    renderItemActions(item, "text", showDelete)
  );
  return row;
}

function renderImageItem(item, showDelete) {
  const tile = element("article", {
    className: `clipboard-image-item${item.favorite ? " is-favorite" : ""}`,
    tabIndex: "0",
    title: "Preview image",
  });
  tile.addEventListener("click", () => togglePreview("image", item.id));
  tile.addEventListener("keydown", (event) => {
    if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      togglePreview("image", item.id);
    }
  });

  const preview = element("div", { className: "clipboard-image-preview" });
  if (item.dataUrl) {
    preview.append(element("img", { src: item.dataUrl, alt: `${item.width} by ${item.height}` }));
  } else {
    preview.append(element("span", {}, "Image"));
  }

  const meta = element("div", { className: "clipboard-image-meta" }, `${item.width}x${item.height}`);
  tile.append(preview, element("div", { className: "clipboard-image-footer" }, meta, renderItemActions(item, "image", showDelete)));
  return tile;
}

function renderItemActions(item, kind, showDelete) {
  const actions = element("div", { className: "clipboard-item-actions" });
  actions.append(
    renderIconButton(item.favorite ? "★" : "☆", item.favorite ? "Remove favorite" : "Add favorite", () => {
      void updateState("clipboard.toggleFavorite", { kind, id: item.id });
    }),
    renderIconButton("⧉", kind === "image" ? "Copy image" : "Copy text", () => {
      activePreview = null;
      void updateState(kind === "image" ? "clipboard.copyImage" : "clipboard.copyText", { id: item.id });
    }),
    renderDragButton("↗", kind === "image" ? "Drag image to another app" : "Drag text to another app", () => {
      void send("clipboard.startExternalDrag", { kind, id: item.id });
    })
  );

  if (showDelete) {
    actions.append(renderIconButton("🗑", "Delete favorite", () => {
      activePreview = null;
      void updateState("clipboard.deleteItem", { kind, id: item.id });
    }, "is-danger"));
  }

  return actions;
}

function renderPreview(previewRef) {
  const item = findItem(previewRef.kind, previewRef.id);
  if (!item) {
    activePreview = null;
    return renderBrowser();
  }

  const preview = element("section", { className: `clipboard-full-preview is-${previewRef.kind}` });
  const title = previewRef.kind === "image"
    ? `${item.width}x${item.height}`
    : formatTime(item.createdAt);
  preview.append(
    element("header", { className: "clipboard-preview-header" },
      element("span", {}, title),
      element("div", { className: "clipboard-spacer" }),
      renderIconButton(item.favorite ? "★" : "☆", item.favorite ? "Remove favorite" : "Add favorite", () => {
        void updateState("clipboard.toggleFavorite", { kind: previewRef.kind, id: item.id });
      }),
      renderIconButton("⧉", previewRef.kind === "image" ? "Copy image" : "Copy text", () => {
        activePreview = null;
        void updateState(previewRef.kind === "image" ? "clipboard.copyImage" : "clipboard.copyText", { id: item.id });
      }),
      renderIconButton("✕", "Close preview", () => {
        activePreview = null;
        render();
      })
    )
  );

  if (previewRef.kind === "image") {
    const imageWrap = element("div", { className: "clipboard-preview-image" });
    if (item.dataUrl) {
      imageWrap.append(element("img", { src: item.dataUrl, alt: `${item.width} by ${item.height}` }));
    } else {
      imageWrap.append(element("span", {}, "Image unavailable"));
    }
    preview.append(imageWrap);
  } else {
    preview.append(element("pre", { className: "clipboard-preview-text" }, item.text ?? ""));
  }

  return preview;
}

function togglePreview(kind, id) {
  if (activePreview?.kind === kind && activePreview?.id === id) {
    activePreview = null;
  } else {
    activePreview = { kind, id };
  }
  render();
}

function findItem(kind, id) {
  const source = kind === "image" ? clipboardState?.imageItems : clipboardState?.textItems;
  return (source ?? []).find((item) => String(item.id) === String(id)) ?? null;
}

function getFavoriteItems() {
  const texts = (clipboardState?.textItems ?? [])
    .filter((item) => item.favorite)
    .map((item) => ({ ...item, kind: "text" }));
  const images = (clipboardState?.imageItems ?? [])
    .filter((item) => item.favorite)
    .map((item) => ({ ...item, kind: "image" }));
  return [...texts, ...images].sort((a, b) => new Date(b.createdAt ?? 0) - new Date(a.createdAt ?? 0));
}

function renderEmpty(label) {
  return element("div", { className: "clipboard-empty" }, label);
}

function renderIconButton(text, label, onClick, tone = "") {
  const button = element("button", {
    className: `clipboard-icon-button ${tone}`.trim(),
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
    } else if (key === "ariaSelected") {
      node.setAttribute("aria-selected", value);
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
