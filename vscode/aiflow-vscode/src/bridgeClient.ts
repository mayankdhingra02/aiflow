import * as net from 'net';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { EventEmitter } from 'events';
import {
    BRIDGE_HOST,
    BRIDGE_PORT,
    BridgeCommand,
    BridgeEvent,
    LineBuffer,
    RequestId,
    TOKEN_RELATIVE_PATH,
    encodeCommand,
    parseEvent
} from './protocol';

/** Reads the bridge token Aiflow wrote. Returns undefined if Aiflow has not run yet. */
export function readBridgeToken(tokenPath = path.join(os.homedir(), TOKEN_RELATIVE_PATH)):
    | string
    | undefined {
    try {
        const token = fs.readFileSync(tokenPath, 'utf8').trim();
        return token.length > 0 ? token : undefined;
    } catch {
        return undefined;
    }
}

export interface BridgeClientOptions {
    host?: string;
    port?: number;
    /** Backoff schedule in ms; the last value repeats. */
    retryDelaysMs?: number[];
    /** Injectable for tests so no real socket is opened. */
    createSocket?: () => net.Socket;
    /** Injectable for tests; defaults to reading Aiflow's token file. */
    readToken?: () => string | undefined;
}

/**
 * Connects to the Aiflow menu-bar app over loopback TCP and reconnects with bounded backoff.
 *
 * This client never starts Codex and never sends execution parameters — only the typed verbs
 * the bridge accepts. Aiflow remains the source of truth; a dropped connection here has no
 * effect on a running Codex session.
 */
export class BridgeClient extends EventEmitter {
    private socket: net.Socket | undefined;
    private readonly buffer = new LineBuffer();
    private readonly host: string;
    private readonly port: number;
    private readonly retryDelays: number[];
    private readonly createSocket: () => net.Socket;
    private readonly readToken: () => string | undefined;

    private retryIndex = 0;
    private reconnectTimer: NodeJS.Timeout | undefined;
    private disposed = false;
    private connected = false;
    /**
     * Bumped whenever the current connection is replaced or abandoned.
     *
     * A socket's callbacks fire asynchronously, so a socket we already discarded can still
     * deliver `close` (or data) afterwards. Without this, that stale `close` would null out the
     * *replacement* socket and schedule yet another reconnect, leaving one client with several
     * live authenticated sockets all emitting the same events — which is how one execute_run
     * turned into a duplicate.
     */
    private generation = 0;

    constructor(options: BridgeClientOptions = {}) {
        super();
        this.host = options.host ?? BRIDGE_HOST;
        this.port = options.port ?? BRIDGE_PORT;
        this.retryDelays = options.retryDelaysMs ?? [500, 1000, 2000, 5000, 10000];
        this.createSocket = options.createSocket ?? (() => new net.Socket());
        this.readToken = options.readToken ?? (() => readBridgeToken());
    }

    get isConnected(): boolean {
        return this.connected;
    }

    connect(): void {
        if (this.disposed || this.socket) {
            return;
        }
        this.clearTimer();

        const socket = this.createSocket();
        const generation = ++this.generation;
        this.socket = socket;
        socket.setEncoding('utf8');

        /** True only while this socket is still the one the client is using. */
        const isCurrent = (): boolean =>
            !this.disposed && generation === this.generation && this.socket === socket;

        socket.on('connect', () => {
            if (!isCurrent()) {
                socket.destroy();
                return;
            }
            this.connected = true;
            this.retryIndex = 0;
            this.buffer.reset();

            // Aiflow sends nothing but `hello` until the companion proves itself, so
            // authenticate immediately — including after every reconnect.
            const token = this.readToken();
            if (token) {
                socket.write(encodeCommand({ type: 'auth', token }));
            } else {
                this.emit('authFailed');
            }

            this.emit('connected');
        });

        socket.on('data', (chunk: string | Buffer) => {
            // A discarded socket must never emit a bridge event.
            if (!isCurrent()) {
                return;
            }
            const lines = this.buffer.append(chunk.toString());
            if (lines === null) {
                // Oversized frame: drop the connection rather than buffering without bound.
                socket.destroy();
                return;
            }
            for (const line of lines) {
                const event = parseEvent(line);
                // Malformed or unknown lines are dropped rather than guessed at.
                if (event) {
                    this.emit('event', event satisfies BridgeEvent);
                }
            }
        });

        socket.on('error', () => {
            // 'close' always follows; reconnection is handled there.
        });

        socket.on('close', () => {
            // A stale close belongs to a connection we already replaced: it must not clear the
            // newer socket, and must not schedule a second reconnect.
            if (!isCurrent()) {
                return;
            }
            const wasConnected = this.connected;
            this.connected = false;
            this.socket = undefined;
            if (wasConnected) {
                this.emit('disconnected');
            }
            this.scheduleReconnect();
        });

        socket.connect({ host: this.host, port: this.port });
    }

    /** Drops the current socket and retries immediately, leaving exactly one connection. */
    reconnectNow(): void {
        this.retryIndex = 0;
        this.clearTimer();

        const previous = this.socket;
        // Retire the old connection first so its late callbacks cannot touch the new one.
        this.generation += 1;
        this.socket = undefined;
        this.connected = false;
        previous?.destroy();

        this.connect();
    }

    private scheduleReconnect(): void {
        if (this.disposed || this.reconnectTimer) {
            return;
        }
        const delay = this.retryDelays[Math.min(this.retryIndex, this.retryDelays.length - 1)];
        this.retryIndex += 1;
        this.reconnectTimer = setTimeout(() => {
            this.reconnectTimer = undefined;
            this.connect();
        }, delay);
        // Never hold the extension host open just to retry.
        this.reconnectTimer.unref?.();
    }

    private clearTimer(): void {
        if (this.reconnectTimer) {
            clearTimeout(this.reconnectTimer);
            this.reconnectTimer = undefined;
        }
    }

    private send(command: BridgeCommand): boolean {
        if (!this.socket || !this.connected) {
            return false;
        }
        this.socket.write(encodeCommand(command));
        return true;
    }

    ping(): boolean {
        return this.send({ type: 'ping' });
    }

    cancel(): boolean {
        return this.send({ type: 'cancel' });
    }

    approve(requestId: RequestId): boolean {
        return this.send({ type: 'approve', requestId });
    }

    deny(requestId: RequestId): boolean {
        return this.send({ type: 'deny', requestId });
    }

    answerQuestion(requestId: RequestId, answers: Record<string, string>): boolean {
        return this.send({ type: 'answer_question', requestId, answers });
    }

    // MARK: - v2 worker reports
    //
    // Every report names the run it belongs to, so a stale report from a previous run can
    // never complete the wrong Aiflow job.

    /** Announces whether this companion can serve runs through the official Codex extension. */
    workerAvailable(ready: boolean): boolean {
        return this.send({ type: 'worker_available', workerState: ready ? 'ready' : 'unavailable' });
    }

    workerAccepted(runId: string): boolean {
        return this.send({ type: 'worker_accepted', runId });
    }

    workerThread(runId: string, conversationId: string, turnId?: string): boolean {
        return this.send({ type: 'worker_thread', runId, conversationId, turnId });
    }

    workerStatus(runId: string, workerState: string): boolean {
        return this.send({ type: 'worker_status', runId, workerState });
    }

    workerCompleted(runId: string, message: string): boolean {
        return this.send({ type: 'worker_completed', runId, message });
    }

    workerFailed(runId: string, message: string): boolean {
        return this.send({ type: 'worker_failed', runId, message });
    }

    workerCancelled(runId: string): boolean {
        return this.send({ type: 'worker_cancelled', runId });
    }

    dispose(): void {
        this.disposed = true;
        this.generation += 1;
        this.clearTimer();
        this.socket?.destroy();
        this.socket = undefined;
        this.connected = false;
        this.removeAllListeners();
    }
}
