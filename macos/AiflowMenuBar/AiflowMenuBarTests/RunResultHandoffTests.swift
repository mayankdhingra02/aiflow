import XCTest


@testable import AiflowMenuBar

@MainActor
final class RunResultHandoffTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    private let project = SavedProject(name: "demo", path: "/repos/demo")

    override func setUp() {
        super.setUp()
        let unique = UUID().uuidString
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiflow-handoff-view-\(unique)")
        suiteName = "aiflow.tests.handoff.\(unique)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testOfficialCompletionPersistsCanonicalTerminalHandoff() throws {
        let store = RunResultHandoffStore(directoryURL: directory.appendingPathComponent("pending"))
        let runId = UUID().uuidString
        let now = sequenced([Date(timeIntervalSince1970: 1_700_000_100)])
        let viewModel = makeViewModel(handoffStore: store, now: now)

        viewModel.startRunForTesting(
            project,
            worker: .officialVSCode,
            runId: runId,
            sourceChatURL: "https://chatgpt.com/c/chat-one",
            modelRole: "sol",
            modelId: "gpt-5.6-sol",
            effort: "low",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        viewModel.handleBridgeCommand(
            BridgeCommand(type: .workerThread, runId: runId, conversationId: "codex-conv", turnId: "codex-turn")
        )
        viewModel.handleBridgeCommand(
            BridgeCommand(type: .workerCompleted, runId: runId, message: "all done")
        )

        let handoff = try XCTUnwrap(store.handoff(runId: runId))

        XCTAssertEqual(viewModel.runState, .completed(project))
        XCTAssertEqual(handoff.runId, runId)
        XCTAssertEqual(handoff.outcome, .completed)
        XCTAssertEqual(handoff.project, .init(id: project.id, name: "demo", path: "/repos/demo"))
        XCTAssertEqual(handoff.sourceChat.url, "https://chatgpt.com/c/chat-one")
        XCTAssertEqual(handoff.sourceChat.conversationId, "chat-one")
        XCTAssertEqual(handoff.execution.worker, "official-vscode")
        XCTAssertEqual(handoff.execution.modelRole, "sol")
        XCTAssertEqual(handoff.execution.modelId, "gpt-5.6-sol")
        XCTAssertEqual(handoff.execution.effort, "low")
        XCTAssertEqual(handoff.execution.codexConversationId, "codex-conv")
        XCTAssertEqual(handoff.execution.codexTurnId, "codex-turn")
        XCTAssertEqual(handoff.result.finalMessage, "all done")
        XCTAssertNil(handoff.result.errorMessage)
        XCTAssertEqual(handoff.startedAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(handoff.finishedAt, Date(timeIntervalSince1970: 1_700_000_100))
    }

    func testOfficialFailurePersistsErrorMessage() throws {
        let store = RunResultHandoffStore(directoryURL: directory.appendingPathComponent("pending"))
        let runId = UUID().uuidString
        let now = sequenced([Date(timeIntervalSince1970: 1_700_000_100)])
        let viewModel = makeViewModel(handoffStore: store, now: now)

        viewModel.startRunForTesting(
            project,
            worker: .officialVSCode,
            runId: runId,
            sourceChatURL: "https://chatgpt.com/c/chat-one",
            modelRole: "sol",
            modelId: "gpt-5.6-sol",
            effort: "low",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        viewModel.handleBridgeCommand(
            BridgeCommand(type: .workerFailed, runId: runId, message: "official worker failed")
        )

        let handoff = try XCTUnwrap(store.handoff(runId: runId))
        XCTAssertEqual(handoff.outcome, .failed)
        XCTAssertEqual(handoff.result.errorMessage, "official worker failed")
        XCTAssertNil(handoff.result.finalMessage)
    }

    func testOfficialCancellationPersistsCancelledOutcome() throws {
        let store = RunResultHandoffStore(directoryURL: directory.appendingPathComponent("pending"))
        let runId = UUID().uuidString
        let now = sequenced([Date(timeIntervalSince1970: 1_700_000_100)])
        let viewModel = makeViewModel(handoffStore: store, now: now)

        viewModel.startRunForTesting(
            project,
            worker: .officialVSCode,
            runId: runId,
            sourceChatURL: "https://chatgpt.com/c/chat-one"
        )

        viewModel.handleBridgeCommand(
            BridgeCommand(type: .workerCancelled, runId: runId)
        )

        let handoff = try XCTUnwrap(store.handoff(runId: runId))
        XCTAssertEqual(handoff.outcome, .cancelled)
        XCTAssertNil(handoff.result.finalMessage)
        XCTAssertNil(handoff.result.errorMessage)
    }

    func testLegacyCompletionPersistsCanonicalTerminalHandoff() throws {
        let store = RunResultHandoffStore(directoryURL: directory.appendingPathComponent("pending"))
        let runId = UUID().uuidString
        let now = sequenced([Date(timeIntervalSince1970: 1_700_000_100)])
        let viewModel = makeViewModel(handoffStore: store, now: now)

        viewModel.startRunForTesting(
            project,
            worker: .legacyAppServer,
            runId: runId,
            sourceChatURL: "https://chatgpt.com/c/chat-one"
        )

        viewModel.handleEventForTesting(
            .assistantMessage("legacy interim"),
            project: project
        )
        viewModel.handleEventForTesting(.finished, project: project)

        let handoff = try XCTUnwrap(store.handoff(runId: runId))
        XCTAssertEqual(handoff.outcome, .completed)
        XCTAssertEqual(handoff.result.finalMessage, "legacy interim")
        XCTAssertEqual(handoff.execution.worker, "legacy-app-server")
        XCTAssertNil(handoff.execution.codexConversationId)
        XCTAssertNil(handoff.execution.codexTurnId)
    }

    func testLegacyFailurePersistsErrorMessage() throws {
        let store = RunResultHandoffStore(directoryURL: directory.appendingPathComponent("pending"))
        let runId = UUID().uuidString
        let now = sequenced([Date(timeIntervalSince1970: 1_700_000_100)])
        let viewModel = makeViewModel(handoffStore: store, now: now)

        viewModel.startRunForTesting(
            project,
            worker: .legacyAppServer,
            runId: runId,
            sourceChatURL: "https://chatgpt.com/c/chat-one"
        )
        viewModel.handleEventForTesting(.failed("legacy failed"), project: project)

        let handoff = try XCTUnwrap(store.handoff(runId: runId))
        XCTAssertEqual(handoff.outcome, .failed)
        XCTAssertEqual(handoff.result.errorMessage, "legacy failed")
        XCTAssertNil(handoff.result.finalMessage)
    }

    func testLegacyCancellationPersistsCancelledOutcome() throws {
        let store = RunResultHandoffStore(directoryURL: directory.appendingPathComponent("pending"))
        let runId = UUID().uuidString
        let now = sequenced([Date(timeIntervalSince1970: 1_700_000_100)])
        let viewModel = makeViewModel(handoffStore: store, now: now)

        viewModel.startRunForTesting(
            project,
            worker: .legacyAppServer,
            runId: runId,
            sourceChatURL: "https://chatgpt.com/c/chat-one"
        )
        viewModel.handleEventForTesting(.cancelled, project: project)

        let handoff = try XCTUnwrap(store.handoff(runId: runId))
        XCTAssertEqual(handoff.outcome, .cancelled)
        XCTAssertNil(handoff.result.errorMessage)
        XCTAssertNil(handoff.result.finalMessage)
    }

    func testNoDetectedSourceChatProducesNoPendingHandoff() throws {
        let store = RunResultHandoffStore(directoryURL: directory.appendingPathComponent("pending"))
        let runId = UUID().uuidString
        let now = sequenced([Date(timeIntervalSince1970: 1_700_000_100)])
        let viewModel = makeViewModel(handoffStore: store, now: now)

        viewModel.startRunForTesting(
            project,
            worker: .legacyAppServer,
            runId: runId,
            sourceChatURL: nil
        )
        viewModel.handleEventForTesting(.assistantMessage("no chat"), project: project)
        viewModel.handleEventForTesting(.finished, project: project)

        XCTAssertNil(store.handoff(runId: runId))
        XCTAssertTrue(store.pendingHandoffs().isEmpty)
        XCTAssertEqual(viewModel.runState, .completed(project))
    }

    func testSourceChatTargetIsCapturedAtRunStart() throws {
        var current = "https://chatgpt.com/c/chat-one"
        let store = RunResultHandoffStore(directoryURL: directory.appendingPathComponent("pending"))
        let runId = UUID().uuidString
        let now = sequenced([Date(timeIntervalSince1970: 1_700_000_100)])
        let viewModel = makeViewModel(
            detectChat: { current },
            handoffStore: store,
            now: now
        )

        viewModel.startRunForTesting(
            project,
            worker: .legacyAppServer,
            runId: runId,
            sourceChatURL: "https://chatgpt.com/c/chat-one"
        )

        current = "https://chatgpt.com/c/chat-two"
        viewModel.refreshChat()
        viewModel.handleEventForTesting(.finished, project: project)

        let handoff = try XCTUnwrap(store.handoff(runId: runId))
        XCTAssertEqual(handoff.sourceChat.url, "https://chatgpt.com/c/chat-one")
    }

    func testWrongRunReportDoesNotCreateHandoff() throws {
        let store = RunResultHandoffStore(directoryURL: directory.appendingPathComponent("pending"))
        let runId = UUID().uuidString
        let now = sequenced([Date(timeIntervalSince1970: 1_700_000_100)])
        let viewModel = makeViewModel(handoffStore: store, now: now)

        viewModel.startRunForTesting(
            project,
            worker: .officialVSCode,
            runId: runId,
            sourceChatURL: "https://chatgpt.com/c/chat-one"
        )

        viewModel.handleBridgeCommand(
            BridgeCommand(type: .workerCompleted, runId: "run-other", message: "stale")
        )

        XCTAssertEqual(viewModel.runState, .running(project))
        XCTAssertTrue(store.pendingHandoffs().isEmpty)
    }

    func testDuplicateTerminalEvidenceIsIdempotent() throws {
        let store = RunResultHandoffStore(directoryURL: directory.appendingPathComponent("pending"))
        let runId = UUID().uuidString
        let now = sequenced([Date(timeIntervalSince1970: 1_700_000_100)])
        let viewModel = makeViewModel(handoffStore: store, now: now)

        viewModel.startRunForTesting(
            project,
            worker: .officialVSCode,
            runId: runId,
            sourceChatURL: "https://chatgpt.com/c/chat-one",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        viewModel.handleBridgeCommand(BridgeCommand(type: .workerCompleted, runId: runId, message: "once"))
        viewModel.handleBridgeCommand(BridgeCommand(type: .workerCompleted, runId: runId, message: "once"))

        XCTAssertEqual(store.pendingHandoffs().count, 1)
        XCTAssertEqual(store.handoff(runId: runId)?.result.finalMessage, "once")
    }

    func testStartedAtComesFromRunStartAndFinishedAtFromTerminalTime() throws {
        let store = RunResultHandoffStore(directoryURL: directory.appendingPathComponent("pending"))
        let runId = UUID().uuidString
        let now = sequenced([
            Date(timeIntervalSince1970: 1_700_000_100),
            Date(timeIntervalSince1970: 1_700_000_200)
        ])
        let viewModel = makeViewModel(handoffStore: store, now: now)

        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        viewModel.startRunForTesting(
            project,
            worker: .legacyAppServer,
            runId: runId,
            sourceChatURL: "https://chatgpt.com/c/chat-one",
            startedAt: startedAt
        )
        viewModel.handleEventForTesting(.finished, project: project)

        let handoff = try XCTUnwrap(store.handoff(runId: runId))
        XCTAssertEqual(handoff.startedAt, startedAt)
        XCTAssertEqual(handoff.finishedAt, Date(timeIntervalSince1970: 1_700_000_100))
        XCTAssertNotEqual(handoff.finishedAt, startedAt)
    }

    private func makeViewModel(
        detectChat: @escaping () -> String? = { nil },
        handoffStore: RunResultHandoffStore,
        now: @escaping () -> Date
    ) -> WidgetViewModel {
        WidgetViewModel(
            store: SavedProjectStore(fileURL: directory.appendingPathComponent("saved.json")),
            map: ChatProjectMap(fileURL: directory.appendingPathComponent("map.json")),
            defaults: defaults,
            detectChat: detectChat,
            validateGit: { .repository(root: $0) },
            notifications: SilentWorkerNotifications(),
            handoffStore: handoffStore,
            now: now
        )
    }

    private func sequenced(_ dates: [Date]) -> () -> Date {
        var index = 0
        return {
            defer { index += 1 }
            return dates.isEmpty ? Date() : dates[min(index, dates.count - 1)]
        }
    }
}

private final class SilentWorkerNotifications: NotificationManaging {
    func prepareForRun() async -> Bool { false }
    func sendApproval(for request: ApprovalRequest) {}
    func sendQuestion(for question: UserQuestion) {}
    func sendCompletion(for project: SavedProject) {}
    func sendFailure(for project: SavedProject?) {}
    func removePendingRequest(id: CodexRequestID) {}
}
