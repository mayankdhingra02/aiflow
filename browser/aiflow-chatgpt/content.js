chrome.runtime.onMessage.addListener(
  (message, sender, sendResponse) => {
    if (
      message?.type !==
      "aiflow-deliver-handoff"
    ) {
      return;
    }

    deliver(message)
      .then(sendResponse)
      .catch(error => {
        sendResponse({
          ok: false,
          retryable: true,
          error:
            error?.message ||
            "unexpected_content_error"
        });
      });

    return true;
  }
);

async function deliver(message) {
  const currentConversationId =
    conversationIdFromLocation();

  if (
    !currentConversationId ||
    currentConversationId !==
      message.conversationId
  ) {
    return {
      ok: false,
      retryable: true,
      error: "wrong_conversation"
    };
  }

  const sentinel =
    `[Aiflow result ${message.runId}]`;

  /*
   * The ChatGPT message may already have been submitted even if Aiflow
   * never received its delivery acknowledgement (for example, extension
   * or browser shutdown immediately after Send). In that case acknowledge
   * the existing exact-run message instead of risking a duplicate.
   */
  if (
    userMessageContainsSentinel(
      sentinel
    )
  ) {
    return {
      ok: true
    };
  }

  if (conversationIsBusy()) {
    return {
      ok: false,
      retryable: true,
      error: "conversation_busy"
    };
  }

  const composer =
    findUniqueComposer();

  if (!composer) {
    return {
      ok: false,
      retryable: true,
      error: "composer_not_found"
    };
  }

  if (
    normalizeText(
      composerText(composer)
    ) !== ""
  ) {
    return {
      ok: false,
      retryable: true,
      error: "composer_not_empty"
    };
  }

  const inserted =
    insertComposerText(
      composer,
      message.text
    );

  if (!inserted) {
    clearComposer(composer);

    return {
      ok: false,
      retryable: true,
      error: "composer_insert_failed"
    };
  }

  const insertionObserved =
    await waitForComposerText(
      composer,
      sentinel,
      1500
    );

  if (!insertionObserved) {
    clearComposer(composer);

    return {
      ok: false,
      retryable: true,
      error:
        "composer_insert_not_observed"
    };
  }

  const sendButton =
    await waitForSendButton();

  if (!sendButton) {
    clearComposer(composer);

    return {
      ok: false,
      retryable: true,
      error: "send_button_not_ready"
    };
  }

  /*
   * Persist the ambiguous-send state BEFORE clicking. If the extension,
   * browser, or tab dies after Send but before confirmation, the next
   * attempt will remain blocked instead of risking a duplicate.
   */
  try {
    await chrome.storage.local.set({
      blockedRunId:
        message.runId,
      blockedReason:
        "send_outcome_unconfirmed"
    });
  } catch {
    clearComposer(composer);

    return {
      ok: false,
      retryable: true,
      error:
        "delivery_state_write_failed"
    };
  }

  sendButton.click();

  const confirmed =
    await waitForUserMessage(
      sentinel,
      15000
    );

  if (!confirmed) {
    return {
      ok: false,
      retryable: false,
      error: "send_not_confirmed"
    };
  }

  try {
    await rememberDeliveryReceipt(
      message.runId,
      message.conversationId
    );

    const stored =
      await chrome.storage.local.get(
        "blockedRunId"
      );

    if (
      stored.blockedRunId ===
        message.runId
    ) {
      await chrome.storage.local.remove([
        "blockedRunId",
        "blockedReason"
      ]);
    }
  } catch {
    /*
     * The message definitely exists, but we could not persist the receipt.
     * Leave the pre-send block in place and fail closed rather than risking
     * another automatic submission.
     */
    return {
      ok: false,
      retryable: false,
      error:
        "delivery_receipt_write_failed"
    };
  }

  return {
    ok: true
  };
}

function conversationIdFromLocation() {
  const parts =
    location.pathname
      .split("/")
      .filter(Boolean);

  const index =
    parts.lastIndexOf("c");

  if (
    index < 0 ||
    index + 1 >= parts.length
  ) {
    return null;
  }

  return parts[index + 1] || null;
}

function conversationIsBusy() {
  const selectors = [
    'button[data-testid="stop-button"]',
    'button[aria-label="Stop generating"]',
    'button[aria-label*="Stop generating"]'
  ];

  return selectors.some(selector =>
    visibleElements(selector)
      .length > 0
  );
}

function findUniqueComposer() {
  const selectors = [
    "#prompt-textarea",
    '[data-testid="composer-text-input"]',
    'div.ProseMirror[contenteditable="true"]',
    'div[contenteditable="true"][data-virtualkeyboard="true"]'
  ];

  const found = [];

  for (const selector of selectors) {
    for (
      const element of
      visibleElements(selector)
    ) {
      if (!found.includes(element)) {
        found.push(element);
      }
    }
  }

  return found.length === 1
    ? found[0]
    : null;
}

function composerText(element) {
  if (
    element instanceof
      HTMLTextAreaElement ||
    element instanceof
      HTMLInputElement
  ) {
    return element.value || "";
  }

  return (
    element.innerText ||
    element.textContent ||
    ""
  );
}

function insertComposerText(
  element,
  text
) {
  element.focus();

  if (
    element instanceof
      HTMLTextAreaElement
  ) {
    const setter =
      Object.getOwnPropertyDescriptor(
        HTMLTextAreaElement.prototype,
        "value"
      )?.set;

    if (!setter) return false;

    setter.call(element, text);

    element.dispatchEvent(
      new Event(
        "input",
        {
          bubbles: true
        }
      )
    );

    return true;
  }

  if (
    element instanceof
      HTMLInputElement
  ) {
    const setter =
      Object.getOwnPropertyDescriptor(
        HTMLInputElement.prototype,
        "value"
      )?.set;

    if (!setter) return false;

    setter.call(element, text);

    element.dispatchEvent(
      new Event(
        "input",
        {
          bubbles: true
        }
      )
    );

    return true;
  }

  const selection =
    window.getSelection();

  if (!selection) return false;

  const range =
    document.createRange();

  range.selectNodeContents(
    element
  );

  selection.removeAllRanges();
  selection.addRange(range);

  let inserted = false;

  try {
    inserted =
      document.execCommand(
        "insertText",
        false,
        text
      );
  } catch {
  }

  if (!inserted) {
    element.textContent = text;

    element.dispatchEvent(
      new InputEvent(
        "input",
        {
          bubbles: true,
          inputType: "insertText",
          data: text
        }
      )
    );
  }

  return true;
}

function clearComposer(element) {
  element.focus();

  if (
    element instanceof
      HTMLTextAreaElement ||
    element instanceof
      HTMLInputElement
  ) {
    element.value = "";

    element.dispatchEvent(
      new Event(
        "input",
        {
          bubbles: true
        }
      )
    );

    return;
  }

  element.textContent = "";

  element.dispatchEvent(
    new InputEvent(
      "input",
      {
        bubbles: true,
        inputType:
          "deleteContentBackward"
      }
    )
  );
}

async function waitForSendButton() {
  for (
    let attempt = 0;
    attempt < 50;
    attempt++
  ) {
    const button =
      findUniqueSendButton();

    if (
      button &&
      !button.disabled &&
      button.getAttribute(
        "aria-disabled"
      ) !== "true"
    ) {
      return button;
    }

    await sleep(100);
  }

  return null;
}

function findUniqueSendButton() {
  const selectors = [
    'button[data-testid="send-button"]',
    'button[aria-label="Send prompt"]',
    'button[aria-label="Send message"]'
  ];

  const found = [];

  for (const selector of selectors) {
    for (
      const element of
      visibleElements(selector)
    ) {
      if (!found.includes(element)) {
        found.push(element);
      }
    }
  }

  return found.length === 1
    ? found[0]
    : null;
}

async function waitForComposerText(
  composer,
  expectedText,
  timeoutMs
) {
  const deadline =
    Date.now() + timeoutMs;

  const expected =
    normalizeText(expectedText);

  while (
    Date.now() < deadline
  ) {
    if (
      normalizeText(
        composerText(composer)
      ).includes(expected)
    ) {
      return true;
    }

    await sleep(50);
  }

  return false;
}

async function rememberDeliveryReceipt(
  runId,
  conversationId
) {
  const stored =
    await chrome.storage.local.get(
      "deliveryReceipts"
    );

  const receipts = {
    ...(stored.deliveryReceipts || {})
  };

  receipts[runId] =
    conversationId;

  /*
   * Bound local state. In practice receipts disappear on delivered_ack,
   * but this prevents unlimited accumulation if acknowledgements are lost.
   */
  const entries =
    Object.entries(receipts);

  if (entries.length > 256) {
    const trimmed =
      entries.slice(
        entries.length - 256
      );

    await chrome.storage.local.set({
      deliveryReceipts:
        Object.fromEntries(trimmed)
    });

    return;
  }

  await chrome.storage.local.set({
    deliveryReceipts: receipts
  });
}

function userMessageContainsSentinel(
  sentinel
) {
  const expected =
    normalizeText(sentinel);

  const messages =
    document.querySelectorAll(
      '[data-message-author-role="user"]'
    );

  for (const element of messages) {
    const text =
      normalizeText(
        element.innerText ||
        element.textContent ||
        ""
      );

    if (text.includes(expected)) {
      return true;
    }
  }

  return false;
}

async function waitForUserMessage(
  sentinel,
  timeoutMs
) {
  const deadline =
    Date.now() + timeoutMs;

  while (
    Date.now() < deadline
  ) {
    if (
      userMessageContainsSentinel(
        sentinel
      )
    ) {
      return true;
    }

    await sleep(100);
  }

  return false;
}

function visibleElements(selector) {
  return [
    ...document.querySelectorAll(
      selector
    )
  ].filter(element => {
    const style =
      getComputedStyle(element);

    const rect =
      element.getBoundingClientRect();

    return (
      style.display !== "none" &&
      style.visibility !== "hidden" &&
      rect.width > 0 &&
      rect.height > 0
    );
  });
}

function normalizeText(text) {
  return String(text ?? "")
    .replace(/\u200B/g, "")
    .replace(/\r\n/g, "\n")
    .trim();
}

function sleep(ms) {
  return new Promise(resolve => {
    setTimeout(resolve, ms);
  });
}
