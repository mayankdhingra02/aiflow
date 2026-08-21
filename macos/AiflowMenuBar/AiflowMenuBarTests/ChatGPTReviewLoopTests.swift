import XCTest

@testable import AiflowMenuBar

final class ChatGPTReviewLoopTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    func testParserAcceptsShip() throws {
        XCTAssertEqual(try parse("# Implementation Review\n\n## Verdict\n\nSHIP"), .ship)
    }

    func testParserAcceptsChangesRequestedInstruction() throws {
        XCTAssertEqual(
            try parse("# Implementation Review\n\n## Verdict\n\nCHANGES_REQUESTED\n\n## Codex Instruction\n\nFix the failing test."),
            .changesRequested(instruction: "Fix the failing test.")
        )
    }

    func testParserAcceptsRenderedChatGPTChangesRequested() throws {
        XCTAssertEqual(
            try parse("Implementation Review\nVerdict\n\nCHANGES_REQUESTED\n\nCodex Instruction\n\nChange aiflow-loop-acceptance.txt so that it contains exactly:\n\nPASS_2"),
            .changesRequested(instruction: "Change aiflow-loop-acceptance.txt so that it contains exactly:\n\nPASS_2")
        )
    }

    func testParserAcceptsRenderedChatGPTShip() throws {
        XCTAssertEqual(try parse("Implementation Review\nVerdict\n\nSHIP"), .ship)
    }

    func testParserRejectsMissingVerdict() { XCTAssertThrowsError(try parse("# Implementation Review\n\nNo verdict.")) }
    func testParserRejectsDuplicateVerdict() { XCTAssertThrowsError(try parse("# Implementation Review\n## Verdict\nSHIP\n## Verdict\nSHIP")) }
    func testParserRejectsUnknownVerdict() { XCTAssertThrowsError(try parse("# Implementation Review\n## Verdict\nMAYBE")) }
    func testParserRejectsContradictoryVerdict() { XCTAssertThrowsError(try parse("# Implementation Review\n## Verdict\nSHIP CHANGES_REQUESTED")) }
    func testParserRejectsMissingInstruction() { XCTAssertThrowsError(try parse("# Implementation Review\n## Verdict\nCHANGES_REQUESTED")) }
    func testParserRejectsAmbiguousHeading() { XCTAssertThrowsError(try parse("# Implementation Review\n## Verdict\nSHIP\n## Notes\nMaybe")) }

    func testDispatchStoreIsIdempotentAndConflictsFail() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ChatGPTReviewDispatchStore(directoryURL: directory)
        let value = sampleDispatch()
        XCTAssertEqual(try store.prepare(value), value)
        XCTAssertEqual(try store.prepare(value), value)
        let conflict = ChatGPTReviewDispatch(
            schemaVersion: value.schemaVersion, sourceRunId: value.sourceRunId,
            conversationId: value.conversationId, reviewCapturedAt: value.reviewCapturedAt,
            assistantMessage: "different", verdict: value.verdict, instruction: value.instruction,
            followUpRunId: value.followUpRunId, parentRunId: value.parentRunId, project: value.project,
            codexConversationId: value.codexConversationId, modelRole: value.modelRole,
            modelId: value.modelId, effort: value.effort, lineageDepth: value.lineageDepth,
            state: value.state, createdAt: value.createdAt, updatedAt: value.updatedAt,
            terminalReason: value.terminalReason
        )
        XCTAssertThrowsError(try store.prepare(conflict)) {
            XCTAssertEqual($0 as? ChatGPTReviewDispatchStoreError, .conflictingExistingRecord)
        }
    }

    func testDispatchStoreUnreadableRecordFailsClosed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ChatGPTReviewDispatchStore(directoryURL: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let value = sampleDispatch()
        let url = directory.appendingPathComponent("\(value.sourceRunId).json")
        let bytes = Data("malformed".utf8)
        try bytes.write(to: url)
        XCTAssertThrowsError(try store.prepare(value)) {
            XCTAssertEqual($0 as? ChatGPTReviewDispatchStoreError, .unreadableExistingRecord)
        }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    private func parse(_ text: String) throws -> ParsedChatGPTReview {
        try ChatGPTReviewParser.parse(ChatGPTReview(
            runId: UUID().uuidString, conversationId: "chat", sourceChatURL: "https://chatgpt.com/c/chat",
            assistantMessage: text, capturedAt: date
        ))
    }

    private func sampleDispatch() -> ChatGPTReviewDispatch {
        ChatGPTReviewDispatch(
            schemaVersion: 1, sourceRunId: UUID().uuidString, conversationId: "chat", reviewCapturedAt: date,
            assistantMessage: "# Implementation Review\n## Verdict\nCHANGES_REQUESTED\n## Codex Instruction\nFix it.",
            verdict: "CHANGES_REQUESTED", instruction: "Fix it.", followUpRunId: UUID().uuidString,
            parentRunId: nil, project: .init(id: UUID(), name: "demo", path: "/tmp/demo"),
            codexConversationId: "codex-chat", modelRole: "terra", modelId: "gpt-5.6-terra", effort: "low",
            lineageDepth: 1, state: .pending, createdAt: date, updatedAt: date, terminalReason: nil
        )
    }
}
