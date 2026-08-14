import { t } from "../js/i18n.js";

const waveformHeights = [5, 10, 16, 8, 20, 12, 7, 15, 9, 5];

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
  primary.disabled = !voice.isSessionActive;

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

  compact.append(primary, waveform, conversation, sessionCount, mute, toggle, end);
  container.append(compact);

  if (layout === "expanded") {
    container.append(createExpanded(voice));
  }
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
  if (voice.sessionStatus === "reconnecting" || voice.availability === "faulted") {
    return t("voiceReconnecting");
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
