import Foundation

/// Events the run engine hands back to the UI layer.
enum CodexSessionEvent: Equatable {
    case started
    case approvalRequested(
        id: CodexRequestID, kind: ApprovalRequest.Kind, summary: String, detail: String?,
        permissionProfile: Data?)
    case inputRequested(id: CodexRequestID, questions: [QuestionItem])
    /// Codex confirmed it finished handling the server request with this exact id.
    case requestResolved(CodexRequestID)
    case assistantMessage(String)
    /// A non-terminal error Codex said it will retry — the session stays open.
    case retrying(String)
    case finished
    case cancelled
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
            return ["id": request.id.jsonValue,
                    "result": ["permissions": profile, "scope": "turn"]]
        }
        return ["id": request.id.jsonValue,
                "result": ["decision": allow ? "accept" : "decline"]]
    }

    /// Builds the `answers` map keyed by every exact question id in the request. Question
    /// ids come from the server; none are invented, and none are dropped.
    static func userInputResponse(
        _ request: UserQuestion, answers: [String: String]
    ) -> [String: Any] {
        var payload: [String: Any] = [:]
        for question in request.questions {
            let answer = answers[question.id] ?? ""
            payload[question.id] = ["answers": [answer]]
        }
        return [
            "id": request.id.jsonValue,
            "result": ["answers": payload],
        ]
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

    /// `requestUserInput` is an experimental method, so the client must opt in during
    /// initialize or those requests are never delivered.
    static func initializeParams() -> [String: Any] {
        [
            "clientInfo": ["name": "Aiflow", "version": "1.0"],
            "capabilities": ["experimentalApi": true],
        ]
    }

    /// Sent after the initialize response and before any other request.
    static func initializedNotification() -> [String: Any] {
        ["method": "initialized", "params": [:]]
    }

    static func interruptParams(threadId: String, turnId: String) -> [String: Any] {
        ["threadId": threadId, "turnId": turnId]
    }

    /// Pulls the turn id out of a `turn/start` result or a turn-bearing notification.
    static func turnId(fromTurnPayload object: [String: Any]) -> String? {
        let container = (object["result"] as? [String: Any]) ?? (object["params"] as? [String: Any])
        guard let turn = container?["turn"] as? [String: Any] else { return nil }
        return turn["id"] as? String
    }

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
                let questions = parseQuestions(params["questions"])
                guard !questions.isEmpty else { return nil }
                return .inputRequested(id: id, questions: questions)
            }
            return nil
        }

        switch method {
        case "turn/started":
            return .started

        case "turn/completed":
            // Not every completion is a success: the turn carries its own status, and a
            // failed turn carries a structured error.
            let turn = params["turn"] as? [String: Any] ?? [:]
            switch turn["status"] as? String {
            case "failed":
                let error = turn["error"] as? [String: Any]
                return .failed((error?["message"] as? String) ?? "Codex reported an error")
            case "interrupted":
                return .cancelled
            case "inProgress":
                return nil
            default:
                return .finished
            }

        case "serverRequest/resolved":
            guard let id = requestID(from: params["requestId"]) else { return nil }
            return .requestResolved(id)

        case "error":
            // ErrorNotification nests the message under `error` (TurnError.message) and
            // says whether Codex intends to retry. A retryable error is not terminal.
            let nested = params["error"] as? [String: Any]
            let message =
                (nested?["message"] as? String)
                ?? (params["message"] as? String)
                ?? "Codex reported an error"
            let willRetry = params["willRetry"] as? Bool ?? false
            return willRetry ? .retrying(message) : .failed(message)

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

    /// Decodes every question in a requestUserInput request, preserving the schema's fields.
    static func parseQuestions(_ raw: Any?) -> [QuestionItem] {
        guard let entries = raw as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard let id = entry["id"] as? String,
                let question = entry["question"] as? String
            else { return nil }

            let options = (entry["options"] as? [[String: Any]] ?? []).compactMap {
                option -> QuestionOption? in
                guard let label = option["label"] as? String else { return nil }
                return QuestionOption(
                    label: label, description: option["description"] as? String ?? "")
            }

            return QuestionItem(
                id: id,
                header: entry["header"] as? String ?? "",
                question: question,
                options: options,
                isOther: entry["isOther"] as? Bool ?? false,
                isSecret: entry["isSecret"] as? Bool ?? false
            )
        }
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
    private var turnStartRequestId: Int?

    /// Identifiers for the current active session only; cleared when the session ends.
    private(set) var activeThreadId: String?
    private(set) var activeTurnId: String?

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

        // The handshake is strictly sequential:
        //   initialize -> (response) -> initialized notification -> thread/start
        //   -> (response carries threadId) -> turn/start
        initializeRequestId = takeRequestId()
        send([
            "id": initializeRequestId!, "method": "initialize",
            "params": CodexProtocol.initializeParams(),
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
                // The protocol requires the `initialized` notification before any further
                // request; thread/start is only sent afterwards.
                send(CodexProtocol.initializedNotification())

                threadStartRequestId = takeRequestId()
                send([
                    "id": threadStartRequestId!, "method": "thread/start",
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
                activeThreadId = threadId
                turnStartRequestId = takeRequestId()
                send([
                    "id": turnStartRequestId!, "method": "turn/start",
                    "params": CodexProtocol.turnStartParams(
                        threadId: threadId,
                        repositoryPath: pending.repositoryPath,
                        modelId: pending.modelId,
                        reasoningEffort: pending.reasoningEffort,
                        prompt: pending.prompt),
                ])
                return
            }

            if responseId == turnStartRequestId {
                activeTurnId = CodexProtocol.turnId(fromTurnPayload: object) ?? activeTurnId
                return
            }
            return
        }

        // Notifications also carry the turn, which is the earliest reliable source of the
        // turn id when turn/start's own response does not include it.
        if activeTurnId == nil, let turnId = CodexProtocol.turnId(fromTurnPayload: object) {
            activeTurnId = turnId
        }

        if let event = CodexProtocol.event(from: object) {
            pending.onEvent(event)
        }
    }

    func respondToApproval(_ request: ApprovalRequest, allow: Bool) {
        if let response = CodexProtocol.approvalResponse(request, allow: allow) { send(response) }
    }

    func respondToInput(_ request: UserQuestion, answers: [String: String]) {
        send(CodexProtocol.userInputResponse(request, answers: answers))
    }

    /// Interrupts the active turn by its exact ids and lets the server wind the turn down —
    /// `turn/completed` with `interrupted` status is what actually confirms cancellation.
    /// The process is only terminated if the server stops responding, and only ever this
    /// session's own child process.
    func cancel(terminateAfter: Duration = .seconds(5)) {
        guard let threadId = activeThreadId, !threadId.isEmpty,
            let turnId = activeTurnId, !turnId.isEmpty
        else {
            // No turn is in flight, so there is nothing to wind down. Report the
            // cancellation immediately so the UI is not left waiting.
            let onEvent = pending?.onEvent
            terminateOwnProcess()
            stop()
            onEvent?(.cancelled)
            return
        }

        send([
            "id": takeRequestId(), "method": "turn/interrupt",
            "params": CodexProtocol.interruptParams(threadId: threadId, turnId: turnId),
        ])

        // Bounded fallback: if the server never confirms, stop waiting on it.
        Task { [weak self] in
            try? await Task.sleep(for: terminateAfter)
            await self?.terminateIfStillRunning()
        }
    }

    /// Bounded fallback. Fires only if the session is still open, i.e. the server never
    /// confirmed the interrupt.
    private func terminateIfStillRunning() {
        guard pending != nil else { return }  // the server already wound the turn down
        let onEvent = pending?.onEvent
        terminateOwnProcess()
        stop()
        onEvent?(.cancelled)
    }

    private func terminateOwnProcess() {
        // Only this session's child process is ever signalled.
        if let process, process.isRunning { process.terminate() }
    }

    func stop() {
        try? stdinHandle?.close()
        stdinHandle = nil
        terminateOwnProcess()
        process = nil
        pending = nil
        initializeRequestId = nil
        threadStartRequestId = nil
        turnStartRequestId = nil
        activeThreadId = nil
        activeTurnId = nil
    }

    private func takeRequestId() -> Int {
        defer { nextRequestId += 1 }
        return nextRequestId
    }

    private func send(_ object: [String: Any]) {
        if let outboundRecorder {
            outboundRecorder(object)
            return
        }
        guard let handle = stdinHandle,
            let data = try? JSONSerialization.data(withJSONObject: object)
        else { return }
        handle.write(data)
        handle.write(Data("\n".utf8))
    }

    // MARK: - Test seam
    //
    // Lets the cancellation and wire-format tests drive a session without spawning Codex.
    private var outboundRecorder: (([String: Any]) -> Void)?

    /// Puts the client into the state it would be in mid-turn, recording outbound messages.
    func configureForTesting(
        threadId: String,
        turnId: String,
        onSend: @escaping ([String: Any]) -> Void,
        onEvent: @escaping @Sendable (CodexSessionEvent) -> Void
    ) {
        outboundRecorder = onSend
        activeThreadId = threadId
        activeTurnId = turnId
        pending = PendingRun(
            prompt: "", repositoryPath: "/repo", modelId: "m", reasoningEffort: "low",
            onEvent: onEvent)
    }

    /// True while a session is still open (nothing has stopped or released it).
    var isSessionActive: Bool { pending != nil }
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
