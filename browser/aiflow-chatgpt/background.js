import {
  canonicalChatURL,
  buildHandoffMessage,
  buildReviewCommand,
  reviewMessageIsBounded,
  buildRoutingMessage,
  buildRoutingResponseCommand,
  routingMessageIsBounded,
  routingDeliveryMayRetry,
  createChannelAdmission
} from "./lib.js";
import { createReviewStateRepository, rearmUnresolvedReviews } from "./reviewState.js";

const WS_URL =
  "ws://127.0.0.1:47322";
const PROTOCOL_VERSION = 3;

const RETRY_MS = 4000;
const EMPTY_POLL_MS = 3000;
const HEARTBEAT_MS = 20000;

let socket = null;
let reconnectTimer = null;
let heartbeatTimer = null;
const channelAdmission = createChannelAdmission();
let authenticated = false;
let connecting = false;
let authenticationRejected = false;
const reviewState = createReviewStateRepository(chrome.storage.local);

chrome.action.onClicked.addListener(() => {
  chrome.runtime.openOptionsPage();
});

chrome.runtime.onInstalled.addListener(() => {
  connect();
});

chrome.runtime.onStartup.addListener(() => {
  connect();
});

chrome.runtime.onMessage.addListener(
  (message, sender, sendResponse) => {
    if (message?.type === "aiflow-token-updated") {
      reconnect();
      sendResponse({ ok: true });
      return;
    }

    if (message?.type === "aiflow-clear-blocked") {
      chrome.storage.local.remove([
        "blockedRunId",
        "blockedReason"
      ]).then(() => {
        requestNextSoon(100);
      });

      sendResponse({ ok: true });
    }
  }
);

async function getToken() {
  const {
    handoffToken = ""
  } = await chrome.storage.local.get(
    "handoffToken"
  );

  return handoffToken.trim();
}

function reconnect() {
  clearReconnect();
  stopHeartbeat();

  authenticated = false;
  authenticationRejected = false;
  channelAdmission.reset();

  const previousSocket = socket;
  socket = null;

  if (previousSocket) {
    try {
      previousSocket.close(
        1000,
        "client_reconnect"
      );
    } catch {
    }
  }

  connect();
}

async function connect() {
  if (connecting) {
    return;
  }

  if (
    socket &&
    (
      socket.readyState === WebSocket.CONNECTING ||
      socket.readyState === WebSocket.OPEN
    )
  ) {
    return;
  }

  connecting = true;
  clearReconnect();

  try {
    const token = await getToken();

    // Another caller may have established a socket while
    // chrome.storage was being read.
    if (
      socket &&
      (
        socket.readyState === WebSocket.CONNECTING ||
        socket.readyState === WebSocket.OPEN
      )
    ) {
      return;
    }

    if (!token) {
      console.info(
        "Aiflow handoff token is not configured."
      );
      return;
    }

    let ws;

    try {
      ws = new WebSocket(WS_URL);
    } catch (error) {
      console.warn(
        "Aiflow WebSocket creation failed:",
        error
      );

      scheduleReconnect();
      return;
    }

    socket = ws;

    ws.addEventListener("open", () => {
      if (socket !== ws) {
        return;
      }

      console.info(
        "Connected to Aiflow result transport."
      );
    });

    ws.addEventListener(
      "message",
      event => {
        handleServerMessage(
          event.data,
          token,
          ws
        ).catch(error => {
          console.error(
            "Aiflow message handling failed:",
            error
          );
        });
      }
    );

    ws.addEventListener(
      "close",
      event => {
        console.warn(
          "Aiflow WebSocket closed:",
          {
            code: event.code,
            reason:
              event.reason || "(none)",
            wasClean: event.wasClean
          }
        );

        // Ignore close events from sockets that reconnect()
        // intentionally replaced.
        if (socket !== ws) {
          return;
        }

        socket = null;
        authenticated = false;
        channelAdmission.reset();

        stopHeartbeat();
        scheduleReconnect();
      }
    );

    ws.addEventListener(
      "error",
      error => {
        console.warn(
          "Aiflow WebSocket error:",
          error
        );
      }
    );
  } finally {
    connecting = false;
  }
}

async function handleServerMessage(
  raw,
  token,
  ws
) {
  if (socket !== ws) return;

  let event;

  try {
    event = JSON.parse(raw);
  } catch {
    return;
  }

  switch (event.type) {
    case "hello":
      if (event.protocolVersion !== PROTOCOL_VERSION) {
        authenticated = false;
        authenticationRejected = true;
        channelAdmission.reset();
        stopHeartbeat();

        await chrome.storage.local.set({
          authError: "protocol_incompatible"
        });

        const incompatibleSocket = socket;
        socket = null;

        if (incompatibleSocket) {
          try {
            incompatibleSocket.close(
              1000,
              "protocol_incompatible"
            );
          } catch {
          }
        }

        console.error(
          "Aiflow transport protocol_incompatible:",
          event.protocolVersion
        );
        break;
      }

      send({
        type: "auth",
        token,
        protocolVersion: PROTOCOL_VERSION
      });
      break;

    case "ready":
      authenticated = true;
      authenticationRejected = false;

      await chrome.storage.local.remove(
        "authError"
      );

      startHeartbeat();
      await resumeReviewObservations();
      await submitPendingReviews();
      await resumeRoutingObservations();
      requestNextSoon(50);
      requestRoutingSoon(50);
      break;

    case "pong":
      break;

    case "empty":
      requestNextSoon(
        EMPTY_POLL_MS
      );
      break;

    case "handoff":
      await handleHandoff(
        event.handoff
      );
      break;

    case "delivered_ack":
      await removeDeliveryReceipt(
        event.runId
      );

      await markDeliveryAcknowledged(event.runId);

      // The review may have been captured before the server
      // durably recorded delivery. Retry pending evidence now
      // that delivery is guaranteed to exist server-side.
      await submitPendingReviews();

      requestNextSoon(100);
      break;

    case "review_ack":
      await markReviewAcknowledged(event.runId);
      break;

    case "routing":
      await handleRouting(event.routing);
      break;

    case "routing_delivered_ack":
      // The durable browser correlation was written before injection. This acknowledgement
      // adds no local state; it only confirms the server transitioned `delivering → delivered`.
      break;

    case "routing_empty":
      requestRoutingSoon(EMPTY_POLL_MS);
      break;

    case "routing_response_ack":
      await clearRoutingEvidence(event.runId);
      break;

    case "error":
      console.warn(
        "Aiflow transport error:",
        event.error,
        event.runId ?? ""
      );

      if (
        event.error ===
          "authentication_failed"
      ) {
        authenticated = false;
        authenticationRejected = true;
        processing = false;

        stopHeartbeat();

        await chrome.storage.local.set({
          authError:
            "authentication_failed"
        });

        /*
         * Detach before closing so this socket's close handler
         * cannot schedule another reconnect. Saving a new token
         * explicitly resets authenticationRejected via reconnect().
         */
        const rejectedSocket = socket;
        socket = null;

        if (rejectedSocket) {
          try {
            rejectedSocket.close(
              1000,
              "authentication_failed"
            );
          } catch {
          }
        }

        console.error(
          "Aiflow rejected the handoff token. " +
          "Open extension options and save the " +
          "current handoff token."
        );

        break;
      }

      if (
        event.error === "handoff_not_found"
      ) {
        requestNextSoon(100);
      }

      if (
        [
          "invalid_review",
          "review_conflict",
          "conversation_mismatch",
          "invalid_run_id"
        ].includes(event.error)
      ) {
        await discardReview(
          event.runId,
          event.error
        );
      } else if (event.runId) {
        // Non-terminal server failures retain pending evidence for reconnect retry, but they
        // still become durable lifecycle evidence when this run has a pending review.
        await reviewState.recordServerRejection(event.runId, event.error);
      }

      if (
        [
          "invalid_routing",
          "invalid_run_id",
          "routing_conflict",
          "routing_delivery_conflict",
          "routing_store_error",
          "conversation_mismatch",
          "routing_cancelled",
          "routing_not_found",
          "routing_manual_attention"
        ].includes(event.error)
      ) {
        await clearRoutingEvidence(event.runId);
      }
      break;

    default:
      break;
  }
}

async function handleHandoff(handoff) {
  if (
    !handoff ||
    !handoff.runId ||
    !handoff.sourceChat?.url
  ) {
    return;
  }

  if (!channelAdmission.enter("handoff")) {
    console.info("Aiflow coalesced duplicate handoff delivery:", handoff.runId);
    return;
  }

  try {
    const stored =
      await chrome.storage.local.get([
        "blockedRunId",
        "blockedReason",
        "deliveryReceipts"
      ]);

    const receipt =
      stored.deliveryReceipts?.[
        handoff.runId
      ];

    if (
      receipt ===
        handoff.sourceChat
          ?.conversationId
    ) {
      console.info(
        "Aiflow already confirmed this ChatGPT delivery locally:",
        handoff.runId
      );

      await rememberReviewCorrelation(handoff);

      send({
        type: "delivered",
        runId: handoff.runId
      });

      return;
    }

    if (
      stored.blockedRunId ===
        handoff.runId
    ) {
      console.warn(
        "Aiflow delivery is blocked:",
        stored.blockedReason
      );
      // Preserve the blocked evidence locally, but release only this connection's in-flight
      // slot so a newer pending handoff cannot be starved behind it.
      send({ type: "blocked", runId: handoff.runId });
      requestNextSoon(100);
      return;
    }

    const result =
      await deliverToChatGPT(
        handoff
      );

    if (result.ok) {
      await rememberReviewCorrelation(handoff);
      send({
        type: "delivered",
        runId: handoff.runId
      });

      return;
    }

    if (result.retryable) {
      console.warn(
        "Aiflow delivery will retry:",
        result.error
      );

      requestNextSoon(
        RETRY_MS
      );

      return;
    }

    await chrome.storage.local.set({
      blockedRunId:
        handoff.runId,
      blockedReason:
        result.error ||
        "ambiguous_delivery"
    });

    console.error(
      "Aiflow stopped automatic delivery for run",
      handoff.runId,
      result.error
    );
  } finally {
    channelAdmission.leave("handoff");
  }
}

async function deliverToChatGPT(
  handoff
) {
  const targetURL =
    canonicalChatURL(
      handoff.sourceChat.url
    );

  if (!targetURL) {
    return {
      ok: false,
      retryable: false,
      error: "invalid_chat_target"
    };
  }

  let tabs =
    await chrome.tabs.query({
      url: [
        "https://chatgpt.com/*"
      ]
    });

  let tab =
    tabs.find(candidate =>
      canonicalChatURL(
        candidate.url
      ) === targetURL
    );

  if (!tab) {
    tab =
      await chrome.tabs.create({
        url: targetURL,
        active: false
      });
  }

  if (!tab?.id) {
    return {
      ok: false,
      retryable: true,
      error: "target_tab_unavailable"
    };
  }

  const ready =
    await waitForTabReady(
      tab.id,
      targetURL
    );

  if (!ready) {
    return {
      ok: false,
      retryable: true,
      error: "target_tab_not_ready"
    };
  }

  const text =
    buildHandoffMessage(
      handoff
    );

  for (
    let attempt = 0;
    attempt < 12;
    attempt++
  ) {
    try {
      const response =
        await chrome.tabs.sendMessage(
          tab.id,
          {
            type:
              "aiflow-deliver-handoff",
            runId:
              handoff.runId,
            conversationId:
              handoff.sourceChat
                .conversationId,
            text
          }
        );

      if (response) {
        return response;
      }
    } catch {
    }

    await sleep(500);
  }

  return {
    ok: false,
    retryable: true,
    error:
      "content_script_unavailable"
  };
}

async function waitForTabReady(
  tabId,
  targetURL
) {
  for (
    let attempt = 0;
    attempt < 30;
    attempt++
  ) {
    try {
      const tab =
        await chrome.tabs.get(tabId);

      if (
        canonicalChatURL(
          tab.url
        ) === targetURL &&
        tab.status === "complete"
      ) {
        return true;
      }
    } catch {
      return false;
    }

    await sleep(500);
  }

  return false;
}

async function handleRouting(request) {
  if (!request?.runId) return;
  if (!channelAdmission.enter("routing")) {
    // The active operation for this exact server channel remains responsible for the
    // acknowledgement. Coalescing cannot strand it behind unrelated handoff work.
    console.info("Aiflow coalesced duplicate routing delivery:", request.runId);
    return;
  }
  try {
    if (!request.sourceChat?.url) {
      send({ type: "routing_failed", runId: request.runId });
      return;
    }
    const target = canonicalChatURL(request.sourceChat.url);
    if (!target) {
      send({ type: "routing_failed", runId: request.runId });
      return;
    }
    const tabs = await chrome.tabs.query({ url: ["https://chatgpt.com/*"] });
    let tab = tabs.find(candidate => canonicalChatURL(candidate.url) === target);
    if (!tab) tab = await chrome.tabs.create({ url: target, active: false });
    if (!tab?.id || !await waitForTabReady(tab.id, target)) {
      send({ type: "routing_failed", runId: request.runId });
      return;
    }
    // Persist correlation before delivery: ChatGPT can create and complete the assistant
    // response before the delivery request returns to this service worker.
    const { routingCorrelations = {} } = await chrome.storage.local.get("routingCorrelations");
    routingCorrelations[request.runId] = {
      conversationId: request.sourceChat.conversationId,
      sentinel: `[Aiflow routing ${request.runId}]`
    };
    await chrome.storage.local.set({ routingCorrelations });
    const response = await sendRoutingToContentScript(tab.id, {
      type: "aiflow-deliver-routing",
      runId: request.runId,
      conversationId: request.sourceChat.conversationId,
      sentinel: `[Aiflow routing ${request.runId}]`,
      text: buildRoutingMessage(request)
    });
    // Retry only transport failures that prove the content script never received the message.
    // Once it answered, its outcome is authoritative: retrying could duplicate the sentinel.
    if (routingDeliveryMayRetry(response) || !response.value?.ok) {
      delete routingCorrelations[request.runId];
      await chrome.storage.local.set({ routingCorrelations });
      send({ type: "routing_failed", runId: request.runId });
      return;
    }
    send({ type: "routing_delivered", runId: request.runId });
  } catch {
    send({ type: "routing_failed", runId: request.runId });
  } finally {
    channelAdmission.leave("routing");
    requestRoutingSoon(100);
  }
}

async function sendRoutingToContentScript(tabId, message) {
  for (let attempt = 0; attempt < 12; attempt++) {
    try {
      const value = await chrome.tabs.sendMessage(tabId, message);
      return { reached: true, value };
    } catch {
      // A reload can briefly remove the content script. No command reached it, so bounded retry
      // is safe; a returned response is never retried.
      await sleep(500);
    }
  }
  return { reached: false, value: null };
}

async function requestRoutingObservation(runId, correlation) {
  const tabs = await chrome.tabs.query({ url: ["https://chatgpt.com/*"] });
  const tab = tabs.find(candidate =>
    canonicalChatURL(candidate.url) === `https://chatgpt.com/c/${correlation.conversationId}`
  );
  if (!tab?.id) return;
  try {
    await chrome.tabs.sendMessage(tab.id, {
      type: "aiflow-observe-routing",
      runId,
      conversationId: correlation.conversationId,
      sentinel: correlation.sentinel
    });
  } catch {}
}

async function resumeRoutingObservations() {
  const { routingCorrelations = {}, pendingRoutingResponses = {}, pendingRoutingFailures = {} } =
    await chrome.storage.local.get(["routingCorrelations", "pendingRoutingResponses", "pendingRoutingFailures"]);
  await Promise.all(Object.entries(routingCorrelations).map(([runId, correlation]) =>
    requestRoutingObservation(runId, correlation)
  ));
  for (const response of Object.values(pendingRoutingResponses)) {
    send(buildRoutingResponseCommand(response));
  }
  for (const failure of Object.values(pendingRoutingFailures)) {
    send({ type: "routing_failed", runId: failure.runId });
  }
}

async function clearRoutingEvidence(runId, preservePendingFailure = false) {
  if (!runId) return;
  const { routingCorrelations = {}, pendingRoutingResponses = {}, pendingRoutingFailures = {}, deliveryReceipts = {} } =
    await chrome.storage.local.get(["routingCorrelations", "pendingRoutingResponses", "pendingRoutingFailures", "deliveryReceipts"]);
  const correlation = routingCorrelations[runId];
  delete routingCorrelations[runId];
  delete pendingRoutingResponses[runId];
  if (!preservePendingFailure) delete pendingRoutingFailures[runId];
  delete deliveryReceipts[runId];
  await chrome.storage.local.set({ routingCorrelations, pendingRoutingResponses, pendingRoutingFailures, deliveryReceipts });
  if (correlation?.conversationId) {
    const tabs = await chrome.tabs.query({ url: ["https://chatgpt.com/*"] });
    const tab = tabs.find(candidate => canonicalChatURL(candidate.url) === `https://chatgpt.com/c/${correlation.conversationId}`);
    if (tab?.id) {
      try { await chrome.tabs.sendMessage(tab.id, { type: "aiflow-cancel-routing-observation", runId }); } catch {}
    }
  }
}

function requestRoutingSoon(delay) {
  setTimeout(() => {
    if (authenticated && !channelAdmission.isActive("routing")) send({ type: "next_routing" });
  }, delay);
}

async function removeDeliveryReceipt(
  runId
) {
  if (!runId) return;

  const {
    deliveryReceipts = {}
  } = await chrome.storage.local.get(
    "deliveryReceipts"
  );

  if (!(runId in deliveryReceipts)) {
    return;
  }

  delete deliveryReceipts[runId];

  await chrome.storage.local.set({
    deliveryReceipts
  });
}

async function rememberReviewCorrelation(handoff) {
  const correlation = await reviewState.remember(handoff);
  await requestReviewObservation(handoff.runId, correlation);
}

async function markDeliveryAcknowledged(runId) {
  if (!runId) return;
  await reviewState.markDeliveryAcknowledged(runId);
}

async function markReviewAcknowledged(runId) {
  if (!runId) return;
  await reviewState.acknowledgeReview(runId);
}

async function discardReview(runId, reason) {
  if (!runId) return;
  const discarded = await reviewState.rejectReview(runId, reason);
  if (discarded) console.warn("Aiflow discarded terminal review evidence:", reason, runId);
}

async function resumeReviewObservations() {
  await rearmUnresolvedReviews(reviewState, requestReviewObservation);
}

async function requestReviewObservation(runId, correlation) {
  let tabs;
  try {
    tabs = await chrome.tabs.query({ url: ["https://chatgpt.com/*"] });
  } catch {
    await reviewState.recordObservationFailure(runId, "tab_query_failed");
    scheduleReviewObservationRetry(runId, correlation);
    return false;
  }
  const target = `https://chatgpt.com/c/${correlation.conversationId}`;
  const tab = tabs.find(candidate => canonicalChatURL(candidate.url) === target);
  if (!tab?.id) {
    await reviewState.recordObservationFailure(runId, "target_tab_not_found");
    scheduleReviewObservationRetry(runId, correlation);
    return false;
  }
  try {
    const response = await chrome.tabs.sendMessage(tab.id, {
      type: "aiflow-observe-review",
      runId,
      conversationId: correlation.conversationId,
      sentinel: correlation.sentinel
    });
    if (!response?.ok) {
      await reviewState.recordObservationFailure(runId, "observer_not_armed");
      scheduleReviewObservationRetry(runId, correlation);
      return false;
    }
    await reviewState.markObserverArmed(runId);
    return true;
  } catch {
    await reviewState.recordObservationFailure(runId, "send_message_failed");
    scheduleReviewObservationRetry(runId, correlation);
    return false;
  }
}

function scheduleReviewObservationRetry(runId, correlation) {
  setTimeout(async () => {
    if (!authenticated) return;
    const current = await reviewState.correlation(runId);
    if (current && current.conversationId === correlation.conversationId && !current.reviewAcknowledged) {
      await requestReviewObservation(runId, current);
    }
  }, RETRY_MS);
}

async function submitPendingReviews() {
  if (!authenticated) return;
  for (const review of await reviewState.pending()) await submitReview(review);
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message?.type !== "aiflow-review-captured") return;
  reviewState.correlation(message.runId).then(async (correlation) => {
    if (!correlation || correlation.conversationId !== message.conversationId || correlation.reviewAcknowledged) {
      sendResponse({ ok: false });
      return;
    }
    if (!reviewMessageIsBounded(message.assistantMessage)) {
      console.warn("Aiflow discarded invalid captured review:", message.runId);
      sendResponse({ ok: false });
      return;
    }
    const review = { runId: message.runId, conversationId: message.conversationId, assistantMessage: message.assistantMessage };
    const captured = await reviewState.captureReview(review);
    if (captured) await submitReview(review);
    sendResponse({ ok: captured });
  });
  return true;
});

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message?.type !== "aiflow-review-observation-failed") return;
  reviewState.recordObservationFailure(message.runId, message.reason || "observer_timeout").then(async (recorded) => {
    if (recorded) {
      const correlation = await reviewState.correlation(message.runId);
      if (correlation) scheduleReviewObservationRetry(message.runId, correlation);
    }
    sendResponse({ ok: recorded });
  });
  return true;
});

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message?.type !== "aiflow-routing-observation-failed") return;
  chrome.storage.local.get("pendingRoutingFailures").then(async ({ pendingRoutingFailures = {} }) => {
    await chrome.storage.local.set({
      pendingRoutingFailures: { ...pendingRoutingFailures, [message.runId]: { runId: message.runId } }
    });
    await clearRoutingEvidence(message.runId, true);
    send({ type: "routing_failed", runId: message.runId });
    sendResponse({ ok: true });
  });
  return true;
});

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message?.type !== "aiflow-routing-captured") return;
  chrome.storage.local.get("routingCorrelations").then(async ({ routingCorrelations = {} }) => {
    const correlation = routingCorrelations[message.runId];
    if (!correlation || correlation.conversationId !== message.conversationId ||
        !routingMessageIsBounded(message.assistantMessage)) {
      sendResponse({ ok: false });
      return;
    }
    const response = {
      runId: message.runId,
      conversationId: message.conversationId,
      assistantMessage: message.assistantMessage
    };
    const { pendingRoutingResponses = {} } =
      await chrome.storage.local.get("pendingRoutingResponses");
    await chrome.storage.local.set({
      pendingRoutingResponses: { ...pendingRoutingResponses, [message.runId]: response }
    });
    send(buildRoutingResponseCommand(response));
    sendResponse({ ok: true });
  });
  return true;
});

function send(message) {
  if (
    !socket ||
    socket.readyState !==
      WebSocket.OPEN
  ) {
    return false;
  }

  socket.send(
    JSON.stringify(message)
  );

  return true;
}

async function submitReview(review) {
  const submitted = send(buildReviewCommand(review));
  if (submitted) await reviewState.markReviewSubmitted(review.runId);
  return submitted;
}

function requestNextSoon(delay) {
  setTimeout(() => {
    if (
      authenticated &&
      !channelAdmission.isActive("handoff")
    ) {
      send({
        type: "next"
      });
    }
  }, delay);
}

function scheduleReconnect() {
  if (authenticationRejected) {
    return;
  }

  if (reconnectTimer) {
    return;
  }

  if (
    socket &&
    (
      socket.readyState === WebSocket.CONNECTING ||
      socket.readyState === WebSocket.OPEN
    )
  ) {
    return;
  }

  reconnectTimer =
    setTimeout(() => {
      reconnectTimer = null;
      connect();
    }, 2000);
}

function clearReconnect() {
  if (reconnectTimer) {
    clearTimeout(
      reconnectTimer
    );

    reconnectTimer = null;
  }
}

function startHeartbeat() {
  stopHeartbeat();

  heartbeatTimer =
    setInterval(() => {
      if (authenticated) {
        send({
          type: "ping"
        });
      }
    }, HEARTBEAT_MS);
}

function stopHeartbeat() {
  if (heartbeatTimer) {
    clearInterval(
      heartbeatTimer
    );

    heartbeatTimer = null;
  }
}

function sleep(ms) {
  return new Promise(resolve => {
    setTimeout(resolve, ms);
  });
}

connect();
