import { strict as assert } from 'node:assert';
import { test } from 'node:test';
import {
    OfficialCodexWorker,
    WorkerError,
    isProvisionalConversationId,
    turnIdFromStartResponse
} from '../codexIpc/worker';
import { SessionRecord } from '../codexIpc/sessionWatcher';
import {
    ThreadResolutionError,
    conversationIdFromBroadcast,
    createFreshThread
} from '../codexIpc/threadResolver';

const CONV = '01a01c88-87fe-71d0-9d34-ad555722dc2a';

/** Records the exact IPC calls the worker makes, in order. */
class FakeIpc {
    calls: { op: string; args: unknown[] }[] = [];
    owner = 'client-codex-owner';
    failSettings = false;
    failStart = false;
    failOwner = false;

    async discoverThreadOwner(conversationId: string): Promise<string> {
        this.calls.push({ op: 'discoverThreadOwner', args: [conversationId] });
        if (this.failOwner) {
            throw new Error('no client found');
        }
        return this.owner;
    }
    async updateThreadSettings(target: string, conv: string, execution: unknown): Promise<void> {
        this.calls.push({ op: 'updateThreadSettings', args: [target, conv, execution] });
        if (this.failSettings) {
            throw new Error('settings rejected');
        }
    }
    startTurnResult: unknown = {};
    async startTurn(
        target: string, conv: string, prompt: string, execution: unknown
    ): Promise<unknown> {
        this.calls.push({ op: 'startTurn', args: [target, conv, prompt, execution] });
        if (this.failStart) {
            throw new Error('start rejected');
        }
        return this.startTurnResult;
    }
    async interruptTurn(target: string, conv: string, turnId?: string): Promise<void> {
        this.calls.push({ op: 'interruptTurn', args: [target, conv, turnId] });
    }
}

/** Feeds pre-scripted session batches, one per poll. */
function scriptedTail(batches: SessionRecord[][]): { readNew: () => SessionRecord[] } {
    let index = 0;
    return {
        readNew: (): SessionRecord[] => (index < batches.length ? batches[index++] : [])
    };
}

function started(turnId: string): SessionRecord {
    return { type: 'event_msg', payload: { type: 'task_started', turn_id: turnId } };
}
function complete(turnId: string, message: string): SessionRecord {
    return {
        type: 'event_msg',
        payload: { type: 'task_complete', turn_id: turnId, last_agent_message: message }
    };
}

function makeWorker(
    ipc: FakeIpc,
    batches: SessionRecord[][],
    conversationId: string = CONV
): OfficialCodexWorker {
    return new OfficialCodexWorker({
        ipc: ipc as never,
        resolveConversation: async () => conversationId,
        findSession: () => '/fake/session.jsonl',
        // The worker drains pre-existing history before starting the turn, so the first
        // batch it reads is never part of this run. Model that with a leading empty batch.
        createTail: () => scriptedTail([[], ...batches]),
        // Yield a real macrotask: an await of an already-resolved promise would starve timers.
        delay: () => new Promise<void>((resolve) => setTimeout(resolve, 0)),
        now: () => Date.now()
    });
}

const REQUEST = {
    runId: 'run-1',
    workspacePath: '/repos/demo',
    prompt: 'Report the current branch. Do not modify files.',
    model: 'sol',
    effort: 'low'
};

test('settings are applied and acknowledged before the turn starts', async () => {
    const ipc = new FakeIpc();
    const worker = makeWorker(ipc, [[started('turn-1')], [complete('turn-1', 'done')]]);

    await worker.run(REQUEST);

    const ops = ipc.calls.map((c) => c.op);
    const settingsIndex = ops.indexOf('updateThreadSettings');
    const startIndex = ops.indexOf('startTurn');

    assert.ok(settingsIndex >= 0 && startIndex >= 0);
    assert.ok(settingsIndex < startIndex, 'settings must precede start-turn');
});

test('the same model and effort go to both settings and start-turn', async () => {
    const ipc = new FakeIpc();
    const worker = makeWorker(ipc, [[started('turn-1')], [complete('turn-1', 'ok')]]);

    await worker.run(REQUEST);

    const settings = ipc.calls.find((c) => c.op === 'updateThreadSettings');
    const start = ipc.calls.find((c) => c.op === 'startTurn');
    const expected = { model: 'gpt-5.6-sol', effort: 'low' };

    assert.deepEqual(settings?.args[2], expected);
    assert.deepEqual(start?.args[3], expected);
});

test('the exact prompt text is submitted unchanged', async () => {
    const ipc = new FakeIpc();
    const worker = makeWorker(ipc, [[started('turn-1')], [complete('turn-1', 'ok')]]);

    await worker.run(REQUEST);

    const start = ipc.calls.find((c) => c.op === 'startTurn');
    assert.equal(start?.args[2], REQUEST.prompt);
});

test('fresh-thread bootstrap resolves before owner discovery and runs once per worker turn', async () => {
    const ipc = new FakeIpc();
    let bootstrapCalls = 0;
    const worker = new OfficialCodexWorker({
        ipc: ipc as never,
        resolveConversation: async (request) => {
            bootstrapCalls += 1;
            assert.equal(request.prompt, REQUEST.prompt);
            ipc.calls.push({ op: 'bootstrapFreshThread', args: [request.workspacePath] });
            return CONV;
        },
        findSession: () => '/fake/session.jsonl',
        createTail: () => scriptedTail([[], [started('turn-1')], [complete('turn-1', 'ok')]]),
        delay: () => new Promise<void>((resolve) => setTimeout(resolve, 0)),
        now: () => Date.now()
    });

    await worker.run(REQUEST);

    assert.equal(bootstrapCalls, 1);
    const ops = ipc.calls.map((call) => call.op);
    assert.ok(ops.indexOf('bootstrapFreshThread') < ops.indexOf('discoverThreadOwner'));
    assert.ok(ops.indexOf('discoverThreadOwner') < ops.indexOf('updateThreadSettings'));
    assert.ok(ops.indexOf('updateThreadSettings') < ops.indexOf('startTurn'));
});

test('a rejected settings update fails closed and never starts a turn', async () => {
    const ipc = new FakeIpc();
    ipc.failSettings = true;
    const worker = makeWorker(ipc, [[started('turn-1')]]);

    await assert.rejects(
        () => worker.run(REQUEST),
        (error: WorkerError) => error.code === 'settings_rejected'
    );
    assert.ok(!ipc.calls.some((c) => c.op === 'startTurn'), 'no turn may start');
});

test('a missing thread owner is a typed failure', async () => {
    const ipc = new FakeIpc();
    ipc.failOwner = true;
    const worker = makeWorker(ipc, [[]]);

    await assert.rejects(
        () => worker.run(REQUEST),
        (error: WorkerError) => error.code === 'thread_unavailable'
    );
});

test('a provisional conversation id is never dispatched to', async () => {
    const ipc = new FakeIpc();
    const worker = makeWorker(ipc, [[]], 'client-new-thread:pending');

    await assert.rejects(
        () => worker.run(REQUEST),
        (error: WorkerError) => error.code === 'thread_unavailable'
    );
    assert.deepEqual(ipc.calls, [], 'nothing is sent for a provisional id');
});

test('completion is reported with the final agent message', async () => {
    const ipc = new FakeIpc();
    const worker = makeWorker(ipc, [[started('turn-1')], [complete('turn-1', 'AIFLOW_OK')]]);

    const result = await worker.run(REQUEST);

    assert.equal(result.outcome, 'completed');
    assert.equal(result.turnId, 'turn-1');
    assert.equal(result.finalMessage, 'AIFLOW_OK');
});

test('a completion for an unrelated turn does not finish this run', async () => {
    const ipc = new FakeIpc();
    // Another Codex run completes while ours is still working.
    const worker = makeWorker(ipc, [
        [started('turn-ours')],
        [complete('turn-someone-else', 'not ours')],
        [complete('turn-ours', 'ours')]
    ]);

    const result = await worker.run(REQUEST);
    assert.equal(result.turnId, 'turn-ours');
    assert.equal(result.finalMessage, 'ours');
});

test('an interrupted turn is reported as interrupted, not failed', async () => {
    const ipc = new FakeIpc();
    const worker = makeWorker(ipc, [
        [started('turn-1')],
        [{ type: 'event_msg', payload: { type: 'turn_aborted', turn_id: 'turn-1' } }]
    ]);

    assert.equal((await worker.run(REQUEST)).outcome, 'interrupted');
});

test('a failed turn carries the error message', async () => {
    const ipc = new FakeIpc();
    const worker = makeWorker(ipc, [
        [started('turn-1')],
        [{ type: 'event_msg', payload: { type: 'task_failed', turn_id: 'turn-1', message: 'boom' } }]
    ]);

    const result = await worker.run(REQUEST);
    assert.equal(result.outcome, 'failed');
    assert.equal(result.errorMessage, 'boom');
});

test('a turn that never finishes times out cleanly', async () => {
    const ipc = new FakeIpc();
    let clock = 0;
    const worker = new OfficialCodexWorker({
        ipc: ipc as never,
        resolveConversation: async () => CONV,
        findSession: () => '/fake/session.jsonl',
        createTail: () => scriptedTail([[], [started('turn-1')]]),
        delay: async () => {
            clock += 1000;
        },
        now: () => clock
    });

    await assert.rejects(
        () => worker.run(REQUEST, { completionTimeoutMs: 3000 }),
        (error: WorkerError) => error.code === 'timed_out'
    );
});

test('worker events report thread then turn, both carrying the run id', async () => {
    const ipc = new FakeIpc();
    const worker = makeWorker(ipc, [[started('turn-1')], [complete('turn-1', 'ok')]]);
    const events: string[] = [];

    await worker.run(REQUEST, {
        onEvent: (event) => {
            events.push(event.type);
            assert.equal((event as { runId: string }).runId, 'run-1');
        }
    });

    assert.ok(events.indexOf('thread') < events.indexOf('turn'));
});

// MARK: cancellation

test('cancel interrupts this run own conversation and turn', async () => {
    const ipc = new FakeIpc();
    const worker = makeWorker(ipc, [[started('turn-1')], [], [complete('turn-1', 'stopped')]]);
    const cancels: Promise<boolean>[] = [];

    // Cancel exactly when the turn id becomes known, so the run is provably still in flight.
    await worker.run(REQUEST, {
        onEvent: (event) => {
            if (event.type === 'turn') {
                cancels.push(worker.cancel(REQUEST.runId));
            }
        }
    });
    await Promise.all(cancels);

    const interrupt = ipc.calls.find((c) => c.op === 'interruptTurn');
    assert.ok(interrupt, 'an interrupt was sent');
    assert.equal(interrupt?.args[1], CONV, 'the exact conversation');
    assert.equal(interrupt?.args[2], 'turn-1', 'the exact turn');
});

test('cancelling an unknown or stale run does nothing', async () => {
    const ipc = new FakeIpc();
    const worker = makeWorker(ipc, [[started('turn-1')], [complete('turn-1', 'ok')]]);

    assert.equal(await worker.cancel('run-that-never-ran'), false);
    assert.ok(!ipc.calls.some((c) => c.op === 'interruptTurn'));

    await worker.run(REQUEST);
    // The run has finished; a late cancel must not interrupt anything.
    assert.equal(await worker.cancel('run-1'), false);
});

test('cancel is idempotent', async () => {
    const ipc = new FakeIpc();
    const worker = makeWorker(ipc, [[started('turn-1')], [], [], [complete('turn-1', 'x')]]);
    const cancels: Promise<boolean>[] = [];

    await worker.run(REQUEST, {
        onEvent: (event) => {
            if (event.type === 'turn') {
                cancels.push(worker.cancel(REQUEST.runId));
                cancels.push(worker.cancel(REQUEST.runId));
            }
        }
    });
    const results = await Promise.all(cancels);

    assert.deepEqual(results, [true, true]);
    assert.equal(
        ipc.calls.filter((c) => c.op === 'interruptTurn').length,
        1,
        'a repeated cancel must not send a second interrupt'
    );
});

test('cancel during bootstrap latches and prevents the real prompt from starting', async () => {
    const ipc = new FakeIpc();
    let finishBootstrap!: (conversationId: string) => void;
    const bootstrap = new Promise<string>((resolve) => {
        finishBootstrap = resolve;
    });
    const worker = new OfficialCodexWorker({
        ipc: ipc as never,
        resolveConversation: async () => bootstrap,
        findSession: () => '/fake/session.jsonl',
        createTail: () => scriptedTail([[], [started('real')], [complete('real', 'should-not-run')]])
    });

    const run = worker.run(REQUEST);
    await Promise.resolve();
    assert.equal(await worker.cancel(REQUEST.runId), true);
    assert.equal(await worker.cancel(REQUEST.runId), true, 'bootstrap cancellation is idempotent');
    assert.equal(worker.activeHandle, undefined, 'no conversation exists during bootstrap');

    finishBootstrap(CONV);
    const result = await run;

    assert.equal(result.outcome, 'interrupted');
    assert.ok(!ipc.calls.some((call) => call.op === 'startTurn'));
    assert.ok(!ipc.calls.some((call) => call.args.includes(REQUEST.prompt)));
});

test('a stale cancel does not affect a run that is still bootstrapping', async () => {
    const ipc = new FakeIpc();
    let finishBootstrap!: (conversationId: string) => void;
    const bootstrap = new Promise<string>((resolve) => {
        finishBootstrap = resolve;
    });
    const worker = new OfficialCodexWorker({
        ipc: ipc as never,
        resolveConversation: async () => bootstrap,
        findSession: () => '/fake/session.jsonl',
        createTail: () => scriptedTail([[], [started('real')], [complete('real', 'ok')]]),
        delay: () => new Promise<void>((resolve) => setTimeout(resolve, 0)),
        now: () => Date.now()
    });

    const run = worker.run(REQUEST);
    await Promise.resolve();
    assert.equal(await worker.cancel('stale-run'), false);
    finishBootstrap(CONV);

    assert.equal((await run).outcome, 'completed');
    assert.ok(!ipc.calls.some((call) => call.op === 'interruptTurn'));
});

// MARK: fresh-thread correlation

test('provisional ids are recognised', () => {
    assert.equal(isProvisionalConversationId('client-new-thread:abc'), true);
    assert.equal(isProvisionalConversationId(CONV), false);
    assert.equal(isProvisionalConversationId(undefined), false);
});

test('conversation ids are read from a broadcast in either shape', () => {
    assert.equal(conversationIdFromBroadcast({ params: { conversationId: 'a' } }), 'a');
    assert.equal(conversationIdFromBroadcast({ params: { thread_id: 'b' } }), 'b');
    assert.equal(conversationIdFromBroadcast({ conversationId: 'c' }), 'c');
    assert.equal(conversationIdFromBroadcast({ params: {} }), undefined);
    assert.equal(conversationIdFromBroadcast(null), undefined);
});

/** Drives createFreshThread with scripted broadcasts. */
function freshThreadHarness(script: {
    before?: string[];
    afterOpen?: string[];
}): { run: () => Promise<string>; opened: () => number } {
    let listener: ((message: unknown) => void) | undefined;
    let openCount = 0;

    const deps = {
        onBroadcast: (l: (message: unknown) => void) => {
            listener = l;
            for (const id of script.before ?? []) {
                l({ params: { conversationId: id } });
            }
            return (): void => {
                listener = undefined;
            };
        },
        openNewPanel: async (): Promise<void> => {
            openCount += 1;
            for (const id of script.afterOpen ?? []) {
                listener?.({ params: { conversationId: id } });
            }
        },
        delay: async (): Promise<void> => {},
        now: ((): (() => number) => {
            let t = 0;
            return () => (t += 100);
        })()
    };

    return { run: () => createFreshThread(deps), opened: () => openCount };
}

test('a freshly created conversation is selected', async () => {
    const harness = freshThreadHarness({ afterOpen: [CONV] });
    assert.equal(await harness.run(), CONV);
    assert.equal(harness.opened(), 1);
});

test('an existing unrelated conversation is never selected', async () => {
    const existing = '01a0aaaa-1111-2222-3333-444444444444';
    const harness = freshThreadHarness({ before: [existing], afterOpen: [] });

    await assert.rejects(() => harness.run(), ThreadResolutionError);
});

test('a fresh conversation is chosen even when unrelated ones are already open', async () => {
    const existing = '01a0aaaa-1111-2222-3333-444444444444';
    const harness = freshThreadHarness({ before: [existing], afterOpen: [CONV] });

    assert.equal(await harness.run(), CONV);
});

test('a provisional id alone is not accepted as the conversation', async () => {
    const harness = freshThreadHarness({ afterOpen: ['client-new-thread:pending'] });

    await assert.rejects(
        () => harness.run(),
        (error: ThreadResolutionError) =>
            error.code === 'timeout' && /never reported a real conversation id/.test(error.message)
    );
});

test('a provisional id followed by a real one resolves to the real one', async () => {
    const harness = freshThreadHarness({ afterOpen: ['client-new-thread:pending', CONV] });
    assert.equal(await harness.run(), CONV);
});

test('a timeout fails cleanly instead of picking some other thread', async () => {
    const other = '01a0bbbb-1111-2222-3333-444444444444';
    const harness = freshThreadHarness({ before: [other] });

    await assert.rejects(
        () => harness.run(),
        (error: ThreadResolutionError) => error.code === 'timeout'
    );
});

// MARK: ordering and turn-id source

test('the bootstrapped session is opened and drained before the real turn starts', async () => {
    const ipc = new FakeIpc();
    const worker = new OfficialCodexWorker({
        ipc: ipc as never,
        resolveConversation: async () => CONV,
        findSession: () => {
            ipc.calls.push({ op: 'findSession', args: [] });
            return '/fake/session.jsonl';
        },
        createTail: () =>
            scriptedTail([
                [started('bootstrap'), complete('bootstrap', 'bootstrap')],
                [started('turn-1')],
                [complete('turn-1', 'ok')]
            ]),
        delay: () => new Promise<void>((resolve) => setTimeout(resolve, 0)),
        now: () => Date.now()
    });

    await worker.run(REQUEST);

    const ops = ipc.calls.map((c) => c.op);
    const sessionIndex = ops.indexOf('findSession');
    const startIndex = ops.indexOf('startTurn');

    assert.ok(startIndex >= 0 && sessionIndex >= 0, 'both steps happened');
    assert.ok(
        sessionIndex < startIndex,
        `session lookup must precede start-turn, got ${JSON.stringify(ops)}`
    );
});

test('the turn id from the start-turn response is preferred over inference', async () => {
    const ipc = new FakeIpc();
    ipc.startTurnResult = { result: { turn: { id: 'turn-from-response' } } };
    // The session also reports a different turn starting; the response must win.
    const worker = makeWorker(ipc, [
        [started('turn-from-some-other-run')],
        [complete('turn-from-response', 'authoritative')]
    ]);

    const result = await worker.run(REQUEST);

    assert.equal(result.turnId, 'turn-from-response');
    assert.equal(result.finalMessage, 'authoritative');
});

test('turn ids are read from several plausible response shapes', () => {
    assert.equal(turnIdFromStartResponse({ result: { turn: { id: 'a' } } }), 'a');
    assert.equal(turnIdFromStartResponse({ result: { turnId: 'b' } }), 'b');
    assert.equal(turnIdFromStartResponse({ turn: { id: 'c' } }), 'c');
    assert.equal(turnIdFromStartResponse({ result: {} }), undefined);
    assert.equal(turnIdFromStartResponse(undefined), undefined);
});

test('without a turn id the fallback ignores bootstrap history and selects the real turn', async () => {
    const ipc = new FakeIpc();
    ipc.startTurnResult = {};
    const worker = new OfficialCodexWorker({
        ipc: ipc as never,
        resolveConversation: async () => CONV,
        findSession: () => '/fake/session.jsonl',
        createTail: () =>
            scriptedTail([
                [started('bootstrap-turn'), complete('bootstrap-turn', 'BOOTSTRAP_RESULT')],
                [started('real-turn')],
                [complete('real-turn', 'REAL_RESULT')]
            ]),
        delay: () => new Promise<void>((resolve) => setTimeout(resolve, 0)),
        now: () => Date.now()
    });

    const result = await worker.run(REQUEST);
    assert.equal(result.turnId, 'real-turn');
    assert.equal(result.finalMessage, 'REAL_RESULT');
});

test('a failed run leaves no active handle for a later cancel', async () => {
    const ipc = new FakeIpc();
    ipc.failSettings = true;
    const worker = makeWorker(ipc, [[started('turn-1')]]);

    await assert.rejects(() => worker.run(REQUEST));

    assert.equal(worker.activeHandle, undefined);
    assert.equal(await worker.cancel(REQUEST.runId), false, 'nothing of ours remains to cancel');
});
