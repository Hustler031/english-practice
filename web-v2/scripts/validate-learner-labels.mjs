import assert from "node:assert/strict";
import { cleanLearnerName, confusionLabel } from "../lib/learner-label.ts";

assert.equal(confusionLabel("Phrasal Verbs", "Phrasal Verbs"), "English practice");
assert.equal(confusionLabel("Phrasal Verbs", "put aside"), "put aside");
assert.equal(confusionLabel("put aside", "lay aside"), "put aside vs lay aside");
assert.equal(cleanLearnerName("Vocabulary", "scrimmage"), "scrimmage");
console.log("Learner label resolver contracts PASS");
