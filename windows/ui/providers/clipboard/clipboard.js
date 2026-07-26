let bridgeRequest = null;
let containerEl = null;
let appState = null;
let clipboardState = null;
let clipboardStateSignature = "";
let activePreview = null;
let activeTab = "all";
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
  activePreview = null;
  activeTab = "all";
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
  const stableRefreshOk = rootBeforeRefresh === containerEl?.querySelector(".clipboard-root")
    && renderCount === renderCountBeforeRefresh;
  const split = containerEl?.querySelector(".clipboard-split");
  const splitStyle = split ? getComputedStyle(split) : null;
  const splitColumns = splitStyle?.gridTemplateColumns?.split(" ").map((value) => Number.parseFloat(value)) ?? [];
  const allTab = containerEl?.querySelector('[data-clipboard-tab="all"]');
  const favoritesTab = containerEl?.querySelector('[data-clipboard-tab="favorites"]');
  favoritesTab?.click();
  const selectedFavoritesTab = containerEl?.querySelector('[data-clipboard-tab="favorites"]');
  const favoritesSelected = selectedFavoritesTab?.getAttribute("aria-selected") === "true"
    && Boolean(containerEl?.querySelector(".clipboard-split.is-favorites"));
  containerEl?.querySelector('[data-clipboard-tab="all"]')?.click();
  const firstItem = containerEl?.querySelector("[data-clipboard-item]");
  firstItem?.click();
  const preview = containerEl?.querySelector(".clipboard-full-preview");
  const previewContent = preview?.querySelector(".clipboard-preview-image img, .clipboard-preview-text");
  const previewStyle = previewContent ? getComputedStyle(previewContent) : null;
  const previewBehaviorOk = !firstItem || Boolean(
    preview
    && previewContent
    && (previewContent.classList.contains("clipboard-preview-text")
      ? ["auto", "scroll"].includes(previewStyle?.overflowY ?? "")
      : previewStyle?.objectFit === "contain"),
  );
  preview?.querySelector('[data-clipboard-action="close"]')?.click();
  return {
    clipboardBridgeOk: Array.isArray(state?.textItems) && Array.isArray(state?.imageItems),
    clipboardFavoriteFieldOk: [...textItems, ...imageItems].every((item) => typeof item.favorite === "boolean"),
    clipboardPrivateMode: Boolean(state?.privateMode),
    clipboardMonitoringKnown: typeof state?.isMonitoring === "boolean",
    clipboardStableRefreshOk: stableRefreshOk,
    clipboardSplitViewOk: Boolean(
      containerEl?.querySelector(".clipboard-split .clipboard-pane.is-text")
      && containerEl?.querySelector(".clipboard-split .clipboard-pane.is-image"),
    ),
    clipboardCenteredSplitOk: splitColumns.length === 3
      && Math.abs(splitColumns[0] - splitColumns[2]) <= 1,
    clipboardTabsOk: Boolean(allTab && favoritesTab && favoritesSelected),
    clipboardDeleteActionsOk: [...(containerEl?.querySelectorAll("[data-clipboard-item]") ?? [])]
      .every((item) => item.querySelector('[data-clipboard-action="delete"]')),
    clipboardNoDragActionOk: !containerEl?.querySelector('[data-clipboard-action="drag"]'),
    clipboardNoResolutionOk: !containerEl?.querySelector("[data-clipboard-resolution]"),
    clipboardPreviewBehaviorOk: previewBehaviorOk,
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
  root.append(activePreview ? renderPreview(activePreview) : renderBrowser());
  containerEl.replaceChildren(root);
  restoreScrollState(scrollState);
}

function captureScrollState() {
  if (!containerEl) {
    return null;
  }

  return [...containerEl.querySelectorAll("[data-scroll-key]")].map((scrollable) => ({
    key: scrollable.dataset.scrollKey,
    top: scrollable.scrollTop,
    left: scrollable.scrollLeft,
  }));
}

function restoreScrollState(scrollState) {
  if (!containerEl || !scrollState) {
    return;
  }

  for (const entry of scrollState) {
    const scrollable = containerEl.querySelector(`[data-scroll-key="${entry.key}"]`);
    if (scrollable) {
      scrollable.scrollTop = entry.top;
      scrollable.scrollLeft = entry.left;
    }
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
    renderIconButton(trashIcon(), tx("お気に入り以外の履歴を消去", "Clear non-favorite history"), () => {
      activePreview = null;
      void updateState("clipboard.clear");
    }, "is-danger")
  );

  if (clipboardState.lastErrorMessage) {
    header.append(element("div", { className: "clipboard-error" }, clipboardState.lastErrorMessage));
  }

  return header;
}

function renderBrowser() {
  const browser = element("div", { className: "clipboard-browser" });
  browser.append(renderTabs(), renderSplit(activeTab === "favorites"));
  return browser;
}

function renderTabs() {
  const tabs = element("div", { className: "clipboard-tabs", role: "tablist" });
  const allCount = (clipboardState.textItems?.length ?? 0) + (clipboardState.imageItems?.length ?? 0);
  const items = [
    ["all", tx("すべて", "All"), allCount],
    ["favorites", tx("お気に入り", "Favorites"), getFavoriteItems().length],
  ];
  for (const [id, label, count] of items) {
    const button = element("button", {
      className: `clipboard-tab${activeTab === id ? " is-active" : ""}`,
      type: "button",
      role: "tab",
      ariaSelected: String(activeTab === id),
      "data-clipboard-tab": id,
    }, element("span", {}, label), element("strong", {}, String(count)));
    button.addEventListener("click", () => {
      if (activeTab === id) {
        return;
      }
      activeTab = id;
      activePreview = null;
      render();
    });
    tabs.append(button);
  }
  return tabs;
}

function renderSplit(favoritesOnly = false) {
  const textItems = (clipboardState.textItems ?? []).filter((item) => !favoritesOnly || item.favorite);
  const imageItems = (clipboardState.imageItems ?? []).filter((item) => !favoritesOnly || item.favorite);
  const split = element("div", { className: `clipboard-split${favoritesOnly ? " is-favorites" : ""}` });
  split.append(
    renderSplitPane("text", tx("テキスト", "Text"), textItems),
    element("div", { className: "clipboard-split-divider", ariaHidden: "true" }),
    renderSplitPane("image", tx("画像", "Images"), imageItems),
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
    kind === "image" ? renderImagePanel(items) : renderTextPanel(items),
  );
  return pane;
}

function renderTextPanel(items) {
  const panel = element("section", { className: "clipboard-panel" });
  if (items.length === 0) {
    panel.append(renderEmpty(tx("テキスト履歴はありません", "No text")));
    return panel;
  }

  const list = element("div", { className: "clipboard-text-list", "data-scroll-key": `${activeTab}-text` });
  for (const item of items) {
    list.append(renderTextItem(item));
  }
  panel.append(list);
  return panel;
}

function renderImagePanel(items) {
  const panel = element("section", { className: "clipboard-panel" });
  if (items.length === 0) {
    panel.append(renderEmpty(tx("画像履歴はありません", "No images")));
    return panel;
  }

  const grid = element("div", { className: "clipboard-image-grid", "data-scroll-key": `${activeTab}-image` });
  for (const item of items) {
    grid.append(renderImageItem(item));
  }
  panel.append(grid);
  return panel;
}

function renderTextItem(item) {
  const row = element("article", {
    className: `clipboard-text-item${item.favorite ? " is-favorite" : ""}`,
    tabIndex: "0",
    title: tx("テキストをプレビュー", "Preview text"),
    "data-clipboard-item": item.id,
    "data-clipboard-kind": "text",
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
    renderItemActions(item, "text")
  );
  return row;
}

function renderImageItem(item) {
  const tile = element("article", {
    className: `clipboard-image-item${item.favorite ? " is-favorite" : ""}`,
    tabIndex: "0",
    title: tx("画像をプレビュー", "Preview image"),
    "data-clipboard-item": item.id,
    "data-clipboard-kind": "image",
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
    preview.append(element("img", { src: item.dataUrl, alt: tx("クリップボード画像", "Clipboard image") }));
  } else {
    preview.append(element("span", {}, tx("画像", "Image")));
  }

  const meta = element("div", { className: "clipboard-image-meta" }, formatTime(item.createdAt));
  tile.append(preview, element("div", { className: "clipboard-image-footer" }, meta, renderItemActions(item, "image")));
  return tile;
}

function renderItemActions(item, kind) {
  const actions = element("div", { className: "clipboard-item-actions" });
  actions.append(
    renderIconButton(item.favorite ? "★" : "☆", item.favorite ? tx("お気に入りを解除", "Remove favorite") : tx("お気に入りに追加", "Add favorite"), () => {
      void updateState("clipboard.toggleFavorite", { kind, id: item.id });
    }),
    renderIconButton("⧉", kind === "image" ? tx("画像をコピー", "Copy image") : tx("テキストをコピー", "Copy text"), () => {
      activePreview = null;
      void updateState(kind === "image" ? "clipboard.copyImage" : "clipboard.copyText", { id: item.id });
    }, "", "copy"),
    renderIconButton(trashIcon(), tx("項目を削除", "Delete item"), () => {
      activePreview = null;
      void updateState("clipboard.deleteItem", { kind, id: item.id });
    }, "is-danger", "delete")
  );
  return actions;
}

function renderPreview(previewRef) {
  const item = findItem(previewRef.kind, previewRef.id);
  if (!item) {
    activePreview = null;
    return renderBrowser();
  }

  const preview = element("section", { className: `clipboard-full-preview is-${previewRef.kind}` });
  const title = formatTime(item.createdAt);
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
      }, "", "copy"),
      renderIconButton(trashIcon(), tx("項目を削除", "Delete item"), () => {
        activePreview = null;
        void updateState("clipboard.deleteItem", { kind: previewRef.kind, id: item.id });
      }, "is-danger", "delete"),
      renderIconButton("✕", tx("プレビューを閉じる", "Close preview"), () => {
        activePreview = null;
        render();
      }, "", "close")
    )
  );

  if (previewRef.kind === "image") {
    const imageWrap = element("div", { className: "clipboard-preview-image" });
    if (item.dataUrl) {
      imageWrap.append(element("img", { src: item.dataUrl, alt: tx("クリップボード画像", "Clipboard image") }));
    } else {
      imageWrap.append(element("span", {}, tx("画像を表示できません", "Image unavailable")));
    }
    preview.append(imageWrap);
  } else {
    preview.append(element("pre", { className: "clipboard-preview-text", "data-scroll-key": "preview-text" }, item.text ?? ""));
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

function renderIconButton(content, label, onClick, tone = "", action = "") {
  const button = element("button", {
    className: `clipboard-icon-button ${tone}`.trim(),
    type: "button",
    ariaLabel: label,
    title: label,
    "data-clipboard-action": action || undefined,
  }, content);
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

function formatTime(value) {
  if (!value) {
    return "";
  }

  return new Date(value).toLocaleTimeString(appState?.settings?.language === "en" ? "en-US" : "ja-JP", { hour: "2-digit", minute: "2-digit" });
}

function trashIcon() {
  const icon = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  icon.setAttribute("viewBox", "0 0 24 24");
  icon.setAttribute("aria-hidden", "true");
  icon.innerHTML = '<path d="M4 7h16M9 7V4h6v3m-8 0 1 13h8l1-13M10 11v5m4-5v5"/>';
  return icon;
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
