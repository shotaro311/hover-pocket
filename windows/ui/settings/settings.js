import { on, request } from "../js/bridge.js";
import { labelForSize, setLanguage, t } from "../js/i18n.js";

const languageEl = document.querySelector("[data-language]");
const displayPlacementEl = document.querySelector("[data-display-placement]");
const panelSizeEl = document.querySelector("[data-panel-size]");
const textSizeEl = document.querySelector("[data-text-size]");
const switchingEl = document.querySelector("[data-switching]");
const providerListEl = document.querySelector("[data-provider-list]");
const providerSelectionEl = document.querySelector("[data-provider-selection]");
const preferredProviderEl = document.querySelector("[data-preferred-provider]");
const pocketAppListEl = document.querySelector("[data-pocket-app-list]");
const handleIconEl = document.querySelector("[data-handle-icon]");
const handleSideAreaEl = document.querySelector("[data-handle-side-area]");
const disableFullscreenEl = document.querySelector("[data-disable-fullscreen]");
const clipboardPrivateEl = document.querySelector("[data-clipboard-private]");
const stickyUndoToastEl = document.querySelector("[data-sticky-undo-toast]");
const stickyGridSizeEl = document.querySelector("[data-sticky-grid-size]");
const startupEl = document.querySelector("[data-startup]");
const startupStatusEl = document.querySelector("[data-startup-status]");
const autoUpdatesEl = document.querySelector("[data-auto-updates]");
const checkUpdatesEl = document.querySelector("[data-check-updates]");
const updateStatusEl = document.querySelector("[data-update-status]");
const statusEl = document.querySelector("[data-status]");
const resetEl = document.querySelector("[data-reset]");
const resetBindingEl = document.querySelector("[data-reset-binding]");
const openDataFolderEl = document.querySelector("[data-open-data-folder]");

let currentState = null;
let stickyState = null;

on("state.changed", (state) => render(state));

bootstrap();

async function bootstrap() {
  currentState = await request("app.getState");
  stickyState = await request("sticky.getState");
  render(currentState);
  await request("app.ready");
}

function render(state) {
  currentState = state;
  setLanguage(state.settings.language);
  document.querySelectorAll("[data-i18n]").forEach((node) => {
    node.textContent = t(node.getAttribute("data-i18n"));
  });
  resetEl.textContent = t("resetDefaults");
  checkUpdatesEl.textContent = t("checkForUpdates");

  renderSegment(languageEl, [
    { id: "ja", label: "JA" },
    { id: "en", label: "EN" },
  ], state.settings.language, (language) => update("settings.setLanguage", { language }));

  renderSegment(displayPlacementEl, [
    { id: "main", label: t("mainDisplay") },
    { id: "sub", label: t("subDisplay") },
    { id: "all", label: t("allDisplays") },
  ], state.settings.displayPlacement, (displayPlacement) => update("settings.setDisplayPlacement", { displayPlacement }));

  renderSegment(panelSizeEl, state.panel.sizes.map((size) => ({
    id: size.id,
    label: labelForSize(size.id),
  })), state.settings.panelSize, (panelSize) => update("settings.setPanelSize", { panelSize }));

  renderSegment(textSizeEl, ["small", "medium", "large"].map((size) => ({
    id: size,
    label: labelForSize(size),
  })), state.settings.textSize, (textSize) => update("settings.setTextSize", { textSize }));

  renderSegment(switchingEl, [
    { id: "click", label: t("click") },
    { id: "hover", label: t("hover") },
  ], state.settings.switchingMode, (switchingMode) => update("settings.setSwitchingMode", { switchingMode }));

  renderProviders(state);
  renderProviderSelection(state);
  renderPocketApps(state);
  renderSegment(handleIconEl, [
    { id: "b", label: "B" },
    { id: "c", label: "C" },
    { id: "none", label: t("none") },
  ], state.settings.handleIcon, (handleIcon) => update("settings.setHandleIcon", { handleIcon }));
  handleSideAreaEl.checked = state.settings.showTopHandleSideArea !== false;
  disableFullscreenEl.checked = state.settings.disableTopEdgeInFullscreen !== false;
  clipboardPrivateEl.checked = Boolean(state.settings.clipboardPrivateMode);
  renderStickySettings();
  startupEl.checked = Boolean(state.settings.startWithWindows);
  startupStatusEl.textContent = state.settings.startWithWindowsRegistered ? t("registered") : t("off");
  autoUpdatesEl.checked = state.settings.autoCheckForUpdates !== false;
  updateStatusEl.textContent = state.updater?.message ?? "";
}

function renderPocketApps(state) {
  pocketAppListEl.replaceChildren();
  const apps = state.pocketApps ?? [];
  if (!apps.length) {
    const empty = document.createElement("p");
    empty.className = "settings-note";
    empty.textContent = state.settings.language === "en"
      ? "No Pocket App is active. AI-native features are off by default."
      : "有効なPocket Appはありません。AIネイティブ機能は既定でオフです。";
    pocketAppListEl.append(empty);
    return;
  }

  for (const app of apps) {
    const card = document.createElement("article");
    card.className = "pocket-app-card";
    const heading = document.createElement("div");
    heading.className = "pocket-app-heading";
    const name = document.createElement("strong");
    name.textContent = app.name;
    const version = document.createElement("span");
    version.textContent = `v${app.version}`;
    heading.append(name, version);

    const intent = document.createElement("p");
    intent.textContent = app.intent;
    const capabilities = document.createElement("code");
    capabilities.textContent = (app.capabilities ?? []).join(" · ");
    const boundary = document.createElement("p");
    boundary.className = "settings-note";
    boundary.textContent = state.settings.language === "en"
      ? "Definition, user data, and receipts are stored separately."
      : "定義、ユーザーデータ、実行履歴は分離して保持します。";
    card.append(heading, intent, capabilities, boundary);
    pocketAppListEl.append(card);
  }
}

function renderStickySettings() {
  stickyUndoToastEl.checked = stickyState?.preferences?.showUndoToast !== false;
  renderSegment(stickyGridSizeEl, ["small", "medium", "large"].map((size) => ({
    id: size,
    label: labelForSize(size),
  })), stickyState?.preferences?.gridSize ?? "medium", async (gridSize) => {
    stickyState = await request("sticky.setGridSize", { gridSize });
    renderStickySettings();
    statusEl.textContent = t("saved");
  });
}

function renderProviderSelection(state) {
  renderSegment(providerSelectionEl, [
    { id: "last", label: t("rememberLastProvider") },
    { id: "fixed", label: t("fixedProvider") },
  ], state.settings.rememberLastSelectedProvider === false ? "fixed" : "last", (mode) => {
    update("settings.setProviderSelection", { rememberLast: mode === "last" });
  });

  preferredProviderEl.replaceChildren();
  for (const provider of state.providers) {
    const option = document.createElement("option");
    option.value = provider.id;
    option.textContent = provider.title;
    option.selected = provider.id === state.settings.preferredProviderId;
    preferredProviderEl.append(option);
  }
  preferredProviderEl.disabled = state.settings.rememberLastSelectedProvider !== false;
}

function renderSegment(root, options, selectedId, onSelect) {
  root.replaceChildren();
  for (const option of options) {
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = option.label;
    button.setAttribute("aria-pressed", String(option.id === selectedId));
    button.addEventListener("click", () => onSelect(option.id));
    root.append(button);
  }
}

function renderProviders(state) {
  providerListEl.replaceChildren();
  for (const providerId of state.settings.providerOrder) {
    const provider = (state.allProviders ?? state.providers).find((candidate) => candidate.id === providerId)
      ?? { id: providerId, title: providerId };
    const row = document.createElement("div");
    row.className = "provider-row";

    const visible = document.createElement("label");
    visible.className = "provider-visible";
    const checkbox = document.createElement("input");
    checkbox.type = "checkbox";
    checkbox.checked = state.settings.providerVisibility[provider.id] !== false;
    checkbox.addEventListener("change", () => {
      update("settings.setProviderVisibility", { id: provider.id, visible: checkbox.checked });
    });
    const title = document.createElement("span");
    title.className = "provider-title";
    title.textContent = provider.title;
    visible.append(checkbox, title);

    const actions = document.createElement("div");
    actions.className = "provider-actions";
    const up = moveButton(t("up"), provider.id, "up");
    const down = moveButton(t("down"), provider.id, "down");
    actions.append(up, down);

    row.append(visible, actions);
    providerListEl.append(row);
  }
}

function moveButton(label, id, direction) {
  const button = document.createElement("button");
  button.type = "button";
  button.textContent = label;
  button.addEventListener("click", () => {
    update("settings.moveProvider", { id, direction });
  });
  return button;
}

startupEl.addEventListener("change", () => {
  update("settings.setStartWithWindows", { enabled: startupEl.checked });
});

autoUpdatesEl.addEventListener("change", () => {
  update("settings.setAutoCheckForUpdates", { enabled: autoUpdatesEl.checked });
});

clipboardPrivateEl.addEventListener("change", () => {
  update("settings.setClipboardPrivateMode", { enabled: clipboardPrivateEl.checked });
});

preferredProviderEl.addEventListener("change", () => {
  update("settings.setPreferredProvider", { id: preferredProviderEl.value });
});

handleSideAreaEl.addEventListener("change", () => {
  update("settings.setShowTopHandleSideArea", { visible: handleSideAreaEl.checked });
});

disableFullscreenEl.addEventListener("change", () => {
  update("settings.setDisableTopEdgeInFullscreen", { disabled: disableFullscreenEl.checked });
});

checkUpdatesEl.addEventListener("click", async () => {
  checkUpdatesEl.disabled = true;
  try {
    statusEl.textContent = "";
    updateStatusEl.textContent = t("checkingForUpdates");
    const result = await request("updates.check");
    updateStatusEl.textContent = result?.message ?? t("saved");
  } catch (error) {
    updateStatusEl.textContent = String(error?.message ?? error);
  } finally {
    checkUpdatesEl.disabled = false;
  }
});

stickyUndoToastEl.addEventListener("change", async () => {
  try {
    statusEl.textContent = "";
    stickyState = await request("sticky.setUndoToastVisible", { visible: stickyUndoToastEl.checked });
    renderStickySettings();
    statusEl.textContent = t("saved");
  } catch (error) {
    statusEl.textContent = String(error?.message ?? error);
    renderStickySettings();
  }
});

resetEl.addEventListener("click", () => {
  update("settings.resetDefaults");
});

resetBindingEl.addEventListener("click", () => {
  update("settings.resetPanelBinding");
});

openDataFolderEl.addEventListener("click", async () => {
  try {
    await request("settings.openDataFolder");
    statusEl.textContent = t("opened");
  } catch (error) {
    statusEl.textContent = String(error?.message ?? error);
  }
});

async function update(method, params = undefined) {
  try {
    statusEl.textContent = "";
    const state = await request(method, params);
    render(state);
    statusEl.textContent = t("saved");
  } catch (error) {
    statusEl.textContent = String(error?.message ?? error);
    render(currentState);
  }
}
