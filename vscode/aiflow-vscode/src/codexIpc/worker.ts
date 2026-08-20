import { CodexIpcClient, CodexIpcError } from './client';
import { resolveExecution } from './models';
import {
    SessionTail,
    TurnResult,
    findSessionFile,
    findStartedTurnIds,
    findTurnResult
} from './sessionWatcher';

/**
 * Drives one Aiflow run through the official Codex extension.
 *
 * Aiflow never starts Codex here. It joins the official extension's local IPC router as a
 * follower, asks the client that owns a thread to start a turn, and then reads the durable
 * session log to learn how that exact turn ended.
 */

/** A provisional id the official extension uses before a thread is real. */
export const PROVISIONAL_PREFIX = 'client-new-thread:';

export function isProvisionalConversationId(id: string | undefined): boolean {
    return typeof id === 'string' && id.startsWith(PROVISIONAL_PREFIX);
}

export type WorkerFailureCode =
    | 'extension_unavailable'
    | 'ipc_unavailable'
    | 'thread_unavailable'
    | 'settings_rejected'
    | 'start_rejected'
    | 'timed_out'
    | 'turn_failed';

export class WorkerError extends Error {
    constructor(readonly code: WorkerFailureCode, message: string) {
        super(message);
    }
}

export interface WorkerRunRequest {
    runId: string;
    workspacePath: string;
    prompt: string;
    model?: string;
    effort?: string;
}

export interface WorkerHandle {
    runId: string;
    conversationId: string;
    turnId?: string;
}

/** Everything the worker needs from the outside, injectable so the flow is testable. */
export interface WorkerDeps {
    ipc: CodexIpcClient;
    /** Resolves the conversation the run should execute in, creating a fresh one when needed. */
    resolveConversation: (request: WorkerRunRequest) => Promise<string>;
    /** Locates the durable session file for a conversation. */
    findSession?: (conversationId: string) => string | undefined;
    /** Builds a tail reader; injectable for tests. */
    createTail?: (filePath: string) => Pick<SessionTail, 'readNew'>;
    /** Sleep between session polls. */
    delay?: (ms: number) => Promise<void>;
    now?: () => number;
}

export interface WorkerRunOptions {
    /** How long to wait for the turn to finish. */
    completionTimeoutMs?: number;
    /** How long to wait for the session file and the turn id to appear. */
    startTimeoutMs?: number;
    pollIntervalMs?: number;
    onEvent?: (event: WorkerEvent) => void;
}

export type WorkerEvent =
    | { type: 'thread'; runId: string; conversationId: string }
    | { type: 'turn'; runId: string; conversationId: string; turnId: string }
    | { type: 'status'; runId: string; state: string };

const DEFAULT_COMPLETION_TIMEOUT_MS = 30 * 60_000;
const DEFAULT_START_TIMEOUT_MS = 90_000;
const DEFAULT_POLL_INTERVAL_MS = 400;

export class OfficialCodexWorker {
    private active: WorkerHandle | undefined;
    private cancelled = false;

    constructor(private readonly deps: WorkerDeps) {}

    /** The run currently in flight, if any. */
    get activeHandle(): WorkerHandle | undefined {
        return this.active;
    }

    /**
     * Executes one run end to end.
     *
     * The order here is deliberate and load-bearing: settings must be applied and acknowledged
     * *before* the turn starts, because overriding reasoning effort inside start-turn alone
     * does not durably take effect on an existing thread.
     */
    async run(request: WorkerRunRequest, options: WorkerRunOptions = {}): Promise<TurnResult> {
        try {
            return await this.execute(request, options);
        } finally {
            // Whatever happened — owner discovery, settings, session resolution, start, or a
            // timeout — the run is over. A stale handle would otherwise let a later cancel
            // interrupt a conversation this worker no longer owns.
            this.active = undefined;
            this.cancelled = false;
        }
    }

    private async execute(
        request: WorkerRunRequest,
        options: WorkerRunOptions
    ): Promise<TurnResult> {
        const execution = resolveExecution(request.model, request.effort);
        const emit = options.onEvent ?? ((): void => {});
        const delay = this.deps.delay ?? ((ms: number) => new Promise((r) => setTimeout(r, ms)));
        const now = this.deps.now ?? (() => Date.now());
        const findSession = this.deps.findSession ?? findSessionFile;

        this.cancelled = false;

        // 1. Which official conversation should this run use?
        const conversationId = await this.deps.resolveConversation(request);
        if (!conversationId || isProvisionalConversationId(conversationId)) {
            throw new WorkerError(
                'thread_unavailable',
                'no official Codex conversation could be resolved for this run'
            );
        }
        this.active = { runId: request.runId, conversationId };
        emit({ type: 'thread', runId: request.runId, conversationId });

        // 2. Who owns that conversation right now?
        const owner = await this.discoverOwner(conversationId);

        // 3. Apply model + effort and require success. Fail closed: running on whatever the
        //    official UI happened to have selected is not acceptable.
        emit({ type: 'status', runId: request.runId, state: 'configuring' });
        try {
            await this.deps.ipc.updateThreadSettings(owner, conversationId, execution);
        } catch (error) {
            throw new WorkerError(
                'settings_rejected',
                `could not apply model/effort: ${describe(error)}`
            );
        }

        // 4. Submit the exact prompt. The turn must be started before the session log is
        //    opened: a conversation that has never taken a turn has no session file yet, so
        //    waiting for one first would deadlock.
        emit({ type: 'status', runId: request.runId, state: 'starting' });
        let startResponse: unknown;
        try {
            startResponse = await this.deps.ipc.startTurn(
                owner, conversationId, request.prompt, execution);
        } catch (error) {
            throw new WorkerError('start_rejected', `could not start turn: ${describe(error)}`);
        }

        // 5. Prefer the turn id Codex returned. Inferring it from "the first task_started we
        //    happen to see" is a guess; the response is authoritative when it carries one.
        let turnId = turnIdFromStartResponse(startResponse);
        if (turnId) {
            this.active = { runId: request.runId, conversationId, turnId };
            emit({ type: 'turn', runId: request.runId, conversationId, turnId });
        }

        const sessionPath = await this.waitForSession(
            conversationId,
            findSession,
            delay,
            now,
            options.startTimeoutMs ?? DEFAULT_START_TIMEOUT_MS,
            options.pollIntervalMs ?? DEFAULT_POLL_INTERVAL_MS
        );
        const tail = (this.deps.createTail ?? ((p: string) => new SessionTail(p)))(sessionPath);

        // 6. Learn the exact turn id, then wait for that exact turn to finish.
        const deadline = now() + (options.completionTimeoutMs ?? DEFAULT_COMPLETION_TIMEOUT_MS);
        let result: TurnResult | undefined;

        while (now() < deadline) {
            const records = tail.readNew();

            if (!turnId) {
                // Only used when the start-turn response did not name the turn.
                const started = findStartedTurnIds(records);
                if (started.length > 0) {
                    turnId = started[0];
                    this.active = { runId: request.runId, conversationId, turnId };
                    emit({ type: 'turn', runId: request.runId, conversationId, turnId });
                    emit({ type: 'status', runId: request.runId, state: 'running' });
                }
            }

            if (turnId) {
                result = findTurnResult(records, turnId);
                if (result) {
                    break;
                }
            }

            if (this.cancelled && turnId) {
                // Keep reading: the interrupt was sent, the turn's own record is authoritative.
                emit({ type: 'status', runId: request.runId, state: 'cancelling' });
            }

            await delay(options.pollIntervalMs ?? DEFAULT_POLL_INTERVAL_MS);
        }

        if (!result) {
            throw new WorkerError(
                'timed_out',
                turnId
                    ? `turn ${turnId} did not finish in time`
                    : 'Codex never reported a turn starting for this run'
            );
        }

        return result;
    }

    private async discoverOwner(conversationId: string): Promise<string> {
        try {
            return await this.deps.ipc.discoverThreadOwner(conversationId);
        } catch (error) {
            throw new WorkerError(
                'thread_unavailable',
                `no Codex client owns that conversation: ${describe(error)}`
            );
        }
    }

    private async waitForSession(
        conversationId: string,
        findSession: (id: string) => string | undefined,
        delay: (ms: number) => Promise<void>,
        now: () => number,
        timeoutMs: number,
        pollMs: number
    ): Promise<string> {
        const deadline = now() + timeoutMs;
        for (;;) {
            const found = findSession(conversationId);
            if (found) {
                return found;
            }
            if (now() >= deadline) {
                throw new WorkerError(
                    'thread_unavailable',
                    `no Codex session log appeared for conversation ${conversationId}`
                );
            }
            await delay(pollMs);
        }
    }

    /**
     * Interrupts the run's own turn. Idempotent, and scoped to the exact conversation this
     * worker started — never whatever conversation happens to be active in the UI.
     */
    async cancel(runId: string): Promise<boolean> {
        const handle = this.active;
        if (!handle || handle.runId !== runId) {
            return false; // stale or unknown run: nothing of ours to cancel
        }
        if (this.cancelled) {
            return true;
        }
        this.cancelled = true;

        try {
            const owner = await this.deps.ipc.discoverThreadOwner(handle.conversationId);
            await this.deps.ipc.interruptTurn(owner, handle.conversationId, handle.turnId);
            return true;
        } catch (error) {
            throw new WorkerError('ipc_unavailable', `could not interrupt turn: ${describe(error)}`);
        }
    }
}

function describe(error: unknown): string {
    if (error instanceof CodexIpcError || error instanceof Error) {
        return error.message;
    }
    return String(error);
}

/**
 * Reads the turn id out of a `thread-follower-start-turn` response, when the router provides
 * one. Several shapes are tolerated because only the presence of a turn id matters.
 */
export function turnIdFromStartResponse(response: unknown): string | undefined {
    const result = (response as { result?: unknown } | undefined)?.result ?? response;
    if (typeof result !== 'object' || result === null) {
        return undefined;
    }
    const record = result as Record<string, unknown>;
    const turn = record.turn as { id?: unknown } | undefined;

    for (const candidate of [turn?.id, record.turnId, record.turn_id]) {
        if (typeof candidate === 'string' && candidate.length > 0) {
            return candidate;
        }
    }
    return undefined;
}
