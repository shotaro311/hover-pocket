import { t } from "../js/i18n.js";

let draft = "";
let lastInput = null;

export function focusAiLaneInput() {
  if (lastInput) {
    lastInput.focus({ preventScroll: true });
  }
}

export function renderAiLane(root, state, request, render) {
  root.replaceChildren();
  const aiLane = state.aiLane ?? {};
  const pending = aiLane.pendingApproval;

  const status = document.createElement("div");
  status.className = "hp-ai-status";
  status.textContent = pending
    ? t("aiPending")
    : aiLane.message || t("aiStatusReady");
  root.append(status);

  if (pending) {
    root.append(renderApprovalCard(pending, request, render));
    lastInput = null;
    return;
  }

  const row = document.createElement("div");
  row.className = "hp-ai-row";

  const input = document.createElement("input");
  input.className = "hp-ai-input";
  input.type = "text";
  input.value = draft;
  input.placeholder = t("aiPlaceholder");
  input.setAttribute("aria-label", "AI command");
  input.addEventListener("input", () => {
    draft = input.value;
  });
  input.addEventListener("keydown", (event) => {
    if (event.key === "Enter") {
      submit(request, render);
    }
  });

  const button = document.createElement("button");
  button.className = "hp-ai-button";
  button.type = "button";
  button.title = t("aiSubmit");
  button.setAttribute("aria-label", t("aiSubmit"));
  button.addEventListener("click", () => submit(request, render));

  row.append(input, button);
  root.append(row);
  lastInput = input;
  requestAnimationFrame(focusAiLaneInput);
}

function renderApprovalCard(card, request, render) {
  const wrapper = document.createElement("div");
  wrapper.className = "hp-ai-approval";

  const fields = document.createElement("div");
  fields.className = "hp-ai-fields";
  for (const field of card.fields ?? []) {
    const item = document.createElement("div");
    item.className = "hp-ai-field";
    item.innerHTML = `
      <span>${escapeHtml(field.label)}</span>
      <strong>${escapeHtml(String(field.value ?? "-"))}</strong>
    `;
    fields.append(item);
  }

  const actions = document.createElement("div");
  actions.className = "hp-ai-actions";
  const approve = document.createElement("button");
  approve.type = "button";
  approve.textContent = t("aiApprove");
  approve.addEventListener("click", () => {
    request("ailane.approve", { actionId: card.actionId }).then(render);
  });

  const reject = document.createElement("button");
  reject.type = "button";
  reject.textContent = t("aiReject");
  reject.addEventListener("click", () => {
    request("ailane.reject", { actionId: card.actionId }).then(render);
  });
  actions.append(approve, reject);

  wrapper.append(fields, actions);
  return wrapper;
}

function submit(request, render) {
  const text = draft.trim();
  if (!text) {
    return;
  }

  draft = "";
  request("ailane.submit", { text }).then(render);
}

function escapeHtml(value) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}
