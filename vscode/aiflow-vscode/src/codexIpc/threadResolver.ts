import { isProvisionalConversationId } from './worker';

/**
 * Decides which official Codex conversation an Aiflow run executes in.
 *
 * The hard requirement is that a run must never be dispatched into an unrelated conversation
 * the user happens to have open. So a conversation is only accepted if it is observed to
 * appear *after* we asked for a new panel — never merely because it is present.
 */

export const OFFICIAL_EXTENSION_ID = 'openai.chatgpt';
export const NEW_PANEL_COMMAND = 'chatgpt.newCodexPanel';

export class ThreadResolutionError extends Error {
    constructor(readonly code: 'timeout' | 'no_signal', message: string) {
        super(message);
    }
}

/** A conversation id seen in a router broadcast. */
export function conversationIdFromBroadcast(message: unknown): string | undefined {
    if (typeof message !== 'object' || message === null) {
        return undefined;
    }
    const params = (message as { params?: unknown }).params;
    const candidates: unknown[] = [];

    if (typeof params === 'object' && params !== null) {
        const p = params as Record<string, unknown>;
        candidates.push(p.conversationId, p.threadId, p.conversation_id, p.thread_id);
    }
    const top = message as Record<string, unknown>;
    candidates.push(top.conversationId, top.threadId);

    for (const candidate of candidates) {
        if (typeof candidate === 'string' && candidate.length > 0) {
            return candidate;
        }
    }
    return undefined;
}

export interface FreshThreadDeps {
    /** Subscribes to router broadcasts; returns an unsubscribe function. */
    onBroadcast: (listener: (message: unknown) => void) => () => void;
    /** Runs the official "new Codex panel" command. */
    openNewPanel: () => Promise<void>;
    delay?: (ms: number) => Promise<void>;
    now?: () => number;
}

export interface FreshThreadOptions {
    timeoutMs?: number;
    pollIntervalMs?: number;
}

const DEFAULT_TIMEOUT_MS = 30_000;
const DEFAULT_POLL_MS = 200;

/**
 * Opens a new official Codex panel and returns the conversation id it created.
 *
 * Correlation rule: we start listening first, record every conversation id already mentioned
 * on the router, then ask for a new panel. Only an id we had not seen before is eligible, so a
 * user's existing threads can never be selected.
 *
 * KNOWN LIMITATION, measured against the installed extension (26.814.41407): opening a panel
 * announces no conversation at all. `chatgpt.newCodexPanel` and `chatgpt.newChat` both emit
 * only `client-status-changed` with no id, no provisional `client-new-thread:` id reaches the
 * router, and the router's method table contains no thread-creation request — every
 * `thread-follower-*` operation addresses a conversation that already exists. A real
 * conversation appears to come into being only when a human submits the first message in the
 * panel.
 *
 * So this resolver currently always times out, by design: failing is correct, because the
 * alternative would be dispatching an Aiflow run into one of the user's unrelated
 * conversations. It is kept (rather than deleted) so the moment the extension does announce a
 * new thread, the correlation is already right.
 */
export async function createFreshThread(
    deps: FreshThreadDeps,
    options: FreshThreadOptions = {}
): Promise<string> {
    const delay = deps.delay ?? ((ms: number) => new Promise((r) => setTimeout(r, ms)));
    const now = deps.now ?? (() => Date.now());
    const timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS;
    const pollMs = options.pollIntervalMs ?? DEFAULT_POLL_MS;

    const known = new Set<string>();
    const fresh: string[] = [];
    let sawProvisional = false;
    let capturing = false;

    const unsubscribe = deps.onBroadcast((message) => {
        const id = conversationIdFromBroadcast(message);
        if (!id) {
            return;
        }
        if (!capturing) {
            known.add(id); // pre-existing conversation: never eligible
            return;
        }
        if (isProvisionalConversationId(id)) {
            sawProvisional = true; // a panel is being created; the real id follows
            return;
        }
        if (!known.has(id) && !fresh.includes(id)) {
            fresh.push(id);
        }
    });

    try {
        // Let existing threads announce themselves before we start treating ids as new.
        await delay(pollMs);
        capturing = true;

        await deps.openNewPanel();

        const deadline = now() + timeoutMs;
        while (now() < deadline) {
            if (fresh.length > 0) {
                return fresh[0];
            }
            await delay(pollMs);
        }

        throw new ThreadResolutionError(
            'timeout',
            sawProvisional
                ? 'a new Codex panel was created but never reported a real conversation id'
                : 'the official Codex extension announced no conversation for the new panel; ' +
                  'a fresh official thread cannot currently be created from a follower client'
        );
    } finally {
        unsubscribe();
    }
}
