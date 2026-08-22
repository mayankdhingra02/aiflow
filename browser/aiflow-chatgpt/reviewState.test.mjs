import assert from "node:assert/strict";
import test from "node:test";
import { createReviewStateRepository, rearmUnresolvedReviews } from "./reviewState.js";

function storageWithInterleaving() {
  const values = {};
  return {
    values,
    async get(keys) {
      await Promise.resolve();
      return Object.fromEntries(keys.map(key => [key, values[key]]));
    },
    async set(next) {
      await Promise.resolve();
      Object.assign(values, structuredClone(next));
    }
  };
}

function handoff(runId) {
  return { runId, sourceChat: { conversationId: `conversation-${runId}` } };
}

function lifecycle(storage, runId) {
  return storage.values.reviewObservationDiagnostics[runId].events.map(entry => entry.event);
}

test("the former unguarded whole-object writes deterministically lose a newly remembered run", async () => {
  const storage = storageWithInterleaving();
  storage.values.reviewCorrelations = {
    "run-a": { conversationId: "conversation-run-a", deliveryAcknowledged: false }
  };

  // These are the old independent read-modify-write paths: both reads see only run-a,
  // B remembers EFB, then A's delayed delivered_ack overwrites B's newer object.
  const snapshotA = await storage.get(["reviewCorrelations"]);
  const snapshotB = await storage.get(["reviewCorrelations"]);
  const fromB = { ...snapshotB.reviewCorrelations, EFB: { conversationId: "conversation-EFB" } };
  await storage.set({ reviewCorrelations: fromB });
  const fromA = { ...snapshotA.reviewCorrelations };
  fromA["run-a"].deliveryAcknowledged = true;
  await storage.set({ reviewCorrelations: fromA });

  assert.equal(storage.values.reviewCorrelations.EFB, undefined);
});

test("delivery acknowledgement retains its exact review correlation", async () => {
  const storage = storageWithInterleaving();
  const reviews = createReviewStateRepository(storage);

  await reviews.remember(handoff("run-a"));
  await reviews.markDeliveryAcknowledged("run-a");

  assert.deepEqual(storage.values.reviewCorrelations["run-a"], {
    conversationId: "conversation-run-a",
    sentinel: "[Aiflow result run-a]",
    deliveryAcknowledged: true,
    reviewAcknowledged: false
  });
  assert.deepEqual(lifecycle(storage, "run-a"), [
    "correlation_created",
    "delivery_acknowledged"
  ]);
});

test("a delivered correlation gets a durable created diagnostic", async () => {
  const storage = storageWithInterleaving();
  const reviews = createReviewStateRepository(storage, { now: () => 17 });

  await reviews.remember(handoff("run-a"));

  assert.deepEqual(storage.values.reviewObservationDiagnostics["run-a"], {
    status: "active",
    latestEvent: "correlation_created",
    updatedAt: 17,
    events: [{ event: "correlation_created", at: 17 }]
  });
});

test("interleaved acknowledgement and correlation creation cannot lose either run", async () => {
  const storage = storageWithInterleaving();
  const reviews = createReviewStateRepository(storage);
  await reviews.remember(handoff("run-a"));

  await Promise.all([
    reviews.markDeliveryAcknowledged("run-a"),
    reviews.remember(handoff("run-b"))
  ]);

  assert.equal(storage.values.reviewCorrelations["run-a"].deliveryAcknowledged, true);
  assert.equal(storage.values.reviewCorrelations["run-b"].conversationId, "conversation-run-b");
});

test("review acknowledgement removes only the acknowledged run", async () => {
  const storage = storageWithInterleaving();
  const reviews = createReviewStateRepository(storage);
  await Promise.all([reviews.remember(handoff("run-a")), reviews.remember(handoff("run-b"))]);
  await reviews.captureReview({ runId: "run-a", conversationId: "conversation-run-a", assistantMessage: "A" });
  await reviews.captureReview({ runId: "run-b", conversationId: "conversation-run-b", assistantMessage: "B" });

  await reviews.acknowledgeReview("run-a");

  assert.equal(storage.values.reviewCorrelations["run-a"], undefined);
  assert.equal(storage.values.pendingReviews["run-a"], undefined);
  assert.equal(storage.values.reviewObservationDiagnostics["run-a"].status, "acknowledged");
  assert.equal(storage.values.reviewObservationDiagnostics["run-a"].latestEvent, "review_acknowledged");
  assert.ok(storage.values.reviewCorrelations["run-b"]);
  assert.ok(storage.values.pendingReviews["run-b"]);
  assert.equal(storage.values.reviewObservationDiagnostics["run-b"].status, "active");
});

test("terminal rejection removes only its exact run", async () => {
  const storage = storageWithInterleaving();
  const reviews = createReviewStateRepository(storage);
  await Promise.all([reviews.remember(handoff("run-a")), reviews.remember(handoff("run-b"))]);
  await reviews.captureReview({ runId: "run-a", conversationId: "conversation-run-a", assistantMessage: "A" });

  await reviews.rejectReview("run-a", "invalid_review");

  assert.equal(storage.values.reviewCorrelations["run-a"], undefined);
  assert.equal(storage.values.pendingReviews["run-a"], undefined);
  assert.equal(storage.values.reviewObservationDiagnostics["run-a"].terminalReason, "invalid_review");
  assert.ok(storage.values.reviewCorrelations["run-b"]);
  assert.equal(storage.values.reviewObservationDiagnostics["run-b"].status, "active");
});

test("a same-run generic error cannot remove a correlation before a review exists", async () => {
  const storage = storageWithInterleaving();
  const reviews = createReviewStateRepository(storage);
  await reviews.remember(handoff("run-a"));

  assert.equal(await reviews.rejectReview("run-a", "conversation_mismatch"), false);
  assert.ok(storage.values.reviewCorrelations["run-a"]);
  assert.deepEqual(lifecycle(storage, "run-a"), ["correlation_created"]);
});

test("review capture records assistant_captured, local persistence, and submission lifecycle", async () => {
  const storage = storageWithInterleaving();
  const reviews = createReviewStateRepository(storage);
  await reviews.remember(handoff("run-a"));

  await reviews.captureReview({
    runId: "run-a",
    conversationId: "conversation-run-a",
    assistantMessage: "bounded review"
  });
  await reviews.markReviewSubmitted("run-a");

  assert.deepEqual(lifecycle(storage, "run-a"), [
    "correlation_created",
    "assistant_captured",
    "review_persisted_locally",
    "review_submitted"
  ]);
});

for (const rejection of ["invalid_review", "conversation_mismatch"]) {
  test(`${rejection} leaves an exact terminal diagnostic`, async () => {
    const storage = storageWithInterleaving();
    const reviews = createReviewStateRepository(storage);
    await reviews.remember(handoff("run-a"));
    await reviews.captureReview({ runId: "run-a", conversationId: "conversation-run-a", assistantMessage: "A" });

    await reviews.rejectReview("run-a", rejection);

    assert.equal(storage.values.reviewCorrelations["run-a"], undefined);
    assert.equal(storage.values.pendingReviews["run-a"], undefined);
    assert.equal(storage.values.reviewObservationDiagnostics["run-a"].status, "rejected");
    assert.equal(storage.values.reviewObservationDiagnostics["run-a"].terminalReason, rejection);
    assert.equal(storage.values.reviewObservationDiagnostics["run-a"].latestEvent, rejection);
  });
}

test("unresolved correlations survive repository recreation and observer failures", async () => {
  const storage = storageWithInterleaving();
  await createReviewStateRepository(storage).remember(handoff("run-a"));

  const restartedWorker = createReviewStateRepository(storage, { now: () => 42 });
  await restartedWorker.recordObservationFailure("run-a", "observer_timeout");

  assert.deepEqual(await restartedWorker.unresolved(), [["run-a", storage.values.reviewCorrelations["run-a"]]]);
  assert.equal(storage.values.reviewObservationDiagnostics["run-a"].status, "active");
  assert.equal(storage.values.reviewObservationDiagnostics["run-a"].latestEvent, "observer_timeout");
  assert.equal(storage.values.reviewObservationDiagnostics["run-a"].lastFailureReason, "observer_timeout");
});

test("service-worker reconnect re-arms every unresolved correlation", async () => {
  const storage = storageWithInterleaving();
  const reviews = createReviewStateRepository(storage);
  await Promise.all([reviews.remember(handoff("run-a")), reviews.remember(handoff("run-b"))]);
  const rearmed = [];

  await rearmUnresolvedReviews(reviews, async (runId, correlation) => {
    rearmed.push([runId, correlation.conversationId]);
  });

  assert.deepEqual(rearmed.sort(), [
    ["run-a", "conversation-run-a"],
    ["run-b", "conversation-run-b"]
  ]);
});

test("a temporarily unavailable content script leaves the correlation durable for retry", async () => {
  const storage = storageWithInterleaving();
  const reviews = createReviewStateRepository(storage);
  await reviews.remember(handoff("run-a"));
  await reviews.recordObservationFailure("run-a", "send_message_failed");

  assert.equal((await reviews.correlation("run-a")).conversationId, "conversation-run-a");
  assert.deepEqual((await reviews.unresolved()).map(([runId]) => runId), ["run-a"]);
  assert.equal((await reviews.diagnostic("run-a")).latestEvent, "content_script_unavailable");
});

test("a failed re-arm attempt leaves the correlation available to a later retry", async () => {
  const storage = storageWithInterleaving();
  const reviews = createReviewStateRepository(storage);
  await reviews.remember(handoff("run-a"));

  const first = await rearmUnresolvedReviews(reviews, async () => {
    throw new Error("content_script_unavailable");
  });
  const retried = [];
  await rearmUnresolvedReviews(reviews, async (runId) => retried.push(runId));

  assert.equal(first[0].status, "rejected");
  assert.deepEqual(retried, ["run-a"]);
});

test("two-run interleavings cannot erase either run diagnostic", async () => {
  const storage = storageWithInterleaving();
  const reviews = createReviewStateRepository(storage);
  await Promise.all([reviews.remember(handoff("run-a")), reviews.remember(handoff("run-b"))]);

  await Promise.all([
    reviews.markDeliveryAcknowledged("run-a"),
    reviews.recordObservationFailure("run-b", "observer_timeout"),
    reviews.markObserverArmed("run-a")
  ]);

  assert.deepEqual(lifecycle(storage, "run-a"), [
    "correlation_created",
    "delivery_acknowledged",
    "observer_armed"
  ]);
  assert.deepEqual(lifecycle(storage, "run-b"), [
    "correlation_created",
    "observer_timeout"
  ]);
});

test("bounded retry history always retains the correlation creation event", async () => {
  const storage = storageWithInterleaving();
  const reviews = createReviewStateRepository(storage);
  await reviews.remember(handoff("run-a"));

  for (let attempt = 0; attempt < 40; attempt++) {
    await reviews.recordObservationFailure("run-a", "send_message_failed");
  }

  assert.equal(lifecycle(storage, "run-a").length, 32);
  assert.equal(lifecycle(storage, "run-a")[0], "correlation_created");
  assert.equal(lifecycle(storage, "run-a").at(-1), "content_script_unavailable");
});

test("terminal cleanup can never leave neither active state nor diagnostic", async () => {
  for (const terminal of ["acknowledged", "invalid_review", "conversation_mismatch", "review_conflict"]) {
    const storage = storageWithInterleaving();
    const reviews = createReviewStateRepository(storage);
    await reviews.remember(handoff("run-a"));
    await reviews.captureReview({ runId: "run-a", conversationId: "conversation-run-a", assistantMessage: "A" });

    if (terminal === "acknowledged") await reviews.acknowledgeReview("run-a");
    else await reviews.rejectReview("run-a", terminal);

    const hasActiveState = Boolean(
      storage.values.reviewCorrelations["run-a"] || storage.values.pendingReviews["run-a"]
    );
    const hasDiagnostic = Boolean(storage.values.reviewObservationDiagnostics["run-a"]);
    assert.equal(hasActiveState, false, terminal);
    assert.equal(hasDiagnostic, true, terminal);
  }
});

test("lifecycle diagnostics contain no review text, token, or arbitrary rejection detail", async () => {
  const storage = storageWithInterleaving();
  const reviews = createReviewStateRepository(storage);
  await reviews.remember(handoff("run-a"));
  await reviews.captureReview({
    runId: "run-a",
    conversationId: "conversation-run-a",
    assistantMessage: "SECRET_REVIEW_TEXT"
  });

  await reviews.rejectReview("run-a", "/Users/example/private-token");

  const diagnostic = JSON.stringify(storage.values.reviewObservationDiagnostics["run-a"]);
  assert.equal(diagnostic.includes("SECRET_REVIEW_TEXT"), false);
  assert.equal(diagnostic.includes("/Users/example/private-token"), false);
  assert.equal(storage.values.reviewObservationDiagnostics["run-a"].terminalReason, "server_rejection");
});
