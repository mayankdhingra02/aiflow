import * as net from 'net';
import * as os from 'os';
import * as path from 'path';
import { randomUUID } from 'crypto';
import { EventEmitter } from 'events';
import { FrameDecoder, FrameError, MAX_FRAME_BYTES, encodeFrame } from './framing';
import { ResolvedExecution } from './models';

/**
 * A minimal client for the official Codex extension's local client-coordination IPC router.
 *
 * Aiflow joins the router as an additional local client and asks the Codex client that already
 * owns a thread to drive it. Aiflow never becomes the thread owner and never starts a Codex
 * process — the official extension remains the only thing running Codex.
 *
 * The envelope below is the router's real wire format, confirmed against the running router:
 *
 *   request   { type, requestId, sourceClientId, version, method, params,
 *               targetClientId?, timeoutMs? }
 *   response  { type: "response", requestId, resultType: "success" | "error",
 *               method, handledByClientId, result } | { ..., resultType: "error", error }
 *   broadcast { type: "broadcast", method, sourceClientId, targetClientIds, params, version }
 *
 * Two details matter and are easy to get wrong:
 *  - `targetClientId` is a top-level envelope field. It is *not* part of a follower's `params`.
 *  - some methods answer in the envelope rather than the body: `thread-owner-discovery`
 *    returns an empty `result` and names the owner in `handledByClientId`.
 */

export const CLIENT_TYPE = 'aiflow-vscode';

/** The router expects this as `sourceClientId` until it has assigned us one. */
export const INITIALIZING_CLIENT_ID = 'initializing-client';

/**
 * Request versions, taken from the official extension's own version table. `initialize`
 * predates versioning and uses 0.
 */
export const REQUEST_VERSIONS = {
    initialize: 0,
    'thread-owner-discovery': 1,
    'thread-follower-start-turn': 1,
    'thread-follower-update-thread-settings': 1,
    /** 4 normally; 3 is the compatibility version used when there is no `expectedTurnId`. */
    'thread-follower-interrupt-turn': 4,
    'thread-follower-interrupt-turn-without-expected-turn': 3
} as const satisfies Record<string, number>;

/** The official interrupt reason for a user-initiated stop. */
export const USER_STOP_MODE = 'user-stop';

export const DEFAULT_REQUEST_TIMEOUT_MS = 20_000;

export class CodexIpcError extends Error {}
export class CodexIpcTimeoutError extends CodexIpcError {}
export class CodexIpcNoOwnerError extends CodexIpcError {}

export interface CodexIpcOptions {
    socketPath?: string;
    requestTimeoutMs?: number;
    maxFrameBytes?: number;
    /** Injectable for tests so no real socket is opened. */
    createSocket?: () => net.Socket;
    /** Injectable for deterministic request ids in tests. */
    newRequestId?: () => string;
}

/** Options that live on the router envelope, not inside `params`. */
export interface RequestOptions {
    version?: number;
    targetClientId?: string;
    timeoutMs?: number;
}

/** A response, keeping the envelope fields callers sometimes need. */
export interface CodexResponse {
    result: unknown;
    handledByClientId?: string;
    method?: string;
}

interface PendingRequest {
    resolve: (value: CodexResponse) => void;
    reject: (error: Error) => void;
    timer: NodeJS.Timeout;
    method: string;
}

/** The default macOS location of the router socket. Never a hard-coded home directory. */
export function defaultSocketPath(): string {
    return process.env.CODEX_IPC_SOCKET?.trim()
        ? (process.env.CODEX_IPC_SOCKET as string)
        : path.join(os.homedir(), '.codex', 'ipc', 'ipc.sock');
}

export class CodexIpcClient extends EventEmitter {
    private socket: net.Socket | undefined;
    private decoder: FrameDecoder;
    private readonly pending = new Map<string, PendingRequest>();
    private clientId: string | undefined;
    private disposed = false;

    private readonly socketPath: string;
    private readonly requestTimeoutMs: number;
    private readonly maxFrameBytes: number;
    private readonly createSocket: () => net.Socket;
    private readonly newRequestId: () => string;

    constructor(options: CodexIpcOptions = {}) {
        super();
        this.socketPath = options.socketPath ?? defaultSocketPath();
        this.requestTimeoutMs = options.requestTimeoutMs ?? DEFAULT_REQUEST_TIMEOUT_MS;
        this.maxFrameBytes = options.maxFrameBytes ?? MAX_FRAME_BYTES;
        this.decoder = new FrameDecoder(this.maxFrameBytes);
        this.createSocket = options.createSocket ?? (() => new net.Socket());
        this.newRequestId = options.newRequestId ?? (() => randomUUID());
    }

    get isConnected(): boolean {
        return this.socket !== undefined && this.clientId !== undefined;
    }

    get assignedClientId(): string | undefined {
        return this.clientId;
    }

    /** Connects and performs `initialize`, retaining the assigned client id. */
    async connect(): Promise<string> {
        if (this.disposed) {
            throw new CodexIpcError('client disposed');
        }
        if (this.clientId) {
            return this.clientId;
        }

        await this.openSocket();

        const response = await this.request(
            'initialize',
            { clientType: CLIENT_TYPE },
            { version: REQUEST_VERSIONS.initialize }
        );

        const clientId = (response.result as { clientId?: string } | undefined)?.clientId;
        if (!clientId) {
            throw new CodexIpcError('router did not return a clientId');
        }
        this.clientId = clientId;
        this.emit('connected', clientId);
        return clientId;
    }

    private openSocket(): Promise<void> {
        return new Promise((resolve, reject) => {
            const socket = this.createSocket();
            this.socket = socket;
            this.decoder = new FrameDecoder(this.maxFrameBytes);

            const onError = (error: Error): void => {
                reject(new CodexIpcError(`could not connect to Codex IPC: ${error.message}`));
            };

            socket.once('error', onError);
            socket.once('connect', () => {
                socket.removeListener('error', onError);
                socket.on('error', () => {
                    /* handled by 'close' */
                });
                resolve();
            });

            socket.on('data', (chunk: Buffer) => this.onData(chunk));
            socket.on('close', () => this.onClose());

            socket.connect({ path: this.socketPath } as net.NetConnectOpts);
        });
    }

    private onData(chunk: Buffer): void {
        let frames: unknown[];
        try {
            frames = this.decoder.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
        } catch (error) {
            // Framing is unrecoverable; drop the connection rather than misinterpret bytes.
            this.emit(
                'protocolError',
                error instanceof FrameError ? error : new FrameError(String(error))
            );
            this.socket?.destroy();
            return;
        }
        for (const frame of frames) {
            this.dispatch(frame);
        }
    }

    private dispatch(frame: unknown): void {
        if (typeof frame !== 'object' || frame === null) {
            return;
        }
        const message = frame as {
            type?: string;
            requestId?: string;
            resultType?: string;
            result?: unknown;
            error?: unknown;
            method?: string;
            handledByClientId?: string;
        };

        if (message.type === 'response' && typeof message.requestId === 'string') {
            const pending = this.pending.get(message.requestId);
            if (!pending) {
                return; // stale or unknown response
            }
            this.pending.delete(message.requestId);
            clearTimeout(pending.timer);

            if (message.resultType === 'error') {
                pending.reject(
                    new CodexIpcError(`${pending.method} failed: ${describeError(message.error)}`)
                );
            } else {
                pending.resolve({
                    result: message.result,
                    handledByClientId: message.handledByClientId,
                    method: message.method
                });
            }
            return;
        }

        // Anything else is a broadcast the router pushes to clients.
        this.emit('broadcast', message);
    }

    private onClose(): void {
        this.socket = undefined;
        this.clientId = undefined;
        this.rejectAllPending(new CodexIpcError('Codex IPC connection closed'));
        if (!this.disposed) {
            this.emit('disconnected');
        }
    }

    private rejectAllPending(error: Error): void {
        for (const [, pending] of this.pending) {
            clearTimeout(pending.timer);
            pending.reject(error);
        }
        this.pending.clear();
    }

    /**
     * Sends a request and resolves with the response envelope.
     *
     * `targetClientId` and `timeoutMs` belong on the envelope; putting either inside `params`
     * would silently address the wrong client.
     */
    request(method: string, params: unknown, options: RequestOptions = {}): Promise<CodexResponse> {
        const socket = this.socket;
        if (!socket) {
            return Promise.reject(new CodexIpcError('not connected to Codex IPC'));
        }

        const requestId = this.newRequestId();
        const message: Record<string, unknown> = {
            type: 'request',
            requestId,
            sourceClientId: this.clientId ?? INITIALIZING_CLIENT_ID,
            version: options.version ?? 0,
            method,
            params
        };
        if (options.targetClientId !== undefined) {
            message.targetClientId = options.targetClientId;
        }
        if (options.timeoutMs !== undefined) {
            message.timeoutMs = options.timeoutMs;
        }

        let framed: Buffer;
        try {
            framed = encodeFrame(message, this.maxFrameBytes);
        } catch (error) {
            return Promise.reject(error as Error);
        }

        return new Promise<CodexResponse>((resolve, reject) => {
            const timer = setTimeout(() => {
                this.pending.delete(requestId);
                reject(new CodexIpcTimeoutError(`${method} timed out`));
            }, this.requestTimeoutMs);

            this.pending.set(requestId, { resolve, reject, timer, method });
            socket.write(framed);
        });
    }

    // MARK: - Typed operations Aiflow needs

    /**
     * Finds the connected Codex client that currently owns a thread.
     *
     * The owner is reported in the response envelope's `handledByClientId`; the body is empty.
     */
    async discoverThreadOwner(conversationId: string, hostId = 'local'): Promise<string> {
        const response = await this.request(
            'thread-owner-discovery',
            { hostId, conversationId },
            { version: REQUEST_VERSIONS['thread-owner-discovery'] }
        );

        const owner =
            response.handledByClientId ??
            (response.result as { handledByClientId?: string } | undefined)?.handledByClientId;

        if (!owner) {
            throw new CodexIpcNoOwnerError(`no Codex client owns conversation ${conversationId}`);
        }
        return owner;
    }

    /**
     * Applies model and reasoning effort to the thread. This must succeed *before* a turn is
     * started: overriding reasoning only inside start-turn does not durably take effect on an
     * existing thread.
     */
    async updateThreadSettings(
        targetClientId: string,
        conversationId: string,
        execution: ResolvedExecution
    ): Promise<void> {
        await this.request(
            'thread-follower-update-thread-settings',
            {
                conversationId,
                threadSettings: { model: execution.model, effort: execution.effort }
            },
            {
                version: REQUEST_VERSIONS['thread-follower-update-thread-settings'],
                targetClientId
            }
        );
    }

    /** Starts a turn with the exact prompt text. */
    async startTurn(
        targetClientId: string,
        conversationId: string,
        prompt: string,
        execution: ResolvedExecution
    ): Promise<CodexResponse> {
        return this.request(
            'thread-follower-start-turn',
            {
                conversationId,
                turnStartParams: {
                    input: [{ type: 'text', text: prompt, text_elements: [] }],
                    model: execution.model,
                    effort: execution.effort
                },
                localTurnMetadata: null,
                mcpAppModelContextAttachments: null
            },
            { version: REQUEST_VERSIONS['thread-follower-start-turn'], targetClientId }
        );
    }

    /**
     * Interrupts the active turn of one exact conversation with the official user-stop
     * semantics.
     *
     * The extension's own version function drops to 3 when `expectedTurnId` is absent, so the
     * version sent here follows the same rule rather than claiming a turn id we do not have.
     */
    async interruptTurn(
        targetClientId: string,
        conversationId: string,
        expectedTurnId?: string
    ): Promise<void> {
        const params: Record<string, unknown> = { conversationId, mode: USER_STOP_MODE };
        let version: number =
            REQUEST_VERSIONS['thread-follower-interrupt-turn-without-expected-turn'];

        if (expectedTurnId) {
            params.expectedTurnId = expectedTurnId;
            version = REQUEST_VERSIONS['thread-follower-interrupt-turn'];
        }

        await this.request('thread-follower-interrupt-turn', params, { version, targetClientId });
    }

    dispose(): void {
        this.disposed = true;
        this.rejectAllPending(new CodexIpcError('Codex IPC client disposed'));
        this.socket?.destroy();
        this.socket = undefined;
        this.clientId = undefined;
        this.removeAllListeners();
    }
}

function describeError(error: unknown): string {
    if (typeof error === 'string') {
        return error;
    }
    if (typeof error === 'object' && error !== null) {
        const candidate = error as { message?: unknown; code?: unknown };
        if (typeof candidate.message === 'string') {
            return candidate.message;
        }
        if (typeof candidate.code === 'string' || typeof candidate.code === 'number') {
            return String(candidate.code);
        }
    }
    return 'unknown error';
}
