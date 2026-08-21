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
    "",
    resultText,
    "",
    "Review this Codex result in the context of our current task.",
    "If more implementation work is needed, give me the exact next instruction to send to Codex."
  ].join("\n");
}

export function reviewMessageIsBounded(message, maximumBytes = 32 * 1024) {
  const text = String(message ?? "");
  return text.trim().length > 0 && new TextEncoder().encode(text).length <= maximumBytes;
}

export function buildReviewCommand(review) {
  return {
    type: "review",
    runId: review?.runId,
    conversationId: review?.conversationId,
    assistantMessage: review?.assistantMessage
  };
}
