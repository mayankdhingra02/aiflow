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
    case invalidRecord
    case conflictingExistingRecord
    case unreadableExistingRecord
    case recordNotFound
    case storeIntegrityFailure
    case ambiguousFollowUp
    case writeVerificationFailed
}

final class ChatGPTReviewDispatchStore {
    let directoryURL: URL
    private let beforeWrite: ((ChatGPTReviewDispatch) throws -> Void)?

    init(
        directoryURL: URL = ChatGPTReviewDispatchStore.defaultDirectoryURL(),
        beforeWrite: ((ChatGPTReviewDispatch) throws -> Void)? = nil
    ) {
        self.directoryURL = directoryURL
        self.beforeWrite = beforeWrite
    }

    static func defaultDirectoryURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Aiflow/review-dispatches", isDirectory: true)
    }

    func record(sourceRunId: String) throws -> ChatGPTReviewDispatch? {
        guard UUID(uuidString: sourceRunId) != nil else {
            throw ChatGPTReviewDispatchStoreError.invalidRunId
        }
        let target = url(for: sourceRunId)
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        return try loadValidated(target, expectedSourceRunId: sourceRunId)
    }

    func allRecords() throws -> [ChatGPTReviewDispatch] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory)
        else { return [] }
        guard isDirectory.boolValue else {
            throw ChatGPTReviewDispatchStoreError.storeIntegrityFailure
        }

        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw ChatGPTReviewDispatchStoreError.storeIntegrityFailure
        }

        let records = try urls
            .filter { $0.pathExtension.lowercased() == "json" }
            .map { url in
                try loadValidated(
                    url,
                    expectedSourceRunId: url.deletingPathExtension().lastPathComponent
                )
            }
        try validateRelationships(records)
        return records.sorted {
            $0.createdAt == $1.createdAt
                ? $0.sourceRunId < $1.sourceRunId
                : $0.createdAt < $1.createdAt
        }
    }

    func pendingRecords() throws -> [ChatGPTReviewDispatch] {
        try allRecords().filter { $0.state == .pending }
    }

    func parentDepth(for sourceRunId: String) throws -> Int {
        let records = try allRecords()
        let parents = records.filter { $0.followUpRunId == sourceRunId }
        guard parents.count <= 1 else {
            throw ChatGPTReviewDispatchStoreError.ambiguousFollowUp
        }
        return parents.first?.lineageDepth ?? 0
    }

    @discardableResult
    func prepare(_ value: ChatGPTReviewDispatch) throws -> ChatGPTReviewDispatch {
        try validate(value, expectedSourceRunId: value.sourceRunId)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let target = url(for: value.sourceRunId)
        if FileManager.default.fileExists(atPath: target.path) {
            let existing = try loadValidated(
                target,
                expectedSourceRunId: value.sourceRunId
            )
            guard hasSameImmutableFields(existing, value) else {
                throw ChatGPTReviewDispatchStoreError.conflictingExistingRecord
            }
            return existing
        }

        let existing = try allRecords()
        try validateRelationships(existing + [value])
        try write(value, to: target)
        guard let persisted = try record(sourceRunId: value.sourceRunId),
              persisted == value else {
            throw ChatGPTReviewDispatchStoreError.writeVerificationFailed
        }
        return value
    }

    func update(
        sourceRunId: String,
        state: ChatGPTReviewDispatchState,
        reason: String? = nil
    ) throws {
        guard var value = try record(sourceRunId: sourceRunId) else {
            throw ChatGPTReviewDispatchStoreError.recordNotFound
        }
        guard value.state != .completed, value.state != .stopped,
              value.state != .manualAttention else { return }
        value.state = state
        value.updatedAt = Date()
        value.terminalReason = reason
        try write(value, to: url(for: sourceRunId))
        guard let persisted = try record(sourceRunId: sourceRunId),
              persisted.state == state,
              persisted.terminalReason == reason else {
            throw ChatGPTReviewDispatchStoreError.writeVerificationFailed
        }
    }

    /// Neither state is safe to resend after process death without reconstructed run context.
    func markAmbiguousDispatchesForManualAttention() throws {
        for value in try allRecords()
        where value.state == .dispatching || value.state == .dispatched {
            try update(
                sourceRunId: value.sourceRunId,
                state: .manualAttention,
                reason: "dispatch outcome was ambiguous across restart"
            )
        }
    }

    func markCompleted(followUpRunId: String, reason: String? = nil) throws {
        guard let record = try find(followUpRunId: followUpRunId) else { return }
        try update(sourceRunId: record.sourceRunId, state: .completed, reason: reason)
    }

    func markDispatched(followUpRunId: String) throws {
        guard let record = try find(followUpRunId: followUpRunId) else { return }
        try update(sourceRunId: record.sourceRunId, state: .dispatched)
    }

    private func find(followUpRunId: String) throws -> ChatGPTReviewDispatch? {
        let matches = try allRecords().filter { $0.followUpRunId == followUpRunId }
        guard matches.count <= 1 else {
            throw ChatGPTReviewDispatchStoreError.ambiguousFollowUp
        }
        return matches.first
    }

    private func url(for runId: String) -> URL {
        directoryURL.appendingPathComponent("\(runId).json")
    }

    private func loadValidated(
        _ url: URL,
        expectedSourceRunId: String
    ) throws -> ChatGPTReviewDispatch {
        let value: ChatGPTReviewDispatch
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            value = try decoder.decode(
                ChatGPTReviewDispatch.self,
                from: Data(contentsOf: url)
            )
        } catch {
            throw ChatGPTReviewDispatchStoreError.unreadableExistingRecord
        }
        try validate(value, expectedSourceRunId: expectedSourceRunId)
        return value
    }

    private func validate(
        _ value: ChatGPTReviewDispatch,
        expectedSourceRunId: String
    ) throws {
        guard value.schemaVersion == ChatGPTReviewDispatch.currentSchemaVersion,
              value.sourceRunId == expectedSourceRunId,
              UUID(uuidString: value.sourceRunId) != nil,
              !value.conversationId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.assistantMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.assistantMessage.lengthOfBytes(using: .utf8)
                <= ChatGPTReview.maximumAssistantMessageUTF8Bytes,
              ["CHANGES_REQUESTED", "SHIP", "INVALID"].contains(value.verdict),
              !value.project.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.lineageDepth >= 0,
              value.lineageDepth <= 5 else {
            throw ChatGPTReviewDispatchStoreError.invalidRecord
        }
        if let followUpRunId = value.followUpRunId {
            guard UUID(uuidString: followUpRunId) != nil,
                  value.verdict == "CHANGES_REQUESTED",
                  value.parentRunId == value.sourceRunId,
                  let instruction = value.instruction,
                  !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !value.codexConversationId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !value.modelRole.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !value.modelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !value.effort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ChatGPTReviewDispatchStoreError.invalidRecord
            }
        }
    }

    private func validateRelationships(_ records: [ChatGPTReviewDispatch]) throws {
        guard Set(records.map(\.sourceRunId)).count == records.count else {
            throw ChatGPTReviewDispatchStoreError.storeIntegrityFailure
        }
        let followUps = records.compactMap(\.followUpRunId)
        guard Set(followUps).count == followUps.count else {
            throw ChatGPTReviewDispatchStoreError.ambiguousFollowUp
        }

        let byFollowUp = Dictionary(uniqueKeysWithValues: records.compactMap { record in
            record.followUpRunId.map { ($0, record) }
        })
        var memo: [String: Int] = [:]

        func priorDepth(for sourceRunId: String, visiting: Set<String>) throws -> Int {
            if let cached = memo[sourceRunId] { return cached }
            guard !visiting.contains(sourceRunId) else {
                throw ChatGPTReviewDispatchStoreError.invalidRecord
            }
            guard let parent = byFollowUp[sourceRunId] else {
                memo[sourceRunId] = 0
                return 0
            }
            var next = visiting
            next.insert(sourceRunId)
            let parentPrior = try priorDepth(for: parent.sourceRunId, visiting: next)
            let expectedParentDepth = parentPrior + 1
            guard parent.lineageDepth == expectedParentDepth else {
                throw ChatGPTReviewDispatchStoreError.invalidRecord
            }
            memo[sourceRunId] = parent.lineageDepth
            return parent.lineageDepth
        }

        for record in records {
            let prior = try priorDepth(for: record.sourceRunId, visiting: [])
            let expected = record.followUpRunId == nil ? prior : prior + 1
            guard record.lineageDepth == expected else {
                throw ChatGPTReviewDispatchStoreError.invalidRecord
            }
        }
    }

    private func hasSameImmutableFields(
        _ left: ChatGPTReviewDispatch,
        _ right: ChatGPTReviewDispatch
    ) -> Bool {
        left.schemaVersion == right.schemaVersion
            && left.sourceRunId == right.sourceRunId
            && left.conversationId == right.conversationId
            && left.reviewCapturedAt == right.reviewCapturedAt
            && left.assistantMessage == right.assistantMessage
            && left.verdict == right.verdict
            && left.instruction == right.instruction
            && left.followUpRunId == right.followUpRunId
            && left.parentRunId == right.parentRunId
            && left.project == right.project
            && left.codexConversationId == right.codexConversationId
            && left.modelRole == right.modelRole
            && left.modelId == right.modelId
            && left.effort == right.effort
            && left.lineageDepth == right.lineageDepth
            && left.createdAt == right.createdAt
    }

    private func write(_ value: ChatGPTReviewDispatch, to url: URL) throws {
        try beforeWrite?(value)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}
