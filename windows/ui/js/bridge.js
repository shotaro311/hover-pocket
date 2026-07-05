/** @typedef {{ id: string, method: string, params?: unknown }} BridgeRequest */
/** @typedef {{ id?: string, result?: unknown, error?: { code: string, message: string } }} BridgeResponse */
/** @typedef {{ event: string, payload?: unknown }} BridgeEvent */

let nextId = 1;
const pending = new Map();
const listeners = new Map();

/**
 * Sends a request to the C# bridge.
 * @param {string} method
 * @param {unknown=} params
 * @returns {Promise<unknown>}
 */
export function request(method, params = undefined) {
  const id = String(nextId++);
  /** @type {BridgeRequest} */
  const message = { id, method };
  if (params !== undefined) {
    message.params = params;
  }

  const promise = new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject });
  });

  if (!window.chrome?.webview) {
    pending.delete(id);
    return Promise.reject(new Error("WebView2 bridge is unavailable."));
  }

  window.chrome.webview.postMessage(JSON.stringify(message));
  return promise;
}

/**
 * Subscribes to a C# event.
 * @param {string} eventName
 * @param {(payload: unknown) => void} handler
 */
export function on(eventName, handler) {
  const handlers = listeners.get(eventName) ?? new Set();
  handlers.add(handler);
  listeners.set(eventName, handlers);
}

if (window.chrome?.webview) {
  window.chrome.webview.addEventListener("message", (event) => {
    handleBridgeMessage(event.data);
  });
}

/**
 * @param {BridgeResponse | BridgeEvent | string} raw
 */
function handleBridgeMessage(raw) {
  const message = typeof raw === "string" ? JSON.parse(raw) : raw;

  if ("id" in message && message.id) {
    const completion = pending.get(message.id);
    if (!completion) {
      return;
    }

    pending.delete(message.id);
    if (message.error) {
      completion.reject(new Error(message.error.message));
      return;
    }

    completion.resolve(message.result);
    return;
  }

  if ("event" in message && message.event) {
    const handlers = listeners.get(message.event);
    if (!handlers) {
      return;
    }

    for (const handler of handlers) {
      handler(message.payload);
    }
  }
}
