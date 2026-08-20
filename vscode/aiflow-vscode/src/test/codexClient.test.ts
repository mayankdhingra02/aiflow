import { strict as assert } from 'node:assert';
import { test } from 'node:test';
import * as net from 'net';
import {
    CLIENT_TYPE,
    CodexIpcClient,
    CodexIpcNoOwnerError,
    CodexIpcTimeoutError,
    REQUESTS
} from '../codexIpc/client';
import { encodeFrame } from '../codexIpc/framing';

/** A fake Unix socket: records what Aiflow writes, and lets a test push frames back. */
class FakeSocket extends net.Socket {
    sent: Record<string, unknown>[] = [];
    connectPaths: string[] = [];
    destroyed_ = false;

    override connect(options: any): this {
        this.connectPaths.push(options.path);
        setImmediate(() => this.emit('connect'));
        return this;
    }

    override write(chunk: any): boolean {
        const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
        const length = buffer.readUInt32LE(0);
        this.sent.push(JSON.parse(buffer.subarray(4, 4 + length).toString('utf8')));
        return true;
    }

    override destroy(): this {
        this.destroyed_ = true;
        this.emit('close');
        return this;
    }

    /** Pushes a response frame for the request at `index`. */
    respondTo(index: number, result: unknown, error?: unknown): void {
        const request = this.sent[index];
        const message: Record<string, unknown> = { type: 'response', id: request.id };
        if (error !== undefined) {
            message.error = error;
        } else {
            message.result = result;
        }
        this.emit('data', encodeFrame(message));
    }

    broadcast(message: unknown): void {
        this.emit('data', encodeFrame(message));
    }
}

function makeClient(timeoutMs = 200): { client: CodexIpcClient; socket: FakeSocket } {
    const socket = new FakeSocket();
    const client = new CodexIpcClient({
        socketPath: '/tmp/fake-codex.sock',
        requestTimeoutMs: timeoutMs,
        createSocket: () => socket
    });
    return { client, socket };
}

/** Connects and completes `initialize`. */
async function connected(timeoutMs = 200): Promise<{ client: CodexIpcClient; socket: FakeSocket }> {
    const { client, socket } = makeClient(timeoutMs);
    const connecting = client.connect();
    await new Promise((r) => setImmediate(r));
    socket.respondTo(0, { clientId: 'client-aiflow-1' });
    await connecting;
    return { client, socket };
}

test('initialize announces the Aiflow client type and retains the client id', async () => {
    const { client, socket } = await connected();

    assert.equal(socket.sent[0].method, 'initialize');
    assert.deepEqual(socket.sent[0].params, { clientType: CLIENT_TYPE });
    assert.equal(client.assignedClientId, 'client-aiflow-1');
    assert.equal(client.isConnected, true);
    client.dispose();
});

test('connects to the configured socket path', async () => {
    const { client, socket } = await connected();
    assert.deepEqual(socket.connectPaths, ['/tmp/fake-codex.sock']);
    client.dispose();
});

test('matches responses to their own request ids', async () => {
    const { client, socket } = await connected();

    const first = client.request('a', {});
    const second = client.request('b', {});
    await new Promise((r) => setImmediate(r));

    // Answer out of order: correlation is by id, not arrival order.
    socket.respondTo(2, { which: 'second' });
    socket.respondTo(1, { which: 'first' });

    assert.deepEqual(await first, { which: 'first' });
    assert.deepEqual(await second, { which: 'second' });
    client.dispose();
});

test('a request rejects on timeout', async () => {
    const { client } = await connected(60);
    await assert.rejects(() => client.request('never-answered', {}), CodexIpcTimeoutError);
    client.dispose();
});

test('an error response rejects with the router message', async () => {
    const { client, socket } = await connected();
    const pending = client.request('thing', {});
    await new Promise((r) => setImmediate(r));
    socket.respondTo(1, undefined, { message: 'no client found' });

    await assert.rejects(() => pending, /no client found/);
    client.dispose();
});

test('pending requests reject when the connection drops', async () => {
    const { client, socket } = await connected();
    const pending = client.request('thing', {});
    await new Promise((r) => setImmediate(r));

    socket.emit('close');

    await assert.rejects(() => pending, /connection closed/);
    assert.equal(client.isConnected, false);
    client.dispose();
});

test('a fatal framing error drops the connection instead of misreading bytes', async () => {
    const { client, socket } = await connected();
    let protocolError: Error | undefined;
    client.on('protocolError', (error: Error) => (protocolError = error));

    const header = Buffer.alloc(4);
    header.writeUInt32LE(500_000_000, 0); // absurd length
    socket.emit('data', header);

    assert.ok(protocolError, 'a framing error is surfaced');
    assert.equal(socket.destroyed_, true);
    client.dispose();
});

test('broadcasts are emitted rather than treated as responses', async () => {
    const { client, socket } = await connected();
    const seen: unknown[] = [];
    client.on('broadcast', (message: unknown) => seen.push(message));

    socket.broadcast({ type: 'notification', method: 'thread/following', params: { conversationId: 'c1' } });

    assert.equal(seen.length, 1);
    client.dispose();
});

// MARK: typed operations

test('owner discovery sends the documented payload and returns the owner', async () => {
    const { client, socket } = await connected();
    const pending = client.discoverThreadOwner('conv-1');
    await new Promise((r) => setImmediate(r));

    assert.equal(socket.sent[1].method, REQUESTS.threadOwnerDiscovery.method);
    assert.equal(socket.sent[1].version, 1);
    assert.deepEqual(socket.sent[1].params, { hostId: 'local', conversationId: 'conv-1' });

    socket.respondTo(1, { handledByClientId: 'client-codex-9' });
    assert.equal(await pending, 'client-codex-9');
    client.dispose();
});

test('owner discovery rejects when no client owns the thread', async () => {
    const { client, socket } = await connected();
    const pending = client.discoverThreadOwner('conv-1');
    await new Promise((r) => setImmediate(r));
    socket.respondTo(1, {});

    await assert.rejects(() => pending, CodexIpcNoOwnerError);
    client.dispose();
});

test('settings update carries the exact model and effort', async () => {
    const { client, socket } = await connected();
    const pending = client.updateThreadSettings('owner-1', 'conv-1', {
        model: 'gpt-5.6-sol',
        effort: 'low'
    });
    await new Promise((r) => setImmediate(r));

    assert.equal(socket.sent[1].method, REQUESTS.followerUpdateSettings.method);
    assert.equal(socket.sent[1].version, 1);
    assert.deepEqual(socket.sent[1].params, {
        targetClientId: 'owner-1',
        conversationId: 'conv-1',
        threadSettings: { model: 'gpt-5.6-sol', effort: 'low' }
    });

    socket.respondTo(1, {});
    await pending;
    client.dispose();
});

test('start-turn submits the exact prompt with the same model and effort', async () => {
    const { client, socket } = await connected();
    const prompt = 'AIFLOW_EXACT_IPC_PROBE. Reply with exactly AIFLOW_EXACT_IPC_OK.';
    const pending = client.startTurn('owner-1', 'conv-1', prompt, {
        model: 'gpt-5.6-sol',
        effort: 'low'
    });
    await new Promise((r) => setImmediate(r));

    const params = socket.sent[1].params as Record<string, any>;
    assert.equal(socket.sent[1].method, REQUESTS.followerStartTurn.method);
    assert.equal(socket.sent[1].version, 1);
    assert.equal(params.targetClientId, 'owner-1');
    assert.equal(params.conversationId, 'conv-1');
    assert.deepEqual(params.turnStartParams.input, [
        { type: 'text', text: prompt, text_elements: [] }
    ]);
    assert.equal(params.turnStartParams.model, 'gpt-5.6-sol');
    assert.equal(params.turnStartParams.effort, 'low');
    assert.equal(params.localTurnMetadata, null);
    assert.equal(params.mcpAppModelContextAttachments, null);

    // No TODO wrapper, ever.
    assert.ok(!JSON.stringify(socket.sent[1]).toLowerCase().includes('implementtodo'));
    socket.respondTo(1, {});
    await pending;
    client.dispose();
});

test('interrupt names the exact conversation and turn', async () => {
    const { client, socket } = await connected();
    const pending = client.interruptTurn('owner-1', 'conv-1', 'turn-7');
    await new Promise((r) => setImmediate(r));

    assert.equal(socket.sent[1].method, REQUESTS.followerInterruptTurn.method);
    assert.deepEqual(socket.sent[1].params, {
        targetClientId: 'owner-1',
        conversationId: 'conv-1',
        turnId: 'turn-7'
    });
    socket.respondTo(1, {});
    await pending;
    client.dispose();
});

test('requests are refused when not connected', async () => {
    const { client } = makeClient();
    await assert.rejects(() => client.request('x', {}), /not connected/);
    client.dispose();
});

test('dispose rejects everything in flight', async () => {
    const { client } = await connected();
    const pending = client.request('thing', {});
    client.dispose();
    await assert.rejects(() => pending, /disposed/);
});
