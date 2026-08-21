import test from "node:test";
import assert from "node:assert/strict";

import {
  canonicalChatURL,
  conversationIdFromURL,
  buildHandoffMessage,
  buildReviewCommand,
  reviewMessageIsBounded,
  assistantAfterExactSentinel
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

test("correlates only the unique exact sentinel to its following assistant", () => {
  const sentinel = "[Aiflow result run-123]";
  const assistant = { role: "assistant", text: "PR12_OK" };
  assert.deepEqual(
    assistantAfterExactSentinel([
      { role: "assistant", text: "old history" },
      { role: "user", text: `${sentinel} details` },
      assistant
    ], sentinel),
    assistant
  );
});

test("does not use an old assistant remounted after the baseline", () => {
  const sentinel = "[Aiflow result run-123]";
  assert.equal(
    assistantAfterExactSentinel([
      { role: "assistant", text: "old history" },
      { role: "user", text: "unrelated user message" },
      { role: "assistant", text: "old history" },
      { role: "user", text: `${sentinel} details` }
    ], sentinel),
    null
  );
});

test("waits when the exact sentinel has no assistant yet", () => {
  assert.equal(
    assistantAfterExactSentinel(
      [{ role: "user", text: "[Aiflow result run-123] details" }],
      "[Aiflow result run-123]"
    ),
    null
  );
});

test("accepts an initially empty assistant placeholder", () => {
  const placeholder = { role: "assistant", text: "" };
  assert.deepEqual(
    assistantAfterExactSentinel([
      { role: "user", text: "[Aiflow result run-123] details" },
      placeholder
    ], "[Aiflow result run-123]"),
    placeholder
  );
});

test("rejects a partial prefix without the exact run sentinel", () => {
  assert.equal(
    assistantAfterExactSentinel([
      { role: "user", text: "[Aiflow result run-12] details" },
      { role: "assistant", text: "wrong" }
    ], "[Aiflow result run-123]"),
    null
  );
});

test("rejects duplicate matching sentinels", () => {
  assert.equal(
    assistantAfterExactSentinel([
      { role: "user", text: "[Aiflow result run-123] first" },
      { role: "assistant", text: "first" },
      { role: "user", text: "[Aiflow result run-123] duplicate" },
      { role: "assistant", text: "second" }
    ], "[Aiflow result run-123]"),
    null
  );
});

test("rejects an intervening user message", () => {
  assert.equal(
    assistantAfterExactSentinel([
      { role: "user", text: "[Aiflow result run-123] details" },
      { role: "user", text: "another request" },
      { role: "assistant", text: "unrelated" }
    ], "[Aiflow result run-123]"),
    null
  );
});

test("keeps observers for different sentinels isolated", () => {
  const messages = [
    { role: "user", text: "[Aiflow result run-a] details" },
    { role: "assistant", text: "review-a" },
    { role: "user", text: "[Aiflow result run-b] details" },
    { role: "assistant", text: "review-b" }
  ];
  assert.equal(assistantAfterExactSentinel(messages, "[Aiflow result run-a]").text, "review-a");
  assert.equal(assistantAfterExactSentinel(messages, "[Aiflow result run-b]").text, "review-b");
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
      /# Implementation Review/
    );
    assert.match(text, /## Verdict/);
    assert.match(text, /## Codex Instruction/);
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
