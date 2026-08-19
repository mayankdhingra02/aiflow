import * as net from 'net';
import { EventEmitter } from 'events';
import {
    BRIDGE_HOST,
    BRIDGE_PORT,
    BridgeCommand,
    BridgeEvent,
    LineBuffer,
    RequestId,
    encodeCommand,
    parseEvent
} from './protocol';

export interface BridgeClientOptions {
    host?: string;
    port?: number;
    /** Backoff schedule in ms; the last value repeats. */
    retryDelaysMs?: number[];
    /** Injectable for tests so no real socket is opened. */
    createSocket?: () => net.Socket;
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

    private retryIndex = 0;
    private reconnectTimer: NodeJS.Timeout | undefined;
    private disposed = false;
    private connected = false;

    constructor(options: BridgeClientOptions = {}) {
        super();
        this.host = options.host ?? BRIDGE_HOST;
        this.port = options.port ?? BRIDGE_PORT;
        this.retryDelays = options.retryDelaysMs ?? [500, 1000, 2000, 5000, 10000];
        this.createSocket = options.createSocket ?? (() => new net.Socket());
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
        this.socket = socket;
        socket.setEncoding('utf8');

        socket.on('connect', () => {
            this.connected = true;
            this.retryIndex = 0;
            this.buffer.reset();
            this.emit('connected');
        });

        socket.on('data', (chunk: string | Buffer) => {
            for (const line of this.buffer.append(chunk.toString())) {
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

    /** Drops the current socket and retries immediately. */
    reconnectNow(): void {
        this.retryIndex = 0;
        this.clearTimer();
        if (this.socket) {
            this.socket.destroy();
            this.socket = undefined;
            this.connected = false;
        }
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

    dispose(): void {
        this.disposed = true;
        this.clearTimer();
        this.socket?.destroy();
        this.socket = undefined;
        this.connected = false;
        this.removeAllListeners();
    }
}
