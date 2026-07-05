const styleHref = "./providers/calculator/calculator.css";

/**
 * @param {{ container: Element, request: (method: string, params?: unknown) => Promise<any> }} context
 */
export function renderCalculatorProvider(context) {
  ensureStyle(styleHref);
  const root = document.createElement("section");
  root.className = "hp-calc";
  root.tabIndex = 0;
  root.innerHTML = `
    <div class="hp-calc-display">
      <div class="hp-calc-actions">
        <button class="hp-calc-tool" type="button" data-input="BS" aria-label="Backspace">⌫</button>
        <button class="hp-calc-tool" type="button" data-copy aria-label="Copy">⧉</button>
      </div>
      <output class="hp-calc-output" data-display>0</output>
    </div>
    <div class="hp-calc-grid" data-grid></div>
  `;
  context.container.append(root);

  const display = root.querySelector("[data-display]");
  const grid = root.querySelector("[data-grid]");
  const copyButton = root.querySelector("[data-copy]");
  const keys = [
    ["AC", "utility"], ["+/-", "utility"], ["%", "utility"], ["÷", "op"],
    ["7", "num"], ["8", "num"], ["9", "num"], ["×", "op"],
    ["4", "num"], ["5", "num"], ["6", "num"], ["−", "op"],
    ["1", "num"], ["2", "num"], ["3", "num"], ["+", "op"],
    ["0", "num wide"], [".", "num"], ["=", "equals"],
  ];

  for (const [input, kind] of keys) {
    const button = document.createElement("button");
    button.className = `hp-calc-key ${kind.split(" ").map((name) => `is-${name}`).join(" ")}`;
    button.type = "button";
    button.textContent = input;
    button.dataset.input = input;
    button.setAttribute("aria-label", input);
    grid.append(button);
  }

  root.addEventListener("click", (event) => {
    const target = /** @type {HTMLElement | null} */ (event.target.closest("[data-input]"));
    if (!target) {
      return;
    }
    press(target.dataset.input ?? "");
  });

  copyButton.addEventListener("click", copy);
  root.addEventListener("keydown", (event) => {
    const input = keyToInput(event);
    if (!input) {
      return;
    }
    event.preventDefault();
    if (input === "COPY") {
      copy();
      return;
    }
    press(input);
  });

  requestAnimationFrame(() => root.focus());
  refresh();

  async function refresh() {
    try {
      update(await context.request("calculator.getState"));
    } catch (error) {
      display.textContent = "Error";
      root.classList.add("is-error");
      copyButton.disabled = true;
    }
  }

  /**
   * @param {string} input
   */
  async function press(input) {
    try {
      update(await context.request("calculator.press", { input }));
    } catch (error) {
      display.textContent = "Error";
      root.classList.add("is-error");
      copyButton.disabled = true;
    }
  }

  async function copy() {
    if (copyButton.disabled) {
      return;
    }

    try {
      const result = await context.request("calculator.copy");
      if (result?.copied) {
        copyButton.classList.add("is-copied");
        setTimeout(() => copyButton.classList.remove("is-copied"), 900);
      }
    } catch (error) {
      copyButton.classList.remove("is-copied");
    }
  }

  /**
   * @param {{ display?: string, hasError?: boolean, canCopy?: boolean }} state
   */
  function update(state) {
    display.textContent = state?.display ?? "0";
    root.classList.toggle("is-error", Boolean(state?.hasError));
    copyButton.disabled = state?.canCopy === false;
  }
}

/**
 * @param {KeyboardEvent} event
 */
function keyToInput(event) {
  if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "c") {
    return "COPY";
  }
  if (/^[0-9]$/.test(event.key)) {
    return event.key;
  }
  switch (event.key) {
    case ".":
    case "+":
    case "%":
      return event.key;
    case "-":
      return "−";
    case "*":
    case "x":
    case "X":
      return "×";
    case "/":
      return "÷";
    case "Enter":
    case "=":
      return "=";
    case "Escape":
      return "AC";
    case "Backspace":
      return "BS";
    default:
      return null;
  }
}

/**
 * @param {string} href
 */
function ensureStyle(href) {
  if (document.querySelector(`link[href="${href}"]`)) {
    return;
  }
  const link = document.createElement("link");
  link.rel = "stylesheet";
  link.href = href;
  document.head.append(link);
}
