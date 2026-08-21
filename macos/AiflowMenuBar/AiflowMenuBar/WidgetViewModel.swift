import AppKit
import Foundation

private enum ChatGPTReviewAutomationError: Error {
    case evidenceMismatch(String)
}

enum ApprovalHandling: String, Equatable {
    case manual
    case autoApprove
}

enum FollowUpRoutingMode: String, Equatable {
    case manual
    case chatGPT
}

@MainActor
final class WidgetViewModel: ObservableObject {
    private static let dismissedReviewWarningsKey = "aiflow.dismissed-review-warnings"
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
    @Published private(set) var currentReviewLoopStatus: ReviewLoopReadModel.Record?
    @Published private(set) var recentReviewLoopRecords: [ReviewLoopReadModel.Record] = []
    @Published private(set) var reviewManualAttentionCount = 0
    @Published private(set) var hasQueuedAutomaticReviewFollowUp = false
    @Published private(set) var reviewAutomationBlocked = false
    @Published private(set) var reviewAutomationBlockReason: String?
    @Published private(set) var attentionPreferences: AiflowAttentionPreferences
    @Published private(set) var approvalHandling: ApprovalHandling
    @Published private(set) var followUpRoutingMode: FollowUpRoutingMode

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
    private let attention: AttentionCoordinating
    private let handoffStore: RunResultHandoffStore
    private let reviewStore: ChatGPTReviewStore
    private let reviewDispatchStore: ChatGPTReviewDispatchStore
    private let now: () -> Date
    private let reviewFollowupSender: ((BridgeEvent) -> Bool)?
    private let approvalResponseSender: ((ApprovalRequest, Bool) -> Void)?
    private var dismissedReviewWarningIDs: Set<String> = []
    private var manualRecoveryDraft: ManualRecoveryDraft?

    private var client: CodexAppServerClient?
    private var isPopoverVisible = false
    private var notificationsAvailable = true
    private var activeHandoffContext: ActiveRunHandoffContext?

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

    private struct ActiveRunHandoffContext {
        let runId: String
        let project: SavedProject
        let sourceChat: RunResultHandoff.ChatTarget?
        let modelRole: String
        let modelId: String
        let effort: String
        let startedAt: Date

        var codexConversationId: String?
        var codexTurnId: String?
    }

    private struct ManualRecoveryDraft {
        let sourceRunId: String
        let forbiddenFollowUpRunId: String?
        let prompt: String
    }

    /// True when a companion has reported that the official Codex worker is usable.
    @Published private(set) var officialWorkerAvailable = false

    /// The companion bridge, if one is attached. Held strongly here while the bridge holds
    /// the controller weakly, so there is no cycle. The bridge is a mirror only — the run
    /// never depends on it being present or connected.
    private var bridge: AiflowBridgeServer?
    private var handoffTransportServer: HandoffTransportServer?
    private static let maximumReviewFollowups = 5

    private static let modelKey = "aiflow.model"
    private static let effortKey = "aiflow.effort"
    private static let approvalHandlingKey = "aiflow.approval-handling"
    private static let followUpRoutingModeKey = "aiflow.follow-up-routing"

    init(
        cli: AiflowCLI = .shared,
        store: SavedProjectStore = SavedProjectStore(),
        map: ChatProjectMap = ChatProjectMap(),
        defaults: UserDefaults = .standard,
        detectChat: @escaping () -> String? = { BrowserURLDetector.detectChatURL() },
        validateGit: @escaping (String) -> GitRepositoryValidator.Result = {
            GitRepositoryValidator.validate(path: $0)
        },
        notifications: NotificationManaging? = nil,
        attention: AttentionCoordinating? = nil,
        handoffStore: RunResultHandoffStore = RunResultHandoffStore(),
        reviewStore: ChatGPTReviewStore = ChatGPTReviewStore(),
        reviewDispatchStore: ChatGPTReviewDispatchStore = ChatGPTReviewDispatchStore(),
        now: @escaping () -> Date = Date.init,
        reviewFollowupSender: ((BridgeEvent) -> Bool)? = nil,
        approvalResponseSender: ((ApprovalRequest, Bool) -> Void)? = nil
    ) {
        self.cli = cli
        self.store = store
        self.map = map
        self.defaults = defaults
        self.detectChat = detectChat
        self.validateGit = validateGit
        let resolvedNotifications = notifications ?? NotificationManager()
        self.notifications = resolvedNotifications
        let resolvedAttention = attention ?? AttentionCoordinator(
            defaults: defaults,
            notifications: resolvedNotifications
        )
        self.attention = resolvedAttention
        self.attentionPreferences = resolvedAttention.preferences
        self.handoffStore = handoffStore
        self.reviewStore = reviewStore
        self.reviewDispatchStore = reviewDispatchStore
        self.now = now
        self.reviewFollowupSender = reviewFollowupSender
        self.approvalResponseSender = approvalResponseSender
        self.approvalHandling = ApprovalHandling(
            rawValue: defaults.string(forKey: Self.approvalHandlingKey) ?? ""
        ) ?? .manual
        self.followUpRoutingMode = FollowUpRoutingMode(
            rawValue: defaults.string(forKey: Self.followUpRoutingModeKey) ?? ""
        ) ?? .manual
        self.selectedModelRole =
            defaults.string(forKey: Self.modelKey) ?? CodexConfig.defaultModelRole
        self.selectedEffort =
            defaults.string(forKey: Self.effortKey) ?? CodexConfig.defaultReasoningEffort
        self.dismissedReviewWarningIDs = Set(
            defaults.stringArray(forKey: Self.dismissedReviewWarningsKey) ?? []
        )
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
            return approvalHandling == .autoApprove
                ? "Approval: Auto unavailable"
                : "Approval: Codex policy"
        }
        return approvalHandling == .autoApprove ? "Approval: Auto-approve" : "Approval: Manual"
    }

    var approvalHandlingDescription: String {
        if activeWorker == .officialVSCode || (activeWorker == nil && officialWorkerAvailable) {
            return approvalHandling == .autoApprove
                ? "Auto-approve is unavailable for the official Codex worker."
                : "Official Codex approval remains user-mediated."
        }
        return approvalHandling == .autoApprove
            ? "Approves legacy Codex permission requests locally. Questions still stop for you."
            : "Codex permission requests wait for your decision."
    }

    var hasPrompt: Bool { !effectivePrompt.isEmpty }
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

    var confirmationPromptPreview: String { String(effectivePrompt.prefix(400)) }

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
        refreshReviewLoopStatus()
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

    func popoverDidBecomeVisible() {
        isPopoverVisible = true
        attention.updateWidgetVisibility(true)
    }

    func popoverDidBecomeHidden() {
        isPopoverVisible = false
        attention.updateWidgetVisibility(false)
    }

    func attachAttentionPresenter(_ presenter: AttentionWidgetPresenting) {
        attention.attachPresenter(presenter)
    }

    func setSystemNotificationsEnabled(_ enabled: Bool) {
        var preferences = attentionPreferences
        preferences.systemNotificationsEnabled = enabled
        updateAttentionPreferences(preferences)
        guard enabled else { return }

        Task { [weak self] in
            guard let self else { return }
            self.notificationsAvailable = await self.attention.requestNotificationPermissionIfNeeded()
            if !self.notificationsAvailable {
                self.notice = "macOS notifications are denied. Auto-show remains available."
            }
        }
    }

    func setAutoShowWidgetEnabled(_ enabled: Bool) {
        var preferences = attentionPreferences
        preferences.autoShowWidgetEnabled = enabled
        updateAttentionPreferences(preferences)
    }

    func setAttentionMuted(_ muted: Bool) {
        var preferences = attentionPreferences
        preferences.muted = muted
        updateAttentionPreferences(preferences)
    }

    func setApprovalHandling(_ handling: ApprovalHandling) {
        approvalHandling = handling
        defaults.set(handling.rawValue, forKey: Self.approvalHandlingKey)
    }

    func setFollowUpRoutingMode(_ mode: FollowUpRoutingMode) {
        followUpRoutingMode = mode
        defaults.set(mode.rawValue, forKey: Self.followUpRoutingModeKey)
    }

    private func updateAttentionPreferences(_ preferences: AiflowAttentionPreferences) {
        attention.updatePreferences(preferences)
        attentionPreferences = attention.preferences
    }

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

    func returnChatURL(for project: SavedProject) -> String? {
        map.chatURL(forProjectPath: project.path)
    }

    func setReturnChatURL(_ project: SavedProject, rawURL: String) {
        guard let normalized = ChatURL.normalize(rawURL) else {
            notice = "Enter a valid ChatGPT conversation link."
            return
        }

        map.setMapping(
            chatURL: normalized,
            projectPath: project.path
        )

        objectWillChange.send()
        notice = "Return chat set for \(project.name)"
    }

    func mapCurrentChat(to project: SavedProject) {
        guard let chatURL else {
            notice = "No ChatGPT conversation detected"
            return
        }

        setReturnChatURL(
            project,
            rawURL: chatURL
        )
    }

    func clearReturnChat(for project: SavedProject) {
        map.removeMapping(
            forProjectPath: project.path
        )

        objectWillChange.send()
        notice = "Return chat removed for \(project.name)"
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
        if case .confirming = runState {
            manualRecoveryDraft = nil
            runState = .ready
        }
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

        let prompt = effectivePrompt
        let forbiddenFollowUpRunId = manualRecoveryDraft?.forbiddenFollowUpRunId
        manualRecoveryDraft = nil
        let effort = selectedEffort
        lastMessage = ""
        runningProject = project
        runState = .launching(project)

        var runId = UUID().uuidString
        while runId == forbiddenFollowUpRunId { runId = UUID().uuidString }
        activeRunId = runId
        activeHandoffContext = ActiveRunHandoffContext(
            runId: runId,
            project: project,
            sourceChat: sourceChatTargetForRun(project),
            modelRole: selectedModelRole,
            modelId: modelId,
            effort: effort,
            startedAt: now()
        )

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
            runState = .failed(project: project, message: "Codex not installed")
            persistTerminalHandoff(outcome: .failed, errorMessage: "Codex not installed")
            clearActiveRunContextAfterTerminalRelease()
            return
        }

        let client = CodexAppServerClient()
        self.client = client

        emitRunStarted(project: project, effort: effort, prompt: prompt)

        Task {
            guard attentionPreferences.systemNotificationsEnabled else { return }
            notificationsAvailable = await attention.requestNotificationPermissionIfNeeded()
            if !notificationsAvailable {
                notice = "macOS notifications are denied. Aiflow will still show attention requests in the widget."
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
                    self.persistTerminalHandoff(
                        outcome: .failed,
                        errorMessage: "Codex could not be started"
                    )
                    self.clearActiveRunContextAfterTerminalRelease()
                }
            }
        }
    }

    private var effectivePrompt: String {
        manualRecoveryDraft?.prompt ?? clipboardPrompt
    }

    /// Starts a new normal run only after the user confirms it in the existing confirmation
    /// panel. This intentionally never resumes or reuses an ambiguous automatic follow-up.
    func requestManualRecoveryRun(_ record: ReviewLoopReadModel.Record) {
        guard let evidence = manualRecoveryEvidence(for: record) else {
            notice = "A new manual run cannot be prepared from this review."
            return
        }

        let prompt = """
        Manual review recovery for Aiflow source run \(record.sourceRunId).

        This is a new user-confirmed run. Do not assume an earlier automatic follow-up was not received.

        Codex Instruction:
        \(evidence.instruction)
        """
        guard prompt.lengthOfBytes(using: .utf8) <= 32 * 1024 else {
            notice = "The recovery instruction is too large for a safe manual run."
            return
        }

        manualRecoveryDraft = ManualRecoveryDraft(
            sourceRunId: record.sourceRunId,
            forbiddenFollowUpRunId: evidence.dispatch.followUpRunId,
            prompt: prompt
        )
        runState = .confirming(evidence.project)
        notice = "Confirm a new manual run; the ambiguous follow-up will not be replayed."
    }

    func canStartManualRecoveryRun(_ record: ReviewLoopReadModel.Record) -> Bool {
        manualRecoveryEvidence(for: record) != nil
    }

    private func manualRecoveryEvidence(
        for record: ReviewLoopReadModel.Record
    ) -> (dispatch: ChatGPTReviewDispatch, instruction: String, project: SavedProject)? {
        guard record.needsManualAttention,
              !runState.isBusy,
              resolvedModelId != nil,
              let evidence = try? correlatedReviewEvidence(for: record.sourceRunId),
              let parsed = try? ChatGPTReviewParser.parse(evidence.review),
              case .changesRequested(let instruction, _) = parsed,
              let project = store.project(withPath: evidence.handoff.project.path),
              project.id == evidence.handoff.project.id,
              project.name == evidence.handoff.project.name,
              project.path == evidence.handoff.project.path,
              project.exists else { return nil }
        return (evidence.dispatch, instruction, project)
    }

    /// Resolves the return destination at dispatch time.
    ///
    /// An explicitly assigned project Return Chat is authoritative. Only when a
    /// project has no assignment do we fall back to the currently detected browser
    /// conversation. Once resolved, the caller snapshots this target into the active
    /// handoff context, so changing tabs or mappings mid-run cannot retarget the run.
    func sourceChatTargetForRun(
        _ project: SavedProject
    ) -> RunResultHandoff.ChatTarget? {
        if let assigned = map.chatURL(forProjectPath: project.path) {
            // A stored assignment is authoritative. If it is somehow corrupt,
            // fail closed rather than silently sending to another active chat.
            guard let normalized = ChatURL.normalize(assigned) else {
                return nil
            }

            return RunResultHandoff.ChatTarget(
                url: normalized,
                conversationId: ChatURL.conversationID(from: normalized)
            )
        }

        let detected = detectChat()
        let normalized = ChatURL.normalize(detected)
        chatURL = normalized

        guard let normalized else { return nil }

        return RunResultHandoff.ChatTarget(
            url: normalized,
            conversationId: ChatURL.conversationID(from: normalized)
        )
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
            if case .cancelling = runState { return }
            let request = ApprovalRequest(
                    id: id, kind: kind, summary: summary, detail: detail,
                    projectName: project.name, permissionProfile: permissionProfile)
            if shouldAutoApproveLegacyRequest {
                if case .respondingToRequest = runState {
                    return  // Never replay or replace an unresolved automatic decision.
                }
                if case .waitingForApproval = runState {
                    return  // Never auto-decide while a manual request remains pending.
                }
                runState = .respondingToRequest(request.id)
                sendApprovalDecision(request, allow: true)
                return
            }
            runState = .waitingForApproval(request)
            emit(.approvalRequested(request))
            attention.deliver(.approvalRequired(
                requestId: request.id.notificationValue,
                projectName: project.name
            ))

        case .inputRequested(let id, let questions):
            let request = UserQuestion(
                id: id, questions: questions, projectName: project.name)
            runState = .waitingForInput(request)
            emit(.questionRequested(request))
            attention.deliver(.manualActionRequired(
                runId: attentionRunID(for: project),
                projectName: project.name,
                category: .question,
                requestId: request.id.notificationValue,
                reason: "Codex needs your input."
            ))

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
            persistTerminalHandoff(
                outcome: .completed,
                finalMessage: lastMessage
            )
            var completed = BridgeEvent(type: .runCompleted)
            completed.runState = runState.bridgeName
            completed.project = project.name
            completed.message = lastMessage
            emit(completed)
            attention.deliver(.codexCompleted(
                runId: attentionRunID(for: project),
                projectName: project.name
            ))
            finishSession()

        case .cancelled:
            runState = .cancelled(project)
            persistTerminalHandoff(outcome: .cancelled)
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
            persistTerminalHandoff(
                outcome: .failed,
                errorMessage: detail
            )
            var failed = BridgeEvent(type: .runFailed)
            failed.runState = runState.bridgeName
            failed.project = project.name
            failed.message = detail
            emit(failed)
            attention.deliver(.codexFailed(
                runId: attentionRunID(for: project),
                projectName: project.name
            ))
            finishSession()
        }
    }

    /// Sends the user's explicit decision. Typed legacy auto-approval is handled separately;
    /// questions and unsupported official-worker requests always remain user-mediated.
    /// The run stays blocked on this exact request until Codex confirms it resolved it.
    func respondToApproval(allow: Bool) {
        guard case .waitingForApproval(let request) = runState, runningProject != nil else {
            return
        }
        notifications.removePendingRequest(id: request.id)
        runState = .respondingToRequest(request.id)
        sendApprovalDecision(request, allow: allow)
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

    private func persistTerminalHandoff(
        outcome: RunResultHandoff.Outcome,
        finalMessage: String? = nil,
        errorMessage: String? = nil
    ) {
        guard
            let context = activeHandoffContext,
            context.runId == activeRunId,
            let sourceChat = context.sourceChat,
            let worker = activeWorker
        else { return }

        let handoff = RunResultHandoff(
            runId: context.runId,
            outcome: outcome,
            project: .init(
                id: context.project.id,
                name: context.project.name,
                path: context.project.path
            ),
            sourceChat: sourceChat,
            execution: .init(
                worker: worker.rawValue,
                modelRole: context.modelRole,
                modelId: context.modelId,
                effort: context.effort,
                codexConversationId: context.codexConversationId,
                codexTurnId: context.codexTurnId
            ),
            result: .init(
                finalMessage: finalMessage,
                errorMessage: errorMessage
            ),
            startedAt: context.startedAt,
            finishedAt: now()
        )

        do {
            try handoffStore.persist(handoff)
        } catch {
            notice = "Aiflow could not save the ChatGPT result handoff."
        }
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
        activeHandoffContext = nil
        Task { await finishing?.stop() }
        resumePendingReviewDispatches()
    }

    private var shouldAutoApproveLegacyRequest: Bool {
        approvalHandling == .autoApprove &&
            activeWorker == .legacyAppServer &&
            runningProject != nil &&
            (approvalResponseSender != nil || client != nil)
    }

    private func sendApprovalDecision(_ request: ApprovalRequest, allow: Bool) {
        if let approvalResponseSender {
            approvalResponseSender(request, allow)
        } else {
            Task { await client?.respondToApproval(request, allow: allow) }
        }
    }

    private func clearActiveRunContextAfterTerminalRelease() {
        activeRunId = nil
        activeWorker = nil
        runningProject = nil
        activeHandoffContext = nil
    }

    // MARK: - Companion bridge

    /// Wires the app-lifetime bridge to this view model. The view model stays the single
    /// source of truth; the bridge only mirrors it outward and forwards commands inward.
    func attachBridge(_ bridge: AiflowBridgeServer) {
        self.bridge = bridge
        bridge.controller = self
        bridge.start()
        reconcileDurableReviewsAndResume()
    }

    /// Idempotent: the popover's `.task` can run many times, but only one server is created.
    func startCompanionBridgeIfNeeded() {
        guard bridge == nil else { return }
        attachBridge(AiflowBridgeServer())
    }

    /// Starts the browser-facing result transport once for the app lifetime.
    /// This channel can only read pending result handoffs and acknowledge
    /// exact run ids as delivered.
    func startHandoffTransportIfNeeded() {
        guard handoffTransportServer == nil else { return }

        let server = HandoffTransportServer(
            store: handoffStore,
            reviewStore: reviewStore,
            onReviewPersisted: { [weak self] review in
                Task { @MainActor in self?.handlePersistedReview(review) }
            }
        )

        handoffTransportServer = server

        if !server.start() {
            notice = "Aiflow result transport could not start."
        }
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
            if let runId = activeRunId {
                do {
                    try reviewDispatchStore.markDispatched(followUpRunId: runId)
                    refreshReviewLoopStatus()
                } catch {
                    stopAutomaticReviewDispatch("Aiflow could not persist the accepted follow-up.")
                }
            }

        case .workerThread:
            // The official conversation/turn now executing this run. Recorded for the status
            // line only; the official Codex UI is where the conversation itself is visible.
            if let conversationId = command.conversationId {
                activeHandoffContext?.codexConversationId = conversationId
            }
            if let turnId = command.turnId {
                activeHandoffContext?.codexTurnId = turnId
            }
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
            persistTerminalHandoff(
                outcome: .completed,
                finalMessage: command.message
            )
            attention.deliver(.codexCompleted(runId: runId, projectName: project.name))
            finishWorkerRun()

        case .workerFailed:
            let detail = command.message ?? "official Codex worker failed"
            // If the official path is unusable, stop preferring it so the next run falls back
            // to Aiflow's own worker. The failure stays visible rather than silently retried.
            if detail.hasPrefix("extension_unavailable") || detail.hasPrefix("ipc_unavailable") {
                officialWorkerAvailable = false
            }
            runState = .failed(project: project, message: detail)
            persistTerminalHandoff(
                outcome: .failed,
                errorMessage: detail
            )
            attention.deliver(.codexFailed(runId: runId, projectName: project.name))
            finishWorkerRun()

        case .workerCancelled:
            runState = .cancelled(project)
            persistTerminalHandoff(outcome: .cancelled)
            attention.deliver(.codexCancelled(runId: runId, projectName: project.name))
            finishWorkerRun()

        default:
            break
        }
    }

    private func handlePersistedReview(_ review: ChatGPTReview) {
        defer { refreshReviewLoopStatus() }
        guard !reviewAutomationBlocked else { return }
        do {
            _ = try reviewStore.allReviews()
            _ = try reviewDispatchStore.allRecords()
            try prepareDispatchForPersistedReview(review)
            resumePendingReviewDispatches()
        } catch {
            stopAutomaticReviewDispatch("Aiflow review evidence needs manual attention.")
        }
    }

    private func reconcileDurableReviewsAndResume() {
        defer { refreshReviewLoopStatus() }
        guard !reviewAutomationBlocked else { return }
        do {
            let reviews = try reviewStore.allReviews()
            _ = try reviewDispatchStore.allRecords()
            try reviewDispatchStore.markAmbiguousDispatchesForManualAttention()
            var knownSourceRunIds = Set(try reviewDispatchStore.allRecords().map(\.sourceRunId))
            for review in reviews where !knownSourceRunIds.contains(review.runId) {
                try prepareDispatchForPersistedReview(review)
                knownSourceRunIds.insert(review.runId)
            }
            resumePendingReviewDispatches()
        } catch {
            stopAutomaticReviewDispatch("Aiflow review recovery stopped on unreadable evidence.")
        }
    }

    private func prepareDispatchForPersistedReview(_ review: ChatGPTReview) throws {
        guard try reviewDispatchStore.record(sourceRunId: review.runId) == nil else { return }
        guard let handoff = try handoffStore.validatedDeliveredHandoff(runId: review.runId),
              handoff.sourceChat.conversationId == review.conversationId else {
            throw ChatGPTReviewAutomationError.evidenceMismatch(
                "review does not match its delivered handoff"
            )
        }

        let parsed: ParsedChatGPTReview
        do {
            parsed = try ChatGPTReviewParser.parse(review)
        } catch {
            try persistReviewDispatch(
                review: review, handoff: handoff, verdict: "INVALID", instruction: nil,
                state: .manualAttention, reason: "review format is not an unambiguous implementation review"
            )
            return
        }

        switch parsed {
        case .ship:
            try persistReviewDispatch(
                review: review, handoff: handoff, verdict: "SHIP", instruction: nil,
                state: .stopped, reason: "ChatGPT review shipped the result"
            )
        case let .changesRequested(instruction, recommendation):
            guard handoff.execution.worker == RunWorker.officialVSCode.rawValue,
                  let codexConversationId = handoff.execution.codexConversationId,
                  !codexConversationId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let project = store.project(withPath: handoff.project.path),
                  project.id == handoff.project.id,
                  project.name == handoff.project.name else {
                try persistReviewDispatch(
                    review: review, handoff: handoff, verdict: "CHANGES_REQUESTED", instruction: instruction,
                    state: .manualAttention, reason: "the original official worker/project/conversation is unavailable",
                    recommendation: recommendation
                )
                return
            }

            let parentDepth = try reviewDispatchStore.parentDepth(for: review.runId)
            let depth = parentDepth + 1
            guard depth <= Self.maximumReviewFollowups else {
                try persistReviewDispatch(
                    review: review, handoff: handoff, verdict: "CHANGES_REQUESTED", instruction: instruction,
                    state: .manualAttention, reason: "automatic follow-up limit reached",
                    lineageDepth: parentDepth, recommendation: recommendation
                )
                return
            }
            if followUpRoutingMode == .chatGPT {
                guard let recommendation else {
                    try persistReviewDispatch(
                        review: review, handoff: handoff, verdict: "CHANGES_REQUESTED", instruction: instruction,
                        state: .manualAttention,
                        reason: "ChatGPT routing requires Codex Execution evidence."
                    )
                    return
                }
                guard let config,
                      config.model(forRole: recommendation.modelRole) != nil,
                      config.reasoningEfforts.contains(recommendation.effort) else {
                    try persistReviewDispatch(
                        review: review, handoff: handoff, verdict: "CHANGES_REQUESTED", instruction: instruction,
                        state: .manualAttention,
                        reason: "ChatGPT routing recommendation is not supported by current Aiflow configuration.",
                        recommendation: recommendation
                    )
                    return
                }
            }
            let dispatch = ChatGPTReviewDispatch(
                schemaVersion: ChatGPTReviewDispatch.currentSchemaVersion,
                sourceRunId: review.runId,
                conversationId: review.conversationId,
                reviewCapturedAt: review.capturedAt,
                assistantMessage: review.assistantMessage,
                verdict: "CHANGES_REQUESTED",
                instruction: instruction,
                followUpRunId: UUID().uuidString,
                parentRunId: review.runId,
                project: handoff.project,
                codexConversationId: codexConversationId,
                modelRole: handoff.execution.modelRole,
                modelId: handoff.execution.modelId,
                effort: handoff.execution.effort,
                recommendedModelRole: recommendation?.modelRole,
                recommendedEffort: recommendation?.effort,
                usesRecommendedExecution: followUpRoutingMode == .chatGPT,
                lineageDepth: depth,
                state: .pending,
                createdAt: now(),
                updatedAt: now(),
                terminalReason: nil
            )
            try reviewDispatchStore.prepare(dispatch)
            attention.deliver(.reviewChangesRequested(
                sourceRunId: review.runId,
                projectName: handoff.project.name
            ))
            refreshReviewLoopStatus()
        }
    }

    private func persistReviewDispatch(
        review: ChatGPTReview, handoff: RunResultHandoff, verdict: String, instruction: String?,
        state: ChatGPTReviewDispatchState, reason: String, lineageDepth: Int? = nil,
        recommendation: ChatGPTReviewExecutionRecommendation? = nil
    ) throws {
        let resolvedDepth: Int
        if let lineageDepth {
            resolvedDepth = lineageDepth
        } else {
            resolvedDepth = try reviewDispatchStore.parentDepth(for: review.runId)
        }
        let dispatch = ChatGPTReviewDispatch(
            schemaVersion: ChatGPTReviewDispatch.currentSchemaVersion,
            sourceRunId: review.runId,
            conversationId: review.conversationId,
            reviewCapturedAt: review.capturedAt,
            assistantMessage: review.assistantMessage,
            verdict: verdict,
            instruction: instruction,
            followUpRunId: nil,
            parentRunId: nil,
            project: handoff.project,
            codexConversationId: handoff.execution.codexConversationId ?? "",
            modelRole: handoff.execution.modelRole,
            modelId: handoff.execution.modelId,
            effort: handoff.execution.effort,
            recommendedModelRole: recommendation?.modelRole,
            recommendedEffort: recommendation?.effort,
            usesRecommendedExecution: false,
            lineageDepth: resolvedDepth,
            state: state,
            createdAt: now(),
            updatedAt: now(),
            terminalReason: reason
        )
        try reviewDispatchStore.prepare(dispatch)
        if state == .stopped || state == .manualAttention {
            notifyReviewTerminalState(dispatch)
        }
        refreshReviewLoopStatus()
    }

    private func resumePendingReviewDispatches() {
        guard !reviewAutomationBlocked, !runState.isBusy, officialWorkerAvailable else { return }
        guard reviewFollowupSender != nil || bridge?.hasDesignatedWorker == true else { return }

        let dispatch: ChatGPTReviewDispatch
        do {
            guard let pending = try reviewDispatchStore.pendingRecords().first else { return }
            dispatch = pending
        } catch {
            stopAutomaticReviewDispatch("Aiflow dispatch state is unreadable.")
            return
        }

        let evidence: (
            followUpRunId: String, instruction: String, project: SavedProject,
            modelRole: String, modelId: String, effort: String
        )
        do {
            evidence = try validatedExecutionEvidence(for: dispatch)
        } catch ChatGPTReviewAutomationError.evidenceMismatch(let reason) {
            moveToManualAttention(dispatch, reason: reason)
            return
        } catch {
            stopAutomaticReviewDispatch("Aiflow immutable review evidence is unreadable.")
            return
        }

        let prompt = """
        Follow-up review pass for Aiflow run \(evidence.followUpRunId).
        Preserve the correct existing work and address only the findings below. Do not broaden scope, reset, discard, commit, push, merge, rewrite history, expose secrets, weaken tests, or request danger-full-access. Validate the requested change, do not claim tests you did not run, and stop/report any unsafe conflict.

        Codex Instruction:
        \(evidence.instruction)

        Finish with changed files, findings addressed, tests run, unresolved risks, and git status.
        """
        guard prompt.lengthOfBytes(using: .utf8) <= 32 * 1024 else {
            moveToManualAttention(dispatch, reason: "bounded follow-up envelope exceeded")
            return
        }

        do {
            try reviewDispatchStore.update(sourceRunId: dispatch.sourceRunId, state: .dispatching)
            guard try reviewDispatchStore.record(sourceRunId: dispatch.sourceRunId)?.state
                == .dispatching else {
                throw ChatGPTReviewDispatchStoreError.writeVerificationFailed
            }
            refreshReviewLoopStatus()
        } catch {
            stopAutomaticReviewDispatch("Aiflow could not persist follow-up dispatch intent.")
            return
        }

        runningProject = evidence.project
        runState = .launching(evidence.project)
        activeWorker = .officialVSCode
        activeRunId = evidence.followUpRunId
        activeHandoffContext = ActiveRunHandoffContext(
            runId: evidence.followUpRunId, project: evidence.project,
            sourceChat: .init(url: "https://chatgpt.com/c/\(dispatch.conversationId)", conversationId: dispatch.conversationId),
            modelRole: evidence.modelRole, modelId: evidence.modelId, effort: evidence.effort,
            startedAt: now(), codexConversationId: dispatch.codexConversationId, codexTurnId: nil
        )

        let event = BridgeEvent.executeFollowup(
            runId: evidence.followUpRunId, parentRunId: dispatch.sourceRunId,
            project: evidence.project,
            conversationId: dispatch.codexConversationId, prompt: prompt,
            model: evidence.modelRole, effort: evidence.effort
        )
        let sent = reviewFollowupSender?(event) ?? bridge?.sendToWorker(event) ?? false
        if !sent {
            moveToManualAttention(dispatch, reason: "follow-up dispatch outcome was ambiguous")
            clearActiveRunContextAfterTerminalRelease()
        }
    }

    private func validatedExecutionEvidence(
        for dispatch: ChatGPTReviewDispatch
    ) throws -> (
        followUpRunId: String, instruction: String, project: SavedProject,
        modelRole: String, modelId: String, effort: String
    ) {
        guard let review = try reviewStore.validatedReview(runId: dispatch.sourceRunId),
              let handoff = try handoffStore.validatedDeliveredHandoff(
                runId: dispatch.sourceRunId
              ),
              review.runId == dispatch.sourceRunId,
              review.conversationId == dispatch.conversationId,
              handoff.runId == dispatch.sourceRunId,
              handoff.sourceChat.conversationId == review.conversationId,
              review.assistantMessage == dispatch.assistantMessage,
              review.capturedAt == dispatch.reviewCapturedAt,
              handoff.execution.worker == RunWorker.officialVSCode.rawValue,
              handoff.project == dispatch.project,
              let project = store.project(withPath: handoff.project.path),
              project.id == handoff.project.id,
              project.name == handoff.project.name,
              let handoffConversationId = handoff.execution.codexConversationId,
              !handoffConversationId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              handoffConversationId == dispatch.codexConversationId,
              handoff.execution.modelRole == dispatch.modelRole,
              handoff.execution.modelId == dispatch.modelId,
              handoff.execution.effort == dispatch.effort,
              let followUpRunId = dispatch.followUpRunId,
              UUID(uuidString: followUpRunId) != nil,
              dispatch.parentRunId == dispatch.sourceRunId,
              dispatch.lineageDepth > 0,
              dispatch.lineageDepth <= Self.maximumReviewFollowups,
              try reviewDispatchStore.parentDepth(for: dispatch.sourceRunId) + 1
                == dispatch.lineageDepth else {
            throw ChatGPTReviewAutomationError.evidenceMismatch(
                "dispatch no longer matches immutable review, handoff, project, or lineage evidence"
            )
        }

        guard case let .changesRequested(parsedInstruction, recommendation) = try ChatGPTReviewParser.parse(review),
              dispatch.verdict == "CHANGES_REQUESTED",
              dispatch.instruction == parsedInstruction,
              dispatch.recommendedModelRole == recommendation?.modelRole,
              dispatch.recommendedEffort == recommendation?.effort else {
            throw ChatGPTReviewAutomationError.evidenceMismatch(
                "dispatch instruction no longer matches the immutable review"
            )
        }
        if dispatch.usesRecommendedExecution == true {
            guard let recommendation,
                  let config,
                  let model = config.model(forRole: recommendation.modelRole),
                  config.reasoningEfforts.contains(recommendation.effort) else {
                throw ChatGPTReviewAutomationError.evidenceMismatch(
                    "persisted ChatGPT routing recommendation is no longer supported"
                )
            }
            return (
                followUpRunId, parsedInstruction, project,
                recommendation.modelRole, model.modelId, recommendation.effort
            )
        }
        return (
            followUpRunId, parsedInstruction, project,
            dispatch.modelRole, dispatch.modelId, dispatch.effort
        )
    }

    private func moveToManualAttention(
        _ dispatch: ChatGPTReviewDispatch,
        reason: String
    ) {
        do {
            try reviewDispatchStore.update(
                sourceRunId: dispatch.sourceRunId,
                state: .manualAttention,
                reason: reason
            )
            notice = "Aiflow review follow-up requires manual attention."
            refreshReviewLoopStatus()
            if let updated = try reviewDispatchStore.record(sourceRunId: dispatch.sourceRunId) {
                notifyReviewTerminalState(updated, reason: reason)
            }
        } catch {
            stopAutomaticReviewDispatch("Aiflow could not persist manual-attention state.")
        }
    }

    private func stopAutomaticReviewDispatch(_ message: String) {
        reviewAutomationBlocked = true
        notice = String(message.prefix(240))
        reviewAutomationBlockReason = notice
        refreshReviewLoopStatus()
        notifyReviewAutomationBlockedIfNeeded(notice)
    }

    private func refreshReviewLoopStatus() {
        do {
            let evidence = try reviewLoopEvidenceSnapshot()
            let snapshot = ReviewLoopReadModel.make(
                reviews: evidence.reviews,
                dispatches: evidence.dispatches
            )
            recentReviewLoopRecords = snapshot.records
            reviewManualAttentionCount = snapshot.manualAttentionCount
            hasQueuedAutomaticReviewFollowUp = snapshot.hasQueuedFollowUp
            currentReviewLoopStatus = snapshot.records.first(where: {
                !$0.needsManualAttention || !dismissedReviewWarningIDs.contains($0.id)
            }) ?? snapshot.current
        } catch {
            recentReviewLoopRecords = []
            currentReviewLoopStatus = nil
            reviewManualAttentionCount = 0
            hasQueuedAutomaticReviewFollowUp = false
            reviewAutomationBlocked = true
            reviewAutomationBlockReason = "Review evidence could not be validated. Resolve the underlying file problem, then recheck evidence."
        }
    }

    func recheckReviewEvidence() {
        do {
            _ = try reviewLoopEvidenceSnapshot()
            reviewAutomationBlocked = false
            reviewAutomationBlockReason = nil
            reconcileDurableReviewsAndResume()
            notice = "Review evidence passed revalidation."
        } catch {
            reviewAutomationBlocked = true
            reviewAutomationBlockReason = "Review evidence is still unreadable or inconsistent."
            notice = reviewAutomationBlockReason ?? "Review evidence needs attention."
        }
        refreshReviewLoopStatus()
    }

    func dismissReviewWarning(_ record: ReviewLoopReadModel.Record) {
        dismissedReviewWarningIDs.insert(record.id)
        defaults.set(
            Array(dismissedReviewWarningIDs).sorted(),
            forKey: Self.dismissedReviewWarningsKey
        )
        refreshReviewLoopStatus()
    }

    func openReviewConversation(_ record: ReviewLoopReadModel.Record) {
        guard let url = URL(string: "https://chatgpt.com/c/\(record.conversationId)") else { return }
        NSWorkspace.shared.open(url)
    }

    func revealReviewEvidence(_ record: ReviewLoopReadModel.Record) {
        let urls = [
            try? reviewStore.evidenceURL(runId: record.sourceRunId),
            try? reviewDispatchStore.evidenceURL(sourceRunId: record.sourceRunId),
            try? handoffStore.deliveredEvidenceURL(runId: record.sourceRunId),
        ]
        .compactMap { $0 }
        .filter { FileManager.default.fileExists(atPath: $0.path) }

        guard !urls.isEmpty else {
            notice = "No immutable review evidence file is currently available to reveal."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func copyReviewSourceRunID(_ record: ReviewLoopReadModel.Record) {
        copyToPasteboard(record.sourceRunId, notice: "Copied source run ID.")
    }

    func copyReviewInstruction(_ record: ReviewLoopReadModel.Record) {
        do {
            let evidence = try correlatedReviewEvidence(for: record.sourceRunId)
            guard case .changesRequested(let instruction, _) = try ChatGPTReviewParser.parse(evidence.review)
            else {
                notice = "No follow-up instruction is available for this review."
                return
            }
            copyToPasteboard(instruction, notice: "Copied follow-up instruction.")
        } catch {
            notice = "Review evidence is inconsistent; instruction was not copied."
        }
    }

    private func reviewLoopEvidenceSnapshot() throws -> (
        reviews: [ChatGPTReview], dispatches: [ChatGPTReviewDispatch]
    ) {
        let reviews = try reviewStore.allReviews()
        let dispatches = try reviewDispatchStore.allRecords()
        try ReviewLoopEvidenceValidator.validate(
            reviews: reviews,
            dispatches: dispatches,
            handoffForRunId: { try handoffStore.validatedDeliveredHandoff(runId: $0) },
            followUpHandoffForRunId: { try handoffStore.validatedHandoff(runId: $0) }
        )
        return (reviews, dispatches)
    }

    private func correlatedReviewEvidence(for sourceRunId: String) throws -> (
        review: ChatGPTReview, dispatch: ChatGPTReviewDispatch, handoff: RunResultHandoff
    ) {
        guard let review = try reviewStore.validatedReview(runId: sourceRunId),
              let dispatch = try reviewDispatchStore.record(sourceRunId: sourceRunId),
              let handoff = try handoffStore.validatedDeliveredHandoff(runId: sourceRunId) else {
            throw ReviewLoopEvidenceError.inconsistentEvidence
        }
        let followUpHandoff: RunResultHandoff?
        if let followUpRunId = dispatch.followUpRunId {
            followUpHandoff = try handoffStore.validatedHandoff(runId: followUpRunId)
        } else {
            followUpHandoff = nil
        }
        try ReviewLoopEvidenceValidator.validate(
            review: review,
            dispatch: dispatch,
            handoff: handoff,
            followUpHandoff: followUpHandoff
        )
        return (review, dispatch, handoff)
    }

    private func copyToPasteboard(_ value: String, notice: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        self.notice = notice
    }

    private func notifyReviewTerminalState(
        _ dispatch: ChatGPTReviewDispatch,
        reason: String? = nil
    ) {
        if dispatch.state == .stopped, dispatch.verdict == "SHIP" {
            attention.deliver(.reviewShipped(
                sourceRunId: dispatch.sourceRunId,
                projectName: dispatch.project.name
            ))
        } else if dispatch.state == .manualAttention {
            attention.deliver(.reviewManualAttention(
                sourceRunId: dispatch.sourceRunId,
                projectName: dispatch.project.name,
                reason: reason ?? dispatch.terminalReason ?? "Review requires manual attention."
            ))
        }
    }

    private func notifyReviewAutomationBlockedIfNeeded(_ reason: String) {
        attention.deliver(.reviewAutomationBlocked(reason: reason))
    }

    private func attentionRunID(for project: SavedProject) -> String {
        activeRunId ?? activeHandoffContext?.runId ?? "\(project.path):\(now().timeIntervalSince1970)"
    }

    private func finishWorkerRun() {
        if let runId = activeRunId {
            do {
                try reviewDispatchStore.markCompleted(followUpRunId: runId)
                refreshReviewLoopStatus()
            } catch {
                stopAutomaticReviewDispatch("Aiflow could not persist follow-up completion.")
            }
        }
        clearActiveRunContextAfterTerminalRelease()
        resumePendingReviewDispatches()
    }

    /// Records what the companion reports about official Codex availability.
    func setOfficialWorkerAvailable(_ available: Bool) {
        officialWorkerAvailable = available
        if available { resumePendingReviewDispatches() }
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
    func reconcileReviewsForTesting() {
        reconcileDurableReviewsAndResume()
    }

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
    func startRunForTesting(
        _ project: SavedProject,
        worker: RunWorker,
        runId: String,
        sourceChatURL: String? = nil,
        modelRole: String = "terra",
        modelId: String = "gpt-5.6-terra",
        effort: String = "low",
        startedAt: Date = Date()
    ) {
        let normalizedSourceChat = sourceChatURL.flatMap(ChatURL.normalize)
        chatURL = normalizedSourceChat
        runningProject = project
        activeWorker = worker
        activeRunId = runId
        runState = .running(project)
        lastMessage = ""
        activeHandoffContext = ActiveRunHandoffContext(
            runId: runId,
            project: project,
            sourceChat: normalizedSourceChat.map {
                .init(url: $0, conversationId: ChatURL.conversationID(from: $0))
            },
            modelRole: modelRole,
            modelId: modelId,
            effort: effort,
            startedAt: startedAt
        )
    }

    func setNotificationsAvailableForTesting(_ available: Bool) {
        notificationsAvailable = available
        var preferences = attentionPreferences
        preferences.systemNotificationsEnabled = available
        updateAttentionPreferences(preferences)
    }
}
