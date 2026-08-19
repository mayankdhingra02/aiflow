import Foundation

/// Events the run engine hands back to the UI layer.
enum CodexSessionEvent: Equatable {
    case started
    case approvalRequested(id: CodexRequestID, kind: ApprovalRequest.Kind, summary: String, detail: String?, permissionProfile: Data?)
    case inputRequested(id: CodexRequestID, questionID: String, question: String)
    case assistantMessage(String)
    case finished
    case failed(String)
}

/// Decodes one line of app-server JSON-RPC into something the UI understands.
///
/// Split out from the process plumbing so the protocol handling is unit testable without
/// spawning Codex. It is deliberately conservative: anything it does not recognise is
/// ignored rather than guessed at, and it never fabricates an approval decision.
enum CodexProtocol {
    /// Approval + input requests the server sends to us, as `ServerRequest` methods.
    static let commandApprovalMethod = "item/commandExecution/requestApproval"
    static let fileChangeApprovalMethod = "item/fileChange/requestApproval"
    static let permissionsApprovalMethod = "item/permissions/requestApproval"
    static let userInputMethod = "item/tool/requestUserInput"

    static func approvalKind(for method: String) -> ApprovalRequest.Kind? {
        switch method {
        case commandApprovalMethod: return .commandExecution
        case fileChangeApprovalMethod: return .fileChange
        case permissionsApprovalMethod: return .permissions
        default: return nil
        }
    }

    /// The JSON body of a decision. `"approved"` / `"denied"` are the protocol's
    /// ReviewDecision values; there is no implicit default — the caller must choose.
    static func approvalResponse(_ request: ApprovalRequest, allow: Bool) -> [String: Any]? {
        if request.kind == .permissions {
            let profile: Any
            if allow, let data = request.permissionProfile,
                let decoded = try? JSONSerialization.jsonObject(with: data) {
                profile = decoded
            } else {
                // The typed response represents denial as an empty granted profile.
                profile = [String: Any]()
            }
            return ["jsonrpc": "2.0", "id": request.id.jsonValue,
                    "result": ["permissions": profile, "scope": "turn"]]
        }
        return ["jsonrpc": "2.0", "id": request.id.jsonValue,
                "result": ["decision": allow ? "accept" : "decline"]]
    }

    static func userInputResponse(_ question: UserQuestion, answer: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": question.id.jsonValue,
         "result": ["answers": [question.questionID: ["answers": [answer]]]]]
    }

    /// The id of a JSON-RPC *response* to one of our requests, if this object is one.
    /// Responses carry `id` with `result`/`error` and no `method`.
    static func responseId(from object: [String: Any]) -> Int? {
        guard object["method"] == nil, let id = object["id"] as? Int else { return nil }
        guard object["result"] != nil || object["error"] != nil else { return nil }
        return id
    }

    /// Pulls the thread id out of a `thread/start` result. `turn/start` requires it.
    static func threadId(fromThreadStartResult object: [String: Any]) -> String? {
        guard let result = object["result"] as? [String: Any] else { return nil }
        if let thread = result["thread"] as? [String: Any], let id = thread["id"] as? String {
            return id
        }
        return result["threadId"] as? String
    }

    static func errorMessage(from object: [String: Any]) -> String? {
        guard let error = object["error"] as? [String: Any] else { return nil }
        return (error["message"] as? String) ?? "Codex rejected the request"
    }

    /// The sandbox this app always runs under. Never `danger-full-access`.
    static let sandbox = "workspace-write"

    /// Approvals are always routed to the user. Never `"never"`, and never the
    /// auto-approving reviewer — Aiflow does not answer permission requests on its own.
    static let approvalPolicy = "on-request"

    /// Pure payload builders, so the safety-critical session parameters are unit testable
    /// without spawning Codex.
    static func threadStartParams(repositoryPath: String, modelId: String) -> [String: Any] {
        [
            "cwd": repositoryPath,
            "model": modelId,
            "sandbox": sandbox,
            "approvalPolicy": approvalPolicy,
        ]
    }

    static func turnStartParams(
        threadId: String,
        repositoryPath: String,
        modelId: String,
        reasoningEffort: String,
        prompt: String
    ) -> [String: Any] {
        [
            "threadId": threadId,
            "cwd": repositoryPath,
            "model": modelId,
            "effort": reasoningEffort,
            "input": [["type": "text", "text": prompt]],
        ]
    }

    /// Interprets a decoded JSON object from the server. Returns nil for the many
    /// notifications this widget does not surface (deltas, plans, diffs, …).
    static func event(from object: [String: Any]) -> CodexSessionEvent? {
        let method = object["method"] as? String
        let params = object["params"] as? [String: Any] ?? [:]

        // Server -> client requests carry an id and expect a response.
        if let id = requestID(from: object["id"]), let method {
            if let kind = approvalKind(for: method) {
                return .approvalRequested(
                    id: id,
                    kind: kind,
                    summary: summary(for: kind, params: params),
                    detail: detail(for: kind, params: params),
                    permissionProfile: permissionProfile(for: kind, params: params)
                )
            }
            if method == userInputMethod {
                guard let first = (params["questions"] as? [[String: Any]])?.first,
                    let questionID = first["id"] as? String,
                    let question = first["question"] as? String
                else { return nil }
                return .inputRequested(id: id, questionID: questionID, question: question)
            }
            return nil
        }

        switch method {
        case "turn/started":
            return .started

        case "turn/completed":
            return .finished

        case "error":
            let message = (params["message"] as? String) ?? "Codex reported an error"
            return .failed(message)

        case "item/completed":
            // Surface only the assistant's own message; ignore command/reasoning items.
            guard let item = params["item"] as? [String: Any] else { return nil }
            let type = (item["type"] as? String) ?? (item["itemType"] as? String)
            guard type == "agentMessage" || type == "assistantMessage" else { return nil }
            guard let text = item["text"] as? String ?? item["message"] as? String else {
                return nil
            }
            return .assistantMessage(text)

        default:
            return nil
        }
    }

    private static func summary(for kind: ApprovalRequest.Kind, params: [String: Any]) -> String {
        switch kind {
        case .commandExecution:
            if let command = params["command"] as? String { return command }
            if let parts = params["command"] as? [String] { return parts.joined(separator: " ") }
            return "Run a command"
        case .fileChange:
            if let changes = params["fileChanges"] as? [String: Any], !changes.isEmpty {
                return changes.keys.sorted().joined(separator: ", ")
            }
            return "Modify files"
        case .permissions:
            return (params["reason"] as? String) ?? "Additional permissions"
        }
    }

    private static func detail(for kind: ApprovalRequest.Kind, params: [String: Any]) -> String? {
        (params["reason"] as? String) ?? (params["cwd"] as? String)
    }

    private static func permissionProfile(for kind: ApprovalRequest.Kind, params: [String: Any]) -> Data? {
        guard kind == .permissions, let profile = params["permissions"] else { return nil }
        return try? JSONSerialization.data(withJSONObject: profile)
    }

    static func requestID(from value: Any?) -> CodexRequestID? {
        if let value = value as? Int { return .integer(value) }
        if let value = value as? String { return .string(value) }
        return nil
    }
}

/// Drives `codex app-server` over newline-delimited JSON-RPC on stdio.
///
/// This is the only Codex integration that can surface approval and clarification requests,
/// because `codex exec` is non-interactive by design (its only approval-related flags are
/// `--approve-for-me`, which auto-answers, and the dangerous bypass — neither of which this
/// app uses).
actor CodexAppServerClient {
    private struct PendingRun {
        let prompt: String
        let repositoryPath: String
        let modelId: String
        let reasoningEffort: String
        let onEvent: @Sendable (CodexSessionEvent) -> Void
    }

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var nextRequestId = 1
    private var pending: PendingRun?
    private var initializeRequestId: Int?
    private var threadStartRequestId: Int?

    /// Starts a run and streams events. The continuation finishes when the turn completes,
    /// fails, or the process exits.
    func start(
        codexURL: URL,
        prompt: String,
        repositoryPath: String,
        modelId: String,
        reasoningEffort: String,
        onEvent: @escaping @Sendable (CodexSessionEvent) -> Void
    ) throws {
        let process = Process()
        process.executableURL = codexURL
        process.arguments = ["app-server"]
        process.currentDirectoryURL = URL(fileURLWithPath: repositoryPath)

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let lineBuffer = LineBuffer()

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            for line in lineBuffer.append(data) {
                guard let self else { return }
                Task { await self.receive(line: line) }
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }

        process.terminationHandler = { finished in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            if finished.terminationStatus != 0 {
                onEvent(.failed("Codex exited with status \(finished.terminationStatus)"))
            }
        }

        try process.run()

        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.pending = PendingRun(
            prompt: prompt,
            repositoryPath: repositoryPath,
            modelId: modelId,
            reasoningEffort: reasoningEffort,
            onEvent: onEvent
        )

        // The handshake is strictly sequential: turn/start requires the threadId that only
        // comes back in the thread/start response, so each step waits for the previous one.
        initializeRequestId = takeRequestId()
        send([
            "jsonrpc": "2.0", "id": initializeRequestId!, "method": "initialize",
            "params": ["clientInfo": ["name": "Aiflow", "version": "1.0"]],
        ])
    }

    /// Handles one line of server output: advances the handshake, or forwards a UI event.
    private func receive(line: String) {
        guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
            let object = json as? [String: Any],
            let pending
        else { return }

        if let responseId = CodexProtocol.responseId(from: object) {
            if let message = CodexProtocol.errorMessage(from: object) {
                pending.onEvent(.failed(message))
                return
            }

            if responseId == initializeRequestId {
                threadStartRequestId = takeRequestId()
                send([
                    "jsonrpc": "2.0", "id": threadStartRequestId!, "method": "thread/start",
                    "params": CodexProtocol.threadStartParams(
                        repositoryPath: pending.repositoryPath, modelId: pending.modelId),
                ])
                return
            }

            if responseId == threadStartRequestId {
                guard let threadId = CodexProtocol.threadId(fromThreadStartResult: object) else {
                    pending.onEvent(.failed("Codex did not return a thread"))
                    return
                }
                send([
                    "jsonrpc": "2.0", "id": takeRequestId(), "method": "turn/start",
                    "params": CodexProtocol.turnStartParams(
                        threadId: threadId,
                        repositoryPath: pending.repositoryPath,
                        modelId: pending.modelId,
                        reasoningEffort: pending.reasoningEffort,
                        prompt: pending.prompt),
                ])
                return
            }
            return
        }

        if let event = CodexProtocol.event(from: object) {
            pending.onEvent(event)
        }
    }

    func respondToApproval(_ request: ApprovalRequest, allow: Bool) {
        if let response = CodexProtocol.approvalResponse(request, allow: allow) { send(response) }
    }

    func respondToInput(_ question: UserQuestion, answer: String) {
        send(CodexProtocol.userInputResponse(question, answer: answer))
    }

    func cancel() {
        send(["jsonrpc": "2.0", "id": takeRequestId(), "method": "turn/interrupt", "params": [:]])
        process?.terminate()
        stop()
    }

    func stop() {
        try? stdinHandle?.close()
        stdinHandle = nil
        process = nil
        pending = nil
        initializeRequestId = nil
        threadStartRequestId = nil
    }

    private func takeRequestId() -> Int {
        defer { nextRequestId += 1 }
        return nextRequestId
    }

    private func send(_ object: [String: Any]) {
        guard let handle = stdinHandle,
            let data = try? JSONSerialization.data(withJSONObject: object)
        else { return }
        handle.write(data)
        handle.write(Data("\n".utf8))
    }
}

/// Accumulates piped bytes and yields complete newline-delimited lines.
final class LineBuffer: @unchecked Sendable {
    private var pending = Data()
    private let lock = NSLock()

    func append(_ data: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }

        pending.append(data)
        var lines: [String] = []
        while let newlineIndex = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = pending[pending.startIndex..<newlineIndex]
            pending = pending[pending.index(after: newlineIndex)...]
            let line = String(decoding: lineData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }
}
