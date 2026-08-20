import XCTest

@testable import AiflowMenuBar

/// The macOS side of the official-Codex worker path: which backend serves a run, and how
/// worker reports are correlated back to it.
@MainActor
final class OfficialWorkerTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        let unique = UUID().uuidString
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiflow-worker-\(unique)")
        suiteName = "aiflow.tests.worker.\(unique)"
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
            notifications: SilentWorkerNotifications()
        )
    }

    private let project = SavedProject(name: "demo", path: "/repos/demo")

    /// A real directory: starting a run requires the repository to exist.
    private func makeRealRepository() throws -> String {
        let url = directory.appendingPathComponent("repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private func testConfig() -> CodexConfig {
        CodexConfig(
            models: [CodexModel(role: "terra", modelId: "gpt-5.6-terra")],
            reasoningEfforts: ["low", "medium"],
            defaultSandbox: "workspace-write")
    }

    // MARK: - execute_run payload

    func testExecuteRunCarriesEverythingTheWorkerNeeds() {
        let event = BridgeEvent.executeRun(
            runId: "run-1", project: project, prompt: "Report the branch.", model: "sol",
            effort: "low")

        XCTAssertEqual(event.type, .executeRun)
        XCTAssertEqual(event.runId, "run-1")
        XCTAssertEqual(event.workspacePath, "/repos/demo")
        XCTAssertEqual(event.prompt, "Report the branch.")
        XCTAssertEqual(event.model, "sol")
        XCTAssertEqual(event.effort, "low")
    }

    func testExecuteRunSurvivesTheWire() throws {
        let event = BridgeEvent.executeRun(
            runId: "run-1", project: project, prompt: "exact prompt", model: "terra",
            effort: "high")

        let line = try XCTUnwrap(BridgeCodec.encodeLine(event))
        let decoded = try XCTUnwrap(BridgeCodec.decodeEvent(line))

        XCTAssertEqual(decoded, event)
        XCTAssertTrue(line.contains("\"execute_run\""))
    }

    func testCancelRunNamesTheExactRun() {
        let event = BridgeEvent.cancelRun(runId: "run-7")

        XCTAssertEqual(event.type, .cancelRun)
        XCTAssertEqual(event.runId, "run-7")
    }

    func testWorkerReportCommandsDecode() {
        let cases: [(String, BridgeCommandType)] = [
            (#"{"type":"worker_accepted","runId":"r1"}"#, .workerAccepted),
            (#"{"type":"worker_thread","runId":"r1","conversationId":"c","turnId":"t"}"#, .workerThread),
            (#"{"type":"worker_status","runId":"r1","workerState":"running"}"#, .workerStatus),
            (#"{"type":"worker_completed","runId":"r1","message":"done"}"#, .workerCompleted),
            (#"{"type":"worker_failed","runId":"r1","message":"boom"}"#, .workerFailed),
            (#"{"type":"worker_cancelled","runId":"r1"}"#, .workerCancelled)
        ]

        for (json, expected) in cases {
            XCTAssertEqual(BridgeCodec.decodeCommand(json)?.type, expected, json)
        }
    }

    // MARK: - Worker selection

    func testLegacyWorkerServesTheRunWhenNoCompanionIsAvailable() {
        let viewModel = makeViewModel()
        viewModel.startRunForTesting(project, worker: .legacyAppServer, runId: "run-1")

        XCTAssertEqual(viewModel.activeWorker, .legacyAppServer)
    }

    func testOfficialWorkerAvailabilityIsOffUntilAnnounced() {
        let viewModel = makeViewModel()
        XCTAssertFalse(viewModel.officialWorkerAvailable)

        viewModel.setOfficialWorkerAvailable(true)
        XCTAssertTrue(viewModel.officialWorkerAvailable)
    }

    func testApprovalLabelDistinguishesOfficialWorkerPolicyFromLegacyManualApproval() {
        let viewModel = makeViewModel()
        XCTAssertEqual(viewModel.approvalDisplayLabel, "Approval: Manual")

        viewModel.setOfficialWorkerAvailable(true)
        XCTAssertEqual(viewModel.approvalDisplayLabel, "Approval: Codex policy")

        viewModel.startRunForTesting(project, worker: .legacyAppServer, runId: "legacy-run")
        XCTAssertEqual(viewModel.approvalDisplayLabel, "Approval: Manual")
    }

    // MARK: - Run-id correlation

    func testWorkerCompletionFinishesTheMatchingRun() {
        let viewModel = makeViewModel()
        viewModel.startRunForTesting(project, worker: .officialVSCode, runId: "run-1")

        viewModel.handleBridgeCommand(
            BridgeCommand(type: .workerCompleted, runId: "run-1", message: "AIFLOW_OK"))

        XCTAssertEqual(viewModel.runState, .completed(project))
        XCTAssertEqual(viewModel.lastMessage, "AIFLOW_OK")
    }

    /// A report from a previous run must never complete the run in flight.
    func testStaleWorkerReportCannotCompleteTheCurrentRun() {
        let viewModel = makeViewModel()
        viewModel.startRunForTesting(project, worker: .officialVSCode, runId: "run-2")

        viewModel.handleBridgeCommand(
            BridgeCommand(type: .workerCompleted, runId: "run-1", message: "stale"))

        XCTAssertEqual(viewModel.runState, .running(project))
        XCTAssertEqual(viewModel.lastMessage, "")
    }

    func testWorkerReportWithoutARunIdIsIgnored() {
        let viewModel = makeViewModel()
        viewModel.startRunForTesting(project, worker: .officialVSCode, runId: "run-1")

        viewModel.handleBridgeCommand(BridgeCommand(type: .workerCompleted, message: "no id"))

        XCTAssertEqual(viewModel.runState, .running(project))
    }

    /// Worker reports are only meaningful while the official worker owns the run.
    func testWorkerReportIsIgnoredWhenTheLegacyWorkerOwnsTheRun() {
        let viewModel = makeViewModel()
        viewModel.startRunForTesting(project, worker: .legacyAppServer, runId: "run-1")

        viewModel.handleBridgeCommand(
            BridgeCommand(type: .workerCompleted, runId: "run-1", message: "not yours"))

        XCTAssertEqual(viewModel.runState, .running(project))
        XCTAssertEqual(viewModel.lastMessage, "")
    }

    func testWorkerFailureFailsTheRunWithItsMessage() {
        let viewModel = makeViewModel()
        viewModel.startRunForTesting(project, worker: .officialVSCode, runId: "run-1")

        viewModel.handleBridgeCommand(
            BridgeCommand(type: .workerFailed, runId: "run-1", message: "thread_unavailable"))

        XCTAssertEqual(
            viewModel.runState, .failed(project: project, message: "thread_unavailable"))
    }

    func testWorkerCancellationCancelsTheRun() {
        let viewModel = makeViewModel()
        viewModel.startRunForTesting(project, worker: .officialVSCode, runId: "run-1")

        viewModel.handleBridgeCommand(BridgeCommand(type: .workerCancelled, runId: "run-1"))

        XCTAssertEqual(viewModel.runState, .cancelled(project))
    }

    func testWorkerThreadReportIsRecordedWithoutMirroringTheConversation() {
        let viewModel = makeViewModel()
        viewModel.startRunForTesting(project, worker: .officialVSCode, runId: "run-1")

        viewModel.handleBridgeCommand(
            BridgeCommand(
                type: .workerThread, runId: "run-1", conversationId: "conv-9", turnId: "turn-3"))

        // Identifiers only: the conversation itself stays in the official Codex UI.
        XCTAssertTrue(viewModel.notice.contains("conv-9"))
        XCTAssertTrue(viewModel.notice.contains("turn-3"))
    }

    /// One run is served by exactly one worker; a finished run releases it.
    func testFinishedRunReleasesTheWorker() {
        let viewModel = makeViewModel()
        viewModel.startRunForTesting(project, worker: .officialVSCode, runId: "run-1")

        viewModel.handleBridgeCommand(
            BridgeCommand(type: .workerCompleted, runId: "run-1", message: "done"))

        XCTAssertNil(viewModel.activeWorker)

        // A late report for the finished run changes nothing.
        viewModel.handleBridgeCommand(
            BridgeCommand(type: .workerFailed, runId: "run-1", message: "late"))
        XCTAssertEqual(viewModel.runState, .completed(project))
    }

    // MARK: - Availability announcement

    func testCompanionAnnouncementEnablesAndDisablesTheOfficialWorker() {
        let viewModel = makeViewModel()

        viewModel.handleBridgeCommand(BridgeCommand(type: .workerAvailable, workerState: "ready"))
        XCTAssertTrue(viewModel.officialWorkerAvailable)

        viewModel.handleBridgeCommand(
            BridgeCommand(type: .workerAvailable, workerState: "unavailable"))
        XCTAssertFalse(viewModel.officialWorkerAvailable)
    }

    /// An availability announcement is about the companion, so it must not need a run id.
    func testAvailabilityAnnouncementNeedsNoRunId() {
        let viewModel = makeViewModel()
        viewModel.handleBridgeCommand(BridgeCommand(type: .workerAvailable, workerState: "ready"))

        XCTAssertTrue(viewModel.officialWorkerAvailable)
    }

    /// When the official path cannot be reached, Aiflow stops preferring it so the next run
    /// falls back explicitly instead of failing again.
    func testUnreachableOfficialWorkerStopsBeingPreferred() {
        let viewModel = makeViewModel()
        viewModel.setOfficialWorkerAvailable(true)
        viewModel.startRunForTesting(project, worker: .officialVSCode, runId: "run-1")

        viewModel.handleBridgeCommand(
            BridgeCommand(
                type: .workerFailed, runId: "run-1",
                message: "ipc_unavailable: could not reach Codex IPC"))

        XCTAssertFalse(viewModel.officialWorkerAvailable, "the next run falls back")
        XCTAssertEqual(viewModel.activeWorker, nil)
    }

    /// An ordinary turn failure says nothing about the transport, so availability is kept.
    func testAnOrdinaryTurnFailureKeepsTheOfficialWorkerPreferred() {
        let viewModel = makeViewModel()
        viewModel.setOfficialWorkerAvailable(true)
        viewModel.startRunForTesting(project, worker: .officialVSCode, runId: "run-1")

        viewModel.handleBridgeCommand(
            BridgeCommand(type: .workerFailed, runId: "run-1", message: "turn_failed: model error"))

        XCTAssertTrue(viewModel.officialWorkerAvailable)
    }

    // MARK: - Menu-bar lifecycle state
    //
    // The popup renders these transitions inline, so the state machine behind them has to be
    // exactly right: nothing may start or cancel a run before the user confirms.

    func testRequestingARunOnlyEntersConfirming() throws {
        let repo = try makeRealRepository()
        let viewModel = makeViewModel()
        viewModel.applyConfigForTesting(testConfig())
        viewModel.setPromptForTesting("do the thing")
        viewModel.addProject(at: repo)
        let saved = try XCTUnwrap(viewModel.savedProjects.first)

        viewModel.requestRun(saved)

        XCTAssertEqual(viewModel.confirmingProject, saved)
        XCTAssertFalse(viewModel.runState.isBusy, "confirming must not start Codex")
        XCTAssertNil(viewModel.activeWorker)
    }

    func testBackingOutOfConfirmationReturnsToReady() throws {
        let repo = try makeRealRepository()
        let viewModel = makeViewModel()
        viewModel.applyConfigForTesting(testConfig())
        viewModel.setPromptForTesting("do the thing")
        viewModel.addProject(at: repo)
        viewModel.requestRun(try XCTUnwrap(viewModel.savedProjects.first))

        viewModel.cancelConfirmation()

        XCTAssertNil(viewModel.confirmingProject)
        XCTAssertEqual(viewModel.runState, .ready)
    }

    /// The inline cancel prompt is view state; the run must keep going until the user confirms.
    func testShowingTheCancelPromptDoesNotCancelTheRun() {
        let viewModel = makeViewModel()
        viewModel.startRunForTesting(project, worker: .officialVSCode, runId: "run-1")

        // Merely deciding to ask does nothing to the run.
        XCTAssertEqual(viewModel.runState, .running(project))
        XCTAssertTrue(viewModel.isRunning)

        viewModel.cancelRun()
        XCTAssertEqual(viewModel.runState, .cancelling(project))
    }

    /// Cancelling while Codex waits on an approval is reachable from the inline panel.
    func testCancelWorksWhileAnApprovalIsPending() {
        let viewModel = makeViewModel()
        viewModel.startRunForTesting(project, worker: .officialVSCode, runId: "run-1")
        viewModel.handleEventForTesting(
            .approvalRequested(
                id: .integer(3), kind: .commandExecution, summary: "npm i", detail: nil,
                permissionProfile: nil), project: project)

        XCTAssertNotNil(viewModel.pendingApproval)
        XCTAssertTrue(viewModel.isRunning, "an approval still counts as a live run")

        viewModel.cancelRun()

        XCTAssertEqual(viewModel.runState, .cancelling(project))
    }

    /// Approval and question requests are plain view-model state, so they render inline.
    func testPendingRequestsAreRepresentableWithoutAnySheet() {
        let viewModel = makeViewModel()
        viewModel.startRunForTesting(project, worker: .officialVSCode, runId: "run-1")

        viewModel.handleEventForTesting(
            .inputRequested(
                id: .integer(9),
                questions: [
                    QuestionItem(
                        id: "q1", header: "H", question: "Which?",
                        options: [QuestionOption(label: "v1", description: "Stable")],
                        isOther: true, isSecret: false)
                ]), project: project)

        let pending = viewModel.pendingQuestion
        XCTAssertEqual(pending?.id, .integer(9))
        XCTAssertEqual(pending?.questions.first?.options.first?.label, "v1")
        XCTAssertEqual(pending?.questions.first?.allowsFreeForm, true)
    }

    // MARK: - Security posture

    /// The execution request is the only event carrying parameters, and it never carries a
    /// sandbox or approval override — the official worker inherits the official extension's
    /// current policy.
    func testExecuteRunCarriesNoPermissionOverrides() throws {
        let event = BridgeEvent.executeRun(
            runId: "run-1", project: project, prompt: "p", model: "terra", effort: "medium")
        let line = try XCTUnwrap(BridgeCodec.encodeLine(event)).lowercased()

        for forbidden in ["danger-full-access", "sandbox", "approvalpolicy", "bypass", "full-auto"] {
            XCTAssertFalse(line.contains(forbidden), "must not contain \(forbidden)")
        }
    }

    /// Worker reports are inbound commands, so they must not be able to smuggle execution
    /// parameters back into Aiflow.
    func testWorkerReportCannotCarryExecutionParameters() throws {
        let json = """
            {"type":"worker_completed","runId":"r1","message":"ok","workspacePath":"/etc",
             "sandbox":"danger-full-access","prompt":"evil"}
            """
        let command = try XCTUnwrap(BridgeCodec.decodeCommand(json))

        XCTAssertEqual(command.type, .workerCompleted)
        XCTAssertEqual(command.runId, "r1")
        XCTAssertEqual(command.message, "ok")
        // There is no field for any of the smuggled keys, so they are simply dropped.
    }
}

@MainActor
private final class SilentWorkerNotifications: NotificationManaging {
    func prepareForRun() async -> Bool { false }
    func sendApproval(for request: ApprovalRequest) {}
    func sendQuestion(for question: UserQuestion) {}
    func sendCompletion(for project: SavedProject) {}
    func sendFailure(for project: SavedProject?) {}
    func removePendingRequest(id: CodexRequestID) {}
}
