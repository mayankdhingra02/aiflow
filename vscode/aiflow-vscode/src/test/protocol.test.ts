import { strict as assert } from 'node:assert';
import { test } from 'node:test';
import {
    AiflowState,
    BRIDGE_HOST,
    BRIDGE_PORT,
    MAX_FRAME_BYTES,
    TOKEN_RELATIVE_PATH,
    LineBuffer,
    admitRun,
    parseExecutionRequest,
    parseFollowupExecutionRequest,
    encodeCommand,
    initialState,
    parseEvent,
    reduce,
    statusLabel,
    terminalEvent
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

// MARK: v2 execution requests

test('a well-formed execution request is accepted', () => {
    const request = parseExecutionRequest({
        type: 'execute_run',
        runId: 'run-1',
        workspacePath: '/repos/demo',
        prompt: 'Report the branch.',
        model: 'sol',
        effort: 'low'
    });

    assert.deepEqual(request, {
        runId: 'run-1',
        workspacePath: '/repos/demo',
        prompt: 'Report the branch.',
        model: 'sol',
        effort: 'low'
    });
});

test('an execution request without a run id is refused', () => {
    // Without a run id a completion could be attributed to the wrong Aiflow job.
    assert.equal(
        parseExecutionRequest({ type: 'execute_run', workspacePath: '/repos/demo', prompt: 'x' }),
        undefined
    );
});

test('an execution request without a prompt or workspace is refused', () => {
    assert.equal(
        parseExecutionRequest({ type: 'execute_run', runId: 'r', prompt: 'x' }),
        undefined
    );
    assert.equal(
        parseExecutionRequest({ type: 'execute_run', runId: 'r', workspacePath: '/repos/demo' }),
        undefined
    );
    assert.equal(
        parseExecutionRequest({
            type: 'execute_run',
            runId: 'r',
            workspacePath: '/repos/demo',
            prompt: '   '
        }),
        undefined
    );
});

test('a relative workspace path is refused', () => {
    assert.equal(
        parseExecutionRequest({
            type: 'execute_run',
            runId: 'r',
            workspacePath: 'repos/demo',
            prompt: 'x'
        }),
        undefined
    );
});

test('only an execute_run event yields an execution request', () => {
    assert.equal(
        parseExecutionRequest({
            type: 'run_started',
            runId: 'r',
            workspacePath: '/repos/demo',
            prompt: 'x'
        }),
        undefined
    );
});

test('worker execution events parse as recognised events', () => {
    assert.equal(parseEvent('{"type":"execute_run","runId":"r"}')?.type, 'execute_run');
    const followup = parseEvent(JSON.stringify({
        type: 'execute_followup',
        runId: 'followup-run',
        parentRunId: 'source-run',
        workspacePath: '/repos/demo',
        conversationId: 'codex-conversation',
        prompt: 'Fix the review finding.'
    }));
    assert.ok(followup);
    assert.deepEqual(parseFollowupExecutionRequest(followup), {
        runId: 'followup-run',
        workspacePath: '/repos/demo',
        conversationId: 'codex-conversation',
        prompt: 'Fix the review finding.',
        model: undefined,
        effort: undefined
    });
    assert.equal(parseEvent('{"type":"cancel_run","runId":"r"}')?.type, 'cancel_run');
});

test('an execute_run event is a worker instruction, not view state', () => {
    const before = reduce(initialState(), { type: 'snapshot', runState: 'ready' });
    const after = reduce(before, {
        type: 'execute_run',
        runId: 'r',
        workspacePath: '/repos/demo',
        prompt: 'x'
    });
    assert.deepEqual(after, before);
});

test('worker reports are outbound commands with their run id', () => {
    for (const type of [
        'worker_accepted',
        'worker_thread',
        'worker_status',
        'worker_completed',
        'worker_failed',
        'worker_cancelled'
    ] as const) {
        const line = encodeCommand({ type, runId: 'run-1' });
        assert.ok(line.includes('"runId":"run-1"'), type);
        assert.ok(line.endsWith('\n'));
    }
});

// MARK: execute_run admission
//
// A reconnect can redeliver the same execute_run. Treating that as "busy" would fail the run
// that is currently succeeding.

test('an execution request starts when nothing is running', () => {
    assert.equal(admitRun(undefined, 'run-1'), 'start');
});

test('a duplicate of the active run is ignored, not rejected', () => {
    assert.equal(admitRun('run-1', 'run-1'), 'ignore-duplicate');
});

test('a different run while one is active is rejected as busy', () => {
    assert.equal(admitRun('run-1', 'run-2'), 'reject-busy');
});

/** A connected companion; statusLabel reports "Disconnected" otherwise, whatever the run did. */
function connectedState(): AiflowState {
    return reduce(initialState(), { type: 'hello' });
}

// MARK: terminal companion state
//
// The companion reported terminal outcomes to the macOS app but left its own panel on the
// last transient state, so a cancelled run still read "Cancelling" in VS Code.

test('a completed run lands on completed and keeps the final message', () => {
    const running = reduce(connectedState(), {
        type: 'run_started',
        project: '/repos/demo',
        runState: 'running'
    });

    const state = reduce(running, terminalEvent('completed', { finalMessage: 'AIFLOW_OK' }));

    assert.equal(state.runState, 'completed');
    assert.equal(statusLabel(state), 'Completed');
    assert.equal(state.lastMessage, 'AIFLOW_OK');
    assert.equal(state.project, '/repos/demo', 'the project stays visible on the terminal state');
});

test('an interrupted run lands on cancelled, not stuck on cancelling', () => {
    let state = reduce(connectedState(), { type: 'run_started', project: '/repos/demo' });
    state = reduce(state, { type: 'run_status', runState: 'cancelling' });
    assert.equal(statusLabel(state), 'Cancelling');

    state = reduce(state, terminalEvent('interrupted'));

    assert.equal(state.runState, 'cancelled');
    assert.equal(statusLabel(state), 'Cancelled');
});

test('a failed result lands on failed and carries the reason', () => {
    const state = reduce(connectedState(), terminalEvent('failed', { errorMessage: 'boom' }));

    assert.equal(state.runState, 'failed');
    assert.equal(statusLabel(state), 'Failed');
    assert.equal(state.lastMessage, 'boom');
});

test('a thrown worker error is reported the same way as a failed result', () => {
    const detail = 'thread_unavailable: no conversation';
    const state = reduce(initialState(), terminalEvent('failed', { errorMessage: detail }));

    assert.equal(state.runState, 'failed');
    assert.equal(state.lastMessage, detail);
});

test('a failed outcome without a reason still says something useful', () => {
    assert.equal(
        reduce(initialState(), terminalEvent('failed')).lastMessage,
        'Codex reported a failure'
    );
});

test('a terminal outcome clears any pending approval or question', () => {
    let state = reduce(initialState(), { type: 'approval_requested', requestId: 7, summary: 'npm i' });
    assert.ok(state.pendingApproval);

    state = reduce(state, terminalEvent('interrupted'));
    assert.equal(state.pendingApproval, undefined);
});

test('a cancelled run does not block the next one', () => {
    // cancelled -> launching -> running, with no stale cancellation state left behind.
    let state = reduce(connectedState(), { type: 'run_started', project: '/repos/demo' });
    state = reduce(state, terminalEvent('interrupted'));
    assert.equal(state.runState, 'cancelled');

    state = reduce(state, {
        type: 'run_started',
        project: '/repos/demo',
        runState: 'launching'
    });
    assert.equal(state.runState, 'launching');
    assert.equal(state.lastMessage, undefined, 'the previous run leaves no message behind');

    state = reduce(state, { type: 'run_status', runState: 'running' });
    assert.equal(statusLabel(state), 'Running');
});
