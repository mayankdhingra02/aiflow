import * as vscode from 'vscode';
import { BridgeClient } from './bridgeClient';
import { AiflowViewProvider } from './aiflowView';
import {
    AiflowState,
    BridgeEvent,
    admitRun,
    initialState,
    parseExecutionRequest,
    reduce,
    statusLabel
} from './protocol';
import { OfficialCodexHost } from './codexIpc/host';
import { WorkerError } from './codexIpc/worker';

/**
 * Aiflow companion.
 *
 * Two roles:
 *  - a live viewer/controller for a run the Aiflow menu-bar app owns itself (legacy path), and
 *  - a worker that executes a run through the official Codex extension when the app asks it to.
 *
 * The companion never starts a Codex process of its own. On the worker path the official
 * `openai.chatgpt` extension owns and runs the session, and the conversation is visible in the
 * official Codex UI; Aiflow only drives it as a follower over Codex's local IPC router.
 */
export function activate(context: vscode.ExtensionContext): void {
    let state: AiflowState = initialState();

    const view = new AiflowViewProvider(state);
    context.subscriptions.push(vscode.window.registerTreeDataProvider('aiflow.runView', view));

    const statusBar = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 100);
    statusBar.command = 'aiflow.focusView';
    context.subscriptions.push(statusBar);

    const client = new BridgeClient();
    context.subscriptions.push({ dispose: () => client.dispose() });

    const codex = new OfficialCodexHost();
    context.subscriptions.push({ dispose: () => codex.dispose() });

    const announceOfficialWorker = (): void => {
        const enabled = vscode.workspace
            .getConfiguration()
            .get<boolean>('aiflow.officialWorker.enabled', false);
        client.workerAvailable(enabled && codex.isExtensionInstalled);
    };

    /** The run the official worker is currently executing, if any. */
    let activeWorkerRunId: string | undefined;

    /**
     * Executes one Aiflow run through the official Codex extension.
     *
     * Only one worker run is in flight at a time: a second request while one is active is
     * refused rather than silently running two Codex turns for one Aiflow job.
     */
    const executeRun = async (event: BridgeEvent): Promise<void> => {
        const request = parseExecutionRequest(event);
        if (!request) {
            return; // malformed execution requests are ignored, never guessed at
        }
        switch (admitRun(activeWorkerRunId, request.runId)) {
            case 'ignore-duplicate':
                // The same run redelivered — typically a reconnect replaying the request.
                // Starting a second Codex turn, or reporting a failure, would break the run
                // that is currently succeeding.
                return;
            case 'reject-busy':
                client.workerFailed(request.runId, 'another Aiflow run is already executing');
                return;
            case 'start':
                break;
        }

        activeWorkerRunId = request.runId;
        client.workerAccepted(request.runId);
        state = { ...state, runState: 'launching', project: request.workspacePath };
        render();

        try {
            const result = await codex.run(request, (workerEvent) => {
                if (workerEvent.type === 'thread' && workerEvent.conversationId) {
                    client.workerThread(request.runId, workerEvent.conversationId);
                } else if (workerEvent.type === 'turn' && workerEvent.conversationId) {
                    client.workerThread(
                        request.runId,
                        workerEvent.conversationId,
                        workerEvent.turnId
                    );
                } else if (workerEvent.type === 'status' && workerEvent.state) {
                    client.workerStatus(request.runId, workerEvent.state);
                    state = { ...state, runState: workerEvent.state };
                    render();
                }
            });

            if (result.outcome === 'completed') {
                client.workerCompleted(request.runId, result.finalMessage ?? '');
            } else if (result.outcome === 'interrupted') {
                client.workerCancelled(request.runId);
            } else {
                client.workerFailed(request.runId, result.errorMessage ?? 'Codex reported a failure');
            }
        } catch (error) {
            const detail =
                error instanceof WorkerError
                    ? `${error.code}: ${error.message}`
                    : error instanceof Error
                      ? error.message
                      : 'official Codex worker failed';
            client.workerFailed(request.runId, detail);
        } finally {
            activeWorkerRunId = undefined;
        }
    };

    const render = (): void => {
        view.update(state);
        statusBar.text = `$(${statusIcon(state)}) Aiflow: ${statusLabel(state)}`;
        statusBar.tooltip = state.project
            ? `Aiflow — ${state.project} (${statusLabel(state)})`
            : 'Aiflow companion';
        statusBar.show();
        void vscode.commands.executeCommand(
            'setContext',
            'aiflow.waitingForApproval',
            Boolean(state.pendingApproval)
        );
        void vscode.commands.executeCommand(
            'setContext',
            'aiflow.waitingForInput',
            Boolean(state.pendingQuestion)
        );
    };

    client.on('connected', () => {
        state = { ...state, connected: true };
        // Tell the app whether this companion can act as the official Codex worker, so it
        // knows which backend to dispatch to. Presence of the extension is what is announced;
        // an unreachable IPC router still fails the individual run with a typed error.
        // The official worker remains opt-in pending final app-level acceptance. When enabled,
        // the host creates a fresh thread through the synthetic bootstrapper and never selects
        // an arbitrary conversation already open in the user's UI.
        announceOfficialWorker();
        render();
    });

    context.subscriptions.push(
        vscode.workspace.onDidChangeConfiguration((event) => {
            if (event.affectsConfiguration('aiflow.officialWorker.enabled')) {
                announceOfficialWorker();
            }
        })
    );

    client.on('authFailed', () => {
        // No token file yet, so Aiflow will send nothing beyond its greeting.
        void vscode.window.showWarningMessage(
            'Aiflow: no bridge token found. Start the Aiflow menu-bar app, then run "Aiflow: Reconnect".'
        );
    });

    client.on('disconnected', () => {
        // The run keeps going in Aiflow; only this viewer lost sight of it.
        state = { ...state, connected: false, runState: 'disconnected' };
        render();
    });

    client.on('event', (event: BridgeEvent) => {
        if (event.type === 'file_open' && event.path) {
            void openFile(event.path);
            return;
        }
        if (event.type === 'execute_run') {
            void executeRun(event);
            return;
        }
        if (event.type === 'cancel_run') {
            // Only the run the worker is actually serving may be interrupted.
            if (event.runId && event.runId === activeWorkerRunId) {
                void codex.cancel(event.runId);
            }
            return;
        }
        state = reduce(state, event);
        render();
    });

    context.subscriptions.push(
        vscode.commands.registerCommand('aiflow.reconnect', () => {
            client.reconnectNow();
            vscode.window.setStatusBarMessage('Aiflow: reconnecting…', 2000);
        }),

        vscode.commands.registerCommand('aiflow.focusView', () =>
            vscode.commands.executeCommand('aiflow.runView.focus')
        ),

        vscode.commands.registerCommand('aiflow.cancelRun', () => {
            // A worker run is interrupted at its exact official turn; otherwise the app
            // cancels the run it owns itself.
            if (activeWorkerRunId) {
                void codex.cancel(activeWorkerRunId);
            }
            if (!client.cancel()) {
                void vscode.window.showWarningMessage('Aiflow is not connected.');
            }
        }),

        vscode.commands.registerCommand('aiflow.approve', () => {
            const approval = state.pendingApproval;
            if (!approval) {
                void vscode.window.showInformationMessage('No approval is pending.');
                return;
            }
            client.approve(approval.requestId);
        }),

        vscode.commands.registerCommand('aiflow.deny', () => {
            const approval = state.pendingApproval;
            if (!approval) {
                void vscode.window.showInformationMessage('No approval is pending.');
                return;
            }
            client.deny(approval.requestId);
        }),

        vscode.commands.registerCommand('aiflow.answerQuestion', async () => {
            const pending = state.pendingQuestion;
            if (!pending) {
                void vscode.window.showInformationMessage('No question is pending.');
                return;
            }

            // Every question must be answered; the protocol keys answers by exact question id.
            const answers: Record<string, string> = {};
            for (const question of pending.questions) {
                const answer = question.options.length
                    ? await askWithOptions(question)
                    : await vscode.window.showInputBox({
                          title: question.header || 'Codex asks',
                          prompt: question.question,
                          password: question.isSecret,
                          ignoreFocusOut: true
                      });
                if (answer === undefined || answer.trim() === '') {
                    void vscode.window.showWarningMessage(
                        'Aiflow: answer cancelled — nothing was sent.'
                    );
                    return;
                }
                answers[question.id] = answer;
            }
            client.answerQuestion(pending.requestId, answers);
        })
    );

    render();
    client.connect();
}

async function askWithOptions(question: {
    header: string;
    question: string;
    options: { label: string; description: string }[];
    isOther: boolean;
    isSecret: boolean;
}): Promise<string | undefined> {
    const OTHER = 'Other…';
    const picks = question.options.map((option) => ({
        label: option.label,
        detail: option.description
    }));
    if (question.isOther) {
        picks.push({ label: OTHER, detail: 'Type a free-form answer' });
    }

    const choice = await vscode.window.showQuickPick(picks, {
        title: question.header || 'Codex asks',
        placeHolder: question.question,
        ignoreFocusOut: true
    });
    if (!choice) {
        return undefined;
    }
    if (choice.label !== OTHER) {
        return choice.label;
    }
    return vscode.window.showInputBox({
        title: question.header || 'Codex asks',
        prompt: question.question,
        password: question.isSecret,
        ignoreFocusOut: true
    });
}

/**
 * Opens a file Aiflow pointed at. Aiflow validates the path against the active saved
 * repository before sending it, and this never shells out to `code`.
 */
async function openFile(path: string): Promise<void> {
    try {
        const document = await vscode.workspace.openTextDocument(vscode.Uri.file(path));
        await vscode.window.showTextDocument(document, { preview: true });
    } catch {
        void vscode.window.showWarningMessage(`Aiflow could not open ${path}`);
    }
}

function statusIcon(state: AiflowState): string {
    if (!state.connected) {
        return 'circle-slash';
    }
    if (state.pendingApproval || state.pendingQuestion) {
        return 'warning';
    }
    switch (state.runState) {
        case 'running':
        case 'launching':
        case 'responding':
        case 'retrying':
        case 'cancelling':
            return 'sync~spin';
        case 'completed':
            return 'pass';
        case 'failed':
            return 'error';
        default:
            return 'circle-outline';
    }
}

export function deactivate(): void {
    // Nothing to tear down beyond the disposables registered above.
}
