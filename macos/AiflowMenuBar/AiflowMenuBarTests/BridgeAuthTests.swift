import Network
import XCTest

@testable import AiflowMenuBar

final class BridgeTokenTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiflow-token-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private var tokenURL: URL { directory.appendingPathComponent("bridge-token") }

    func testGeneratedTokenIsLongAndUnpredictable() {
        let first = BridgeToken.generate()
        let second = BridgeToken.generate()

        // 32 random bytes, hex encoded.
        XCTAssertEqual(first.count, 64)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.allSatisfy { $0.isHexDigit })
    }

    func testTokenIsCreatedOnceAndReused() throws {
        let created = try XCTUnwrap(BridgeToken.loadOrCreate(at: tokenURL))
        let reloaded = try XCTUnwrap(BridgeToken.loadOrCreate(at: tokenURL))

        XCTAssertEqual(created, reloaded, "the token must be stable across launches")
    }

    /// The token file must not be readable by other users on the machine.
    func testTokenFileIsUserOnly() throws {
        _ = BridgeToken.loadOrCreate(at: tokenURL)

        let attributes = try FileManager.default.attributesOfItem(atPath: tokenURL.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)

        XCTAssertEqual(permissions.int16Value, 0o600)
    }

    func testMatchesAcceptsOnlyTheExactToken() {
        let token = BridgeToken.generate()

        XCTAssertTrue(BridgeToken.matches(token, expected: token))
        XCTAssertFalse(BridgeToken.matches(token + "a", expected: token))
        XCTAssertFalse(BridgeToken.matches(String(token.dropLast()), expected: token))
        XCTAssertFalse(BridgeToken.matches("", expected: token))
        XCTAssertFalse(BridgeToken.matches(token, expected: ""), "an empty secret matches nothing")
    }
}

// MARK: - Bounded framing

final class BoundedLineBufferTests: XCTestCase {
    func testSplitsCompleteLines() {
        let buffer = BoundedLineBuffer()
        XCTAssertEqual(buffer.append(Data("{\"a\":1}\n{\"b\":2}\n".utf8)), ["{\"a\":1}", "{\"b\":2}"])
    }

    func testHoldsPartialLineUntilNewlineArrives() {
        let buffer = BoundedLineBuffer()
        XCTAssertEqual(buffer.append(Data("{\"a\":".utf8)), [])
        XCTAssertEqual(buffer.append(Data("1}\n".utf8)), ["{\"a\":1}"])
    }

    func testOversizedFrameWithoutANewlineIsRejected() {
        let buffer = BoundedLineBuffer(limit: 1024)

        XCTAssertNotNil(buffer.append(Data(repeating: UInt8(ascii: "x"), count: 512)))
        XCTAssertNil(
            buffer.append(Data(repeating: UInt8(ascii: "x"), count: 1024)),
            "exceeding the limit without a newline must reject the stream")
        XCTAssertTrue(buffer.didOverflow)
    }

    func testBufferStaysRejectedAfterOverflow() {
        let buffer = BoundedLineBuffer(limit: 64)
        _ = buffer.append(Data(repeating: UInt8(ascii: "x"), count: 200))

        XCTAssertNil(buffer.append(Data("{\"type\":\"cancel\"}\n".utf8)))
    }

    /// Many small complete frames must never trip the limit, however many arrive.
    func testManyCompleteFramesDoNotOverflow() {
        let buffer = BoundedLineBuffer(limit: 128)
        let frame = Data("{\"type\":\"ping\"}\n".utf8)

        for _ in 0..<500 {
            XCTAssertNotNil(buffer.append(frame))
        }
        XCTAssertFalse(buffer.didOverflow)
    }

    func testDefaultLimitIsBounded() {
        XCTAssertEqual(BoundedLineBuffer.maxFrameBytes, 64 * 1024)
    }

    // MARK: - Oversized frames that are already newline-terminated
    //
    // Checking only the trailing remainder would let a complete oversized frame through,
    // because extracting it leaves nothing behind to measure.

    private func payload(_ count: Int) -> Data {
        Data(repeating: UInt8(ascii: "x"), count: count)
    }

    func testOversizedCompleteFrameInASingleAppendIsRejected() {
        let buffer = BoundedLineBuffer(limit: 64)

        var frame = payload(70)
        frame.append(UInt8(ascii: "\n"))

        XCTAssertNil(buffer.append(frame), "a terminated oversized frame must be rejected")
        XCTAssertTrue(buffer.didOverflow)
    }

    func testOversizedFrameCompletedByALaterChunkIsRejected() {
        let buffer = BoundedLineBuffer(limit: 64)

        // Stay under the limit per chunk so only the assembled frame is oversized.
        XCTAssertNotNil(buffer.append(payload(40)))
        XCTAssertNotNil(buffer.append(payload(20)))

        // This chunk both pushes it over and terminates it.
        XCTAssertNil(buffer.append(payload(20) + Data("\n".utf8)))
        XCTAssertTrue(buffer.didOverflow)
    }

    func testNoFramesAreReturnedFromAnAppendContainingAnOversizedFrame() {
        let buffer = BoundedLineBuffer(limit: 64)

        var data = Data("{\"type\":\"ping\"}\n".utf8)
        data.append(payload(70))
        data.append(UInt8(ascii: "\n"))

        // The good frame that preceded the oversized one is discarded along with it.
        XCTAssertNil(buffer.append(data))
    }

    func testFrameExactlyAtTheLimitIsAccepted() {
        let buffer = BoundedLineBuffer(limit: 64)

        var frame = payload(64)
        frame.append(UInt8(ascii: "\n"))

        let lines = buffer.append(frame)
        XCTAssertEqual(lines?.count, 1)
        XCTAssertEqual(lines?.first?.count, 64)
        XCTAssertFalse(buffer.didOverflow)
    }

    func testSeveralSmallFramesInOneAppendAreAccepted() {
        let buffer = BoundedLineBuffer(limit: 64)
        let data = Data("{\"type\":\"ping\"}\n{\"type\":\"cancel\"}\n".utf8)

        XCTAssertEqual(buffer.append(data), ["{\"type\":\"ping\"}", "{\"type\":\"cancel\"}"])
        XCTAssertFalse(buffer.didOverflow)
    }
}

// MARK: - Authenticated server

/// End-to-end over a real loopback socket, with a real token.
@MainActor
final class BridgeAuthenticationTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var server: AiflowBridgeServer!
    private var viewModel: WidgetViewModel!
    private let token = BridgeToken.generate()
    private let project = SavedProject(name: "ef", path: "/repos/ef")

    override func setUp() async throws {
        try await super.setUp()
        let unique = UUID().uuidString
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiflow-auth-\(unique)")
        suiteName = "aiflow.tests.auth.\(unique)"
        defaults = UserDefaults(suiteName: suiteName)

        viewModel = WidgetViewModel(
            store: SavedProjectStore(fileURL: directory.appendingPathComponent("saved.json")),
            map: ChatProjectMap(fileURL: directory.appendingPathComponent("map.json")),
            defaults: defaults,
            detectChat: { nil },
            validateGit: { .repository(root: $0) },
            notifications: MuteNotifications()
        )

        server = AiflowBridgeServer(port: UInt16.random(in: 49_920...49_990), token: token)
        viewModel.attachBridge(server)
    }

    override func tearDown() async throws {
        server?.stop()
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    private func connect() throws -> AuthTestClient {
        try AuthTestClient(port: server.boundPort)
    }

    private func authenticate(_ client: AuthTestClient) {
        client.send(#"{"type":"auth","token":"\#(token)"}"#)
    }

    // MARK: Unauthenticated

    func testUnauthenticatedClientGetsHelloButNoRunState() async throws {
        viewModel.enterRunningForTesting(project)
        let client = try connect()
        defer { client.close() }

        let hello = try await client.nextEvent(ofType: .hello)
        XCTAssertNil(hello.runState, "the greeting must not describe the run")
        XCTAssertNil(hello.project)
        XCTAssertNil(hello.requestId)

        // No snapshot arrives without authentication.
        await XCTAssertNoEvent(client, .snapshot)
    }

    func testUnauthenticatedApprovalRequestIsNotBroadcast() async throws {
        viewModel.enterRunningForTesting(project)
        let client = try connect()
        defer { client.close() }
        _ = try await client.nextEvent(ofType: .hello)

        viewModel.handleEventForTesting(
            .approvalRequested(
                id: .integer(17), kind: .commandExecution, summary: "npm i", detail: nil,
                permissionProfile: nil), project: project)

        // The pending request id must never leak to an unauthenticated listener.
        await XCTAssertNoEvent(client, .approvalRequested)
    }

    func testUnauthenticatedCancelIsIgnored() async throws {
        viewModel.enterRunningForTesting(project)
        let client = try connect()
        defer { client.close() }
        _ = try await client.nextEvent(ofType: .hello)

        client.send(#"{"type":"cancel"}"#)
        try await Task.sleep(for: .milliseconds(350))

        XCTAssertEqual(viewModel.runState, .running(project), "the run must be untouched")
    }

    func testUnauthenticatedApproveIsIgnored() async throws {
        viewModel.enterRunningForTesting(project)
        viewModel.handleEventForTesting(
            .approvalRequested(
                id: .integer(5), kind: .commandExecution, summary: "npm i", detail: nil,
                permissionProfile: nil), project: project)

        let client = try connect()
        defer { client.close() }
        _ = try await client.nextEvent(ofType: .hello)

        client.send(#"{"type":"approve","requestId":5}"#)
        try await Task.sleep(for: .milliseconds(350))

        XCTAssertEqual(
            viewModel.pendingApproval?.id, .integer(5),
            "an unauthenticated client must not be able to approve")
    }

    func testWrongTokenCannotAuthenticate() async throws {
        viewModel.enterRunningForTesting(project)
        let client = try connect()
        defer { client.close() }
        _ = try await client.nextEvent(ofType: .hello)

        client.send(#"{"type":"auth","token":"\#(BridgeToken.generate())"}"#)

        await XCTAssertNoEvent(client, .snapshot)

        client.send(#"{"type":"cancel"}"#)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(viewModel.runState, .running(project))
    }

    // MARK: Authenticated

    func testCorrectTokenAuthenticatesAndReceivesSnapshot() async throws {
        viewModel.enterRunningForTesting(project)
        viewModel.handleEventForTesting(.assistantMessage("halfway"), project: project)

        let client = try connect()
        defer { client.close() }
        _ = try await client.nextEvent(ofType: .hello)

        authenticate(client)

        let snapshot = try await client.nextEvent(ofType: .snapshot)
        XCTAssertEqual(snapshot.runState, "running")
        XCTAssertEqual(snapshot.project, "ef")
        XCTAssertEqual(snapshot.message, "halfway")
    }

    func testAuthenticatedClientCanCancel() async throws {
        viewModel.enterRunningForTesting(project)
        let client = try connect()
        defer { client.close() }
        _ = try await client.nextEvent(ofType: .hello)
        authenticate(client)
        _ = try await client.nextEvent(ofType: .snapshot)

        client.send(#"{"type":"cancel"}"#)

        let status = try await client.nextEvent(ofType: .runStatus)
        XCTAssertEqual(status.runState, "cancelling")
    }

    /// Authentication does not loosen request-id correlation.
    func testAuthenticatedClientStillCannotApproveAStaleRequest() async throws {
        viewModel.enterRunningForTesting(project)
        let client = try connect()
        defer { client.close() }
        _ = try await client.nextEvent(ofType: .hello)
        authenticate(client)
        _ = try await client.nextEvent(ofType: .snapshot)

        viewModel.handleEventForTesting(
            .approvalRequested(
                id: .integer(17), kind: .commandExecution, summary: "npm i", detail: nil,
                permissionProfile: nil), project: project)
        _ = try await client.nextEvent(ofType: .approvalRequested)

        client.send(#"{"type":"approve","requestId":16}"#)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(viewModel.pendingApproval?.id, .integer(17))

        client.send(#"{"type":"approve","requestId":17}"#)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(viewModel.runState, .respondingToRequest(.integer(17)))
    }

    /// A reconnecting client must authenticate again, and then gets the live snapshot.
    func testReconnectMustReauthenticateAndThenRestoresSnapshot() async throws {
        viewModel.enterRunningForTesting(project)

        let first = try connect()
        _ = try await first.nextEvent(ofType: .hello)
        authenticate(first)
        _ = try await first.nextEvent(ofType: .snapshot)
        first.close()
        try await Task.sleep(for: .milliseconds(250))

        // The run is untouched by the viewer going away.
        XCTAssertEqual(viewModel.runState, .running(project))

        let second = try connect()
        defer { second.close() }
        _ = try await second.nextEvent(ofType: .hello)

        // Authentication does not carry over: the fresh connection starts untrusted.
        client_sendCancelAndExpectNoEffect(second)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(viewModel.runState, .running(project))

        authenticate(second)
        let snapshot = try await second.nextEvent(ofType: .snapshot)
        XCTAssertEqual(snapshot.runState, "running")
    }

    private func client_sendCancelAndExpectNoEffect(_ client: AuthTestClient) {
        client.send(#"{"type":"cancel"}"#)
    }

    /// Fails the test if the given event arrives within the window.
    private func XCTAssertNoEvent(
        _ client: AuthTestClient, _ type: BridgeEventType, seconds: TimeInterval = 0.7
    ) async {
        do {
            let leaked = try await client.nextEvent(ofType: type, timeout: seconds)
            XCTFail("unauthenticated client received \(leaked.type)")
        } catch {
            // Expected: the wait timed out because nothing was sent.
        }
    }
}

@MainActor
private final class MuteNotifications: NotificationManaging {
    func prepareForRun() async -> Bool { false }
    func sendApproval(for request: ApprovalRequest) {}
    func sendQuestion(for question: UserQuestion) {}
    func sendCompletion(for project: SavedProject) {}
    func sendFailure(for project: SavedProject?) {}
    func removePendingRequest(id: CodexRequestID) {}
}

private final class AuthTestClient {
    private let connection: NWConnection
    private let buffer = BoundedLineBuffer(limit: 1024 * 1024)
    private var events: [BridgeEvent] = []
    private let lock = NSLock()

    init(port: UInt16) throws {
        connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp)
        connection.start(queue: DispatchQueue(label: "aiflow.bridge.auth.client"))
        read()
    }

    private func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty, let lines = self.buffer.append(data) {
                let decoded = lines.compactMap(BridgeCodec.decodeEvent)
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
            domain: "AuthTestClient", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "timed out waiting for \(type)"])
    }

    func close() { connection.cancel() }
}

// MARK: - Single-worker routing
//
// Several companion windows can be authenticated at once. Broadcasting an execution
// instruction to all of them would have each start its own Codex turn for one Aiflow run.

@MainActor
final class BridgeWorkerRoutingTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var server: AiflowBridgeServer!
    private var viewModel: WidgetViewModel!
    private let token = BridgeToken.generate()
    private let project = SavedProject(name: "demo", path: "/repos/demo")

    override func setUp() async throws {
        try await super.setUp()
        let unique = UUID().uuidString
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiflow-routing-\(unique)")
        suiteName = "aiflow.tests.routing.\(unique)"
        defaults = UserDefaults(suiteName: suiteName)

        viewModel = WidgetViewModel(
            store: SavedProjectStore(fileURL: directory.appendingPathComponent("saved.json")),
            map: ChatProjectMap(fileURL: directory.appendingPathComponent("map.json")),
            defaults: defaults,
            detectChat: { nil },
            validateGit: { .repository(root: $0) },
            notifications: MuteNotifications()
        )
        server = AiflowBridgeServer(port: UInt16.random(in: 49_600...49_780), token: token)
        viewModel.attachBridge(server)
    }

    override func tearDown() async throws {
        server?.stop()
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    /// Connects and authenticates a companion, optionally announcing it as a worker.
    private func connectCompanion(asWorker: Bool) async throws -> AuthTestClient {
        let client = try AuthTestClient(port: server.boundPort)
        _ = try await client.nextEvent(ofType: .hello)
        client.send(#"{"type":"auth","token":"\#(token)"}"#)
        _ = try await client.nextEvent(ofType: .snapshot)
        if asWorker {
            client.send(#"{"type":"worker_available","workerState":"ready"}"#)
            try await Task.sleep(for: .milliseconds(250))
        }
        return client
    }

    func testExecutionReachesOnlyTheDesignatedWorker() async throws {
        let worker = try await connectCompanion(asWorker: true)
        let viewer = try await connectCompanion(asWorker: false)
        defer { worker.close(); viewer.close() }

        XCTAssertTrue(server.hasDesignatedWorker)
        XCTAssertTrue(
            server.sendToWorker(
                .executeRun(
                    runId: "run-1", project: project, prompt: "p", model: "terra",
                    effort: "low")))

        let received = try await worker.nextEvent(ofType: .executeRun)
        XCTAssertEqual(received.runId, "run-1")

        // The passive viewer must never be told to execute.
        do {
            let leaked = try await viewer.nextEvent(ofType: .executeRun, timeout: 0.7)
            XCTFail("a second companion received the execution request: \(leaked.runId ?? "?")")
        } catch {
            // Expected.
        }
    }

    /// A second companion announcing readiness must not take the role from the first.
    func testASecondReadyCompanionDoesNotBecomeAWorkerToo() async throws {
        let first = try await connectCompanion(asWorker: true)
        let second = try await connectCompanion(asWorker: true)
        defer { first.close(); second.close() }

        XCTAssertTrue(
            server.sendToWorker(
                .executeRun(
                    runId: "run-1", project: project, prompt: "p", model: "terra",
                    effort: "low")))

        _ = try await first.nextEvent(ofType: .executeRun)
        do {
            _ = try await second.nextEvent(ofType: .executeRun, timeout: 0.7)
            XCTFail("the execution request reached two companions")
        } catch {
            // Expected: exactly one worker serves a run.
        }
    }

    func testNoWorkerMeansExecutionIsNotSent() async throws {
        let viewer = try await connectCompanion(asWorker: false)
        defer { viewer.close() }

        XCTAssertFalse(server.hasDesignatedWorker)
        XCTAssertFalse(
            server.sendToWorker(
                .executeRun(
                    runId: "run-1", project: project, prompt: "p", model: "terra",
                    effort: "low")),
            "with no worker the app must fall back rather than broadcast")
    }

    /// Reconnecting replaces the worker rather than accumulating a second one.
    func testReconnectingWorkerDoesNotCreateASecondWorker() async throws {
        let first = try await connectCompanion(asWorker: true)
        first.close()
        try await Task.sleep(for: .milliseconds(300))

        let second = try await connectCompanion(asWorker: true)
        defer { second.close() }

        XCTAssertTrue(server.hasDesignatedWorker)
        XCTAssertTrue(
            server.sendToWorker(
                .executeRun(
                    runId: "run-2", project: project, prompt: "p", model: "terra",
                    effort: "low")))
        let delivered = try await second.nextEvent(ofType: .executeRun)
        XCTAssertEqual(delivered.runId, "run-2")
    }

    /// A report from a companion that is not the worker is not evidence about the run.
    func testWorkerReportsFromANonWorkerAreIgnored() async throws {
        let worker = try await connectCompanion(asWorker: true)
        let viewer = try await connectCompanion(asWorker: false)
        defer { worker.close(); viewer.close() }

        viewModel.startRunForTesting(project, worker: .officialVSCode, runId: "run-1")

        viewer.send(#"{"type":"worker_completed","runId":"run-1","message":"not from the worker"}"#)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(viewModel.runState, .running(project), "a viewer cannot finish a run")

        worker.send(#"{"type":"worker_completed","runId":"run-1","message":"done"}"#)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(viewModel.runState, .completed(project))
    }

    /// Passive viewers still receive ordinary run events.
    func testViewersStillReceiveStatusEvents() async throws {
        let worker = try await connectCompanion(asWorker: true)
        let viewer = try await connectCompanion(asWorker: false)
        defer { worker.close(); viewer.close() }

        server.broadcast(.agentMessage("hello"))

        let toViewer = try await viewer.nextEvent(ofType: .agentMessage)
        let toWorker = try await worker.nextEvent(ofType: .agentMessage)
        XCTAssertEqual(toViewer.message, "hello")
        XCTAssertEqual(toWorker.message, "hello")
    }
}
