import Foundation

enum InitialRoutingMode: String, Equatable { case manual; case chatGPT }

enum CodexInitialRoutingState: String, Codable, Equatable {
    case pending, delivering, delivered, completed, starting, started
    case manualAttention = "manual_attention"
    case cancelled
}

struct CodexInitialRoutingRequest: Codable, Equatable, Identifiable {
    static let currentSchemaVersion = 1
    static let maximumPromptUTF8Bytes = 24 * 1024
    static let maximumAssistantMessageUTF8Bytes = 32 * 1024

    let schemaVersion: Int
    let runId: String
    let project: RunResultHandoff.ProjectContext
    let sourceChat: RunResultHandoff.ChatTarget
    let prompt: String
    let manualModelRole: String
    let manualModelId: String
    let manualEffort: String
    var assistantMessage: String?
    var state: CodexInitialRoutingState
    let createdAt: Date
    var updatedAt: Date
    var terminalReason: String?
    /// `nil` is retained for pre-flag records and fails closed. Only a transition that
    /// predates any execution start may explicitly opt into same-run manual fallback.
    var manualFallbackAvailable: Bool? = nil
    var id: String { runId }
}

struct CodexInitialRoutingSelection: Equatable { let modelRole: String; let effort: String }
enum CodexInitialRoutingParserError: Error, Equatable { case invalidContract }

enum CodexInitialRoutingParser {
    static func parse(_ text: String) throws -> CodexInitialRoutingSelection {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n")
        guard lines.count == 5, lines[0] == "# Codex Routing", lines[1] == "## Model",
              lines[3] == "## Reasoning", ["luna", "terra", "sol"].contains(lines[2]),
              ["low", "medium", "high", "xhigh"].contains(lines[4])
        else { throw CodexInitialRoutingParserError.invalidContract }
        return .init(modelRole: lines[2], effort: lines[4])
    }
}

enum CodexInitialRoutingStoreError: Error, Equatable {
    case invalidRunId
    case recordNotFound
    case unreadableRecord
    case invalidRecord
    case conflictingExistingRecord
    case invalidTransition
    case storeIntegrityFailure
}

/// Durable first-turn routing evidence. Enumeration is deliberately fail-closed: one unreadable
/// record blocks all automatic routing instead of allowing neighboring records to hide it.
final class CodexInitialRoutingStore {
    let directoryURL: URL

    static func defaultDirectoryURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Aiflow/initial-routing", isDirectory: true)
    }

    init(directoryURL: URL = CodexInitialRoutingStore.defaultDirectoryURL()) { self.directoryURL = directoryURL }

    func persist(_ request: CodexInitialRoutingRequest) throws {
        guard isValid(request) else { throw CodexInitialRoutingStoreError.invalidRecord }
        try ensureDirectory()
        let url = recordURL(request.runId)
        if FileManager.default.fileExists(atPath: url.path) {
            let existing = try loadValidated(url: url, expectedRunId: request.runId)
            guard existing == request else { throw CodexInitialRoutingStoreError.conflictingExistingRecord }
            return
        }
        try write(request, to: url)
    }

    func record(runId: String) throws -> CodexInitialRoutingRequest? {
        guard UUID(uuidString: runId) != nil else { throw CodexInitialRoutingStoreError.invalidRunId }
        let url = recordURL(runId)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try loadValidated(url: url, expectedRunId: runId)
    }

    func allRequests() throws -> [CodexInitialRoutingRequest] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) else { return [] }
        guard isDirectory.boolValue else { throw CodexInitialRoutingStoreError.storeIntegrityFailure }
        let urls: [URL]
        do { urls = try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) }
        catch { throw CodexInitialRoutingStoreError.storeIntegrityFailure }
        return try urls.filter { $0.pathExtension.lowercased() == "json" }.map { url in
            let runId = url.deletingPathExtension().lastPathComponent
            guard UUID(uuidString: runId) != nil else { throw CodexInitialRoutingStoreError.invalidRecord }
            return try loadValidated(url: url, expectedRunId: runId)
        }.sorted { $0.createdAt == $1.createdAt ? $0.runId < $1.runId : $0.createdAt < $1.createdAt }
    }

    func pendingRequest() throws -> CodexInitialRoutingRequest? {
        try allRequests().first { $0.state == .pending }
    }

    func markDelivering(runId: String) throws { try transition(runId, from: [.pending], to: .delivering) }
    func markDelivered(runId: String) throws { try transition(runId, from: [.delivering, .delivered], to: .delivered) }

    func captureResponse(runId: String, conversationId: String, assistantMessage: String) throws -> CodexInitialRoutingRequest {
        guard UUID(uuidString: runId) != nil else { throw CodexInitialRoutingStoreError.invalidRunId }
        guard !conversationId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !assistantMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              assistantMessage.lengthOfBytes(using: .utf8) <= CodexInitialRoutingRequest.maximumAssistantMessageUTF8Bytes
        else { throw CodexInitialRoutingStoreError.invalidRecord }
        return try update(runId) { request in
            guard request.state == .delivered, request.sourceChat.conversationId == conversationId else {
                throw CodexInitialRoutingStoreError.invalidTransition
            }
            request.assistantMessage = assistantMessage
            request.state = .completed
        }
    }

    /// This must complete before any worker dispatch. It is the one-way no-replay boundary.
    func beginExecution(runId: String) throws -> CodexInitialRoutingRequest {
        try transitionAndReturn(runId, from: [.completed], to: .starting)
    }

    func beginManualFallback(runId: String) throws -> CodexInitialRoutingRequest {
        try update(runId) { request in
            guard request.state == .manualAttention, request.manualFallbackAvailable == true else {
                throw CodexInitialRoutingStoreError.invalidTransition
            }
            request.state = .starting
            request.manualFallbackAvailable = false
        }
    }

    func markStarted(runId: String) throws { try transition(runId, from: [.starting], to: .started) }
    func markCancelled(runId: String) throws { try transition(runId, from: [.pending, .delivering, .delivered, .completed], to: .cancelled) }

    func markManualAttention(runId: String, reason: String, manualFallbackAvailable: Bool = false) throws {
        _ = try update(runId) { request in
            switch request.state {
            // These states prove that no Codex dispatch has begun. They may offer the user the
            // same-run manual selection exactly once.
            case .pending, .delivering, .delivered, .completed:
                request.state = .manualAttention
                request.terminalReason = String(reason.prefix(300))
                request.manualFallbackAvailable = manualFallbackAvailable

            // Crossing into `.starting` is the durable no-replay boundary. Attention is still
            // useful, but it can never create a second execution path.
            case .starting, .started:
                guard !manualFallbackAvailable else { throw CodexInitialRoutingStoreError.invalidTransition }
                request.state = .manualAttention
                request.terminalReason = String(reason.prefix(300))
                request.manualFallbackAvailable = false

            // A manual-attention record keeps its existing fallback right. In particular, stale
            // evidence cannot elevate an execution-ambiguous record from false/nil to true.
            case .manualAttention:
                guard !manualFallbackAvailable || request.manualFallbackAvailable == true else {
                    throw CodexInitialRoutingStoreError.invalidTransition
                }
                request.terminalReason = String(reason.prefix(300))

            case .cancelled:
                throw CodexInitialRoutingStoreError.invalidTransition
            }
        }
    }

    /// Browser reconnects within one live macOS process may retry pending routing. After a macOS
    /// restart, however, the app-lifetime execution owner is gone, so every non-cancelled
    /// in-flight state becomes attention rather than being exposed for automatic replay.
    func reconcileAfterRestart() throws -> [CodexInitialRoutingRequest] {
        let requests = try allRequests()
        var changed: [CodexInitialRoutingRequest] = []
        for request in requests where [.pending, .delivering, .delivered, .completed, .starting, .started].contains(request.state) {
            let isPreDispatch = [.pending, .delivering, .delivered, .completed].contains(request.state)
            try markManualAttention(
                runId: request.runId,
                reason: "Aiflow restarted while initial routing was in progress.",
                manualFallbackAvailable: isPreDispatch
            )
            if let updated = try record(runId: request.runId) { changed.append(updated) }
        }
        return changed
    }

    private func transition(_ runId: String, from allowed: Set<CodexInitialRoutingState>, to state: CodexInitialRoutingState) throws {
        _ = try transitionAndReturn(runId, from: allowed, to: state)
    }

    private func transitionAndReturn(_ runId: String, from allowed: Set<CodexInitialRoutingState>, to state: CodexInitialRoutingState) throws -> CodexInitialRoutingRequest {
        try update(runId) { request in
            guard allowed.contains(request.state) else { throw CodexInitialRoutingStoreError.invalidTransition }
            request.state = state
        }
    }

    private func update(_ runId: String, mutate: (inout CodexInitialRoutingRequest) throws -> Void) throws -> CodexInitialRoutingRequest {
        guard UUID(uuidString: runId) != nil else { throw CodexInitialRoutingStoreError.invalidRunId }
        let url = recordURL(runId)
        guard FileManager.default.fileExists(atPath: url.path) else { throw CodexInitialRoutingStoreError.recordNotFound }
        var request = try loadValidated(url: url, expectedRunId: runId)
        try mutate(&request)
        request.updatedAt = Date()
        guard isValid(request) else { throw CodexInitialRoutingStoreError.invalidRecord }
        try write(request, to: url)
        return request
    }

    private func isValid(_ request: CodexInitialRoutingRequest) -> Bool {
        let hasResponse = !(request.assistantMessage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        return request.schemaVersion == CodexInitialRoutingRequest.currentSchemaVersion &&
            UUID(uuidString: request.runId) != nil && !request.project.name.isEmpty && !request.project.path.isEmpty &&
            ChatURL.normalize(request.sourceChat.url) == request.sourceChat.url &&
            ChatURL.conversationID(from: request.sourceChat.url) == request.sourceChat.conversationId &&
            !request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            request.prompt.lengthOfBytes(using: .utf8) <= CodexInitialRoutingRequest.maximumPromptUTF8Bytes &&
            !request.manualModelRole.isEmpty && !request.manualModelId.isEmpty && !request.manualEffort.isEmpty &&
            (request.assistantMessage?.lengthOfBytes(using: .utf8) ?? 0) <= CodexInitialRoutingRequest.maximumAssistantMessageUTF8Bytes &&
            // A manually recovered request enters `starting` without a ChatGPT response;
            // only `completed` itself proves that an automatic recommendation was captured.
            (request.state != .completed || hasResponse)
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
    }
    private func recordURL(_ runId: String) -> URL { directoryURL.appendingPathComponent("\(runId).json") }
    private func loadValidated(url: URL, expectedRunId: String) throws -> CodexInitialRoutingRequest {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let request: CodexInitialRoutingRequest
        do { request = try decoder.decode(CodexInitialRoutingRequest.self, from: Data(contentsOf: url)) }
        catch { throw CodexInitialRoutingStoreError.unreadableRecord }
        guard request.runId == expectedRunId, isValid(request) else { throw CodexInitialRoutingStoreError.invalidRecord }
        return request
    }
    private func write(_ request: CodexInitialRoutingRequest, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(request).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
