import Network
import XCTest

@testable import AiflowMenuBar

/// End-to-end over a real loopback socket: a real `WidgetViewModel` wired to a real
/// `AiflowBridgeServer`, with a real TCP client on the other side.
///
/// Only the Codex events are injected. The Codex App Server transport itself is verified
/// separately against the live binary; what these tests prove is that a run's lifecycle is
/// mirrored to a connected client, and that a client's commands reach the run.
@MainActor
final class BridgeIntegrationTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var server: AiflowBridgeServer!
    private var viewModel: WidgetViewModel!
    private var client: TestBridgeClient!

    private let project = SavedProject(name: "ef", path: "/repos/ef")
    private let token = BridgeToken.generate()

    override func setUp() async throws {
        try await super.setUp()
        let unique = UUID().uuidString
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiflow-bridge-e2e-\(unique)")
        suiteName = "aiflow.tests.e2e.\(unique)"
        defaults = UserDefaults(suiteName: suiteName)

        viewModel = WidgetViewModel(
            store: SavedProjectStore(fileURL: directory.appendingPathComponent("saved.json")),
            map: ChatProjectMap(fileURL: directory.appendingPathComponent("map.json")),
            defaults: defaults,
            detectChat: { nil },
            validateGit: { .repository(root: $0) },
            notifications: QuietNotifications()
        )

        // An explicit test token: never the real one from Application Support.
        server = AiflowBridgeServer(port: 0, token: token)
        viewModel.attachBridge(server)
        let port = try await server.waitUntilReady()

        client = try TestBridgeClient(port: port)
        // A client is greeted with hello, then must authenticate before any run state.
        _ = try await client.nextEvent(ofType: .hello)
        client.send(#"{"type":"auth","token":"\#(token)"}"#)
        _ = try await client.nextEvent(ofType: .snapshot)
    }

    override func tearDown() async throws {
        client?.close()
        server?.stop()
        try? await server?.waitUntilStopped()
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    /// A run's lifecycle is mirrored to the connected client as it happens.
    func testRunLifecycleIsMirroredToTheClient() async throws {
        viewModel.enterRunningForTesting(project)
        viewModel.handleEventForTesting(.started, project: project)

        let status = try await client.nextEvent(ofType: .runStatus)
        XCTAssertEqual(status.runState, "running")

        viewModel.handleEventForTesting(.assistantMessage("Reading the repository…"), project: project)
        let message = try await client.nextEvent(ofType: .agentMessage)
        XCTAssertEqual(message.message, "Reading the repository…")

        viewModel.handleEventForTesting(.finished, project: project)
        let completed = try await client.nextEvent(ofType: .runCompleted)
        XCTAssertEqual(completed.runState, "completed")
        XCTAssertEqual(completed.project, "ef")
        XCTAssertEqual(completed.message, "Reading the repository…")
    }

    func testApprovalRequestIsMirroredWithItsExactId() async throws {
        viewModel.enterRunningForTesting(project)
        viewModel.handleEventForTesting(
            .approvalRequested(
                id: .integer(0), kind: .commandExecution, summary: "curl -I https://example.com",
                detail: "Requires network access", permissionProfile: nil),
            project: project)

        let event = try await client.nextEvent(ofType: .approvalRequested)

        // id 0 is what the live App Server actually sends first.
        XCTAssertEqual(event.requestId, .integer(0))
        XCTAssertEqual(event.kind, "command_execution")
        XCTAssertEqual(event.summary, "curl -I https://example.com")
        XCTAssertEqual(event.detail, "Requires network access")
    }

    func testQuestionSetIsMirroredWhole() async throws {
        viewModel.enterRunningForTesting(project)
        viewModel.handleEventForTesting(
            .inputRequested(
                id: .integer(7),
                questions: ["q1", "q2"].map {
                    QuestionItem(
                        id: $0, header: "H", question: "?",
                        options: [QuestionOption(label: "v1", description: "Stable")],
                        isOther: true, isSecret: false)
                }), project: project)

        let event = try await client.nextEvent(ofType: .questionRequested)

        XCTAssertEqual(event.requestId, .integer(7))
        XCTAssertEqual(event.questions?.map(\.id), ["q1", "q2"])
        XCTAssertEqual(event.questions?.first?.options.first?.label, "v1")
    }

    /// Cancel sent over the socket reaches the run and moves it to cancelling.
    func testCancelCommandFromTheClientCancelsTheRun() async throws {
        viewModel.enterRunningForTesting(project)
        viewModel.handleEventForTesting(.started, project: project)
        _ = try await client.nextEvent(ofType: .runStatus)

        client.send(#"{"type":"cancel"}"#)

        let status = try await client.nextEvent(ofType: .runStatus)
        XCTAssertEqual(status.runState, "cancelling")
        XCTAssertEqual(viewModel.runState, .cancelling(project))

        // The run only reports cancelled once Codex confirms the turn wound down.
        viewModel.handleEventForTesting(.cancelled, project: project)
        let cancelled = try await client.nextEvent(ofType: .runCancelled)
        XCTAssertEqual(cancelled.runState, "cancelled")
    }

    /// An approve carrying a stale id must not resolve the pending request.
    func testStaleApproveOverTheSocketIsIgnored() async throws {
        viewModel.enterRunningForTesting(project)
        viewModel.handleEventForTesting(
            .approvalRequested(
                id: .integer(17), kind: .commandExecution, summary: "npm i", detail: nil,
                permissionProfile: nil), project: project)
        _ = try await client.nextEvent(ofType: .approvalRequested)

        client.send(#"{"type":"approve","requestId":16}"#)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(viewModel.pendingApproval?.id, .integer(17), "stale id must not approve")

        client.send(#"{"type":"approve","requestId":17}"#)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(viewModel.runState, .respondingToRequest(.integer(17)))
    }

    /// Malformed and unknown frames arriving over the real socket must not touch the run.
    func testGarbageOverTheSocketCannotMutateRunState() async throws {
        viewModel.enterRunningForTesting(project)
        viewModel.handleEventForTesting(.started, project: project)
        _ = try await client.nextEvent(ofType: .runStatus)

        client.send("{not json")
        client.send(#"{"type":"launch_codex"}"#)
        client.send(#"{"type":"cancel","repositoryPath":"/etc","sandbox":"danger-full-access"}"#)

        try await Task.sleep(for: .milliseconds(300))

        // The recognized verb still applies; the smuggled fields are simply not decodable.
        XCTAssertEqual(viewModel.runState, .cancelling(project))
    }

    /// A client that reconnects mid-run is handed the current state, including whatever the
    /// run is blocked on, without the run restarting.
    func testReconnectingClientReceivesASnapshotOfTheLiveRun() async throws {
        viewModel.enterRunningForTesting(project)
        viewModel.handleEventForTesting(.started, project: project)
        viewModel.handleEventForTesting(.assistantMessage("halfway"), project: project)
        viewModel.handleEventForTesting(
            .approvalRequested(
                id: .integer(3), kind: .fileChange, summary: "Modify files", detail: nil,
                permissionProfile: nil), project: project)

        // Drop the viewer entirely, as closing the extension host would.
        client.close()
        try await Task.sleep(for: .milliseconds(300))

        // The run is untouched by the viewer going away.
        XCTAssertEqual(viewModel.pendingApproval?.id, .integer(3))

        let reconnected = try TestBridgeClient(port: server.boundPort)
        defer { reconnected.close() }
        _ = try await reconnected.nextEvent(ofType: .hello)
        // A fresh connection starts untrusted and must authenticate again.
        reconnected.send(#"{"type":"auth","token":"\#(token)"}"#)
        let snapshot = try await reconnected.nextEvent(ofType: .snapshot)

        XCTAssertEqual(snapshot.runState, "waiting_for_approval")
        XCTAssertEqual(snapshot.project, "ef")
        XCTAssertEqual(snapshot.message, "halfway")
        XCTAssertEqual(snapshot.requestId, .integer(3))
        XCTAssertEqual(snapshot.kind, "file_change")

        // And the reconnected client can answer the request it just learned about.
        reconnected.send(#"{"type":"approve","requestId":3}"#)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(viewModel.runState, .respondingToRequest(.integer(3)))
    }

    /// `file_open` is emitted only for a path inside the active repository.
    func testFileOpenIsEmittedOnlyForPathsInsideTheRepository() async throws {
        viewModel.enterRunningForTesting(project)

        XCTAssertFalse(viewModel.emitFileOpen(path: "/etc/passwd"))
        XCTAssertFalse(viewModel.emitFileOpen(path: "/repos/ef-other/a.swift"))

        XCTAssertTrue(viewModel.emitFileOpen(path: "/repos/ef/src/main.swift"))

        let event = try await client.nextEvent(ofType: .fileOpen)
        XCTAssertEqual(event.path, "/repos/ef/src/main.swift")
    }

    /// The README spike affordance, against a real directory on disk: Aiflow picks the path,
    /// validates it, and the connected client receives it over the socket.
    func testOpenReadmeInCompanionEmitsTheRepositoryReadme() async throws {
        let repo = directory.appendingPathComponent("readme-repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let readme = repo.appendingPathComponent("README.md")
        try Data("# Test repo\n".utf8).write(to: readme)

        let saved = SavedProject(name: "readme-repo", path: repo.path)

        XCTAssertTrue(viewModel.openReadmeInCompanion(saved))

        let event = try await client.nextEvent(ofType: .fileOpen)
        XCTAssertEqual(
            event.path, readme.resolvingSymlinksInPath().path,
            "the emitted path must be the repository's own README")
        XCTAssertTrue(FileManager.default.fileExists(atPath: event.path ?? ""))
    }

    func testOpenReadmeInCompanionRefusesARepositoryWithoutOne() async throws {
        let repo = directory.appendingPathComponent("bare-repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)

        XCTAssertFalse(
            viewModel.openReadmeInCompanion(SavedProject(name: "bare", path: repo.path)))
        XCTAssertTrue(viewModel.notice.contains("no README.md"))
    }

    /// The outside-repository rejection, re-proven against a real file that genuinely exists.
    func testAnExistingFileOutsideTheRepositoryIsStillRefused() async throws {
        let repo = directory.appendingPathComponent("scoped-repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let saved = SavedProject(name: "scoped", path: repo.path)

        // /etc/passwd exists, so this is a scoping decision rather than a missing-file one.
        XCTAssertTrue(FileManager.default.fileExists(atPath: "/etc/passwd"))
        XCTAssertFalse(viewModel.emitFileOpen(path: "/etc/passwd", in: saved))

        // Nothing reached the client.
        do {
            let leaked = try await client.nextEvent(ofType: .fileOpen, timeout: 0.6)
            XCTFail("an out-of-repository path was emitted: \(leaked.path ?? "?")")
        } catch {
            // Expected: the wait timed out because no file_open was ever sent.
        }
    }
}

@MainActor
private final class QuietNotifications: NotificationManaging {
    func prepareForRun() async -> Bool { false }
    func sendApproval(for request: ApprovalRequest) {}
    func sendQuestion(for question: UserQuestion) {}
    func sendCompletion(for project: SavedProject) {}
    func sendFailure(for project: SavedProject?) {}
    func removePendingRequest(id: CodexRequestID) {}
}

/// A minimal real TCP client for the integration tests.
private final class TestBridgeClient {
    private let connection: NWConnection
    private let buffer = LineBuffer()
    private var events: [BridgeEvent] = []
    private let lock = NSLock()

    init(port: UInt16) throws {
        connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp)
        connection.start(queue: DispatchQueue(label: "aiflow.bridge.e2e.client"))
        read()
    }

    private func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                let decoded = self.buffer.append(data).compactMap(BridgeCodec.decodeEvent)
                self.lock.lock()
                self.events.append(contentsOf: decoded)
                self.lock.unlock()
            }
            if isComplete || error != nil { return }
            self.read()
        }
    }

    func send(_ line: String) {
        connection.send(content: Data((line + "\n").utf8), completion: .contentProcessed { _ in })
    }

    /// Waits for the next event of a given type, ignoring any others in between.
    func nextEvent(ofType type: BridgeEventType, timeout: TimeInterval = 5) async throws
        -> BridgeEvent
    {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            let index = events.firstIndex { $0.type == type }
            let found = index.map { events.remove(at: $0) }
            lock.unlock()
            if let found { return found }
            try? await Task.sleep(for: .milliseconds(25))
        }
        throw NSError(
            domain: "TestBridgeClient", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "timed out waiting for \(type)"])
    }

    func close() { connection.cancel() }
}
