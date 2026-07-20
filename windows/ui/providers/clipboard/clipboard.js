let bridgeRequest = null;
let containerEl = null;
let appState = null;
let clipboardState = null;
let clipboardStateSignature = "";
let activePreview = null;
let activeMount = 0;
let refreshPromise = null;
let renderCount = 0;

/**
 * @param {{ container: HTMLElement, request: (method: string, params?: unknown) => Promise<unknown> }} options
 */
export function renderClipboardProvider(options) {
  const mount = ++activeMount;
  containerEl = options.container;
  bridgeRequest = options.request;
  appState = options.state;
  ensureStylesheet();

  if (clipboardState) {
    validateViewState();
    render();
  } else {
    renderLoading();
  }

  void refreshState();
  return {
    refresh: refreshState,
    dispose() {
      if (mount === activeMount) {
        containerEl = null;
        bridgeRequest = null;
      }
    },
  };
}

export async function runClipboardUiVerify(request) {
  const state = await request("clipboard.getState");
  const textItems = Array.isArray(state?.textItems) ? state.textItems : [];
  const imageItems = Array.isArray(state?.imageItems) ? state.imageItems : [];
  const rootBeforeRefresh = containerEl?.querySelector(".clipboard-root") ?? null;
  const renderCountBeforeRefresh = renderCount;
  await refreshState();
  return {
    clipboardBridgeOk: Array.isArray(state?.textItems) && Array.isArray(state?.imageItems),
    clipboardFavoriteFieldOk: [...textItems, ...imageItems].every((item) => typeof item.favorite === "boolean"),
    clipboardPrivateMode: Boolean(state?.privateMode),
    clipboardMonitoringKnown: typeof state?.isMonitoring === "boolean",
    clipboardStableRefreshOk: rootBeforeRefresh === containerEl?.querySelector(".clipboard-root")
      && renderCount === renderCountBeforeRefresh,
    clipboardSplitViewOk: Boolean(
      containerEl?.querySelector(".clipboard-split .clipboard-pane.is-text")
      && containerEl?.querySelector(".clipboard-split .clipboard-pane.is-image"),
    ),
  };
}

async function refreshState() {
  if (refreshPromise) {
    return refreshPromise;
  }

  refreshPromise = send("clipboard.getState").then((state) => {
    applyClipboardState(state, false);
    return state;
  }).finally(() => {
    refreshPromise = null;
  });
  return refreshPromise;
}

async function send(method, params = undefined) {
  if (!bridgeRequest) {
    throw new Error(tx("クリップボードを読み込めません。", "Clipboard bridge is unavailable."));
  }

  return bridgeRequest(method, params);
}

async function updateState(method, params = undefined) {
  const result = await send(method, params);
  applyClipboardState(result?.state ?? result, true);
  return result;
}

function applyClipboardState(state, forceRender) {
  const nextSignature = stateSignature(state);
  const changed = nextSignature !== clipboardStateSignature;
  clipboardState = state;
  clipboardStateSignature = nextSignature;
  validateViewState();
  if (forceRender || changed) {
    render();
  }
}

function stateSignature(state) {
  const texts = (state?.textItems ?? []).map((item) => [
    item.id,
    item.createdAt,
    item.favorite,
    item.text?.length ?? 0,
  ].join(":"));
  const images = (state?.imageItems ?? []).map((item) => [
    item.id,
    item.createdAt,
    item.favorite,
    item.contentHash,
  ].join(":"));
  return JSON.stringify([
    state?.isMonitoring,
    state?.privateMode,
    state?.providerVisible,
    state?.lastErrorMessage,
    texts,
    images,
  ]);
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

  containerEl.replaceChildren(element("div", { className: "clipboard-loading" }, tx("クリップボード履歴を読み込んでいます…", "Loading clipboard history...")));
}

function render() {
  if (!containerEl || !clipboardState) {
    return;
  }

  const scrollState = captureScrollState();
  const root = element("section", { className: "clipboard-root" });
  renderCount++;
  root.append(renderHeader());
  root.append(activePreview ? renderPreview(activePreview) : renderSplit());
  containerEl.replaceChildren(root);
  restoreScrollState(scrollState);
}

function captureScrollState() {
  if (!containerEl) {
    return null;
  }

  const scrollable = containerEl.querySelector(
    ".clipboard-text-list, .clipboard-image-grid, .clipboard-favorites-list, .clipboard-preview-text"
  );
  return scrollable ? { top: scrollable.scrollTop, left: scrollable.scrollLeft } : null;
}

function restoreScrollState(scrollState) {
  if (!containerEl || !scrollState) {
    return;
  }

  const scrollable = containerEl.querySelector(
    ".clipboard-text-list, .clipboard-image-grid, .clipboard-favorites-list, .clipboard-preview-text"
  );
  if (scrollable) {
    scrollable.scrollTop = scrollState.top;
    scrollable.scrollLeft = scrollState.left;
  }
}

function renderHeader() {
  const header = element("header", { className: "clipboard-header" });
  const textItems = clipboardState.textItems ?? [];
  const imageItems = clipboardState.imageItems ?? [];
  const favoriteCount = getFavoriteItems().length;
  const status = clipboardState.privateMode
    ? tx("プライベート", "Private mode")
    : clipboardState.isMonitoring
      ? tx("監視中", "Watching")
      : clipboardState.providerVisible
        ? tx("一時停止", "Paused")
        : tx("非表示", "Provider hidden");
  header.append(
    element("div", { className: "clipboard-status" }, status),
    element("div", { className: "clipboard-count" }, `${tx("文字", "Text")} ${textItems.length}/${clipboardState.textLimit}`),
    element("div", { className: "clipboard-count" }, `${tx("画像", "Images")} ${imageItems.length}/${clipboardState.imageLimit}`),
    element("div", { className: "clipboard-count" }, `★ ${favoriteCount}`),
    element("div", { className: "clipboard-spacer" }),
    renderTextButton(clipboardState.privateMode ? tx("再開", "Resume") : tx("プライベート", "Private"), () => {
      void updateState("clipboard.setPrivateMode", { enabled: !clipboardState.privateMode });
    }, clipboardState.privateMode ? "is-active" : ""),
    renderIconButton("⌫", tx("お気に入り以外の履歴を消去", "Clear non-favorite history"), () => {
      activePreview = null;
      void updateState("clipboard.clear");
    })
  );

  if (clipboardState.lastErrorMessage) {
    header.append(element("div", { className: "clipboard-error" }, clipboardState.lastErrorMessage));
  }

  return header;
}

function renderSplit() {
  const split = element("div", { className: "clipboard-split" });
  split.append(
    renderSplitPane("text", tx("テキスト", "Text"), clipboardState.textItems ?? []),
    element("div", { className: "clipboard-split-divider", ariaHidden: "true" }),
    renderSplitPane("image", tx("画像", "Images"), clipboardState.imageItems ?? []),
  );
  return split;
}

function renderSplitPane(kind, title, items) {
  const pane = element("section", { className: `clipboard-pane is-${kind}` });
  const favoriteCount = items.filter((item) => item.favorite).length;
  pane.append(
    element("header", { className: "clipboard-pane-header" },
      element("strong", {}, title),
      element("span", {}, String(items.length)),
      element("small", {}, `★ ${favoriteCount}`),
    ),
    kind === "image" ? renderImagePanel(items, false) : renderTextPanel(items, false),
  );
  return pane;
}

function renderTextPanel(items, showDelete) {
  const panel = element("section", { className: "clipboard-panel" });
  if (items.length === 0) {
    panel.append(renderEmpty(tx("テキスト履歴はありません", "No text")));
    return panel;
  }

  const list = element("div", { className: "clipboard-text-list" });
  for (const item of items) {
    list.append(renderTextItem(item, showDelete || item.favorite));
  }
  panel.append(list);
  return panel;
}

function renderImagePanel(items, showDelete) {
  const panel = element("section", { className: "clipboard-panel" });
  if (items.length === 0) {
    panel.append(renderEmpty(tx("画像履歴はありません", "No images")));
    return panel;
  }

  const grid = element("div", { className: "clipboard-image-grid" });
  for (const item of items) {
    grid.append(renderImageItem(item, showDelete || item.favorite));
  }
  panel.append(grid);
  return panel;
}

function renderTextItem(item, showDelete) {
  const row = element("article", {
    className: `clipboard-text-item${item.favorite ? " is-favorite" : ""}`,
    tabIndex: "0",
    title: tx("テキストをプレビュー", "Preview text"),
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
    title: tx("画像をプレビュー", "Preview image"),
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
    preview.append(element("span", {}, tx("画像", "Image")));
  }

  const meta = element("div", { className: "clipboard-image-meta" }, `${item.width}x${item.height}`);
  tile.append(preview, element("div", { className: "clipboard-image-footer" }, meta, renderItemActions(item, "image", showDelete)));
  return tile;
}

function renderItemActions(item, kind, showDelete) {
  const actions = element("div", { className: "clipboard-item-actions" });
  actions.append(
    renderIconButton(item.favorite ? "★" : "☆", item.favorite ? tx("お気に入りを解除", "Remove favorite") : tx("お気に入りに追加", "Add favorite"), () => {
      void updateState("clipboard.toggleFavorite", { kind, id: item.id });
    }),
    renderIconButton("⧉", kind === "image" ? tx("画像をコピー", "Copy image") : tx("テキストをコピー", "Copy text"), () => {
      activePreview = null;
      void updateState(kind === "image" ? "clipboard.copyImage" : "clipboard.copyText", { id: item.id });
    }),
    renderDragButton("↗", kind === "image" ? tx("画像を別のアプリへドラッグ", "Drag image to another app") : tx("テキストを別のアプリへドラッグ", "Drag text to another app"), () => {
      void send("clipboard.startExternalDrag", { kind, id: item.id });
    })
  );

  if (showDelete) {
    actions.append(renderIconButton("🗑", tx("項目を削除", "Delete item"), () => {
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
    return renderSplit();
  }

  const preview = element("section", { className: `clipboard-full-preview is-${previewRef.kind}` });
  const title = previewRef.kind === "image"
    ? `${item.width}x${item.height}`
    : formatTime(item.createdAt);
  preview.append(
    element("header", { className: "clipboard-preview-header" },
      element("span", {}, title),
      element("div", { className: "clipboard-spacer" }),
      renderIconButton(item.favorite ? "★" : "☆", item.favorite ? tx("お気に入りを解除", "Remove favorite") : tx("お気に入りに追加", "Add favorite"), () => {
        void updateState("clipboard.toggleFavorite", { kind: previewRef.kind, id: item.id });
      }),
      renderIconButton("⧉", previewRef.kind === "image" ? tx("画像をコピー", "Copy image") : tx("テキストをコピー", "Copy text"), () => {
        activePreview = null;
        void updateState(previewRef.kind === "image" ? "clipboard.copyImage" : "clipboard.copyText", { id: item.id });
      }),
      renderIconButton("✕", tx("プレビューを閉じる", "Close preview"), () => {
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
      imageWrap.append(element("span", {}, tx("画像を表示できません", "Image unavailable")));
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

  return new Date(value).toLocaleTimeString(appState?.settings?.language === "en" ? "en-US" : "ja-JP", { hour: "2-digit", minute: "2-digit" });
}

function tx(ja, en) {
  return appState?.settings?.language === "en" ? en : ja;
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
