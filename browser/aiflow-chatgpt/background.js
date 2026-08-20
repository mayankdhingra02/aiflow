import {
  canonicalChatURL,
  buildHandoffMessage
} from "./lib.js";

const WS_URL =
  "ws://127.0.0.1:47322";

const RETRY_MS = 4000;
const EMPTY_POLL_MS = 3000;
const HEARTBEAT_MS = 20000;

let socket = null;
let reconnectTimer = null;
let heartbeatTimer = null;
let processing = false;
let authenticated = false;
let connecting = false;
let authenticationRejected = false;

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
  processing = false;

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
        processing = false;

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
      send({
        type: "auth",
        token
      });
      break;

    case "ready":
      authenticated = true;
      authenticationRejected = false;

      await chrome.storage.local.remove(
        "authError"
      );

      startHeartbeat();
      requestNextSoon(50);
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

      requestNextSoon(100);
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
      break;

    default:
      break;
  }
}

async function handleHandoff(handoff) {
  if (processing) return;

  if (
    !handoff ||
    !handoff.runId ||
    !handoff.sourceChat?.url
  ) {
    return;
  }

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

    return;
  }

  processing = true;

  try {
    const result =
      await deliverToChatGPT(
        handoff
      );

    if (result.ok) {
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
    processing = false;
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

function requestNextSoon(delay) {
  setTimeout(() => {
    if (
      authenticated &&
      !processing
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
