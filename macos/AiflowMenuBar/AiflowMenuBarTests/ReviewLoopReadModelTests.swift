import XCTest

@testable import AiflowMenuBar

final class ReviewLoopReadModelTests: XCTestCase {
    private let project = RunResultHandoff.ProjectContext(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        name: "demo",
        path: "/tmp/demo"
    )

    func testShipRendersStoppedAndShipped() {
        let runId = "00000000-0000-0000-0000-000000000010"
        let model = ReviewLoopReadModel.make(
            reviews: [review(runId: runId, capturedAt: Date(timeIntervalSince1970: 20))],
            dispatches: [dispatch(runId: runId, verdict: "SHIP", state: .stopped)]
        )

        XCTAssertEqual(model.current?.verdict, .ship)
        XCTAssertEqual(model.current?.dispatchState, .stopped)
        XCTAssertFalse(model.current?.isActive ?? true)
        XCTAssertEqual(model.current?.stateTitle, "Loop stopped")
    }

    func testChangesRequestedMapsQueuedRunningCompletedAndManualStates() {
        let states: [(ChatGPTReviewDispatchState, String)] = [
            (.pending, "Follow-up queued"),
            (.dispatching, "Dispatching follow-up"),
            (.dispatched, "Follow-up running"),
            (.completed, "Follow-up completed"),
            (.manualAttention, "Needs attention"),
        ]

        for (index, (state, expectedTitle)) in states.enumerated() {
            let runId = String(format: "00000000-0000-0000-0000-%012d", index + 20)
            let model = ReviewLoopReadModel.make(
                reviews: [review(runId: runId)],
                dispatches: [dispatch(runId: runId, verdict: "CHANGES_REQUESTED", state: state, depth: 3)]
            )

            XCTAssertEqual(model.current?.verdict, .changesRequested)
            XCTAssertEqual(model.current?.stateTitle, expectedTitle)
            XCTAssertEqual(model.current?.lineageDepth, 3)
            XCTAssertEqual(model.current?.isActive, state != .completed)
        }
    }

    func testManualAttentionPreservesBoundedReasonAndInstructionPreview() {
        let runId = "00000000-0000-0000-0000-000000000030"
        let model = ReviewLoopReadModel.make(
            reviews: [review(runId: runId)],
            dispatches: [dispatch(
                runId: runId,
                verdict: "INVALID",
                state: .manualAttention,
                reason: "dispatch outcome was ambiguous across restart",
                instruction: String(repeating: "x", count: 2_000)
            )]
        )

        XCTAssertEqual(model.manualAttentionCount, 1)
        XCTAssertEqual(model.current?.terminalReason, "dispatch outcome was ambiguous across restart")
        XCTAssertTrue((model.current?.instructionPreview?.count ?? 0) < 2_000)
        XCTAssertTrue(model.current?.needsManualAttention ?? false)
    }

    func testRecentRecordsAreNewestFirstWithDeterministicRunIDTieBreak() {
        let earlier = "00000000-0000-0000-0000-000000000040"
        let tiedLow = "00000000-0000-0000-0000-000000000041"
        let tiedHigh = "00000000-0000-0000-0000-000000000042"
        let first = Date(timeIntervalSince1970: 10)
        let second = Date(timeIntervalSince1970: 20)
        let model = ReviewLoopReadModel.make(
            reviews: [
                review(runId: earlier, capturedAt: first),
                review(runId: tiedLow, capturedAt: second),
                review(runId: tiedHigh, capturedAt: second),
            ],
            dispatches: [
                dispatch(runId: earlier, verdict: "SHIP", state: .stopped),
                dispatch(runId: tiedLow, verdict: "SHIP", state: .stopped),
                dispatch(runId: tiedHigh, verdict: "SHIP", state: .stopped),
            ]
        )

        XCTAssertEqual(model.records.map(\.sourceRunId), [tiedHigh, tiedLow, earlier])
    }

    private func review(runId: String, capturedAt: Date = Date(timeIntervalSince1970: 10)) -> ChatGPTReview {
        ChatGPTReview(
            runId: runId,
            conversationId: "chat",
            sourceChatURL: "https://chatgpt.com/c/chat",
            assistantMessage: "# Implementation Review\n\n## Verdict\n\nSHIP",
            capturedAt: capturedAt
        )
    }

    private func dispatch(
        runId: String,
        verdict: String,
        state: ChatGPTReviewDispatchState,
        depth: Int = 1,
        reason: String? = nil,
        instruction: String? = "Fix it."
    ) -> ChatGPTReviewDispatch {
        ChatGPTReviewDispatch(
            schemaVersion: 1,
            sourceRunId: runId,
            conversationId: "chat",
            reviewCapturedAt: Date(timeIntervalSince1970: 10),
            assistantMessage: "review",
            verdict: verdict,
            instruction: instruction,
            followUpRunId: UUID().uuidString,
            parentRunId: runId,
            project: project,
            codexConversationId: "codex-chat",
            modelRole: "terra",
            modelId: "gpt-5.6-terra",
            effort: "low",
            recommendedModelRole: nil,
            recommendedEffort: nil,
            usesRecommendedExecution: false,
            lineageDepth: depth,
            state: state,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 10),
            terminalReason: reason
        )
    }
}
