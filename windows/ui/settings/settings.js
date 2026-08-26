import { on, request } from "../js/bridge.js";
import { labelForSize, setLanguage, t } from "../js/i18n.js";
import { createGenerationTargetState } from "./generation-target-state.mjs";

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
const voiceHeadingEl = document.querySelector("[data-voice-heading]");
const voiceProviderEl = document.querySelector("[data-voice-provider]");
const voiceEnabledEl = document.querySelector("[data-voice-enabled]");
const voiceOpenAIKeyRowEl = document.querySelector("[data-voice-openai-key-row]");
const voiceOpenAIKeyStatusEl = document.querySelector("[data-voice-openai-key-status]");
const voiceOpenAIKeyConfigureEl = document.querySelector("[data-voice-openai-key-configure]");
const voiceOpenAIKeyDeleteEl = document.querySelector("[data-voice-openai-key-delete]");
const voiceEnabledLabelEl = document.querySelector("[data-voice-enabled-label]");
const voiceLayoutEl = document.querySelector("[data-voice-layout]");
const voiceNoteEl = document.querySelector("[data-voice-note]");
const voiceCalendarAccessEl = document.querySelector("[data-voice-calendar-access]");
const voiceCalendarLabelEl = document.querySelector("[data-voice-calendar-label]");
const voiceCalendarNoteEl = document.querySelector("[data-voice-calendar-note]");
const pocketGenerationEl = document.querySelector("[data-pocket-generation]");
const pocketGenerationNoteEl = document.querySelector("[data-pocket-generation-note]");
const pocketGenerationRequestEl = document.querySelector("[data-pocket-generation-request]");
const pocketGenerationUpdateSelectionEl = document.querySelector("[data-pocket-generation-update-selection]");
const pocketGenerationUpdateTargetEl = document.querySelector("[data-pocket-generation-update-target]");
const pocketGenerationClearTargetEl = document.querySelector("[data-pocket-generation-clear-target]");
const pocketGenerateEl = document.querySelector("[data-pocket-generate]");
const pocketCancelEl = document.querySelector("[data-pocket-cancel]");
const pocketGenerationStatusEl = document.querySelector("[data-pocket-generation-status]");
const pocketGenerationProposalEl = document.querySelector("[data-pocket-generation-proposal]");
const pocketGenerationManagedEl = document.querySelector("[data-pocket-generation-managed]");
const pocketWorkspaceExportEl = document.querySelector("[data-pocket-workspace-export]");
const pocketWorkspaceRestoreEl = document.querySelector("[data-pocket-workspace-restore]");
const pocketWorkspaceStatusEl = document.querySelector("[data-pocket-workspace-status]");
const pocketWorkspacePreviewEl = document.querySelector("[data-pocket-workspace-preview]");
const pocketWorkspaceNoteEl = document.querySelector("[data-pocket-workspace-note]");
const capabilityHistoryHeadingEl = document.querySelector("[data-capability-history-heading]");
const capabilityRetentionEl = document.querySelector("[data-capability-retention]");
const capabilityHistorySummaryEl = document.querySelector("[data-capability-history-summary]");
const capabilityHistoryClearEl = document.querySelector("[data-capability-history-clear]");
const capabilityHistoryNoteEl = document.querySelector("[data-capability-history-note]");
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
const generationTarget = createGenerationTargetState();

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
  const voiceProviderId = state.settings.voiceProviderId ?? "off";
  const voiceEnabled = Boolean(state.settings.voiceEnabled);
  const englishVoice = state.settings.language === "en";
  voiceHeadingEl.textContent = "Voice Lane";
  renderSegment(voiceProviderEl, [
    { id: "off", label: englishVoice ? "Off" : "オフ" },
    { id: "openai_realtime_byok", label: "OpenAI Realtime BYOK" },
    { id: "codex_app_server", label: "Codex app-server" },
  ], voiceProviderId, (providerId) => update("settings.setVoiceProvider", { providerId }));
  voiceEnabledEl.checked = voiceEnabled;
  voiceEnabledEl.disabled = voiceProviderId === "off";
  voiceEnabledLabelEl.textContent = englishVoice ? "Enable Voice Lane" : "Voice Laneを有効化";
  voiceOpenAIKeyRowEl.hidden = voiceProviderId !== "openai_realtime_byok";
  voiceOpenAIKeyStatusEl.textContent = state.settings.voiceOpenAIKeyConfigured
    ? (englishVoice ? "API key saved securely" : "APIキーは安全に保存済み")
    : (englishVoice ? "API key not configured" : "APIキー未設定");
  voiceOpenAIKeyConfigureEl.textContent = englishVoice ? "Configure API key" : "APIキーを設定";
  voiceOpenAIKeyDeleteEl.textContent = englishVoice ? "Delete API key" : "APIキーを削除";
  voiceOpenAIKeyDeleteEl.disabled = !state.settings.voiceOpenAIKeyConfigured;
  voiceNoteEl.textContent = voiceProviderId === "codex_app_server"
    ? (englishVoice
      ? "Codex app-server remains fail-closed until its installed version can positively prove Broker-only tools. There is no fallback to OpenAI Realtime."
      : "Codex app-serverは、導入済み版がBroker限定ツールを正に証明できるまでfail-closedのままです。OpenAI Realtimeへの自動fallbackはありません。")
    : voiceProviderId === "openai_realtime_byok"
      ? (englishVoice
        ? "The API key stays Host-only. Windows exchanges SDP with /v1/realtime/calls and exposes only Registry-derived Calendar/Timer functions through CapabilityBroker."
        : "APIキーはHostだけが保持します。Windowsは/v1/realtime/callsでSDPを交換し、CapabilityBroker経由のRegistry由来Calendar/Timer関数だけを公開します。")
      : (englishVoice ? "Provider is explicitly Off. No credential, network, or transport work occurs." : "Providerは明示的にオフです。credential・network・transport処理は行いません。");
  voiceCalendarAccessEl.checked = Boolean(state.settings.voiceCalendarAccessGranted);
  voiceCalendarLabelEl.textContent = englishVoice
    ? "Allow Voice Lane to use today's Calendar and create approved events"
    : "Voice Laneに今日のCalendar参照と承認済み予定作成を許可";
  voiceCalendarNoteEl.textContent = englishVoice
    ? "Separate from Google sign-in and microphone access. Calendar create requires native per-call approval and Broker readback."
    : "Googleログインやマイク権限とは別の許可です。Calendar作成は毎回ネイティブ承認とBroker readbackを要求します。";
  renderSegment(voiceLayoutEl, [
    { id: "compact", label: state.settings.language === "en" ? "Compact" : "コンパクト" },
    { id: "expanded", label: state.settings.language === "en" ? "Expanded" : "展開" },
  ], state.settings.voiceLaneLayout ?? "compact", (layout) => update("settings.setVoiceLayout", { layout }), !voiceEnabled);
  renderPocketApps(state);
  generationState = state.pocketAppGeneration ?? generationState;
  renderPocketGeneration(generationState, state.settings.language);
  renderCapabilityHistory(state);
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

function renderCapabilityHistory(state) {
  const english = state.settings.language === "en";
  const governance = state.capabilityDataGovernance;
  capabilityHistoryHeadingEl.textContent = english ? "Audit logs and execution history" : "監査ログと実行履歴";
  capabilityHistoryClearEl.textContent = english ? "Delete history" : "履歴を削除";
  capabilityHistoryClearEl.disabled = governance?.available !== true;
  capabilityHistoryNoteEl.textContent = english
    ? "Deleting removes receipt content and audit logs. Minimal completion tombstones remain to prevent duplicate execution."
    : "削除後も重複実行を防ぐ最小限の実行済み情報は残ります。";
  renderSegment(capabilityRetentionEl, [
    { id: "sevenDays", label: english ? "7 days" : "7日" },
    { id: "thirtyDays", label: english ? "30 days" : "30日" },
    { id: "ninetyDays", label: english ? "90 days" : "90日" },
    { id: "forever", label: english ? "Forever" : "無期限" },
  ], state.settings.capabilityDataRetentionPeriod ?? "ninetyDays", (period) => {
    update("settings.setCapabilityRetention", { period });
  }, governance?.available !== true);
  capabilityHistorySummaryEl.textContent = governance?.available === true
    ? english
      ? `${governance.auditFileCount} audit files · ${governance.storedReceiptCount} stored receipts · ${governance.redactedTombstoneCount} redacted tombstones`
      : `監査ファイル ${governance.auditFileCount}件・保存済み履歴 ${governance.storedReceiptCount}件・削除済み墓標 ${governance.redactedTombstoneCount}件`
    : english
      ? "History storage is unavailable."
      : "履歴ストレージを利用できません。";
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
    generationTarget.clear();
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
    || Boolean(generation.workspaceBackup?.pending)
    || generation.generatorAvailable === false;

  const updateTarget = generationTarget.value;
  pocketGenerationUpdateSelectionEl.hidden = updateTarget === null;
  pocketGenerationUpdateTargetEl.textContent = updateTarget === null
    ? ""
    : (language === "en" ? `Update target: ${updateTarget}` : `更新対象: ${updateTarget}`);
  pocketGenerationClearTargetEl.textContent = language === "en" ? "Create new app instead" : "新規Appとして作成";
  renderWorkspaceBackup(generation.workspaceBackup, generation, language);

  const statusParts = [generation.phase, generation.errorCode].filter(Boolean);
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
  const healthByApp = new Map((generation.appHealth ?? []).map((item) => [item.appId, item]));
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
    const health = healthByApp.get(app.appId);
    const healthLine = document.createElement("p");
    healthLine.className = "settings-note";
    if (health?.status === "unused") {
      healthLine.textContent = language === "en"
        ? "Unused for 30+ days. You can disable it if no longer needed."
        : "30日以上未使用です。必要なければ無効化できます。";
    } else if (health?.status === "attention") {
      healthLine.textContent = language === "en"
        ? `Needs attention: ${health.reasonCode}`
        : `要確認: ${health.reasonCode}`;
    } else if (health?.status === "disabled") {
      healthLine.textContent = language === "en" ? "Disabled" : "無効化済み";
    } else {
      healthLine.textContent = language === "en" ? "Healthy" : "正常";
    }
    const actions = document.createElement("div");
    actions.className = "settings-button-row";

    const updateButton = document.createElement("button");
    updateButton.type = "button";
    updateButton.textContent = language === "en" ? "Update" : "更新";
    updateButton.addEventListener("click", () => {
      generationTarget.select(app.appId);
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

    card.append(heading, digest, healthLine, actions);
    if (generation.workspaceBackup?.pending) {
      actions.querySelectorAll("button").forEach((button) => { button.disabled = true; });
    }
    pocketGenerationManagedEl.append(card);
  }

  for (const issue of generation.managementIssues ?? []) {
    const card = document.createElement("article");
    card.className = "pocket-app-card";
    const heading = document.createElement("div");
    heading.className = "pocket-app-heading";
    const name = document.createElement("strong");
    name.textContent = issue.appId;
    const status = document.createElement("span");
    status.textContent = language === "en" ? "Needs repair" : "要修復";
    heading.append(name, status);
    const error = document.createElement("code");
    error.textContent = issue.errorCode;
    const actions = document.createElement("div");
    actions.className = "settings-button-row";
    if (issue.migrationAvailable === true && typeof issue.suggestedVersion === "string") {
      const migrationButton = document.createElement("button");
      migrationButton.type = "button";
      migrationButton.textContent = language === "en" ? "Prepare compatibility update" : "互換更新を準備";
      migrationButton.addEventListener("click", () => runGenerationAction(
        "pocketApps.prepareCapabilityMigration",
        { appId: issue.appId, targetVersion: issue.suggestedVersion },
      ));
      actions.append(migrationButton);
    }
    const removeButton = document.createElement("button");
    removeButton.type = "button";
    removeButton.className = "danger";
    removeButton.textContent = language === "en" ? "Remove, preserve data" : "削除（データ保持）";
    removeButton.disabled = issue.removalAllowed !== true;
    removeButton.addEventListener("click", () => runGenerationAction(
      "pocketApps.removePreservingData",
      { appId: issue.appId },
    ));
    actions.append(removeButton);
    if (generation.workspaceBackup?.pending) {
      actions.querySelectorAll("button").forEach((button) => { button.disabled = true; });
    }
    card.append(heading, error, actions);
    pocketGenerationManagedEl.append(card);
  }
}

function renderWorkspaceBackup(workspace, generation, language) {
  const busy = generation.phase === "generating"
    || generation.phase === "installing"
    || Boolean(generation.proposal)
    || Boolean(workspace?.pending);
  pocketWorkspaceExportEl.textContent = language === "en" ? "Export workspace" : "workspaceを書き出す";
  pocketWorkspaceRestoreEl.textContent = language === "en" ? "Restore from backup" : "backupから復元";
  pocketWorkspaceExportEl.disabled = busy;
  pocketWorkspaceRestoreEl.disabled = busy;
  pocketWorkspaceNoteEl.textContent = language === "en"
    ? "OAuth, credentials, audit logs, and Codex workspaces are excluded. Restore revalidates every hash, schema, permission, and data entry."
    : "OAuth、credential、監査ログ、Codex workspaceは含みません。復元は全hash・schema・権限・dataを再検証します。";

  const status = [];
  if (workspace?.errorCode) status.push(workspace.errorCode);
  if (workspace?.receipt?.readbackVerified) {
    status.push(language === "en"
      ? `Post-restore readback verified: ${workspace.receipt.restoredApps.length} app(s)`
      : `復元後readback確認済み: ${workspace.receipt.restoredApps.length}件`);
  } else if (workspace?.lastBackupDigest) {
    status.push(language === "en"
      ? `Backup readback verified: ${shortDigest(workspace.lastBackupDigest)}`
      : `backup readback確認済み: ${shortDigest(workspace.lastBackupDigest)}`);
  }
  pocketWorkspaceStatusEl.textContent = status.join(" · ");

  pocketWorkspacePreviewEl.replaceChildren();
  if (!workspace?.pending) return;
  const proposal = workspace.pending;
  const card = document.createElement("article");
  card.className = "pocket-app-card";
  const heading = document.createElement("div");
  heading.className = "pocket-app-heading";
  const title = document.createElement("strong");
  title.textContent = language === "en" ? "Restore preview" : "復元preview";
  const digest = document.createElement("span");
  digest.textContent = shortDigest(proposal.backupDigest);
  heading.append(title, digest);
  card.append(heading);
  for (const change of proposal.changes ?? []) {
    const line = document.createElement("code");
    line.textContent = `${change.action} · ${change.appId} · ${change.fromVersion ?? "-"} → ${change.toVersion} · state ${change.fromLifecycleState ?? "-"} → ${change.toLifecycleState} · permissions +${change.addedPermissions.length}/-${change.removedPermissions.length} · data ${change.dataChanged ? "changed" : "same"}`;
    card.append(line);
  }
  const actions = document.createElement("div");
  actions.className = "settings-button-row";
  const cancel = document.createElement("button");
  cancel.type = "button";
  cancel.textContent = language === "en" ? "Cancel" : "取消";
  cancel.addEventListener("click", () => runGenerationAction("pocketApps.cancelRestore"));
  const approve = document.createElement("button");
  approve.type = "button";
  approve.textContent = language === "en" ? "Review restore" : "復元内容を確認";
  approve.addEventListener("click", () => runGenerationAction("pocketApps.presentRestoreApproval"));
  actions.append(cancel, approve);
  card.append(actions);
  pocketWorkspacePreviewEl.append(card);
}

async function runGenerationAction(method, params = undefined) {
  try {
    pocketGenerationStatusEl.textContent = "";
    generationState = await request(method, params);
    if (generationState.receipt?.readbackVerified) {
      generationTarget.clear();
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

function renderSegment(root, options, selectedId, onSelect, disabled = false) {
  root.replaceChildren();
  for (const option of options) {
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = option.label;
    button.disabled = disabled;
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

voiceEnabledEl.addEventListener("change", () => {
  update("settings.setVoiceEnabled", { enabled: voiceEnabledEl.checked });
});

voiceOpenAIKeyConfigureEl.addEventListener("click", () => {
  update("settings.configureVoiceOpenAIKey");
});

voiceOpenAIKeyDeleteEl.addEventListener("click", () => {
  update("settings.deleteVoiceOpenAIKey");
});

voiceCalendarAccessEl.addEventListener("change", () => {
  update("settings.setVoiceCalendarAccess", { enabled: voiceCalendarAccessEl.checked });
});

capabilityHistoryClearEl.addEventListener("click", () => {
  update("settings.clearCapabilityHistory");
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
    updatingAppId: generationTarget.value,
  });
  if (generationState?.phase === "awaiting_approval") {
    generationTarget.clear();
    renderPocketGeneration(generationState, currentState.settings.language);
  }
});

pocketGenerationClearTargetEl.addEventListener("click", () => {
  generationTarget.clear();
  renderPocketGeneration(generationState, currentState.settings.language);
  pocketGenerationRequestEl.focus();
});

pocketCancelEl.addEventListener("click", () => {
  runGenerationAction("pocketApps.cancelGeneration");
});

pocketWorkspaceExportEl.addEventListener("click", () => {
  runGenerationAction("pocketApps.exportBackup");
});

pocketWorkspaceRestoreEl.addEventListener("click", () => {
  runGenerationAction("pocketApps.prepareRestore");
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
