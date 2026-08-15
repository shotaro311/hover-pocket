export function createGenerationTargetState() {
  let value = null;
  return Object.freeze({
    get value() {
      return value;
    },
    select(appId) {
      if (typeof appId !== "string" || appId.length === 0) {
        throw new TypeError("A non-empty Pocket App ID is required.");
      }
      value = appId;
    },
    clear() {
      value = null;
    },
  });
}
