import XCTest

@testable import AiflowMenuBar

final class HandoffTransportProtocolTests: XCTestCase {
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
                #""protocolVersion":1"#
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
