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
        <button class="hp-calc-tool" type="button" data-input="BS" aria-label="${tx(context.state, "1文字削除", "Backspace")}">⌫</button>
        <button class="hp-calc-tool" type="button" data-clear-history aria-label="${tx(context.state, "履歴を消去", "Clear history")}" title="${tx(context.state, "履歴を消去", "Clear history")}">↺</button>
        <button class="hp-calc-tool" type="button" data-copy aria-label="${tx(context.state, "結果をコピー", "Copy")}" title="${tx(context.state, "結果をコピー", "Copy")}">⧉</button>
      </div>
      <div class="hp-calc-history" data-history aria-label="${tx(context.state, "計算履歴", "Calculation history")}"></div>
      <output class="hp-calc-expression" data-expression></output>
      <output class="hp-calc-output" data-display>0</output>
    </div>
    <div class="hp-calc-grid" data-grid></div>
  `;
  context.container.append(root);

  const display = root.querySelector("[data-display]");
  const grid = root.querySelector("[data-grid]");
  const copyButton = root.querySelector("[data-copy]");
  const clearHistoryButton = root.querySelector("[data-clear-history]");
  const expressionDisplay = root.querySelector("[data-expression]");
  const history = root.querySelector("[data-history]");
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
  clearHistoryButton.addEventListener("click", clearHistory);
  history.addEventListener("click", (event) => {
    const restoreTarget = /** @type {HTMLElement | null} */ (event.target.closest("[data-history-restore]"));
    if (restoreTarget) {
      restoreHistory(restoreTarget.dataset.historyId ?? "");
      return;
    }

    const valueTarget = /** @type {HTMLElement | null} */ (event.target.closest("[data-history-value]"));
    if (valueTarget) {
      useHistoryValue(valueTarget.dataset.historyId ?? "");
    }
  });
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
      display.textContent = tx(context.state, "エラー", "Error");
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
      display.textContent = tx(context.state, "エラー", "Error");
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

  async function clearHistory() {
    try {
      update(await context.request("calculator.clearHistory"));
    } catch (error) {
      display.textContent = tx(context.state, "エラー", "Error");
      root.classList.add("is-error");
      copyButton.disabled = true;
    }
  }

  /**
   * @param {string} id
   */
  async function useHistoryValue(id) {
    if (!id) {
      return;
    }

    try {
      update(await context.request("calculator.useHistoryValue", { id }));
    } catch (error) {
      display.textContent = tx(context.state, "エラー", "Error");
      root.classList.add("is-error");
      copyButton.disabled = true;
    }
  }

  /**
   * @param {string} id
   */
  async function restoreHistory(id) {
    if (!id) {
      return;
    }

    try {
      update(await context.request("calculator.restoreHistory", { id }));
    } catch (error) {
      display.textContent = tx(context.state, "エラー", "Error");
      root.classList.add("is-error");
      copyButton.disabled = true;
    }
  }

  /**
   * @param {{ display?: string, expressionDisplay?: string, hasError?: boolean, canCopy?: boolean, history?: Array<{ id?: string, expression?: string, result?: string }> }} state
   */
  function update(state) {
    display.textContent = state?.display ?? "0";
    expressionDisplay.textContent = state?.expressionDisplay ?? "";
    expressionDisplay.hidden = !state?.expressionDisplay;
    root.classList.toggle("is-error", Boolean(state?.hasError));
    copyButton.disabled = state?.canCopy === false;
    clearHistoryButton.disabled = !Array.isArray(state?.history) || state.history.length === 0;
    renderHistory(Array.isArray(state?.history) ? state.history : []);
  }

  /**
   * @param {Array<{ id?: string, expression?: string, result?: string }>} items
   */
  function renderHistory(items) {
    history.replaceChildren();
    for (const item of items) {
      const id = item.id ?? "";
      const row = document.createElement("div");
      row.className = "hp-calc-history-row";

      const valueButton = document.createElement("button");
      valueButton.className = "hp-calc-history-value";
      valueButton.type = "button";
      valueButton.dataset.historyValue = "true";
      valueButton.dataset.historyId = id;
      valueButton.title = tx(context.state, "結果を使用", "Use result");

      const expression = document.createElement("span");
      expression.className = "hp-calc-history-expression";
      expression.textContent = item.expression ?? "";

      const result = document.createElement("span");
      result.className = "hp-calc-history-result";
      result.textContent = item.result ?? "";

      valueButton.append(expression, result);

      const restoreButton = document.createElement("button");
      restoreButton.className = "hp-calc-history-restore";
      restoreButton.type = "button";
      restoreButton.dataset.historyRestore = "true";
      restoreButton.dataset.historyId = id;
      restoreButton.title = tx(context.state, "この計算を復元", "Restore state");
      restoreButton.setAttribute("aria-label", tx(context.state, "この計算を復元", "Restore calculation state"));
      restoreButton.textContent = "↩";

      row.append(valueButton, restoreButton);
      history.append(row);
    }

    history.scrollTop = history.scrollHeight;
  }
}

/**
 * @param {KeyboardEvent} event
 */
function tx(state, ja, en) {
  return state?.settings?.language === "en" ? en : ja;
}

function keyToInput(event) {
  if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "c") {
    return "COPY";
  }
  if (/^Numpad[0-9]$/.test(event.code)) {
    return event.code.at(-1) ?? null;
  }
  switch (event.code) {
    case "NumpadDecimal":
      return ".";
    case "NumpadAdd":
      return "+";
    case "NumpadSubtract":
      return "−";
    case "NumpadMultiply":
      return "×";
    case "NumpadDivide":
      return "÷";
    case "NumpadEnter":
    case "NumpadEqual":
      return "=";
    default:
      break;
  }
  if (/^[0-9]$/.test(event.key)) {
    return event.key;
  }
  switch (event.key) {
    case ".":
    case "+":
    case "%":
      return event.key;
    case ";":
      return "+";
    case ":":
      return "×";
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
