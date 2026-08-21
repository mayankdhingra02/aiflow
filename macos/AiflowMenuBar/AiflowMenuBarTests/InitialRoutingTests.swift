import XCTest
@testable import AiflowMenuBar

final class InitialRoutingTests: XCTestCase {
    private func request(state: CodexInitialRoutingState = .pending, response: String? = nil) -> CodexInitialRoutingRequest {
        .init(schemaVersion: 1, runId: UUID().uuidString,
              project: .init(id: UUID(), name: "demo", path: "/repos/demo"),
              sourceChat: .init(url: "https://chatgpt.com/c/chat", conversationId: "chat"),
              prompt: "Fix it", manualModelRole: "terra", manualModelId: "gpt-5.6-terra", manualEffort: "medium",
              assistantMessage: response, state: state, createdAt: Date(), updatedAt: Date(), terminalReason: nil)
    }
    func testParserRejectsAnythingOutsideExactContract() throws {
        XCTAssertEqual(try CodexInitialRoutingParser.parse("# Codex Routing\n## Model\nsol\n## Reasoning\nhigh"), .init(modelRole: "sol", effort: "high"))
        XCTAssertThrowsError(try CodexInitialRoutingParser.parse("# Codex Routing\n## Model\nsol\n## Reasoning\nhigh\nextra"))
    }

    func testRestartDoesNotReplayDeliveredRequest() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CodexInitialRoutingStore(directoryURL: directory)
        let request = request()
        try store.persist(request)
        try store.markDelivering(runId: request.runId)
        try store.markDelivered(runId: request.runId)
        _ = try store.reconcileAfterRestart()
        XCTAssertEqual(try store.record(runId: request.runId)?.state, .manualAttention)
    }

    func testEnumerationFailsClosedAndPreservesMalformedEvidence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CodexInitialRoutingStore(directoryURL: directory)
        try store.persist(request())
        let corruptURL = directory.appendingPathComponent("\(UUID().uuidString).json")
        let malformed = Data("not json".utf8)
        try malformed.write(to: corruptURL)
        XCTAssertThrowsError(try store.allRequests()) { error in
            XCTAssertEqual(error as? CodexInitialRoutingStoreError, .unreadableRecord)
        }
        XCTAssertEqual(try Data(contentsOf: corruptURL), malformed)
    }

    func testRestartLeavesOnlyPendingReplaySafe() throws {
        let states: [(CodexInitialRoutingState, String?)] = [(.pending, nil), (.delivering, nil), (.delivered, nil), (.completed, "# Codex Routing\n## Model\nsol\n## Reasoning\nhigh"), (.starting, "# Codex Routing\n## Model\nsol\n## Reasoning\nhigh"), (.started, "# Codex Routing\n## Model\nsol\n## Reasoning\nhigh"), (.cancelled, nil), (.manualAttention, nil)]
        for (state, response) in states {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = CodexInitialRoutingStore(directoryURL: directory)
            let record = request(state: state, response: response)
            try store.persist(record)
            _ = try store.reconcileAfterRestart()
            let expected: CodexInitialRoutingState = state == .pending || state == .cancelled || state == .manualAttention ? state : .manualAttention
            XCTAssertEqual(try store.record(runId: record.runId)?.state, expected, "\(state)")
        }
    }

    func testManualFallbackUsesSameRunAndPreventsLateResponse() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CodexInitialRoutingStore(directoryURL: directory)
        var record = request(state: .manualAttention)
        record.manualFallbackAvailable = true
        try store.persist(record)
        let starting = try store.beginManualFallback(runId: record.runId)
        XCTAssertEqual(starting.runId, record.runId)
        XCTAssertEqual(starting.manualModelRole, "terra")
        XCTAssertThrowsError(try store.captureResponse(runId: record.runId, conversationId: "chat", assistantMessage: "# Codex Routing\n## Model\nsol\n## Reasoning\nhigh"))
    }

    func testRestartAfterExecutionStartNeverOffersManualFallback() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CodexInitialRoutingStore(directoryURL: directory)
        let record = request(state: .starting)
        try store.persist(record)
        _ = try store.reconcileAfterRestart()
        XCTAssertEqual(try store.record(runId: record.runId)?.manualFallbackAvailable, false)
        XCTAssertThrowsError(try store.beginManualFallback(runId: record.runId))
    }
}
