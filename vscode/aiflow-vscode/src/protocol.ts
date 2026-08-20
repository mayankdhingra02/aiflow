/**
 * Wire types for the local Aiflow bridge, mirroring
 * macos/AiflowMenuBar/AiflowMenuBar/BridgeProtocol.swift.
 *
 * The extension is a view/control surface: it sends verbs, never execution parameters.
 * There is deliberately no way to express a repository path, sandbox, model, or command
 * in an outbound message.
 */

export const BRIDGE_HOST = '127.0.0.1';
export const BRIDGE_PORT = 47321;
export const PROTOCOL_VERSION = 1;

/**
 * Where Aiflow keeps the bridge token, relative to the user's home directory. Loopback is
 * not an authorization boundary — any local process could otherwise read the pending
 * approval's request id and answer it — so the companion proves itself with this shared
 * secret before Aiflow sends any run state.
 */
export const TOKEN_RELATIVE_PATH = 'Library/Application Support/Aiflow/bridge-token';

export type BridgeEventType =
    | 'hello'
    | 'snapshot'
    | 'run_started'
    | 'run_status'
    | 'agent_message'
    | 'approval_requested'
    | 'question_requested'
    | 'run_completed'
    | 'run_failed'
    | 'run_cancelled'
    | 'file_open'
    | 'file_changed'
    /**
     * v2: the macOS app asks the companion to execute a run through the official Codex
     * extension. This is the one event that carries execution parameters, and it only ever
     * travels app -> companion over the authenticated bridge.
     */
    | 'execute_run'
    /** v2: interrupt the official turn serving this exact run. */
    | 'cancel_run';

export type BridgeCommandType =
    | 'auth'
    | 'ping'
    /** v2 worker reports. Every one carries the runId it belongs to. */
    | 'worker_accepted'
    | 'worker_thread'
    | 'worker_status'
    | 'worker_completed'
    | 'worker_failed'
    | 'worker_cancelled'
    | 'worker_available'
    | 'cancel'
    | 'approve'
    | 'deny'
    | 'answer_question';

/** A JSON-RPC request id is an integer or a string; both must round-trip exactly. */
export type RequestId = number | string;

export interface BridgeOption {
    label: string;
    description: string;
}

export interface BridgeQuestion {
    id: string;
    header: string;
    question: string;
    options: BridgeOption[];
    isOther: boolean;
    isSecret: boolean;
}

export interface BridgeEvent {
    type: BridgeEventType;
    protocolVersion?: number;
    connected?: boolean;
    runState?: string;
    project?: string;
    model?: string;
    effort?: string;
    message?: string;
    promptPreview?: string;
    requestId?: RequestId;
    kind?: string;
    summary?: string;
    detail?: string;
    questions?: BridgeQuestion[];
    path?: string;

    // v2 execute_run fields.
    /** Correlates every worker report with the Aiflow run that asked for it. */
    runId?: string;
    /** Absolute repository path the run must execute in. */
    workspacePath?: string;
    /** The exact prompt text, submitted to Codex verbatim. */
    prompt?: string;
}

export interface BridgeCommand {
    type: BridgeCommandType;
    requestId?: RequestId;

    // v2 worker report fields.
    runId?: string;
    conversationId?: string;
    turnId?: string;
    workerState?: string;
    message?: string;
    answers?: Record<string, string>;
    /** Only ever set on an `auth` command. Never logged or surfaced in the UI. */
    token?: string;
}

const EVENT_TYPES: ReadonlySet<string> = new Set<BridgeEventType>([
    'hello',
    'snapshot',
    'run_started',
    'run_status',
    'agent_message',
    'approval_requested',
    'question_requested',
    'run_completed',
    'run_failed',
    'run_cancelled',
    'file_open',
    'file_changed',
    'execute_run',
    'cancel_run'
]);

/** Returns null for malformed JSON and unrecognized event types. Never throws. */
export function parseEvent(line: string): BridgeEvent | null {
    const trimmed = line.trim();
    if (!trimmed) {
        return null;
    }
    let value: unknown;
    try {
        value = JSON.parse(trimmed);
    } catch {
        return null;
    }
    if (typeof value !== 'object' || value === null || Array.isArray(value)) {
        return null;
    }
    const candidate = value as { type?: unknown };
    if (typeof candidate.type !== 'string' || !EVENT_TYPES.has(candidate.type)) {
        return null;
    }
    return value as BridgeEvent;
}

/** Encodes one newline-delimited command frame. */
export function encodeCommand(command: BridgeCommand): string {
    return JSON.stringify(command) + '\n';
}

/**
 * The largest inbound frame this client will buffer. Events can legitimately carry a whole
 * agent message, so this is far larger than the 64 KiB ceiling Aiflow applies to inbound
 * commands, which are only ever verbs plus short answers.
 */
export const MAX_FRAME_BYTES = 1024 * 1024;

/**
 * Accumulates socket chunks and yields complete newline-delimited lines, with a hard ceiling
 * on how much may accumulate without a newline.
 */
export class LineBuffer {
    private pending = '';
    private overflowed = false;

    constructor(private readonly limit: number = MAX_FRAME_BYTES) {}

    get didOverflow(): boolean {
        return this.overflowed;
    }

    /** Returns completed lines, or null once the limit is exceeded. */
    append(chunk: string): string[] | null {
        if (this.overflowed) {
            return null;
        }

        this.pending += chunk;
        const parts = this.pending.split('\n');
        this.pending = parts.pop() ?? '';

        // Every completed frame is measured, not just the trailing remainder: an oversized
        // frame that arrives already newline-terminated would otherwise pass unchecked.
        // Byte length, not character count, so multi-byte text is measured as it is framed.
        for (const part of parts) {
            if (Buffer.byteLength(part, 'utf8') > this.limit) {
                return this.reject();
            }
        }

        // Whatever remains has no newline yet; past the limit it never will.
        if (Buffer.byteLength(this.pending, 'utf8') > this.limit) {
            return this.reject();
        }

        return parts.map((part) => part.trim()).filter((part) => part.length > 0);
    }

    /**
     * Drops everything buffered and refuses the rest of the stream. No frames are returned
     * from the offending append, even ones parsed before the oversized frame.
     */
    private reject(): null {
        this.overflowed = true;
        this.pending = '';
        return null;
    }

    reset(): void {
        this.pending = '';
        this.overflowed = false;
    }
}

/** The state the view renders, rebuilt from snapshots and events. */
export interface AiflowState {
    connected: boolean;
    runState: string;
    project?: string;
    model?: string;
    effort?: string;
    lastMessage?: string;
    pendingApproval?: {
        requestId: RequestId;
        kind?: string;
        summary?: string;
        detail?: string;
    };
    pendingQuestion?: {
        requestId: RequestId;
        questions: BridgeQuestion[];
    };
}

export function initialState(): AiflowState {
    return { connected: false, runState: 'disconnected' };
}

/**
 * Folds one event into the view state. A snapshot replaces the world wholesale, which is
 * what makes reconnecting mid-run work without restarting anything.
 */
export function reduce(state: AiflowState, event: BridgeEvent): AiflowState {
    switch (event.type) {
        case 'hello':
            return { ...state, connected: true };

        case 'snapshot': {
            const next: AiflowState = {
                connected: true,
                runState: event.runState ?? 'ready',
                project: event.project,
                model: event.model,
                effort: event.effort,
                lastMessage: event.message || undefined,
                pendingApproval: undefined,
                pendingQuestion: undefined
            };
            if (event.runState === 'waiting_for_approval' && event.requestId !== undefined) {
                next.pendingApproval = {
                    requestId: event.requestId,
                    kind: event.kind,
                    summary: event.summary,
                    detail: event.detail
                };
            }
            if (event.runState === 'waiting_for_input' && event.requestId !== undefined) {
                next.pendingQuestion = {
                    requestId: event.requestId,
                    questions: event.questions ?? []
                };
            }
            return next;
        }

        case 'run_started':
            return {
                ...state,
                runState: event.runState ?? 'launching',
                project: event.project ?? state.project,
                model: event.model ?? state.model,
                effort: event.effort ?? state.effort,
                lastMessage: undefined,
                pendingApproval: undefined,
                pendingQuestion: undefined
            };

        case 'run_status':
            return { ...state, runState: event.runState ?? state.runState };

        case 'agent_message':
            return { ...state, lastMessage: event.message ?? state.lastMessage };

        case 'approval_requested':
            if (event.requestId === undefined) {
                return state;
            }
            return {
                ...state,
                runState: 'waiting_for_approval',
                pendingApproval: {
                    requestId: event.requestId,
                    kind: event.kind,
                    summary: event.summary,
                    detail: event.detail
                }
            };

        case 'question_requested':
            if (event.requestId === undefined) {
                return state;
            }
            return {
                ...state,
                runState: 'waiting_for_input',
                pendingQuestion: {
                    requestId: event.requestId,
                    questions: event.questions ?? []
                }
            };

        case 'run_completed':
            return {
                ...state,
                runState: 'completed',
                lastMessage: event.message ?? state.lastMessage,
                pendingApproval: undefined,
                pendingQuestion: undefined
            };

        case 'run_failed':
            return {
                ...state,
                runState: 'failed',
                lastMessage: event.message ?? state.lastMessage,
                pendingApproval: undefined,
                pendingQuestion: undefined
            };

        case 'run_cancelled':
            return {
                ...state,
                runState: 'cancelled',
                pendingApproval: undefined,
                pendingQuestion: undefined
            };

        default:
            // file_open / file_changed / execute_run are side effects handled elsewhere,
            // not view state.
            return state;
    }
}

/** Human-readable status for the status bar and tree. */
export function statusLabel(state: AiflowState): string {
    if (!state.connected) {
        return 'Disconnected';
    }
    switch (state.runState) {
        case 'ready':
            return 'Ready';
        case 'confirming':
            return 'Awaiting confirmation';
        case 'launching':
        case 'running':
        case 'responding':
            return 'Running';
        case 'retrying':
            return 'Retrying';
        case 'waiting_for_approval':
            return 'Waiting for approval';
        case 'waiting_for_input':
            return 'Waiting for input';
        case 'cancelling':
            return 'Cancelling';
        case 'cancelled':
            return 'Cancelled';
        case 'completed':
            return 'Completed';
        case 'failed':
            return 'Failed';
        default:
            return state.runState;
    }
}

/** A validated execution request. Missing or malformed fields make the request unusable. */
export interface ExecutionRequest {
    runId: string;
    workspacePath: string;
    prompt: string;
    model?: string;
    effort?: string;
}

/**
 * Validates an `execute_run` event into something the worker may act on.
 *
 * The companion refuses to guess: without a run id it could complete the wrong Aiflow job,
 * and without an absolute workspace path or a prompt there is nothing coherent to run.
 */
export function parseExecutionRequest(event: BridgeEvent): ExecutionRequest | undefined {
    if (event.type !== 'execute_run') {
        return undefined;
    }
    const runId = (event.runId ?? '').trim();
    const workspacePath = (event.workspacePath ?? '').trim();
    const prompt = event.prompt ?? '';

    if (!runId || !workspacePath || prompt.trim().length === 0) {
        return undefined;
    }
    if (!workspacePath.startsWith('/')) {
        return undefined; // only absolute local paths
    }
    return { runId, workspacePath, prompt, model: event.model, effort: event.effort };
}
