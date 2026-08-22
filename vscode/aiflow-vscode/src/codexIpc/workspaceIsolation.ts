import * as os from 'os';
import * as path from 'path';
import { SessionRecord } from './sessionWatcher';

export type WorkspaceIsolationFailureCode =
    | 'missing_turn_context'
    | 'wrong_workspace'
    | 'invalid_writable_roots'
    | 'cross_workspace_writable_root';

export interface WorkspaceIsolationFailure {
    code: WorkspaceIsolationFailureCode;
    detail: string;
}

/**
 * Validates the official extension's recorded context before Aiflow submits a real prompt.
 * Aiflow cannot set sandbox roots through the pinned follower API, so an inherited root that
 * is neither this workspace nor an exact system temporary directory must fail closed.
 */
export function validateWorkspaceIsolation(
    records: SessionRecord[],
    workspacePath: string,
    canonicalPath: (value: string) => string,
    turnId?: string
): WorkspaceIsolationFailure | undefined {
    const contexts = records.filter((record) =>
        record.type === 'turn_context' &&
        typeof record.payload?.turn_id === 'string' &&
        (turnId === undefined || record.payload.turn_id === turnId)
    );
    const context = contexts.at(-1)?.payload;
    if (!context) {
        return {
            code: 'missing_turn_context',
            detail: 'official Codex conversation has no recorded turn context'
        };
    }

    const cwd = context.cwd;
    if (typeof cwd !== 'string' || canonicalPath(cwd) !== canonicalPath(workspacePath)) {
        return {
            code: 'wrong_workspace',
            detail: 'official Codex conversation is rooted at a different workspace'
        };
    }

    const sandbox = context.sandbox_policy as Record<string, unknown> | undefined;
    const rawRoots = sandbox?.writable_roots;
    if (rawRoots === undefined) {
        return undefined;
    }
    if (!Array.isArray(rawRoots) || rawRoots.some((root) => typeof root !== 'string')) {
        return {
            code: 'invalid_writable_roots',
            detail: 'official Codex writable-root evidence is malformed'
        };
    }

    const workspace = canonicalPath(workspacePath);
    const temporaryRoots = new Set([
        canonicalPath('/tmp'),
        canonicalPath('/private/tmp'),
        canonicalPath(os.tmpdir())
    ]);
    for (const rawRoot of rawRoots as string[]) {
        const root = canonicalPath(rawRoot);
        if (root === workspace || isWithin(root, workspace) || temporaryRoots.has(root)) {
            continue;
        }
        return {
            code: 'cross_workspace_writable_root',
            detail: 'official Codex conversation contains a writable root outside this workspace'
        };
    }
    return undefined;
}

function isWithin(candidate: string, parent: string): boolean {
    const relative = path.relative(parent, candidate);
    return relative !== '' && !relative.startsWith('..') && !path.isAbsolute(relative);
}
