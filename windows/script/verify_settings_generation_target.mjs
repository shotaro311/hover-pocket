import assert from "node:assert/strict";
import { createGenerationTargetState } from "../ui/settings/generation-target-state.mjs";

const target = createGenerationTargetState();
assert.equal(target.value, null);
target.select("local.generated.focus");
assert.equal(target.value, "local.generated.focus");
target.clear();
assert.equal(target.value, null);
assert.throws(() => target.select(""), TypeError);

console.log("PASS settings generation target verify: select and explicit clear");
