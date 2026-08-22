/**
 * Serializes all compound review-state changes. chrome.storage.local has no compare-and-swap:
 * concurrent read-modify-write operations on a shared object otherwise lose unrelated runs.
 */
export function createReviewStateRepository(storage, { now = () => Date.now() } = {}) {
  let tail = Promise.resolve();
  const maximumLifecycleEvents = 32;

  const safeReasons = new Set([
    "observer_timeout",
    "tab_query_failed",
    "target_tab_not_found",
    "observer_not_armed",
    "send_message_failed",
    "invalid_review",
    "conversation_mismatch",
    "review_conflict",
    "invalid_run_id",
    "handoff_not_delivered",
    "review_store_error",
    "server_rejection"
  ]);

  const boundedReason = (reason) => safeReasons.has(reason) ? reason : "server_rejection";

  const appendLifecycle = (state, runId, event, options = {}) => {
    const previous = state.reviewObservationDiagnostics[runId] || {};
    const entry = { event, at: now() };
    if (options.reason) entry.reason = boundedReason(options.reason);
    const combinedEvents = [...(Array.isArray(previous.events) ? previous.events : []), entry];
    const events = combinedEvents.length <= maximumLifecycleEvents
      ? combinedEvents
      : combinedEvents[0]?.event === "correlation_created"
        ? [combinedEvents[0], ...combinedEvents.slice(-(maximumLifecycleEvents - 1))]
        : combinedEvents.slice(-maximumLifecycleEvents);
    const diagnostic = {
      status: options.terminalStatus || "active",
      latestEvent: event,
      updatedAt: entry.at,
      events
    };
    if (options.reason) diagnostic.lastFailureReason = entry.reason;
    if (options.terminalStatus) diagnostic.terminalReason = entry.reason || event;
    state.reviewObservationDiagnostics[runId] = diagnostic;
    return diagnostic;
  };

  const mutate = (change) => {
    const operation = tail.then(async () => {
      const stored = await storage.get([
        "reviewCorrelations",
        "pendingReviews",
        "reviewObservationDiagnostics"
      ]);
      const state = {
        reviewCorrelations: { ...(stored.reviewCorrelations || {}) },
        pendingReviews: { ...(stored.pendingReviews || {}) },
        reviewObservationDiagnostics: { ...(stored.reviewObservationDiagnostics || {}) }
      };
      const result = await change(state);
      await storage.set(state);
      return result;
    });
    // Keep the queue usable after an individual storage failure.
    tail = operation.catch(() => {});
    return operation;
  };

  const read = async () => {
    await tail;
    const stored = await storage.get([
      "reviewCorrelations",
      "pendingReviews",
      "reviewObservationDiagnostics"
    ]);
    return {
      reviewCorrelations: { ...(stored.reviewCorrelations || {}) },
      pendingReviews: { ...(stored.pendingReviews || {}) },
      reviewObservationDiagnostics: { ...(stored.reviewObservationDiagnostics || {}) }
    };
  };

  return {
    async remember(handoff) {
      return mutate((state) => {
        const previous = state.reviewCorrelations[handoff.runId] || {};
        const correlation = {
          ...previous,
          conversationId: handoff.sourceChat.conversationId,
          sentinel: `[Aiflow result ${handoff.runId}]`,
          // A duplicate handoff may arrive after delivered_ack. Never regress that fact.
          deliveryAcknowledged: previous.deliveryAcknowledged === true,
          reviewAcknowledged: false
        };
        state.reviewCorrelations[handoff.runId] = correlation;
        appendLifecycle(state, handoff.runId, "correlation_created");
        return correlation;
      });
    },

    async markDeliveryAcknowledged(runId) {
      return mutate((state) => {
        const correlation = state.reviewCorrelations[runId];
        if (!correlation) return false;
        correlation.deliveryAcknowledged = true;
        appendLifecycle(state, runId, "delivery_acknowledged");
        return true;
      });
    },

    async acknowledgeReview(runId) {
      return mutate((state) => {
        // A review acknowledgement is correlated to an actual locally persisted submission.
        // A generic same-run server event must not clean up an observation-only correlation.
        if (!state.pendingReviews[runId]) return false;
        appendLifecycle(state, runId, "review_acknowledged", {
          terminalStatus: "acknowledged"
        });
        delete state.reviewCorrelations[runId];
        delete state.pendingReviews[runId];
        return true;
      });
    },

    async rejectReview(runId, reason) {
      return mutate((state) => {
        // Server error frames do not identify their originating command. Pending review
        // evidence is therefore required before treating one as a terminal review rejection.
        if (!state.pendingReviews[runId]) return false;
        const exactReason = boundedReason(reason);
        appendLifecycle(state, runId, exactReason, {
          reason: exactReason,
          terminalStatus: "rejected"
        });
        delete state.reviewCorrelations[runId];
        delete state.pendingReviews[runId];
        return true;
      });
    },

    async captureReview(review) {
      return mutate((state) => {
        const correlation = state.reviewCorrelations[review.runId];
        if (!correlation ||
            correlation.conversationId !== review.conversationId ||
            correlation.reviewAcknowledged) {
          return false;
        }
        state.pendingReviews[review.runId] = review;
        appendLifecycle(state, review.runId, "assistant_captured");
        appendLifecycle(state, review.runId, "review_persisted_locally");
        return true;
      });
    },

    async markObserverArmed(runId) {
      return mutate((state) => {
        if (!state.reviewCorrelations[runId]) return false;
        appendLifecycle(state, runId, "observer_armed");
        return true;
      });
    },

    async recordObservationFailure(runId, reason) {
      return mutate((state) => {
        if (!state.reviewCorrelations[runId]) return false;
        const exactReason = boundedReason(reason);
        const event = exactReason === "observer_timeout"
          ? "observer_timeout"
          : "content_script_unavailable";
        appendLifecycle(state, runId, event, { reason: exactReason });
        return true;
      });
    },

    async markReviewSubmitted(runId) {
      return mutate((state) => {
        if (!state.pendingReviews[runId]) return false;
        const diagnostic = state.reviewObservationDiagnostics[runId];
        if (diagnostic?.events?.some(entry => entry.event === "review_submitted")) return true;
        appendLifecycle(state, runId, "review_submitted");
        return true;
      });
    },

    async recordServerRejection(runId, reason) {
      return mutate((state) => {
        if (!state.pendingReviews[runId]) return false;
        appendLifecycle(state, runId, "server_rejection", {
          reason: boundedReason(reason)
        });
        return true;
      });
    },

    async unresolved() {
      const state = await read();
      return Object.entries(state.reviewCorrelations)
        .filter(([, correlation]) => !correlation.reviewAcknowledged);
    },

    async pending() {
      return Object.values((await read()).pendingReviews);
    },

    async correlation(runId) {
      return (await read()).reviewCorrelations[runId];
    },

    async diagnostic(runId) {
      return (await read()).reviewObservationDiagnostics[runId];
    }
  };
}

/** Reconnect-safe: a failed observation request never changes the durable correlation. */
export async function rearmUnresolvedReviews(repository, observe) {
  const unresolved = await repository.unresolved();
  return Promise.allSettled(unresolved.map(([runId, correlation]) => observe(runId, correlation)));
}
