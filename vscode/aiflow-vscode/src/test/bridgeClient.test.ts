import { strict as assert } from 'node:assert';
import { test } from 'node:test';
import * as net from 'net';
import { BridgeClient } from '../bridgeClient';
import { BridgeEvent } from '../protocol';

/**
 * A fake socket standing in for a real TCP connection, so the client's framing and
 * reconnect behaviour can be tested without opening a port.
 */
class FakeSocket extends net.Socket {
    written: string[] = [];
    connectCalls: { host?: string; port?: number }[] = [];
    destroyed_ = false;

    override connect(options: any): this {
        this.connectCalls.push({ host: options.host, port: options.port });
        return this;
    }

    override write(chunk: any): boolean {
        this.written.push(String(chunk));
        return true;
    }

    override setEncoding(): this {
        return this;
    }

    override destroy(): this {
        this.destroyed_ = true;
        this.emit('close');
        return this;
    }

    // Test helpers
    open(): void {
        this.emit('connect');
    }
    feed(chunk: string): void {
        this.emit('data', chunk);
    }
    simulateClose(): void {
        this.emit('close');
    }
}

function makeClient(): { client: BridgeClient; sockets: FakeSocket[] } {
    const sockets: FakeSocket[] = [];
    const client = new BridgeClient({
        retryDelaysMs: [10],
        createSocket: () => {
            const socket = new FakeSocket();
            sockets.push(socket);
            return socket;
        }
    });
    return { client, sockets };
}

test('connects to loopback on the agreed port', () => {
    const { client, sockets } = makeClient();
    client.connect();

    assert.equal(sockets.length, 1);
    assert.deepEqual(sockets[0].connectCalls, [{ host: '127.0.0.1', port: 47321 }]);
    client.dispose();
});

test('emits parsed events and drops malformed lines', () => {
    const { client, sockets } = makeClient();
    const received: BridgeEvent[] = [];
    client.on('event', (event: BridgeEvent) => received.push(event));

    client.connect();
    sockets[0].open();
    sockets[0].feed('{"type":"hello"}\n{not json\n{"type":"launch_codex"}\n');
    sockets[0].feed('{"type":"agent_mes');
    sockets[0].feed('sage","message":"hi"}\n');

    assert.deepEqual(
        received.map((e) => e.type),
        ['hello', 'agent_message']
    );
    assert.equal(received[1].message, 'hi');
    client.dispose();
});

test('tracks connected state across connect and disconnect', () => {
    const { client, sockets } = makeClient();
    let connects = 0;
    let disconnects = 0;
    client.on('connected', () => (connects += 1));
    client.on('disconnected', () => (disconnects += 1));

    client.connect();
    assert.equal(client.isConnected, false, 'not connected until the socket opens');

    sockets[0].open();
    assert.equal(client.isConnected, true);
    assert.equal(connects, 1);

    sockets[0].simulateClose();
    assert.equal(client.isConnected, false);
    assert.equal(disconnects, 1);
    client.dispose();
});

test('reconnects with backoff after the connection drops', async () => {
    const { client, sockets } = makeClient();
    client.connect();
    sockets[0].open();
    sockets[0].simulateClose();

    await new Promise((resolve) => setTimeout(resolve, 60));

    assert.ok(sockets.length >= 2, 'a new socket should have been created');
    client.dispose();
});

test('sending is refused while disconnected and succeeds once connected', () => {
    const { client, sockets } = makeClient();
    client.connect();

    // Before the socket opens there is nothing to write to.
    assert.equal(client.cancel(), false);

    sockets[0].open();
    assert.equal(client.cancel(), true);
    assert.equal(client.approve(17), true);
    assert.equal(client.deny(18), true);
    assert.equal(client.answerQuestion(4, { q1: 'a' }), true);
    assert.equal(client.ping(), true);

    assert.deepEqual(sockets[0].written, [
        '{"type":"cancel"}\n',
        '{"type":"approve","requestId":17}\n',
        '{"type":"deny","requestId":18}\n',
        '{"type":"answer_question","requestId":4,"answers":{"q1":"a"}}\n',
        '{"type":"ping"}\n'
    ]);
    client.dispose();
});

test('reconnectNow drops the current socket and opens a fresh one', () => {
    const { client, sockets } = makeClient();
    client.connect();
    sockets[0].open();

    client.reconnectNow();

    assert.equal(sockets.length, 2);
    assert.equal(sockets[0].destroyed_, true);
    client.dispose();
});

test('dispose stops further reconnection', async () => {
    const { client, sockets } = makeClient();
    client.connect();
    sockets[0].open();
    client.dispose();
    sockets[0].simulateClose();

    await new Promise((resolve) => setTimeout(resolve, 60));

    assert.equal(sockets.length, 1, 'a disposed client must not reconnect');
});
