import test from "node:test";
import assert from "node:assert/strict";

import {
  canonicalChatURL,
  conversationIdFromURL,
  buildHandoffMessage,
  buildReviewCommand,
  reviewMessageIsBounded
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

test("accepts bounded non-empty review text", () => {
  assert.equal(reviewMessageIsBounded("Review complete."), true);
  assert.equal(reviewMessageIsBounded("   "), false);
  assert.equal(reviewMessageIsBounded("x".repeat(33 * 1024)), false);
  assert.equal(reviewMessageIsBounded(" ".repeat(33 * 1024) + "x"), false);
});

test("builds a typed review transport command", () => {
  assert.deepEqual(
    buildReviewCommand({
      runId: "run-123",
      conversationId: "chat-123",
      assistantMessage: "Review complete."
    }),
    {
      type: "review",
      runId: "run-123",
      conversationId: "chat-123",
      assistantMessage: "Review complete."
    }
  );
});

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
