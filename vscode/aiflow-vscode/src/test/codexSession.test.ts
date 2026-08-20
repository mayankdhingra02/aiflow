import { strict as assert } from 'node:assert';
import { test } from 'node:test';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import {
    SessionTail,
    findSessionFile,
    findStartedTurnIds,
    findTurnContext,
    findTurnResult,
    SessionRecord
} from '../codexIpc/sessionWatcher';
import {
    DEFAULT_EFFORT,
    DEFAULT_MODEL_ROLE,
    ModelResolutionError,
    resolveEffort,
    resolveExecution,
    resolveModelId
} from '../codexIpc/models';

// MARK: model + effort mapping

test('resolves Aiflow roles to official Codex model ids', () => {
    assert.equal(resolveModelId('luna'), 'gpt-5.6-luna');
    assert.equal(resolveModelId('terra'), 'gpt-5.6-terra');
    assert.equal(resolveModelId('sol'), 'gpt-5.6-sol');
    assert.equal(resolveModelId('SOL'), 'gpt-5.6-sol');
});

test('accepts an already-resolved model id', () => {
    assert.equal(resolveModelId('gpt-5.6-sol'), 'gpt-5.6-sol');
});

test('fails closed on an unknown model rather than guessing', () => {
    assert.throws(() => resolveModelId('gpt-4o'), ModelResolutionError);
    assert.throws(() => resolveModelId(''), ModelResolutionError);
    assert.throws(() => resolveModelId(undefined), ModelResolutionError);
});

test('resolves and validates reasoning effort', () => {
    for (const effort of ['low', 'medium', 'high', 'xhigh']) {
        assert.equal(resolveEffort(effort), effort);
    }
    assert.throws(() => resolveEffort('turbo'), ModelResolutionError);
    assert.throws(() => resolveEffort(undefined), ModelResolutionError);
});

test('resolveExecution produces the exact pair sent to Codex', () => {
    assert.deepEqual(resolveExecution('sol', 'low'), { model: 'gpt-5.6-sol', effort: 'low' });
    assert.equal(DEFAULT_MODEL_ROLE, 'terra');
    assert.equal(DEFAULT_EFFORT, 'medium');
});

// MARK: session correlation

function makeSessions(): { root: string; write: (conv: string, lines: SessionRecord[]) => string } {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'aiflow-sessions-'));
    const write = (conv: string, lines: SessionRecord[]): string => {
        const dir = path.join(root, '2026', '08', '19');
        fs.mkdirSync(dir, { recursive: true });
        const file = path.join(dir, `rollout-2026-08-19T10-00-00-${conv}.jsonl`);
        fs.writeFileSync(file, lines.map((l) => JSON.stringify(l)).join('\n') + '\n');
        return file;
    };
    return { root, write };
}

const CONV_A = '01a01c88-87fe-71d0-9d34-ad555722dc2a';
const CONV_B = '01a01c99-1111-2222-3333-444455556666';

function taskStarted(turnId: string): SessionRecord {
    return { type: 'event_msg', payload: { type: 'task_started', turn_id: turnId } };
}
function taskComplete(turnId: string, message: string): SessionRecord {
    return {
        type: 'event_msg',
        payload: { type: 'task_complete', turn_id: turnId, last_agent_message: message }
    };
}

test('locates the session file for one exact conversation', () => {
    const { root, write } = makeSessions();
    const fileA = write(CONV_A, [{ type: 'session_meta', payload: { id: CONV_A } }]);
    write(CONV_B, [{ type: 'session_meta', payload: { id: CONV_B } }]);

    assert.equal(findSessionFile(CONV_A, root), fileA);
    assert.notEqual(findSessionFile(CONV_B, root), fileA);
    fs.rmSync(root, { recursive: true, force: true });
});

test('returns undefined for an unknown conversation rather than any other session', () => {
    const { root, write } = makeSessions();
    write(CONV_A, [{ type: 'session_meta', payload: { id: CONV_A } }]);

    assert.equal(findSessionFile('019dffff-0000-0000-0000-000000000000', root), undefined);
    fs.rmSync(root, { recursive: true, force: true });
});

test('refuses a conversation id that is not an id', () => {
    const { root } = makeSessions();
    assert.equal(findSessionFile('../../etc/passwd', root), undefined);
    assert.equal(findSessionFile('', root), undefined);
    fs.rmSync(root, { recursive: true, force: true });
});

test('matches the outcome of one exact turn', () => {
    const records: SessionRecord[] = [
        { type: 'event_msg', payload: { type: 'task_started', turn_id: 'turn-1' } },
        { type: 'event_msg', payload: { type: 'task_complete', turn_id: 'turn-1', last_agent_message: 'done A' } }
    ];

    const result = findTurnResult(records, 'turn-1');
    assert.equal(result?.outcome, 'completed');
    assert.equal(result?.finalMessage, 'done A');
});

test('ignores a completion belonging to a different turn', () => {
    const records = [taskComplete('other-turn', 'not ours')];
    assert.equal(findTurnResult(records, 'turn-1'), undefined);
});

test('reports interrupted and failed turns distinctly', () => {
    assert.equal(
        findTurnResult([{ type: 'event_msg', payload: { type: 'turn_aborted', turn_id: 't' } }], 't')
            ?.outcome,
        'interrupted'
    );
    const failed = findTurnResult(
        [{ type: 'event_msg', payload: { type: 'task_failed', turn_id: 't', message: 'boom' } }],
        't'
    );
    assert.equal(failed?.outcome, 'failed');
    assert.equal(failed?.errorMessage, 'boom');
});

test('extracts started turn ids', () => {
    assert.deepEqual(findStartedTurnIds([taskStarted('a'), taskStarted('b')]), ['a', 'b']);
    assert.deepEqual(findStartedTurnIds([taskComplete('a', 'x')]), []);
});

test('extracts the safety context recorded for one exact turn', () => {
    const records: SessionRecord[] = [
        {
            type: 'turn_context',
            payload: {
                turn_id: 'turn-1',
                cwd: '/repos/demo',
                approval_policy: 'on-request',
                approvals_reviewer: 'user',
                sandbox_policy: { type: 'workspace-write', network_access: false }
            }
        }
    ];

    const context = findTurnContext(records, 'turn-1');
    assert.equal(context?.sandboxType, 'workspace-write');
    assert.equal(context?.approvalPolicy, 'on-request');
    assert.equal(context?.approvalsReviewer, 'user');
    assert.equal(context?.networkAccess, false);
    // A different turn's context must not be returned.
    assert.equal(findTurnContext(records, 'turn-2'), undefined);
});

// MARK: incremental tailing

test('reads only newly appended records', () => {
    const { root, write } = makeSessions();
    const file = write(CONV_A, [taskStarted('turn-1')]);
    const tail = new SessionTail(file);

    assert.equal(tail.readNew().length, 1);
    assert.deepEqual(tail.readNew(), [], 'nothing new yet');

    fs.appendFileSync(file, JSON.stringify(taskComplete('turn-1', 'done')) + '\n');
    const appended = tail.readNew();
    assert.equal(appended.length, 1);
    assert.equal(findTurnResult(appended, 'turn-1')?.finalMessage, 'done');
    fs.rmSync(root, { recursive: true, force: true });
});

test('a concurrent unrelated session never satisfies our turn', () => {
    const { root, write } = makeSessions();
    const ours = write(CONV_A, [taskStarted('turn-ours')]);
    const theirs = write(CONV_B, [taskStarted('turn-theirs'), taskComplete('turn-theirs', 'other run')]);

    const tail = new SessionTail(ours);
    const records = tail.readNew();
    assert.equal(findTurnResult(records, 'turn-ours'), undefined, 'our turn has not completed');

    // Even reading the unrelated file, its completion is for a different turn id.
    const otherRecords = new SessionTail(theirs).readNew();
    assert.equal(findTurnResult(otherRecords, 'turn-ours'), undefined);
    fs.rmSync(root, { recursive: true, force: true });
});

test('a partially flushed final line is not parsed until complete', () => {
    const { root, write } = makeSessions();
    const file = write(CONV_A, [taskStarted('turn-1')]);
    const tail = new SessionTail(file);
    tail.readNew();

    fs.appendFileSync(file, '{"type":"event_msg","payload":{"type":"task_com');
    assert.deepEqual(tail.readNew(), [], 'a half-written line yields nothing');

    fs.appendFileSync(file, 'plete","turn_id":"turn-1","last_agent_message":"ok"}}\n');
    assert.equal(findTurnResult(tail.readNew(), 'turn-1')?.finalMessage, 'ok');
    fs.rmSync(root, { recursive: true, force: true });
});

test('a truncated file is re-read rather than producing garbage', () => {
    const { root, write } = makeSessions();
    const file = write(CONV_A, [taskStarted('turn-1'), taskComplete('turn-1', 'first')]);
    const tail = new SessionTail(file);
    assert.equal(tail.readNew().length, 2);

    fs.writeFileSync(file, JSON.stringify(taskStarted('turn-2')) + '\n');
    const records = tail.readNew();
    assert.deepEqual(findStartedTurnIds(records), ['turn-2']);
    fs.rmSync(root, { recursive: true, force: true });
});

test('a missing file yields nothing instead of throwing', () => {
    const tail = new SessionTail(path.join(os.tmpdir(), 'aiflow-does-not-exist.jsonl'));
    assert.deepEqual(tail.readNew(), []);
});
