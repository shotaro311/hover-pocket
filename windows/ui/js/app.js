import { on, request } from "./bridge.js";
import { labelForSize, setLanguage, t } from "./i18n.js";
import { renderCalculatorProvider, runCalculatorUiVerify } from "../providers/calculator/calculator.js";
import { renderCalendarProvider } from "../providers/calendar/calendar.js";
import { renderClipboardProvider, runClipboardUiVerify } from "../providers/clipboard/clipboard.js";
import { renderControlsProvider } from "../providers/controls/controls.js";
import { renderStickyProvider } from "../providers/sticky/sticky.js";
import { renderTimerProvider } from "../providers/timer/timer.js";
import { renderPocketSurfaceProvider, runPocketSurfaceUiVerify } from "../providers/pocket-surface/pocket-surface.js";

const providerRenderers = {
  controls: renderControlsProvider,
  calculator: renderCalculatorProvider,
  calendar: renderCalendarProvider,
  "today-focus": renderPocketSurfaceProvider,
  clipboard: renderClipboardProvider,
  sticky: renderStickyProvider,
  timer: renderTimerProvider,
};

const titleEl = document.querySelector("[data-provider-title]");
const providerContainerEl = document.querySelector("[data-provider-container]");
const providerIconsEl = document.querySelector("[data-provider-icons]");
const sizeSwitchEl = document.querySelector("[data-size-switch]");
const refreshButtonEl = document.querySelector("[data-refresh]");
const settingsButtonEl = document.querySelector("[data-settings]");

/** @type {any} */
let currentState = null;
let providerCleanup = null;
let providerRefresh = null;
let providerStateFlush = null;
let providerStateTransitionBegin = null;
let providerStateTransitionRelease = null;
const providerStateTransitionLeases = new Map();
let activeProviderKey = "";
let renderTask = Promise.resolve(true);
let pendingProviderId = null;
let providerSelectionTask = null;
let textInputActivationTask = null;
let draggingProviderId = null;
let suppressProviderSelection = false;

on("state.changed", (state) => {
  void render(state);
});

on("panel.opened", (state) => {
  void render(state, { refreshProvider: true });
});

bootstrap();

async function bootstrap() {
  const initialState = await request("app.getState");
  await render(initialState);
  await request("app.ready");
  window.__hoverPocketReady = true;
}

/**
 * @param {any} state
 * @param {{ forceProvider?: boolean, refreshProvider?: boolean }=} options
 */
function render(state, options = {}) {
  const scheduled = renderTask.then(() => renderNow(state, options));
  renderTask = scheduled.catch(() => false);
  return scheduled;
}

async function renderNow(state, options = {}) {
  const providerKey = providerRenderKey(state);
  const providerWillRemount = Boolean(options.forceProvider) || providerKey !== activeProviderKey;
  if (providerWillRemount && !await disposeActiveProvider()) {
    return false;
  }

  currentState = state;
  document.documentElement.style.setProperty("--hp-header-height", `${state.panel.headerHeight}px`);
  document.documentElement.style.setProperty("--hp-ai-height", `${state.panel.aiLaneHeight}px`);
  document.documentElement.dataset.textSize = state.settings.textSize;
  document.documentElement.dataset.panelSize = state.settings.panelSize;
  setLanguage(state.settings.language);

  renderTitle(state);
  renderSizeSwitch(state);
  renderProviderIcons(state);
  renderProvider(state, options, providerWillRemount);
  renderCommands();
  return true;
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
    button.textContent = labelForSize(size.id);
    button.setAttribute("aria-label", `${t("panelSize")} ${labelForSize(size.id)}`);
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
  const providerIds = new Set(state.providers.map((provider) => provider.id));
  for (const child of [...providerIconsEl.children]) {
    if (!providerIds.has(child.dataset.providerId)) {
      child.remove();
    }
  }

  state.providers.forEach((provider, index) => {
    let button = [...providerIconsEl.children]
      .find((candidate) => candidate.dataset.providerId === provider.id);
    if (!button) {
      button = createProviderIconButton(provider.id);
    }
    if (providerIconsEl.children[index] !== button) {
      providerIconsEl.insertBefore(button, providerIconsEl.children[index] ?? null);
    }
    button.innerHTML = iconSvg(provider.icon);
    button.setAttribute("aria-label", provider.title);
    button.classList.toggle("is-selected", provider.selected);
    button.setAttribute("aria-pressed", String(provider.selected));
    button.title = provider.title;
  });
}

function createProviderIconButton(providerId) {
  const button = document.createElement("button");
  button.className = "hp-icon-button";
  button.type = "button";
  button.draggable = true;
  button.dataset.providerId = providerId;
  button.addEventListener("click", () => {
    if (!suppressProviderSelection && currentState?.settings?.switchingMode !== "hover") {
      queueProviderSelection(button.dataset.providerId);
    }
  });
  button.addEventListener("mouseenter", () => {
    if (!draggingProviderId && currentState?.settings?.switchingMode === "hover") {
      queueProviderSelection(button.dataset.providerId);
    }
  });
  button.addEventListener("dragstart", (event) => {
    draggingProviderId = button.dataset.providerId;
    suppressProviderSelection = true;
    button.classList.add("is-dragging");
    if (event.dataTransfer) {
      event.dataTransfer.effectAllowed = "move";
      event.dataTransfer.setData("text/plain", draggingProviderId);
    }
  });
  button.addEventListener("dragenter", (event) => {
    if (!draggingProviderId || draggingProviderId === button.dataset.providerId) {
      return;
    }
    event.preventDefault();
    const dragged = [...providerIconsEl.children]
      .find((candidate) => candidate.dataset.providerId === draggingProviderId);
    if (!dragged) {
      return;
    }
    const bounds = button.getBoundingClientRect();
    providerIconsEl.insertBefore(dragged, event.clientX > bounds.left + bounds.width / 2 ? button.nextSibling : button);
  });
  button.addEventListener("dragover", (event) => {
    if (draggingProviderId) {
      event.preventDefault();
      if (event.dataTransfer) {
        event.dataTransfer.dropEffect = "move";
      }
    }
  });
  button.addEventListener("drop", (event) => {
    event.preventDefault();
    void persistProviderIconOrder();
  });
  button.addEventListener("dragend", () => {
    if (draggingProviderId) {
      draggingProviderId = null;
      renderProviderIcons(currentState);
    }
    button.classList.remove("is-dragging");
    window.setTimeout(() => {
      suppressProviderSelection = false;
    }, 0);
  });
  return button;
}

async function persistProviderIconOrder() {
  if (!currentState || !draggingProviderId) {
    return;
  }
  const visibleOrder = [...providerIconsEl.children].map((button) => button.dataset.providerId);
  const visibleIds = new Set(visibleOrder);
  let visibleIndex = 0;
  const providerOrder = currentState.settings.providerOrder.map((id) => (
    visibleIds.has(id) ? visibleOrder[visibleIndex++] : id
  ));
  draggingProviderId = null;
  for (const button of providerIconsEl.children) {
    button.classList.remove("is-dragging");
  }
  try {
    await render(await request("settings.setProviderOrder", { providerOrder }));
  } catch {
    renderProviderIcons(currentState);
  } finally {
    window.setTimeout(() => {
      suppressProviderSelection = false;
    }, 0);
  }
}

function queueProviderSelection(providerId) {
  if (!providerId || currentState?.selectedProvider?.id === providerId) {
    return;
  }

  pendingProviderId = providerId;
  providerSelectionTask ??= flushProviderSelection().finally(() => {
    providerSelectionTask = null;
  });
}

async function flushProviderSelection() {
  while (pendingProviderId) {
    const providerId = pendingProviderId;
    pendingProviderId = null;
    if (currentState?.selectedProvider?.id === providerId) {
      continue;
    }
    const selected = await selectProvider(providerId);
    if (!selected) return;
  }
}

async function disposeActiveProvider() {
  const cleanup = providerCleanup;
  if (!cleanup) return true;
  const disposed = await cleanup();
  if (disposed === false) return false;
  if (providerCleanup === cleanup) {
    providerCleanup = null;
    providerRefresh = null;
    providerStateFlush = null;
    providerStateTransitionBegin = null;
    providerStateTransitionRelease = null;
  }
  return true;
}

async function selectProvider(providerId, selectRequest = request) {
  if (!providerId || currentState?.selectedProvider?.id === providerId) {
    return currentState;
  }

  const previousState = currentState;
  if (!await disposeActiveProvider()) return null;
  try {
    const selected = await selectRequest("provider.select", { id: providerId });
    await render(selected);
    return selected;
  } catch (error) {
    if (previousState && currentState?.selectedProvider?.id === previousState.selectedProvider?.id) {
      await render(previousState, { forceProvider: true });
    }
    throw error;
  }
}

document.addEventListener("focusin", (event) => {
  const target = event.target;
  if (!isTextEntryTarget(target) || textInputActivationTask) {
    return;
  }

  textInputActivationTask = request("panel.beginTextInput")
    .then(() => {
      if (target.isConnected && document.activeElement !== target) {
        target.focus({ preventScroll: true });
      }
    })
    .finally(() => {
      textInputActivationTask = null;
    });
}, true);

function isTextEntryTarget(target) {
  if (!(target instanceof HTMLElement)) {
    return false;
  }
  if (target instanceof HTMLTextAreaElement || target.isContentEditable) {
    return true;
  }
  if (!(target instanceof HTMLInputElement)) {
    return false;
  }
  return !["button", "checkbox", "color", "file", "hidden", "radio", "range", "reset", "submit"]
    .includes(target.type);
}

/**
 * @param {any} state
 * @param {{ forceProvider?: boolean, refreshProvider?: boolean }} options
 * @param {boolean} providerWillRemount
 */
function renderProvider(state, options, providerWillRemount) {
  const provider = state.selectedProvider;
  const providerKey = providerRenderKey(state);
  if (!providerWillRemount) {
    if (options.refreshProvider) {
      void providerRefresh?.();
    }
    return;
  }

  activeProviderKey = providerKey;
  providerContainerEl.replaceChildren();
  providerContainerEl.classList.remove("is-provider-entering");
  void providerContainerEl.offsetWidth;
  providerContainerEl.classList.add("is-provider-entering");

  const renderer = provider?.id?.startsWith("generated-pocket-app:")
    ? renderPocketSurfaceProvider
    : providerRenderers[provider?.id];
  if (renderer) {
    const lifecycle = renderer({
      container: providerContainerEl,
      provider,
      state,
      request,
      iconSvg,
    });
    providerCleanup = typeof lifecycle === "function"
      ? lifecycle
      : typeof lifecycle?.dispose === "function"
        ? () => lifecycle.dispose()
        : null;
    providerRefresh = typeof lifecycle?.refresh === "function"
      ? () => lifecycle.refresh()
      : null;
    providerStateFlush = typeof lifecycle?.flushPendingState === "function"
      ? () => lifecycle.flushPendingState()
      : null;
    providerStateTransitionBegin = typeof lifecycle?.beginStateTransition === "function"
      ? () => lifecycle.beginStateTransition()
      : null;
    providerStateTransitionRelease = typeof lifecycle?.releaseStateTransition === "function"
      ? () => lifecycle.releaseStateTransition()
      : null;
    void attachActiveStateTransitionLeases(state.pocketSurface?.appId);
    return;
  }

  const card = document.createElement("article");
  card.className = "hp-provider-card";
  card.innerHTML = `
    <div>
      <div class="hp-provider-kicker">${escapeHtml(provider?.summary ?? t("tool"))}</div>
      <h1 class="hp-provider-heading">${escapeHtml(provider?.title ?? t("noTool"))}</h1>
    </div>
    <div class="hp-provider-body">
      <p>${escapeHtml(provider?.body ?? t("noVisibleTool"))}</p>
    </div>
  `;
  providerContainerEl.append(card);
}

window.__hoverPocketFlushActiveProviderState = async (appId, operationId) => {
  if (!operationId || providerStateTransitionLeases.has(operationId)) {
    return false;
  }
  const lease = {
    appId,
    releases: new Set(),
  };
  providerStateTransitionLeases.set(operationId, lease);
  if (currentState?.pocketSurface?.appId !== appId
    || !providerStateTransitionBegin
    || !providerStateTransitionRelease) {
    return true;
  }
  lease.releases.add(providerStateTransitionRelease);
  return await providerStateTransitionBegin() !== false;
};

window.__hoverPocketCompleteActiveProviderStateTransition = (operationId, releaseInteraction) => {
  const lease = providerStateTransitionLeases.get(operationId);
  if (!lease) return true;
  providerStateTransitionLeases.delete(operationId);
  if (releaseInteraction) {
    for (const release of lease.releases) release();
  }
  return true;
};

async function attachActiveStateTransitionLeases(appId) {
  if (!appId || !providerStateTransitionBegin || !providerStateTransitionRelease) return;
  const begin = providerStateTransitionBegin;
  const release = providerStateTransitionRelease;
  const attached = [];
  for (const lease of providerStateTransitionLeases.values()) {
    if (lease.appId !== appId || lease.releases.has(release)) continue;
    lease.releases.add(release);
    attached.push(Promise.resolve(begin()).catch(() => false));
  }
  await Promise.all(attached);
}

function providerRenderKey(state) {
  const surface = state.pocketSurface;
  const surfaceIdentity = surface
    ? `:${surface.appId ?? ""}:${surface.version ?? ""}:${surface.manifestDigest ?? ""}`
    : "";
  return `${state.selectedProvider?.id ?? "none"}:${state.settings.language}${surfaceIdentity}`;
}

function renderCommands() {
  refreshButtonEl.innerHTML = iconSvg("refresh");
  refreshButtonEl.title = t("refresh");
  refreshButtonEl.setAttribute("aria-label", t("refresh"));
  refreshButtonEl.onclick = () => {
    if (providerRefresh) {
      void providerRefresh();
      return;
    }
    request("provider.refreshPlaceholder").then((state) => render(state, { forceProvider: true }));
  };

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
    controls: '<svg viewBox="0 0 24 24" fill="none" stroke-width="1.8"><path d="M4 7h10M18 7h2M4 17h2M10 17h10M14 4v6M6 14v6"/><circle cx="14" cy="7" r="2"/><circle cx="8" cy="17" r="2"/></svg>',
    calculator: '<svg viewBox="0 0 24 24" fill="none" stroke-width="1.8"><rect x="6" y="3" width="12" height="18" rx="2"/><path d="M9 7h6M9 11h.01M12 11h.01M15 11h.01M9 15h.01M12 15h.01M15 15h.01"/></svg>',
    calendar: '<svg viewBox="0 0 24 24" fill="none" stroke-width="1.8"><rect x="4" y="5" width="16" height="15" rx="2"/><path d="M8 3v4M16 3v4M4 10h16M8 14h.01M12 14h.01M16 14h.01M8 17h.01M12 17h.01"/></svg>',
    clipboard: '<svg viewBox="0 0 24 24" fill="none" stroke-width="1.8"><path d="M9 4h6l1 2h2v15H6V6h2z"/><path d="M9 4h6v4H9zM9 12h6M9 16h4"/></svg>',
    timer: '<svg viewBox="0 0 24 24" fill="none" stroke-width="1.8"><path d="M10 2h4M12 14l3-3"/><circle cx="12" cy="13" r="8"/></svg>',
    target: '<svg viewBox="0 0 24 24" fill="none" stroke-width="1.8"><circle cx="12" cy="12" r="8"/><circle cx="12" cy="12" r="4"/><path d="M12 2v3M22 12h-3M12 22v-3M2 12h3"/></svg>',
    note: '<svg viewBox="0 0 24 24" fill="none" stroke-width="1.8"><path d="M6 3h9l3 3v15H6z"/><path d="M14 3v4h4M9 11h6M9 15h4"/></svg>',
    refresh: '<svg viewBox="0 0 24 24" fill="none" stroke-width="1.8"><path d="M20 12a8 8 0 1 1-2.3-5.6"/><path d="M20 4v6h-6"/></svg>',
    settings: '<svg viewBox="0 0 24 24" fill="none" stroke-width="1.8"><path d="M12 8.5a3.5 3.5 0 1 0 0 7 3.5 3.5 0 0 0 0-7z"/><path d="M19 12a7 7 0 0 0-.1-1l2-1.5-2-3.4-2.4 1a8 8 0 0 0-1.8-1L14.4 3h-4.8l-.4 3.1a8 8 0 0 0-1.8 1l-2.4-1-2 3.4 2 1.5a7 7 0 0 0 0 2l-2 1.5 2 3.4 2.4-1a8 8 0 0 0 1.8 1l.4 3.1h4.8l.4-3.1a8 8 0 0 0 1.8-1l2.4 1 2-3.4-2-1.5c.1-.3.1-.7.1-1z"/></svg>',
  };
  return icons[name] ?? icons.note;
}

window.__hoverPocketVerify = {
  async run() {
    window.__hoverPocketVerifyStep = "get-state";
    const state = await request("app.getState");
    window.__hoverPocketVerifyStep = "echo";
    const echo = await request("diagnostics.echo", { value: "ui-round-trip" });
    const originalProvider = state.selectedProvider?.id;
    const controlsProvider = state.providers.find((provider) => provider.id === "controls");
    let controlsRenderedOk = false;
    let controlsLayoutOk = false;
    let controlsHitAreasOk = false;
    let controlsFallbackLayerOk = false;
    let controlsStableRefreshOk = false;
    let controlsBrightnessResolvedOk = false;
    let controlsMediaActionsOk = false;
    if (controlsProvider) {
      window.__hoverPocketVerifyStep = "select-controls";
      await request("provider.select", { id: controlsProvider.id });
      window.__hoverPocketVerifyStep = "render-controls";
      const controlsRoot = await waitForElement(".hp-controls:not(.is-loading)", 4500);
      if (controlsRoot) {
        window.__hoverPocketVerifyStep = "resolve-controls-brightness";
        controlsBrightnessResolvedOk = Boolean(await waitForElement(
          ".hp-controls-section:first-child .hp-control-row:not(.is-detecting)",
          4500,
        ));
        const rootBounds = controlsRoot.getBoundingClientRect();
        const sections = [...controlsRoot.querySelectorAll(":scope > .hp-controls-section")];
        controlsRenderedOk = !controlsRoot.classList.contains("is-error") && sections.length === 3;
        controlsLayoutOk = rootBounds.width > 0
          && rootBounds.height > 0
          && sections.every((section) => {
            const bounds = section.getBoundingClientRect();
            return bounds.left >= rootBounds.left - 1
              && bounds.top >= rootBounds.top - 1
              && bounds.right <= rootBounds.right + 1
              && bounds.bottom <= rootBounds.bottom + 1;
          });
        const mediaButtons = [...controlsRoot.querySelectorAll(".hp-media-commands button")];
        controlsHitAreasOk = mediaButtons.length >= 6 && mediaButtons.every((button) => {
          const bounds = button.getBoundingClientRect();
          return bounds.width >= 32 && bounds.height >= 32;
        });
        controlsMediaActionsOk = Boolean(
          (controlsRoot.querySelector("[data-open-media-source]") || controlsRoot.querySelector(".hp-media.is-unavailable"))
          && controlsRoot.querySelector("[data-rate-decrease]")
          && controlsRoot.querySelector("[data-rate-increase]")
          && controlsRoot.querySelector("[data-playback-rate]"),
        );
        controlsFallbackLayerOk = Boolean(
          controlsRoot.querySelector(".hp-media-fallback")
          && controlsRoot.querySelector("canvas[data-live-preview]"),
        ) || Boolean(controlsRoot.querySelector(".hp-media.is-empty"));
        controlsStableRefreshOk = Boolean(await controlsRoot.__verifyStableRefresh?.());
      }
    }
    const clipboardProvider = state.providers.find((provider) => provider.id === "clipboard");
    let clipboardStableProviderOk = false;
    let clipboardStableRefreshOk = false;
    let clipboardSplitViewOk = false;
    let clipboardCenteredSplitOk = false;
    let clipboardTabsOk = false;
    let clipboardDeleteActionsOk = false;
    let clipboardNoDragActionOk = false;
    let clipboardNoResolutionOk = false;
    let clipboardPreviewBehaviorOk = false;
    let providerIconStableOk = false;
    if (clipboardProvider) {
      window.__hoverPocketVerifyStep = "select-clipboard";
      await request("provider.select", { id: clipboardProvider.id });
      window.__hoverPocketVerifyStep = "render-clipboard";
      const clipboardRoot = await waitForElement(".clipboard-root", 4500);
      window.__hoverPocketVerifyStep = "verify-clipboard-refresh";
      const clipboardVerify = await runClipboardUiVerify(request);
      window.__hoverPocketVerifyStep = "render-same-clipboard";
      const clipboardRootAfterInteraction = document.querySelector(".clipboard-root");
      const clipboardIcon = [...providerIconsEl.children]
        .find((candidate) => candidate.dataset.providerId === clipboardProvider.id);
      await render(currentState);
      clipboardStableProviderOk = clipboardRootAfterInteraction === document.querySelector(".clipboard-root");
      clipboardStableRefreshOk = clipboardVerify.clipboardStableRefreshOk;
      clipboardSplitViewOk = clipboardVerify.clipboardSplitViewOk;
      clipboardCenteredSplitOk = clipboardVerify.clipboardCenteredSplitOk;
      clipboardTabsOk = clipboardVerify.clipboardTabsOk;
      clipboardDeleteActionsOk = clipboardVerify.clipboardDeleteActionsOk;
      clipboardNoDragActionOk = clipboardVerify.clipboardNoDragActionOk;
      clipboardNoResolutionOk = clipboardVerify.clipboardNoResolutionOk;
      clipboardPreviewBehaviorOk = clipboardVerify.clipboardPreviewBehaviorOk;
      providerIconStableOk = clipboardIcon === [...providerIconsEl.children]
        .find((candidate) => candidate.dataset.providerId === clipboardProvider.id);
    }
    const calculatorProvider = state.providers.find((provider) => provider.id === "calculator");
    let calculatorHistorySidebarOk = false;
    if (calculatorProvider) {
      window.__hoverPocketVerifyStep = "select-calculator";
      await request("provider.select", { id: calculatorProvider.id });
      await waitForElement(".hp-calc", 4500);
      window.__hoverPocketVerifyStep = "verify-calculator-history-sidebar";
      calculatorHistorySidebarOk = await runCalculatorUiVerify();
    }
    window.__hoverPocketVerifyStep = "begin-text-input";
    const textInputBegin = await request("panel.beginTextInput");
    window.__hoverPocketVerifyStep = "end-text-input";
    const textInputEnd = await request("panel.endTextInput");
    const textInputActivationOk = textInputBegin?.keyboardInteractionEnabled === true
      && textInputBegin?.noActivateStyle === false
      && textInputEnd?.keyboardInteractionEnabled === false
      && textInputEnd?.noActivateStyle === true;
    const calendarProvider = state.providers.find((provider) => provider.id === "calendar");
    let calendarMacLayoutOk = false;
    let calendarEditorStableOk = false;
    if (calendarProvider) {
      window.__hoverPocketVerifyStep = "select-calendar";
      await render(await request("provider.select", { id: calendarProvider.id }));
      const calendarRoot = await waitForElement(".hp-calendar", 4500);
      const dayCells = [...(calendarRoot?.querySelectorAll(".hp-calendar-day") ?? [])];
      calendarMacLayoutOk = Boolean(
        calendarRoot?.querySelector(".hp-calendar-month-pane")
        && calendarRoot.querySelector(".hp-calendar-divider")
        && calendarRoot.querySelector(".hp-calendar-detail")
        && dayCells.length === 42
        && dayCells.every((cell) => cell.querySelectorAll(".hp-calendar-event-dots i").length <= 3)
        && !calendarRoot.querySelector(".hp-calendar-event-count"),
      );
      calendarEditorStableOk = Boolean(await calendarRoot?.__verifyEditorStability?.());
    }
    const timerProvider = state.providers.find((provider) => provider.id === "timer");
    let timerLayoutOk = false;
    let timerInteractionStableOk = false;
    let timerStopwatchOk = false;
    if (timerProvider) {
      window.__hoverPocketVerifyStep = "select-timer";
      await render(await request("provider.select", { id: timerProvider.id }));
      const pomodoroCard = await waitForElement(".hp-timer .hp-timer-entry.is-pomodoro", 4500);
      const timerRoot = pomodoroCard?.closest(".hp-timer");
      const timerCard = timerRoot?.querySelector(".hp-timer-entry.is-timer");
      const timerStack = timerRoot?.querySelector(".hp-timer-stack");
      const sections = [...(timerRoot?.querySelectorAll(".hp-timer-section") ?? [])];
      timerLayoutOk = Boolean(timerRoot && timerStack && timerCard && pomodoroCard)
        && timerRoot.clientWidth > 0
        && timerStack.scrollWidth <= timerStack.clientWidth + 1
        && sections.every((section) => section.scrollWidth <= section.clientWidth + 1);
      const durationRail = timerRoot?.querySelector("[data-duration-rail]");
      durationRail?.dispatchEvent(new Event("input", { bubbles: true }));
      timerInteractionStableOk = Boolean(durationRail?.isConnected && durationRail === timerRoot?.querySelector("[data-duration-rail]"));
      const stopwatchEntry = timerRoot?.querySelector(".hp-timer-section.is-add .hp-timer-entry.is-stopwatch");
      const runningStopwatch = timerRoot?.querySelector(".hp-timer-section.is-running [data-stopwatch]");
      timerStopwatchOk = Boolean(
        stopwatchEntry?.querySelector("[data-color-trigger]")
        && stopwatchEntry.querySelector("[data-title]")
        && stopwatchEntry.querySelector("[data-start]")
        && (!runningStopwatch || (
          runningStopwatch.querySelector("[data-stopwatch-elapsed]")
          && runningStopwatch.querySelector("[data-stopwatch-toggle]")
          && runningStopwatch.querySelector("[data-stopwatch-stop]"))),
      );
    }
    window.__hoverPocketVerifyStep = "verify-pocket-surface-renderer";
    const pocketSurfaceVerify = await runPocketSurfaceUiVerify();
    const providerBeforeSwitch = currentState?.selectedProvider?.id;
    const targetProvider = state.providers.find((provider) => provider.id !== providerBeforeSwitch) ?? state.providers[0];
    window.__hoverPocketVerifyStep = "switch-provider";
    const cleanupBeforeSwitch = providerCleanup;
    let providerSelectCalledAfterFailedCleanup = false;
    providerCleanup = async () => false;
    const blockedSwitchState = await selectProvider(targetProvider.id, async () => {
      providerSelectCalledAfterFailedCleanup = true;
      return currentState;
    });
    const providerSwitchBlockedOnSaveFailure = blockedSwitchState === null
      && !providerSelectCalledAfterFailedCleanup
      && currentState?.selectedProvider?.id === providerBeforeSwitch;
    let providerCleanupAwaited = false;
    let providerSelectAfterCleanup = false;
    providerCleanup = async () => {
      const disposed = await cleanupBeforeSwitch?.();
      await Promise.resolve();
      providerCleanupAwaited = true;
      return disposed;
    };
    const switchedState = await selectProvider(targetProvider.id, async (method, params) => {
      providerSelectAfterCleanup = providerCleanupAwaited;
      return request(method, params);
    });
    const cleanupBeforeRerender = providerCleanup;
    let providerRerenderCleanupAwaited = false;
    providerCleanup = async () => {
      const disposed = await cleanupBeforeRerender?.();
      await Promise.resolve();
      providerRerenderCleanupAwaited = true;
      return disposed;
    };
    const rerendered = await render(switchedState, { forceProvider: true });
    const providerRerenderCleanupAwaitedOk = rerendered !== false && providerRerenderCleanupAwaited;
    const cleanupAfterRerender = providerCleanup;
    const providerNodeBeforeBlockedRerender = providerContainerEl.firstChild;
    providerCleanup = async () => false;
    const blockedRerender = await render(switchedState, { forceProvider: true });
    const providerRerenderBlockedOnSaveFailureOk = blockedRerender === false
      && providerContainerEl.firstChild === providerNodeBeforeBlockedRerender;
    providerCleanup = cleanupAfterRerender;
    const stateBeforeHostFlush = currentState;
    const flushBeforeHostProbe = providerStateFlush;
    const beginBeforeHostProbe = providerStateTransitionBegin;
    const releaseBeforeHostProbe = providerStateTransitionRelease;
    let hostFlushCalls = 0;
    let hostReleaseCalls = 0;
    currentState = { ...currentState, pocketSurface: { appId: "local.example.verify" } };
    providerStateTransitionBegin = async () => {
      hostFlushCalls += 1;
      return true;
    };
    providerStateTransitionRelease = () => {
      hostReleaseCalls += 1;
    };
    const matchingHostFlush = await window.__hoverPocketFlushActiveProviderState(
      "local.example.verify",
      "verify-transition",
    );
    const unrelatedHostFlush = await window.__hoverPocketFlushActiveProviderState(
      "local.example.other",
      "verify-unrelated",
    );
    providerStateTransitionBegin = async () => {
      hostFlushCalls += 1;
      return true;
    };
    providerStateTransitionRelease = () => {
      hostReleaseCalls += 1;
    };
    await attachActiveStateTransitionLeases("local.example.verify");
    const matchingHostRelease = window.__hoverPocketCompleteActiveProviderStateTransition(
      "verify-transition",
      true,
    );
    const unrelatedHostRelease = window.__hoverPocketCompleteActiveProviderStateTransition(
      "verify-unrelated",
      true,
    );
    const providerHostStateFlushOk = matchingHostFlush
      && unrelatedHostFlush
      && matchingHostRelease
      && unrelatedHostRelease
      && hostFlushCalls === 2
      && hostReleaseCalls === 2;
    const providerSurfaceIdentityRemountOk = providerRenderKey({
      selectedProvider: { id: "generated-pocket-app:local.example.verify" },
      settings: { language: "ja" },
      pocketSurface: { appId: "local.example.verify", version: "1.0.0", manifestDigest: "digest-a" },
    }) !== providerRenderKey({
      selectedProvider: { id: "generated-pocket-app:local.example.verify" },
      settings: { language: "ja" },
      pocketSurface: { appId: "local.example.verify", version: "1.0.1", manifestDigest: "digest-b" },
    });
    currentState = stateBeforeHostFlush;
    providerStateFlush = flushBeforeHostProbe;
    providerStateTransitionBegin = beginBeforeHostProbe;
    providerStateTransitionRelease = releaseBeforeHostProbe;
    const originalPanelSize = state.settings.panelSize;
    const probePanelSize = originalPanelSize === "small" ? "medium" : "small";
    window.__hoverPocketVerifyStep = "resize-probe";
    const resizedState = await request("settings.setPanelSize", { panelSize: probePanelSize });
    await request("settings.setPanelSize", { panelSize: originalPanelSize });
    window.__hoverPocketVerifyStep = "complete";

    return {
      echoOk: echo?.value === "ui-round-trip",
      controlsRenderedOk,
      controlsLayoutOk,
      controlsHitAreasOk,
      controlsFallbackLayerOk,
      controlsStableRefreshOk,
      controlsBrightnessResolvedOk,
      controlsMediaActionsOk,
      clipboardStableProviderOk,
      clipboardStableRefreshOk,
      clipboardSplitViewOk,
      clipboardCenteredSplitOk,
      clipboardTabsOk,
      clipboardDeleteActionsOk,
      clipboardNoDragActionOk,
      clipboardNoResolutionOk,
      clipboardPreviewBehaviorOk,
      calculatorHistorySidebarOk,
      providerIconStableOk,
      providerDragReorderReadyOk: [...providerIconsEl.children].every((button) => button.draggable),
      textInputActivationOk,
      calendarMacLayoutOk,
      calendarEditorStableOk,
      timerLayoutOk,
      timerInteractionStableOk,
      timerStopwatchOk,
      pocketSurfaceRenderedOk: pocketSurfaceVerify.rendered,
      pocketSurfaceSelectionOk: pocketSurfaceVerify.selection,
      pocketSurfaceDurationOk: pocketSurfaceVerify.duration,
      pocketSurfacePurposeOk: pocketSurfaceVerify.purpose,
      pocketSurfaceStatePersistedOk: pocketSurfaceVerify.statePersisted,
      pocketSurfaceStateBoundControlsPersistedOk: pocketSurfaceVerify.stateBoundControlsPersisted,
      pocketSurfaceFailedStateWriteRetriedOk: pocketSurfaceVerify.failedStateWriteRetried,
      pocketSurfaceStateWorkflowInputOk: pocketSurfaceVerify.stateWorkflowInputForwarded,
      pocketSurfaceApprovalHostOwnedOk: pocketSurfaceVerify.approvalHostOwned,
      pocketSurfaceLayoutMatrixOk: pocketSurfaceVerify.layoutMatrix,
      pocketSurfaceStateTransitionBoundaryOk: pocketSurfaceVerify.stateTransitionBoundary,
      textSizeScaleReadyOk: getComputedStyle(document.documentElement).getPropertyValue("--hp-text-scale").trim() !== "",
      providerSwitchOk: switchedState?.selectedProvider?.id === targetProvider.id,
      providerSwitchCleanupAwaitedOk: providerSelectAfterCleanup,
      providerSwitchBlockedOnSaveFailureOk: providerSwitchBlockedOnSaveFailure,
      providerRerenderCleanupAwaitedOk,
      providerRerenderBlockedOnSaveFailureOk,
      providerHostStateFlushOk,
      providerSurfaceIdentityRemountOk,
      settingsWriteOk: resizedState.settings?.panelSize === probePanelSize,
      originalProvider,
      switchedProvider: switchedState?.selectedProvider?.id,
      originalPanelSize,
      probePanelSize,
    };
  },
};

function waitForElement(selector, timeoutMs) {
  return new Promise((resolve) => {
    const existing = document.querySelector(selector);
    if (existing) {
      resolve(existing);
      return;
    }

    const observer = new MutationObserver(() => {
      const match = document.querySelector(selector);
      if (match) {
        observer.disconnect();
        window.clearTimeout(timeout);
        resolve(match);
      }
    });
    const timeout = window.setTimeout(() => {
      observer.disconnect();
      resolve(null);
    }, timeoutMs);
    observer.observe(document.body, { childList: true, subtree: true, attributes: true });
  });
}
