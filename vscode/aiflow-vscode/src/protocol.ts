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
    | 'file_changed';

export type BridgeCommandType = 'ping' | 'cancel' | 'approve' | 'deny' | 'answer_question';

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
}

export interface BridgeCommand {
    type: BridgeCommandType;
    requestId?: RequestId;
    answers?: Record<string, string>;
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
    'file_changed'
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

/** Accumulates socket chunks and yields complete newline-delimited lines. */
export class LineBuffer {
    private pending = '';

    append(chunk: string): string[] {
        this.pending += chunk;
        const parts = this.pending.split('\n');
        this.pending = parts.pop() ?? '';
        return parts.map((part) => part.trim()).filter((part) => part.length > 0);
    }

    reset(): void {
        this.pending = '';
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
            // file_open / file_changed are side effects, not state.
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
