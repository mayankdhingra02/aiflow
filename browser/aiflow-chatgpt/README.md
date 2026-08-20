# Aiflow ChatGPT handoff extension

Local Chrome extension that receives terminal Aiflow result handoffs over the authenticated WebSocket at `ws://127.0.0.1:47322`.

It does not call private ChatGPT APIs, read cookies, or extract session credentials.

A handoff is sent only to the exact ChatGPT conversation captured by Aiflow at run dispatch.

Delivery is acknowledged only after the content script observes the unique Aiflow run sentinel in a user message in that exact conversation.

If the extension clicks Send but cannot confirm the resulting user message, the run is blocked instead of automatically retrying and risking a duplicate message.

## Load locally

1. Open `chrome://extensions`.
2. Enable Developer mode.
3. Choose **Load unpacked**.
4. Select `browser/aiflow-chatgpt`.
5. Click the Aiflow extension icon to open its options.
6. Paste the contents of:

   `~/Library/Application Support/Aiflow/handoff-token`

7. Save.

This extension is intended for the local Aiflow installation only.

## Result routing and safety

The macOS app exposes pending terminal handoffs over the authenticated
loopback WebSocket at `ws://127.0.0.1:47322`. The browser extension uses the
dedicated token stored at:

`~/Library/Application Support/Aiflow/handoff-token`

That token is intentionally separate from Aiflow's Codex/VS Code bridge token.

A saved project may have one explicit **Return Chat**. When configured, that
conversation is authoritative for the run. Active-browser ChatGPT detection is
only a fallback when the project has no Return Chat. The resolved target is
snapshotted at dispatch so changing tabs or mappings during a Codex run cannot
retarget the result.

Delivery is fail-closed around the ChatGPT composer. The extension verifies the
exact conversation, refuses to overwrite a non-empty composer, and confirms
the unique `[Aiflow result <runId>]` user-message sentinel before acknowledging
delivery. If that sentinel already exists after an interrupted acknowledgement,
the extension acknowledges it without submitting a duplicate message.

A rejected handoff token is recorded as an authentication error and automatic
reconnect stops until a new token is saved through the extension options page.

This implements only the **Codex result → ChatGPT** leg. It does not yet
automatically extract ChatGPT's response and redispatch the next instruction to
Codex.
