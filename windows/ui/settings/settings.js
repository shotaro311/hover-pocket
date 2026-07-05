import { on, request } from "../js/bridge.js";
import { labelForSize, setLanguage, t } from "../js/i18n.js";

const languageEl = document.querySelector("[data-language]");
const panelSizeEl = document.querySelector("[data-panel-size]");
const textSizeEl = document.querySelector("[data-text-size]");
const switchingEl = document.querySelector("[data-switching]");
const providerListEl = document.querySelector("[data-provider-list]");
const stickyUndoToastEl = document.querySelector("[data-sticky-undo-toast]");
const startupEl = document.querySelector("[data-startup]");
const startupStatusEl = document.querySelector("[data-startup-status]");
const statusEl = document.querySelector("[data-status]");
const resetEl = document.querySelector("[data-reset]");

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

  renderSegment(languageEl, [
    { id: "ja", label: "JA" },
    { id: "en", label: "EN" },
  ], state.settings.language, (language) => update("settings.setLanguage", { language }));

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
  renderStickySettings();
  startupEl.checked = Boolean(state.settings.startWithWindows);
  startupStatusEl.textContent = state.settings.startWithWindowsRegistered ? t("registered") : t("off");
}

function renderStickySettings() {
  stickyUndoToastEl.checked = stickyState?.preferences?.showUndoToast !== false;
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
