import XCTest

@testable import AiflowMenuBar

final class HandoffTransportProtocolTests: XCTestCase {
    func testCurrentProtocolVersionIsThree() {
        XCTAssertEqual(HandoffTransport.protocolVersion, 3)
    }

    func testAuthCommandRoundTrips() throws {
        let original =
            HandoffClientCommand.auth(
                token: "test-token"
            )

        let data =
            try XCTUnwrap(
                HandoffTransportCodec
                    .encodeClientCommand(
                        original
                    )
            )

        XCTAssertEqual(
            HandoffTransportCodec
                .decodeClientCommand(data),
            original
        )
    }

    func testUnknownCommandIsRejected() {
        let data =
            Data(
                #"{"type":"launch_shell"}"#
                    .utf8
            )

        XCTAssertNil(
            HandoffTransportCodec
                .decodeClientCommand(data)
        )
    }

    func testHelloCarriesOnlyProtocolVersion() throws {
        let data =
            try XCTUnwrap(
                HandoffTransportCodec
                    .encodeServerEvent(
                        .hello()
                    )
            )

        let text =
            try XCTUnwrap(
                String(
                    data: data,
                    encoding: .utf8
                )
            )

        XCTAssertTrue(
            text.contains(
                #""protocolVersion":3"#
            )
        )

        XCTAssertFalse(
            text.contains("token")
        )

        XCTAssertFalse(
            text.contains("handoff")
        )
    }

    func testHandoffEventRoundTrips() throws {
        let handoff = sampleHandoff()

        let original =
            HandoffServerEvent.handoff(
                handoff
            )

        let data =
            try XCTUnwrap(
                HandoffTransportCodec
                    .encodeServerEvent(
                        original
                    )
            )

        XCTAssertEqual(
            HandoffTransportCodec
                .decodeServerEvent(data),
            original
        )
    }

    func testDeliveredAckNamesExactRun() {
        let runId =
            UUID().uuidString

        let event =
            HandoffServerEvent
                .deliveredAck(
                    runId: runId
                )

        XCTAssertEqual(
            event.type,
            .deliveredAck
        )

        XCTAssertEqual(
            event.runId,
            runId
        )
    }

    func testBlockedCommandRoundTrips() throws {
        let command = HandoffClientCommand.blocked(runId: UUID().uuidString)
        XCTAssertEqual(HandoffTransportCodec.decodeClientCommand(try XCTUnwrap(HandoffTransportCodec.encodeClientCommand(command))), command)
    }

    func testReviewCommandAndAcknowledgementRoundTrip() throws {
        let command = HandoffClientCommand.review(runId: UUID().uuidString, conversationId: "chat-one", assistantMessage: "Review complete.")
        let data = try XCTUnwrap(HandoffTransportCodec.encodeClientCommand(command))
        XCTAssertEqual(HandoffTransportCodec.decodeClientCommand(data), command)
        XCTAssertEqual(HandoffServerEvent.reviewAck(runId: command.runId!).type, .reviewAck)
    }

    func testRoutingCommandAndEventRoundTrip() throws {
        let request = CodexInitialRoutingRequest(
            schemaVersion: 1, runId: UUID().uuidString,
            project: .init(id: UUID(), name: "demo", path: "/repos/demo"),
            sourceChat: .init(url: "https://chatgpt.com/c/chat", conversationId: "chat"),
            prompt: "Fix it", manualModelRole: "terra", manualModelId: "gpt-5.6-terra",
            manualEffort: "medium", assistantMessage: nil, state: .pending,
            createdAt: Date(), updatedAt: Date(), terminalReason: nil
        )
        let command = HandoffClientCommand.routingResponse(
            runId: request.runId, conversationId: "chat", assistantMessage: "# Codex Routing\n## Model\nsol\n## Reasoning\nhigh"
        )
        XCTAssertEqual(HandoffTransportCodec.decodeClientCommand(try XCTUnwrap(HandoffTransportCodec.encodeClientCommand(command))), command)
        let decoded = HandoffTransportCodec.decodeServerEvent(
            try XCTUnwrap(HandoffTransportCodec.encodeServerEvent(.routing(request)))
        )?.routing
        XCTAssertEqual(decoded?.runId, request.runId)
        XCTAssertEqual(decoded?.sourceChat, request.sourceChat)
        XCTAssertEqual(decoded?.manualModelRole, request.manualModelRole)
    }

    private func sampleHandoff()
        -> RunResultHandoff
    {
        RunResultHandoff(
            runId: UUID().uuidString,
            outcome: .completed,
            project: .init(
                id: UUID(),
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
                        1_700_000_010
                )
        )
    }
}
