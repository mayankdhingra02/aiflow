import XCTest

@testable import AiflowMenuBar

/// Keeps the tests away from the real notification centre.
@MainActor
private final class SilentNotifications: NotificationManaging {
    func prepareForRun() async -> Bool { false }
    func sendApproval(for request: ApprovalRequest) {}
    func sendQuestion(for question: UserQuestion) {}
    func sendCompletion(for project: SavedProject) {}
    func sendFailure(for project: SavedProject?) {}
    func removePendingRequest(id: CodexRequestID) {}
}

/// The view model is the source of truth: a bridge command may only resolve the request that
/// is actually pending, and may never introduce execution parameters.
@MainActor
final class BridgeRoutingTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        let unique = UUID().uuidString
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiflow-bridge-\(unique)")
        suiteName = "aiflow.tests.bridge.\(unique)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeViewModel() -> WidgetViewModel {
        WidgetViewModel(
            store: SavedProjectStore(fileURL: directory.appendingPathComponent("saved.json")),
            map: ChatProjectMap(fileURL: directory.appendingPathComponent("map.json")),
            defaults: defaults,
            detectChat: { nil },
            validateGit: { .repository(root: $0) },
            notifications: SilentNotifications()
        )
    }

    private let project = SavedProject(name: "ef", path: "/repos/ef")

    private func approval(_ id: Int) -> CodexSessionEvent {
        .approvalRequested(
            id: .integer(id), kind: .commandExecution, summary: "npm i", detail: nil,
            permissionProfile: nil)
    }

    private func question(_ id: Int, _ questionID: String) -> CodexSessionEvent {
        .inputRequested(
            id: .integer(id),
            questions: [
                QuestionItem(
                    id: questionID, header: "", question: "Which?", options: [], isOther: false,
                    isSecret: false)
            ])
    }

    // MARK: - Approvals

    func testMatchingApprovalIdRoutesTheDecision() {
        let viewModel = makeViewModel()
        viewModel.enterRunningForTesting(project)
        viewModel.handleEventForTesting(approval(17), project: project)

        viewModel.handleBridgeCommand(BridgeCommand(type: .approve, requestId: .integer(17)))

        // Answered: the run now waits for Codex to confirm it resolved request 17.
        XCTAssertEqual(viewModel.runState, .respondingToRequest(.integer(17)))
    }

    func testMismatchedApprovalIdCannotApprove() {
        let viewModel = makeViewModel()
        viewModel.enterRunningForTesting(project)
        viewModel.handleEventForTesting(approval(17), project: project)

        viewModel.handleBridgeCommand(BridgeCommand(type: .approve, requestId: .integer(16)))
        viewModel.handleBridgeCommand(BridgeCommand(type: .approve, requestId: .integer(18)))
        viewModel.handleBridgeCommand(BridgeCommand(type: .approve, requestId: .string("17")))

        // Still waiting on 17 — a stale or wrongly typed id resolves nothing.
        XCTAssertEqual(viewModel.pendingApproval?.id, .integer(17))
    }

    func testApprovalWithoutARequestIdIsIgnored() {
        let viewModel = makeViewModel()
        viewModel.enterRunningForTesting(project)
        viewModel.handleEventForTesting(approval(17), project: project)

        viewModel.handleBridgeCommand(BridgeCommand(type: .approve))

        XCTAssertEqual(viewModel.pendingApproval?.id, .integer(17))
    }

    func testDenyRoutesWhenTheIdMatches() {
        let viewModel = makeViewModel()
        viewModel.enterRunningForTesting(project)
        viewModel.handleEventForTesting(approval(5), project: project)

        viewModel.handleBridgeCommand(BridgeCommand(type: .deny, requestId: .integer(5)))

        XCTAssertEqual(viewModel.runState, .respondingToRequest(.integer(5)))
    }

    func testApproveIsIgnoredWhenNothingIsPending() {
        let viewModel = makeViewModel()
        viewModel.enterRunningForTesting(project)

        viewModel.handleBridgeCommand(BridgeCommand(type: .approve, requestId: .integer(1)))

        XCTAssertEqual(viewModel.runState, .running(project))
    }

    // MARK: - Questions

    func testQuestionAnswerRoutesWhenIdsMatch() {
        let viewModel = makeViewModel()
        viewModel.enterRunningForTesting(project)
        viewModel.handleEventForTesting(question(21, "api"), project: project)

        viewModel.handleBridgeCommand(
            BridgeCommand(type: .answerQuestion, requestId: .integer(21), answers: ["api": "v2"]))

        XCTAssertEqual(viewModel.runState, .respondingToRequest(.integer(21)))
    }

    func testQuestionAnswerWithMismatchedRequestIdIsIgnored() {
        let viewModel = makeViewModel()
        viewModel.enterRunningForTesting(project)
        viewModel.handleEventForTesting(question(21, "api"), project: project)

        viewModel.handleBridgeCommand(
            BridgeCommand(type: .answerQuestion, requestId: .integer(20), answers: ["api": "v2"]))

        XCTAssertEqual(viewModel.pendingQuestion?.id, .integer(21))
    }

    /// The question id inside the payload still has to match; a wrong key leaves the request
    /// unanswered rather than sending a partial response.
    func testQuestionAnswerWithWrongQuestionKeyIsIgnored() {
        let viewModel = makeViewModel()
        viewModel.enterRunningForTesting(project)
        viewModel.handleEventForTesting(question(21, "api"), project: project)

        viewModel.handleBridgeCommand(
            BridgeCommand(
                type: .answerQuestion, requestId: .integer(21), answers: ["wrong": "v2"]))

        XCTAssertEqual(viewModel.pendingQuestion?.id, .integer(21))
    }

    // MARK: - Cancel

    func testCancelCommandRoutesToCancelRun() {
        let viewModel = makeViewModel()
        viewModel.enterRunningForTesting(project)

        viewModel.handleBridgeCommand(BridgeCommand(type: .cancel))

        XCTAssertEqual(viewModel.runState, .cancelling(project))
    }

    func testCancelWithNoRunIsHarmless() {
        let viewModel = makeViewModel()

        viewModel.handleBridgeCommand(BridgeCommand(type: .cancel))

        XCTAssertEqual(viewModel.runState, .ready)
    }

    // MARK: - Snapshot

    func testSnapshotDescribesAnIdleApp() {
        let viewModel = makeViewModel()

        let snapshot = viewModel.bridgeSnapshot()

        XCTAssertEqual(snapshot.type, .snapshot)
        XCTAssertEqual(snapshot.runState, "ready")
        XCTAssertEqual(snapshot.connected, true)
        XCTAssertEqual(snapshot.model, "terra")
        XCTAssertEqual(snapshot.effort, "medium")
    }

    func testSnapshotDescribesARunningRun() {
        let viewModel = makeViewModel()
        viewModel.enterRunningForTesting(project)
        viewModel.handleEventForTesting(.assistantMessage("working on it"), project: project)

        let snapshot = viewModel.bridgeSnapshot()

        XCTAssertEqual(snapshot.runState, "running")
        XCTAssertEqual(snapshot.project, "ef")
        XCTAssertEqual(snapshot.message, "working on it")
    }

    /// A client reconnecting mid-approval must be able to answer, so the snapshot carries the
    /// pending request.
    func testSnapshotCarriesThePendingApproval() {
        let viewModel = makeViewModel()
        viewModel.enterRunningForTesting(project)
        viewModel.handleEventForTesting(approval(9), project: project)

        let snapshot = viewModel.bridgeSnapshot()

        XCTAssertEqual(snapshot.runState, "waiting_for_approval")
        XCTAssertEqual(snapshot.requestId, .integer(9))
        XCTAssertEqual(snapshot.summary, "npm i")
        XCTAssertEqual(snapshot.kind, "command_execution")
    }

    func testSnapshotCarriesThePendingQuestionSet() {
        let viewModel = makeViewModel()
        viewModel.enterRunningForTesting(project)
        viewModel.handleEventForTesting(question(11, "api"), project: project)

        let snapshot = viewModel.bridgeSnapshot()

        XCTAssertEqual(snapshot.runState, "waiting_for_input")
        XCTAssertEqual(snapshot.requestId, .integer(11))
        XCTAssertEqual(snapshot.questions?.map(\.id), ["api"])
    }

    // MARK: - file_open scoping

    func testFileOpenIsRefusedOutsideTheActiveRepository() {
        let viewModel = makeViewModel()
        viewModel.enterRunningForTesting(project)

        XCTAssertFalse(viewModel.emitFileOpen(path: "/etc/passwd"))
        XCTAssertFalse(viewModel.emitFileOpen(path: "/repos/other/file.swift"))
        // A sibling directory sharing the prefix is still outside the repository.
        XCTAssertFalse(viewModel.emitFileOpen(path: "/repos/ef-other/file.swift"))
    }

    func testFileOpenIsAllowedInsideTheActiveRepository() {
        let viewModel = makeViewModel()
        viewModel.enterRunningForTesting(project)

        XCTAssertTrue(viewModel.emitFileOpen(path: "/repos/ef/src/main.swift"))
    }

    func testFileOpenIsRefusedWithNoActiveRun() {
        let viewModel = makeViewModel()

        XCTAssertFalse(viewModel.emitFileOpen(path: "/repos/ef/src/main.swift"))
    }

    // MARK: - Bridge absence

    /// Every lifecycle path emits to the bridge; with no bridge attached those calls must be
    /// no-ops rather than crashes, because the run must not depend on the companion.
    func testRunLifecycleWorksWithNoBridgeAttached() {
        let viewModel = makeViewModel()
        viewModel.enterRunningForTesting(project)

        viewModel.handleEventForTesting(.assistantMessage("hi"), project: project)
        viewModel.handleEventForTesting(approval(1), project: project)
        viewModel.handleBridgeCommand(BridgeCommand(type: .approve, requestId: .integer(1)))
        viewModel.handleEventForTesting(.requestResolved(.integer(1)), project: project)
        viewModel.handleEventForTesting(.finished, project: project)

        XCTAssertEqual(viewModel.runState, .completed(project))
    }
}
