import Foundation

enum ChatGPTReviewDispatchState: String, Codable, Equatable {
    case pending
    case dispatching
    case dispatched
    case completed
    case stopped
    case manualAttention
}

struct ChatGPTReviewDispatch: Codable, Equatable, Identifiable {
    static let currentSchemaVersion = 1
    let schemaVersion: Int
    let sourceRunId: String
    let conversationId: String
    let reviewCapturedAt: Date
    let assistantMessage: String
    let verdict: String
    let instruction: String?
    let followUpRunId: String?
    let parentRunId: String?
    let project: RunResultHandoff.ProjectContext
    let codexConversationId: String
    let modelRole: String
    let modelId: String
    let effort: String
    let lineageDepth: Int
    var state: ChatGPTReviewDispatchState
    let createdAt: Date
    var updatedAt: Date
    var terminalReason: String?

    var id: String { sourceRunId }
}

enum ChatGPTReviewDispatchStoreError: Error, Equatable {
    case invalidRunId
    case conflictingExistingRecord
    case unreadableExistingRecord
    case recordNotFound
}

final class ChatGPTReviewDispatchStore {
    let directoryURL: URL

    init(directoryURL: URL = ChatGPTReviewDispatchStore.defaultDirectoryURL()) {
        self.directoryURL = directoryURL
    }

    static func defaultDirectoryURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Aiflow/review-dispatches", isDirectory: true)
    }

    func record(sourceRunId: String) -> ChatGPTReviewDispatch? { load(url(for: sourceRunId)) }

    func pendingRecords() -> [ChatGPTReviewDispatch] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directoryURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return urls.compactMap(load)
            .filter { $0.state == .pending }
            .sorted { $0.createdAt == $1.createdAt ? $0.sourceRunId < $1.sourceRunId : $0.createdAt < $1.createdAt }
    }

    func parentDepth(for sourceRunId: String) -> Int {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directoryURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return 0 }
        return urls.compactMap(load).first { $0.followUpRunId == sourceRunId }?.lineageDepth ?? 0
    }

    @discardableResult
    func prepare(_ value: ChatGPTReviewDispatch) throws -> ChatGPTReviewDispatch {
        guard UUID(uuidString: value.sourceRunId) != nil else { throw ChatGPTReviewDispatchStoreError.invalidRunId }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let target = url(for: value.sourceRunId)
        if FileManager.default.fileExists(atPath: target.path) {
            guard let existing = load(target) else { throw ChatGPTReviewDispatchStoreError.unreadableExistingRecord }
            guard existing.sourceRunId == value.sourceRunId,
                  existing.conversationId == value.conversationId,
                  existing.assistantMessage == value.assistantMessage,
                  existing.verdict == value.verdict,
                  existing.instruction == value.instruction else {
                throw ChatGPTReviewDispatchStoreError.conflictingExistingRecord
            }
            return existing
        }
        try write(value, to: target)
        return value
    }

    func update(sourceRunId: String, state: ChatGPTReviewDispatchState, reason: String? = nil) throws {
        guard var value = record(sourceRunId: sourceRunId) else { throw ChatGPTReviewDispatchStoreError.recordNotFound }
        guard value.state != .completed, value.state != .stopped, value.state != .manualAttention else { return }
        value.state = state
        value.updatedAt = Date()
        value.terminalReason = reason
        try write(value, to: url(for: sourceRunId))
    }

    func markAmbiguousDispatchesForManualAttention() {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directoryURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
        for value in urls.compactMap(load) where value.state == .dispatching {
            try? update(sourceRunId: value.sourceRunId, state: .manualAttention, reason: "dispatch outcome was ambiguous across restart")
        }
    }

    func markCompleted(followUpRunId: String, reason: String? = nil) throws {
        guard let record = find(followUpRunId: followUpRunId) else { return }
        try update(sourceRunId: record.sourceRunId, state: .completed, reason: reason)
    }

    func markDispatched(followUpRunId: String) throws {
        guard let record = find(followUpRunId: followUpRunId) else { return }
        try update(sourceRunId: record.sourceRunId, state: .dispatched)
    }

    private func find(followUpRunId: String) -> ChatGPTReviewDispatch? {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directoryURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        return urls.compactMap(load).first { $0.followUpRunId == followUpRunId }
    }

    private func url(for runId: String) -> URL { directoryURL.appendingPathComponent("\(runId).json") }

    private func load(_ url: URL) -> ChatGPTReviewDispatch? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ChatGPTReviewDispatch.self, from: data)
    }

    private func write(_ value: ChatGPTReviewDispatch, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
