import test from "node:test";
import assert from "node:assert/strict";

import {
  canonicalChatURL,
  conversationIdFromURL,
  buildHandoffMessage
} from "./lib.js";

test(
  "canonicalizes ChatGPT conversation URLs",
  () => {
    assert.equal(
      canonicalChatURL(
        "https://chatgpt.com/c/abc123?x=1#y"
      ),
      "https://chatgpt.com/c/abc123"
    );

    assert.equal(
      canonicalChatURL(
        "https://chatgpt.com/g/gpt-id/c/abc123"
      ),
      "https://chatgpt.com/c/abc123"
    );
  }
);

test(
  "rejects non-conversation URLs",
  () => {
    assert.equal(
      conversationIdFromURL(
        "https://chatgpt.com/"
      ),
      null
    );

    assert.equal(
      canonicalChatURL(
        "https://example.com/c/abc"
      ),
      null
    );
  }
);

test(
  "formats successful handoff with unique run sentinel",
  () => {
    const text =
      buildHandoffMessage({
        runId: "run-123",
        outcome: "completed",
        project: {
          name: "demo"
        },
        execution: {
          worker: "official-vscode"
        },
        result: {
          finalMessage: "Tests passed."
        }
      });

    assert.match(
      text,
      /\[Aiflow result run-123\]/
    );

    assert.match(
      text,
      /Tests passed\./
    );

    assert.match(
      text,
      /exact next instruction/
    );
  }
);

test(
  "formats failed handoff using error text",
  () => {
    const text =
      buildHandoffMessage({
        runId: "run-fail",
        outcome: "failed",
        project: {
          name: "demo"
        },
        execution: {
          worker: "legacy-app-server"
        },
        result: {
          errorMessage: "Build failed."
        }
      });

    assert.match(
      text,
      /Build failed\./
    );
  }
);
