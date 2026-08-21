import assert from "node:assert/strict";
import test from "node:test";
import { buildRoutingMessage, routingMessageIsBounded } from "./lib.js";

test("routing envelope carries an exact routing sentinel and bounded response guard", () => {
  const message = buildRoutingMessage({
    runId: "00000000-0000-0000-0000-000000000001",
    project: { name: "demo" }, prompt: "Fix it"
  });
  assert.match(message, /^\[Aiflow routing 00000000-0000-0000-0000-000000000001\]/);
  assert.equal(routingMessageIsBounded("# Codex Routing\n## Model\nsol\n## Reasoning\nhigh"), true);
  assert.equal(routingMessageIsBounded(""), false);
  assert.equal(routingMessageIsBounded("x".repeat(32 * 1024 + 1)), false);
});
