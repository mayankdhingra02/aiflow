import * as vscode from 'vscode';
import { CodexIpcClient } from './client';
import { OfficialCodexWorker, WorkerError, WorkerRunRequest } from './worker';
import { TurnResult } from './sessionWatcher';
import {
    NEW_PANEL_COMMAND,
    OFFICIAL_EXTENSION_ID,
    ThreadResolutionError,
    createFreshThread
} from './threadResolver';

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
                resolveConversation: (request) => this.resolveConversation(ipc, request)
            });
            this.lastDetail = undefined;
        }
    }

    /**
     * Opens a fresh official Codex panel for this run and returns its conversation id.
     *
     * A run is never dispatched into a conversation the user already had open — only one that
     * appears after we asked for a new panel.
     */
    private async resolveConversation(
        ipc: CodexIpcClient,
        _request: WorkerRunRequest
    ): Promise<string> {
        try {
            return await createFreshThread({
                onBroadcast: (listener) => {
                    const handler = (message: unknown): void => listener(message);
                    ipc.on('broadcast', handler);
                    return () => ipc.off('broadcast', handler);
                },
                openNewPanel: async () => {
                    await vscode.commands.executeCommand(NEW_PANEL_COMMAND);
                }
            });
        } catch (error) {
            const detail =
                error instanceof ThreadResolutionError
                    ? error.message
                    : 'could not create an official Codex conversation';
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
    }
}
