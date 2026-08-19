import Network
import XCTest

@testable import AiflowMenuBar

final class BridgeProtocolTests: XCTestCase {
    func testEventRoundTripsThroughJSONL() throws {
        var event = BridgeEvent(type: .runStarted)
        event.project = "ef"
        event.model = "terra"
        event.effort = "high"

        let line = try XCTUnwrap(BridgeCodec.encodeLine(event))
        XCTAssertTrue(line.hasSuffix("\n"), "frames must be newline delimited")

        let decoded = try XCTUnwrap(BridgeCodec.decodeEvent(line))
        XCTAssertEqual(decoded, event)
        XCTAssertEqual(decoded.type, .runStarted)
    }

    func testEventTypeWireNames() throws {
        let line = try XCTUnwrap(BridgeCodec.encodeLine(BridgeEvent(type: .approvalRequested)))
        XCTAssertTrue(line.contains("\"approval_requested\""))
    }

    func testCommandDecodesEachSupportedVerb() {
        let cases: [(String, BridgeCommandType)] = [
            (#"{"type":"ping"}"#, .ping),
            (#"{"type":"cancel"}"#, .cancel),
            (#"{"type":"approve","requestId":3}"#, .approve),
            (#"{"type":"deny","requestId":3}"#, .deny),
            (#"{"type":"answer_question","requestId":4,"answers":{"q1":"a"}}"#, .answerQuestion),
        ]

        for (json, expected) in cases {
            XCTAssertEqual(BridgeCodec.decodeCommand(json)?.type, expected, json)
        }
    }

    func testRequestIdSurvivesAsIntegerOrString() throws {
        let integer = try XCTUnwrap(BridgeCodec.decodeCommand(#"{"type":"approve","requestId":0}"#))
        let string = try XCTUnwrap(
            BridgeCodec.decodeCommand(#"{"type":"approve","requestId":"abc"}"#))

        // id 0 is real: the live App Server numbers approval requests from zero.
        XCTAssertEqual(integer.requestId, .integer(0))
        XCTAssertEqual(string.requestId, .string("abc"))
    }

    func testMalformedJSONIsRejected() {
        XCTAssertNil(BridgeCodec.decodeCommand("{not json"))
        XCTAssertNil(BridgeCodec.decodeCommand(""))
        XCTAssertNil(BridgeCodec.decodeCommand("   "))
        XCTAssertNil(BridgeCodec.decodeCommand("[]"))
    }

    func testUnknownCommandTypeIsRejected() {
        XCTAssertNil(BridgeCodec.decodeCommand(#"{"type":"run"}"#))
        XCTAssertNil(BridgeCodec.decodeCommand(#"{"type":"approve_all"}"#))
        XCTAssertNil(BridgeCodec.decodeCommand(#"{"requestId":1}"#))
    }

    /// The command shape has no field for a path, sandbox, model, or command, so a client
    /// cannot smuggle one in — extra keys are simply dropped.
    func testClientSuppliedExecutionFieldsAreNotDecoded() throws {
        let json = """
            {"type":"cancel","repositoryPath":"/etc","sandbox":"danger-full-access",
             "modelId":"evil","command":"rm -rf /"}
            """
        let command = try XCTUnwrap(BridgeCodec.decodeCommand(json))

        XCTAssertEqual(command.type, .cancel)
        XCTAssertNil(command.answers)
        XCTAssertNil(command.requestId)

        let reencoded = try XCTUnwrap(BridgeCodec.encodeLine(BridgeEvent(type: .hello)))
        XCTAssertFalse(reencoded.contains("danger-full-access"))
    }

    func testQuestionSetIsCarriedWhole() {
        let questions = ["q1", "q2", "q3"].map {
            QuestionItem(
                id: $0, header: "H", question: "?",
                options: [QuestionOption(label: "v1", description: "Stable")],
                isOther: true, isSecret: false)
        }
        let request = UserQuestion(id: .integer(4), questions: questions, projectName: "ef")

        let event = BridgeEvent.questionRequested(request)

        XCTAssertEqual(event.questions?.map(\.id), ["q1", "q2", "q3"])
        XCTAssertEqual(event.questions?.first?.options.first?.label, "v1")
        XCTAssertEqual(event.questions?.first?.isOther, true)
        XCTAssertEqual(event.requestId, .integer(4))
    }

    func testRunStateBridgeNamesAreStable() {
        let project = SavedProject(name: "ef", path: "/repos/ef")

        XCTAssertEqual(RunState.ready.bridgeName, "ready")
        XCTAssertEqual(RunState.running(project).bridgeName, "running")
        XCTAssertEqual(RunState.cancelling(project).bridgeName, "cancelling")
        XCTAssertEqual(RunState.cancelled(project).bridgeName, "cancelled")
        XCTAssertEqual(RunState.completed(project).bridgeName, "completed")
        XCTAssertEqual(RunState.failed(project: project, message: "x").bridgeName, "failed")
    }
}

// MARK: - Server

final class AiflowBridgeServerTests: XCTestCase {
    /// A high port so a running Aiflow app on 47321 cannot collide with the tests.
    private func freePort() -> UInt16 { UInt16.random(in: 49_200...49_900) }

    func testServerBindsToLoopbackOnly() {
        let server = AiflowBridgeServer(port: freePort())
        defer { server.stop() }

        XCTAssertTrue(server.start())
        XCTAssertTrue(server.isListening)
        XCTAssertEqual(AiflowBridgeServer.loopbackHost, "127.0.0.1")
        XCTAssertNotEqual(AiflowBridgeServer.loopbackHost, "0.0.0.0")
    }

    func testDefaultPortIsTheAgreedLocalPort() {
        XCTAssertEqual(AiflowBridgeServer.defaultPort, 47321)
    }

    /// End-to-end over a real loopback socket: connect, receive hello + snapshot, send a
    /// command, and confirm it reaches the controller.
    func testClientReceivesHelloAndSnapshotThenCommandsReachController() async throws {
        let port = freePort()
        let controller = await MockController()
        let server = AiflowBridgeServer(port: port)
        await MainActor.run { server.controller = controller }
        defer { server.stop() }
        XCTAssertTrue(server.start())

        let client = try LoopbackClient(port: port)
        defer { client.close() }

        let hello = try await client.nextLine(timeout: 3)
        XCTAssertEqual(BridgeCodec.decodeEvent(hello)?.type, .hello)

        let snapshot = try await client.nextLine(timeout: 3)
        let decoded = BridgeCodec.decodeEvent(snapshot)
        XCTAssertEqual(decoded?.type, .snapshot)
        XCTAssertEqual(decoded?.runState, "ready")

        client.send(#"{"type":"cancel"}"# + "\n")
        try await waitUntil(timeout: 3) { await controller.received.contains(.cancel) }

        // Malformed and unknown lines must be dropped without reaching the controller.
        client.send("{not json\n")
        client.send(#"{"type":"launch_codex"}"# + "\n")
        try? await Task.sleep(for: .milliseconds(300))
        let types = await controller.received
        XCTAssertEqual(types, [.cancel])
    }

    func testBroadcastReachesConnectedClient() async throws {
        let port = freePort()
        let controller = await MockController()
        let server = AiflowBridgeServer(port: port)
        await MainActor.run { server.controller = controller }
        defer { server.stop() }
        XCTAssertTrue(server.start())

        let client = try LoopbackClient(port: port)
        defer { client.close() }

        _ = try await client.nextLine(timeout: 3)  // hello
        _ = try await client.nextLine(timeout: 3)  // snapshot

        server.broadcast(.agentMessage("hello from codex"))

        let line = try await client.nextLine(timeout: 3)
        let event = BridgeCodec.decodeEvent(line)
        XCTAssertEqual(event?.type, .agentMessage)
        XCTAssertEqual(event?.message, "hello from codex")
    }

    /// Losing the viewer must never disturb the run.
    func testDisconnectionDoesNotMutateRunState() async throws {
        let port = freePort()
        let controller = await MockController()
        let server = AiflowBridgeServer(port: port)
        await MainActor.run { server.controller = controller }
        defer { server.stop() }
        XCTAssertTrue(server.start())

        let client = try LoopbackClient(port: port)
        _ = try await client.nextLine(timeout: 3)
        client.close()

        try? await Task.sleep(for: .milliseconds(300))

        let commands = await controller.received
        XCTAssertTrue(commands.isEmpty, "a disconnect must not synthesize a command")

        // Broadcasting with no client attached must be harmless.
        server.broadcast(.runStatus("running"))
    }
}

@MainActor
private final class MockController: BridgeController {
    var received: [BridgeCommandType] = []
    var snapshot = BridgeEvent(type: .snapshot)

    init() {
        snapshot.runState = "ready"
        snapshot.connected = true
    }

    func handleBridgeCommand(_ command: BridgeCommand) {
        received.append(command.type)
    }

    func bridgeSnapshot() -> BridgeEvent { snapshot }
}

/// A minimal loopback TCP client for the tests.
private final class LoopbackClient {
    private let connection: NWConnection
    private let buffer = LineBuffer()
    private var lines: [String] = []
    private let lock = NSLock()

    init(port: UInt16) throws {
        connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp)
        connection.start(queue: DispatchQueue(label: "aiflow.bridge.test.client"))
        read()
    }

    private func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                let newLines = self.buffer.append(data)
                self.lock.lock()
                self.lines.append(contentsOf: newLines)
                self.lock.unlock()
            }
            if isComplete || error != nil { return }
            self.read()
        }
    }

    func send(_ text: String) {
        connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in })
    }

    func nextLine(timeout: TimeInterval) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            let line = lines.isEmpty ? nil : lines.removeFirst()
            lock.unlock()
            if let line { return line }
            try? await Task.sleep(for: .milliseconds(25))
        }
        throw XCTSkip("no line received within \(timeout)s")
    }

    func close() { connection.cancel() }
}

private func waitUntil(
    timeout: TimeInterval, _ condition: @Sendable () async -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(25))
    }
    XCTFail("condition not met within \(timeout)s")
}
