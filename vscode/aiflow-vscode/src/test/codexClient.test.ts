import { strict as assert } from 'node:assert';
import { test } from 'node:test';
import * as net from 'net';
import {
    CLIENT_TYPE,
    CodexIpcClient,
    CodexIpcNoOwnerError,
    CodexIpcTimeoutError,
    INITIALIZING_CLIENT_ID,
    REQUEST_VERSIONS,
    USER_STOP_MODE
} from '../codexIpc/client';
import { encodeFrame } from '../codexIpc/framing';

/**
 * These fixtures are the router's real frames, captured from the running official Codex
 * extension. The fake below only replays them — it never re-derives the shape from our own
 * types, which is how the previous envelope bug survived a green test suite.
 */
const REAL_INITIALIZE_REQUEST = {
    type: 'request',
    requestId: 'request-1',
    sourceClientId: 'initializing-client',
    version: 0,
    method: 'initialize',
    params: { clientType: 'aiflow-vscode' }
};

const REAL_INITIALIZE_RESPONSE = {
    type: 'response',
    requestId: 'request-1',
    resultType: 'success',
    method: 'initialize',
    handledByClientId: 'assigned-client-id',
    result: { clientId: 'assigned-client-id' }
};

/** Owner discovery answers in the envelope: `result` is empty. */
const REAL_OWNER_DISCOVERY_RESPONSE = {
    type: 'response',
    requestId: 'request-2',
    resultType: 'success',
    method: 'thread-owner-discovery',
    handledByClientId: 'f6811611-dc4b-41f3-8b99-44b2f541fa19',
    result: {}
};

/** A broadcast the router pushes when a client starts following a thread. */
const REAL_FOLLOWING_BROADCAST = {
    type: 'broadcast',
    method: 'thread-stream-following-changed',
    sourceClientId: 'f6811611-dc4b-41f3-8b99-44b2f541fa19',
    targetClientIds: ['assigned-client-id'],
    params: {
        conversationId: '019ff6f3-9f27-7983-b94b-2a67d19e5d94',
        hostId: 'local',
        following: true
    },
    version: 1
};

/** Replays recorded router frames and records exactly what Aiflow writes. */
class FakeRouter extends net.Socket {
    sent: Record<string, any>[] = [];
    private nextId = 1;

    override connect(_options: any): this {
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
        this.emit('close');
        return this;
    }

    /** Answers request `index` the way the real router does. */
    succeed(index: number, result: unknown, handledByClientId?: string): void {
        const request = this.sent[index];
        this.push_({
            type: 'response',
            requestId: request.requestId,
            resultType: 'success',
            method: request.method,
            handledByClientId,
            result
        });
    }

    fail(index: number, error: string): void {
        const request = this.sent[index];
        this.push_({
            type: 'response',
            requestId: request.requestId,
            resultType: 'error',
            method: request.method,
            error
        });
    }

    push_(message: unknown): void {
        this.emit('data', encodeFrame(message));
    }

    takeRequestId(): string {
        return `request-${this.nextId++}`;
    }
}

/** Reads a recorded frame without narrowing, so negative assertions stay possible. */
function frameAt(router: FakeRouter, index: number): any {
    return router.sent[index];
}

function makeClient(timeoutMs = 200): { client: CodexIpcClient; router: FakeRouter } {
    const router = new FakeRouter();
    const client = new CodexIpcClient({
        socketPath: '/tmp/fake-codex.sock',
        requestTimeoutMs: timeoutMs,
        createSocket: () => router,
        newRequestId: () => router.takeRequestId()
    });
    return { client, router };
}

async function connected(timeoutMs = 200): Promise<{ client: CodexIpcClient; router: FakeRouter }> {
    const { client, router } = makeClient(timeoutMs);
    const connecting = client.connect();
    await new Promise((r) => setImmediate(r));
    router.push_(REAL_INITIALIZE_RESPONSE);
    await connecting;
    return { client, router };
}

// MARK: - initialize, against the captured frames

test('the initialize request matches the real captured frame exactly', async () => {
    const { client, router } = makeClient();
    const connecting = client.connect();
    await new Promise((r) => setImmediate(r));

    assert.deepEqual(router.sent[0], REAL_INITIALIZE_REQUEST);
    assert.equal(router.sent[0].sourceClientId, INITIALIZING_CLIENT_ID);
    assert.equal(router.sent[0].params.clientType, CLIENT_TYPE);
    // The old, wrong envelope used `id`; the router requires `requestId`.
    assert.equal(frameAt(router, 0).id, undefined);

    router.push_(REAL_INITIALIZE_RESPONSE);
    assert.equal(await connecting, 'assigned-client-id');
    client.dispose();
});

test('the assigned client id is retained and reused as sourceClientId', async () => {
    const { client, router } = await connected();
    assert.equal(client.assignedClientId, 'assigned-client-id');
    assert.equal(client.isConnected, true);

    client.request('some-method', {}).catch(() => {});
    await new Promise((r) => setImmediate(r));

    assert.equal(router.sent[1].sourceClientId, 'assigned-client-id');
    client.dispose();
});

test('responses correlate by requestId, not arrival order', async () => {
    const { client, router } = await connected();

    const first = client.request('a', {});
    const second = client.request('b', {});
    await new Promise((r) => setImmediate(r));

    router.succeed(2, { which: 'second' });
    router.succeed(1, { which: 'first' });

    assert.deepEqual((await first).result, { which: 'first' });
    assert.deepEqual((await second).result, { which: 'second' });
    client.dispose();
});

test('a response for an unknown requestId is ignored', async () => {
    const { client, router } = await connected();
    const pending = client.request('a', {});
    await new Promise((r) => setImmediate(r));

    router.push_({
        type: 'response',
        requestId: 'not-a-request-we-sent',
        resultType: 'success',
        result: { bogus: true }
    });
    router.succeed(1, { real: true });

    assert.deepEqual((await pending).result, { real: true });
    client.dispose();
});

test('resultType error rejects with the router message', async () => {
    const { client, router } = await connected();
    const pending = client.request('thing', {});
    await new Promise((r) => setImmediate(r));
    router.fail(1, 'no client found for target');

    await assert.rejects(() => pending, /no client found for target/);
    client.dispose();
});

test('a request rejects on timeout', async () => {
    const { client } = await connected(60);
    await assert.rejects(() => client.request('never-answered', {}), CodexIpcTimeoutError);
    client.dispose();
});

test('pending requests reject when the connection drops', async () => {
    const { client, router } = await connected();
    const pending = client.request('thing', {});
    await new Promise((r) => setImmediate(r));

    router.emit('close');

    await assert.rejects(() => pending, /connection closed/);
    assert.equal(client.isConnected, false);
    client.dispose();
});

test('a real broadcast frame is emitted, not mistaken for a response', async () => {
    const { client, router } = await connected();
    const seen: any[] = [];
    client.on('broadcast', (message: unknown) => seen.push(message));

    router.push_(REAL_FOLLOWING_BROADCAST);

    assert.equal(seen.length, 1);
    assert.equal(seen[0].method, 'thread-stream-following-changed');
    assert.equal(seen[0].params.conversationId, '019ff6f3-9f27-7983-b94b-2a67d19e5d94');
    client.dispose();
});

// MARK: - owner discovery

test('owner discovery reads handledByClientId from the envelope', async () => {
    const { client, router } = await connected();
    const pending = client.discoverThreadOwner('019ff6f3-9f27-7983-b94b-2a67d19e5d94');
    await new Promise((r) => setImmediate(r));

    assert.equal(router.sent[1].method, 'thread-owner-discovery');
    assert.equal(router.sent[1].version, REQUEST_VERSIONS['thread-owner-discovery']);
    assert.deepEqual(router.sent[1].params, {
        hostId: 'local',
        conversationId: '019ff6f3-9f27-7983-b94b-2a67d19e5d94'
    });

    // The real router answers with an EMPTY result and names the owner in the envelope.
    router.push_(REAL_OWNER_DISCOVERY_RESPONSE);
    assert.equal(await pending, 'f6811611-dc4b-41f3-8b99-44b2f541fa19');
    client.dispose();
});

test('owner discovery rejects when the envelope names no owner', async () => {
    const { client, router } = await connected();
    const pending = client.discoverThreadOwner('conv-1');
    await new Promise((r) => setImmediate(r));
    router.succeed(1, {});

    await assert.rejects(() => pending, CodexIpcNoOwnerError);
    client.dispose();
});

// MARK: - targeting lives on the envelope

test('settings update targets the owner at the envelope level', async () => {
    const { client, router } = await connected();
    const pending = client.updateThreadSettings('owner-1', 'conv-1', {
        model: 'gpt-5.6-sol',
        effort: 'low'
    });
    await new Promise((r) => setImmediate(r));

    const frame = router.sent[1];
    assert.equal(frame.method, 'thread-follower-update-thread-settings');
    assert.equal(frame.version, REQUEST_VERSIONS['thread-follower-update-thread-settings']);
    assert.equal(frame.targetClientId, 'owner-1');
    // The exact follower payload: no targetClientId inside params.
    assert.deepEqual(frame.params, {
        conversationId: 'conv-1',
        threadSettings: { model: 'gpt-5.6-sol', effort: 'low' }
    });
    assert.equal(frameAt(router, 1).params.targetClientId, undefined);

    router.succeed(1, {});
    await pending;
    client.dispose();
});

test('start-turn targets the owner at the envelope level and keeps the exact prompt', async () => {
    const { client, router } = await connected();
    const prompt = 'AIFLOW_EXACT_IPC_PROBE. Reply with exactly AIFLOW_EXACT_IPC_OK.';
    const pending = client.startTurn('owner-1', 'conv-1', prompt, {
        model: 'gpt-5.6-sol',
        effort: 'low'
    });
    await new Promise((r) => setImmediate(r));

    const frame = router.sent[1];
    assert.equal(frame.method, 'thread-follower-start-turn');
    assert.equal(frame.version, REQUEST_VERSIONS['thread-follower-start-turn']);
    assert.equal(frame.targetClientId, 'owner-1');
    assert.equal(frame.params.targetClientId, undefined, 'must not leak into params');
    assert.equal(frame.params.conversationId, 'conv-1');
    assert.deepEqual(frame.params.turnStartParams.input, [
        { type: 'text', text: prompt, text_elements: [] }
    ]);
    assert.equal(frame.params.turnStartParams.model, 'gpt-5.6-sol');
    assert.equal(frame.params.turnStartParams.effort, 'low');
    assert.equal(frame.params.localTurnMetadata, null);
    assert.equal(frame.params.mcpAppModelContextAttachments, null);
    assert.ok(!JSON.stringify(frame).toLowerCase().includes('implementtodo'));

    router.succeed(1, {});
    await pending;
    client.dispose();
});

test('no follower request ever puts targetClientId inside params', async () => {
    const { client, router } = await connected();

    const ignore = (): void => {};
    client.updateThreadSettings('owner-1', 'c', { model: 'gpt-5.6-sol', effort: 'low' }).catch(ignore);
    client.startTurn('owner-1', 'c', 'p', { model: 'gpt-5.6-sol', effort: 'low' }).catch(ignore);
    client.interruptTurn('owner-1', 'c', 'turn-1').catch(ignore);
    await new Promise((r) => setImmediate(r));

    for (const frame of router.sent.slice(1)) {
        assert.equal(frame.params.targetClientId, undefined, frame.method);
        assert.equal(frame.targetClientId, 'owner-1', frame.method);
    }
    client.dispose();
});

// MARK: - interrupt uses the official user-stop semantics

test('interrupt sends mode and expectedTurnId at version 4', async () => {
    const { client, router } = await connected();
    const pending = client.interruptTurn('owner-1', 'conv-1', 'turn-7');
    await new Promise((r) => setImmediate(r));

    const frame = router.sent[1];
    assert.equal(frame.method, 'thread-follower-interrupt-turn');
    assert.equal(frame.version, 4, 'version 4 when an expected turn id is known');
    assert.equal(frame.targetClientId, 'owner-1');
    assert.deepEqual(frame.params, {
        conversationId: 'conv-1',
        mode: USER_STOP_MODE,
        expectedTurnId: 'turn-7'
    });
    assert.equal(frameAt(router, 1).params.turnId, undefined, 'the field is expectedTurnId, not turnId');

    router.succeed(1, {});
    await pending;
    client.dispose();
});

test('interrupt without an expected turn id drops to compatibility version 3', async () => {
    const { client, router } = await connected();
    const pending = client.interruptTurn('owner-1', 'conv-1');
    await new Promise((r) => setImmediate(r));

    const frame = router.sent[1];
    assert.equal(frame.version, 3, 'the extension itself uses 3 when expectedTurnId is absent');
    // No fabricated turn id.
    assert.deepEqual(frame.params, { conversationId: 'conv-1', mode: USER_STOP_MODE });
    assert.equal('expectedTurnId' in frame.params, false);

    router.succeed(1, {});
    await pending;
    client.dispose();
});

test('the request versions match the official extension table', () => {
    assert.equal(REQUEST_VERSIONS['thread-owner-discovery'], 1);
    assert.equal(REQUEST_VERSIONS['thread-follower-start-turn'], 1);
    assert.equal(REQUEST_VERSIONS['thread-follower-update-thread-settings'], 1);
    assert.equal(REQUEST_VERSIONS['thread-follower-interrupt-turn'], 4);
    assert.equal(REQUEST_VERSIONS['thread-follower-interrupt-turn-without-expected-turn'], 3);
});

test('timeoutMs, when sent, is a top-level envelope field', async () => {
    const { client, router } = await connected();
    client.request('m', { a: 1 }, { timeoutMs: 5000, targetClientId: 'owner-1' }).catch(() => {});
    await new Promise((r) => setImmediate(r));

    assert.equal(router.sent[1].timeoutMs, 5000);
    assert.deepEqual(router.sent[1].params, { a: 1 });
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
