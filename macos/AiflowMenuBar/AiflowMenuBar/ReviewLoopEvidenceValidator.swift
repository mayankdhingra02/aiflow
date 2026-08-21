import Foundation

enum ReviewLoopEvidenceError: Error, Equatable {
    case inconsistentEvidence
}

/// Validates the immutable evidence graph before it is presented or used for recovery.
/// Orphan reviews are a legitimate crash-window state; orphan dispatch records are not.
enum ReviewLoopEvidenceValidator {
    static func validate(
        reviews: [ChatGPTReview],
        dispatches: [ChatGPTReviewDispatch],
        handoffForRunId: (String) throws -> RunResultHandoff?
    ) throws {
        let reviewsByRunId = Dictionary(uniqueKeysWithValues: reviews.map { ($0.runId, $0) })
        for dispatch in dispatches {
            guard let review = reviewsByRunId[dispatch.sourceRunId],
                  let handoff = try handoffForRunId(dispatch.sourceRunId) else {
                throw ReviewLoopEvidenceError.inconsistentEvidence
            }
            try validate(review: review, dispatch: dispatch, handoff: handoff)
        }
    }

    static func validate(
        review: ChatGPTReview,
        dispatch: ChatGPTReviewDispatch,
        handoff: RunResultHandoff
    ) throws {
        guard review.runId == dispatch.sourceRunId,
              review.conversationId == dispatch.conversationId,
              review.capturedAt == dispatch.reviewCapturedAt,
              review.assistantMessage == dispatch.assistantMessage,
              handoff.runId == review.runId,
              handoff.sourceChat.conversationId == review.conversationId,
              handoff.project == dispatch.project,
              handoff.execution.modelRole == dispatch.modelRole,
              handoff.execution.modelId == dispatch.modelId,
              handoff.execution.effort == dispatch.effort else {
            throw ReviewLoopEvidenceError.inconsistentEvidence
        }

        if !dispatch.codexConversationId.isEmpty {
            guard handoff.execution.codexConversationId == dispatch.codexConversationId else {
                throw ReviewLoopEvidenceError.inconsistentEvidence
            }
        }

        do {
            switch try ChatGPTReviewParser.parse(review) {
            case .ship:
                guard dispatch.verdict == "SHIP", dispatch.instruction == nil else {
                    throw ReviewLoopEvidenceError.inconsistentEvidence
                }
            case .changesRequested(let instruction):
                guard dispatch.verdict == "CHANGES_REQUESTED",
                      dispatch.instruction == instruction else {
                    throw ReviewLoopEvidenceError.inconsistentEvidence
                }
            }
        } catch is ChatGPTReviewParserError {
            guard dispatch.verdict == "INVALID",
                  dispatch.state == .manualAttention,
                  dispatch.instruction == nil else {
                throw ReviewLoopEvidenceError.inconsistentEvidence
            }
        }
    }
}
