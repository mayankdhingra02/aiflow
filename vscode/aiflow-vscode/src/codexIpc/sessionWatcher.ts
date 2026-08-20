import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';

/**
 * Reads the durable Codex session log for one exact conversation and reports the outcome of
 * one exact turn.
 *
 * Correlation is by `conversationId` + `turnId` only. Modification time is never used to pick
 * a session: the user may have several Codex windows running, and "most recently modified"
 * would happily hand back somebody else's run.
 */

export const SESSIONS_DIR_NAME = 'sessions';

/** Bounds so a huge or runaway log cannot be pulled into memory. */
export const MAX_LINE_BYTES = 4 * 1024 * 1024;
export const MAX_BYTES_PER_READ = 8 * 1024 * 1024;

export type TurnOutcome = 'completed' | 'failed' | 'interrupted';

export interface TurnResult {
    outcome: TurnOutcome;
    turnId: string;
    /** The agent's final message for this turn, when Codex recorded one. */
    finalMessage?: string;
    errorMessage?: string;
}

/** The safety-relevant context Codex recorded for a turn. */
export interface TurnContext {
    turnId: string;
    cwd?: string;
    approvalPolicy?: string;
    approvalsReviewer?: string;
    sandboxType?: string;
    networkAccess?: boolean;
}

export function defaultSessionsRoot(): string {
    const home = process.env.CODEX_HOME?.trim() ? (process.env.CODEX_HOME as string) : path.join(os.homedir(), '.codex');
    return path.join(home, SESSIONS_DIR_NAME);
}

/**
 * Finds the session file for one conversation.
 *
 * Codex names each file `rollout-<timestamp>-<conversationId>.jsonl`, so the exact session can
 * be found by name without opening any other file.
 */
export function findSessionFile(
    conversationId: string,
    sessionsRoot: string = defaultSessionsRoot()
): string | undefined {
    if (!/^[0-9a-fA-F-]{8,}$/.test(conversationId)) {
        return undefined; // never let an id become a directory traversal
    }
    const suffix = `-${conversationId}.jsonl`;

    const walk = (dir: string, depth: number): string | undefined => {
        if (depth > 5) {
            return undefined;
        }
        let entries: fs.Dirent[];
        try {
            entries = fs.readdirSync(dir, { withFileTypes: true });
        } catch {
            return undefined;
        }
        // Newest date directories first: sessions are laid out YYYY/MM/DD.
        const dirs = entries.filter((e) => e.isDirectory()).sort((a, b) => b.name.localeCompare(a.name));
        const files = entries.filter((e) => e.isFile() && e.name.endsWith(suffix));
        if (files.length > 0) {
            return path.join(dir, files[0].name);
        }
        for (const child of dirs) {
            const found = walk(path.join(dir, child.name), depth + 1);
            if (found) {
                return found;
            }
        }
        return undefined;
    };

    return walk(sessionsRoot, 0);
}

/** One JSONL record from a Codex session log. */
export interface SessionRecord {
    type?: string;
    payload?: Record<string, unknown>;
}

/** Incrementally tails one session file, parsing only newly appended lines. */
export class SessionTail {
    private offset = 0;
    private carry = '';

    constructor(readonly filePath: string) {}

    /** Reads whatever has been appended since the last call. */
    readNew(): SessionRecord[] {
        let handle: number;
        try {
            handle = fs.openSync(this.filePath, 'r');
        } catch {
            return [];
        }

        try {
            const size = fs.fstatSync(handle).size;
            if (size < this.offset) {
                // Truncated or rotated underneath us: start over rather than read garbage.
                this.offset = 0;
                this.carry = '';
            }
            if (size === this.offset) {
                return [];
            }

            const length = Math.min(size - this.offset, MAX_BYTES_PER_READ);
            const buffer = Buffer.allocUnsafe(length);
            const read = fs.readSync(handle, buffer, 0, length, this.offset);
            this.offset += read;

            const text = this.carry + buffer.subarray(0, read).toString('utf8');
            const parts = text.split('\n');
            this.carry = parts.pop() ?? '';

            if (Buffer.byteLength(this.carry, 'utf8') > MAX_LINE_BYTES) {
                // A single line this long is not something we will ever parse usefully.
                this.carry = '';
            }

            const records: SessionRecord[] = [];
            for (const line of parts) {
                const trimmed = line.trim();
                if (!trimmed) {
                    continue;
                }
                try {
                    records.push(JSON.parse(trimmed) as SessionRecord);
                } catch {
                    // A partially flushed line; skip it.
                }
            }
            return records;
        } finally {
            fs.closeSync(handle);
        }
    }
}

/** Pulls the outcome of one exact turn out of a batch of session records. */
export function findTurnResult(records: SessionRecord[], turnId: string): TurnResult | undefined {
    for (const record of records) {
        const payload = record.payload ?? {};
        if (record.type !== 'event_msg') {
            continue;
        }
        if (payload.turn_id !== turnId) {
            continue; // a different turn, possibly from a concurrent run
        }

        const kind = payload.type;
        if (kind === 'task_complete') {
            const message = payload.last_agent_message;
            return {
                outcome: 'completed',
                turnId,
                finalMessage: typeof message === 'string' ? message : undefined
            };
        }
        if (kind === 'turn_aborted' || kind === 'task_interrupted') {
            return { outcome: 'interrupted', turnId };
        }
        if (kind === 'task_failed' || kind === 'error') {
            const message = payload.message ?? payload.error;
            return {
                outcome: 'failed',
                turnId,
                errorMessage: typeof message === 'string' ? message : 'Codex reported an error'
            };
        }
    }
    return undefined;
}

/** Extracts the recorded safety context for one exact turn. */
export function findTurnContext(
    records: SessionRecord[],
    turnId: string
): TurnContext | undefined {
    for (const record of records) {
        if (record.type !== 'turn_context') {
            continue;
        }
        const payload = record.payload ?? {};
        if (payload.turn_id !== turnId) {
            continue;
        }
        const sandbox = payload.sandbox_policy as { type?: string; network_access?: boolean } | undefined;
        return {
            turnId,
            cwd: typeof payload.cwd === 'string' ? payload.cwd : undefined,
            approvalPolicy:
                typeof payload.approval_policy === 'string' ? payload.approval_policy : undefined,
            approvalsReviewer:
                typeof payload.approvals_reviewer === 'string'
                    ? payload.approvals_reviewer
                    : undefined,
            sandboxType: sandbox?.type,
            networkAccess: sandbox?.network_access
        };
    }
    return undefined;
}

/** The turn ids observed starting in a batch — used to learn the turn id of a fresh turn. */
export function findStartedTurnIds(records: SessionRecord[]): string[] {
    const ids: string[] = [];
    for (const record of records) {
        const payload = record.payload ?? {};
        if (record.type === 'event_msg' && payload.type === 'task_started') {
            if (typeof payload.turn_id === 'string') {
                ids.push(payload.turn_id);
            }
        }
    }
    return ids;
}
