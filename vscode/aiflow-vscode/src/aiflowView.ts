import * as vscode from 'vscode';
import { AiflowState, statusLabel } from './protocol';

/**
 * A small read-only tree describing the Aiflow-owned run. Deliberately a TreeView rather
 * than a webview: this is a status surface, not a chat application.
 */
export class AiflowViewProvider implements vscode.TreeDataProvider<AiflowItem> {
    private readonly emitter = new vscode.EventEmitter<AiflowItem | undefined>();
    readonly onDidChangeTreeData = this.emitter.event;

    private state: AiflowState;

    constructor(state: AiflowState) {
        this.state = state;
    }

    update(state: AiflowState): void {
        this.state = state;
        this.emitter.fire(undefined);
    }

    getTreeItem(element: AiflowItem): vscode.TreeItem {
        return element;
    }

    getChildren(element?: AiflowItem): AiflowItem[] {
        if (element) {
            return [];
        }

        const s = this.state;
        const items: AiflowItem[] = [
            new AiflowItem(
                'Connection',
                s.connected ? 'Connected' : 'Disconnected',
                s.connected ? 'debug-disconnect' : 'circle-slash'
            ),
            new AiflowItem('Status', statusLabel(s), runIcon(s.runState)),
            new AiflowItem('Project', s.project ?? '—', 'repo'),
            new AiflowItem(
                'Model',
                s.model && s.effort ? `${s.model} / ${s.effort}` : (s.model ?? '—'),
                'settings-gear'
            )
        ];

        if (s.pendingApproval) {
            const approval = s.pendingApproval;
            items.push(
                new AiflowItem(
                    'Approval needed',
                    approval.summary ?? approval.kind ?? 'Codex needs approval',
                    'shield',
                    approval.detail
                )
            );
        }

        if (s.pendingQuestion) {
            const count = s.pendingQuestion.questions.length;
            items.push(
                new AiflowItem(
                    'Question',
                    count === 1
                        ? s.pendingQuestion.questions[0].question
                        : `${count} questions from Codex`,
                    'comment-discussion'
                )
            );
        }

        if (s.lastMessage) {
            items.push(new AiflowItem('Last message', firstLine(s.lastMessage), 'comment', s.lastMessage));
        }

        return items;
    }
}

function firstLine(text: string): string {
    const line = text.split('\n').find((candidate) => candidate.trim().length > 0) ?? text;
    return line.length > 120 ? `${line.slice(0, 120)}…` : line;
}

function runIcon(runState: string): string {
    switch (runState) {
        case 'running':
        case 'launching':
        case 'responding':
        case 'retrying':
            return 'sync';
        case 'waiting_for_approval':
        case 'waiting_for_input':
            return 'warning';
        case 'completed':
            return 'pass';
        case 'failed':
            return 'error';
        case 'cancelling':
        case 'cancelled':
            return 'circle-slash';
        default:
            return 'circle-outline';
    }
}

export class AiflowItem extends vscode.TreeItem {
    constructor(label: string, value: string, icon: string, tooltip?: string) {
        super(label, vscode.TreeItemCollapsibleState.None);
        this.description = value;
        this.iconPath = new vscode.ThemeIcon(icon);
        this.tooltip = tooltip ?? `${label}: ${value}`;
    }
}
