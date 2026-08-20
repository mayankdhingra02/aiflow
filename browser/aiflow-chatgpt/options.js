const tokenInput =
  document.getElementById(
    "token"
  );

const status =
  document.getElementById(
    "status"
  );

const blockedStatus =
  document.getElementById(
    "blocked-status"
  );

document
  .getElementById("save")
  .addEventListener(
    "click",
    saveToken
  );

document
  .getElementById(
    "clear-blocked"
  )
  .addEventListener(
    "click",
    clearBlocked
  );

async function load() {
  const stored =
    await chrome.storage.local.get([
      "handoffToken",
      "blockedRunId",
      "blockedReason",
      "authError"
    ]);

  tokenInput.value =
    stored.handoffToken || "";

  renderBlocked(stored);
  renderAuthError(
    stored.authError
  );
}

async function saveToken() {
  const token =
    tokenInput.value.trim();

  if (!token) {
    status.textContent =
      "Token cannot be empty.";
    return;
  }

  await chrome.storage.local.set({
    handoffToken: token
  });

  await chrome.storage.local.remove(
    "authError"
  );

  status.textContent =
    "Saved. Reconnecting…";

  try {
    await chrome.runtime.sendMessage({
      type: "aiflow-token-updated"
    });
  } catch {
    status.textContent =
      "Saved. The extension will reconnect when its service worker starts.";
  }
}

async function clearBlocked() {
  await chrome.storage.local.remove([
    "blockedRunId",
    "blockedReason"
  ]);

  blockedStatus.textContent =
    "None.";

  try {
    await chrome.runtime.sendMessage({
      type: "aiflow-clear-blocked"
    });
  } catch {
  }
}

function renderBlocked(stored) {
  if (!stored.blockedRunId) {
    blockedStatus.textContent =
      "None.";
    return;
  }

  blockedStatus.textContent =
    `${stored.blockedRunId}: ` +
    `${stored.blockedReason || "unknown reason"}`;
}

function renderAuthError(authError) {
  if (
    authError !==
      "authentication_failed"
  ) {
    return;
  }

  status.textContent =
    "Token rejected by Aiflow. Copy the current token from " +
    "~/Library/Application Support/Aiflow/handoff-token " +
    "and click Save.";
}

chrome.storage.onChanged.addListener(
  (changes, areaName) => {
    if (
      areaName !== "local" ||
      !changes.authError
    ) {
      return;
    }

    renderAuthError(
      changes.authError.newValue
    );
  }
);

load();
