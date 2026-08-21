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
        handoffForRunId: (String) throws -> RunResultHandoff?,
        followUpHandoffForRunId: (String) throws -> RunResultHandoff?
    ) throws {
        let reviewsByRunId = Dictionary(uniqueKeysWithValues: reviews.map { ($0.runId, $0) })
        for dispatch in dispatches {
            guard let review = reviewsByRunId[dispatch.sourceRunId],
                  let handoff = try handoffForRunId(dispatch.sourceRunId) else {
                throw ReviewLoopEvidenceError.inconsistentEvidence
            }
            let followUpHandoff: RunResultHandoff?
            if dispatch.state == .completed {
                guard let followUpRunId = dispatch.followUpRunId,
                      let handoff = try followUpHandoffForRunId(followUpRunId) else {
                    throw ReviewLoopEvidenceError.inconsistentEvidence
                }
                followUpHandoff = handoff
            } else {
                followUpHandoff = nil
            }
            try validate(
                review: review,
                dispatch: dispatch,
                handoff: handoff,
                followUpHandoff: followUpHandoff
            )
        }
    }

    static func validate(
        review: ChatGPTReview,
        dispatch: ChatGPTReviewDispatch,
        handoff: RunResultHandoff,
        followUpHandoff: RunResultHandoff? = nil
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

        guard (dispatch.recommendedModelRole == nil) == (dispatch.recommendedEffort == nil),
              dispatch.usesRecommendedExecution != true || dispatch.recommendedModelRole != nil else {
            throw ReviewLoopEvidenceError.inconsistentEvidence
        }

        do {
            switch try ChatGPTReviewParser.parse(review) {
            case .ship:
                guard dispatch.verdict == "SHIP", dispatch.instruction == nil,
                      dispatch.recommendedModelRole == nil,
                      dispatch.recommendedEffort == nil,
                      dispatch.usesRecommendedExecution != true else {
                    throw ReviewLoopEvidenceError.inconsistentEvidence
                }
            case let .changesRequested(instruction, recommendation):
                guard dispatch.verdict == "CHANGES_REQUESTED",
                      dispatch.instruction == instruction,
                      dispatch.recommendedModelRole == recommendation?.modelRole,
                      dispatch.recommendedEffort == recommendation?.effort,
                      dispatch.usesRecommendedExecution != true || recommendation != nil else {
                    throw ReviewLoopEvidenceError.inconsistentEvidence
                }
            }
        } catch is ChatGPTReviewParserError {
            guard dispatch.verdict == "INVALID",
                  dispatch.state == .manualAttention,
                  dispatch.instruction == nil,
                  dispatch.recommendedModelRole == nil,
                  dispatch.recommendedEffort == nil,
                  dispatch.usesRecommendedExecution != true else {
                throw ReviewLoopEvidenceError.inconsistentEvidence
            }
        }

        guard dispatch.state != .completed || followUpHandoff != nil,
              dispatch.state != .completed || dispatch.followUpRunId != nil else {
            throw ReviewLoopEvidenceError.inconsistentEvidence
        }
        guard let followUpHandoff else { return }
        guard let followUpRunId = dispatch.followUpRunId,
              followUpHandoff.runId == followUpRunId,
              followUpHandoff.sourceChat.conversationId == dispatch.conversationId,
              followUpHandoff.project == dispatch.project,
              followUpHandoff.execution.worker == "official-vscode",
              followUpHandoff.execution.codexConversationId == dispatch.codexConversationId else {
            throw ReviewLoopEvidenceError.inconsistentEvidence
        }

        if dispatch.usesRecommendedExecution == true {
            guard followUpHandoff.execution.modelRole == dispatch.recommendedModelRole,
                  followUpHandoff.execution.effort == dispatch.recommendedEffort else {
                throw ReviewLoopEvidenceError.inconsistentEvidence
            }
        } else {
            guard followUpHandoff.execution.modelRole == dispatch.modelRole,
                  followUpHandoff.execution.modelId == dispatch.modelId,
                  followUpHandoff.execution.effort == dispatch.effort else {
                throw ReviewLoopEvidenceError.inconsistentEvidence
            }
        }
    }
}
