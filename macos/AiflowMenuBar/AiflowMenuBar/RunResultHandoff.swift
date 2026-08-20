import Foundation

/// Stable, transport-neutral result of one terminal Aiflow run.
///
/// This is the boundary between local code execution and a future ChatGPT return transport.
/// It intentionally contains no original clipboard prompt.
struct RunResultHandoff: Codable, Equatable, Identifiable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let runId: String
    let outcome: Outcome
    let project: ProjectContext
    let sourceChat: ChatTarget
    let execution: ExecutionContext
    let result: ResultPayload
    let startedAt: Date
    let finishedAt: Date

    var id: String { runId }

    init(
        schemaVersion: Int = RunResultHandoff.currentSchemaVersion,
        runId: String,
        outcome: Outcome,
        project: ProjectContext,
        sourceChat: ChatTarget,
        execution: ExecutionContext,
        result: ResultPayload,
        startedAt: Date,
        finishedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.runId = runId
        self.outcome = outcome
        self.project = project
        self.sourceChat = sourceChat
        self.execution = execution
        self.result = result
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    enum Outcome: String, Codable, Equatable {
        case completed
        case failed
        case cancelled
    }

    struct ProjectContext: Codable, Equatable {
        let id: UUID
        let name: String
        let path: String
    }

    struct ChatTarget: Codable, Equatable {
        /// Canonical form: https://chatgpt.com/c/<conversation-id>
        let url: String
        let conversationId: String
    }

    struct ExecutionContext: Codable, Equatable {
        /// Current values are "official-vscode" or "legacy-app-server".
        let worker: String
        let modelRole: String
        let modelId: String
        let effort: String

        /// Populated for the official VS Code worker when already reported by its exact
        /// run-correlated worker_thread messages.
        ///
        /// Legacy App Server identifiers are deliberately not surfaced in its public event
        /// protocol in this PR, so they may be nil.
        let codexConversationId: String?
        let codexTurnId: String?
    }

    struct ResultPayload: Codable, Equatable {
        /// Exact final assistant message for a successful run, when Codex supplied one.
        let finalMessage: String?

        /// Exact terminal failure detail for a failed run.
        let errorMessage: String?
    }
}
