import Foundation
import XCTest

@testable import AiflowMenuBar

final class HandoffTransportServerTests: XCTestCase {
    private var directory: URL!
    private var store: RunResultHandoffStore!
    private var reviewStore: ChatGPTReviewStore!
    private var routingStore: CodexInitialRoutingStore!
    private var server: HandoffTransportServer!
    private var socket: URLSessionWebSocketTask!
    private var token: String!
    private var port: UInt16!
    private var routingResponseCount = 0
    private var routingAttentionCount = 0

    override func setUp() async throws {
        try await super.setUp()

        directory =
            FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "aiflow-handoff-ws-\(UUID().uuidString)"
                )

        store =
            RunResultHandoffStore(
                directoryURL:
                    directory.appendingPathComponent(
                        "pending"
                    ),
                deliveredDirectoryURL:
                    directory.appendingPathComponent(
                        "delivered"
                    )
            )

        reviewStore = ChatGPTReviewStore(directoryURL: directory.appendingPathComponent("reviews"))
        routingStore = CodexInitialRoutingStore(directoryURL: directory.appendingPathComponent("routing"))

        token = HandoffToken.generate()
        port = 0

        server =
            HandoffTransportServer(
                port: port,
                store: store,
                reviewStore: reviewStore,
                routingStore: routingStore,
                token: token,
                onRoutingResponse: { [weak self] _ in self?.routingResponseCount += 1 },
                onRoutingAttention: { [weak self] _ in self?.routingAttentionCount += 1 }
            )

        XCTAssertTrue(server.start())
        port = try await server.waitUntilReady()

        socket =
            URLSession.shared
                .webSocketTask(
                    with: URL(
                        string:
                            "ws://127.0.0.1:\(port!)"
                    )!
                )

        socket.resume()
    }

    override func tearDown() async throws {
        socket?.cancel(
            with: .goingAway,
            reason: nil
        )

        server?.stop()
        try? await server?.waitUntilStopped()

        try? FileManager.default
            .removeItem(
                at: directory
            )

        try await super.tearDown()
    }

    func testUnauthenticatedNextCannotReadHandoff()
        throws
    {
        let handoff =
            sampleHandoff(
                finishedAt: 1
            )

        try store.persist(handoff)

        let hello =
            try receiveEvent()

        XCTAssertEqual(
            hello.type,
            .hello
        )

        try send(
            .next()
        )

        try send(
            .auth(token: token)
        )

        let firstPostAuth =
            try receiveEvent()

        XCTAssertEqual(
            firstPostAuth.type,
            .ready
        )

        try send(
            .next()
        )

        let event =
            try receiveEvent()

        XCTAssertEqual(
            event.type,
            .handoff
        )

        XCTAssertEqual(
            event.runId,
            handoff.runId
        )
    }

    func testAuthenticatedClientPullsOldestAndMarksDelivered()
        throws
    {
        let first =
            sampleHandoff(
                runId:
                    "00000000-0000-0000-0000-0000000000A1",
                finishedAt: 1
            )

        let second =
            sampleHandoff(
                runId:
                    "00000000-0000-0000-0000-0000000000B2",
                finishedAt: 2
            )

        try store.persist(first)
        try store.persist(second)

        _ = try receiveEvent()

        try send(
            .auth(token: token)
        )

        XCTAssertEqual(
            try receiveEvent().type,
            .ready
        )

        try send(
            .next()
        )

        let handoffEvent =
            try receiveEvent()

        XCTAssertEqual(
            handoffEvent.type,
            .handoff
        )

        XCTAssertEqual(
            handoffEvent.runId,
            first.runId
        )

        try send(
            .delivered(
                runId: first.runId
            )
        )

        let ack =
            try receiveEvent()

        XCTAssertEqual(
            ack.type,
            .deliveredAck
        )

        XCTAssertEqual(
            ack.runId,
            first.runId
        )

        XCTAssertNil(
            store.handoff(
                runId: first.runId
            )
        )

        XCTAssertNotNil(
            store.deliveredHandoff(
                runId: first.runId
            )
        )

        try send(
            .next()
        )

        let secondEvent =
            try receiveEvent()

        XCTAssertEqual(
            secondEvent.runId,
            second.runId
        )
    }

    func testBlockedHandoffDoesNotStarveNewerPendingHandoff() throws {
        let blocked = sampleHandoff(finishedAt: 1)
        let newer = sampleHandoff(finishedAt: 2)
        try store.persist(blocked)
        try store.persist(newer)

        _ = try receiveEvent()
        try send(.auth(token: token))
        XCTAssertEqual(try receiveEvent().type, .ready)
        try send(.next())
        XCTAssertEqual(try receiveEvent().runId, blocked.runId)

        // The browser keeps its terminal ambiguity evidence; this merely releases this
        // connection's queue slot so a separate safe run remains deliverable.
        try send(.blocked(runId: blocked.runId))
        try send(.next())
        XCTAssertEqual(try receiveEvent().runId, newer.runId)
        XCTAssertEqual(store.handoff(runId: blocked.runId), blocked)
        XCTAssertEqual(store.handoff(runId: newer.runId), newer)
    }

    func testMismatchedDeliveryCannotMoveAnotherRun()
        throws
    {
        let first =
            sampleHandoff(
                runId:
                    "00000000-0000-0000-0000-0000000000A1",
                finishedAt: 1
            )

        let second =
            sampleHandoff(
                runId:
                    "00000000-0000-0000-0000-0000000000B2",
                finishedAt: 2
            )

        try store.persist(first)
        try store.persist(second)

        _ = try receiveEvent()

        try send(
            .auth(token: token)
        )

        _ = try receiveEvent()

        try send(
            .next()
        )

        XCTAssertEqual(
            try receiveEvent().runId,
            first.runId
        )

        try send(
            .delivered(
                runId: second.runId
            )
        )

        let error =
            try receiveEvent()

        XCTAssertEqual(
            error.type,
            .error
        )

        XCTAssertEqual(
            error.error,
            "run_mismatch"
        )

        XCTAssertNotNil(
            store.handoff(
                runId: first.runId
            )
        )

        XCTAssertNotNil(
            store.handoff(
                runId: second.runId
            )
        )
    }

    func testWrongTokenReturnsExplicitAuthenticationFailure()
        throws
    {
        let handoff =
            sampleHandoff(
                finishedAt: 1
            )

        try store.persist(handoff)

        XCTAssertEqual(
            try receiveEvent().type,
            .hello
        )

        try send(
            .auth(token: "definitely-wrong-token")
        )

        let error =
            try receiveEvent()

        XCTAssertEqual(
            error.type,
            .error
        )

        XCTAssertEqual(
            error.error,
            "authentication_failed"
        )

        // Prove authentication failure did not expose the outbox.
        XCTAssertNotNil(
            store.handoff(
                runId: handoff.runId
            )
        )

        // The same connection may authenticate correctly afterward.
        try send(
            .auth(token: token)
        )

        XCTAssertEqual(
            try receiveEvent().type,
            .ready
        )

        try send(
            .next()
        )

        XCTAssertEqual(
            try receiveEvent().runId,
            handoff.runId
        )
    }

    func testWebSocketProtocolPingLeavesAuthenticatedConnectionUsable()
        throws
    {
        _ = try receiveEvent()

        try send(
            .auth(token: token)
        )

        XCTAssertEqual(
            try receiveEvent().type,
            .ready
        )

        // Send a genuine RFC WebSocket PING. Do not await the client-side
        // PONG callback: a minimal Network.framework hello/auth/ready fixture
        // reproduces delayed PONG observation despite immediate server send
        // completion, independently of Aiflow. Aiflow's heartbeat is the
        // typed application ping/pong below and has deterministic coverage.
        socket.sendPing { _ in }

        // A control PING must not close or corrupt the authenticated channel.
        try send(
            .ping()
        )

        XCTAssertEqual(
            try receiveEvent().type,
            .pong
        )
    }

    func testPingDoesNotTouchOutbox()
        throws
    {
        let handoff =
            sampleHandoff(
                finishedAt: 1
            )

        try store.persist(handoff)

        _ = try receiveEvent()

        try send(
            .auth(token: token)
        )

        _ = try receiveEvent()

        try send(
            .ping()
        )

        let pong =
            try receiveEvent()

        XCTAssertEqual(
            pong.type,
            .pong
        )

        XCTAssertNotNil(
            store.handoff(
                runId: handoff.runId
            )
        )
    }

    func testAuthenticatedReviewPersistsOnlyAfterDeliveredHandoff() throws {
        let handoff = sampleHandoff(finishedAt: 1)
        try store.persist(handoff)
        _ = try receiveEvent()
        try send(.auth(token: token))
        _ = try receiveEvent()
        try send(.next())
        _ = try receiveEvent()
        try send(.delivered(runId: handoff.runId))
        _ = try receiveEvent()
        try send(.review(runId: handoff.runId, conversationId: handoff.sourceChat.conversationId, assistantMessage: "Review complete."))
        XCTAssertEqual(try receiveEvent().type, .reviewAck)
        XCTAssertEqual(reviewStore.review(runId: handoff.runId)?.assistantMessage, "Review complete.")

        try send(.review(runId: handoff.runId, conversationId: handoff.sourceChat.conversationId, assistantMessage: "Review complete."))
        XCTAssertEqual(try receiveEvent().type, .reviewAck)
    }

    func testUnauthenticatedReviewCannotPersist() throws {
        let handoff = sampleHandoff(finishedAt: 1)
        try store.persist(handoff)
        _ = try receiveEvent()
        try send(.review(runId: handoff.runId, conversationId: handoff.sourceChat.conversationId, assistantMessage: "Review complete."))
        XCTAssertNil(reviewStore.review(runId: handoff.runId))
    }

    func testProtocolMismatchReturnsExplicitErrorWithoutAuthenticating() throws {
        let handoff = sampleHandoff(finishedAt: 1)
        try store.persist(handoff)
        XCTAssertEqual(try receiveEvent().type, .hello)

        try send(.auth(token: token, protocolVersion: 1))

        let error = try receiveEvent()
        XCTAssertEqual(error.type, .error)
        XCTAssertEqual(error.error, "protocol_incompatible")

        try send(.next())
        XCTAssertNil(reviewStore.review(runId: handoff.runId))
    }

    func testMalformedExistingReviewReturnsConflictWithoutOverwrite() throws {
        let handoff = sampleHandoff(finishedAt: 1)
        try store.persist(handoff)
        let reviewURL = reviewStore.directoryURL.appendingPathComponent("\(handoff.runId).json")
        let malformed = Data("not valid JSON".utf8)
        try FileManager.default.createDirectory(
            at: reviewStore.directoryURL,
            withIntermediateDirectories: true
        )
        try malformed.write(to: reviewURL)

        _ = try receiveEvent()
        try send(.auth(token: token))
        _ = try receiveEvent()
        try send(.next())
        _ = try receiveEvent()
        try send(.delivered(runId: handoff.runId))
        _ = try receiveEvent()
        try send(.review(runId: handoff.runId, conversationId: handoff.sourceChat.conversationId, assistantMessage: "Review complete."))

        let error = try receiveEvent()
        XCTAssertEqual(error.type, .error)
        XCTAssertEqual(error.error, "review_conflict")
        XCTAssertEqual(try Data(contentsOf: reviewURL), malformed)
    }

    func testConflictingAndOversizedReviewsFailClosed() throws {
        let handoff = sampleHandoff(finishedAt: 1)
        try store.persist(handoff)
        _ = try receiveEvent(); try send(.auth(token: token)); _ = try receiveEvent(); try send(.next()); _ = try receiveEvent(); try send(.delivered(runId: handoff.runId)); _ = try receiveEvent()
        try send(.review(runId: handoff.runId, conversationId: handoff.sourceChat.conversationId, assistantMessage: "first")); _ = try receiveEvent()
        try send(.review(runId: handoff.runId, conversationId: handoff.sourceChat.conversationId, assistantMessage: "second"))
        XCTAssertEqual(try receiveEvent().error, "review_conflict")
        try send(.review(runId: handoff.runId, conversationId: handoff.sourceChat.conversationId, assistantMessage: String(repeating: "x", count: 33 * 1024)))
        XCTAssertEqual(try receiveEvent().error, "invalid_review")
    }

    func testRoutingFailureWinsBeforeResponseAndPermitsManualFallback() throws {
        let request = sampleRoutingRequest()
        try routingStore.persist(request)
        try authenticate()
        try send(.nextRouting())
        XCTAssertEqual(try receiveEvent().type, .routing)
        try send(.routingDelivered(runId: request.runId))
        XCTAssertEqual(try receiveEvent().type, .routingDeliveredAck)

        try send(.routingFailed(runId: request.runId))
        XCTAssertEqual(try receiveEvent().type, .routingResponseAck)
        XCTAssertEqual(try routingStore.record(runId: request.runId)?.state, .manualAttention)
        XCTAssertEqual(try routingStore.record(runId: request.runId)?.manualFallbackAvailable, true)
        XCTAssertEqual(routingAttentionCount, 1)

        try send(.routingResponse(
            runId: request.runId,
            conversationId: request.sourceChat.conversationId,
            assistantMessage: "# Codex Routing\n## Model\nsol\n## Reasoning\nhigh"
        ))
        XCTAssertEqual(try receiveEvent().error, "routing_conflict")
        XCTAssertEqual(routingResponseCount, 0)
    }

    func testLateRoutingFailureCannotReplaceResponseOrExecutionEvidence() throws {
        let request = sampleRoutingRequest()
        try routingStore.persist(request)
        try authenticate()
        try send(.nextRouting())
        _ = try receiveEvent()
        try send(.routingDelivered(runId: request.runId))
        _ = try receiveEvent()
        let response = "# Codex Routing\n## Model\nsol\n## Reasoning\nhigh"
        try send(.routingResponse(runId: request.runId, conversationId: request.sourceChat.conversationId, assistantMessage: response))
        XCTAssertEqual(try receiveEvent().type, .routingResponseAck)
        XCTAssertEqual(routingResponseCount, 1)

        try send(.routingFailed(runId: request.runId))
        XCTAssertEqual(try receiveEvent().type, .routingResponseAck)
        XCTAssertEqual(try routingStore.record(runId: request.runId)?.state, .completed)
        XCTAssertEqual(try routingStore.record(runId: request.runId)?.assistantMessage, response)
        XCTAssertNotEqual(try routingStore.record(runId: request.runId)?.manualFallbackAvailable, true)
        XCTAssertEqual(routingAttentionCount, 0)

        _ = try routingStore.beginExecution(runId: request.runId)
        try send(.routingFailed(runId: request.runId))
        XCTAssertEqual(try receiveEvent().type, .routingResponseAck)
        XCTAssertEqual(try routingStore.record(runId: request.runId)?.state, .starting)
        XCTAssertNotEqual(try routingStore.record(runId: request.runId)?.manualFallbackAvailable, true)

        try routingStore.markStarted(runId: request.runId)
        try send(.routingFailed(runId: request.runId))
        XCTAssertEqual(try receiveEvent().type, .routingResponseAck)
        XCTAssertEqual(try routingStore.record(runId: request.runId)?.state, .started)
        XCTAssertNotEqual(try routingStore.record(runId: request.runId)?.manualFallbackAvailable, true)

        _ = try routingStore.reconcileAfterRestart()
        try send(.routingFailed(runId: request.runId))
        XCTAssertEqual(try receiveEvent().type, .routingResponseAck)
        XCTAssertEqual(try routingStore.record(runId: request.runId)?.state, .manualAttention)
        XCTAssertEqual(try routingStore.record(runId: request.runId)?.manualFallbackAvailable, false)
    }

    private func authenticate() throws {
        _ = try receiveEvent()
        try send(.auth(token: token))
        XCTAssertEqual(try receiveEvent().type, .ready)
    }

    private func sampleRoutingRequest() -> CodexInitialRoutingRequest {
        .init(
            schemaVersion: 1,
            runId: UUID().uuidString,
            project: .init(id: UUID(), name: "demo", path: "/repos/demo"),
            sourceChat: .init(url: "https://chatgpt.com/c/chat-one", conversationId: "chat-one"),
            prompt: "Fix it",
            manualModelRole: "terra",
            manualModelId: "gpt-5.6-terra",
            manualEffort: "medium",
            assistantMessage: nil,
            state: .pending,
            createdAt: Date(),
            updatedAt: Date(),
            terminalReason: nil
        )
    }

    private func send(
        _ command: HandoffClientCommand
    ) throws {
        let data =
            try XCTUnwrap(
                HandoffTransportCodec
                    .encodeClientCommand(
                        command
                    )
            )

        let text =
            try XCTUnwrap(
                String(
                    data: data,
                    encoding: .utf8
                )
            )

        let expectation =
            XCTestExpectation(
                description:
                    "websocket send"
            )

        var sendError: Error?

        socket.send(
            .string(text)
        ) {
            error in

            sendError = error
            expectation.fulfill()
        }

        let result =
            XCTWaiter.wait(
                for: [expectation],
                timeout: 3
            )

        guard result == .completed else {
            throw TestError.timeout
        }

        if let sendError {
            throw sendError
        }
    }

    private func receiveEvent()
        throws -> HandoffServerEvent
    {
        let expectation =
            XCTestExpectation(
                description:
                    "websocket receive"
            )

        var received:
            Result<
                URLSessionWebSocketTask.Message,
                Error
            >?

        socket.receive {
            result in

            received = result
            expectation.fulfill()
        }

        let wait =
            XCTWaiter.wait(
                for: [expectation],
                timeout: 3
            )

        guard wait == .completed else {
            throw TestError.timeout
        }

        let message =
            try XCTUnwrap(received).get()

        let data: Data

        switch message {
        case .string(let text):
            data = Data(text.utf8)

        case .data(let binary):
            data = binary

        @unknown default:
            throw TestError.invalidMessage
        }

        return try XCTUnwrap(
            HandoffTransportCodec
                .decodeServerEvent(data)
        )
    }

    private func sampleHandoff(
        runId: String =
            UUID().uuidString,
        finishedAt: TimeInterval
    ) -> RunResultHandoff {
        RunResultHandoff(
            runId: runId,
            outcome: .completed,
            project: .init(
                id: UUID(
                    uuidString:
                        "D0D5A8B1-8FF3-4B7F-A4E2-3ADF8D5D5BD1"
                )!,
                name: "demo",
                path: "/repos/demo"
            ),
            sourceChat: .init(
                url:
                    "https://chatgpt.com/c/chat-one",
                conversationId:
                    "chat-one"
            ),
            execution: .init(
                worker:
                    "official-vscode",
                modelRole: "sol",
                modelId: "gpt-5.6-sol",
                effort: "low",
                codexConversationId:
                    "codex-conversation",
                codexTurnId:
                    "codex-turn"
            ),
            result: .init(
                finalMessage: "done",
                errorMessage: nil
            ),
            startedAt:
                Date(
                    timeIntervalSince1970:
                        1_700_000_000
                ),
            finishedAt:
                Date(
                    timeIntervalSince1970:
                        finishedAt
                )
        )
    }

    private enum TestError: Error {
        case timeout
        case invalidMessage
    }
}
