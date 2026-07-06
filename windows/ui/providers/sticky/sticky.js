const COLORS = [
  { id: "yellow", label: "Yellow" },
  { id: "pink", label: "Pink" },
  { id: "mint", label: "Mint" },
  { id: "blue", label: "Blue" },
  { id: "lavender", label: "Lavender" },
];

const GRID_SIZES = [
  { id: "small", label: "S" },
  { id: "medium", label: "M" },
  { id: "large", label: "L" },
];

let bridgeRequest = null;
let containerEl = null;
let stickyState = null;
let selectedNoteId = null;
let selectedNewColor = "yellow";
let draft = null;
let toast = null;
let draggingNoteId = null;
let dropTargetNoteId = null;
let trashTargeted = false;
let menu = null;
const pendingNewNoteIds = new Set();

/**
 * @param {{ container: HTMLElement, request: (method: string, params?: unknown) => Promise<unknown> }} options
 */
export function renderStickyProvider(options) {
  containerEl = options.container;
  bridgeRequest = options.request;
  ensureStylesheet();

  if (!stickyState) {
    renderLoading();
  }

  void refreshState();
}

export async function runStickyVerify() {
  const state = await send("sticky.getState");
  return {
    stickyBridgeOk: Array.isArray(state?.notes),
    stickyPreferencesOk: Boolean(state?.preferences?.gridSize),
    stickyNoteCount: state?.notes?.length ?? 0,
  };
}

async function refreshState() {
  stickyState = await send("sticky.getState");
  render();
}

async function send(method, params = undefined) {
  if (!bridgeRequest) {
    throw new Error("Sticky bridge is unavailable.");
  }

  return bridgeRequest(method, params);
}

async function updateState(method, params = undefined) {
  const result = await send(method, params);
  stickyState = result?.state ?? result;
  return result;
}

function renderLoading() {
  if (!containerEl) {
    return;
  }

  containerEl.replaceChildren(element("div", { className: "sticky-loading" }, "Loading sticky notes..."));
}

function render() {
  if (!containerEl || !stickyState) {
    return;
  }

  closeMenuIfNoteGone();

  const root = element("section", {
    className: `sticky-root sticky-grid-${stickyState.preferences?.gridSize ?? "medium"}`,
  });
  root.append(renderHeader());
  root.append(renderBoard());
  if (toast && stickyState.preferences?.showUndoToast !== false) {
    root.append(renderUndoToast());
  }
  if (menu) {
    root.append(renderContextMenu());
  }

  containerEl.replaceChildren(root);
}

function renderHeader() {
  const header = element("header", { className: "sticky-header" });
  const count = stickyState.notes?.length ?? 0;
  header.append(
    element("div", { className: "sticky-title" }, "Sticky Notes"),
    element("div", { className: "sticky-count" }, String(count)),
    renderGridSizeButtons(),
    element("div", { className: "sticky-header-spacer" }),
    renderColorSwatches({
      selectedColor: selectedNewColor,
      onSelect: (color) => {
        selectedNewColor = color;
        render();
      },
      onDoubleClick: (color) => void createNote(color),
    }),
    renderIconButton("+", "New note", () => void createNote(selectedNewColor), "sticky-new-button")
  );

  if (stickyState.lastErrorMessage) {
    header.append(element("div", { className: "sticky-error" }, stickyState.lastErrorMessage));
  }

  return header;
}

function renderGridSizeButtons() {
  const wrapper = element("div", { className: "sticky-grid-size", role: "group", ariaLabel: "Sticky note grid size" });
  const current = stickyState.preferences?.gridSize ?? "medium";

  for (const size of GRID_SIZES) {
    const button = element("button", {
      className: "sticky-mini-button",
      type: "button",
      ariaPressed: String(current === size.id),
      ariaLabel: `Grid size ${size.label}`,
    }, size.label);
    button.addEventListener("click", async () => {
      await finishEditing();
      stickyState = await send("sticky.setGridSize", { gridSize: size.id });
      render();
    });
    wrapper.append(button);
  }

  return wrapper;
}

function renderBoard() {
  const board = element("div", { className: "sticky-board" });
  const notes = stickyState.notes ?? [];

  if (notes.length === 0) {
    board.append(element("div", { className: "sticky-empty" }, "No notes"));
  } else {
    const grid = element("div", { className: "sticky-grid" });
    grid.addEventListener("click", (event) => {
      if (event.target === grid) {
        void finishEditing();
      }
    });
    for (const [index, note] of notes.entries()) {
      grid.append(note.id === selectedNoteId ? renderEditor(note) : renderPreviewCard(note, index));
    }
    board.append(grid);
  }

  board.append(renderTrashDropZone());
  return board;
}

function renderPreviewCard(note, index) {
  const card = element("article", {
    className: `sticky-note sticky-note-${note.color}${dropTargetNoteId === note.id ? " is-drop-target" : ""}${draggingNoteId === note.id ? " is-dragging" : ""}`,
    draggable: "true",
    tabIndex: "0",
    ariaLabel: `Edit ${displayTitle(note)}`,
  });
  card.dataset.stickyNoteId = note.id;

  card.addEventListener("click", () => void beginEditing(note));
  card.addEventListener("keydown", (event) => {
    if (event.key === "Enter") {
      event.preventDefault();
      void beginEditing(note);
    }
  });
  card.addEventListener("contextmenu", (event) => {
    event.preventDefault();
    showContextMenu(note, event.clientX, event.clientY);
  });
  card.addEventListener("dragstart", (event) => {
    draggingNoteId = note.id;
    dropTargetNoteId = null;
    trashTargeted = false;
    if (event.dataTransfer) {
      event.dataTransfer.setData("text/plain", externalText(note));
      event.dataTransfer.setData("application/x-hoverpocket-sticky-id", note.id);
      event.dataTransfer.effectAllowed = "move";
    }
    card.classList.add("is-dragging");
    setTrashVisible(true);
  });
  card.addEventListener("dragover", (event) => {
    if (!draggingNoteId || draggingNoteId === note.id) {
      return;
    }
    event.preventDefault();
    setDropTarget(note.id);
    if (event.dataTransfer) {
      event.dataTransfer.dropEffect = "move";
    }
  });
  card.addEventListener("drop", async (event) => {
    event.preventDefault();
    if (!draggingNoteId || draggingNoteId === note.id) {
      resetDragState();
      return;
    }
    await updateState("sticky.move", { id: draggingNoteId, toIndex: index });
    resetDragState({ renderAfter: true });
  });
  card.addEventListener("dragend", () => resetDragState({ renderAfter: true }));

  const titleRow = element("div", { className: "sticky-note-title-row" });
  titleRow.append(
    element("h2", { className: "sticky-note-title" }, displayTitle(note)),
    renderExternalDragButton(note),
    renderIconButton("✓", "Archive note", async (event) => {
      event.stopPropagation();
      await archiveNote(note);
    }, "sticky-archive-button")
  );

  card.append(titleRow);
  const preview = cardPreview(note);
  if (preview) {
    card.append(element("p", { className: "sticky-note-body" }, preview));
  }
  card.append(element("time", { className: "sticky-note-time" }, formatTime(note.updatedAt)));
  return card;
}

function renderEditor(note) {
  draft ??= {
    id: note.id,
    title: note.title ?? "",
    body: note.body ?? "",
    color: note.color ?? "yellow",
  };

  const card = element("article", { className: `sticky-note sticky-editor sticky-note-${draft.color}` });
  card.addEventListener("contextmenu", (event) => {
    event.preventDefault();
    showContextMenu(note, event.clientX, event.clientY);
  });

  const toolbar = element("div", { className: "sticky-editor-toolbar" });
  toolbar.append(
    renderColorSwatches({
      selectedColor: draft.color,
      onSelect: (color) => void changeDraftColor(color),
    }),
    element("div", { className: "sticky-header-spacer" }),
    renderIconButton("✓", "Archive note", () => void archiveNote(note), "sticky-archive-button"),
    renderIconButton("⌫", "Delete note", () => void deleteNote(note), "sticky-delete-button"),
    renderIconButton("↵", "Done", () => void finishEditing(), "sticky-done-button")
  );

  const titleInput = element("input", {
    className: "sticky-title-input",
    type: "text",
    placeholder: "Title",
    value: draft.title,
  });
  titleInput.addEventListener("input", () => {
    draft.title = titleInput.value;
  });
  titleInput.addEventListener("keydown", handleEditorKeyDown);

  const bodyInput = element("textarea", {
    className: "sticky-body-input",
    placeholder: "Body",
  });
  bodyInput.value = draft.body;
  bodyInput.addEventListener("input", () => {
    draft.body = bodyInput.value;
  });
  bodyInput.addEventListener("keydown", handleEditorKeyDown);

  card.append(toolbar, titleInput, bodyInput);
  queueMicrotask(() => {
    if (document.activeElement !== titleInput && document.activeElement !== bodyInput) {
      titleInput.focus();
    }
  });
  return card;
}

function renderExternalDragButton(note) {
  const button = renderIconButton("↗", "Drag body to another app", async (event) => {
    event.stopPropagation();
  }, "sticky-external-drag-button");
  button.draggable = false;
  button.addEventListener("pointerdown", (event) => {
    event.stopPropagation();
    event.preventDefault();
    void send("sticky.startExternalDrag", { id: note.id, text: externalText(note) });
  });
  return button;
}

function renderTrashDropZone() {
  const zone = element("div", { className: `sticky-trash${draggingNoteId ? " is-visible" : ""}${trashTargeted ? " is-targeted" : ""}` });
  zone.append(element("span", { className: "sticky-trash-icon" }, "⌫"), element("span", {}, "Drop to archive"));
  zone.addEventListener("dragover", (event) => {
    if (!draggingNoteId) {
      return;
    }

    event.preventDefault();
    trashTargeted = true;
    zone.classList.add("is-targeted");
    if (event.dataTransfer) {
      event.dataTransfer.dropEffect = "move";
    }
  });
  zone.addEventListener("dragleave", () => {
    trashTargeted = false;
    zone.classList.remove("is-targeted");
  });
  zone.addEventListener("drop", async (event) => {
    event.preventDefault();
    event.stopPropagation();
    if (!draggingNoteId) {
      resetDragState();
      return;
    }

    const droppedNoteId = draggingNoteId;
    await updateState("sticky.archiveDropped", { id: droppedNoteId });
    toast = "archived";
    resetDragState({ renderAfter: true });
  });
  return zone;
}

function renderUndoToast() {
  const message = toast === "deleted" ? "Note deleted" : "Note archived";
  const wrapper = element("div", { className: "sticky-toast" });
  wrapper.append(
    element("span", {}, message),
    renderTextButton("Undo", async () => {
      await updateState("sticky.undo");
      toast = null;
      render();
    }),
    renderTextButton("Don't show", async () => {
      stickyState = await send("sticky.setUndoToastVisible", { visible: false });
      toast = null;
      render();
    })
  );
  return wrapper;
}

function renderContextMenu() {
  const note = stickyState.notes.find((candidate) => candidate.id === menu.noteId);
  if (!note) {
    menu = null;
    return document.createDocumentFragment();
  }

  const wrapper = element("div", {
    className: "sticky-menu",
    style: `left:${menu.x}px;top:${menu.y}px;`,
  });
  wrapper.append(
    renderMenuButton("Edit", () => {
      menu = null;
      void beginEditing(note);
    }),
    element("div", { className: "sticky-menu-label" }, "Color")
  );

  const colors = element("div", { className: "sticky-menu-colors" });
  for (const color of COLORS) {
    const swatch = renderSwatch(color.id, note.color === color.id, color.label);
    swatch.addEventListener("click", async () => {
      menu = null;
      await finishEditing();
      await updateState("sticky.update", {
        id: note.id,
        title: note.title ?? "",
        body: note.body ?? "",
        color: color.id,
      });
      render();
    });
    colors.append(swatch);
  }
  wrapper.append(colors);
  wrapper.append(
    renderMenuButton("Archive", () => {
      menu = null;
      void archiveNote(note);
    }),
    renderMenuButton("Delete", () => {
      menu = null;
      void deleteNote(note);
    }, "danger")
  );
  return wrapper;
}

function renderColorSwatches({ selectedColor, onSelect, onDoubleClick }) {
  const wrapper = element("div", { className: "sticky-swatches" });
  for (const color of COLORS) {
    const swatch = renderSwatch(color.id, selectedColor === color.id, color.label);
    swatch.addEventListener("click", (event) => {
      event.stopPropagation();
      onSelect(color.id);
    });
    if (onDoubleClick) {
      swatch.addEventListener("dblclick", (event) => {
        event.stopPropagation();
        onDoubleClick(color.id);
      });
    }
    wrapper.append(swatch);
  }
  return wrapper;
}

function renderSwatch(color, selected, label) {
  return element("button", {
    className: `sticky-swatch sticky-note-${color}${selected ? " is-selected" : ""}`,
    type: "button",
    title: label,
    ariaLabel: label,
  });
}

function renderIconButton(text, label, onClick, className = "") {
  const button = element("button", {
    className: `sticky-icon-button ${className}`.trim(),
    type: "button",
    ariaLabel: label,
    title: label,
  }, text);
  button.addEventListener("click", onClick);
  return button;
}

function renderTextButton(text, onClick) {
  const button = element("button", { className: "sticky-text-button", type: "button" }, text);
  button.addEventListener("click", onClick);
  return button;
}

function renderMenuButton(text, onClick, tone = "") {
  const button = element("button", {
    className: `sticky-menu-button${tone ? ` is-${tone}` : ""}`,
    type: "button",
  }, text);
  button.addEventListener("click", onClick);
  return button;
}

async function createNote(color) {
  await finishEditing();
  const result = await updateState("sticky.create", { color });
  const note = result?.note;
  if (note?.id) {
    pendingNewNoteIds.add(note.id);
    selectedNoteId = note.id;
    draft = {
      id: note.id,
      title: note.title ?? "",
      body: note.body ?? "",
      color: note.color ?? color,
    };
  }
  render();
}

async function beginEditing(note) {
  if (selectedNoteId && selectedNoteId !== note.id) {
    await finishEditing();
    note = stickyState.notes.find((candidate) => candidate.id === note.id) ?? note;
  }

  selectedNoteId = note.id;
  draft = {
    id: note.id,
    title: note.title ?? "",
    body: note.body ?? "",
    color: note.color ?? "yellow",
  };
  menu = null;
  render();
}

async function finishEditing() {
  if (!selectedNoteId || !draft) {
    return true;
  }

  const isBlank = !draft.title.trim() && !draft.body.trim();
  const isPendingNew = pendingNewNoteIds.has(selectedNoteId);
  const id = selectedNoteId;

  if (isPendingNew && isBlank) {
    await updateState("sticky.discard", { id });
    pendingNewNoteIds.delete(id);
  } else {
    await updateState("sticky.update", {
      id,
      title: draft.title,
      body: draft.body,
      color: draft.color,
    });
    pendingNewNoteIds.delete(id);
  }

  selectedNoteId = null;
  draft = null;
  render();
  return !(isPendingNew && isBlank);
}

async function commitDraftBeforeAction(note) {
  if (!selectedNoteId) {
    return true;
  }

  if (selectedNoteId !== note.id) {
    return finishEditing();
  }

  const isBlank = draft && !draft.title.trim() && !draft.body.trim();
  if (pendingNewNoteIds.has(note.id) && isBlank) {
    await finishEditing();
    return false;
  }

  await updateState("sticky.update", {
    id: note.id,
    title: draft?.title ?? note.title ?? "",
    body: draft?.body ?? note.body ?? "",
    color: draft?.color ?? note.color ?? "yellow",
  });
  return true;
}

async function changeDraftColor(color) {
  if (!selectedNoteId || !draft) {
    return;
  }

  draft.color = color;
  await updateState("sticky.update", {
    id: selectedNoteId,
    title: draft.title,
    body: draft.body,
    color: draft.color,
  });
  render();
}

async function archiveNote(note) {
  const committed = await commitDraftBeforeAction(note);
  if (!committed) {
    return;
  }

  await updateState("sticky.archive", { id: note.id });
  selectedNoteId = null;
  draft = null;
  pendingNewNoteIds.delete(note.id);
  toast = "archived";
  render();
}

async function deleteNote(note) {
  const committed = await commitDraftBeforeAction(note);
  if (!committed) {
    return;
  }

  await updateState("sticky.delete", { id: note.id });
  selectedNoteId = null;
  draft = null;
  pendingNewNoteIds.delete(note.id);
  toast = "deleted";
  render();
}

function handleEditorKeyDown(event) {
  if (event.ctrlKey && event.key === "Enter") {
    event.preventDefault();
    void finishEditing();
  }
}

function resetDragState({ renderAfter = false } = {}) {
  clearDropTarget();
  setTrashVisible(false);
  draggingNoteId = null;
  trashTargeted = false;
  if (renderAfter) {
    render();
  }
}

function setDropTarget(noteId) {
  if (dropTargetNoteId === noteId) {
    return;
  }

  clearDropTarget();
  dropTargetNoteId = noteId;
  for (const card of containerEl?.querySelectorAll("[data-sticky-note-id]") ?? []) {
    if (card.dataset.stickyNoteId === noteId) {
      card.classList.add("is-drop-target");
      return;
    }
  }
}

function clearDropTarget() {
  dropTargetNoteId = null;
  for (const card of containerEl?.querySelectorAll(".sticky-note.is-drop-target") ?? []) {
    card.classList.remove("is-drop-target");
  }
  for (const card of containerEl?.querySelectorAll(".sticky-note.is-dragging") ?? []) {
    card.classList.remove("is-dragging");
  }
}

function setTrashVisible(visible) {
  const trash = containerEl?.querySelector(".sticky-trash");
  if (!trash) {
    return;
  }

  trash.classList.toggle("is-visible", visible);
  if (!visible) {
    trash.classList.remove("is-targeted");
  }
}

function showContextMenu(note, x, y) {
  menu = {
    noteId: note.id,
    x: Math.min(x, Math.max(12, window.innerWidth - 158)),
    y: Math.min(y, Math.max(12, window.innerHeight - 190)),
  };
  render();
}

function closeMenuIfNoteGone() {
  if (!menu) {
    return;
  }

  if (!stickyState?.notes?.some((note) => note.id === menu.noteId)) {
    menu = null;
  }
}

function displayTitle(note) {
  const title = (note.title ?? "").trim();
  if (title) {
    return title;
  }

  const firstBodyLine = (note.body ?? "")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .find(Boolean);
  return firstBodyLine || "Untitled";
}

function cardPreview(note) {
  const title = (note.title ?? "").trim();
  const lines = (note.body ?? "")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean);

  if (title) {
    return lines.join(" ");
  }

  return lines.slice(1).join(" ");
}

function externalText(note) {
  const body = (note.body ?? "").trim();
  return body || (note.title ?? "").trim();
}

function formatTime(value) {
  if (!value) {
    return "";
  }

  const date = new Date(value);
  return date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
}

function ensureStylesheet() {
  if (document.querySelector("link[data-sticky-css]")) {
    return;
  }

  const link = document.createElement("link");
  link.rel = "stylesheet";
  link.href = "./providers/sticky/sticky.css";
  link.dataset.stickyCss = "true";
  document.head.append(link);
}

function element(tagName, props = {}, ...children) {
  const node = document.createElement(tagName);
  for (const [key, value] of Object.entries(props)) {
    if (value === undefined || value === null) {
      continue;
    }

    if (key === "className") {
      node.className = value;
    } else if (key === "ariaLabel") {
      node.setAttribute("aria-label", value);
    } else if (key === "ariaPressed") {
      node.setAttribute("aria-pressed", value);
    } else if (key === "tabIndex") {
      node.tabIndex = value;
    } else if (key === "style") {
      node.setAttribute("style", value);
    } else if (key in node) {
      node[key] = value;
    } else {
      node.setAttribute(key, value);
    }
  }

  for (const child of children) {
    node.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return node;
}
