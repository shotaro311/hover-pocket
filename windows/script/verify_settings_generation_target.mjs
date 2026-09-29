import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createGenerationTargetState } from "../ui/settings/generation-target-state.mjs";

const target = createGenerationTargetState();
assert.equal(target.value, null);
target.select("local.generated.focus");
assert.equal(target.value, "local.generated.focus");
target.clear();
assert.equal(target.value, null);
assert.throws(() => target.select(""), TypeError);

const settingsHtml = readFileSync(
  new URL("../ui/settings/index.html", import.meta.url),
  "utf8",
);
assert.match(
  settingsHtml,
  /<button\b[^>]*\bdata-codex-sandbox-setup\b[^>]*\bdisabled\b[^>]*>/,
  "Codex sandbox setup must be disabled before the first state readback",
);

console.log("PASS settings generation target verify: select, explicit clear, and fail-closed initial setup UI");
