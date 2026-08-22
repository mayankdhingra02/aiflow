import assert from "node:assert/strict";
import test from "node:test";
import {
  buildRoutingMessage,
  createChannelAdmission,
  routingMessageIsBounded,
  routingDeliveryMayRetry
} from "./lib.js";

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

test("routing retries only when the content script was definitely not reached", () => {
  assert.equal(routingDeliveryMayRetry({ reached: false, value: null }), true);
  assert.equal(routingDeliveryMayRetry({ reached: true, value: { ok: false } }), false);
  assert.equal(routingDeliveryMayRetry({ reached: true, value: { ok: true } }), false);
});

test("routing is admitted while a normal handoff is busy and duplicates coalesce", () => {
  const admission = createChannelAdmission();
  assert.equal(admission.enter("handoff"), true);
  assert.equal(admission.enter("routing"), true);
  assert.equal(admission.enter("routing"), false);
  assert.equal(admission.isActive("handoff"), true);
  assert.equal(admission.isActive("routing"), true);
  admission.leave("routing");
  admission.leave("handoff");
  assert.equal(admission.isActive("routing"), false);
  assert.equal(admission.isActive("handoff"), false);
});

test("handoff is admitted while routing is busy and simultaneous polls remain independent", () => {
  const admission = createChannelAdmission();
  assert.equal(admission.enter("routing"), true);
  assert.equal(admission.enter("handoff"), true);
  assert.equal(admission.isActive("routing"), true);
  assert.equal(admission.isActive("handoff"), true);
  admission.leave("handoff");
  assert.equal(admission.enter("handoff"), true);
  admission.leave("handoff");
  admission.leave("routing");
});
