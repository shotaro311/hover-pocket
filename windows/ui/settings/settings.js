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
const aiNativeEl = document.querySelector("[data-ai-native]");
const aiNativeLabelEl = document.querySelector("[data-ai-native-label]");
const aiNativeNoteEl = document.querySelector("[data-ai-native-note]");
const pocketGenerationEl = document.querySelector("[data-pocket-generation]");
const pocketGenerationNoteEl = document.querySelector("[data-pocket-generation-note]");
const pocketGenerationRequestEl = document.querySelector("[data-pocket-generation-request]");
const pocketGenerateEl = document.querySelector("[data-pocket-generate]");
const pocketCancelEl = document.querySelector("[data-pocket-cancel]");
const pocketGenerationStatusEl = document.querySelector("[data-pocket-generation-status]");
const pocketGenerationProposalEl = document.querySelector("[data-pocket-generation-proposal]");
const pocketGenerationManagedEl = document.querySelector("[data-pocket-generation-managed]");
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
let generationState = null;
let generationUpdateTarget = null;

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
  aiNativeEl.checked = Boolean(state.settings.aiNativeEnabled);
  aiNativeLabelEl.textContent = state.settings.language === "en" ? "AI-native features" : "AIネイティブ機能";
  aiNativeNoteEl.textContent = state.settings.language === "en"
    ? "Off by default. Disabling cancels generation immediately; enabling after an OFF startup requires a HoverPocket restart and never hot-starts Codex."
    : "既定ではオフです。OFFは生成を即時停止します。OFFで起動した後のONはHoverPocket再起動後に有効となり、Codexをhot-startしません。";
  renderPocketApps(state);
  generationState = state.pocketAppGeneration ?? generationState;
  renderPocketGeneration(generationState, state.settings.language);
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

function renderPocketGeneration(generation, language) {
  const enabled = Boolean(currentState?.settings?.aiNativeEnabled && generation);
  pocketGenerationEl.hidden = !enabled;
  if (!enabled) {
    generationState = null;
    return;
  }

  generationState = generation;
  pocketGenerationNoteEl.textContent = language === "en"
    ? "Codex returns definition files only. HoverPocket revalidates exact bytes, previews, permissions, grants, and tests before explicit approval."
    : "Codexは定義ファイルだけを返します。HoverPocketがbytes・preview・権限・grant・testsを再検証し、明示承認後にだけ導入します。";
  pocketGenerateEl.textContent = language === "en" ? "Generate & Validate" : "生成して検証";
  pocketCancelEl.textContent = language === "en" ? "Cancel" : "キャンセル";
  pocketCancelEl.hidden = generation.phase !== "generating";
  pocketGenerateEl.disabled = generation.phase === "generating"
    || generation.phase === "installing"
    || Boolean(generation.proposal)
    || generation.generatorAvailable === false;

  const targetLabel = generationUpdateTarget
    ? (language === "en" ? `Update target: ${generationUpdateTarget}` : `更新対象: ${generationUpdateTarget}`)
    : "";
  const statusParts = [generation.phase, targetLabel, generation.errorCode].filter(Boolean);
  if (generation.receipt?.readbackVerified) {
    statusParts.push(language === "en"
      ? `readback verified: ${generation.receipt.action} ${generation.receipt.appId} ${generation.receipt.version ?? "-"}`
      : `readback確認済み: ${generation.receipt.action} ${generation.receipt.appId} ${generation.receipt.version ?? "-"}`);
  }
  pocketGenerationStatusEl.textContent = statusParts.join(" · ");

  pocketGenerationProposalEl.replaceChildren();
  if (generation.proposal) {
    const proposal = generation.proposal;
    const card = document.createElement("article");
    card.className = "pocket-app-card";
    const heading = document.createElement("div");
    heading.className = "pocket-app-heading";
    const title = document.createElement("strong");
    title.textContent = `${proposal.action} · ${proposal.appId} · v${proposal.version}`;
    const digest = document.createElement("span");
    digest.textContent = shortDigest(proposal.packageDigest);
    heading.append(title, digest);

    const binding = document.createElement("code");
    binding.textContent = `request=${proposal.requestId}\nbinding=${proposal.bindingDigest}\npreview=${proposal.previewDigest}`;
    const diff = document.createElement("code");
    diff.textContent = `permissions +[${proposal.permissionDiff.added.join(", ")}] -[${proposal.permissionDiff.removed.join(", ")}]\ngrants +${proposal.capabilityGrantDiff.added.length} / -${proposal.capabilityGrantDiff.removed.length}\ntests ${proposal.tests.filter((item) => item.status === item.expected).length}/${proposal.tests.length}`;
    card.append(heading, binding, diff);

    for (const preview of proposal.previews ?? []) {
      const previewTitle = document.createElement("code");
      previewTitle.textContent = `${preview.id} · ${shortDigest(preview.renderDigest)}`;
      const pre = document.createElement("pre");
      pre.textContent = JSON.stringify(preview.renderModel, null, 2).slice(0, 3000);
      card.append(previewTitle, pre);
    }

    const actions = document.createElement("div");
    actions.className = "settings-button-row";
    const reject = document.createElement("button");
    reject.type = "button";
    reject.textContent = language === "en" ? "Reject" : "拒否";
    reject.addEventListener("click", () => runGenerationAction("pocketApps.reject", {
      requestId: proposal.requestId,
      bindingDigest: proposal.bindingDigest,
    }));
    const approve = document.createElement("button");
    approve.type = "button";
    approve.textContent = language === "en" ? "Approve exact bytes & install" : "このbytesを承認して導入";
    approve.addEventListener("click", () => runGenerationAction("pocketApps.presentApproval", {}));
    approve.disabled = proposal.activationAllowed !== true;
    actions.append(reject, approve);
    card.append(actions);
    if (proposal.activationAllowed !== true) {
      const previewOnly = document.createElement("p");
      previewOnly.className = "settings-note";
      previewOnly.textContent = language === "en"
        ? "Real Codex output is preview-only until the storage and process isolation gates are complete."
        : "実Codexの生成物は保存先・process隔離の追加検証が完了するまでpreviewのみです。";
      card.append(previewOnly);
    }
    pocketGenerationProposalEl.append(card);
  }

  pocketGenerationManagedEl.replaceChildren();
  for (const app of generation.managedApps ?? []) {
    const card = document.createElement("article");
    card.className = "pocket-app-card";
    const heading = document.createElement("div");
    heading.className = "pocket-app-heading";
    const name = document.createElement("strong");
    name.textContent = app.appId;
    const version = document.createElement("span");
    version.textContent = `${app.state} · v${app.version ?? "-"}`;
    heading.append(name, version);
    const digest = document.createElement("code");
    digest.textContent = shortDigest(app.packageDigest);
    const actions = document.createElement("div");
    actions.className = "settings-button-row";

    const updateButton = document.createElement("button");
    updateButton.type = "button";
    updateButton.textContent = language === "en" ? "Update" : "更新";
    updateButton.addEventListener("click", () => {
      generationUpdateTarget = app.appId;
      renderPocketGeneration(generationState, language);
      pocketGenerationRequestEl.focus();
    });
    actions.append(updateButton);

    if (app.state === "enabled") {
      const disableButton = document.createElement("button");
      disableButton.type = "button";
      disableButton.textContent = language === "en" ? "Disable" : "無効化";
      disableButton.addEventListener("click", () => runGenerationAction("pocketApps.disable", { appId: app.appId }));
      actions.append(disableButton);
    } else if (app.state === "disabled") {
      const enableButton = document.createElement("button");
      enableButton.type = "button";
      enableButton.textContent = language === "en" ? "Enable" : "有効化";
      enableButton.addEventListener("click", () => runGenerationAction("pocketApps.enable", { appId: app.appId }));
      actions.append(enableButton);
    }

    for (const rollbackVersion of app.rollbackVersions ?? []) {
      const rollbackButton = document.createElement("button");
      rollbackButton.type = "button";
      rollbackButton.textContent = language === "en" ? `Rollback ${rollbackVersion}` : `${rollbackVersion}へ戻す`;
      rollbackButton.addEventListener("click", () => runGenerationAction("pocketApps.prepareRollback", {
        appId: app.appId,
        version: rollbackVersion,
      }));
      actions.append(rollbackButton);
    }

    const removeButton = document.createElement("button");
    removeButton.type = "button";
    removeButton.className = "danger";
    removeButton.textContent = language === "en" ? "Remove, preserve data" : "削除（データ保持）";
    removeButton.addEventListener("click", () => runGenerationAction("pocketApps.removePreservingData", { appId: app.appId }));
    actions.append(removeButton);

    card.append(heading, digest, actions);
    pocketGenerationManagedEl.append(card);
  }
}

async function runGenerationAction(method, params = undefined) {
  try {
    pocketGenerationStatusEl.textContent = "";
    generationState = await request(method, params);
    if (generationState.receipt?.readbackVerified) {
      generationUpdateTarget = null;
    }
    renderPocketGeneration(generationState, currentState.settings.language);
  } catch (error) {
    pocketGenerationStatusEl.textContent = String(error?.message ?? error);
  }
}

function shortDigest(value) {
  if (!value) return "-";
  return value.length > 22 ? `${value.slice(0, 22)}…` : value;
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

aiNativeEl.addEventListener("change", () => {
  update("settings.setAiNativeEnabled", { enabled: aiNativeEl.checked });
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

pocketGenerateEl.addEventListener("click", async () => {
  const text = pocketGenerationRequestEl.value.trim();
  if (!text) return;
  await runGenerationAction("pocketApps.generate", {
    request: text,
    updatingAppId: generationUpdateTarget,
  });
  if (generationState?.phase === "awaiting_approval") {
    generationUpdateTarget = null;
  }
});

pocketCancelEl.addEventListener("click", () => {
  runGenerationAction("pocketApps.cancelGeneration");
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
