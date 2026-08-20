import * as vscode from 'vscode';
import { CodexIpcClient } from './client';
import { OfficialCodexWorker, WorkerError, WorkerRunRequest } from './worker';
import { defaultSessionsRoot, TurnResult } from './sessionWatcher';
import { OFFICIAL_EXTENSION_ID } from './threadResolver';
import { bootstrapFreshThread, canonicalPath, productionBootstrapDeps } from './bootstrapper';
import { ConversationCache } from './conversationCache';

/**
 * Glue between VS Code and the official Codex worker.
 *
 * Kept apart from the pure IPC/worker modules so those stay unit testable without the `vscode`
 * module, which only exists inside an Extension Development Host.
 */

export interface OfficialCodexStatus {
    extensionInstalled: boolean;
    ipcConnected: boolean;
    detail?: string;
}

export class OfficialCodexHost {
    private ipc: CodexIpcClient | undefined;
    private worker: OfficialCodexWorker | undefined;
    private lastDetail: string | undefined;

    /**
     * Live conversations per workspace, so the synthetic bootstrap is paid once rather than
     * on every run. Survives IPC reconnects — our connection dropping says nothing about
     * whether the official client still owns the conversation — and dies with this host.
     */
    private readonly conversations = new ConversationCache({
        canonicalPath,
        hasLiveOwner: (conversationId) => this.hasLiveOwner(conversationId),
        bootstrap: (workspacePath) => this.bootstrapConversation(workspacePath)
    });

    /** Whether a remembered conversation can still be driven. */
    private async hasLiveOwner(conversationId: string): Promise<boolean> {
        const ipc = this.ipc;
        if (!ipc || !ipc.isConnected) {
            return false;
        }
        try {
            await ipc.discoverThreadOwner(conversationId);
            return true;
        } catch {
            // No owner: the VS Code client that owned this conversation is gone.
            return false;
        }
    }

    /** Mints one fresh conversation with a synthetic first turn. */
    private async bootstrapConversation(workspacePath: string): Promise<string> {
        const result = await bootstrapFreshThread(
            workspacePath,
            productionBootstrapDeps(
                async (command, argument) =>
                    await vscode.commands.executeCommand(command, argument),
                defaultSessionsRoot()
            )
        );
        return result.conversationId;
    }

    /** Whether the official extension is present at all. */
    get isExtensionInstalled(): boolean {
        return vscode.extensions.getExtension(OFFICIAL_EXTENSION_ID) !== undefined;
    }

    status(): OfficialCodexStatus {
        return {
            extensionInstalled: this.isExtensionInstalled,
            ipcConnected: this.ipc?.isConnected ?? false,
            detail: this.lastDetail
        };
    }

    /**
     * Ensures the official extension is active and Aiflow has joined its IPC router.
     *
     * Aiflow never bundles or modifies the official extension; it only activates what the user
     * already installed.
     */
    async ensureReady(): Promise<void> {
        const extension = vscode.extensions.getExtension(OFFICIAL_EXTENSION_ID);
        if (!extension) {
            this.lastDetail = `${OFFICIAL_EXTENSION_ID} is not installed`;
            throw new WorkerError('extension_unavailable', this.lastDetail);
        }
        if (!extension.isActive) {
            await extension.activate();
        }

        if (!this.ipc || !this.ipc.isConnected) {
            this.ipc?.dispose();
            const ipc = new CodexIpcClient();
            try {
                await ipc.connect();
            } catch (error) {
                ipc.dispose();
                this.lastDetail =
                    error instanceof Error ? error.message : 'could not reach Codex IPC';
                throw new WorkerError('ipc_unavailable', this.lastDetail);
            }
            this.ipc = ipc;
            this.worker = new OfficialCodexWorker({
                ipc,
                resolveConversation: (request) => this.resolveConversation(request)
            });
            this.lastDetail = undefined;
        }
    }

    /**
     * Picks the conversation for this run: the workspace's existing one when it still has an
     * owner, otherwise a freshly bootstrapped one.
     *
     * The real Aiflow prompt is deliberately not an argument here — it is sent afterwards
     * through follower IPC, never through the bootstrap command. The worker performs its own
     * owner discovery before the turn regardless of what this returns.
     */
    private async resolveConversation(request: WorkerRunRequest): Promise<string> {
        try {
            const resolved = await this.conversations.resolve(request.workspacePath);
            return resolved.conversationId;
        } catch (error) {
            const detail =
                error instanceof Error ? error.message : 'could not bootstrap a conversation';
            throw new WorkerError('thread_unavailable', detail);
        }
    }

    async run(
        request: WorkerRunRequest,
        onEvent: (event: { type: string; conversationId?: string; turnId?: string; state?: string }) => void
    ): Promise<TurnResult> {
        await this.ensureReady();
        if (!this.worker) {
            throw new WorkerError('ipc_unavailable', 'official Codex worker is not ready');
        }
        return this.worker.run(request, { onEvent: (event) => onEvent(event as never) });
    }

    async cancel(runId: string): Promise<boolean> {
        if (!this.worker) {
            return false;
        }
        return this.worker.cancel(runId);
    }

    dispose(): void {
        this.ipc?.dispose();
        this.ipc = undefined;
        this.worker = undefined;
        this.conversations.clear();
    }
}
