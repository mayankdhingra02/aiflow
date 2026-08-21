import Foundation

enum ChatGPTReviewStoreError: Error, Equatable {
    case invalidRunId
    case invalidReview
    case conflictingExistingRecord
    case unreadableExistingRecord
    case storeIntegrityFailure
}

/// Durable pending review inbox. Each run owns at most one immutable record.
final class ChatGPTReviewStore {
    let directoryURL: URL

    static func defaultDirectoryURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())

        return base.appendingPathComponent(
            "Aiflow/reviews/pending",
            isDirectory: true
        )
    }

    init(directoryURL: URL = ChatGPTReviewStore.defaultDirectoryURL()) {
        self.directoryURL = directoryURL
    }

    func persist(_ review: ChatGPTReview) throws {
        guard UUID(uuidString: review.runId) != nil else {
            throw ChatGPTReviewStoreError.invalidRunId
        }

        guard isValid(review) else {
            throw ChatGPTReviewStoreError.invalidReview
        }

        try ensureDirectory()
        let url = recordURL(runId: review.runId)

        if FileManager.default.fileExists(atPath: url.path) {
            guard let existing = load(url: url) else {
                throw ChatGPTReviewStoreError.unreadableExistingRecord
            }
            guard existing == review || hasSameEvidence(existing, review) else {
                throw ChatGPTReviewStoreError.conflictingExistingRecord
            }
            return
        }

        let data = try encoder().encode(review)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    func review(runId: String) -> ChatGPTReview? {
        guard UUID(uuidString: runId) != nil else { return nil }
        return load(url: recordURL(runId: runId))
    }

    /// Read-only diagnostic location for the immutable review evidence.
    func evidenceURL(runId: String) throws -> URL {
        guard UUID(uuidString: runId) != nil else {
            throw ChatGPTReviewStoreError.invalidRunId
        }
        return recordURL(runId: runId)
    }

    /// Execution-sensitive reads must distinguish absent evidence from corrupt evidence.
    func validatedReview(runId: String) throws -> ChatGPTReview? {
        guard UUID(uuidString: runId) != nil else {
            throw ChatGPTReviewStoreError.invalidRunId
        }
        let url = recordURL(runId: runId)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try loadValidated(url: url, expectedRunId: runId)
    }

    /// Enumerates the immutable inbox without silently dropping an unreadable review.
    func allReviews() throws -> [ChatGPTReview] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory)
        else { return [] }
        guard isDirectory.boolValue else {
            throw ChatGPTReviewStoreError.storeIntegrityFailure
        }

        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw ChatGPTReviewStoreError.storeIntegrityFailure
        }

        return try urls
            .filter { $0.pathExtension.lowercased() == "json" }
            .map { url in
                let runId = url.deletingPathExtension().lastPathComponent
                guard UUID(uuidString: runId) != nil else {
                    throw ChatGPTReviewStoreError.storeIntegrityFailure
                }
                return try loadValidated(url: url, expectedRunId: runId)
            }
            .sorted {
                $0.capturedAt == $1.capturedAt
                    ? $0.runId < $1.runId
                    : $0.capturedAt < $1.capturedAt
            }
    }

    private func isValid(_ review: ChatGPTReview) -> Bool {
        review.schemaVersion == ChatGPTReview.currentSchemaVersion
            && UUID(uuidString: review.runId) != nil
            && !review.conversationId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !review.sourceChatURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !review.assistantMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && review.assistantMessage.lengthOfBytes(using: .utf8)
                <= ChatGPTReview.maximumAssistantMessageUTF8Bytes
            && review.source == ChatGPTReview.sourceName
    }

    private func hasSameEvidence(
        _ left: ChatGPTReview,
        _ right: ChatGPTReview
    ) -> Bool {
        left.schemaVersion == right.schemaVersion
            && left.runId == right.runId
            && left.conversationId == right.conversationId
            && left.sourceChatURL == right.sourceChatURL
            && left.assistantMessage == right.assistantMessage
            && left.source == right.source
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
    }

    private func recordURL(runId: String) -> URL {
        directoryURL.appendingPathComponent("\(runId).json")
    }

    private func load(url: URL) -> ChatGPTReview? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder().decode(ChatGPTReview.self, from: data)
    }

    private func loadValidated(url: URL, expectedRunId: String) throws -> ChatGPTReview {
        let review: ChatGPTReview
        do {
            review = try decoder().decode(ChatGPTReview.self, from: Data(contentsOf: url))
        } catch {
            throw ChatGPTReviewStoreError.unreadableExistingRecord
        }
        guard review.runId == expectedRunId, isValid(review) else {
            throw ChatGPTReviewStoreError.storeIntegrityFailure
        }
        return review
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
