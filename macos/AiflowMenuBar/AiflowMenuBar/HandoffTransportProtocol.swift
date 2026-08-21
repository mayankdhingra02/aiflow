import Foundation

enum HandoffTransport {
    static let protocolVersion = 3
    static let maximumInboundMessageBytes = 64 * 1024
}

enum HandoffClientCommandType: String, Codable, Equatable {
    case auth
    case next
    case delivered
    case review
    case ping
    case nextRouting = "next_routing"
    case routingDelivered = "routing_delivered"
    case routingResponse = "routing_response"
    case routingFailed = "routing_failed"
}

struct HandoffClientCommand: Codable, Equatable {
    let type: HandoffClientCommandType
    var token: String?
    var runId: String?
    var protocolVersion: Int?
    var conversationId: String?
    var assistantMessage: String?

    static func auth(token: String, protocolVersion: Int = HandoffTransport.protocolVersion) -> HandoffClientCommand {
        HandoffClientCommand(
            type: .auth,
            token: token,
            runId: nil,
            protocolVersion: protocolVersion,
            conversationId: nil,
            assistantMessage: nil
        )
    }

    static func next() -> HandoffClientCommand {
        HandoffClientCommand(
            type: .next,
            token: nil,
            runId: nil, protocolVersion: nil, conversationId: nil, assistantMessage: nil
        )
    }

    static func delivered(
        runId: String
    ) -> HandoffClientCommand {
        HandoffClientCommand(
            type: .delivered,
            token: nil,
            runId: runId, protocolVersion: nil, conversationId: nil, assistantMessage: nil
        )
    }

    static func review(runId: String, conversationId: String, assistantMessage: String) -> HandoffClientCommand {
        HandoffClientCommand(type: .review, token: nil, runId: runId, protocolVersion: nil, conversationId: conversationId, assistantMessage: assistantMessage)
    }

    static func ping() -> HandoffClientCommand {
        HandoffClientCommand(
            type: .ping,
            token: nil,
            runId: nil, protocolVersion: nil, conversationId: nil, assistantMessage: nil
        )
    }

    static func nextRouting() -> HandoffClientCommand { HandoffClientCommand(type: .nextRouting, token: nil, runId: nil, protocolVersion: nil, conversationId: nil, assistantMessage: nil) }
    static func routingDelivered(runId: String) -> HandoffClientCommand { HandoffClientCommand(type: .routingDelivered, token: nil, runId: runId, protocolVersion: nil, conversationId: nil, assistantMessage: nil) }
    static func routingResponse(runId: String, conversationId: String, assistantMessage: String) -> HandoffClientCommand { HandoffClientCommand(type: .routingResponse, token: nil, runId: runId, protocolVersion: nil, conversationId: conversationId, assistantMessage: assistantMessage) }
    static func routingFailed(runId: String) -> HandoffClientCommand { HandoffClientCommand(type: .routingFailed, token: nil, runId: runId, protocolVersion: nil, conversationId: nil, assistantMessage: nil) }
}

enum HandoffServerEventType: String, Codable, Equatable {
    case hello
    case ready
    case pong
    case handoff
    case empty
    case deliveredAck = "delivered_ack"
    case reviewAck = "review_ack"
    case error
    case routing
    case routingEmpty = "routing_empty"
    case routingDeliveredAck = "routing_delivered_ack"
    case routingResponseAck = "routing_response_ack"
}

struct HandoffServerEvent: Codable, Equatable {
    let type: HandoffServerEventType
    var protocolVersion: Int?
    var handoff: RunResultHandoff?
    var routing: CodexInitialRoutingRequest?
    var runId: String?
    var error: String?

    static func hello() -> HandoffServerEvent {
        HandoffServerEvent(
            type: .hello,
            protocolVersion: HandoffTransport.protocolVersion
        )
    }

    static func ready() -> HandoffServerEvent {
        HandoffServerEvent(type: .ready)
    }

    static func pong() -> HandoffServerEvent {
        HandoffServerEvent(type: .pong)
    }

    static func handoff(
        _ handoff: RunResultHandoff
    ) -> HandoffServerEvent {
        HandoffServerEvent(
            type: .handoff,
            handoff: handoff,
            runId: handoff.runId
        )
    }

    static func empty() -> HandoffServerEvent {
        HandoffServerEvent(type: .empty)
    }

    static func deliveredAck(
        runId: String
    ) -> HandoffServerEvent {
        HandoffServerEvent(
            type: .deliveredAck,
            runId: runId
        )
    }

    static func reviewAck(runId: String) -> HandoffServerEvent {
        HandoffServerEvent(type: .reviewAck, runId: runId)
    }

    static func routing(_ request: CodexInitialRoutingRequest) -> HandoffServerEvent { HandoffServerEvent(type: .routing, routing: request, runId: request.runId) }
    static func routingEmpty() -> HandoffServerEvent { HandoffServerEvent(type: .routingEmpty) }
    static func routingDeliveredAck(runId: String) -> HandoffServerEvent { HandoffServerEvent(type: .routingDeliveredAck, runId: runId) }
    static func routingResponseAck(runId: String) -> HandoffServerEvent { HandoffServerEvent(type: .routingResponseAck, runId: runId) }

    static func error(
        _ code: String,
        runId: String? = nil
    ) -> HandoffServerEvent {
        HandoffServerEvent(
            type: .error,
            runId: runId,
            error: code
        )
    }
}

enum HandoffTransportCodec {
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func encodeServerEvent(
        _ event: HandoffServerEvent
    ) -> Data? {
        try? encoder().encode(event)
    }

    static func decodeServerEvent(
        _ data: Data
    ) -> HandoffServerEvent? {
        try? decoder().decode(
            HandoffServerEvent.self,
            from: data
        )
    }

    static func encodeClientCommand(
        _ command: HandoffClientCommand
    ) -> Data? {
        try? encoder().encode(command)
    }

    static func decodeClientCommand(
        _ data: Data
    ) -> HandoffClientCommand? {
        try? decoder().decode(
            HandoffClientCommand.self,
            from: data
        )
    }
}
