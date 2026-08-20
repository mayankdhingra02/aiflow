/**
 * Remembers which official Codex conversation belongs to which workspace, so the synthetic
 * bootstrap turn is paid for once per live conversation instead of once per Aiflow run.
 *
 * In memory only, for the lifetime of this extension host. An official conversation becomes
 * unowned when the VS Code client that owns it goes away, and reattaching to a conversation
 * across an extension-host restart has not been proven — so nothing is written to disk. A
 * reload may cost one more bootstrap; that is the safe trade.
 *
 * Nothing about a prompt is stored here.
 */

export interface ConversationCacheDeps {
    /** Canonicalises a workspace path (so /tmp and /private/tmp share one entry). */
    canonicalPath: (value: string) => string;
    /** True when the conversation still has a live official owner. */
    hasLiveOwner: (conversationId: string) => Promise<boolean>;
    /** Mints a new conversation for the workspace. Only called when reuse is impossible. */
    bootstrap: (workspacePath: string) => Promise<string>;
}

export interface ResolvedConversation {
    conversationId: string;
    /** True when this call had to pay for a synthetic bootstrap turn. */
    bootstrapped: boolean;
}

export class ConversationCache {
    /** canonical workspace path -> official conversation id */
    private readonly entries = new Map<string, string>();
    /** Bootstraps already running, so two calls never mint two conversations for one workspace. */
    private readonly inFlight = new Map<string, Promise<string>>();

    constructor(private readonly deps: ConversationCacheDeps) {}

    /** How many workspaces currently have a remembered conversation. */
    get size(): number {
        return this.entries.size;
    }

    /** The remembered conversation for a workspace, without validating or creating anything. */
    peek(workspacePath: string): string | undefined {
        return this.entries.get(this.deps.canonicalPath(workspacePath));
    }

    /**
     * Returns the conversation to run in, reusing a live one when possible.
     *
     * Reuse is only accepted after confirming the conversation still has an owner: a remembered
     * id whose owner has gone is worthless, and dispatching to it would fail. Recovery happens
     * here, strictly before the real prompt is dispatched — never after a turn has been started.
     */
    async resolve(workspacePath: string): Promise<ResolvedConversation> {
        const key = this.deps.canonicalPath(workspacePath);

        const cached = this.entries.get(key);
        if (cached && (await this.deps.hasLiveOwner(cached))) {
            return { conversationId: cached, bootstrapped: false };
        }
        if (cached) {
            // Stale: the owning client is gone, so this conversation can no longer be driven.
            this.entries.delete(key);
        }

        const existing = this.inFlight.get(key);
        if (existing) {
            return { conversationId: await existing, bootstrapped: false };
        }

        const pending = this.deps.bootstrap(workspacePath);
        this.inFlight.set(key, pending);
        try {
            const conversationId = await pending;
            this.entries.set(key, conversationId);
            return { conversationId, bootstrapped: true };
        } finally {
            this.inFlight.delete(key);
        }
    }

    /**
     * Forgets a workspace's conversation.
     *
     * Deliberately not called on completion, cancellation, or an ordinary turn failure: those
     * say nothing about whether the conversation is still usable, and `resolve` revalidates
     * ownership before every run anyway.
     */
    forget(workspacePath: string): void {
        this.entries.delete(this.deps.canonicalPath(workspacePath));
    }

    clear(): void {
        this.entries.clear();
        this.inFlight.clear();
    }
}
