import { t } from "../js/i18n.js";

const waveformHeights = [5, 10, 16, 8, 20, 12, 7, 15, 9, 5];
let peerConnection = null;
let microphoneStream = null;
let remoteAudio = null;
let sessionStarting = false;
let transportAttached = false;

export function renderVoiceLane({ container, state, request }) {
  const voice = state.voiceLane ?? {};
  const layout = voice.layout ?? "disabled";
  container.hidden = layout === "disabled";
  container.dataset.layout = layout;
  container.setAttribute("aria-label", t("voiceAccessibilityLabel"));
  container.replaceChildren();
  if (layout === "disabled") {
    return;
  }

  const compact = create("div", "hp-voice-compact");
  const primary = iconButton("●", "hp-voice-round-button", t("voiceStart"));
  primary.disabled = sessionStarting || voice.availability !== "ready" || Boolean(voice.isSessionActive);
  primary.addEventListener("click", () => {
    startVoiceSession(request).catch(() => {});
  });

  const waveform = create("div", "hp-voice-waveform");
  waveform.setAttribute("aria-hidden", "true");
  waveform.classList.toggle("is-active", Boolean(voice.isSessionActive && !voice.isMuted));
  waveformHeights.forEach((height) => {
    const bar = document.createElement("i");
    bar.style.height = `${height}px`;
    waveform.append(bar);
  });

  const conversation = create("div", "hp-voice-conversation");
  const status = create("div", "hp-voice-status", statusText(voice));
  const lastLine = create(
    "div",
    "hp-voice-last-line",
    voice.transcript?.at(-1)?.text ?? t("voiceStartHint"),
  );
  conversation.append(status, lastLine);

  const sessionCount = create(
    "div",
    "hp-voice-session-count",
    `${t("voiceSessions")} ${voice.sessions?.length ?? 0}`,
  );
  const mute = iconButton(voice.isMuted ? "◉" : "◎", "hp-voice-icon-button", t("voiceMute"));
  mute.disabled = !voice.isSessionActive;
  mute.addEventListener("click", () => {
    setLocalMuted(!voice.isMuted);
    request("codexVoice.setMuted", { muted: !voice.isMuted });
  });
  const toggle = iconButton(layout === "expanded" ? "⌄" : "⌃", "hp-voice-icon-button", layout === "expanded"
    ? t("voiceCollapse")
    : t("voiceExpand"));
  toggle.dataset.voiceToggle = "true";
  toggle.setAttribute("aria-expanded", String(layout === "expanded"));
  toggle.addEventListener("click", () => {
    request("settings.setCodexVoiceLayout", {
      layout: layout === "expanded" ? "compact" : "expanded",
    });
  });
  const end = iconButton("×", "hp-voice-icon-button", t("voiceEnd"));
  end.disabled = !voice.isSessionActive;
  end.addEventListener("click", () => {
    endVoiceSession(request).catch(() => {});
  });

  compact.append(primary, waveform, conversation, sessionCount, mute, toggle, end);
  container.append(compact);

  if (layout === "expanded") {
    container.append(createExpanded(voice));
  }
}

export function handleVoicePanelClosed(request) {
  if (!peerConnection && !microphoneStream) {
    return;
  }

  cleanupTransport();
  request("codexVoice.transportDetached", { reconnectExpected: true }).catch(() => {});
}

async function startVoiceSession(request) {
  if (sessionStarting || peerConnection) {
    return;
  }

  sessionStarting = true;
  try {
    const arm = await request("codexVoice.beginMicrophoneRequest");
    if (!arm?.armed) {
      throw new DOMException("Microphone request was not armed.", "NotAllowedError");
    }

    microphoneStream = await navigator.mediaDevices.getUserMedia({
      audio: {
        echoCancellation: true,
        noiseSuppression: true,
        autoGainControl: true,
      },
      video: false,
    });

    const connection = new RTCPeerConnection();
    peerConnection = connection;
    connection.createDataChannel("oai-events");
    microphoneStream.getAudioTracks().forEach((track) => {
      connection.addTrack(track, microphoneStream);
    });
    connection.addEventListener("track", (event) => {
      remoteAudio ??= new Audio();
      remoteAudio.autoplay = true;
      remoteAudio.srcObject = event.streams[0] ?? new MediaStream([event.track]);
      remoteAudio.play().catch(() => {});
    });
    connection.addEventListener("connectionstatechange", () => {
      if (connection !== peerConnection) {
        return;
      }

      if (["failed", "disconnected", "closed"].includes(connection.connectionState)) {
        const shouldNotify = transportAttached;
        cleanupTransport();
        if (shouldNotify) {
          request("codexVoice.transportDetached", { reconnectExpected: true }).catch(() => {});
        }
      }
    });

    const offer = await connection.createOffer({ offerToReceiveAudio: true });
    await connection.setLocalDescription(offer);
    await waitForIceGatheringComplete(connection);
    const localSdp = connection.localDescription?.sdp;
    if (!localSdp) {
      throw new Error("WebRTC local SDP was unavailable.");
    }

    const answer = await request("codexVoice.startWebRtc", { sdp: localSdp });
    if (!answer?.sdp || connection !== peerConnection) {
      throw new Error("WebRTC remote SDP was unavailable.");
    }

    await connection.setRemoteDescription({ type: "answer", sdp: answer.sdp });
    transportAttached = true;
    setLocalMuted(false);
    await request("codexVoice.transportAttached");
  } catch (error) {
    const errorCode = error?.name === "NotAllowedError"
      ? "microphone_denied"
      : "webrtc_failed";
    cleanupTransport();
    await request("codexVoice.startFailed", { errorCode }).catch(() => {});
    throw error;
  } finally {
    sessionStarting = false;
  }
}

async function endVoiceSession(request) {
  cleanupTransport();
  await request("codexVoice.stop");
}

function setLocalMuted(muted) {
  microphoneStream?.getAudioTracks().forEach((track) => {
    track.enabled = !muted;
  });
}

function cleanupTransport() {
  transportAttached = false;
  const connection = peerConnection;
  peerConnection = null;
  if (connection) {
    connection.ontrack = null;
    connection.close();
  }

  microphoneStream?.getTracks().forEach((track) => track.stop());
  microphoneStream = null;
  if (remoteAudio) {
    remoteAudio.pause();
    remoteAudio.srcObject = null;
    remoteAudio = null;
  }
}

function waitForIceGatheringComplete(connection) {
  if (connection.iceGatheringState === "complete") {
    return Promise.resolve();
  }

  return new Promise((resolve, reject) => {
    const timeout = window.setTimeout(() => {
      connection.removeEventListener("icegatheringstatechange", onStateChange);
      reject(new Error("WebRTC ICE gathering timed out."));
    }, 8000);
    const onStateChange = () => {
      if (connection.iceGatheringState === "complete") {
        window.clearTimeout(timeout);
        connection.removeEventListener("icegatheringstatechange", onStateChange);
        resolve();
      }
    };
    connection.addEventListener("icegatheringstatechange", onStateChange);
  });
}

function createExpanded(voice) {
  const expanded = create("div", "hp-voice-expanded");
  const transcriptColumn = create("section", "hp-voice-column");
  transcriptColumn.append(create("h2", "", t("voiceConversation")));
  const transcriptScroll = create("div", "hp-voice-scroll");
  if (!voice.transcript?.length) {
    transcriptScroll.append(create("div", "hp-voice-empty", t("voiceTranscriptEmpty")));
  } else {
    voice.transcript.forEach((entry) => {
      const item = create("article", "hp-voice-transcript-entry");
      item.append(
        create("div", "hp-voice-transcript-role", entry.role === "user" ? t("voiceYou") : "Codex"),
        create("div", "hp-voice-transcript-text", entry.text ?? ""),
      );
      transcriptScroll.append(item);
    });
  }
  transcriptColumn.append(transcriptScroll);

  const sessionColumn = create("section", "hp-voice-column");
  sessionColumn.append(create("h2", "", t("voiceCodexSessions")));
  const sessionScroll = create("div", "hp-voice-scroll");
  if (!voice.sessions?.length) {
    sessionScroll.append(create("div", "hp-voice-empty", t("voiceSessionsEmpty")));
  } else {
    voice.sessions.forEach((session) => sessionScroll.append(createSessionCard(session)));
  }
  sessionColumn.append(sessionScroll);
  expanded.append(transcriptColumn, sessionColumn);
  return expanded;
}

function createSessionCard(session) {
  const card = create("article", "hp-voice-session-card");
  const dot = create("span", "hp-voice-session-dot");
  dot.classList.toggle("is-completed", session.state === "completed");
  dot.classList.toggle("is-failed", session.state === "failed");
  const copy = create("div", "");
  copy.append(
    create("div", "hp-voice-session-title", session.title ?? ""),
    create("div", "hp-voice-session-detail", session.detail ?? ""),
  );
  card.append(dot, copy, create("div", "hp-voice-session-time", elapsedText(session.elapsedSeconds)));
  return card;
}

function statusText(voice) {
  if (voice.expansionBlocked) {
    return t("voiceCompactFallback");
  }
  if (voice.status === "listening") {
    return t("voiceListening");
  }
  if (voice.lastErrorCode === "microphone_denied") {
    return t("voiceMicrophoneDenied");
  }
  if (voice.sessionStatus === "requestingPermission") {
    return t("voiceRequestingPermission");
  }
  if (["negotiating", "connecting"].includes(voice.sessionStatus)) {
    return t("voiceNegotiating");
  }
  if (voice.sessionStatus === "connected") {
    return t("voiceConnected");
  }
  if (voice.sessionStatus === "muted") {
    return t("voiceMuted");
  }
  if (voice.sessionStatus === "recoverableFailure") {
    return t("voiceStartFailed");
  }
  if (voice.sessionStatus === "reconnecting" || voice.availability === "faulted") {
    return t("voiceReconnecting");
  }
  if (voice.availability === "starting") {
    return t("voiceStarting");
  }
  if (voice.availability === "ready") {
    return t("voiceReady");
  }
  if (voice.availability === "signedOut") {
    return t("voiceSignedOut");
  }
  if (voice.availability === "unavailable") {
    return t("voiceUnavailable");
  }
  if (voice.availability === "incompatible" || voice.availability === "blocked") {
    return t("voiceIncompatible");
  }
  return t("voiceNotConnected");
}

function elapsedText(totalSeconds = 0) {
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = Math.max(0, totalSeconds % 60);
  return `${minutes}:${String(seconds).padStart(2, "0")}`;
}

function iconButton(text, className, label) {
  const button = create("button", className, text);
  button.type = "button";
  button.setAttribute("aria-label", label);
  return button;
}

function create(tagName, className, text = undefined) {
  const element = document.createElement(tagName);
  if (className) {
    element.className = className;
  }
  if (text !== undefined) {
    element.textContent = text;
  }
  return element;
}
