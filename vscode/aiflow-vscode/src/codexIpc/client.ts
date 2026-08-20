import * as net from 'net';
import * as os from 'os';
import * as path from 'path';
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
 * Only the small set of operations Aiflow needs is implemented. The typed request helpers are
 * deliberately thin so more follower operations can be added without touching transport.
 */

export const CLIENT_TYPE = 'aiflow-vscode';

/** Request method names, with the router's request version for each. */
export const REQUESTS = {
    initialize: { method: 'initialize', version: undefined as number | undefined },
    threadOwnerDiscovery: { method: 'thread-owner-discovery', version: 1 },
    followerStartTurn: { method: 'thread-follower-start-turn', version: 1 },
    followerUpdateSettings: { method: 'thread-follower-update-thread-settings', version: 1 },
    followerInterruptTurn: { method: 'thread-follower-interrupt-turn', version: 1 }
} as const;

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
}

interface PendingRequest {
    resolve: (value: unknown) => void;
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
    private nextRequestId = 1;
    private clientId: string | undefined;
    private disposed = false;

    private readonly socketPath: string;
    private readonly requestTimeoutMs: number;
    private readonly maxFrameBytes: number;
    private readonly createSocket: () => net.Socket;

    constructor(options: CodexIpcOptions = {}) {
        super();
        this.socketPath = options.socketPath ?? defaultSocketPath();
        this.requestTimeoutMs = options.requestTimeoutMs ?? DEFAULT_REQUEST_TIMEOUT_MS;
        this.maxFrameBytes = options.maxFrameBytes ?? MAX_FRAME_BYTES;
        this.decoder = new FrameDecoder(this.maxFrameBytes);
        this.createSocket = options.createSocket ?? (() => new net.Socket());
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

        const result = (await this.request(REQUESTS.initialize.method, {
            clientType: CLIENT_TYPE
        })) as { clientId?: string } | undefined;

        const clientId = result?.clientId;
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
            this.emit('protocolError', error instanceof FrameError ? error : new FrameError(String(error)));
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
            id?: string | number;
            result?: unknown;
            error?: unknown;
            method?: string;
            params?: unknown;
        };

        if (message.type === 'response' && message.id !== undefined) {
            const pending = this.pending.get(String(message.id));
            if (!pending) {
                return; // stale or unknown response
            }
            this.pending.delete(String(message.id));
            clearTimeout(pending.timer);

            if (message.error !== undefined && message.error !== null) {
                pending.reject(
                    new CodexIpcError(
                        `${pending.method} failed: ${describeError(message.error)}`
                    )
                );
            } else {
                pending.resolve(message.result);
            }
            return;
        }

        // Anything else is a broadcast/notification the router pushes to clients.
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

    /** Sends a request and resolves with its result. */
    request(method: string, params: unknown, version?: number): Promise<unknown> {
        const socket = this.socket;
        if (!socket) {
            return Promise.reject(new CodexIpcError('not connected to Codex IPC'));
        }

        const id = String(this.nextRequestId++);
        const message: Record<string, unknown> = { type: 'request', id, method, params };
        if (version !== undefined) {
            message.version = version;
        }

        let framed: Buffer;
        try {
            framed = encodeFrame(message, this.maxFrameBytes);
        } catch (error) {
            return Promise.reject(error as Error);
        }

        return new Promise<unknown>((resolve, reject) => {
            const timer = setTimeout(() => {
                this.pending.delete(id);
                reject(new CodexIpcTimeoutError(`${method} timed out`));
            }, this.requestTimeoutMs);

            this.pending.set(id, { resolve, reject, timer, method });
            socket.write(framed);
        });
    }

    // MARK: - Typed operations Aiflow needs

    /** Finds the connected Codex client that currently owns a thread. */
    async discoverThreadOwner(conversationId: string, hostId = 'local'): Promise<string> {
        const result = (await this.request(
            REQUESTS.threadOwnerDiscovery.method,
            { hostId, conversationId },
            REQUESTS.threadOwnerDiscovery.version
        )) as { handledByClientId?: string } | undefined;

        const owner = result?.handledByClientId;
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
            REQUESTS.followerUpdateSettings.method,
            {
                targetClientId,
                conversationId,
                threadSettings: { model: execution.model, effort: execution.effort }
            },
            REQUESTS.followerUpdateSettings.version
        );
    }

    /** Starts a turn with the exact prompt text. Returns the router's raw result. */
    async startTurn(
        targetClientId: string,
        conversationId: string,
        prompt: string,
        execution: ResolvedExecution
    ): Promise<unknown> {
        return this.request(
            REQUESTS.followerStartTurn.method,
            {
                targetClientId,
                conversationId,
                turnStartParams: {
                    input: [{ type: 'text', text: prompt, text_elements: [] }],
                    model: execution.model,
                    effort: execution.effort
                },
                localTurnMetadata: null,
                mcpAppModelContextAttachments: null
            },
            REQUESTS.followerStartTurn.version
        );
    }

    /** Interrupts the active turn of one exact conversation. */
    async interruptTurn(
        targetClientId: string,
        conversationId: string,
        turnId?: string
    ): Promise<void> {
        const params: Record<string, unknown> = { targetClientId, conversationId };
        if (turnId) {
            params.turnId = turnId;
        }
        await this.request(
            REQUESTS.followerInterruptTurn.method,
            params,
            REQUESTS.followerInterruptTurn.version
        );
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
