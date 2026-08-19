import XCTest

@testable import AiflowMenuBar

/// The widget drives Codex through the app-server protocol rather than `codex exec`, because
/// exec is non-interactive and cannot surface approval requests. These assert the same
/// safety guarantees the exec-based backend has, expressed as session parameters.
final class CodexSessionParameterTests: XCTestCase {
    private let repo = "/Users/me/Desktop/Engineeringfoundry"

    private func threadParams() -> [String: Any] {
        CodexProtocol.threadStartParams(repositoryPath: repo, modelId: "gpt-5.6-terra")
    }

    private func turnParams(effort: String = "high", prompt: String = "Fix the navbar")
        -> [String: Any]
    {
        CodexProtocol.turnStartParams(
            threadId: "thread-1", repositoryPath: repo, modelId: "gpt-5.6-terra",
            reasoningEffort: effort, prompt: prompt)
    }

    func testSelectedRepositoryIsTheWorkingDirectory() {
        XCTAssertEqual(threadParams()["cwd"] as? String, repo)
        XCTAssertEqual(turnParams()["cwd"] as? String, repo)
    }

    func testSelectedModelIsPassed() {
        XCTAssertEqual(threadParams()["model"] as? String, "gpt-5.6-terra")
        XCTAssertEqual(turnParams()["model"] as? String, "gpt-5.6-terra")
    }

    func testSelectedReasoningEffortIsPassed() {
        for effort in ["low", "medium", "high", "xhigh"] {
            XCTAssertEqual(turnParams(effort: effort)["effort"] as? String, effort)
        }
    }

    /// The wire enum is the hyphenated `SandboxMode` from the app-server schema. The server
    /// rejects a camelCased variant outright:
    ///   "unknown variant `workspaceWrite`, expected one of `read-only`, `workspace-write`,
    ///    `danger-full-access`"
    func testSandboxIsAlwaysWorkspaceWrite() {
        XCTAssertEqual(threadParams()["sandbox"] as? String, "workspace-write")
        XCTAssertEqual(CodexProtocol.sandbox, "workspace-write")
    }

    // MARK: - Handshake

    /// `requestUserInput` is experimental, so it is only delivered when the client opts in.
    func testInitializeOptsIntoTheExperimentalApi() {
        let params = CodexProtocol.initializeParams()
        let capabilities = params["capabilities"] as? [String: Any]

        XCTAssertEqual(capabilities?["experimentalApi"] as? Bool, true)
        XCTAssertEqual((params["clientInfo"] as? [String: Any])?["name"] as? String, "Aiflow")
    }

    func testInitializedNotificationHasNoIdAndEmptyParams() {
        let notification = CodexProtocol.initializedNotification()

        XCTAssertEqual(notification["method"] as? String, "initialized")
        XCTAssertNil(notification["id"], "a notification must not carry a request id")
        XCTAssertTrue((notification["params"] as? [String: Any])?.isEmpty ?? false)
    }

    // MARK: - Session identifiers

    func testThreadIdIsParsedFromThreadStartResult() {
        let object =
            (try? JSONSerialization.jsonObject(
                with: Data(#"{"id":2,"result":{"thread":{"id":"thread-abc"}}}"#.utf8)))
            as? [String: Any] ?? [:]

        XCTAssertEqual(CodexProtocol.threadId(fromThreadStartResult: object), "thread-abc")
    }

    func testTurnIdIsParsedFromResultAndFromNotification() {
        let response =
            (try? JSONSerialization.jsonObject(
                with: Data(#"{"id":3,"result":{"turn":{"id":"turn-xyz"}}}"#.utf8)))
            as? [String: Any] ?? [:]
        let notification =
            (try? JSONSerialization.jsonObject(
                with: Data(
                    #"{"method":"turn/started","params":{"turn":{"id":"turn-noti"}}}"#.utf8)))
            as? [String: Any] ?? [:]

        XCTAssertEqual(CodexProtocol.turnId(fromTurnPayload: response), "turn-xyz")
        XCTAssertEqual(CodexProtocol.turnId(fromTurnPayload: notification), "turn-noti")
    }

    // MARK: - Interrupt

    func testInterruptCarriesTheExactThreadAndTurnIds() {
        let params = CodexProtocol.interruptParams(threadId: "thread-abc", turnId: "turn-xyz")

        XCTAssertEqual(params["threadId"] as? String, "thread-abc")
        XCTAssertEqual(params["turnId"] as? String, "turn-xyz")
        XCTAssertEqual(params.keys.sorted(), ["threadId", "turnId"])
    }

    // MARK: - Wire format
    //
    // The app-server protocol omits the JSON-RPC envelope field; messages carry only
    // method/id/params (requests), method/params (notifications), or id/result (responses).

    func testInitializedNotificationOmitsJsonrpc() {
        XCTAssertNil(CodexProtocol.initializedNotification()["jsonrpc"])
    }

    func testApprovalResponseOmitsJsonrpcAndCarriesOnlyIdAndResult() {
        let request = ApprovalRequest(
            id: .integer(7), kind: .commandExecution, summary: "npm i", detail: nil,
            projectName: "p", permissionProfile: nil)
        let response = CodexProtocol.approvalResponse(request, allow: true)

        XCTAssertNil(response?["jsonrpc"])
        XCTAssertEqual(response?.keys.sorted(), ["id", "result"])
    }

    func testPermissionResponseOmitsJsonrpc() {
        let request = ApprovalRequest(
            id: .integer(8), kind: .permissions, summary: "network", detail: nil,
            projectName: "p", permissionProfile: nil)
        let response = CodexProtocol.approvalResponse(request, allow: false)

        XCTAssertNil(response?["jsonrpc"])
        XCTAssertEqual(response?.keys.sorted(), ["id", "result"])
    }

    func testUserInputResponseOmitsJsonrpc() {
        let request = UserQuestion(
            id: .integer(9),
            questions: [
                QuestionItem(
                    id: "q1", header: "", question: "?", options: [], isOther: false,
                    isSecret: false)
            ],
            projectName: "p")
        let response = CodexProtocol.userInputResponse(request, answers: ["q1": "a"])

        XCTAssertNil(response["jsonrpc"])
        XCTAssertEqual(response.keys.sorted(), ["id", "result"])
    }

    /// Every message the client actually puts on the wire during a session.
    func testNoOutboundMessageEverIncludesJsonrpc() async {
        let recorder = OutboundRecorder()
        let client = CodexAppServerClient()
        await client.configureForTesting(
            threadId: "t", turnId: "u", onSend: { recorder.record($0) }, onEvent: { _ in })

        await client.cancel(terminateAfter: .seconds(60))
        await client.respondToApproval(
            ApprovalRequest(
                id: .integer(1), kind: .commandExecution, summary: "s", detail: nil,
                projectName: "p", permissionProfile: nil), allow: true)
        await client.respondToInput(
            UserQuestion(
                id: .integer(2),
                questions: [
                    QuestionItem(
                        id: "q", header: "", question: "?", options: [], isOther: false,
                        isSecret: false)
                ], projectName: "p"), answers: ["q": "a"])

        let sent = recorder.messages
        XCTAssertFalse(sent.isEmpty)
        for message in sent {
            XCTAssertNil(message["jsonrpc"], "outbound message must not carry a jsonrpc field")
        }
    }


    func testNeverUsesDangerFullAccess() {
        XCTAssertNotEqual(CodexProtocol.sandbox, "danger-full-access")
        XCTAssertFalse(describe(threadParams()).contains("danger"))
        XCTAssertFalse(describe(turnParams()).contains("danger"))
    }

    /// The approval policy must route requests to the user — never "never" (silently
    /// proceed) and never an auto-approving reviewer.
    func testApprovalPolicyAsksTheUser() {
        XCTAssertEqual(threadParams()["approvalPolicy"] as? String, "on-request")
        XCTAssertNotEqual(CodexProtocol.approvalPolicy, "never")
        XCTAssertNil(threadParams()["approvalsReviewer"])
    }

    func testNoBypassOrFullAutoFlagIsEverSent() {
        let text = describe(threadParams()) + describe(turnParams())

        for forbidden in [
            "dangerously-bypass", "bypass", "full-auto", "approve-for-me", "danger",
        ] {
            XCTAssertFalse(text.contains(forbidden), "must not contain \(forbidden)")
        }
    }

    func testTheFullPromptIsSentAsTurnInput() {
        let prompt = String(repeating: "long prompt ", count: 200)
        let input = turnParams(prompt: prompt)["input"] as? [[String: Any]]

        XCTAssertEqual(input?.first?["type"] as? String, "text")
        XCTAssertEqual(input?.first?["text"] as? String, prompt)
    }

    func testTurnCarriesTheThreadIdReturnedByThreadStart() {
        // turn/start requires threadId; sending it without one is rejected by Codex.
        XCTAssertEqual(turnParams()["threadId"] as? String, "thread-1")
    }

    /// The app-server process itself is launched with a bare subcommand and no shell.
    func testAppServerIsLaunchedWithoutAShell() {
        let arguments = ["app-server"]

        XCTAssertFalse(arguments.contains("-c"))
        XCTAssertFalse(arguments.contains { $0.hasSuffix("sh") })
        XCTAssertEqual(arguments, ["app-server"])
    }

    private func describe(_ params: [String: Any]) -> String {
        String(describing: params).lowercased()
    }
}

final class CodexLocatorTests: XCTestCase {
    func testPrefersEnvironmentOverride() {
        let url = CodexLocator.resolve(
            environment: ["AIFLOW_CODEX_PATH": "/custom/codex", "PATH": "/opt/homebrew/bin"],
            isExecutableFile: { $0 == "/custom/codex" || $0 == "/opt/homebrew/bin/codex" }
        )

        XCTAssertEqual(url?.path, "/custom/codex")
    }

    func testScansPathEntriesWithoutAShell() {
        let url = CodexLocator.resolve(
            environment: ["PATH": "/nowhere:/somewhere/bin"],
            isExecutableFile: { $0 == "/somewhere/bin/codex" }
        )

        XCTAssertEqual(url?.path, "/somewhere/bin/codex")
    }

    func testFallsBackToKnownInstallLocations() {
        let url = CodexLocator.resolve(
            environment: [:],
            isExecutableFile: { $0 == "/opt/homebrew/bin/codex" }
        )

        XCTAssertEqual(url?.path, "/opt/homebrew/bin/codex")
    }

    /// When only the ChatGPT desktop app is installed, Codex lives inside its bundle.
    func testFindsCodexBundledInsideChatGPTApp() {
        let bundled = "/Applications/ChatGPT.app/Contents/Resources/codex"
        let url = CodexLocator.resolve(environment: [:], isExecutableFile: { $0 == bundled })

        XCTAssertEqual(url?.path, bundled)
    }

    func testReturnsNilWhenCodexIsNotInstalled() {
        XCTAssertNil(CodexLocator.resolve(environment: [:], isExecutableFile: { _ in false }))
    }

    func testDoesNotHardcodeADerivedDataPath() {
        XCTAssertFalse(CodexLocator.knownPaths.contains { $0.contains("DerivedData") })
    }
}

/// Collects outbound messages from the client's test seam.
final class OutboundRecorder: @unchecked Sendable {
    private var storage: [[String: Any]] = []
    private let lock = NSLock()

    func record(_ message: [String: Any]) {
        lock.lock()
        storage.append(message)
        lock.unlock()
    }

    var messages: [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// The client must keep the session open after sending the interrupt, so the server has a
/// chance to confirm; only the bounded fallback ends it early.
final class CodexCancellationTests: XCTestCase {
    private func makeClient(
        recorder: OutboundRecorder,
        events: @escaping @Sendable (CodexSessionEvent) -> Void = { _ in }
    ) async -> CodexAppServerClient {
        let client = CodexAppServerClient()
        await client.configureForTesting(
            threadId: "thread-abc", turnId: "turn-xyz", onSend: { recorder.record($0) },
            onEvent: events)
        return client
    }

    func testCancelSendsInterruptWithTheExactIds() async {
        let recorder = OutboundRecorder()
        let client = await makeClient(recorder: recorder)

        await client.cancel(terminateAfter: .seconds(60))

        let interrupt = recorder.messages.first { $0["method"] as? String == "turn/interrupt" }
        XCTAssertNotNil(interrupt, "cancel must send turn/interrupt")
        let params = interrupt?["params"] as? [String: Any]
        XCTAssertEqual(params?["threadId"] as? String, "thread-abc")
        XCTAssertEqual(params?["turnId"] as? String, "turn-xyz")
    }

    func testClientStaysAliveWhileWaitingForConfirmation() async {
        let recorder = OutboundRecorder()
        let client = await makeClient(recorder: recorder)

        await client.cancel(terminateAfter: .seconds(60))

        let active = await client.isSessionActive
        XCTAssertTrue(active, "the session must survive until the turn is confirmed ended")
    }

    func testBoundedFallbackCancelsWhenTheServerNeverConfirms() async {
        let recorder = OutboundRecorder()
        let received = EventRecorder()
        let client = await makeClient(recorder: recorder, events: { received.record($0) })

        await client.cancel(terminateAfter: .milliseconds(50))

        try? await Task.sleep(for: .milliseconds(400))

        XCTAssertTrue(received.events.contains(.cancelled), "fallback must report cancellation")
        let active = await client.isSessionActive
        XCTAssertFalse(active, "the session must be released after the fallback fires")
    }

    func testCancelWithNoActiveTurnReportsCancellationImmediately() async {
        let received = EventRecorder()
        let client = CodexAppServerClient()
        // A session that never got as far as starting a turn has no ids to interrupt.
        await client.configureForTesting(
            threadId: "", turnId: "", onSend: { _ in }, onEvent: { received.record($0) })

        await client.cancel(terminateAfter: .seconds(60))

        XCTAssertTrue(received.events.contains(.cancelled))
    }
}

final class EventRecorder: @unchecked Sendable {
    private var storage: [CodexSessionEvent] = []
    private let lock = NSLock()

    func record(_ event: CodexSessionEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    var events: [CodexSessionEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
