import Foundation

/// Presentation-only projection of durable review and dispatch evidence. It never writes to
/// either store, so a corrupt record remains visible as an integrity failure instead of being
/// silently omitted by the UI.
struct ReviewLoopReadModel: Equatable {
    struct Record: Identifiable, Equatable {
        enum Verdict: String, Equatable {
            case ship = "SHIP"
            case changesRequested = "CHANGES_REQUESTED"
            case invalid = "INVALID"

            var title: String {
                switch self {
                case .ship: return "Shipped"
                case .changesRequested: return "Changes requested"
                case .invalid: return "Review needs attention"
                }
            }
        }

        let sourceRunId: String
        let projectName: String
        let conversationId: String
        let codexConversationId: String?
        let capturedAt: Date
        let verdict: Verdict
        let dispatchState: ChatGPTReviewDispatchState
        let followUpRunId: String?
        let lineageDepth: Int
        let terminalReason: String?
        let assistantPreview: String
        let instructionPreview: String?

        var id: String { sourceRunId }
        var needsManualAttention: Bool { dispatchState == .manualAttention || verdict == .invalid }
        var isActive: Bool {
            switch dispatchState {
            case .pending, .dispatching, .dispatched, .manualAttention: return true
            case .completed, .stopped: return false
            }
        }

        var stateTitle: String {
            switch dispatchState {
            case .pending: return "Follow-up queued"
            case .dispatching: return "Dispatching follow-up"
            case .dispatched: return "Follow-up running"
            case .completed: return "Follow-up completed"
            case .stopped: return "Loop stopped"
            case .manualAttention: return "Needs attention"
            }
        }
    }

    let records: [Record]

    var current: Record? {
        records.first(where: \.isActive) ?? records.first
    }

    var manualAttentionCount: Int { records.filter(\.needsManualAttention).count }
    var hasQueuedFollowUp: Bool { records.contains { $0.dispatchState == .pending } }

    static func make(
        reviews: [ChatGPTReview],
        dispatches: [ChatGPTReviewDispatch]
    ) -> ReviewLoopReadModel {
        let dispatchBySource = Dictionary(uniqueKeysWithValues: dispatches.map { ($0.sourceRunId, $0) })
        var records = reviews.map { review -> Record in
            guard let dispatch = dispatchBySource[review.runId] else {
                return Record(
                    sourceRunId: review.runId,
                    projectName: "Unknown project",
                    conversationId: review.conversationId,
                    codexConversationId: nil,
                    capturedAt: review.capturedAt,
                    verdict: .invalid,
                    dispatchState: .pending,
                    followUpRunId: nil,
                    lineageDepth: 0,
                    terminalReason: "Review awaits durable dispatch validation",
                    assistantPreview: preview(review.assistantMessage, limit: 240),
                    instructionPreview: nil
                )
            }
            return record(dispatch)
        }

        let reviewRunIds = Set(reviews.map(\.runId))
        records += dispatches
            .filter { !reviewRunIds.contains($0.sourceRunId) }
            .map(record)

        return ReviewLoopReadModel(records: records.sorted {
            $0.capturedAt == $1.capturedAt
                ? $0.sourceRunId > $1.sourceRunId
                : $0.capturedAt > $1.capturedAt
        })
    }

    private static func record(_ dispatch: ChatGPTReviewDispatch) -> Record {
        Record(
            sourceRunId: dispatch.sourceRunId,
            projectName: dispatch.project.name,
            conversationId: dispatch.conversationId,
            codexConversationId: dispatch.codexConversationId.isEmpty ? nil : dispatch.codexConversationId,
            capturedAt: dispatch.reviewCapturedAt,
            verdict: Record.Verdict(rawValue: dispatch.verdict) ?? .invalid,
            dispatchState: dispatch.state,
            followUpRunId: dispatch.followUpRunId,
            lineageDepth: dispatch.lineageDepth,
            terminalReason: dispatch.terminalReason,
            assistantPreview: preview(dispatch.assistantMessage, limit: 240),
            instructionPreview: dispatch.instruction.map { preview($0, limit: 500) }
        )
    }

    private static func preview(_ value: String, limit: Int) -> String {
        let compact = value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return compact.count > limit ? String(compact.prefix(limit - 1)) + "…" : compact
    }
}
