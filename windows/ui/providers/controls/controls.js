import { on } from "../../js/bridge.js";

const styleHref = "./providers/controls/controls.css";
const brightnessUpdateDelayMs = 110;

export function renderControlsProvider(context) {
  ensureStylesheet();
  const root = document.createElement("div");
  root.className = "hp-controls is-loading";
  root.textContent = text(context.state, "コントロールを読み込んでいます…", "Loading controls…");
  context.container.append(root);

  let disposed = false;
  const pendingOperations = new Set();
  const brightnessUpdates = new Map();
  let currentSnapshot = null;
  let currentRenderSignature = "";
  let refreshPromise = null;
  let latestPreviewFrame = null;
  let previewSequence = 0;
  let previewDrawing = false;
  let pointerRangeActive = false;
  let keyboardRangeActive = false;
  let deferredSnapshot = null;
  let brightnessDetectionRetryTimer = null;
  let brightnessDetectionRetryCount = 0;

  const synchronizeBrightnessDetection = (snapshot) => {
    const detecting = (snapshot?.displays ?? []).some(
      (display) => display.error === "Brightness detection is still running.",
    );
    if (!detecting) {
      brightnessDetectionRetryCount = 0;
      if (brightnessDetectionRetryTimer != null) {
        window.clearTimeout(brightnessDetectionRetryTimer);
        brightnessDetectionRetryTimer = null;
      }
      return;
    }

    if (brightnessDetectionRetryTimer != null || brightnessDetectionRetryCount >= 3) {
      return;
    }

    brightnessDetectionRetryTimer = window.setTimeout(() => {
      brightnessDetectionRetryTimer = null;
      brightnessDetectionRetryCount += 1;
      void refresh();
    }, 900);
  };

  const drawDeferredWhenIdle = () => {
    if (pointerRangeActive || keyboardRangeActive || brightnessUpdates.size || !deferredSnapshot || disposed) {
      return;
    }

    const snapshot = deferredSnapshot;
    deferredSnapshot = null;
    draw(snapshot);
  };
  const finishRangeInteraction = () => {
    pointerRangeActive = false;
    keyboardRangeActive = false;
    drawDeferredWhenIdle();
  };
  const handlePointerUp = () => finishRangeInteraction();
  root.addEventListener("pointerdown", (event) => {
    if (event.target instanceof HTMLInputElement && event.target.type === "range") {
      pointerRangeActive = true;
    }
  });
  root.addEventListener("keydown", (event) => {
    if (event.target instanceof HTMLInputElement
        && event.target.type === "range"
        && ["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Home", "End", "PageUp", "PageDown"].includes(event.key)) {
      keyboardRangeActive = true;
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

  const queueBrightness = (id, value, immediate = false) => {
    if (disposed) {
      return;
    }

    let state = brightnessUpdates.get(id);
    if (!state) {
      state = { inFlight: false, queuedValue: null, timer: null, lastSentAt: 0 };
      brightnessUpdates.set(id, state);
    }

    state.queuedValue = Math.max(0, Math.min(100, Math.round(Number(value) || 0)));
    if (immediate && state.timer != null) {
      window.clearTimeout(state.timer);
      state.timer = null;
    }

    if (state.inFlight) {
      return;
    }

    if (immediate) {
      sendBrightness(id, state);
    } else if (state.timer == null) {
      state.timer = window.setTimeout(() => {
        state.timer = null;
        sendBrightness(id, state);
      }, brightnessUpdateDelayMs);
    }
  };

  const sendBrightness = (id, state) => {
    if (disposed || state.inFlight || state.queuedValue == null) {
      return;
    }

    const spacing = brightnessUpdateDelayMs - (performance.now() - state.lastSentAt);
    if (spacing > 1) {
      if (state.timer == null) {
        state.timer = window.setTimeout(() => {
          state.timer = null;
          sendBrightness(id, state);
        }, spacing);
      }
      return;
    }

    const value = state.queuedValue;
    state.queuedValue = null;
    state.inFlight = true;
    state.lastSentAt = performance.now();
    const operationKey = `controls.setBrightness:${id}`;
    pendingOperations.add(operationKey);
    root.classList.add("is-busy");
    context.request("controls.setBrightness", { id, value }).then((snapshot) => {
      if (!disposed) {
        draw(snapshot);
      }
    }).catch((error) => {
      if (!disposed) {
        drawError(error);
      }
    }).finally(() => {
      state.inFlight = false;
      pendingOperations.delete(operationKey);
      if (state.queuedValue != null && state.queuedValue !== value && !disposed) {
        sendBrightness(id, state);
        return;
      }

      state.queuedValue = null;
      brightnessUpdates.delete(id);
      root.classList.toggle("is-busy", pendingOperations.size > 0);
      drawDeferredWhenIdle();
    });
  };

  const draw = (snapshot) => {
    if (!snapshot || disposed || isOlderSnapshot(snapshot, currentSnapshot)) {
      return;
    }
    currentSnapshot = snapshot;
    synchronizeBrightnessDetection(snapshot);
    if (pointerRangeActive || keyboardRangeActive || brightnessUpdates.size) {
      deferredSnapshot = snapshot;
      return;
    }

    deferredSnapshot = null;
    const nextSignature = snapshotRenderSignature(snapshot);
    if (nextSignature === currentRenderSignature && root.querySelector(".hp-controls-section")) {
      patchMediaPosition(root, snapshot);
      return;
    }

    root.className = `hp-controls${pendingOperations.size ? " is-busy" : ""}`;
    root.replaceChildren(
      displaySection(snapshot.displays ?? [], context.state, queueBrightness),
      volumeSection(snapshot.volume ?? {}, context.state, update),
      mediaSection(snapshot.media ?? {}, snapshot.preview ?? {}, context.state, update),
    );
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

  const unsubscribeState = on("controls.stateChanged", (snapshot) => {
    if (!disposed) {
      draw(snapshot);
    }
  });
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
      if (brightnessDetectionRetryTimer != null) {
        window.clearTimeout(brightnessDetectionRetryTimer);
        brightnessDetectionRetryTimer = null;
      }
      for (const state of brightnessUpdates.values()) {
        if (state.timer != null) {
          window.clearTimeout(state.timer);
        }
      }
      brightnessUpdates.clear();
      pendingOperations.clear();
      window.removeEventListener("pointerup", handlePointerUp, true);
      window.removeEventListener("pointercancel", handlePointerUp, true);
    },
  };
}

function displaySection(displays, appState, queueBrightness) {
  const body = document.createElement("div");
  body.className = "hp-controls-list";
  for (const display of displays) {
    const row = document.createElement("div");
    const detecting = display.error === "Brightness detection is still running.";
    row.className = `hp-control-row${display.supported ? "" : detecting ? " is-detecting" : " is-unsupported"}`;
    const title = label(
      localizedDisplayName(display.name, appState),
      display.supported && display.value != null
        ? `${display.value}%`
        : detecting
          ? text(appState, "検出中…", "Detecting…")
          : text(appState, "非対応", "Unsupported"),
    );
    if (display.supported && display.value != null) {
      const slider = range(display.value, 0, 100);
      const valueLabel = title.querySelector("span");
      slider.addEventListener("input", () => {
        valueLabel.textContent = `${slider.value}%`;
        queueBrightness(display.id, slider.value);
      });
      slider.addEventListener("change", () => queueBrightness(display.id, slider.value, true));
      row.append(title, slider);
      if (display.writeVerified === false || display.error) {
        row.append(detail(localizeError(
          display.error || text(appState, "読み戻しに失敗しました。", "Readback failed."),
          appState,
        )));
      }
    } else {
      row.append(
        title,
        detail(localizeError(display.error || text(
          appState,
          "このディスプレイは明るさ操作に対応していません。",
          "Brightness control is not available for this display.",
        ), appState)),
      );
    }
    body.append(row);
  }
  return section(text(appState, "ディスプレイ", "Displays"), body);
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
    displays: snapshot?.displays ?? [],
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
