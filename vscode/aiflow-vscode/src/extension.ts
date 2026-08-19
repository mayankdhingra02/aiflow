import * as vscode from 'vscode';
import { BridgeClient } from './bridgeClient';
import { AiflowViewProvider } from './aiflowView';
import { AiflowState, BridgeEvent, initialState, reduce, statusLabel } from './protocol';

/**
 * Aiflow companion. A live viewer/controller for the Codex run the Aiflow menu-bar app
 * already owns — it never launches Codex and never talks to the official Codex extension.
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
        render();
    });

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
