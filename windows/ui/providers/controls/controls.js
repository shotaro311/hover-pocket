import { on } from "../../js/bridge.js";

const styleHref = "./providers/controls/controls.css";
const displayUpdateDelayMs = 110;

export function renderControlsProvider(context) {
  ensureStylesheet();
  const root = document.createElement("div");
  root.className = "hp-controls is-loading";
  root.textContent = text(context.state, "コントロールを読み込んでいます…", "Loading controls…");
  context.container.append(root);

  let disposed = false;
  const pendingOperations = new Set();
  const displayUpdates = new Map();
  let currentSnapshot = null;
  let currentRenderSignature = "";
  let currentDisplaySignature = "";
  let contrastVisible = context.state.settings.controlsContrastVisible === true;
  let contrastVisibilityRevision = 0;
  let contrastSaveError = "";
  let loadedContrastVisibility = null;
  const readContrastVisibility = async () => {
    const { visible } = await context.request("controls.getContrastVisible");
    return visible === true;
  };
  let refreshPromise = null;
  let latestPreviewFrame = null;
  let previewSequence = 0;
  let previewDrawing = false;
  let pointerRangeActive = null;
  let keyboardRangeActive = null;
  let deferredSnapshot = null;
  let displayDetectionRetryTimer = null;
  let displayDetectionRetryCount = 0;

  const synchronizeDisplayDetection = (snapshot) => {
    const detecting = (snapshot?.displays ?? []).some((display) =>
      display.error === "Brightness detection is still running."
      || (contrastVisible && display.supported && display.contrastSupported == null),
    );
    if (!detecting) {
      displayDetectionRetryCount = 0;
      if (displayDetectionRetryTimer != null) {
        window.clearTimeout(displayDetectionRetryTimer);
        displayDetectionRetryTimer = null;
      }
      return;
    }

    if (displayDetectionRetryTimer != null || displayDetectionRetryCount >= 3) {
      return;
    }

    displayDetectionRetryTimer = window.setTimeout(() => {
      displayDetectionRetryTimer = null;
      displayDetectionRetryCount += 1;
      void refresh();
    }, 900);
  };

  const drawDeferredWhenIdle = () => {
    if (pointerRangeActive || keyboardRangeActive || displayUpdates.size || disposed) {
      return;
    }

    if (loadedContrastVisibility != null) {
      const visible = loadedContrastVisibility;
      loadedContrastVisibility = null;
      applyLoadedContrastVisibility(visible);
    }
    if (!deferredSnapshot) {
      return;
    }

    const snapshot = deferredSnapshot;
    deferredSnapshot = null;
    draw(snapshot);
  };
  const finishRangeInteraction = () => {
    pointerRangeActive = null;
    keyboardRangeActive = null;
    drawDeferredWhenIdle();
  };
  const handlePointerUp = () => finishRangeInteraction();
  root.addEventListener("pointerdown", (event) => {
    if (event.target instanceof HTMLInputElement && event.target.type === "range") {
      pointerRangeActive = event.target;
    }
  });
  root.addEventListener("keydown", (event) => {
    if (event.target instanceof HTMLInputElement
        && event.target.type === "range"
        && ["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Home", "End", "PageUp", "PageDown"].includes(event.key)) {
      keyboardRangeActive = event.target;
    }
  });
  root.addEventListener("keyup", (event) => {
    if (event.target instanceof HTMLInputElement && event.target.type === "range") {
      finishRangeInteraction();
    }
  });
  window.addEventListener("pointerup", handlePointerUp, true);
  window.addEventListener("pointercancel", handlePointerUp, true);

  const update = (method, params) => {
    const operationKey = `${method}:${params?.id ?? params?.command ?? "default"}`;
    if (pendingOperations.has(operationKey) || disposed) {
      return;
    }

    pendingOperations.add(operationKey);
    root.classList.add("is-busy");
    context.request(method, params).then((snapshot) => {
      if (!disposed) {
        draw(snapshot);
      }
    }).catch((error) => {
      if (!disposed) {
        drawError(error);
      }
    }).finally(() => {
      pendingOperations.delete(operationKey);
      root.classList.toggle("is-busy", pendingOperations.size > 0);
    });
  };

  const queueDisplayUpdate = (method, id, value, immediate = false) => {
    if (disposed) {
      return;
    }

    const key = displayUpdateKey(method, id);
    let state = displayUpdates.get(key);
    if (!state) {
      state = { method, id, inFlight: false, queuedValue: null, timer: null, lastSentAt: -Infinity };
      displayUpdates.set(key, state);
    }

    state.queuedValue = Math.max(0, Math.min(100, Math.round(Number(value) || 0)));
    state.displayedValue = state.queuedValue;
    if (immediate && state.timer != null) {
      window.clearTimeout(state.timer);
      state.timer = null;
    }

    if (state.inFlight) {
      return;
    }

    if (immediate) {
      sendDisplayUpdate(key, state);
    } else if (state.timer == null) {
      state.timer = window.setTimeout(() => {
        state.timer = null;
        sendDisplayUpdate(key, state);
      }, displayUpdateDelayMs);
    }
  };

  const sendDisplayUpdate = (key, state) => {
    if (disposed || state.inFlight || state.queuedValue == null) {
      return;
    }

    const spacing = displayUpdateDelayMs - (performance.now() - state.lastSentAt);
    if (spacing > 1) {
      if (state.timer == null) {
        state.timer = window.setTimeout(() => {
          state.timer = null;
          sendDisplayUpdate(key, state);
        }, spacing);
      }
      return;
    }

    const value = state.queuedValue;
    state.queuedValue = null;
    state.inFlight = true;
    state.lastSentAt = performance.now();
    pendingOperations.add(key);
    root.classList.add("is-busy");
    context.request(state.method, { id: state.id, value }).then((snapshot) => {
      if (!disposed) {
        draw(snapshot);
      }
    }).catch((error) => {
      if (!disposed) {
        drawError(error);
      }
    }).finally(() => {
      state.inFlight = false;
      pendingOperations.delete(key);
      if (state.queuedValue != null && state.queuedValue !== value && !disposed) {
        sendDisplayUpdate(key, state);
        return;
      }

      state.queuedValue = null;
      displayUpdates.delete(key);
      root.classList.toggle("is-busy", pendingOperations.size > 0);
      drawDeferredWhenIdle();
    });
  };

  const drawDisplays = (displays, force = false) => {
    const signature = JSON.stringify([contrastVisible, contrastSaveError, displays]);
    const previous = root.querySelector(":scope > .hp-controls-display-section");
    if (!force && previous && signature === currentDisplaySignature) {
      return;
    }

    const next = displaySection(displays, context.state, queueDisplayUpdate, {
      contrastVisible,
      toggleContrast,
      pendingValue: (method, id) => displayUpdates.get(displayUpdateKey(method, id))?.displayedValue,
      saveError: contrastSaveError,
    });
    if (previous) {
      const restoreFocus = document.activeElement === previous.querySelector("[data-contrast-toggle]");
      previous.replaceWith(next);
      if (restoreFocus) {
        next.querySelector("[data-contrast-toggle]").focus({ preventScroll: true });
      }
    } else {
      root.prepend(next);
    }
    currentDisplaySignature = signature;
  };

  const toggleContrast = () => {
    const previous = contrastVisible;
    const visible = !previous;
    const revision = ++contrastVisibilityRevision;
    contrastVisible = visible;
    contrastSaveError = "";
    if (pointerRangeActive?.closest(".hp-controls-display-section")) {
      pointerRangeActive = null;
    }
    if (keyboardRangeActive?.closest(".hp-controls-display-section")) {
      keyboardRangeActive = null;
    }
    drawDisplays(currentSnapshot?.displays ?? [], true);
    synchronizeDisplayDetection(currentSnapshot);
    drawDeferredWhenIdle();
    context.request("controls.setContrastVisible", { visible }).then((saved) => {
      if (!disposed && revision === contrastVisibilityRevision) {
        const persisted = saved.visible === true;
        context.state.settings.controlsContrastVisible = persisted;
        if (contrastVisible !== persisted) {
          contrastVisible = persisted;
          drawDisplays(currentSnapshot?.displays ?? [], true);
        }
      }
    }).catch(async () => {
      if (disposed || revision !== contrastVisibilityRevision) {
        return;
      }
      const persisted = await readContrastVisibility().catch(() => previous);
      if (!disposed && revision === contrastVisibilityRevision) {
        contrastVisible = persisted;
        context.state.settings.controlsContrastVisible = persisted;
        contrastSaveError = text(context.state, "表示設定を保存できませんでした。", "Could not save the display setting.");
        drawDisplays(currentSnapshot?.displays ?? [], true);
      }
    });
  };

  const draw = (snapshot) => {
    if (!snapshot || disposed || isOlderSnapshot(snapshot, currentSnapshot)) {
      return;
    }
    currentSnapshot = snapshot;
    synchronizeDisplayDetection(snapshot);
    if (pointerRangeActive || keyboardRangeActive || displayUpdates.size) {
      deferredSnapshot = snapshot;
      return;
    }

    deferredSnapshot = null;
    const nextSignature = snapshotRenderSignature(snapshot);
    if (nextSignature === currentRenderSignature && root.querySelector(".hp-controls-display-section")) {
      drawDisplays(snapshot.displays ?? []);
      patchMediaPosition(root, snapshot);
      return;
    }

    root.className = `hp-controls${pendingOperations.size ? " is-busy" : ""}`;
    root.replaceChildren(
      volumeSection(snapshot.volume ?? {}, context.state, update),
      mediaSection(snapshot.media ?? {}, snapshot.preview ?? {}, context.state, update),
    );
    drawDisplays(snapshot.displays ?? []);
    currentRenderSignature = nextSignature;
    patchMediaPosition(root, snapshot);
    if (latestPreviewFrame) {
      queuePreviewFrame(latestPreviewFrame);
    }
  };

  const drawError = (error) => {
    root.className = "hp-controls is-error";
    root.textContent = localizeError(String(error?.message ?? error), context.state);
  };

  // The saved preference can arrive after the first draw. It never replaces a slider the user is moving;
  // it waits for the same idle point as deferred snapshots.
  const applyLoadedContrastVisibility = (visible) => {
    if (disposed || contrastVisibilityRevision !== 0) {
      return;
    }
    context.state.settings.controlsContrastVisible = visible;
    if (contrastVisible === visible) {
      return;
    }
    if (pointerRangeActive || keyboardRangeActive || displayUpdates.size) {
      loadedContrastVisibility = visible;
      return;
    }
    contrastVisible = visible;
    if (currentSnapshot) {
      drawDisplays(currentSnapshot.displays ?? []);
      synchronizeDisplayDetection(currentSnapshot);
    }
  };
  void readContrastVisibility().then(applyLoadedContrastVisibility).catch(() => {});

  const refresh = () => {
    if (disposed) {
      return Promise.resolve();
    }
    if (!refreshPromise) {
      refreshPromise = context.request("controls.getState")
        .then(draw)
        .catch(drawError)
        .finally(() => {
          refreshPromise = null;
        });
    }
    return refreshPromise;
  };

  const applyPreviewState = (preview) => {
    if (!currentSnapshot || disposed) {
      return;
    }

    currentSnapshot = { ...currentSnapshot, preview };
    const previewRoot = root.querySelector(".hp-media-artwork");
    if (!previewRoot) {
      return;
    }

    previewRoot.classList.toggle("is-live", Boolean(preview.live));
    previewRoot.classList.toggle("is-fallback", !preview.live);
    previewRoot.dataset.mode = preview.mode || "inactive";
    const status = previewRoot.querySelector("[data-preview-status]");
    if (status) {
      status.textContent = preview.live
        ? `${Math.round(Number(preview.measuredFps) || 0)} fps`
        : fallbackLabel(preview.mode, context.state);
    }
  };

  const queuePreviewFrame = (frame) => {
    if (disposed || !frame?.dataUrl) {
      return;
    }

    latestPreviewFrame = frame;
    previewSequence += 1;
    if (!previewDrawing) {
      void drawLatestPreviewFrame();
    }
  };

  const drawLatestPreviewFrame = async () => {
    previewDrawing = true;
    try {
      while (!disposed && latestPreviewFrame?.dataUrl) {
        const frame = latestPreviewFrame;
        const sequence = previewSequence;
        latestPreviewFrame = null;
        const response = await fetch(frame.dataUrl);
        const bitmap = await createImageBitmap(await response.blob());
        try {
          if (disposed || sequence !== previewSequence) {
            continue;
          }

          const canvas = root.querySelector("canvas[data-live-preview]");
          const previewRoot = root.querySelector(".hp-media-artwork");
          if (!(canvas instanceof HTMLCanvasElement) || !previewRoot) {
            continue;
          }

          const drawingContext = canvas.getContext("2d", { alpha: false });
          drawingContext?.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
          previewRoot.classList.add("is-live");
          previewRoot.classList.remove("is-fallback");
          const status = previewRoot.querySelector("[data-preview-status]");
          if (status) {
            status.textContent = `${Math.round(Number(frame.measuredFps) || 0)} fps`;
          }
        } finally {
          bitmap.close();
        }
      }
    } catch {
      root.querySelector(".hp-media-artwork")?.classList.replace("is-live", "is-fallback");
    } finally {
      previewDrawing = false;
      if (!disposed && latestPreviewFrame?.dataUrl) {
        void drawLatestPreviewFrame();
      }
    }
  };

  const unsubscribeState = on("controls.stateChanged", draw);
  const unsubscribePreviewState = on("controls.previewState", applyPreviewState);
  const unsubscribePreviewFrame = on("controls.previewFrame", queuePreviewFrame);

  refresh();
  const mediaClock = window.setInterval(() => {
    if (currentSnapshot) {
      patchMediaPosition(root, currentSnapshot);
    }
  }, 500);
  root.__verifyStableRefresh = async () => {
    const canvas = root.querySelector("canvas[data-live-preview]");
    await refresh();
    return canvas === root.querySelector("canvas[data-live-preview]");
  };
  // Swaps in synthetic display rows under several container sizes and checks that no row is clipped.
  root.__verifyDisplayLayout = async () => {
    const original = root.querySelector(":scope > .hp-controls-section");
    if (!original) {
      return { ok: false, failures: ["display section missing"] };
    }
    const fake = (id, name, isPrimary, value) => ({ id, name, supported: true, value, isPrimary });
    const cases = [
      [fake("ddc:A-0", "Generic PnP Monitor", true, 54), fake("ddc:B-0", "Generic PnP Monitor", false, 73)],
      [
        fake("ddc:A-0", "LG ULTRAGEAR+", true, 54),
        fake("ddc:B-0", "U16ZT", false, 73),
        { id: "display:C", name: "U16ZT", supported: false, value: null, isPrimary: false, error: "DDC/CI is not available." },
      ],
    ];
    const contrastCases = [
      [
        { ...cases[0][0], contrastSupported: true, contrastValue: 70 },
        { ...cases[0][1], contrastSupported: false },
      ],
      [
        { ...cases[1][0], contrastSupported: true, contrastValue: 68, contrastWriteVerified: false,
          contrastError: "Contrast readback did not match 70%." },
        { ...cases[1][1], contrastSupported: null },
        cases[1][2],
      ],
    ];
    const sizes = [["", ""], ["440px", ""], ["", "220px"], ["440px", "220px"]];
    const failures = [];
    const previousWidth = root.style.width;
    const previousHeight = root.style.height;
    try {
      const variants = [
        ...cases.map((displays) => ({ displays, contrastVisible: false })),
        ...contrastCases.map((displays) => ({ displays, contrastVisible: true })),
      ];
      for (const { displays, contrastVisible } of variants) {
        const replacement = displaySection(displays, context.state, () => {}, {
          contrastVisible,
          toggleContrast: () => {},
        });
        original.replaceWith(replacement);
        const expected = displayLabels(displays, context.state);
        try {
          const strongs = [...replacement.querySelectorAll(".hp-control-row strong")].map((item) => item.textContent);
          if (JSON.stringify(strongs) !== JSON.stringify(expected)) {
            failures.push(`labels ${JSON.stringify(strongs)}`);
          }
          if (displays.length === 2 && !(expected[0].includes("メイン") || expected[0].includes("Main"))) {
            failures.push("duplicate primary label missing");
          }
          const button = replacement.querySelector("[data-contrast-toggle]");
          const header = replacement.querySelector(".hp-controls-display-header");
          const heading = header.querySelector("h2");
          if (button.parentElement !== header || button.getAttribute("aria-pressed") !== String(contrastVisible)) {
            failures.push("display heading toggle missing or reports the wrong state");
          }

          const contrastLines = [...replacement.querySelectorAll("[data-contrast-adjustment]")];
          if (contrastLines.length !== (contrastVisible ? 2 : 0)) {
            failures.push("wrong number of contrast lines");
          } else if (contrastVisible) {
            const status = displays[1].contrastSupported === false
              ? text(context.state, "非対応", "Unsupported")
              : text(context.state, "確認中…", "Checking…");
            if (contrastLines[0].querySelector("input")?.value !== String(displays[0].contrastValue)
              || !contrastLines[1].textContent.includes(status)
              || contrastLines[1].querySelector("input")) {
              failures.push("supported, unsupported or checking contrast row is incorrect");
            }
            const error = replacement.querySelector("[data-contrast-error]");
            if ((error?.textContent ?? "") !== localizeError(displays[0].contrastError, context.state)) {
              failures.push("contrast error is missing or incorrectly localized");
            }
          }

          if ([...replacement.querySelectorAll(".hp-control-row p")]
            .some((message) => !message.title || message.title !== message.textContent)) {
            failures.push("display details do not expose their full text in the tooltip");
          }

          for (const [width, height] of sizes) {
            root.style.width = width;
            root.style.height = height;
            await new Promise((resolve) => requestAnimationFrame(() => resolve()));
            const list = replacement.querySelector(".hp-controls-list");
            const sectionBounds = replacement.getBoundingClientRect();
            const rootBounds = root.getBoundingClientRect();
            const rows = [...replacement.querySelectorAll(".hp-control-row")];
            const label = `${displays.length} displays at ${width || "auto"}x${height || "auto"}`;
            const buttonBounds = button.getBoundingClientRect();
            if (Math.abs(buttonBounds.right - header.getBoundingClientRect().right) > 1
              || buttonBounds.left <= heading.getBoundingClientRect().right) {
              failures.push(`${label}: toggle is not at the right end of the display heading`);
            }
            if (rows.length !== displays.length || rows.some((row) => row.querySelectorAll("strong").length !== 1)) {
              failures.push(`${label}: rendered ${rows.length} rows`);
            }
            if (list.scrollHeight > list.clientHeight + 1) {
              failures.push(`${label}: display list scrolls internally`);
            }
            if (sectionBounds.left < rootBounds.left - 1 || sectionBounds.right > rootBounds.right + 1) {
              failures.push(`${label}: display section wider than the Controls view`);
            }
            // Rows taller than the view are fine only if the Controls view itself can scroll to them.
            if (root.scrollHeight > root.clientHeight + 1
              && !["auto", "scroll"].includes(getComputedStyle(root).overflowY)) {
              failures.push(`${label}: Controls view cannot scroll to every row`);
            }
            for (const row of rows) {
              for (const element of [row, ...row.querySelectorAll("strong, span, input, p")]) {
                const bounds = element.getBoundingClientRect();
                if (bounds.top < sectionBounds.top - 1 || bounds.bottom > sectionBounds.bottom + 1
                  || bounds.left < sectionBounds.left - 1 || bounds.right > sectionBounds.right + 1) {
                  failures.push(`${label}: ${element.tagName.toLowerCase()} of ${row.dataset.displayId} clipped`);
                }
              }
            }
          }
        } finally {
          replacement.replaceWith(original);
        }
      }
    } finally {
      root.style.width = previousWidth;
      root.style.height = previousHeight;
    }
    await verifyDisplayInteraction(context.state, contrastCases[0], failures);
    await verifyLateSettingsDuringRange(context.state, contrastCases[0], failures);
    return { ok: failures.length === 0, failures };
  };
  return {
    refresh,
    dispose() {
      disposed = true;
      window.clearInterval(mediaClock);
      unsubscribeState();
      unsubscribePreviewState();
      unsubscribePreviewFrame();
      latestPreviewFrame = null;
      deferredSnapshot = null;
      if (displayDetectionRetryTimer != null) {
        window.clearTimeout(displayDetectionRetryTimer);
        displayDetectionRetryTimer = null;
      }
      for (const state of displayUpdates.values()) {
        if (state.timer != null) {
          window.clearTimeout(state.timer);
        }
      }
      displayUpdates.clear();
      pendingOperations.clear();
      window.removeEventListener("pointerup", handlePointerUp, true);
      window.removeEventListener("pointercancel", handlePointerUp, true);
    },
  };
}

async function verifyDisplayInteraction(appState, displays, failures) {
  const host = document.createElement("div");
  const state = { ...appState, settings: { ...appState.settings, controlsContrastVisible: false } };
  let persisted = false;
  let snapshot = { displays, refreshedAt: "2099-01-01T00:00:00Z", preview: { live: true } };
  const operations = [];
  const finishWrites = [];
  let finishInitialSettings;
  const initialSettings = new Promise((resolve) => { finishInitialSettings = resolve; });
  let visibilityReads = 0;
  const request = async (method, params) => {
    if (method === "controls.getState") {
      return snapshot;
    }
    if (method === "controls.getContrastVisible") {
      return ++visibilityReads === 1 ? initialSettings : { visible: persisted };
    }
    if (method === "controls.setContrastVisible") {
      persisted = params.visible;
      return { visible: persisted };
    }

    operations.push({ method, ...params });
    await new Promise((resolve) => finishWrites.push(resolve));
    const key = method === "controls.setContrast" ? "contrastValue" : "value";
    snapshot = {
      ...snapshot,
      displays: snapshot.displays.map((display) => display.id === params.id
        ? { ...display, [key]: params.value } : display),
    };
    return snapshot;
  };
  const provider = renderControlsProvider({ container: host, state, request });
  try {
    const refresh = provider.refresh();
    await new Promise((resolve) => setTimeout(resolve, 0));
    const root = host.firstElementChild;
    const canvas = root.querySelector("canvas[data-live-preview]");
    const button = () => root.querySelector("[data-contrast-toggle]");
    const range = (method) => root.querySelector(`[data-display-method="${method}"]`);
    const brightness = "controls.setBrightness";
    const contrast = "controls.setContrast";
    const initialBrightness = range(brightness);
    if (!initialBrightness || !root.querySelector(".hp-volume") || !root.querySelector(".hp-media")) {
      failures.push("unanswered contrast settings blocked display, volume or media rendering");
      return;
    }
    await refresh;
    initialBrightness.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true }));
    initialBrightness.value = "61";
    initialBrightness.dispatchEvent(new Event("input", { bubbles: true }));
    button().click();
    if (button().getAttribute("aria-pressed") !== "true" || !range(contrast)
      || range(brightness).value !== "61") {
      failures.push("toggle did not redraw immediately while brightness was queued");
    }
    if ((await request("controls.getContrastVisible")).visible !== true) {
      failures.push("enabled contrast preference did not read back");
    }
    finishInitialSettings({ visible: false });
    await new Promise((resolve) => setTimeout(resolve, 0));
    if (button().getAttribute("aria-pressed") !== "true" || !range(contrast)
      || state.settings.controlsContrastVisible !== true) {
      failures.push("late initial settings overrode the user's contrast toggle");
    }
    const contrastSlider = range(contrast);
    if (!contrastSlider) {
      return;
    }
    contrastSlider.value = "65";
    contrastSlider.dispatchEvent(new Event("change", { bubbles: true }));
    range(brightness).dispatchEvent(new Event("change", { bubbles: true }));
    if (!operations.some((op) => op.method === brightness && op.id === displays[0].id && op.value === 61)
      || !operations.some((op) => op.method === contrast && op.id === displays[0].id && op.value === 65)) {
      failures.push("same-display brightness and contrast did not both send their own values");
    }
    button().click();
    if (button().getAttribute("aria-pressed") !== "false" || range(contrast)
      || (await request("controls.getContrastVisible")).visible !== false) {
      failures.push("toggle did not hide contrast and read back off during writes");
    }
    for (const resolve of finishWrites) {
      resolve();
    }
    await provider.refresh();
    if (!canvas || canvas !== root.querySelector("canvas[data-live-preview]")) {
      failures.push("contrast toggle/save or display refresh recreated the live preview canvas");
    }
  } finally {
    finishInitialSettings({ visible: false });
    provider.dispose();
  }
}

// A saved "on" that arrives while a brightness slider is held by the keyboard must wait for keyup.
async function verifyLateSettingsDuringRange(appState, displays, failures) {
  const host = document.createElement("div");
  const state = { ...appState, settings: { ...appState.settings, controlsContrastVisible: false } };
  const snapshot = { displays, refreshedAt: "2099-01-01T00:00:00Z", preview: { live: true } };
  let finishSettings;
  const settings = new Promise((resolve) => { finishSettings = resolve; });
  const request = async (method) => {
    if (method === "controls.getState") {
      return snapshot;
    }
    if (method === "controls.getContrastVisible") {
      return settings;
    }
    return snapshot;
  };
  const provider = renderControlsProvider({ container: host, state, request });
  try {
    await provider.refresh();
    const root = host.firstElementChild;
    const slider = root.querySelector('[data-display-method="controls.setBrightness"]');
    if (!slider) {
      failures.push("late settings check: brightness slider missing");
      return;
    }
    slider.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true }));
    finishSettings({ visible: true });
    await new Promise((resolve) => setTimeout(resolve, 0));
    // The test host is detached from the document, so containment is checked against the provider root.
    if (!root.contains(slider) || root.querySelector('[data-display-method="controls.setContrast"]')) {
      failures.push("late settings replaced a slider the keyboard was still moving");
    }
    slider.dispatchEvent(new KeyboardEvent("keyup", { key: "ArrowRight", bubbles: true }));
    if (!root.querySelector('[data-display-method="controls.setContrast"]')
      || root.querySelector("[data-contrast-toggle]")?.getAttribute("aria-pressed") !== "true") {
      failures.push("late settings were not applied after the keyboard released the slider");
    }
  } finally {
    finishSettings({ visible: false });
    provider.dispose();
  }
}

function displayUpdateKey(method, id) {
  return `${method}:${id}`;
}

function displaySection(displays, appState, queueDisplayUpdate, options) {
  const { contrastVisible, toggleContrast, pendingValue = () => null, saveError } = options;
  const body = document.createElement("div");
  body.className = "hp-controls-list";
  const names = displayLabels(displays, appState);
  displays.forEach((display, index) => {
    const row = document.createElement("div");
    const detecting = display.error === "Brightness detection is still running.";
    row.className = `hp-control-row${display.supported ? "" : detecting ? " is-detecting" : " is-unsupported"}`;
    row.dataset.displayId = display.id ?? "";
    const brightness = pendingValue("controls.setBrightness", display.id) ?? display.value;
    const title = label(
      names[index],
      display.supported && display.value != null
        ? `${brightness}%`
        : detecting
          ? text(appState, "検出中…", "Detecting…")
          : text(appState, "非対応", "Unsupported"),
    );
    title.querySelector("strong").title = names[index];
    if (display.supported && display.value != null) {
      const brightnessName = text(appState, "明るさ", "Brightness");
      const brightnessValue = title.querySelector("span");
      const brightnessSlider = displayRange("controls.setBrightness", display.id, brightness, brightnessName,
        brightnessValue, queueDisplayUpdate);
      row.append(title);
      if (contrastVisible) {
        brightnessValue.remove();
        row.append(displayAdjustment(brightnessName, brightnessSlider, brightnessValue));
      } else {
        row.append(brightnessSlider);
      }
      if (contrastVisible) {
        row.append(contrastAdjustment(display, appState, queueDisplayUpdate, pendingValue));
        if (display.contrastWriteVerified === false || display.contrastError) {
          const message = displayDetail(localizeError(
            display.contrastError || text(appState, "読み戻しに失敗しました。", "Readback failed."),
            appState,
          ));
          message.dataset.contrastError = "true";
          row.append(message);
        }
      }
      if (display.writeVerified === false || display.error) {
        row.append(displayDetail(localizeError(
          display.error || text(appState, "読み戻しに失敗しました。", "Readback failed."),
          appState,
        )));
      }
    } else {
      row.append(
        title,
        displayDetail(localizeError(display.error || text(
          appState,
          "このディスプレイは明るさ操作に対応していません。",
          "Brightness control is not available for this display.",
        ), appState)),
      );
    }
    body.append(row);
  });
  if (saveError) {
    const message = displayDetail(saveError);
    message.className = "hp-contrast-save-error";
    message.setAttribute("role", "alert");
    body.append(message);
  }

  const root = section(text(appState, "ディスプレイ", "Displays"), body);
  root.classList.add("hp-controls-display-section");
  const header = document.createElement("div");
  header.className = "hp-controls-display-header";
  const button = document.createElement("button");
  button.type = "button";
  button.dataset.contrastToggle = "true";
  button.textContent = text(appState, "◐ コントラスト", "◐ Contrast");
  button.title = contrastVisible
    ? text(appState, "各画面のコントラストを隠す", "Hide contrast for each display")
    : text(appState, "各画面のコントラストを表示", "Show contrast for each display");
  button.setAttribute("aria-pressed", String(contrastVisible));
  button.addEventListener("click", toggleContrast);
  header.append(root.querySelector("h2"), button);
  root.prepend(header);
  return root;
}

function displayRange(method, id, value, name, valueLabel, queueDisplayUpdate) {
  const slider = range(value, 0, 100);
  slider.dataset.displayMethod = method;
  slider.setAttribute("aria-label", name);
  slider.addEventListener("input", () => {
    valueLabel.textContent = `${slider.value}%`;
    queueDisplayUpdate(method, id, slider.value);
  });
  slider.addEventListener("change", () => queueDisplayUpdate(method, id, slider.value, true));
  return slider;
}

function displayAdjustment(name, control, value) {
  const line = document.createElement("div");
  line.className = "hp-display-adjustment";
  const label = document.createElement("span");
  label.textContent = name;
  value.classList.add("hp-display-adjustment-value");
  line.append(label, control, value);
  return line;
}

function contrastAdjustment(display, appState, queueDisplayUpdate, pendingValue) {
  const method = "controls.setContrast";
  const name = text(appState, "コントラスト", "Contrast");
  const valueLabel = document.createElement("span");
  const value = pendingValue(method, display.id) ?? display.contrastValue;
  let control;
  if (display.contrastSupported === true && value != null) {
    valueLabel.textContent = `${value}%`;
    control = displayRange(method, display.id, value, name, valueLabel, queueDisplayUpdate);
  } else {
    control = document.createElement("span");
    control.textContent = display.contrastSupported === false
      ? text(appState, "非対応", "Unsupported")
      : text(appState, "確認中…", "Checking…");
  }
  const line = displayAdjustment(name, control, valueLabel);
  line.dataset.contrastAdjustment = "true";
  return line;
}

// Adds Main / Sub only when two rows would otherwise show the same name.
function displayLabels(displays, appState) {
  const names = displays.map((display) => localizedDisplayName(display.name, appState));
  const counts = new Map();
  for (const name of names) {
    counts.set(name, (counts.get(name) ?? 0) + 1);
  }
  const subCounts = new Map();
  const subTotals = new Map();
  displays.forEach((display, index) => {
    if (!display.isPrimary) {
      subTotals.set(names[index], (subTotals.get(names[index]) ?? 0) + 1);
    }
  });
  const english = appState?.settings?.language === "en";
  return displays.map((display, index) => {
    const name = names[index];
    if ((counts.get(name) ?? 0) < 2) {
      return name;
    }
    let role;
    if (display.isPrimary) {
      role = english ? "Main" : "メイン";
    } else {
      const order = (subCounts.get(name) ?? 0) + 1;
      subCounts.set(name, order);
      const base = english ? "Sub" : "サブ";
      role = (subTotals.get(name) ?? 0) > 1 ? `${base} ${order}` : base;
    }
    return english ? `${name} (${role})` : `${name}（${role}）`;
  });
}

function volumeSection(volume, appState, update) {
  const body = document.createElement("div");
  body.className = `hp-control-row hp-volume${volume.available ? "" : " is-unsupported"}`;
  const title = label(
    text(appState, "音量", "Volume"),
    volume.available ? `${volume.value ?? 0}%` : text(appState, "利用不可", "Unavailable"),
  );
  if (!volume.available) {
    body.append(title, detail(localizeError(
      volume.error || text(appState, "音量を取得できません。", "Volume is unavailable."),
      appState,
    )));
    return section(text(appState, "サウンド", "Sound"), body);
  }

  const controls = document.createElement("div");
  controls.className = "hp-volume-controls";
  const mute = iconButton(
    volume.muted ? "🔇" : "🔊",
    volume.muted ? text(appState, "ミュート解除", "Unmute") : text(appState, "ミュート", "Mute"),
  );
  mute.addEventListener("click", () => update("controls.toggleMute"));
  const slider = range(volume.value ?? 0, 0, 100);
  const valueLabel = title.querySelector("span");
  slider.addEventListener("input", () => {
    valueLabel.textContent = `${slider.value}%`;
  });
  slider.addEventListener("change", () => update("controls.setVolume", { value: Number(slider.value) }));
  controls.append(mute, slider);
  body.append(title, controls);
  if (volume.error) {
    body.append(detail(localizeError(volume.error, appState)));
  }
  return section(text(appState, "サウンド", "Sound"), body);
}

function mediaSection(media, preview, appState, update) {
  const body = document.createElement("div");
  body.className = "hp-media";
  if (!media.available) {
    body.classList.add("is-unavailable");
  }

  const artwork = document.createElement("div");
  artwork.className = `hp-media-artwork ${preview.live ? "is-live" : "is-fallback"}`;
  artwork.dataset.mode = preview.mode || "inactive";
  if (media.available) {
    artwork.classList.add("is-openable");
    artwork.dataset.openMediaSource = "true";
    artwork.tabIndex = 0;
    artwork.setAttribute("role", "button");
    artwork.setAttribute("aria-label", text(appState, "再生中の画面を前面に表示", "Bring playing screen to front"));
    artwork.title = text(appState, "再生中の画面を前面に表示", "Bring playing screen to front");
    const openSource = () => update("controls.openMediaSource");
    artwork.addEventListener("click", openSource);
    artwork.addEventListener("keydown", (event) => {
      if (event.key === "Enter" || event.key === " ") {
        event.preventDefault();
        openSource();
      }
    });
  }
  const fallback = document.createElement("div");
  fallback.className = "hp-media-fallback";
  if (media.artworkDataUrl) {
    const image = document.createElement("img");
    image.src = media.artworkDataUrl;
    image.alt = "";
    fallback.append(image);
  } else {
    fallback.textContent = "♪";
  }
  const canvas = document.createElement("canvas");
  canvas.width = 392;
  canvas.height = 220;
  canvas.dataset.livePreview = "true";
  const previewBadge = document.createElement("span");
  previewBadge.className = "hp-media-preview-status";
  previewBadge.dataset.previewStatus = "true";
  previewBadge.textContent = preview.live
    ? `${Math.round(Number(preview.measuredFps) || 0)} fps`
    : fallbackLabel(preview.mode, appState);
  artwork.append(fallback, canvas, previewBadge);

  const meta = document.createElement("div");
  meta.className = "hp-media-meta";
  const title = document.createElement("strong");
  title.textContent = media.available
    ? media.title || text(appState, "タイトルなし", "Untitled")
    : text(appState, "再生中のメディアはありません", "Nothing is playing");
  const sub = document.createElement("span");
  sub.textContent = media.available
    ? [media.artist, media.source].filter(Boolean).join(" · ")
    : localizeError(media.error, appState) || text(appState, "対応セッションを待機しています。", "Waiting for a supported session.");
  meta.append(title, sub);

  const timeline = document.createElement("div");
  timeline.className = "hp-media-timeline";
  const progress = range(media.positionSeconds ?? 0, 0, Math.max(1, media.durationSeconds ?? 0));
  progress.disabled = !media.available || !media.canSeek;
  progress.step = "0.1";
  progress.addEventListener("change", () => update("controls.mediaCommand", {
    command: "seekAbsolute",
    value: Number(progress.value),
  }));
  const time = document.createElement("span");
  time.dataset.mediaTime = "true";
  time.textContent = `${formatTime(media.positionSeconds)} / ${formatTime(media.durationSeconds)}`;
  timeline.append(progress, time);

  const commands = document.createElement("div");
  commands.className = "hp-media-commands";
  const rateDown = iconButton("−", text(appState, "再生速度を下げる", "Decrease playback rate"));
  rateDown.dataset.rateDecrease = "true";
  rateDown.disabled = !media.available || !media.canChangeRate || Number(media.playbackRate) <= 0.5;
  rateDown.addEventListener("click", () => update("controls.mediaCommand", {
    command: "rate",
    value: adjustedRate(media.playbackRate, -0.25),
  }));
  const previous = iconButton("|◀", text(appState, "前のトラック", "Previous track"));
  previous.disabled = !media.available || !media.canSkipPrevious;
  previous.addEventListener("click", () => update("controls.mediaCommand", { command: "previous" }));
  const back = iconButton("−10", text(appState, "10秒戻す", "Back 10 seconds"));
  back.disabled = !media.available || !media.canSeek;
  back.addEventListener("click", () => update("controls.mediaCommand", { command: "seekRelative", value: -10 }));
  const play = iconButton(
    media.isPlaying ? "Ⅱ" : "▶",
    media.isPlaying ? text(appState, "一時停止", "Pause") : text(appState, "再生", "Play"),
  );
  play.classList.add("is-primary");
  play.disabled = !media.available || !media.canPlayPause;
  play.addEventListener("click", () => update("controls.mediaCommand", { command: "playPause" }));
  const forward = iconButton("+10", text(appState, "10秒送る", "Forward 10 seconds"));
  forward.disabled = !media.available || !media.canSeek;
  forward.addEventListener("click", () => update("controls.mediaCommand", { command: "seekRelative", value: 10 }));
  const next = iconButton("▶|", text(appState, "次のトラック", "Next track"));
  next.disabled = !media.available || !media.canSkipNext;
  next.addEventListener("click", () => update("controls.mediaCommand", { command: "next" }));
  const rateUp = iconButton("+", text(appState, "再生速度を上げる", "Increase playback rate"));
  rateUp.dataset.rateIncrease = "true";
  rateUp.disabled = !media.available || !media.canChangeRate || Number(media.playbackRate) >= 3;
  rateUp.addEventListener("click", () => update("controls.mediaCommand", {
    command: "rate",
    value: adjustedRate(media.playbackRate, 0.25),
  }));
  const rateValue = document.createElement("span");
  rateValue.className = "hp-media-rate";
  rateValue.dataset.playbackRate = "true";
  rateValue.textContent = `${formatRate(media.playbackRate)}×`;
  rateValue.title = text(appState, "現在の再生速度", "Current playback rate");
  commands.append(rateDown, previous, back, play, forward, next, rateUp, rateValue);

  body.append(artwork, meta, timeline, commands);
  if (media.error) {
    const warning = detail(localizeError(media.error, appState));
    warning.classList.add("hp-media-error");
    body.append(warning);
  }
  return section(text(appState, "再生中", "Now Playing"), body);
}

function section(title, body) {
  const root = document.createElement("section");
  root.className = "hp-controls-section";
  const heading = document.createElement("h2");
  heading.textContent = title;
  root.append(heading, body);
  return root;
}

function label(titleText, valueText) {
  const root = document.createElement("div");
  root.className = "hp-control-label";
  const title = document.createElement("strong");
  title.textContent = titleText;
  const value = document.createElement("span");
  value.textContent = valueText;
  root.append(title, value);
  return root;
}

function displayDetail(message) {
  const value = detail(message);
  value.title = message;
  return value;
}

function detail(message) {
  const value = document.createElement("p");
  value.textContent = message;
  return value;
}

function range(value, min, max) {
  const input = document.createElement("input");
  input.type = "range";
  input.min = String(min);
  input.max = String(max);
  input.value = String(Math.min(max, Math.max(min, Number(value) || 0)));
  return input;
}

function snapshotRenderSignature(snapshot) {
  const media = snapshot?.media ?? {};
  return JSON.stringify({
    volume: snapshot?.volume ?? {},
    media: {
      available: media.available,
      title: media.title,
      artist: media.artist,
      source: media.source,
      artworkDataUrl: media.artworkDataUrl,
      durationSeconds: media.durationSeconds,
      isPlaying: media.isPlaying,
      playbackRate: media.playbackRate,
      canPlayPause: media.canPlayPause,
      canSeek: media.canSeek,
      canChangeRate: media.canChangeRate,
      canSkipPrevious: media.canSkipPrevious,
      canSkipNext: media.canSkipNext,
      error: media.error,
    },
  });
}

function patchMediaPosition(root, snapshot) {
  const progress = root.querySelector(".hp-media-timeline input[type=\"range\"]");
  const label = root.querySelector("[data-media-time]");
  if (!(progress instanceof HTMLInputElement) || !label) {
    return;
  }

  const media = snapshot?.media ?? {};
  const duration = Math.max(0, Number(media.durationSeconds) || 0);
  const refreshedAt = Date.parse(snapshot?.refreshedAt ?? "");
  const elapsed = media.isPlaying && Number.isFinite(refreshedAt)
    ? Math.max(0, (Date.now() - refreshedAt) / 1000)
    : 0;
  const position = Math.min(duration || Number.MAX_SAFE_INTEGER, Math.max(0, (Number(media.positionSeconds) || 0) + elapsed));
  if (document.activeElement !== progress) {
    progress.max = String(Math.max(1, duration));
    progress.value = String(position);
  }
  label.textContent = `${formatTime(position)} / ${formatTime(duration)}`;
}

function isOlderSnapshot(next, current) {
  if (!current) {
    return false;
  }
  const nextTime = Date.parse(next?.refreshedAt ?? "");
  const currentTime = Date.parse(current?.refreshedAt ?? "");
  return Number.isFinite(nextTime) && Number.isFinite(currentTime) && nextTime < currentTime;
}

function iconButton(content, labelText) {
  const button = document.createElement("button");
  button.type = "button";
  button.textContent = content;
  button.title = labelText;
  button.setAttribute("aria-label", labelText);
  return button;
}

function fallbackLabel(mode, state) {
  if (mode === "starting") {
    return text(state, "接続中", "Connecting");
  }
  return text(state, "アートワーク", "Artwork");
}

function adjustedRate(current, delta) {
  const normalized = Number(current) || 1;
  return Math.max(0.5, Math.min(3, Math.round((normalized + delta) * 4) / 4));
}

function formatRate(value) {
  return String(Math.round((Number(value) || 1) * 100) / 100);
}

function formatTime(value) {
  const seconds = Math.max(0, Math.floor(Number(value) || 0));
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  const tail = String(seconds % 60).padStart(2, "0");
  return hours > 0 ? `${hours}:${String(minutes).padStart(2, "0")}:${tail}` : `${minutes}:${tail}`;
}

function text(state, ja, en) {
  return state?.settings?.language === "en" ? en : ja;
}

function localizeError(message, state) {
  if (!message || state?.settings?.language === "en") {
    return message || "";
  }

  const exact = new Map([
    ["Brightness detection is still running.", "明るさを検出しています。"],
    ["Brightness readback is still running.", "明るさの反映を確認しています。"],
    ["Display brightness is unavailable.", "ディスプレイの明るさを取得できません。"],
    ["Brightness detection timed out.", "明るさの検出が時間切れになりました。"],
    ["Brightness command timed out.", "明るさの変更が時間切れになりました。"],
    ["Contrast command timed out.", "コントラストの変更が時間切れになりました。"],
    ["DDC/CI contrast read failed.", "DDC/CIでコントラストを読み取れませんでした。"],
    ["Volume detection timed out.", "音量の検出が時間切れになりました。"],
    ["Media detection timed out.", "メディアの検出が時間切れになりました。"],
    ["Volume command timed out.", "音量の変更が時間切れになりました。"],
    ["Mute command timed out.", "ミュート操作が時間切れになりました。"],
    ["Media command timed out.", "メディア操作が時間切れになりました。"],
    ["The playing window could not be brought to the front.", "再生中の画面を特定できなかったため、前面に表示しませんでした。"],
  ]);
  if (exact.has(message)) {
    return exact.get(message);
  }
  if (/^Brightness readback did not match \d+%\.$/.test(message)) {
    return `明るさが指定値（${message.match(/\d+%/)?.[0] ?? ""}）に反映されたことを確認できませんでした。`;
  }
  if (/^Brightness command failed for \d+%\.$/.test(message)) {
    return `明るさを${message.match(/\d+%/)?.[0] ?? "指定値"}へ変更できませんでした。もう一度操作してください。`;
  }
  const contrastMismatch = /^Contrast readback did not match (\d+%)\.$/.exec(message);
  if (contrastMismatch) {
    return `コントラストが指定値（${contrastMismatch[1]}）に反映されたことを確認できませんでした。モニターの映像モードで固定されている場合があります。`;
  }
  const contrastFailure = /^Contrast command failed for (\d+%)\.$/.exec(message);
  if (contrastFailure) {
    return `コントラストを${contrastFailure[1]}へ変更できませんでした。もう一度操作してください。`;
  }
  return message;
}

function localizedDisplayName(name, state) {
  if (state?.settings?.language === "en") {
    return name;
  }
  return String(name ?? "")
    .replace(/^Built-in display/, "内蔵ディスプレイ")
    .replace(/^Display$/, "ディスプレイ");
}

function ensureStylesheet() {
  if (document.querySelector("link[data-controls-css]")) {
    return;
  }
  const link = document.createElement("link");
  link.rel = "stylesheet";
  link.href = styleHref;
  link.dataset.controlsCss = "true";
  document.head.append(link);
}
