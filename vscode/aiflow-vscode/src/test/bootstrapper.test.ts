import { strict as assert } from 'node:assert';
import { test } from 'node:test';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import {
    BOOTSTRAP_COMMAND,
    BootstrapError,
    BootstrapDeps,
    SessionFileIdentity,
    bootstrapArgument,
    bootstrapComment,
    bootstrapFreshThread,
    generateBootstrapNonce,
    readSessionBounded
} from '../codexIpc/bootstrapper';
import { SessionRecord } from '../codexIpc/sessionWatcher';

const NONCE = '8038f6ae';
const CONVERSATION = '01a01ce8-26ec-7a03-af97-7e4bf1196de5';
const TURN = '01a01ce8-27dc-7f01-ad49-76d8ce89f576';
const REPOSITORY = '/tmp/aiflow-target';
const BOOTSTRAP_FILE = '/tmp/aiflow-bootstrap-8038f6ae.txt';

function identity(size: number, mtimeMs = 1): SessionFileIdentity {
    return { size, mtimeMs, ino: size, dev: 1 };
}

function sessionRecords(
    cwd = REPOSITORY,
    complete = true,
    writableRoots?: string[]
): SessionRecord[] {
    const records: SessionRecord[] = [
        { type: 'session_meta', payload: { id: CONVERSATION } },
        { type: 'event_msg', payload: { type: 'user_message', text: `AIFLOW_BOOTSTRAP_OK_${NONCE}` } },
        {
            type: 'turn_context',
            payload: {
                turn_id: TURN,
                cwd,
                approval_policy: 'on-request',
                approvals_reviewer: 'user',
                sandbox_policy: { type: 'workspace-write', writable_roots: writableRoots }
            }
        }
    ];
    if (complete) {
        records.push({
            type: 'event_msg',
            payload: {
                type: 'task_complete',
                turn_id: TURN,
                last_agent_message: `AIFLOW_BOOTSTRAP_OK_${NONCE}`
            }
        });
    }
    return records;
}

function harness(
    after: Map<string, SessionFileIdentity>,
    records: Map<string, SessionRecord[]>,
    overrides: Partial<BootstrapDeps> = {}
): {
    deps: BootstrapDeps;
    command?: { name: string; argument: unknown };
    removed: string[];
} {
    const before = new Map<string, SessionFileIdentity>([
        ['/sessions/old.jsonl', identity(10)]
    ]);
    let command: { name: string; argument: unknown } | undefined;
    let afterCommand = false;
    const removed: string[] = [];
    const deps: BootstrapDeps = {
        runCommand: async (name, argument) => {
            command = { name, argument };
            afterCommand = true;
        },
        snapshotSessionFiles: () => (afterCommand ? after : before),
        readSession: (file) => records.get(file) ?? [],
        writeTempFile: () => {},
        removeTempFile: (file) => removed.push(file),
        tempFilePath: () => BOOTSTRAP_FILE,
        newNonce: () => NONCE,
        canonicalPath: (value) => value.replace('/private/tmp', '/tmp'),
        delay: async () => {},
        now: (() => {
            let time = 0;
            return () => (time += 100);
        })(),
        ...overrides
    };
    return {
        deps,
        get command() {
            return command;
        },
        removed
    };
}

test('bootstrap comment and payload are synthetic and contain no real prompt', () => {
    const realPrompt = 'AIFLOW_REAL_USER_PROMPT_SHOULD_NEVER_BE_HERE';
    const comment = bootstrapComment(NONCE);
    const argument = bootstrapArgument(BOOTSTRAP_FILE, REPOSITORY, NONCE);

    assert.match(comment, /AIFLOW SESSION BOOTSTRAP/);
    assert.ok(!comment.includes(realPrompt));
    assert.equal(argument.fileName, BOOTSTRAP_FILE);
    assert.equal(argument.cwd, REPOSITORY);
    assert.equal(argument.line, 1);
    assert.equal(argument.comment, comment);
    assert.equal(BOOTSTRAP_COMMAND, 'chatgpt.implementTodo');
});

test('production nonce generation is cryptographically random and unique', () => {
    const first = generateBootstrapNonce();
    const second = generateBootstrapNonce();
    assert.match(first, /^[0-9a-f]{32}$/);
    assert.match(second, /^[0-9a-f]{32}$/);
    assert.notEqual(first, second);
});

test('bootstrap selects only a changed/new session containing its nonce', async () => {
    const unrelated = '/sessions/unrelated.jsonl';
    const correct = '/sessions/new.jsonl';
    const h = harness(
        new Map([
            ['/sessions/old.jsonl', identity(10)],
            [unrelated, identity(20)],
            [correct, identity(30)]
        ]),
        new Map([
            [unrelated, [{ type: 'session_meta', payload: { id: 'unrelated' } }]],
            [correct, sessionRecords()]
        ])
    );

    const result = await bootstrapFreshThread(REPOSITORY, h.deps, {
        discoveryTimeoutMs: 500,
        completionTimeoutMs: 500,
        pollIntervalMs: 1
    });

    assert.equal(result.conversationId, CONVERSATION);
    assert.equal(result.bootstrapTurnId, TURN);
    assert.equal(result.sessionFile, correct);
    assert.deepEqual(h.command, {
        name: BOOTSTRAP_COMMAND,
        argument: bootstrapArgument(BOOTSTRAP_FILE, REPOSITORY, NONCE)
    });
    assert.deepEqual(h.removed, [BOOTSTRAP_FILE]);
});

test('pre-existing sessions and stale nonce content cannot satisfy a bootstrap', async () => {
    const old = '/sessions/old.jsonl';
    const h = harness(
        new Map([[old, identity(10, 1)]]),
        new Map([[old, sessionRecords()]])
    );

    await assert.rejects(
        () => bootstrapFreshThread(REPOSITORY, h.deps, { discoveryTimeoutMs: 100, pollIntervalMs: 10 }),
        (error: BootstrapError) => error.code === 'conversation_not_found'
    );
    assert.deepEqual(h.removed, [BOOTSTRAP_FILE]);
});

test('a changed pre-existing session is rejected even when it contains the nonce', async () => {
    const old = '/sessions/old.jsonl';
    const h = harness(
        new Map([[old, identity(99, 2)]]),
        new Map([[old, sessionRecords()]])
    );

    await assert.rejects(
        () => bootstrapFreshThread(REPOSITORY, h.deps, { discoveryTimeoutMs: 100, pollIntervalMs: 10 }),
        (error: BootstrapError) => error.code === 'conversation_not_found'
    );
    assert.deepEqual(h.removed, [BOOTSTRAP_FILE]);
});

test('a session without the expected completion marker does not complete the bootstrap', async () => {
    const candidate = '/sessions/new.jsonl';
    const h = harness(
        new Map([[candidate, identity(30)]]),
        new Map([[candidate, sessionRecords(REPOSITORY, false)]])
    );

    await assert.rejects(
        () =>
            bootstrapFreshThread(REPOSITORY, h.deps, {
                discoveryTimeoutMs: 100,
                completionTimeoutMs: 100,
                pollIntervalMs: 10
            }),
        (error: BootstrapError) => error.code === 'bootstrap_incomplete'
    );
    assert.deepEqual(h.removed, [BOOTSTRAP_FILE]);
});

test('canonical /tmp and /private/tmp cwd spellings are equivalent', async () => {
    const candidate = '/sessions/new.jsonl';
    const h = harness(
        new Map([[candidate, identity(30)]]),
        new Map([[candidate, sessionRecords('/private/tmp/aiflow-target')]])
    );

    const result = await bootstrapFreshThread('/private/tmp/aiflow-target', h.deps, {
        discoveryTimeoutMs: 100,
        completionTimeoutMs: 100,
        pollIntervalMs: 1
    });
    assert.equal(result.conversationId, CONVERSATION);
});

test('wrong cwd is rejected and the temp file is removed', async () => {
    const candidate = '/sessions/new.jsonl';
    const h = harness(
        new Map([[candidate, identity(30)]]),
        new Map([[candidate, sessionRecords('/tmp/aiflow-other')]])
    );

    await assert.rejects(
        () => bootstrapFreshThread(REPOSITORY, h.deps, { discoveryTimeoutMs: 100, pollIntervalMs: 1 }),
        (error: BootstrapError) => error.code === 'wrong_workspace'
    );
    assert.deepEqual(h.removed, [BOOTSTRAP_FILE]);
});

test('bootstrap rejects a stale writable root from another project', async () => {
    const candidate = '/sessions/new.jsonl';
    const h = harness(
        new Map([[candidate, identity(30)]]),
        new Map([[candidate, sessionRecords(REPOSITORY, true, [
            '/tmp/aiflow-acceptance',
            '/tmp'
        ])]])
    );

    await assert.rejects(
        () => bootstrapFreshThread(REPOSITORY, h.deps, {
            discoveryTimeoutMs: 100,
            completionTimeoutMs: 100,
            pollIntervalMs: 1
        }),
        (error: BootstrapError) => error.code === 'workspace_isolation_unavailable'
    );
    assert.deepEqual(h.removed, [BOOTSTRAP_FILE]);
});

test('bootstrap preserves exact workspace and system temporary roots', async () => {
    const candidate = '/sessions/new.jsonl';
    const h = harness(
        new Map([[candidate, identity(30)]]),
        new Map([[candidate, sessionRecords(REPOSITORY, true, [
            REPOSITORY,
            '/private/tmp'
        ])]])
    );

    const result = await bootstrapFreshThread(REPOSITORY, h.deps, {
        discoveryTimeoutMs: 100,
        completionTimeoutMs: 100,
        pollIntervalMs: 1
    });
    assert.equal(result.conversationId, CONVERSATION);
});

test('command failure still cleans up the Aiflow-owned temp file', async () => {
    const h = harness(new Map(), new Map(), {
        runCommand: async () => {
            throw new Error('synthetic command failure');
        }
    });

    await assert.rejects(
        () => bootstrapFreshThread(REPOSITORY, h.deps),
        (error: BootstrapError) => error.code === 'command_failed'
    );
    assert.deepEqual(h.removed, [BOOTSTRAP_FILE]);
});

test('a user source path cannot be used as the bootstrap file', async () => {
    let commandCalled = false;
    const h = harness(new Map(), new Map(), {
        tempFilePath: () => `${REPOSITORY}/user-source.ts`,
        runCommand: async () => {
            commandCalled = true;
        }
    });

    await assert.rejects(
        () => bootstrapFreshThread(REPOSITORY, h.deps),
        (error: BootstrapError) => error.code === 'wrong_workspace'
    );
    assert.equal(commandCalled, false);
    assert.deepEqual(h.removed, []);
});

test('session reads enforce a byte ceiling', () => {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'aiflow-bootstrap-test-'));
    const file = path.join(directory, 'oversized.jsonl');
    try {
        fs.writeFileSync(file, '{"type":"session_meta"}\n'.repeat(4));
        assert.deepEqual(readSessionBounded(file, 8), []);
    } finally {
        fs.rmSync(directory, { recursive: true, force: true });
    }
});

test('a missing candidate times out without reading historical sessions', async () => {
    let reads = 0;
    const h = harness(new Map(), new Map(), {
        readSession: () => {
            reads += 1;
            return [];
        },
        now: (() => {
            let time = 0;
            return () => (time += 100);
        })(),
        delay: async () => {}
    });

    await assert.rejects(
        () => bootstrapFreshThread(REPOSITORY, h.deps, { discoveryTimeoutMs: 250, pollIntervalMs: 10 }),
        (error: BootstrapError) => error.code === 'conversation_not_found'
    );
    assert.equal(reads, 0);
    assert.deepEqual(h.removed, [BOOTSTRAP_FILE]);
});
