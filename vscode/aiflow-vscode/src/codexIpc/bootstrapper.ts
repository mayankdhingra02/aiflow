import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { randomBytes } from 'crypto';
import { SessionRecord, defaultSessionsRoot } from './sessionWatcher';

/** The only command that is allowed to create the synthetic first turn. */
export const BOOTSTRAP_COMMAND = 'chatgpt.implementTodo';

/** Keep discovery bounded even if a machine has many old Codex sessions. */
export const MAX_SESSION_FILES = 4_000;
export const MAX_BOOTSTRAP_SESSION_BYTES = 16 * 1024 * 1024;
export const MAX_BOOTSTRAP_RECORDS = 16_384;

export function generateBootstrapNonce(): string {
    return randomBytes(16).toString('hex');
}

export type BootstrapFailure =
    | 'command_failed'
    | 'conversation_not_found'
    | 'bootstrap_incomplete'
    | 'wrong_workspace'
    | 'timed_out';

export class BootstrapError extends Error {
    constructor(
        readonly code: BootstrapFailure,
        message: string
    ) {
        super(message);
    }
}

export interface BootstrapResult {
    conversationId: string;
    bootstrapTurnId: string;
    sessionFile: string;
}

export interface SessionFileIdentity {
    size: number;
    mtimeMs: number;
    ino?: number;
    dev?: number;
}

export type SessionFileSnapshot = ReadonlyMap<string, SessionFileIdentity>;

export interface BootstrapDeps {
    /** Runs a VS Code command. */
    runCommand: (command: string, argument: unknown) => Promise<unknown>;
    /** Snapshot metadata only; session contents are never read during the snapshot. */
    snapshotSessionFiles: () => SessionFileSnapshot;
    /** Reads one candidate session, subject to the caller's size/record bounds. */
    readSession: (file: string) => SessionRecord[];
    writeTempFile: (filePath: string, contents: string) => void;
    removeTempFile: (filePath: string) => void;
    /** Builds an Aiflow-owned path under the OS temporary directory. */
    tempFilePath: (nonce: string) => string;
    newNonce: () => string;
    /** Resolves a path for comparison (including macOS /tmp vs /private/tmp). */
    canonicalPath: (value: string) => string;
    delay?: (ms: number) => Promise<void>;
    now?: () => number;
}

export interface BootstrapOptions {
    discoveryTimeoutMs?: number;
    completionTimeoutMs?: number;
    pollIntervalMs?: number;
}

const DEFAULT_DISCOVERY_TIMEOUT_MS = 90_000;
const DEFAULT_COMPLETION_TIMEOUT_MS = 180_000;
const DEFAULT_POLL_MS = 1_500;

/** The synthetic comment contains no user prompt or repository instructions. */
export function bootstrapComment(nonce: string): string {
    return [
        'AIFLOW SESSION BOOTSTRAP.',
        'Do not modify project files.',
        'Do not run shell commands.',
        'Reply with exactly:',
        `AIFLOW_BOOTSTRAP_OK_${nonce}`
    ].join('\n');
}

export function bootstrapArgument(
    fileName: string,
    repositoryPath: string,
    nonce: string
): { fileName: string; cwd: string; line: number; comment: string } {
    return { fileName, cwd: repositoryPath, line: 1, comment: bootstrapComment(nonce) };
}

/**
 * Create a fresh official conversation by making one synthetic implementTodo turn.
 *
 * The session boundary is captured before dispatch. After dispatch, only files that are new or
 * whose metadata changed are read, and only a file containing this invocation's nonce qualifies.
 * This prevents an unrelated open Codex session from being selected by recency.
 */
export async function bootstrapFreshThread(
    repositoryPath: string,
    deps: BootstrapDeps,
    options: BootstrapOptions = {}
): Promise<BootstrapResult> {
    const delay = deps.delay ?? ((ms: number) => new Promise((resolve) => setTimeout(resolve, ms)));
    const now = deps.now ?? (() => Date.now());
    const pollMs = options.pollIntervalMs ?? DEFAULT_POLL_MS;
    const nonce = deps.newNonce();
    const tempFile = deps.tempFilePath(nonce);
    const marker = `AIFLOW_BOOTSTRAP_OK_${nonce}`;
    let temporaryFileCreated = false;

    try {
        const repositoryCanonical = deps.canonicalPath(repositoryPath);
        const tempCanonical = deps.canonicalPath(tempFile);
        if (isWithin(tempCanonical, repositoryCanonical)) {
            throw new BootstrapError(
                'wrong_workspace',
                'the bootstrap file must not be inside the target repository'
            );
        }

        const before = deps.snapshotSessionFiles();
        deps.writeTempFile(tempFile, `AIFLOW BOOTSTRAP ${nonce}\n`);
        temporaryFileCreated = true;

        try {
            await deps.runCommand(
                BOOTSTRAP_COMMAND,
                bootstrapArgument(tempFile, repositoryPath, nonce)
            );
        } catch (error) {
            throw new BootstrapError(
                'command_failed',
                `${BOOTSTRAP_COMMAND} failed: ${describe(error)}`
            );
        }

        const candidate = await waitFor(
            () => findNonceCandidate(before, deps.snapshotSessionFiles, deps.readSession, nonce),
            options.discoveryTimeoutMs ?? DEFAULT_DISCOVERY_TIMEOUT_MS,
            pollMs,
            delay,
            now
        );
        if (!candidate) {
            throw new BootstrapError(
                'conversation_not_found',
                'the official extension did not create a conversation for the bootstrap'
            );
        }

        const records = deps.readSession(candidate);
        const conversationId = conversationIdOf(records);
        if (!conversationId) {
            throw new BootstrapError(
                'conversation_not_found',
                'the bootstrap session has no conversation id'
            );
        }

        const completed = await waitFor(
            () => findBootstrapCompletion(deps.readSession(candidate), marker),
            options.completionTimeoutMs ?? DEFAULT_COMPLETION_TIMEOUT_MS,
            pollMs,
            delay,
            now
        );
        if (!completed) {
            throw new BootstrapError(
                'bootstrap_incomplete',
                'the bootstrap turn did not return its expected completion marker'
            );
        }

        const recordedCwd = workspaceOf(deps.readSession(candidate), completed.turnId);
        if (!recordedCwd || deps.canonicalPath(recordedCwd) !== repositoryCanonical) {
            throw new BootstrapError(
                'wrong_workspace',
                `the bootstrapped thread is rooted at ${recordedCwd ?? 'an unknown path'}, not ${repositoryPath}`
            );
        }

        return {
            conversationId,
            bootstrapTurnId: completed.turnId,
            sessionFile: candidate
        };
    } finally {
        // The file is Aiflow-owned and is never a user source file. Cleanup is attempted for
        // every path after the nonce/path were generated, including command and timeout errors.
        if (temporaryFileCreated) {
            deps.removeTempFile(tempFile);
        }
    }
}

/** Production session metadata scan. It never opens session contents. */
export function snapshotSessionFiles(
    sessionsRoot: string = defaultSessionsRoot(),
    maxFiles: number = MAX_SESSION_FILES
): SessionFileSnapshot {
    const result = new Map<string, SessionFileIdentity>();
    const visit = (directory: string, depth: number): void => {
        if (depth > 5 || result.size >= maxFiles) {
            return;
        }
        let entries: fs.Dirent[];
        try {
            entries = fs.readdirSync(directory, { withFileTypes: true });
        } catch {
            return;
        }
        for (const entry of entries) {
            if (result.size >= maxFiles) {
                return;
            }
            const entryPath = path.join(directory, entry.name);
            if (entry.isDirectory()) {
                visit(entryPath, depth + 1);
            } else if (entry.isFile() && entry.name.endsWith('.jsonl')) {
                try {
                    const stat = fs.statSync(entryPath);
                    result.set(entryPath, {
                        size: stat.size,
                        mtimeMs: stat.mtimeMs,
                        ino: stat.ino,
                        dev: stat.dev
                    });
                } catch {
                    // A session may rotate between readdir and stat; ignore that candidate.
                }
            }
        }
    };
    visit(sessionsRoot, 0);
    return result;
}

/** Production bounded JSONL reader used only for post-bootstrap candidates. */
export function readSessionBounded(
    file: string,
    maxBytes: number = MAX_BOOTSTRAP_SESSION_BYTES,
    maxRecords: number = MAX_BOOTSTRAP_RECORDS
): SessionRecord[] {
    let handle: number;
    try {
        handle = fs.openSync(file, 'r');
    } catch {
        return [];
    }

    let contents: string;
    try {
        const initial = fs.fstatSync(handle);
        if (initial.size > maxBytes) {
            return [];
        }
        const buffer = Buffer.allocUnsafe(Math.min(initial.size, maxBytes));
        const read = buffer.length === 0 ? 0 : fs.readSync(handle, buffer, 0, buffer.length, 0);
        // Re-check after the bounded read so a file that grew during the read is rejected.
        if (fs.fstatSync(handle).size > maxBytes) {
            return [];
        }
        contents = buffer.subarray(0, read).toString('utf8');
    } catch {
        return [];
    } finally {
        fs.closeSync(handle);
    }

    const records: SessionRecord[] = [];
    for (const line of contents.split('\n')) {
        if (records.length >= maxRecords) {
            break;
        }
        const trimmed = line.trim();
        if (!trimmed) {
            continue;
        }
        try {
            records.push(JSON.parse(trimmed) as SessionRecord);
        } catch {
            // Ignore a line that is still being flushed by Codex.
        }
    }
    return records;
}

/** Default production dependencies, kept here so the host contains no trust-boundary logic. */
export function productionBootstrapDeps(
    runCommand: (command: string, argument: unknown) => Promise<unknown>,
    sessionsRoot: string = defaultSessionsRoot()
): BootstrapDeps {
    return {
        runCommand,
        snapshotSessionFiles: () => snapshotSessionFiles(sessionsRoot),
        readSession: (file) => readSessionBounded(file),
        writeTempFile: (file, contents) => {
            // Exclusive creation prevents a collision or symlink from redirecting a write into
            // an existing user file. The generated nonce makes collisions extraordinarily rare;
            // failure is safer than overwriting anything.
            let handle: number | undefined;
            try {
                handle = fs.openSync(file, 'wx', 0o600);
                fs.writeFileSync(handle, contents, { encoding: 'utf8' });
                fs.closeSync(handle);
                handle = undefined;
            } catch (error) {
                if (handle !== undefined) {
                    try {
                        fs.closeSync(handle);
                        fs.unlinkSync(file);
                    } catch {
                        // Preserve the original write error.
                    }
                }
                throw error;
            }
        },
        removeTempFile: (file) => {
            try {
                fs.unlinkSync(file);
            } catch (error) {
                if (!isNodeError(error, 'ENOENT')) {
                    throw error;
                }
            }
        },
        tempFilePath: (nonce) => path.join(os.tmpdir(), `aiflow-bootstrap-${nonce}.txt`),
        newNonce: generateBootstrapNonce,
        canonicalPath: (value) => canonicalPath(value)
    };
}

function findNonceCandidate(
    before: SessionFileSnapshot,
    snapshot: () => SessionFileSnapshot,
    readSession: (file: string) => SessionRecord[],
    nonce: string
): string | undefined {
    for (const [file, identity] of snapshot()) {
        const previous = before.get(file);
        if (previous && sameIdentity(previous, identity)) {
            continue;
        }
        const records = readSession(file);
        if (records.some((record) => recordContains(record, nonce))) {
            return file;
        }
    }
    return undefined;
}

function findBootstrapCompletion(
    records: SessionRecord[],
    marker: string
): { turnId: string } | undefined {
    for (const record of records) {
        const payload = record.payload ?? {};
        if (record.type !== 'event_msg' || payload.type !== 'task_complete') {
            continue;
        }
        const turnId = payload.turn_id;
        const message = payload.last_agent_message;
        if (typeof turnId === 'string' && typeof message === 'string' && message.includes(marker)) {
            return { turnId };
        }
    }
    return undefined;
}

function conversationIdOf(records: SessionRecord[]): string | undefined {
    const meta = records.find((record) => record.type === 'session_meta')?.payload;
    const id = meta?.id;
    return typeof id === 'string' && id.length > 0 ? id : undefined;
}

function workspaceOf(records: SessionRecord[], turnId: string): string | undefined {
    const context = records
        .filter((record) => record.type === 'turn_context' && record.payload?.turn_id === turnId)
        .map((record) => record.payload)
        .pop();
    const cwd = context?.cwd;
    return typeof cwd === 'string' ? cwd : undefined;
}

async function waitFor<T>(
    probe: () => T | undefined,
    timeoutMs: number,
    pollMs: number,
    delay: (ms: number) => Promise<void>,
    now: () => number
): Promise<T | undefined> {
    const deadline = now() + timeoutMs;
    for (;;) {
        const value = probe();
        if (value !== undefined) {
            return value;
        }
        if (now() >= deadline) {
            return undefined;
        }
        await delay(Math.min(pollMs, Math.max(0, deadline - now())));
    }
}

function recordContains(record: SessionRecord, value: string): boolean {
    return JSON.stringify(record).includes(value);
}

function sameIdentity(left: SessionFileIdentity, right: SessionFileIdentity): boolean {
    return (
        left.size === right.size &&
        left.mtimeMs === right.mtimeMs &&
        left.ino === right.ino &&
        left.dev === right.dev
    );
}

function isWithin(candidate: string, parent: string): boolean {
    const relative = path.relative(parent, candidate);
    return relative === '' || (!relative.startsWith('..') && !path.isAbsolute(relative));
}

function canonicalPath(value: string): string {
    try {
        return fs.realpathSync.native(value);
    } catch {
        return path.resolve(value);
    }
}

function isNodeError(error: unknown, code: string): boolean {
    return typeof error === 'object' && error !== null && (error as { code?: unknown }).code === code;
}

function describe(error: unknown): string {
    return error instanceof Error ? error.message : String(error);
}
