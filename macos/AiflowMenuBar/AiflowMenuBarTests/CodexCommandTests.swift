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
