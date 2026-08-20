import AppKit
import Foundation

@MainActor
final class WidgetViewModel: ObservableObject {
    /// The app's single instance. Referenced by the scene and by the app delegate so the
    /// companion bridge can start at launch. Tests construct their own instances instead and
    /// never touch this, so no test binds the bridge port.
    static let shared = WidgetViewModel()

    @Published private(set) var savedProjects: [SavedProject] = []
    @Published private(set) var clipboardPrompt = ""
    @Published private(set) var chatURL: String?
    @Published private(set) var runState: RunState = .ready
    /// The project the in-flight run belongs to. Tracked separately because the approval and
    /// question states describe the request, not the project.
    @Published private(set) var runningProject: SavedProject?
    @Published private(set) var lastMessage = ""
    @Published private(set) var notice = ""
    @Published private(set) var config: CodexConfig?

    @Published var selectedModelRole: String {
        didSet { defaults.set(selectedModelRole, forKey: Self.modelKey) }
    }
    @Published var selectedEffort: String {
        didSet { defaults.set(selectedEffort, forKey: Self.effortKey) }
    }

    private let cli: AiflowCLI
    private let store: SavedProjectStore
    private let map: ChatProjectMap
    private let defaults: UserDefaults
    private let detectChat: () -> String?
    private let validateGit: (String) -> GitRepositoryValidator.Result
    private let notifications: NotificationManaging

    private var client: CodexAppServerClient?
    private var isPopoverVisible = false
    private var notificationsAvailable = true

    /// Which execution backend served the current run. Explicit and observable — never an
    /// ambiguous mix, and never two workers for one run.
    enum RunWorker: String {
        /// The official Codex VS Code extension executes the run; Aiflow drives it as a
        /// follower through the companion.
        case officialVSCode = "official-vscode"
        /// Aiflow's own Codex App Server session (the legacy path, kept as fallback).
        case legacyAppServer = "legacy-app-server"
    }

    /// The worker serving the run in flight, and the run's id for correlating worker reports.
    @Published private(set) var activeWorker: RunWorker?
    private var activeRunId: String?

    /// True when a companion has reported that the official Codex worker is usable.
    @Published private(set) var officialWorkerAvailable = false

    /// The companion bridge, if one is attached. Held strongly here while the bridge holds
    /// the controller weakly, so there is no cycle. The bridge is a mirror only — the run
    /// never depends on it being present or connected.
    private var bridge: AiflowBridgeServer?

    private static let modelKey = "aiflow.model"
    private static let effortKey = "aiflow.effort"

    init(
        cli: AiflowCLI = .shared,
        store: SavedProjectStore = SavedProjectStore(),
        map: ChatProjectMap = ChatProjectMap(),
        defaults: UserDefaults = .standard,
        detectChat: @escaping () -> String? = { BrowserURLDetector.detectChatURL() },
        validateGit: @escaping (String) -> GitRepositoryValidator.Result = {
            GitRepositoryValidator.validate(path: $0)
        },
        notifications: NotificationManaging? = nil
    ) {
        self.cli = cli
        self.store = store
        self.map = map
        self.defaults = defaults
        self.detectChat = detectChat
        self.validateGit = validateGit
        self.notifications = notifications ?? NotificationManager()
        self.selectedModelRole =
            defaults.string(forKey: Self.modelKey) ?? CodexConfig.defaultModelRole
        self.selectedEffort =
            defaults.string(forKey: Self.effortKey) ?? CodexConfig.defaultReasoningEffort
        self.savedProjects = store.projects
        if let error = store.loadError { self.notice = error }
    }

    // MARK: - Derived state

    var models: [CodexModel] { config?.models ?? [] }
    var efforts: [String] { config?.reasoningEfforts ?? [] }
    /// The official worker uses the official Codex extension's policy; Aiflow's Manual label
    /// applies only to the legacy App Server path, where this app mediates approval requests.
    var approvalDisplayLabel: String {
        if activeWorker == .officialVSCode || (activeWorker == nil && officialWorkerAvailable) {
            return "Approval: Codex policy"
        }
        return "Approval: Manual"
    }

    var hasPrompt: Bool { !clipboardPrompt.isEmpty }
    var promptCharacterCount: Int { clipboardPrompt.count }
    var resolvedModelId: String? { config?.model(forRole: selectedModelRole)?.modelId }

    /// A project button is clickable when there is a prompt, a model, and no run in flight.
    var canRunProjects: Bool { hasPrompt && resolvedModelId != nil && !runState.isBusy }

    var mappedProjectPath: String? {
        guard let chatURL else { return nil }
        return map.projectPath(for: chatURL)
    }

    func isMapped(_ project: SavedProject) -> Bool {
        mappedProjectPath == project.path
    }

    /// A mapping pointing at a repo that is no longer saved or no longer on disk.
    var staleMappingPath: String? {
        guard let mapped = mappedProjectPath else { return nil }
        let saved = store.project(withPath: mapped)
        if saved == nil || saved?.exists == false { return mapped }
        return nil
    }

    var chatDisplay: String {
        guard let chatURL else { return "No ChatGPT conversation detected" }
        return ChatURL.conversationID(from: chatURL)
    }

    var isRunning: Bool { runState.isBusy }

    /// MenuBarExtra's label is app-lifetime state, independent of its transient popover view.
    var menuBarSymbolName: String {
        switch runState {
        case .ready, .confirming: return "bolt.horizontal.circle"
        case .launching, .running, .respondingToRequest, .cancelling:
            return "bolt.horizontal.circle.fill"
        case .waitingForApproval, .waitingForInput: return "exclamationmark.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .cancelled: return "bolt.horizontal.circle"
        case .failed: return "xmark.circle.fill"
        }
    }

    func isRunning(_ project: SavedProject) -> Bool {
        runState.isBusy && runningProject?.id == project.id
    }

    // MARK: - Refresh

    func refresh() async {
        await loadConfigIfNeeded()
        refreshClipboard()
        refreshChat()
        savedProjects = store.projects
    }

    func refreshClipboard() {
        // Read-only: the widget never writes to the clipboard.
        clipboardPrompt =
            (NSPasteboard.general.string(forType: .string) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func refreshChat() {
        chatURL = detectChat()
    }

    func popoverDidBecomeVisible() { isPopoverVisible = true }
    func popoverDidBecomeHidden() { isPopoverVisible = false }

    private func loadConfigIfNeeded() async {
        guard config == nil else { return }
        do {
            let loaded = try await cli.decode(CodexConfig.self, from: .modelsJSON)
            config = loaded
            if loaded.model(forRole: selectedModelRole) == nil {
                selectedModelRole = CodexConfig.defaultModelRole
            }
            if !loaded.reasoningEfforts.contains(selectedEffort) {
                selectedEffort = CodexConfig.defaultReasoningEffort
            }
        } catch {
            notice = "Could not read Aiflow model configuration"
        }
    }

    // MARK: - Saved projects

    /// Validates a chosen folder, resolves it to its Git root, and saves it.
    func addProject(at path: String) {
        switch validateGit(path) {
        case .repository(let root):
            let (project, isNew) = store.add(path: root)
            savedProjects = store.projects
            notice = isNew ? "" : "\(project.name) is already saved"
        case .notARepository:
            notice = "Selected folder is not a Git repository."
        case .missingDirectory:
            notice = "That folder does not exist."
        case .gitUnavailable:
            notice = "git could not be found, so the folder could not be verified."
        }
    }

    func rename(_ project: SavedProject, to name: String) {
        store.rename(id: project.id, to: name)
        savedProjects = store.projects
    }

    /// Forgets the project. The repository on disk is never touched.
    func remove(_ project: SavedProject) {
        store.remove(id: project.id)
        savedProjects = store.projects
    }

    func revealInFinder(_ project: SavedProject) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path)
    }

    // MARK: - Chat mapping (optional convenience)

    func mapCurrentChat(to project: SavedProject) {
        guard let chatURL else {
            notice = "No ChatGPT conversation detected"
            return
        }
        map.setMapping(chatURL: chatURL, projectPath: project.path)
        objectWillChange.send()
        notice = "Chat mapped to \(project.name)"
    }

    func unmapCurrentChat() {
        guard let chatURL else { return }
        map.removeMapping(chatURL: chatURL)
        objectWillChange.send()
        notice = "Mapping removed"
    }

    // MARK: - Run lifecycle

    /// Clicking a project never starts Codex directly — it always asks first.
    func requestRun(_ project: SavedProject) {
        guard canRunProjects else { return }
        guard project.exists else {
            notice = "\(project.name) no longer exists on disk"
            return
        }
        runState = .confirming(project)
    }

    func cancelConfirmation() {
        if case .confirming = runState { runState = .ready }
    }

    var confirmingProject: SavedProject? {
        if case .confirming(let project) = runState { return project }
        return nil
    }

    var pendingApproval: ApprovalRequest? {
        if case .waitingForApproval(let request) = runState { return request }
        return nil
    }

    var pendingQuestion: UserQuestion? {
        if case .waitingForInput(let question) = runState { return question }
        return nil
    }

    /// Starts Codex after the user confirmed. Only reachable from `.confirming`.
    func confirmRun() {
        guard case .confirming(let project) = runState else { return }
        guard let modelId = resolvedModelId, hasPrompt else { return }

        let prompt = clipboardPrompt  // full clipboard text, never the preview
        let effort = selectedEffort
        lastMessage = ""
        runningProject = project
        runState = .launching(project)

        let runId = UUID().uuidString
        activeRunId = runId

        // Prefer the official Codex extension when a companion is connected and has reported
        // it usable; otherwise fall back to Aiflow's own App Server session. Exactly one of
        // the two runs — never both.
        // Execution goes to the single designated companion, never to every viewer: two
        // companions receiving one execute_run would each start a Codex turn.
        if officialWorkerAvailable, let bridge, bridge.hasDesignatedWorker,
            bridge.sendToWorker(
                .executeRun(
                    runId: runId, project: project, prompt: prompt,
                    model: selectedModelRole, effort: effort))
        {
            activeWorker = .officialVSCode
            emitRunStarted(project: project, effort: effort, prompt: prompt)
            return
        }

        // Only the legacy path needs Aiflow's own Codex executable; the official worker runs
        // inside the companion's editor and has its own runtime.
        activeWorker = .legacyAppServer
        guard let codexURL = CodexLocator.resolve() else {
            activeWorker = nil
            activeRunId = nil
            runningProject = nil
            runState = .failed(project: project, message: "Codex not installed")
            return
        }

        let client = CodexAppServerClient()
        self.client = client

        emitRunStarted(project: project, effort: effort, prompt: prompt)

        Task {
            notificationsAvailable = await notifications.prepareForRun()
            if !notificationsAvailable {
                notice = "Notifications are disabled. Aiflow will show attention requests in the menu bar."
            }
            do {
                try await client.start(
                    codexURL: codexURL,
                    prompt: prompt,
                    repositoryPath: project.path,
                    modelId: modelId,
                    reasoningEffort: effort
                ) { [weak self] event in
                    Task { @MainActor in self?.handle(event, project: project) }
                }
            } catch {
                await MainActor.run {
                    self.runState = .failed(project: project, message: "Codex could not be started")
                }
            }
        }
    }

    fileprivate func handle(_ event: CodexSessionEvent, project: SavedProject) {
        // Ignore late output from a cancelled/finished child process. In particular, a late
        // failure must not replace `.ready` after the user cancelled the run.
        guard runningProject?.id == project.id else { return }

        switch event {
        case .started:
            runState = .running(project)
            emit(.runStatus(runState.bridgeName))

        case .approvalRequested(let id, let kind, let summary, let detail, let permissionProfile):
            let request = ApprovalRequest(
                    id: id, kind: kind, summary: summary, detail: detail,
                    projectName: project.name, permissionProfile: permissionProfile)
            runState = .waitingForApproval(request)
            emit(.approvalRequested(request))
            if !isPopoverVisible && notificationsAvailable { notifications.sendApproval(for: request) }

        case .inputRequested(let id, let questions):
            let request = UserQuestion(
                id: id, questions: questions, projectName: project.name)
            runState = .waitingForInput(request)
            emit(.questionRequested(request))
            if !isPopoverVisible && notificationsAvailable { notifications.sendQuestion(for: request) }

        case .requestResolved(let id):
            // Only the exact request we are blocked on may unblock us; a stale resolution
            // for an earlier request must never clear a newer one.
            guard case .respondingToRequest(let awaiting) = runState, awaiting == id else {
                return
            }
            runState = .running(project)
            emit(.runStatus(runState.bridgeName))

        case .assistantMessage(let text):
            lastMessage = text
            emit(.agentMessage(text))

        case .finished:
            runState = .completed(project)
            var completed = BridgeEvent(type: .runCompleted)
            completed.runState = runState.bridgeName
            completed.project = project.name
            completed.message = lastMessage
            emit(completed)
            if !isPopoverVisible && notificationsAvailable { notifications.sendCompletion(for: project) }
            finishSession()

        case .cancelled:
            runState = .cancelled(project)
            var cancelled = BridgeEvent(type: .runCancelled)
            cancelled.runState = runState.bridgeName
            cancelled.project = project.name
            emit(cancelled)
            finishSession()

        case .retrying(let detail):
            // Not terminal: Codex said it will retry, so the session stays open and the run
            // stays busy. Only the note changes.
            notice = "Codex hit a temporary error and is retrying… (\(detail))"
            var retrying = BridgeEvent(type: .runStatus)
            retrying.runState = "retrying"
            retrying.message = detail
            emit(retrying)

        case .failed(let detail):
            // A failure arriving while the turn is being interrupted must not overwrite the
            // cancellation; the run is already on its way to `.cancelled`.
            if case .cancelling = runState { return }
            runState = .failed(project: project, message: detail)
            var failed = BridgeEvent(type: .runFailed)
            failed.runState = runState.bridgeName
            failed.project = project.name
            failed.message = detail
            emit(failed)
            if !isPopoverVisible && notificationsAvailable { notifications.sendFailure(for: project) }
            finishSession()
        }
    }

    /// Sends the user's explicit decision. Aiflow never answers an approval on its own.
    /// The run stays blocked on this exact request until Codex confirms it resolved it.
    func respondToApproval(allow: Bool) {
        guard case .waitingForApproval(let request) = runState, runningProject != nil else {
            return
        }
        notifications.removePendingRequest(id: request.id)
        runState = .respondingToRequest(request.id)
        Task { await client?.respondToApproval(request, allow: allow) }
    }

    /// Answers every question in the request, keyed by its exact question id.
    func respondToQuestion(_ answers: [String: String]) {
        guard case .waitingForInput(let request) = runState, runningProject != nil else {
            return
        }
        // Every question must have an answer before the response is sent.
        let complete = request.questions.allSatisfy { question in
            !(answers[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard complete else { return }

        let trimmed = answers.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        notifications.removePendingRequest(id: request.id)
        runState = .respondingToRequest(request.id)
        Task { await client?.respondToInput(request, answers: trimmed) }
    }

    /// Asks Codex to wind the turn down and waits for it. The session is deliberately kept
    /// alive here: the run is only `.cancelled` once the client reports the turn actually
    /// ended (`turn/completed` with `interrupted`, or the client's bounded fallback).
    func cancelRun() {
        guard let project = runningProject, runState.isBusy else { return }
        if let request = pendingApproval { notifications.removePendingRequest(id: request.id) }
        if let question = pendingQuestion { notifications.removePendingRequest(id: question.id) }

        runState = .cancelling(project)
        emit(.runStatus(runState.bridgeName))

        // Route the interrupt to whichever worker is actually serving this run.
        if activeWorker == .officialVSCode, let runId = activeRunId {
            bridge?.sendToWorker(.cancelRun(runId: runId))
            return
        }
        Task { await client?.cancel() }
    }

    private func finishSession() {
        let finishing = client
        client = nil
        runningProject = nil
        Task { await finishing?.stop() }
    }

    // MARK: - Companion bridge

    /// Wires the app-lifetime bridge to this view model. The view model stays the single
    /// source of truth; the bridge only mirrors it outward and forwards commands inward.
    func attachBridge(_ bridge: AiflowBridgeServer) {
        self.bridge = bridge
        bridge.controller = self
        bridge.start()
    }

    /// Idempotent: the popover's `.task` can run many times, but only one server is created.
    func startCompanionBridgeIfNeeded() {
        guard bridge == nil else { return }
        attachBridge(AiflowBridgeServer())
    }

    /// Applies a report from the official Codex worker.
    ///
    /// Every report must name the run it belongs to and match the run in flight: a report from
    /// a previous or unknown run must never complete, fail, or cancel the current one. Reports
    /// are also ignored entirely unless the official worker is the one serving this run.
    private func handleWorkerReport(_ command: BridgeCommand) {
        guard activeWorker == .officialVSCode,
            let runId = command.runId, runId == activeRunId,
            let project = runningProject
        else { return }

        switch command.type {
        case .workerAccepted:
            runState = .running(project)

        case .workerThread:
            // The official conversation/turn now executing this run. Recorded for the status
            // line only; the official Codex UI is where the conversation itself is visible.
            if let conversationId = command.conversationId {
                notice = command.turnId.map {
                    "Official Codex turn \($0) in conversation \(conversationId)"
                } ?? "Official Codex conversation \(conversationId)"
            }

        case .workerStatus:
            runState = .running(project)

        case .workerCompleted:
            lastMessage = command.message ?? ""
            runState = .completed(project)
            finishWorkerRun()

        case .workerFailed:
            let detail = command.message ?? "official Codex worker failed"
            // If the official path is unusable, stop preferring it so the next run falls back
            // to Aiflow's own worker. The failure stays visible rather than silently retried.
            if detail.hasPrefix("extension_unavailable") || detail.hasPrefix("ipc_unavailable") {
                officialWorkerAvailable = false
            }
            runState = .failed(project: project, message: detail)
            finishWorkerRun()

        case .workerCancelled:
            runState = .cancelled(project)
            finishWorkerRun()

        default:
            break
        }
    }

    private func finishWorkerRun() {
        activeRunId = nil
        activeWorker = nil
        runningProject = nil
    }

    /// Records what the companion reports about official Codex availability.
    func setOfficialWorkerAvailable(_ available: Bool) {
        officialWorkerAvailable = available
    }

    private func emitRunStarted(project: SavedProject, effort: String, prompt: String) {
        var started = BridgeEvent(type: .runStarted)
        started.project = project.name
        started.model = selectedModelRole
        started.effort = effort
        started.runState = runState.bridgeName
        started.runId = activeRunId
        // A bounded preview only; the full prompt is not mirrored to the companion here.
        started.promptPreview = String(prompt.prefix(200))
        emit(started)
    }

    private func emit(_ event: BridgeEvent) {
        bridge?.broadcast(event)
    }

    /// Sends a `file_open` only for a path inside the given saved repository — the active run's
    /// repository by default. An arbitrary path is never forwarded to the companion, and the
    /// companion can never supply one: `file_open` is outbound only.
    @discardableResult
    func emitFileOpen(path: String, in project: SavedProject? = nil) -> Bool {
        let scope = project ?? runningProject ?? runState.confirmingProject
        guard let root = scope?.path else { return false }
        let resolvedRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard resolved == resolvedRoot || resolved.hasPrefix(resolvedRoot + "/") else {
            return false
        }
        emit(.fileOpen(path: resolved))
        return true
    }

    /// Asks a connected companion to open this repository's README — the `file_open` spike
    /// affordance. Aiflow picks the path and validates it through `emitFileOpen`; this is a
    /// user-initiated one-shot, not automatic file following.
    @discardableResult
    func openReadmeInCompanion(_ project: SavedProject) -> Bool {
        let readme = URL(fileURLWithPath: project.path)
            .appendingPathComponent("README.md").path

        guard FileManager.default.fileExists(atPath: readme) else {
            notice = "\(project.name) has no README.md to open."
            return false
        }
        guard emitFileOpen(path: readme, in: project) else {
            notice = "Could not open README.md in \(project.name)."
            return false
        }
        notice = "Asked VS Code to open \(project.name)/README.md."
        return true
    }
}

// MARK: - BridgeController

extension WidgetViewModel: BridgeController {
    /// The complete current state, so a client that connects or reconnects mid-run can
    /// rebuild its UI without the run restarting.
    func bridgeSnapshot() -> BridgeEvent {
        var event = BridgeEvent(type: .snapshot)
        event.connected = true
        event.protocolVersion = BridgeCodec.protocolVersion
        event.runState = runState.bridgeName
        event.project = (runningProject ?? runState.confirmingProject)?.name
        event.model = selectedModelRole
        event.effort = selectedEffort
        event.message = lastMessage

        // A snapshot must also carry whatever the run is currently blocked on, or a client
        // that reconnects while Codex waits would have no way to answer.
        if let approval = pendingApproval {
            event.requestId = approval.id
            event.kind = approval.kind.wireName
            event.summary = approval.summary
            event.detail = approval.detail
        } else if let question = pendingQuestion {
            event.requestId = question.id
            event.questions = question.questions.map(BridgeQuestion.init)
        }
        return event
    }

    /// Commands are verbs, never data. Anything that does not match the currently pending
    /// request is ignored — the view model's state is authoritative, not the client's claim.
    func handleBridgeCommand(_ command: BridgeCommand) {
        switch command.type {
        case .auth:
            // Authentication is settled by the transport before a command ever reaches the
            // view model; reaching here means the token was already accepted.
            break

        case .ping:
            emit(bridgeSnapshot())

        case .cancel:
            cancelRun()

        case .approve, .deny:
            guard let pending = pendingApproval, let claimed = command.requestId,
                claimed == pending.id
            else { return }  // stale or mismatched id must not resolve a different request
            respondToApproval(allow: command.type == .approve)

        case .answerQuestion:
            guard let pending = pendingQuestion, let claimed = command.requestId,
                claimed == pending.id, let answers = command.answers
            else { return }
            respondToQuestion(answers)

        case .workerAvailable:
            // Availability describes the companion, not a run, so it carries no run id.
            setOfficialWorkerAvailable(command.workerState == "ready")

        case .workerAccepted, .workerThread, .workerStatus, .workerCompleted, .workerFailed,
            .workerCancelled:
            handleWorkerReport(command)
        }
    }
}

extension RunState {
    /// The project being confirmed, used only for snapshot/file-open scoping.
    var confirmingProject: SavedProject? {
        if case .confirming(let project) = self { return project }
        return nil
    }
}

// MARK: - Test seams
//
// These let the unit tests drive state that would otherwise require a live CLI, a real
// clipboard, or an actual Codex process. They are not used by the app itself.
extension WidgetViewModel {
    func applyConfigForTesting(_ config: CodexConfig) {
        self.config = config
    }

    func setPromptForTesting(_ prompt: String) {
        clipboardPrompt = prompt
    }

    func enterRunningForTesting(_ project: SavedProject) {
        runningProject = project
        runState = .running(project)
    }

    func handleEventForTesting(_ event: CodexSessionEvent, project: SavedProject) {
        handle(event, project: project)
    }

    /// Puts a run in flight under a chosen worker, as `confirmRun` would.
    func startRunForTesting(_ project: SavedProject, worker: RunWorker, runId: String) {
        runningProject = project
        activeWorker = worker
        activeRunId = runId
        runState = .running(project)
        lastMessage = ""
    }

    func setNotificationsAvailableForTesting(_ available: Bool) {
        notificationsAvailable = available
    }
}
