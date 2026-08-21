import Foundation

/// Immutable, transport-neutral capture of one completed ChatGPT Web review.
struct ChatGPTReview: Codable, Equatable, Identifiable {
    static let currentSchemaVersion = 1
    static let sourceName = "chatgpt-web"
    static let maximumAssistantMessageUTF8Bytes = 32 * 1024

    let schemaVersion: Int
    let runId: String
    let conversationId: String
    let sourceChatURL: String
    let assistantMessage: String
    let capturedAt: Date
    let source: String

    var id: String { runId }

    init(
        schemaVersion: Int = ChatGPTReview.currentSchemaVersion,
        runId: String,
        conversationId: String,
        sourceChatURL: String,
        assistantMessage: String,
        capturedAt: Date,
        source: String = ChatGPTReview.sourceName
    ) {
        self.schemaVersion = schemaVersion
        self.runId = runId
        self.conversationId = conversationId
        self.sourceChatURL = sourceChatURL
        self.assistantMessage = assistantMessage
        self.capturedAt = capturedAt
        self.source = source
    }
}
