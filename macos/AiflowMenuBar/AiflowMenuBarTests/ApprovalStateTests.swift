import XCTest

@testable import AiflowMenuBar

/// Protocol-level tests for the app-server integration. These exercise decoding of real
/// `ServerRequest`/`ServerNotification` method names taken from the schema Codex itself
/// generates (`codex app-server generate-json-schema`).
final class CodexProtocolTests: XCTestCase {
    private func decode(_ json: String) -> CodexSessionEvent? {
        let object =
            (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        return CodexProtocol.event(from: object)
    }

    func testCommandApprovalRequestBecomesApprovalEvent() {
        let event = decode(
            """
            {"id":7,"method":"item/commandExecution/requestApproval",
             "params":{"command":"npm install left-pad","reason":"Requires network access"}}
            """)

        XCTAssertEqual(
            event,
            .approvalRequested(
                id: .integer(7), kind: .commandExecution, summary: "npm install left-pad",
                detail: "Requires network access", permissionProfile: nil))
    }

    func testCommandApprovalAcceptsArrayCommandForm() {
        let event = decode(
            """
            {"id":8,"method":"item/commandExecution/requestApproval",
             "params":{"command":["git","push"]}}
            """)

        guard case .approvalRequested(_, _, let summary, _, _) = event else {
            return XCTFail("expected an approval event")
        }
        XCTAssertEqual(summary, "git push")
    }

    func testFileChangeApprovalListsChangedFiles() {
        let event = decode(
            """
            {"id":9,"method":"item/fileChange/requestApproval",
             "params":{"fileChanges":{"src/b.swift":{},"src/a.swift":{}}}}
            """)

        guard case .approvalRequested(let id, let kind, let summary, _, _) = event else {
            return XCTFail("expected an approval event")
        }
        XCTAssertEqual(id, .integer(9))
        XCTAssertEqual(kind, .fileChange)
        XCTAssertEqual(summary, "src/a.swift, src/b.swift")
    }

    func testPermissionsApprovalIsRecognised() {
        let event = decode(
            """
            {"id":10,"method":"item/permissions/requestApproval",
             "params":{"reason":"Network access"}}
            """)

        guard case .approvalRequested(_, let kind, let summary, _, _) = event else {
            return XCTFail("expected an approval event")
        }
        XCTAssertEqual(kind, .permissions)
        XCTAssertEqual(summary, "Network access")
    }

    func testSingleQuestionRequestIsParsed() {
        let event = decode(
            """
            {"id":11,"method":"item/tool/requestUserInput",
             "params":{"questions":[
                 {"id":"migration","header":"Scope",
                  "question":"Should I update the migration as well?"}
             ]}}
            """)

        guard case .inputRequested(let id, let questions) = event else {
            return XCTFail("expected an input request")
        }
        XCTAssertEqual(id, .integer(11))
        XCTAssertEqual(questions.count, 1)
        XCTAssertEqual(questions[0].id, "migration")
        XCTAssertEqual(questions[0].header, "Scope")
        XCTAssertEqual(questions[0].question, "Should I update the migration as well?")
        XCTAssertTrue(questions[0].allowsFreeForm)
    }

    /// The protocol allows several questions per request; all of them must survive parsing.
    func testThreeQuestionRequestPreservesEveryQuestion() {
        let event = decode(
            """
            {"id":12,"method":"item/tool/requestUserInput",
             "params":{"questions":[
                 {"id":"q1","header":"A","question":"First?"},
                 {"id":"q2","header":"B","question":"Second?"},
                 {"id":"q3","header":"C","question":"Third?"}
             ]}}
            """)

        guard case .inputRequested(_, let questions) = event else {
            return XCTFail("expected an input request")
        }
        XCTAssertEqual(questions.map(\.id), ["q1", "q2", "q3"])
        XCTAssertEqual(questions.map(\.question), ["First?", "Second?", "Third?"])
    }

    func testOptionQuestionKeepsLabelsDescriptionsAndFlags() {
        let event = decode(
            """
            {"id":13,"method":"item/tool/requestUserInput",
             "params":{"questions":[
                 {"id":"api","header":"API","question":"Which API version?",
                  "isOther":true,"isSecret":false,
                  "options":[
                     {"label":"v1","description":"Stable"},
                     {"label":"v2","description":"Beta"}
                  ]}
             ]}}
            """)

        guard case .inputRequested(_, let questions) = event else {
            return XCTFail("expected an input request")
        }
        let question = questions[0]
        XCTAssertEqual(question.options.map(\.label), ["v1", "v2"])
        XCTAssertEqual(question.options.map(\.description), ["Stable", "Beta"])
        XCTAssertTrue(question.isOther)
        XCTAssertFalse(question.isSecret)
        // "Other" is permitted, so free text is offered alongside the options.
        XCTAssertTrue(question.allowsFreeForm)
    }

    func testOptionQuestionWithoutOtherDoesNotOfferFreeForm() {
        let event = decode(
            """
            {"id":14,"method":"item/tool/requestUserInput",
             "params":{"questions":[
                 {"id":"api","header":"API","question":"Which?",
                  "options":[{"label":"v1","description":"Stable"}]}
             ]}}
            """)

        guard case .inputRequested(_, let questions) = event else {
            return XCTFail("expected an input request")
        }
        XCTAssertFalse(questions[0].allowsFreeForm)
        XCTAssertFalse(questions[0].isOther)
    }

    func testSecretQuestionFlagIsPreserved() {
        let event = decode(
            """
            {"id":15,"method":"item/tool/requestUserInput",
             "params":{"questions":[
                 {"id":"token","header":"Token","question":"API token?","isSecret":true}
             ]}}
            """)

        guard case .inputRequested(_, let questions) = event else {
            return XCTFail("expected an input request")
        }
        XCTAssertTrue(questions[0].isSecret)
    }

    func testRequestWithNoUsableQuestionsIsIgnored() {
        XCTAssertNil(
            decode(#"{"id":16,"method":"item/tool/requestUserInput","params":{"questions":[]}}"#))
    }

    func testTurnStartedIsSurfaced() {
        XCTAssertEqual(decode(#"{"method":"turn/started","params":{}}"#), .started)
    }

    // MARK: - turn/completed carries its own status

    func testCompletedStatusFinishesTheRun() {
        XCTAssertEqual(
            decode(
                #"{"method":"turn/completed","params":{"threadId":"t","turn":{"id":"u","status":"completed"}}}"#
            ),
            .finished)
    }

    func testFailedStatusReportsTheStructuredError() {
        XCTAssertEqual(
            decode(
                """
                {"method":"turn/completed","params":{"threadId":"t","turn":{"id":"u",
                 "status":"failed","error":{"message":"model overloaded"}}}}
                """),
            .failed("model overloaded"))
    }

    func testInterruptedStatusReportsCancellation() {
        XCTAssertEqual(
            decode(
                #"{"method":"turn/completed","params":{"threadId":"t","turn":{"id":"u","status":"interrupted"}}}"#
            ),
            .cancelled)
    }

    func testInProgressStatusIsNotTreatedAsCompletion() {
        XCTAssertNil(
            decode(
                #"{"method":"turn/completed","params":{"threadId":"t","turn":{"id":"u","status":"inProgress"}}}"#
            ))
    }

    // MARK: - error notification shape

    /// ErrorNotification nests the message under `error` (TurnError.message).
    func testNestedErrorMessageIsParsed() {
        XCTAssertEqual(
            decode(
                """
                {"method":"error","params":{"threadId":"t","turnId":"u","willRetry":false,
                 "error":{"message":"stream disconnected"}}}
                """),
            .failed("stream disconnected"))
    }

    /// `willRetry` marks the error as non-terminal: Codex intends to keep going.
    func testRetryableErrorIsNotTerminalAndKeepsTheMessage() {
        XCTAssertEqual(
            decode(
                """
                {"method":"error","params":{"threadId":"t","turnId":"u","willRetry":true,
                 "error":{"message":"stream disconnected"}}}
                """),
            .retrying("stream disconnected"))
    }

    func testErrorWithoutWillRetryIsTreatedAsTerminal() {
        XCTAssertEqual(
            decode(#"{"method":"error","params":{"error":{"message":"boom"}}}"#),
            .failed("boom"))
    }

    func testErrorWithoutAMessageStillFails() {
        guard case .failed = decode(#"{"method":"error","params":{"error":{}}}"#) else {
            return XCTFail("expected a failure event")
        }
    }

    func testServerRequestResolvedIsSurfacedWithItsExactId() {
        XCTAssertEqual(
            decode(
                #"{"method":"serverRequest/resolved","params":{"threadId":"t","requestId":17}}"#),
            .requestResolved(.integer(17)))
    }

    func testAssistantMessageIsSurfaced() {
        let event = decode(
            """
            {"method":"item/completed","params":{"item":{"type":"agentMessage","text":"Done."}}}
            """)

        XCTAssertEqual(event, .assistantMessage("Done."))
    }

    func testNonAssistantItemsAreIgnored() {
        XCTAssertNil(
            decode(
                """
                {"method":"item/completed",
                 "params":{"item":{"type":"commandExecution","text":"ls"}}}
                """))
    }

    func testUnknownNotificationsAreIgnoredRatherThanGuessed() {
        XCTAssertNil(decode(#"{"method":"item/reasoning/textDelta","params":{"delta":"x"}}"#))
        XCTAssertNil(decode(#"{"method":"turn/plan/updated","params":{}}"#))
        XCTAssertNil(decode(#"{"id":1,"result":{"userAgent":"x"}}"#))
    }

    /// An unrecognised server->client request must not be treated as an approval, because
    /// silently ignoring it is safe while guessing an approval would not be.
    func testUnknownServerRequestIsNotTreatedAsApproval() {
        XCTAssertNil(decode(#"{"id":12,"method":"attestation/generate","params":{}}"#))
    }

    func testApprovalResponsesCarryExplicitDecisions() {
        let allow = CodexProtocol.approvalResponse(ApprovalRequest(id: .integer(3), kind: .commandExecution, summary: "x", detail: nil, projectName: "p", permissionProfile: nil), allow: true)
        let deny = CodexProtocol.approvalResponse(ApprovalRequest(id: .integer(4), kind: .commandExecution, summary: "x", detail: nil, projectName: "p", permissionProfile: nil), allow: false)

        XCTAssertEqual((allow?["result"] as? [String: Any])?["decision"] as? String, "accept")
        XCTAssertEqual(allow?["id"] as? Int, 3)
        XCTAssertEqual((deny?["result"] as? [String: Any])?["decision"] as? String, "decline")
        XCTAssertEqual(deny?["id"] as? Int, 4)
    }

    func testUserInputResponseCarriesTheAnswer() {
        let request = UserQuestion(
            id: .integer(5),
            questions: [
                QuestionItem(
                    id: "auth-flow", header: "Auth", question: "Which?", options: [],
                    isOther: false, isSecret: false)
            ],
            projectName: "p")
        let response = CodexProtocol.userInputResponse(request, answers: ["auth-flow": "OAuth"])

        XCTAssertEqual(response["id"] as? Int, 5)
        let answers = (response["result"] as? [String: Any])?["answers"] as? [String: Any]
        XCTAssertEqual(
            ((answers?["auth-flow"] as? [String: Any])?["answers"] as? [String])?.first, "OAuth")
    }

    /// The response must be keyed by every exact question id — no invented fallback keys.
    func testResponseIncludesEveryQuestionIdAndInventsNone() {
        let request = UserQuestion(
            id: .integer(6),
            questions: ["q1", "q2", "q3"].map {
                QuestionItem(
                    id: $0, header: "", question: "?", options: [], isOther: false,
                    isSecret: false)
            },
            projectName: "p")

        let response = CodexProtocol.userInputResponse(
            request, answers: ["q1": "a", "q2": "b", "q3": "c"])
        let answers = (response["result"] as? [String: Any])?["answers"] as? [String: Any]

        XCTAssertEqual(answers?.keys.sorted(), ["q1", "q2", "q3"])
        XCTAssertNil(answers?["answer"], "must not invent a fallback question id")
        for (key, expected) in ["q1": "a", "q2": "b", "q3": "c"] {
            XCTAssertEqual(
                ((answers?[key] as? [String: Any])?["answers"] as? [String])?.first, expected)
        }
    }

    func testDestructiveRequestsPreferDeny() {
        let risky = ApprovalRequest(
            id: .integer(1), kind: .commandExecution, summary: "rm -rf build", detail: nil,
            projectName: "ef", permissionProfile: nil)
        let ordinary = ApprovalRequest(
            id: .integer(2), kind: .commandExecution, summary: "ls -la", detail: nil, projectName: "ef", permissionProfile: nil)

        XCTAssertTrue(risky.prefersDeny)
        XCTAssertFalse(ordinary.prefersDeny)
    }
}

/// `turn/start` requires the threadId returned by `thread/start`, so responses must be
/// distinguished from notifications and the thread id pulled out of the result.
final class CodexHandshakeTests: XCTestCase {
    private func object(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    func testResponseIsDistinguishedFromNotification() {
        XCTAssertEqual(
            CodexProtocol.responseId(from: object(#"{"id":1,"result":{"ok":true}}"#)), 1)
        XCTAssertNil(
            CodexProtocol.responseId(from: object(#"{"method":"turn/started","params":{}}"#)))
    }

    /// A server->client *request* also carries an id, but it must never be mistaken for a
    /// response to one of ours — it has a method and expects an answer.
    func testServerRequestIsNotMistakenForAResponse() {
        let approval = object(
            #"{"id":9,"method":"item/commandExecution/requestApproval","params":{}}"#)

        XCTAssertNil(CodexProtocol.responseId(from: approval))
        XCTAssertNotNil(CodexProtocol.event(from: approval))
    }

    func testThreadIdIsExtractedFromThreadStartResult() {
        let response = object(
            #"{"id":2,"result":{"thread":{"id":"01a018ac-339a-7462-a2cc-351e7e1386a7"}}}"#)

        XCTAssertEqual(
            CodexProtocol.threadId(fromThreadStartResult: response),
            "01a018ac-339a-7462-a2cc-351e7e1386a7")
    }

    func testMissingThreadIdIsReportedRatherThanAssumed() {
        XCTAssertNil(
            CodexProtocol.threadId(fromThreadStartResult: object(#"{"id":2,"result":{}}"#)))
    }

    func testErrorResponsesAreSurfaced() {
        let response = object(#"{"id":2,"error":{"code":-32602,"message":"bad params"}}"#)

        XCTAssertEqual(CodexProtocol.responseId(from: response), 2)
        XCTAssertEqual(CodexProtocol.errorMessage(from: response), "bad params")
        XCTAssertNil(CodexProtocol.errorMessage(from: object(#"{"id":2,"result":{}}"#)))
    }
}

final class LineBufferTests: XCTestCase {
    func testSplitsCompleteLines() {
        let buffer = LineBuffer()

        XCTAssertEqual(buffer.append(Data("{\"a\":1}\n{\"b\":2}\n".utf8)),
                       ["{\"a\":1}", "{\"b\":2}"])
    }

    func testHoldsPartialLineUntilNewlineArrives() {
        let buffer = LineBuffer()

        XCTAssertEqual(buffer.append(Data("{\"a\":".utf8)), [])
        XCTAssertEqual(buffer.append(Data("1}\n".utf8)), ["{\"a\":1}"])
    }

    func testSkipsBlankLines() {
        let buffer = LineBuffer()

        XCTAssertEqual(buffer.append(Data("\n\n{\"a\":1}\n".utf8)), ["{\"a\":1}"])
    }
}

@MainActor
final class ApprovalStateTests: XCTestCase {
    private final class MockNotifications: NotificationManaging {
        var approvals: [ApprovalRequest] = []
        var questions: [UserQuestion] = []
        var completions: [SavedProject] = []
        var failures: [SavedProject?] = []
        var removed: [Int] = []
        var authorization = true

        func prepareForRun() async -> Bool { authorization }
        func sendApproval(for request: ApprovalRequest) { approvals.append(request) }
        func sendQuestion(for question: UserQuestion) { questions.append(question) }
        func sendCompletion(for project: SavedProject) { completions.append(project) }
        func sendFailure(for project: SavedProject?) { failures.append(project) }
        func removePendingRequest(id: CodexRequestID) { if case .integer(let value) = id { removed.append(value) } }
    }

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var directory: URL!

    override func setUp() {
        super.setUp()
        let unique = UUID().uuidString
        suiteName = "aiflow.tests.approval.\(unique)"
        defaults = UserDefaults(suiteName: suiteName)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiflow-approval-\(unique)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeViewModel(notifications: MockNotifications? = nil) -> WidgetViewModel {
        let notificationManager = notifications ?? MockNotifications()
        return WidgetViewModel(
            store: SavedProjectStore(fileURL: directory.appendingPathComponent("saved.json")),
            map: ChatProjectMap(fileURL: directory.appendingPathComponent("map.json")),
            defaults: defaults,
            detectChat: { nil },
            validateGit: { .repository(root: $0) },
            notifications: notificationManager
        )
    }

    private let project = SavedProject(name: "ef", path: "/repos/ef")

    func testApprovalEventMovesToWaitingForApproval() {
        let viewModel = makeViewModel()
        viewModel.enterRunningForTesting(project)

        viewModel.handleEventForTesting(
            .approvalRequested(id: .integer(3), kind: .commandExecution, summary: "npm i", detail: nil, permissionProfile: nil),
            project: project)

        XCTAssertEqual(viewModel.pendingApproval?.id, .integer(3))
        XCTAssertEqual(viewModel.pendingApproval?.summary, "npm i")
        // A run awaiting approval still counts as busy, so no second run can start.
        XCTAssertTrue(viewModel.runState.isBusy)
    }

    private func question(_ id: String) -> QuestionItem {
        QuestionItem(
            id: id, header: "", question: "Which API version?", options: [], isOther: false,
            isSecret: false)
    }

    func testInputEventMovesToWaitingForInput() {
        let viewModel = makeViewModel()
        viewModel.enterRunningForTesting(project)

        viewModel.handleEventForTesting(
            .inputRequested(id: .integer(4), questions: [question("api")]), project: project)

        XCTAssertEqual(viewModel.pendingQuestion?.id, .integer(4))
        XCTAssertEqual(viewModel.pendingQuestion?.questions.first?.question, "Which API version?")
    }

    // MARK: - Approvals stay pending until Codex resolves that exact request

    func testApprovalStaysPendingUntilItsExactRequestResolves() {
        let viewModel = makeViewModel()
        viewModel.enterRunningForTesting(project)
        viewModel.handleEventForTesting(
            .approvalRequested(
                id: .integer(17), kind: .commandExecution, summary: "npm i", detail: nil,
                permissionProfile: nil), project: project)

        viewModel.respondToApproval(allow: true)

        // Answered, but not yet acknowledged: still blocked on request 17.
        XCTAssertEqual(viewModel.runState, .respondingToRequest(.integer(17)))
        XCTAssertNil(viewModel.pendingApproval)
        XCTAssertTrue(viewModel.runState.isBusy)

        viewModel.handleEventForTesting(.requestResolved(.integer(17)), project: project)

        XCTAssertEqual(viewModel.runState, .running(project))
    }

    func testResolutionOfAnEarlierRequestDoesNotClearTheCurrentOne() {
        let viewModel = makeViewModel()
        viewModel.enterRunningForTesting(project)
        viewModel.handleEventForTesting(
            .approvalRequested(
                id: .integer(17), kind: .commandExecution, summary: "npm i", detail: nil,
                permissionProfile: nil), project: project)
        viewModel.respondToApproval(allow: true)

        viewModel.handleEventForTesting(.requestResolved(.integer(16)), project: project)
        XCTAssertEqual(viewModel.runState, .respondingToRequest(.integer(17)))

        viewModel.handleEventForTesting(.requestResolved(.integer(18)), project: project)
        XCTAssertEqual(viewModel.runState, .respondingToRequest(.integer(17)))

        viewModel.handleEventForTesting(.requestResolved(.integer(17)), project: project)
        XCTAssertEqual(viewModel.runState, .running(project))
    }

    func testQuestionStaysPendingUntilItsExactRequestResolves() {
        let viewModel = makeViewModel()
        viewModel.enterRunningForTesting(project)
        viewModel.handleEventForTesting(
            .inputRequested(id: .integer(21), questions: [question("api")]), project: project)

        viewModel.respondToQuestion(["api": "v2"])

        XCTAssertEqual(viewModel.runState, .respondingToRequest(.integer(21)))

        viewModel.handleEventForTesting(.requestResolved(.integer(20)), project: project)
        XCTAssertEqual(viewModel.runState, .respondingToRequest(.integer(21)))

        viewModel.handleEventForTesting(.requestResolved(.integer(21)), project: project)
        XCTAssertEqual(viewModel.runState, .running(project))
    }

    func testPartiallyAnsweredMultiQuestionRequestIsNotSent() {
        let viewModel = makeViewModel()
        viewModel.enterRunningForTesting(project)
        viewModel.handleEventForTesting(
            .inputRequested(id: .integer(22), questions: [question("q1"), question("q2")]),
            project: project)

        viewModel.respondToQuestion(["q1": "only one"])

        // Still waiting: every question must be answered before anything is sent.
        XCTAssertEqual(viewModel.pendingQuestion?.id, .integer(22))
    }

    func testInterruptedTurnCancelsRatherThanFails() {
        let viewModel = makeViewModel()
        viewModel.enterRunningForTesting(project)

        viewModel.handleEventForTesting(.cancelled, project: project)

        XCTAssertEqual(viewModel.runState, .cancelled(project))
        XCTAssertFalse(viewModel.runState.isBusy)
    }

    func testNoApprovalIsPendingUntilCodexAsks() {
        let viewModel = makeViewModel()
        viewModel.enterRunningForTesting(project)

        // Nothing is auto-approved: without a request there is simply no pending decision.
        XCTAssertNil(viewModel.pendingApproval)
        XCTAssertNil(viewModel.pendingQuestion)
    }

    func testFinishedEventCompletesTheRun() {
        let viewModel = makeViewModel()
        viewModel.enterRunningForTesting(project)

        viewModel.handleEventForTesting(.assistantMessage("All done."), project: project)
        viewModel.handleEventForTesting(.finished, project: project)

        XCTAssertEqual(viewModel.runState, .completed(project))
        XCTAssertEqual(viewModel.lastMessage, "All done.")
        XCTAssertFalse(viewModel.runState.isBusy)
    }

    func testFailureEventFailsTheRun() {
        let viewModel = makeViewModel()
        viewModel.enterRunningForTesting(project)

        viewModel.handleEventForTesting(.failed("Codex exited with status 1"), project: project)

        XCTAssertEqual(
            viewModel.runState,
            .failed(project: project, message: "Codex exited with status 1"))
        XCTAssertFalse(viewModel.runState.isBusy)
    }

    func testRunStateBusyRules() {
        XCTAssertFalse(RunState.ready.isBusy)
        XCTAssertFalse(RunState.completed(project).isBusy)
        XCTAssertFalse(RunState.failed(project: project, message: "x").isBusy)
        XCTAssertFalse(RunState.confirming(project).isBusy)
        XCTAssertTrue(RunState.launching(project).isBusy)
        XCTAssertTrue(RunState.running(project).isBusy)
    }

    func testClosedPopoverNotifiesForEveryIndependentApproval() {
        let notifications = MockNotifications()
        let viewModel = makeViewModel(notifications: notifications)
        viewModel.enterRunningForTesting(project)

        viewModel.handleEventForTesting(
            .approvalRequested(id: .integer(3), kind: .commandExecution, summary: "npm i", detail: nil, permissionProfile: nil),
            project: project)
        viewModel.respondToApproval(allow: true)
        viewModel.handleEventForTesting(
            .approvalRequested(id: .integer(4), kind: .permissions, summary: "Network", detail: nil, permissionProfile: nil),
            project: project)

        XCTAssertEqual(notifications.approvals.map(\.id), [.integer(3), .integer(4)])
        XCTAssertEqual(notifications.removed, [3])
    }

    func testVisiblePopoverDoesNotDuplicateApprovalNotification() {
        let notifications = MockNotifications()
        let viewModel = makeViewModel(notifications: notifications)
        viewModel.enterRunningForTesting(project)
        viewModel.popoverDidBecomeVisible()

        viewModel.handleEventForTesting(
            .approvalRequested(id: .integer(3), kind: .commandExecution, summary: "npm i", detail: nil, permissionProfile: nil),
            project: project)

        XCTAssertTrue(notifications.approvals.isEmpty)
    }

    func testDisabledNotificationsDoNotStopApprovalState() {
        let notifications = MockNotifications()
        let viewModel = makeViewModel(notifications: notifications)
        viewModel.enterRunningForTesting(project)
        viewModel.setNotificationsAvailableForTesting(false)

        viewModel.handleEventForTesting(
            .approvalRequested(id: .integer(3), kind: .commandExecution, summary: "npm i", detail: nil, permissionProfile: nil),
            project: project)

        XCTAssertEqual(viewModel.pendingApproval?.id, .integer(3))
        XCTAssertTrue(notifications.approvals.isEmpty)
        XCTAssertEqual(viewModel.menuBarSymbolName, "exclamationmark.circle.fill")
    }

    func testCompletionAndFailureNotifyOnlyWhenPopoverIsHidden() {
        let notifications = MockNotifications()
        let completed = makeViewModel(notifications: notifications)
        completed.enterRunningForTesting(project)
        completed.handleEventForTesting(.finished, project: project)
        XCTAssertEqual(notifications.completions, [project])

        let failed = makeViewModel(notifications: notifications)
        failed.enterRunningForTesting(project)
        failed.popoverDidBecomeVisible()
        failed.handleEventForTesting(.failed("boom"), project: project)
        XCTAssertTrue(notifications.failures.isEmpty)
    }

    // MARK: - Graceful cancellation

    /// Cancelling asks Codex to wind the turn down; the run is not cancelled until Codex
    /// (or the client's bounded fallback) confirms the turn actually ended.
    func testCancelEntersCancellingAndWaitsForConfirmation() {
        let viewModel = makeViewModel()
        viewModel.enterRunningForTesting(project)

        viewModel.cancelRun()

        XCTAssertEqual(viewModel.runState, .cancelling(project))
        XCTAssertTrue(
            viewModel.runState.isBusy,
            "the session is still winding down, so a second run must stay blocked")
    }

    func testInterruptedConfirmationCompletesTheCancellation() {
        let viewModel = makeViewModel()
        viewModel.enterRunningForTesting(project)
        viewModel.cancelRun()

        // This is what turn/completed(status: interrupted) decodes to.
        viewModel.handleEventForTesting(.cancelled, project: project)

        XCTAssertEqual(viewModel.runState, .cancelled(project))
        XCTAssertFalse(viewModel.runState.isBusy, "a cancelled run must not block the next one")
    }

    /// A failure arriving while the interrupt is in flight must not replace the cancellation.
    func testLateFailureCannotReplaceCancellation() {
        let viewModel = makeViewModel()
        viewModel.enterRunningForTesting(project)
        viewModel.cancelRun()

        viewModel.handleEventForTesting(.failed("stream closed"), project: project)
        XCTAssertEqual(viewModel.runState, .cancelling(project))

        viewModel.handleEventForTesting(.cancelled, project: project)
        XCTAssertEqual(viewModel.runState, .cancelled(project))

        // And once cancelled, later output is dropped entirely.
        viewModel.handleEventForTesting(.failed("later still"), project: project)
        XCTAssertEqual(viewModel.runState, .cancelled(project))
    }

    func testCancelIsIgnoredWhenNoRunIsActive() {
        let viewModel = makeViewModel()

        viewModel.cancelRun()

        XCTAssertEqual(viewModel.runState, .ready)
    }

    // MARK: - Retryable errors are not terminal

    func testRetryableErrorDoesNotFailTheRunAndKeepsItBusy() {
        let viewModel = makeViewModel()
        viewModel.enterRunningForTesting(project)

        viewModel.handleEventForTesting(.retrying("stream disconnected"), project: project)

        XCTAssertEqual(viewModel.runState, .running(project))
        XCTAssertTrue(viewModel.runState.isBusy)
        XCTAssertTrue(viewModel.notice.contains("retrying"))
    }

    func testNonRetryableErrorFailsTheRun() {
        let viewModel = makeViewModel()
        viewModel.enterRunningForTesting(project)

        viewModel.handleEventForTesting(.failed("model overloaded"), project: project)

        XCTAssertEqual(viewModel.runState, .failed(project: project, message: "model overloaded"))
        XCTAssertFalse(viewModel.runState.isBusy)
    }
}
