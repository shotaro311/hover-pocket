import { on, request } from "./bridge.js";
import { setLanguage, t } from "./i18n.js";
import { focusAiLaneInput, renderAiLane } from "../ailane/ailane.js";
import { renderCalculatorProvider } from "../providers/calculator/calculator.js";
import { renderStickyProvider } from "../providers/sticky/sticky.js";
import { renderTimerProvider } from "../providers/timer/timer.js";

const providerRenderers = {
  calculator: renderCalculatorProvider,
  sticky: renderStickyProvider,
  timer: renderTimerProvider,
};

const titleEl = document.querySelector("[data-provider-title]");
const providerContainerEl = document.querySelector("[data-provider-container]");
const providerIconsEl = document.querySelector("[data-provider-icons]");
const sizeSwitchEl = document.querySelector("[data-size-switch]");
const refreshButtonEl = document.querySelector("[data-refresh]");
const settingsButtonEl = document.querySelector("[data-settings]");
const aiLaneEl = document.querySelector("[data-ai-lane]");

/** @type {any} */
let currentState = null;

on("state.changed", (state) => {
  render(state);
});

on("panel.opened", (state) => {
  render(state);
  focusAiLaneInput();
});

bootstrap();

async function bootstrap() {
  currentState = await request("app.getState");
  render(currentState);
  await request("app.ready");
  window.__hoverPocketReady = true;
}

/**
 * @param {any} state
 */
function render(state) {
  currentState = state;
  document.documentElement.style.setProperty("--hp-header-height", `${state.panel.headerHeight}px`);
  document.documentElement.style.setProperty("--hp-ai-height", `${state.panel.aiLaneHeight}px`);
  document.documentElement.dataset.textSize = state.settings.textSize;
  setLanguage(state.settings.language);

  renderTitle(state);
  renderSizeSwitch(state);
  renderProviderIcons(state);
  renderProvider(state);
  renderAiLane(aiLaneEl, state, request, render);
  renderCommands();
}

/**
 * @param {any} state
 */
function renderTitle(state) {
  titleEl.textContent = state.selectedProvider?.title ?? "HoverPocket";
}

/**
 * @param {any} state
 */
function renderSizeSwitch(state) {
  sizeSwitchEl.replaceChildren();
  for (const size of state.panel.sizes) {
    const button = document.createElement("button");
    button.className = "hp-size-button";
    button.type = "button";
    button.textContent = size.label;
    button.setAttribute("aria-label", `Panel size ${size.label}`);
    button.setAttribute("aria-pressed", String(size.id === state.settings.panelSize));
    button.addEventListener("click", () => {
      request("settings.setPanelSize", { panelSize: size.id }).then(render);
    });
    sizeSwitchEl.append(button);
  }
}

/**
 * @param {any} state
 */
function renderProviderIcons(state) {
  providerIconsEl.replaceChildren();
  const switchOnHover = state.settings.switchingMode === "hover";

  for (const provider of state.providers) {
    const button = document.createElement("button");
    button.className = `hp-icon-button${provider.selected ? " is-selected" : ""}`;
    button.type = "button";
    button.setAttribute("aria-label", provider.title);
    button.innerHTML = iconSvg(provider.icon);

    const select = () => request("provider.select", { id: provider.id }).then(render);
    button.addEventListener("click", () => {
      if (!switchOnHover) {
        select();
      }
    });
    button.addEventListener("mouseenter", () => {
      if (switchOnHover) {
        select();
      }
    });
    providerIconsEl.append(button);
  }
}

/**
 * @param {any} state
 */
function renderProvider(state) {
  const provider = state.selectedProvider;
  providerContainerEl.replaceChildren();

  const renderer = providerRenderers[provider?.id];
  if (renderer) {
    renderer({
      container: providerContainerEl,
      provider,
      state,
      request,
      iconSvg,
    });
    return;
  }

  const card = document.createElement("article");
  card.className = "hp-provider-card";
  card.innerHTML = `
    <div>
      <div class="hp-provider-kicker">${escapeHtml(provider?.summary ?? "Provider")}</div>
      <h1 class="hp-provider-heading">${escapeHtml(provider?.title ?? "No provider")}</h1>
    </div>
    <div class="hp-provider-body">
      <p>${escapeHtml(provider?.body ?? "No visible provider is available.")}</p>
      <p>Header, provider content, and AI lane are rendered from C# state.</p>
    </div>
  `;
  providerContainerEl.append(card);
}

function renderCommands() {
  refreshButtonEl.innerHTML = iconSvg("refresh");
  refreshButtonEl.title = t("refresh");
  refreshButtonEl.setAttribute("aria-label", t("refresh"));
  refreshButtonEl.onclick = () => request("provider.refreshPlaceholder").then(render);

  settingsButtonEl.innerHTML = iconSvg("settings");
  settingsButtonEl.title = t("settings");
  settingsButtonEl.setAttribute("aria-label", t("settings"));
  settingsButtonEl.onclick = () => request("settings.open");
}

/**
 * @param {string} value
 */
function escapeHtml(value) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

/**
 * @param {string} name
 */
function iconSvg(name) {
  const icons = {
    calculator: '<svg viewBox="0 0 24 24" fill="none" stroke-width="1.8"><rect x="6" y="3" width="12" height="18" rx="2"/><path d="M9 7h6M9 11h.01M12 11h.01M15 11h.01M9 15h.01M12 15h.01M15 15h.01"/></svg>',
    timer: '<svg viewBox="0 0 24 24" fill="none" stroke-width="1.8"><path d="M10 2h4M12 14l3-3"/><circle cx="12" cy="13" r="8"/></svg>',
    note: '<svg viewBox="0 0 24 24" fill="none" stroke-width="1.8"><path d="M6 3h9l3 3v15H6z"/><path d="M14 3v4h4M9 11h6M9 15h4"/></svg>',
    refresh: '<svg viewBox="0 0 24 24" fill="none" stroke-width="1.8"><path d="M20 12a8 8 0 1 1-2.3-5.6"/><path d="M20 4v6h-6"/></svg>',
    settings: '<svg viewBox="0 0 24 24" fill="none" stroke-width="1.8"><path d="M12 8.5a3.5 3.5 0 1 0 0 7 3.5 3.5 0 0 0 0-7z"/><path d="M19 12a7 7 0 0 0-.1-1l2-1.5-2-3.4-2.4 1a8 8 0 0 0-1.8-1L14.4 3h-4.8l-.4 3.1a8 8 0 0 0-1.8 1l-2.4-1-2 3.4 2 1.5a7 7 0 0 0 0 2l-2 1.5 2 3.4 2.4-1a8 8 0 0 0 1.8 1l.4 3.1h4.8l.4-3.1a8 8 0 0 0 1.8-1l2.4 1 2-3.4-2-1.5c.1-.3.1-.7.1-1z"/></svg>',
  };
  return icons[name] ?? icons.note;
}

window.__hoverPocketVerify = {
  async run() {
    const state = await request("app.getState");
    const echo = await request("diagnostics.echo", { value: "ui-round-trip" });
    const originalProvider = state.selectedProvider?.id;
    const targetProvider = state.providers.find((provider) => provider.id !== originalProvider) ?? state.providers[0];
    const switchedState = await request("provider.select", { id: targetProvider.id });
    const originalPanelSize = state.settings.panelSize;
    const probePanelSize = originalPanelSize === "small" ? "medium" : "small";
    const resizedState = await request("settings.setPanelSize", { panelSize: probePanelSize });
    await request("settings.setPanelSize", { panelSize: originalPanelSize });

    return {
      echoOk: echo?.value === "ui-round-trip",
      providerSwitchOk: switchedState.selectedProvider?.id === targetProvider.id,
      settingsWriteOk: resizedState.settings?.panelSize === probePanelSize,
      originalProvider,
      switchedProvider: switchedState.selectedProvider?.id,
      originalPanelSize,
      probePanelSize,
    };
  },
};
