import AppKit
import Foundation

@MainActor
final class WidgetViewModel: ObservableObject {
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
        case .ready: return "bolt.horizontal.circle"
        case .launching, .running: return "bolt.horizontal.circle.fill"
        case .waitingForApproval, .waitingForInput: return "exclamationmark.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .confirming: return "bolt.horizontal.circle"
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

        guard let codexURL = CodexLocator.resolve() else {
            runState = .failed(project: project, message: "Codex not installed")
            return
        }

        let prompt = clipboardPrompt  // full clipboard text, never the preview
        let effort = selectedEffort
        let client = CodexAppServerClient()
        self.client = client
        lastMessage = ""
        runningProject = project
        runState = .launching(project)

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

        case .approvalRequested(let id, let kind, let summary, let detail, let permissionProfile):
            let request = ApprovalRequest(
                    id: id, kind: kind, summary: summary, detail: detail,
                    projectName: project.name, permissionProfile: permissionProfile)
            runState = .waitingForApproval(request)
            if !isPopoverVisible && notificationsAvailable { notifications.sendApproval(for: request) }

        case .inputRequested(let id, let questionID, let question):
            let request = UserQuestion(id: id, questionID: questionID, question: question, projectName: project.name)
            runState = .waitingForInput(request)
            if !isPopoverVisible && notificationsAvailable { notifications.sendQuestion(for: request) }

        case .assistantMessage(let text):
            lastMessage = text

        case .finished:
            runState = .completed(project)
            if !isPopoverVisible && notificationsAvailable { notifications.sendCompletion(for: project) }
            finishSession()

        case .failed(let detail):
            runState = .failed(project: project, message: detail)
            if !isPopoverVisible && notificationsAvailable { notifications.sendFailure(for: project) }
            finishSession()
        }
    }

    /// Sends the user's explicit decision. Aiflow never answers an approval on its own.
    func respondToApproval(allow: Bool) {
        guard case .waitingForApproval(let request) = runState, let project = runningProject else {
            return
        }
        notifications.removePendingRequest(id: request.id)
        runState = .running(project)
        Task { await client?.respondToApproval(request, allow: allow) }
    }

    func respondToQuestion(_ answer: String) {
        guard case .waitingForInput(let question) = runState, let project = runningProject else {
            return
        }
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        notifications.removePendingRequest(id: question.id)
        runState = .running(project)
        Task { await client?.respondToInput(question, answer: trimmed) }
    }

    func cancelRun() {
        Task { await client?.cancel() }
        if let request = pendingApproval { notifications.removePendingRequest(id: request.id) }
        if let question = pendingQuestion { notifications.removePendingRequest(id: question.id) }
        runState = .ready
        finishSession()
    }

    private func finishSession() {
        let finishing = client
        client = nil
        runningProject = nil
        Task { await finishing?.stop() }
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

    func setNotificationsAvailableForTesting(_ available: Bool) {
        notificationsAvailable = available
    }
}
