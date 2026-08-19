import { strict as assert } from 'node:assert';
import { test } from 'node:test';
import {
    BRIDGE_HOST,
    BRIDGE_PORT,
    MAX_FRAME_BYTES,
    TOKEN_RELATIVE_PATH,
    LineBuffer,
    encodeCommand,
    initialState,
    parseEvent,
    reduce,
    statusLabel
} from '../protocol';

test('bridge targets loopback only', () => {
    assert.equal(BRIDGE_HOST, '127.0.0.1');
    assert.equal(BRIDGE_PORT, 47321);
    assert.notEqual(BRIDGE_HOST, '0.0.0.0');
});

// MARK: JSONL framing

test('line buffer splits complete lines', () => {
    const buffer = new LineBuffer();
    assert.deepEqual(buffer.append('{"type":"hello"}\n{"type":"snapshot"}\n'), [
        '{"type":"hello"}',
        '{"type":"snapshot"}'
    ]);
});

test('line buffer holds a partial line until the newline arrives', () => {
    const buffer = new LineBuffer();
    assert.deepEqual(buffer.append('{"type":"hel'), []);
    assert.deepEqual(buffer.append('lo"}\n'), ['{"type":"hello"}']);
});

test('line buffer reassembles a frame split across three chunks', () => {
    const buffer = new LineBuffer();
    assert.deepEqual(buffer.append('{"type":'), []);
    assert.deepEqual(buffer.append('"agent_mes'), []);
    assert.deepEqual(buffer.append('sage","message":"hi"}\n'), [
        '{"type":"agent_message","message":"hi"}'
    ]);
});

test('line buffer handles several frames plus a trailing partial in one chunk', () => {
    const buffer = new LineBuffer();
    const lines = buffer.append('{"type":"hello"}\n{"type":"run_status"}\n{"type":"partial');
    assert.deepEqual(lines, ['{"type":"hello"}', '{"type":"run_status"}']);
    assert.deepEqual(buffer.append('"}\n'), ['{"type":"partial"}']);
});

test('line buffer skips blank lines', () => {
    const buffer = new LineBuffer();
    assert.deepEqual(buffer.append('\n\n{"type":"hello"}\n'), ['{"type":"hello"}']);
});

// MARK: bounded framing

test('line buffer rejects an oversized frame with no newline', () => {
    const buffer = new LineBuffer(1024);
    assert.deepEqual(buffer.append('x'.repeat(512)), []);
    assert.equal(buffer.append('x'.repeat(1024)), null, 'exceeding the limit must reject');
    assert.equal(buffer.didOverflow, true);
});

test('line buffer stays rejected after overflow until reset', () => {
    const buffer = new LineBuffer(64);
    buffer.append('x'.repeat(200));
    assert.equal(buffer.append('{"type":"hello"}\n'), null);

    buffer.reset();
    assert.deepEqual(buffer.append('{"type":"hello"}\n'), ['{"type":"hello"}']);
});

test('many complete frames never trip the limit', () => {
    const buffer = new LineBuffer(128);
    for (let i = 0; i < 500; i += 1) {
        assert.notEqual(buffer.append('{"type":"hello"}\n'), null);
    }
    assert.equal(buffer.didOverflow, false);
});

// An oversized frame that arrives already newline-terminated would slip past a check that
// only measures the trailing remainder, since extracting it leaves nothing behind.

test('oversized complete frame in a single append is rejected', () => {
    const buffer = new LineBuffer(64);
    assert.equal(buffer.append('x'.repeat(70) + '\n'), null);
    assert.equal(buffer.didOverflow, true);
});

test('oversized frame completed by a later chunk is rejected', () => {
    const buffer = new LineBuffer(64);
    // Each chunk stays under the limit; only the assembled frame is oversized.
    assert.deepEqual(buffer.append('x'.repeat(40)), []);
    assert.deepEqual(buffer.append('x'.repeat(20)), []);
    assert.equal(buffer.append('x'.repeat(20) + '\n'), null);
    assert.equal(buffer.didOverflow, true);
});

test('no frames are returned from an append containing an oversized frame', () => {
    const buffer = new LineBuffer(64);
    // The good frame preceding the oversized one is discarded along with it.
    assert.equal(buffer.append('{"type":"ping"}\n' + 'x'.repeat(70) + '\n'), null);
});

test('frame exactly at the limit is accepted', () => {
    const buffer = new LineBuffer(64);
    const lines = buffer.append('x'.repeat(64) + '\n');
    assert.deepEqual(lines, ['x'.repeat(64)]);
    assert.equal(buffer.didOverflow, false);
});

test('several small frames in one append are accepted', () => {
    const buffer = new LineBuffer(64);
    assert.deepEqual(buffer.append('{"type":"ping"}\n{"type":"cancel"}\n'), [
        '{"type":"ping"}',
        '{"type":"cancel"}'
    ]);
    assert.equal(buffer.didOverflow, false);
});

test('the limit is measured in bytes, not characters', () => {
    // 30 emoji are 30 characters but 120 UTF-8 bytes.
    const buffer = new LineBuffer(64);
    assert.equal(buffer.append('😀'.repeat(30) + '\n'), null);
});

test('inbound frame limit is bounded and larger than the command limit', () => {
    // Events can carry a whole agent message, so the inbound ceiling is 1 MiB while Aiflow
    // caps inbound commands at 64 KiB.
    assert.equal(MAX_FRAME_BYTES, 1024 * 1024);
});

// MARK: parsing

test('parses a snapshot', () => {
    const event = parseEvent(
        '{"type":"snapshot","connected":true,"runState":"running","project":"ef","model":"terra","effort":"high","message":"working"}'
    );
    assert.ok(event);
    assert.equal(event.type, 'snapshot');
    assert.equal(event.runState, 'running');
    assert.equal(event.project, 'ef');
});

test('parses an agent message', () => {
    const event = parseEvent('{"type":"agent_message","message":"Done."}');
    assert.equal(event?.type, 'agent_message');
    assert.equal(event?.message, 'Done.');
});

test('rejects malformed and unknown messages', () => {
    assert.equal(parseEvent('{not json'), null);
    assert.equal(parseEvent(''), null);
    assert.equal(parseEvent('   '), null);
    assert.equal(parseEvent('[]'), null);
    assert.equal(parseEvent('"a string"'), null);
    assert.equal(parseEvent('{"type":"launch_codex"}'), null);
    assert.equal(parseEvent('{"message":"no type"}'), null);
});

// MARK: outbound command shapes

test('outbound cancel shape', () => {
    const line = encodeCommand({ type: 'cancel' });
    assert.equal(line, '{"type":"cancel"}\n');
    assert.ok(line.endsWith('\n'));
});

test('outbound approve and deny shapes carry the exact request id', () => {
    assert.equal(encodeCommand({ type: 'approve', requestId: 17 }), '{"type":"approve","requestId":17}\n');
    assert.equal(encodeCommand({ type: 'deny', requestId: 17 }), '{"type":"deny","requestId":17}\n');
    // id 0 is real: the live Codex App Server numbers approval requests from zero.
    assert.equal(encodeCommand({ type: 'approve', requestId: 0 }), '{"type":"approve","requestId":0}\n');
    assert.equal(
        encodeCommand({ type: 'approve', requestId: 'abc' }),
        '{"type":"approve","requestId":"abc"}\n'
    );
});

test('outbound answer keys answers by exact question id', () => {
    const line = encodeCommand({
        type: 'answer_question',
        requestId: 4,
        answers: { q1: 'a', q2: 'b' }
    });
    const parsed = JSON.parse(line) as { answers: Record<string, string> };
    assert.deepEqual(Object.keys(parsed.answers).sort(), ['q1', 'q2']);
});

test('commands cannot express execution parameters', () => {
    // The command type has no field for a path, sandbox, model, or shell command.
    const line = encodeCommand({ type: 'cancel' });
    for (const forbidden of ['repositoryPath', 'sandbox', 'model', 'command', 'danger']) {
        assert.ok(!line.includes(forbidden), `must not contain ${forbidden}`);
    }
});

// MARK: state reduction

test('snapshot rebuilds the whole view state', () => {
    const state = reduce(initialState(), {
        type: 'snapshot',
        connected: true,
        runState: 'running',
        project: 'ef',
        model: 'terra',
        effort: 'high',
        message: 'working on it'
    });

    assert.equal(state.connected, true);
    assert.equal(state.runState, 'running');
    assert.equal(state.project, 'ef');
    assert.equal(state.lastMessage, 'working on it');
    assert.equal(statusLabel(state), 'Running');
});

test('snapshot restores a pending approval so a reconnected client can answer', () => {
    const state = reduce(initialState(), {
        type: 'snapshot',
        connected: true,
        runState: 'waiting_for_approval',
        requestId: 9,
        kind: 'command_execution',
        summary: 'npm i'
    });

    assert.equal(state.pendingApproval?.requestId, 9);
    assert.equal(state.pendingApproval?.summary, 'npm i');
    assert.equal(statusLabel(state), 'Waiting for approval');
});

test('snapshot restores a pending question set', () => {
    const state = reduce(initialState(), {
        type: 'snapshot',
        connected: true,
        runState: 'waiting_for_input',
        requestId: 11,
        questions: [
            { id: 'api', header: 'API', question: 'Which?', options: [], isOther: false, isSecret: false }
        ]
    });

    assert.equal(state.pendingQuestion?.requestId, 11);
    assert.deepEqual(state.pendingQuestion?.questions.map((q) => q.id), ['api']);
});

test('approval then completion clears the pending request', () => {
    let state = initialState();
    state = reduce(state, { type: 'run_started', project: 'ef', runState: 'launching' });
    state = reduce(state, { type: 'run_status', runState: 'running' });
    state = reduce(state, { type: 'approval_requested', requestId: 3, summary: 'npm i' });
    assert.equal(state.pendingApproval?.requestId, 3);

    state = reduce(state, { type: 'run_completed', message: 'All done.' });
    assert.equal(state.runState, 'completed');
    assert.equal(state.pendingApproval, undefined);
    assert.equal(state.lastMessage, 'All done.');
});

test('an approval without a request id is ignored', () => {
    const state = reduce(initialState(), { type: 'approval_requested', summary: 'npm i' });
    assert.equal(state.pendingApproval, undefined);
});

test('run_cancelled and run_failed clear pending requests', () => {
    let cancelled = reduce(initialState(), { type: 'approval_requested', requestId: 1 });
    cancelled = reduce(cancelled, { type: 'run_cancelled' });
    assert.equal(cancelled.runState, 'cancelled');
    assert.equal(cancelled.pendingApproval, undefined);

    let failed = reduce(initialState(), { type: 'question_requested', requestId: 2, questions: [] });
    failed = reduce(failed, { type: 'run_failed', message: 'boom' });
    assert.equal(failed.runState, 'failed');
    assert.equal(failed.pendingQuestion, undefined);
    assert.equal(failed.lastMessage, 'boom');
});

test('file_open is a side effect, not view state', () => {
    const before = reduce(initialState(), { type: 'snapshot', runState: 'running' });
    const after = reduce(before, { type: 'file_open', path: '/repos/ef/a.swift' });
    assert.deepEqual(after, before);
});

test('status labels cover the disconnected and retrying cases', () => {
    assert.equal(statusLabel({ connected: false, runState: 'running' }), 'Disconnected');
    assert.equal(statusLabel({ connected: true, runState: 'retrying' }), 'Retrying');
    assert.equal(statusLabel({ connected: true, runState: 'cancelling' }), 'Cancelling');
});

// MARK: auth command shape

test('outbound auth command carries the token and nothing else', () => {
    const line = encodeCommand({ type: 'auth', token: 'deadbeef' });
    assert.equal(line, '{"type":"auth","token":"deadbeef"}\n');
});

test('token path points at Aiflow application support state', () => {
    assert.equal(TOKEN_RELATIVE_PATH, 'Library/Application Support/Aiflow/bridge-token');
});
