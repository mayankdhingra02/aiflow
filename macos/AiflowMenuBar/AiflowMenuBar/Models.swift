import Foundation

/// A repository the user saved as a one-click run target. `path` is always the Git root.
struct SavedProject: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var path: String
    var createdAt: Date

    init(id: UUID = UUID(), name: String, path: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.path = path
        self.createdAt = createdAt
    }

    /// Default display name is the folder basename of the Git root.
    static func defaultName(for path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    var exists: Bool {
        var isDirectory: ObjCBool = false
        let found = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return found && isDirectory.boolValue
    }
}

/// Model roles and reasoning efforts, loaded from `aiflow models --json` so the Python
/// constants stay the single source of truth for model IDs.
struct CodexModel: Codable, Identifiable, Equatable {
    let role: String
    let modelId: String

    var id: String { role }

    /// "terra" -> "Terra"
    var displayName: String { role.prefix(1).uppercased() + role.dropFirst() }

    enum CodingKeys: String, CodingKey {
        case role
        case modelId = "model_id"
    }
}

struct CodexConfig: Codable, Equatable {
    let models: [CodexModel]
    let reasoningEfforts: [String]
    let defaultSandbox: String

    enum CodingKeys: String, CodingKey {
        case models
        case reasoningEfforts = "reasoning_efforts"
        case defaultSandbox = "default_sandbox"
    }

    static let defaultModelRole = "terra"
    static let defaultReasoningEffort = "medium"

    func model(forRole role: String) -> CodexModel? {
        models.first { $0.role == role }
    }
}

/// "high" -> "High", "xhigh" -> "XHigh"
func displayNameForEffort(_ effort: String) -> String {
    effort == "xhigh" ? "XHigh" : effort.prefix(1).uppercased() + effort.dropFirst()
}

/// A permission request Codex raised mid-run. Answered manually by the user; Aiflow never
/// answers one on its own.
enum CodexRequestID: Hashable, Equatable {
    case integer(Int)
    case string(String)

    var jsonValue: Any { switch self { case .integer(let value): return value; case .string(let value): return value } }
    var notificationValue: String { switch self { case .integer(let value): return String(value); case .string(let value): return value } }
}

struct ApprovalRequest: Equatable, Identifiable {
    let id: CodexRequestID  // exact JSON-RPC request id to respond to
    let kind: Kind
    let summary: String
    let detail: String?
    let projectName: String
    /// The server's requested permission profile, encoded untouched for a turn-scoped reply.
    let permissionProfile: Data?

    enum Kind: Equatable {
        case commandExecution
        case fileChange
        case permissions

        var title: String {
            switch self {
            case .commandExecution: return "Codex wants to run a command"
            case .fileChange: return "Codex wants to change files"
            case .permissions: return "Codex needs extra permission"
            }
        }
    }

    /// Broad or destructive requests should make Deny the visually safer default.
    var prefersDeny: Bool {
        if kind == .permissions { return true }
        let text = (summary + " " + (detail ?? "")).lowercased()
        return ["rm -rf", "sudo", "curl", "npm publish", "git push", "--force", "danger"]
            .contains { text.contains($0) }
    }
}

/// A clarifying question Codex asked mid-run.
struct UserQuestion: Equatable, Identifiable {
    let id: CodexRequestID  // exact JSON-RPC request id to respond to
    let questionID: String  // exact tool question id required by the response payload
    let question: String
    let projectName: String
}

/// Current-run state only. Not history — nothing here is persisted.
enum RunState: Equatable {
    case ready
    case confirming(SavedProject)
    case launching(SavedProject)
    case running(SavedProject)
    case waitingForApproval(ApprovalRequest)
    case waitingForInput(UserQuestion)
    case completed(SavedProject)
    case failed(project: SavedProject?, message: String)

    /// The project a run is currently occupying, if any.
    var activeProject: SavedProject? {
        switch self {
        case .launching(let p), .running(let p), .completed(let p): return p
        case .failed(let project, _): return project
        default: return nil
        }
    }

    /// True once a run has started and has not yet finished — blocks starting a second run.
    var isBusy: Bool {
        switch self {
        case .launching, .running, .waitingForApproval, .waitingForInput: return true
        case .ready, .confirming, .completed, .failed: return false
        }
    }

    var statusText: String {
        switch self {
        case .ready: return "Ready"
        case .confirming: return "Awaiting confirmation"
        case .launching: return "Starting Codex…"
        case .running: return "Running Codex…"
        case .waitingForApproval: return "Waiting for your approval"
        case .waitingForInput: return "Codex asked a question"
        case .completed: return "✓ Codex finished"
        case .failed(_, let detail): return "✕ \(detail)"
        }
    }
}
