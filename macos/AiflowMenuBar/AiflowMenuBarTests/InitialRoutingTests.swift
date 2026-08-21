import XCTest
@testable import AiflowMenuBar

@MainActor
final class InitialRoutingTests: XCTestCase {
    private func request(
        state: CodexInitialRoutingState = .pending,
        response: String? = nil,
        project: RunResultHandoff.ProjectContext? = nil
    ) -> CodexInitialRoutingRequest {
        .init(schemaVersion: 1, runId: UUID().uuidString,
              project: project ?? .init(id: UUID(), name: "demo", path: "/repos/demo"),
              sourceChat: .init(url: "https://chatgpt.com/c/chat", conversationId: "chat"),
              prompt: "Fix it", manualModelRole: "terra", manualModelId: "gpt-5.6-terra", manualEffort: "medium",
              assistantMessage: response, state: state, createdAt: Date(), updatedAt: Date(), terminalReason: nil)
    }
    func testParserRejectsAnythingOutsideExactContract() throws {
        XCTAssertEqual(try CodexInitialRoutingParser.parse("# Codex Routing\n## Model\nsol\n## Reasoning\nhigh"), .init(modelRole: "sol", effort: "high"))
        XCTAssertThrowsError(try CodexInitialRoutingParser.parse("# Codex Routing\n## Model\nsol\n## Reasoning\nhigh\nextra"))
    }

    func testRestartDoesNotReplayDeliveredRequest() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CodexInitialRoutingStore(directoryURL: directory)
        let request = request()
        try store.persist(request)
        try store.markDelivering(runId: request.runId)
        try store.markDelivered(runId: request.runId)
        _ = try store.reconcileAfterRestart()
        XCTAssertEqual(try store.record(runId: request.runId)?.state, .manualAttention)
    }

    func testEnumerationFailsClosedAndPreservesMalformedEvidence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CodexInitialRoutingStore(directoryURL: directory)
        try store.persist(request())
        let corruptURL = directory.appendingPathComponent("\(UUID().uuidString).json")
        let malformed = Data("not json".utf8)
        try malformed.write(to: corruptURL)
        XCTAssertThrowsError(try store.allRequests()) { error in
            XCTAssertEqual(error as? CodexInitialRoutingStoreError, .unreadableRecord)
        }
        XCTAssertEqual(try Data(contentsOf: corruptURL), malformed)
    }

    func testRestartConvertsEveryOwnerlessRoutingStateToTheSafeMatrix() throws {
        let states: [(CodexInitialRoutingState, String?, CodexInitialRoutingState, Bool?)] = [
            (.pending, nil, .manualAttention, true),
            (.delivering, nil, .manualAttention, true),
            (.delivered, nil, .manualAttention, true),
            (.completed, "# Codex Routing\n## Model\nsol\n## Reasoning\nhigh", .manualAttention, true),
            (.starting, "# Codex Routing\n## Model\nsol\n## Reasoning\nhigh", .manualAttention, false),
            (.started, "# Codex Routing\n## Model\nsol\n## Reasoning\nhigh", .manualAttention, false),
            (.cancelled, nil, .cancelled, nil),
            (.manualAttention, nil, .manualAttention, nil)
        ]
        for (state, response, expectedState, expectedFallback) in states {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = CodexInitialRoutingStore(directoryURL: directory)
            let record = request(state: state, response: response)
            try store.persist(record)
            _ = try store.reconcileAfterRestart()
            let updated = try store.record(runId: record.runId)
            XCTAssertEqual(updated?.state, expectedState, "\(state)")
            XCTAssertEqual(updated?.manualFallbackAvailable, expectedFallback, "\(state)")
        }
    }

    func testPendingRemainsRetryableUntilTheOwningMacOSProcessRestarts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CodexInitialRoutingStore(directoryURL: directory)
        let record = request()
        try store.persist(record)

        // Browser reconnect is not startup reconciliation; the same in-memory owner still owns
        // this request, so the transport may safely obtain it from the pending queue.
        XCTAssertEqual(try store.pendingRequest()?.runId, record.runId)
        XCTAssertEqual(try store.record(runId: record.runId)?.state, .pending)
    }

    func testManualFallbackCannotBeElevatedAfterTheExecutionBoundary() throws {
        for state in [CodexInitialRoutingState.starting, .started] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = CodexInitialRoutingStore(directoryURL: directory)
            let record = request(state: state)
            try store.persist(record)
            try store.markManualAttention(runId: record.runId, reason: "execution ambiguous")
            XCTAssertEqual(try store.record(runId: record.runId)?.manualFallbackAvailable, false)
            XCTAssertThrowsError(try store.markManualAttention(
                runId: record.runId,
                reason: "stale browser failure",
                manualFallbackAvailable: true
            ))
            XCTAssertEqual(try store.record(runId: record.runId)?.manualFallbackAvailable, false)
        }
    }

    func testStartupReconciliationMakesPendingRoutingManualAttentionWithoutAutomaticTransportWork() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suiteName = "aiflow.initial-routing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let projectPath = directory.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: projectPath, withIntermediateDirectories: true)
        let savedProjects = SavedProjectStore(fileURL: directory.appendingPathComponent("saved.json"))
        let project = savedProjects.add(path: projectPath.path, name: "demo").project
        let routingStore = CodexInitialRoutingStore(directoryURL: directory.appendingPathComponent("routing"))
        let record = request(project: .init(id: project.id, name: project.name, path: project.path))
        try routingStore.persist(record)
        let attention = InitialRoutingAttentionRecorder(defaults: defaults)
        let viewModel = WidgetViewModel(
            store: savedProjects,
            map: ChatProjectMap(fileURL: directory.appendingPathComponent("map.json")),
            defaults: defaults,
            detectChat: { nil },
            validateGit: { .repository(root: $0) },
            attention: attention,
            initialRoutingStore: routingStore
        )
        viewModel.applyConfigForTesting(CodexConfig(
            models: [CodexModel(role: "terra", modelId: "gpt-5.6-terra")],
            reasoningEfforts: ["medium"],
            defaultSandbox: "workspace-write"
        ))

        viewModel.reconcileInitialRoutingAfterRestartForTesting()

        XCTAssertEqual(viewModel.initialRoutingAttention?.runId, record.runId)
        XCTAssertEqual(viewModel.initialRoutingAttention?.state, .manualAttention)
        XCTAssertEqual(viewModel.initialRoutingAttention?.manualFallbackAvailable, true)
        XCTAssertEqual(viewModel.runState, .ready)
        XCTAssertNil(try routingStore.pendingRequest(), "a stale request cannot generate a browser routing event")
        XCTAssertEqual(attention.events, [.routingNeedsAttention(
            runId: record.runId,
            projectName: project.name,
            category: "manual_fallback"
        )])
    }

    func testManualFallbackUsesSameRunAndPreventsLateResponse() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CodexInitialRoutingStore(directoryURL: directory)
        var record = request(state: .manualAttention)
        record.manualFallbackAvailable = true
        try store.persist(record)
        let starting = try store.beginManualFallback(runId: record.runId)
        XCTAssertEqual(starting.runId, record.runId)
        XCTAssertEqual(starting.manualModelRole, "terra")
        XCTAssertThrowsError(try store.captureResponse(runId: record.runId, conversationId: "chat", assistantMessage: "# Codex Routing\n## Model\nsol\n## Reasoning\nhigh"))
    }

    func testRestartAfterExecutionStartNeverOffersManualFallback() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CodexInitialRoutingStore(directoryURL: directory)
        let record = request(state: .starting)
        try store.persist(record)
        _ = try store.reconcileAfterRestart()
        XCTAssertEqual(try store.record(runId: record.runId)?.manualFallbackAvailable, false)
        XCTAssertThrowsError(try store.beginManualFallback(runId: record.runId))
    }
}

@MainActor
private final class InitialRoutingAttentionRecorder: AttentionCoordinating {
    private(set) var preferences: AiflowAttentionPreferences
    private(set) var events: [AiflowAttentionEvent] = []

    init(defaults: UserDefaults) {
        preferences = AiflowAttentionPreferences(defaults: defaults)
    }

    func updatePreferences(_ preferences: AiflowAttentionPreferences) { self.preferences = preferences }
    func attachPresenter(_ presenter: AttentionWidgetPresenting?) {}
    func updateWidgetVisibility(_ isVisible: Bool) {}
    func deliver(_ event: AiflowAttentionEvent) { events.append(event) }
    func requestNotificationPermissionIfNeeded() async -> Bool { true }
}
