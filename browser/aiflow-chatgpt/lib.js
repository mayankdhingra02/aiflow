export function conversationIdFromURL(raw) {
  if (!raw) return null;

  let url;

  try {
    url = new URL(raw);
  } catch {
    return null;
  }

  if (url.hostname !== "chatgpt.com") {
    return null;
  }

  const parts = url.pathname
    .split("/")
    .filter(Boolean);

  const cIndex = parts.lastIndexOf("c");

  if (
    cIndex < 0 ||
    cIndex + 1 >= parts.length
  ) {
    return null;
  }

  const id = parts[cIndex + 1];

  return id || null;
}

export function canonicalChatURL(raw) {
  const id = conversationIdFromURL(raw);

  if (!id) return null;

  return `https://chatgpt.com/c/${id}`;
}

export function buildHandoffMessage(handoff) {
  const runId = handoff?.runId ?? "";
  const project =
    handoff?.project?.name ?? "Unknown project";
  const worker =
    handoff?.execution?.worker ?? "unknown";
  const modelRole =
    handoff?.execution?.modelRole ?? "unknown";
  const effort =
    handoff?.execution?.effort ?? "unknown";
  const outcome =
    handoff?.outcome ?? "unknown";

  let resultText;

  if (outcome === "completed") {
    resultText =
      handoff?.result?.finalMessage?.trim() ||
      "(Codex completed without a final message.)";
  } else if (outcome === "failed") {
    resultText =
      handoff?.result?.errorMessage?.trim() ||
      "(Codex failed without an error message.)";
  } else if (outcome === "cancelled") {
    resultText = "(The Codex run was cancelled.)";
  } else {
    resultText = "(Unknown terminal outcome.)";
  }

  return [
    `[Aiflow result ${runId}]`,
    `Project: ${project}`,
    `Worker: ${worker}`,
    `Outcome: ${outcome}`,
    `Previous Codex execution: Model: ${modelRole}; Reasoning: ${effort}`,
    "",
    resultText,
    "",
    "Review this Codex result in the context of our current task.",
    "If more implementation work is needed, respond using exactly this format:",
    "",
    "# Implementation Review",
    "## Verdict",
    "SHIP",
    "or",
    "CHANGES_REQUESTED",
    "",
    "For CHANGES_REQUESTED, add these sections in exactly this order:",
    "## Codex Execution",
    "Model: <one allowed role>",
    "Reasoning: <one allowed effort>",
    "## Codex Instruction",
    "<one exact, bounded instruction for Codex>",
    "",
    "Choose the least-expensive, lowest-reasoning configuration likely to complete the work reliably.",
    "Allowed Model values: luna, terra, sol.",
    "Allowed Reasoning values: low, medium, high, xhigh.",
    "Do not explain the routing choice.",
    "",
    "For SHIP, include neither Codex Execution nor Codex Instruction.",
  ].join("\n");
}

export function reviewMessageIsBounded(message, maximumBytes = 32 * 1024) {
  const text = String(message ?? "");
  return text.trim().length > 0 && new TextEncoder().encode(text).length <= maximumBytes;
}

export function assistantAfterExactSentinel(messages, sentinel) {
  const expected = normalizeReviewText(sentinel);
  if (!expected) return null;

  const matches = messages.filter((message) =>
    message?.role === "user" &&
    normalizeReviewText(message.text).startsWith(expected)
  );

  if (matches.length !== 1) return null;

  const sentinelIndex = messages.indexOf(matches[0]);
  for (const message of messages.slice(sentinelIndex + 1)) {
    if (message?.role === "user") return null;
    if (message?.role === "assistant") return message;
  }

  return null;
}

function normalizeReviewText(value) {
  return String(value ?? "").replace(/\s+/g, " ").trim();
}

export function buildReviewCommand(review) {
  return {
    type: "review",
    runId: review?.runId,
    conversationId: review?.conversationId,
    assistantMessage: review?.assistantMessage
  };
}

export function buildRoutingMessage(request) {
  return `[Aiflow routing ${request.runId}]\n\nChoose settings for the next Codex turn only. Do not implement the task.\n\nProject: ${request.project.name}\nPrompt:\n${request.prompt}\n\nReply with exactly:\n# Codex Routing\n## Model\n<luna|terra|sol>\n## Reasoning\n<low|medium|high|xhigh>`;
}
export function routingMessageIsBounded(message) { const text = String(message ?? ""); return text.trim().length > 0 && new TextEncoder().encode(text).length <= 32 * 1024; }
export function buildRoutingResponseCommand(response) { return { type: "routing_response", ...response }; }
