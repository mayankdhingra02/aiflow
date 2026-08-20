/**
 * The one place Aiflow's model/effort vocabulary is translated to the official Codex wire
 * values. Nothing else in the worker may hard-code a model string.
 *
 * Aiflow speaks in roles (`luna`/`terra`/`sol`) because the Python backend owns that mapping;
 * the macOS app resolves a role to a concrete model id before dispatching. Both forms are
 * accepted here so the companion works whichever the app sends.
 */

export type ReasoningEffort = 'low' | 'medium' | 'high' | 'xhigh';

const ROLE_TO_MODEL: Readonly<Record<string, string>> = {
    luna: 'gpt-5.6-luna',
    terra: 'gpt-5.6-terra',
    sol: 'gpt-5.6-sol'
};

const ALLOWED_EFFORTS: ReadonlySet<string> = new Set<ReasoningEffort>([
    'low',
    'medium',
    'high',
    'xhigh'
]);

export const DEFAULT_MODEL_ROLE = 'terra';
export const DEFAULT_EFFORT: ReasoningEffort = 'medium';

export class ModelResolutionError extends Error {}

/**
 * Resolves whatever the app sent into an official Codex model id.
 *
 * Accepts a role (`terra`) or an already-resolved model id (`gpt-5.6-terra`). Fails closed on
 * anything unrecognised: dispatching a turn on a model we did not intend is worse than
 * refusing the run.
 */
export function resolveModelId(requested: string | undefined): string {
    const value = (requested ?? '').trim();
    if (!value) {
        throw new ModelResolutionError('no model was requested');
    }

    const byRole = ROLE_TO_MODEL[value.toLowerCase()];
    if (byRole) {
        return byRole;
    }

    // Already a concrete Codex model id.
    if (Object.values(ROLE_TO_MODEL).includes(value)) {
        return value;
    }

    throw new ModelResolutionError(`unrecognised model: ${value}`);
}

export function resolveEffort(requested: string | undefined): ReasoningEffort {
    const value = (requested ?? '').trim().toLowerCase();
    if (!value) {
        throw new ModelResolutionError('no reasoning effort was requested');
    }
    if (!ALLOWED_EFFORTS.has(value)) {
        throw new ModelResolutionError(`unrecognised reasoning effort: ${value}`);
    }
    return value as ReasoningEffort;
}

/** The exact pair sent to both `update-thread-settings` and `start-turn`. */
export interface ResolvedExecution {
    model: string;
    effort: ReasoningEffort;
}

export function resolveExecution(
    model: string | undefined,
    effort: string | undefined
): ResolvedExecution {
    return { model: resolveModelId(model), effort: resolveEffort(effort) };
}

/** Roles, for display only. */
export function knownRoles(): string[] {
    return Object.keys(ROLE_TO_MODEL);
}
