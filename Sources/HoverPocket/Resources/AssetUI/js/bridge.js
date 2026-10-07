const listeners = new Map();
export function on(name, callback) {
  if (!listeners.has(name)) listeners.set(name, new Set());
  listeners.get(name).add(callback);
  return () => listeners.get(name)?.delete(callback);
}
window.assetEvent = (name, payload = {}) => {
  for (const callback of listeners.get(name) || []) callback(payload);
};
export function request(method, params = {}) {
  return window.webkit.messageHandlers.assets.postMessage({method, params});
}
