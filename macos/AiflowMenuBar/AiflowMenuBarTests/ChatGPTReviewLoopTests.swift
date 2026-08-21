import XCTest

@testable import AiflowMenuBar

@MainActor
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

    func testDispatchPersistenceFailureStartsZeroTurns() throws {
        let harness = try makeHarness { value in
            if value.state == .dispatching { throw TestError.writeFailed }
        }
        defer { harness.remove() }
        let runId = UUID().uuidString
        try persistChangesRequestedEvidence(runId: runId, harness: harness)
        try harness.dispatchStore.prepare(sampleDispatch(
            sourceRunId: runId, project: harness.project
        ))

        harness.viewModel.setOfficialWorkerAvailable(true)

        XCTAssertTrue(harness.recorder.events.isEmpty)
        XCTAssertEqual(try harness.dispatchStore.record(sourceRunId: runId)?.state, .pending)
        XCTAssertFalse(harness.viewModel.runState.isBusy)
    }

    func testOrphanChangesRequestedReviewRecoversExactlyOnePendingDispatch() throws {
        let harness = try makeHarness()
        defer { harness.remove() }
        let runId = UUID().uuidString
        try persistChangesRequestedEvidence(runId: runId, harness: harness)

        harness.viewModel.reconcileReviewsForTesting()
        harness.viewModel.reconcileReviewsForTesting()

        let records = try harness.dispatchStore.allRecords()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.sourceRunId, runId)
        XCTAssertEqual(records.first?.state, .pending)
    }

    func testOrphanShipReviewRecoversStoppedStateWithoutSending() throws {
        let harness = try makeHarness()
        defer { harness.remove() }
        let runId = UUID().uuidString
        try persistEvidence(
            runId: runId,
            message: "# Implementation Review\n\n## Verdict\n\nSHIP",
            harness: harness
        )
        harness.viewModel.setOfficialWorkerAvailable(true)

        harness.viewModel.reconcileReviewsForTesting()

        XCTAssertEqual(try harness.dispatchStore.record(sourceRunId: runId)?.state, .stopped)
        XCTAssertTrue(harness.recorder.events.isEmpty)
        XCTAssertEqual(harness.viewModel.currentReviewLoopStatus?.verdict, .ship)
        XCTAssertEqual(harness.viewModel.currentReviewLoopStatus?.dispatchState, .stopped)
    }

    func testReviewWithExistingDispatchDoesNotDuplicate() throws {
        let harness = try makeHarness()
        defer { harness.remove() }
        let runId = UUID().uuidString
        try persistChangesRequestedEvidence(runId: runId, harness: harness)
        let existing = sampleDispatch(sourceRunId: runId, project: harness.project)
        try harness.dispatchStore.prepare(existing)

        harness.viewModel.reconcileReviewsForTesting()

        XCTAssertEqual(try harness.dispatchStore.allRecords(), [existing])
    }

    func testUnreadableReviewStopsAllAutomaticExecution() throws {
        let harness = try makeHarness()
        defer { harness.remove() }
        harness.viewModel.setOfficialWorkerAvailable(true)
        let runId = UUID().uuidString
        try harness.dispatchStore.prepare(sampleDispatch(
            sourceRunId: runId, project: harness.project
        ))
        try FileManager.default.createDirectory(
            at: harness.reviewStore.directoryURL,
            withIntermediateDirectories: true
        )
        try Data("malformed".utf8).write(
            to: harness.reviewStore.directoryURL.appendingPathComponent("\(runId).json")
        )

        harness.viewModel.reconcileReviewsForTesting()

        XCTAssertTrue(harness.recorder.events.isEmpty)
        XCTAssertEqual(try harness.dispatchStore.record(sourceRunId: runId)?.state, .pending)
        XCTAssertTrue(harness.viewModel.reviewAutomationBlocked)
        XCTAssertNotNil(harness.viewModel.reviewAutomationBlockReason)
        XCTAssertTrue(harness.viewModel.recentReviewLoopRecords.isEmpty)
    }

    func testRestartStateSemanticsNeverResendAmbiguousRecords() throws {
        let expected: [(ChatGPTReviewDispatchState, ChatGPTReviewDispatchState)] = [
            (.pending, .pending),
            (.dispatching, .manualAttention),
            (.dispatched, .manualAttention),
            (.completed, .completed),
            (.stopped, .stopped),
            (.manualAttention, .manualAttention),
        ]
        for (initial, recovered) in expected {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = ChatGPTReviewDispatchStore(directoryURL: directory)
            let value = sampleDispatch(state: initial)
            try store.prepare(value)

            try store.markAmbiguousDispatchesForManualAttention()

            XCTAssertEqual(
                try store.record(sourceRunId: value.sourceRunId)?.state,
                recovered,
                "restart state \(initial)"
            )
        }
    }

    func testUnreadableDispatchRecordStartsZeroTurns() throws {
        let harness = try makeHarness()
        defer { harness.remove() }
        harness.viewModel.setOfficialWorkerAvailable(true)
        let orphanRunId = UUID().uuidString
        try persistChangesRequestedEvidence(runId: orphanRunId, harness: harness)
        try FileManager.default.createDirectory(
            at: harness.dispatchStore.directoryURL,
            withIntermediateDirectories: true
        )
        try Data("malformed".utf8).write(
            to: harness.dispatchStore.directoryURL
                .appendingPathComponent("\(UUID().uuidString).json")
        )

        harness.viewModel.reconcileReviewsForTesting()

        XCTAssertTrue(harness.recorder.events.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: harness.dispatchStore.directoryURL
                .appendingPathComponent("\(orphanRunId).json").path
        ))
    }

    func testUnreadableLineageParentCannotResetDepth() throws {
        let harness = try makeHarness()
        defer { harness.remove() }
        let runId = UUID().uuidString
        try persistChangesRequestedEvidence(runId: runId, harness: harness)
        try FileManager.default.createDirectory(
            at: harness.dispatchStore.directoryURL,
            withIntermediateDirectories: true
        )
        try Data("malformed parent".utf8).write(
            to: harness.dispatchStore.directoryURL
                .appendingPathComponent("\(UUID().uuidString).json")
        )

        harness.viewModel.reconcileReviewsForTesting()

        XCTAssertTrue(harness.recorder.events.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: harness.dispatchStore.directoryURL
                .appendingPathComponent("\(runId).json").path
        ))
    }

    func testConflictingProjectAndCodexConversationFailClosed() throws {
        let harness = try makeHarness()
        defer { harness.remove() }
        let runId = UUID().uuidString
        try persistChangesRequestedEvidence(runId: runId, harness: harness)
        let wrongProject = RunResultHandoff.ProjectContext(
            id: UUID(), name: "retargeted", path: "/tmp/retargeted"
        )
        try harness.dispatchStore.prepare(sampleDispatch(
            sourceRunId: runId,
            projectContext: wrongProject,
            codexConversationId: "different-codex-conversation"
        ))

        harness.viewModel.setOfficialWorkerAvailable(true)

        XCTAssertTrue(harness.recorder.events.isEmpty)
        XCTAssertEqual(
            try harness.dispatchStore.record(sourceRunId: runId)?.state,
            .manualAttention
        )
    }

    func testAlteredInstructionFailsClosed() throws {
        let harness = try makeHarness()
        defer { harness.remove() }
        let runId = UUID().uuidString
        try persistChangesRequestedEvidence(runId: runId, harness: harness)
        try harness.dispatchStore.prepare(sampleDispatch(
            sourceRunId: runId,
            project: harness.project,
            instruction: "Do something else."
        ))

        harness.viewModel.setOfficialWorkerAvailable(true)

        XCTAssertTrue(harness.recorder.events.isEmpty)
        XCTAssertEqual(
            try harness.dispatchStore.record(sourceRunId: runId)?.state,
            .manualAttention
        )
    }

    func testFiveFollowupsStillBlockTheSixth() throws {
        let harness = try makeHarness()
        defer { harness.remove() }
        var sourceRunId = UUID().uuidString
        for depth in 1...5 {
            let followUpRunId = UUID().uuidString
            try harness.dispatchStore.prepare(sampleDispatch(
                sourceRunId: sourceRunId,
                followUpRunId: followUpRunId,
                project: harness.project,
                lineageDepth: depth
            ))
            sourceRunId = followUpRunId
        }
        try persistChangesRequestedEvidence(runId: sourceRunId, harness: harness)
        harness.viewModel.setOfficialWorkerAvailable(true)

        harness.viewModel.reconcileReviewsForTesting()

        let blocked = try XCTUnwrap(
            harness.dispatchStore.record(sourceRunId: sourceRunId)
        )
        XCTAssertEqual(blocked.state, .manualAttention)
        XCTAssertNil(blocked.followUpRunId)
        XCTAssertEqual(blocked.lineageDepth, 5)
        XCTAssertTrue(harness.recorder.events.isEmpty)
    }

    func testQueuedReviewResumesWhenLegacyRunBecomesIdle() throws {
        let harness = try makeHarness()
        defer { harness.remove() }
        let sourceRunId = UUID().uuidString
        try persistChangesRequestedEvidence(runId: sourceRunId, harness: harness)
        harness.viewModel.reconcileReviewsForTesting()
        harness.viewModel.startRunForTesting(
            harness.project,
            worker: .legacyAppServer,
            runId: UUID().uuidString
        )
        harness.viewModel.setOfficialWorkerAvailable(true)
        XCTAssertTrue(harness.recorder.events.isEmpty)

        harness.viewModel.handleEventForTesting(.finished, project: harness.project)

        XCTAssertEqual(harness.recorder.events.count, 1)
        XCTAssertEqual(harness.recorder.events.first?.type, .executeFollowup)
        XCTAssertEqual(
            try harness.dispatchStore.record(sourceRunId: sourceRunId)?.state,
            .dispatching
        )
    }

    func testReviewShipNotificationIsDeliveredOnce() throws {
        let notifications = RecordingNotifications()
        let harness = try makeHarness(notifications: notifications)
        defer { harness.remove() }
        let runId = UUID().uuidString
        try persistEvidence(
            runId: runId,
            message: "# Implementation Review\n\n## Verdict\n\nSHIP",
            harness: harness
        )
        harness.viewModel.setNotificationsAvailableForTesting(true)

        harness.viewModel.reconcileReviewsForTesting()
        harness.viewModel.reconcileReviewsForTesting()

        XCTAssertEqual(notifications.shipProjects, [harness.project.name])
    }

    func testManualAttentionNotificationAndRecheckNeverResendAmbiguousDispatch() throws {
        let notifications = RecordingNotifications()
        let harness = try makeHarness(notifications: notifications)
        defer { harness.remove() }
        let runId = UUID().uuidString
        try persistChangesRequestedEvidence(runId: runId, harness: harness)
        try harness.dispatchStore.prepare(sampleDispatch(
            sourceRunId: runId,
            project: harness.project,
            instruction: "A different instruction."
        ))
        harness.viewModel.setNotificationsAvailableForTesting(true)
        harness.viewModel.setOfficialWorkerAvailable(true)

        harness.viewModel.reconcileReviewsForTesting()
        harness.viewModel.recheckReviewEvidence()

        XCTAssertEqual(try harness.dispatchStore.record(sourceRunId: runId)?.state, .manualAttention)
        XCTAssertEqual(notifications.manualAttentionProjects, [harness.project.name])
        XCTAssertTrue(harness.recorder.events.isEmpty)
        XCTAssertEqual(harness.viewModel.reviewManualAttentionCount, 1)

        harness.viewModel.applyConfigForTesting(CodexConfig(
            models: [CodexModel(role: "terra", modelId: "gpt-5.6-terra")],
            reasoningEfforts: ["low"],
            defaultSandbox: "workspace-write"
        ))
        try FileManager.default.createDirectory(
            atPath: harness.project.path,
            withIntermediateDirectories: true
        )
        let record = try XCTUnwrap(harness.viewModel.currentReviewLoopStatus)
        XCTAssertTrue(harness.viewModel.canStartManualRecoveryRun(record))
        harness.viewModel.requestManualRecoveryRun(record)
        XCTAssertEqual(harness.viewModel.confirmingProject?.id, harness.project.id)
        XCTAssertTrue(harness.viewModel.confirmationPromptPreview.contains("Fix it."))
        XCTAssertFalse(harness.viewModel.confirmationPromptPreview.contains("A different instruction."))
        XCTAssertEqual(try harness.dispatchStore.record(sourceRunId: runId)?.state, .manualAttention)
        XCTAssertTrue(harness.recorder.events.isEmpty)
        harness.viewModel.cancelConfirmation()
    }

    func testBlockedEvidenceRecheckRequiresSuccessfulIntegrityValidation() throws {
        let notifications = RecordingNotifications()
        let harness = try makeHarness(notifications: notifications)
        defer { harness.remove() }
        harness.viewModel.setNotificationsAvailableForTesting(true)
        try FileManager.default.createDirectory(
            at: harness.reviewStore.directoryURL,
            withIntermediateDirectories: true
        )
        let corrupt = harness.reviewStore.directoryURL.appendingPathComponent("corrupt.json")
        try Data("not-json".utf8).write(to: corrupt)

        harness.viewModel.reconcileReviewsForTesting()
        harness.viewModel.recheckReviewEvidence()

        XCTAssertTrue(harness.viewModel.reviewAutomationBlocked)
        XCTAssertEqual(notifications.blockReasons.count, 1)
        XCTAssertTrue(harness.recorder.events.isEmpty)

        try FileManager.default.removeItem(at: corrupt)
        harness.viewModel.recheckReviewEvidence()

        XCTAssertFalse(harness.viewModel.reviewAutomationBlocked)
        XCTAssertTrue(harness.recorder.events.isEmpty)
    }

    func testSuccessfulRecheckResumesOnlyValidatedPendingReview() throws {
        let harness = try makeHarness()
        defer { harness.remove() }
        let runId = UUID().uuidString
        try persistChangesRequestedEvidence(runId: runId, harness: harness)
        harness.viewModel.reconcileReviewsForTesting()
        XCTAssertEqual(try harness.dispatchStore.record(sourceRunId: runId)?.state, .pending)

        try FileManager.default.createDirectory(
            at: harness.reviewStore.directoryURL,
            withIntermediateDirectories: true
        )
        let corrupt = harness.reviewStore.directoryURL.appendingPathComponent("corrupt.json")
        try Data("not-json".utf8).write(to: corrupt)
        harness.viewModel.reconcileReviewsForTesting()
        XCTAssertTrue(harness.viewModel.reviewAutomationBlocked)

        try FileManager.default.removeItem(at: corrupt)
        harness.viewModel.setOfficialWorkerAvailable(true)
        harness.viewModel.recheckReviewEvidence()

        XCTAssertFalse(harness.viewModel.reviewAutomationBlocked)
        XCTAssertEqual(harness.recorder.events.count, 1)
        XCTAssertEqual(harness.recorder.events.first?.type, .executeFollowup)
        XCTAssertEqual(try harness.dispatchStore.record(sourceRunId: runId)?.state, .dispatching)
    }

    private func parse(_ text: String) throws -> ParsedChatGPTReview {
        try ChatGPTReviewParser.parse(ChatGPTReview(
            runId: UUID().uuidString, conversationId: "chat", sourceChatURL: "https://chatgpt.com/c/chat",
            assistantMessage: text, capturedAt: date
        ))
    }

    private func sampleDispatch(
        sourceRunId: String = UUID().uuidString,
        followUpRunId: String? = UUID().uuidString,
        project: SavedProject? = nil,
        projectContext: RunResultHandoff.ProjectContext? = nil,
        codexConversationId: String = "codex-chat",
        instruction: String = "Fix it.",
        lineageDepth: Int = 1,
        state: ChatGPTReviewDispatchState = .pending
    ) -> ChatGPTReviewDispatch {
        let context = projectContext ?? project.map {
            .init(id: $0.id, name: $0.name, path: $0.path)
        } ?? .init(id: UUID(), name: "demo", path: "/tmp/demo")
        return ChatGPTReviewDispatch(
            schemaVersion: 1, sourceRunId: sourceRunId, conversationId: "chat", reviewCapturedAt: date,
            assistantMessage: "# Implementation Review\n## Verdict\nCHANGES_REQUESTED\n## Codex Instruction\nFix it.",
            verdict: "CHANGES_REQUESTED", instruction: instruction, followUpRunId: followUpRunId,
            parentRunId: followUpRunId == nil ? nil : sourceRunId, project: context,
            codexConversationId: codexConversationId, modelRole: "terra",
            modelId: "gpt-5.6-terra", effort: "low", lineageDepth: lineageDepth,
            state: state, createdAt: date, updatedAt: date, terminalReason: nil
        )
    }

    private func makeHarness(
        beforeWrite: ((ChatGPTReviewDispatch) throws -> Void)? = nil,
        notifications: NotificationManaging? = nil
    ) throws -> Harness {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let project = SavedProject(name: "demo", path: root.appendingPathComponent("repo").path)
        let savedProjectsURL = root.appendingPathComponent("saved-projects.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([project]).write(to: savedProjectsURL)

        let handoffStore = RunResultHandoffStore(
            directoryURL: root.appendingPathComponent("handoffs/pending"),
            deliveredDirectoryURL: root.appendingPathComponent("handoffs/delivered")
        )
        let reviewStore = ChatGPTReviewStore(directoryURL: root.appendingPathComponent("reviews"))
        let dispatchStore = ChatGPTReviewDispatchStore(
            directoryURL: root.appendingPathComponent("dispatches"),
            beforeWrite: beforeWrite
        )
        let recorder = EventRecorder()
        let suiteName = "aiflow.review-loop.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let viewModel = WidgetViewModel(
            store: SavedProjectStore(fileURL: savedProjectsURL),
            map: ChatProjectMap(fileURL: root.appendingPathComponent("chat-map.json")),
            defaults: defaults,
            detectChat: { nil },
            validateGit: { .repository(root: $0) },
            notifications: notifications ?? SilentNotifications(),
            handoffStore: handoffStore,
            reviewStore: reviewStore,
            reviewDispatchStore: dispatchStore,
            now: { self.date },
            reviewFollowupSender: recorder.send
        )
        return Harness(
            root: root, suiteName: suiteName, project: project,
            handoffStore: handoffStore, reviewStore: reviewStore,
            dispatchStore: dispatchStore, recorder: recorder, viewModel: viewModel
        )
    }

    private func persistChangesRequestedEvidence(runId: String, harness: Harness) throws {
        try persistEvidence(
            runId: runId,
            message: "# Implementation Review\n## Verdict\nCHANGES_REQUESTED\n## Codex Instruction\nFix it.",
            harness: harness
        )
    }

    private func persistEvidence(runId: String, message: String, harness: Harness) throws {
        let handoff = RunResultHandoff(
            runId: runId,
            outcome: .completed,
            project: .init(
                id: harness.project.id,
                name: harness.project.name,
                path: harness.project.path
            ),
            sourceChat: .init(url: "https://chatgpt.com/c/chat", conversationId: "chat"),
            execution: .init(
                worker: WidgetViewModel.RunWorker.officialVSCode.rawValue,
                modelRole: "terra",
                modelId: "gpt-5.6-terra",
                effort: "low",
                codexConversationId: "codex-chat",
                codexTurnId: "turn-1"
            ),
            result: .init(finalMessage: "result", errorMessage: nil),
            startedAt: date,
            finishedAt: date
        )
        try harness.handoffStore.persist(handoff)
        try harness.handoffStore.markDelivered(runId: runId)
        try harness.reviewStore.persist(ChatGPTReview(
            runId: runId,
            conversationId: "chat",
            sourceChatURL: "https://chatgpt.com/c/chat",
            assistantMessage: message,
            capturedAt: date
        ))
    }

    private enum TestError: Error {
        case writeFailed
    }

    private final class EventRecorder {
        var events: [BridgeEvent] = []

        func send(_ event: BridgeEvent) -> Bool {
            events.append(event)
            return true
        }
    }

    private final class SilentNotifications: NotificationManaging {
        func prepareForRun() async -> Bool { false }
        func sendApproval(for request: ApprovalRequest) {}
        func sendQuestion(for question: UserQuestion) {}
        func sendCompletion(for project: SavedProject) {}
        func sendFailure(for project: SavedProject?) {}
        func removePendingRequest(id: CodexRequestID) {}
    }

    private final class RecordingNotifications: NotificationManaging {
        var shipProjects: [String] = []
        var manualAttentionProjects: [String] = []
        var blockReasons: [String] = []

        func prepareForRun() async -> Bool { true }
        func sendApproval(for request: ApprovalRequest) {}
        func sendQuestion(for question: UserQuestion) {}
        func sendCompletion(for project: SavedProject) {}
        func sendFailure(for project: SavedProject?) {}
        func removePendingRequest(id: CodexRequestID) {}
        func sendReviewShipped(projectName: String) { shipProjects.append(projectName) }
        func sendReviewNeedsAttention(projectName: String, reason: String) {
            manualAttentionProjects.append(projectName)
        }
        func sendReviewAutomationBlocked(reason: String) { blockReasons.append(reason) }
    }

    private struct Harness {
        let root: URL
        let suiteName: String
        let project: SavedProject
        let handoffStore: RunResultHandoffStore
        let reviewStore: ChatGPTReviewStore
        let dispatchStore: ChatGPTReviewDispatchStore
        let recorder: EventRecorder
        let viewModel: WidgetViewModel

        func remove() {
            try? FileManager.default.removeItem(at: root)
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
    }
}
