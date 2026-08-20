import Foundation

enum HandoffTransport {
    static let protocolVersion = 1
    static let maximumInboundMessageBytes = 64 * 1024
}

enum HandoffClientCommandType: String, Codable, Equatable {
    case auth
    case next
    case delivered
    case ping
}

struct HandoffClientCommand: Codable, Equatable {
    let type: HandoffClientCommandType
    var token: String?
    var runId: String?

    static func auth(token: String) -> HandoffClientCommand {
        HandoffClientCommand(
            type: .auth,
            token: token,
            runId: nil
        )
    }

    static func next() -> HandoffClientCommand {
        HandoffClientCommand(
            type: .next,
            token: nil,
            runId: nil
        )
    }

    static func delivered(
        runId: String
    ) -> HandoffClientCommand {
        HandoffClientCommand(
            type: .delivered,
            token: nil,
            runId: runId
        )
    }

    static func ping() -> HandoffClientCommand {
        HandoffClientCommand(
            type: .ping,
            token: nil,
            runId: nil
        )
    }
}

enum HandoffServerEventType: String, Codable, Equatable {
    case hello
    case ready
    case pong
    case handoff
    case empty
    case deliveredAck = "delivered_ack"
    case error
}

struct HandoffServerEvent: Codable, Equatable {
    let type: HandoffServerEventType
    var protocolVersion: Int?
    var handoff: RunResultHandoff?
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
