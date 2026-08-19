import Foundation

/// Wire types for the local Aiflow ↔ VS Code bridge.
///
/// The companion is a view/control surface, never a Codex client. That asymmetry is encoded
/// in these types on purpose: events carry rich state outward, while inbound commands carry
/// only a verb, an optional request id, and answers. There is deliberately no field for a
/// repository path, sandbox value, model id, prompt, or shell command, so a compromised or
/// buggy client cannot introduce one.
enum BridgeEventType: String, Codable {
    case hello
    case snapshot
    case runStarted = "run_started"
    case runStatus = "run_status"
    case agentMessage = "agent_message"
    case approvalRequested = "approval_requested"
    case questionRequested = "question_requested"
    case runCompleted = "run_completed"
    case runFailed = "run_failed"
    case runCancelled = "run_cancelled"
    /// Reserved for the file-following spike.
    case fileOpen = "file_open"
    case fileChanged = "file_changed"
}

enum BridgeCommandType: String, Codable {
    /// Must succeed before any other command is honoured or any run state is sent.
    case auth
    case ping
    case cancel
    case approve
    case deny
    case answerQuestion = "answer_question"
}

/// Mirrors `ToolRequestUserInputOption`.
struct BridgeOption: Codable, Equatable {
    let label: String
    let description: String
}

/// Mirrors `ToolRequestUserInputQuestion`. The whole question set is sent so a client can
/// render every question, not just the first.
struct BridgeQuestion: Codable, Equatable {
    let id: String
    let header: String
    let question: String
    let options: [BridgeOption]
    let isOther: Bool
    let isSecret: Bool

    init(_ item: QuestionItem) {
        id = item.id
        header = item.header
        question = item.question
        options = item.options.map { BridgeOption(label: $0.label, description: $0.description) }
        isOther = item.isOther
        isSecret = item.isSecret
    }

    init(
        id: String, header: String, question: String, options: [BridgeOption], isOther: Bool,
        isSecret: Bool
    ) {
        self.id = id
        self.header = header
        self.question = question
        self.options = options
        self.isOther = isOther
        self.isSecret = isSecret
    }
}

/// Aiflow → VS Code. One flat shape keeps the JSON easy to consume from TypeScript; every
/// field beyond `type` is optional and only populated when it applies.
struct BridgeEvent: Codable, Equatable {
    let type: BridgeEventType

    var protocolVersion: Int?
    var connected: Bool?
    var runState: String?
    var project: String?
    var model: String?
    var effort: String?
    var message: String?
    var promptPreview: String?
    var requestId: CodexRequestID?
    var kind: String?
    var summary: String?
    var detail: String?
    var questions: [BridgeQuestion]?
    var path: String?

    init(type: BridgeEventType) {
        self.type = type
    }
}

/// VS Code → Aiflow. Intentionally minimal; see the note on `BridgeEventType`.
struct BridgeCommand: Codable, Equatable {
    let type: BridgeCommandType
    var requestId: CodexRequestID?
    var answers: [String: String]?
    /// Only ever read from an `auth` command. Never echoed back and never logged.
    var token: String?

    init(
        type: BridgeCommandType, requestId: CodexRequestID? = nil,
        answers: [String: String]? = nil, token: String? = nil
    ) {
        self.type = type
        self.requestId = requestId
        self.answers = answers
        self.token = token
    }
}

/// A JSON-RPC request id is either an integer or a string; both must survive a round trip so
/// an approval can be correlated exactly.
extension CodexRequestID: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .integer(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container, debugDescription: "request id must be an integer or a string")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .integer(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }
}

/// Accumulates bridge bytes into newline-delimited lines with a hard ceiling.
///
/// Deliberately separate from the `LineBuffer` used for the Codex App Server: Codex frames
/// carry whole agent messages and diffs, while bridge commands are tiny. A local client that
/// streams megabytes without a newline is misbehaving, so the connection is dropped rather
/// than buffered indefinitely.
final class BoundedLineBuffer {
    /// Bridge commands are verbs plus short answers; 64 KiB is far more than any legitimate one.
    static let maxFrameBytes = 64 * 1024

    private var pending = Data()
    private let limit: Int
    private(set) var didOverflow = false

    init(limit: Int = BoundedLineBuffer.maxFrameBytes) {
        self.limit = limit
    }

    /// Returns completed lines, or nil once the limit is exceeded — the caller must then
    /// close the connection.
    func append(_ data: Data) -> [String]? {
        guard !didOverflow else { return nil }

        pending.append(data)

        var lines: [String] = []
        while let newlineIndex = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = pending[pending.startIndex..<newlineIndex]
            pending = pending[pending.index(after: newlineIndex)...]

            // A frame that arrives already terminated must be measured too — checking only
            // the trailing remainder would let an oversized complete frame straight through.
            if lineData.count > limit { return reject() }

            let line = String(decoding: lineData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { lines.append(line) }
        }

        // Whatever is left has no newline yet; if it is already over the limit it never will be.
        if pending.count > limit { return reject() }

        return lines
    }

    /// Drops everything buffered and refuses the rest of the stream. No frames are returned
    /// from the offending append, even ones parsed before the oversized frame.
    private func reject() -> [String]? {
        didOverflow = true
        pending = Data()
        return nil
    }
}

/// Newline-delimited JSON framing. Decoding never throws to the caller: a malformed or
/// unrecognized line is simply not a command.
enum BridgeCodec {
    static let protocolVersion = 1

    static func encode(_ event: BridgeEvent) -> Data? {
        guard var data = try? JSONEncoder().encode(event) else { return nil }
        data.append(UInt8(ascii: "\n"))
        return data
    }

    static func encodeLine(_ event: BridgeEvent) -> String? {
        guard let data = encode(event) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Returns nil for blank lines, malformed JSON, and unrecognized command types.
    static func decodeCommand(_ line: String) -> BridgeCommand? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return try? JSONDecoder().decode(BridgeCommand.self, from: Data(trimmed.utf8))
    }

    static func decodeEvent(_ line: String) -> BridgeEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return try? JSONDecoder().decode(BridgeEvent.self, from: Data(trimmed.utf8))
    }
}

/// Builders keep event construction in one place so the shapes stay consistent.
extension BridgeEvent {
    static func hello() -> BridgeEvent {
        var event = BridgeEvent(type: .hello)
        event.protocolVersion = BridgeCodec.protocolVersion
        event.connected = true
        return event
    }

    static func runStatus(_ state: String) -> BridgeEvent {
        var event = BridgeEvent(type: .runStatus)
        event.runState = state
        return event
    }

    static func agentMessage(_ text: String) -> BridgeEvent {
        var event = BridgeEvent(type: .agentMessage)
        event.message = text
        return event
    }

    static func approvalRequested(_ request: ApprovalRequest) -> BridgeEvent {
        var event = BridgeEvent(type: .approvalRequested)
        event.requestId = request.id
        event.kind = request.kind.wireName
        event.summary = request.summary
        event.detail = request.detail
        event.project = request.projectName
        return event
    }

    static func questionRequested(_ request: UserQuestion) -> BridgeEvent {
        var event = BridgeEvent(type: .questionRequested)
        event.requestId = request.id
        event.questions = request.questions.map(BridgeQuestion.init)
        event.project = request.projectName
        return event
    }

    static func fileOpen(path: String) -> BridgeEvent {
        var event = BridgeEvent(type: .fileOpen)
        event.path = path
        return event
    }
}

extension ApprovalRequest.Kind {
    var wireName: String {
        switch self {
        case .commandExecution: return "command_execution"
        case .fileChange: return "file_change"
        case .permissions: return "permissions"
        }
    }
}

/// Stable, client-facing names for the run state. Kept separate from `RunState.statusText`,
/// which is human display text and free to change.
extension RunState {
    var bridgeName: String {
        switch self {
        case .ready: return "ready"
        case .confirming: return "confirming"
        case .launching: return "launching"
        case .running: return "running"
        case .waitingForApproval: return "waiting_for_approval"
        case .waitingForInput: return "waiting_for_input"
        case .respondingToRequest: return "responding"
        case .cancelling: return "cancelling"
        case .completed: return "completed"
        case .cancelled: return "cancelled"
        case .failed: return "failed"
        }
    }
}
