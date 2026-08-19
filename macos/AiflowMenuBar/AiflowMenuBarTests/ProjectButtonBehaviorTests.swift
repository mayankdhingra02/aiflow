import XCTest

@testable import AiflowMenuBar

@MainActor
final class ProjectButtonBehaviorTests: XCTestCase {
    private var storeURL: URL!
    private var mapURL: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        let unique = UUID().uuidString
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiflow-vm-\(unique)/saved.json")
        mapURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiflow-vm-\(unique)/map.json")
        suiteName = "aiflow.tests.\(unique)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent())
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// A real directory on disk, since starting a run requires the repository to still exist.
    private func makeRealDirectory() throws -> String {
        let url = storeURL.deletingLastPathComponent()
            .appendingPathComponent("repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    /// A view model wired to temporary storage, with a stubbed config so no CLI is spawned.
    private func makeViewModel(
        chatURL: String? = nil,
        gitResult: GitRepositoryValidator.Result = .repository(root: "/repos/ef")
    ) -> WidgetViewModel {
        let viewModel = WidgetViewModel(
            store: SavedProjectStore(fileURL: storeURL),
            map: ChatProjectMap(fileURL: mapURL),
            defaults: defaults,
            detectChat: { chatURL },
            validateGit: { _ in gitResult }
        )
        viewModel.applyConfigForTesting(
            CodexConfig(
                models: [
                    CodexModel(role: "luna", modelId: "gpt-5.6-luna"),
                    CodexModel(role: "terra", modelId: "gpt-5.6-terra"),
                    CodexModel(role: "sol", modelId: "gpt-5.6-sol"),
                ],
                reasoningEfforts: ["low", "medium", "high", "xhigh"],
                defaultSandbox: "workspace-write"
            ))
        return viewModel
    }

    func testDefaultsAreTerraAndMedium() {
        let viewModel = makeViewModel()

        XCTAssertEqual(viewModel.selectedModelRole, "terra")
        XCTAssertEqual(viewModel.selectedEffort, "medium")
        XCTAssertEqual(viewModel.resolvedModelId, "gpt-5.6-terra")
    }

    func testModelAndEffortSelectionPersist() {
        let first = makeViewModel()
        first.selectedModelRole = "sol"
        first.selectedEffort = "xhigh"

        let second = makeViewModel()

        XCTAssertEqual(second.selectedModelRole, "sol")
        XCTAssertEqual(second.selectedEffort, "xhigh")
    }

    func testEmptyClipboardDisablesProjectButtons() {
        let viewModel = makeViewModel()
        viewModel.setPromptForTesting("")

        XCTAssertFalse(viewModel.hasPrompt)
        XCTAssertFalse(viewModel.canRunProjects)
    }

    func testPromptEnablesProjectButtons() {
        let viewModel = makeViewModel()
        viewModel.setPromptForTesting("Fix the navbar")

        XCTAssertTrue(viewModel.canRunProjects)
    }

    func testAddProjectSavesResolvedGitRoot() {
        let viewModel = makeViewModel(gitResult: .repository(root: "/repos/ef"))
        viewModel.addProject(at: "/repos/ef/app/foo")

        XCTAssertEqual(viewModel.savedProjects.map(\.path), ["/repos/ef"])
        XCTAssertEqual(viewModel.savedProjects.first?.name, "ef")
    }

    func testAddingNonRepositoryReportsAndSavesNothing() {
        let viewModel = makeViewModel(gitResult: .notARepository)
        viewModel.addProject(at: "/not/a/repo")

        XCTAssertTrue(viewModel.savedProjects.isEmpty)
        XCTAssertEqual(viewModel.notice, "Selected folder is not a Git repository.")
    }

    func testClickingProjectEntersConfirmingWithoutRunning() throws {
        let path = try makeRealDirectory()
        let viewModel = makeViewModel(gitResult: .repository(root: path))
        viewModel.setPromptForTesting("Fix the navbar")
        viewModel.addProject(at: path)
        let project = viewModel.savedProjects[0]

        viewModel.requestRun(project)

        // Confirmation is mandatory: clicking a project must not start Codex.
        XCTAssertEqual(viewModel.confirmingProject, project)
        XCTAssertFalse(viewModel.runState.isBusy)
    }

    func testCancelConfirmationReturnsToReady() throws {
        let path = try makeRealDirectory()
        let viewModel = makeViewModel(gitResult: .repository(root: path))
        viewModel.setPromptForTesting("Fix the navbar")
        viewModel.addProject(at: path)
        viewModel.requestRun(viewModel.savedProjects[0])

        viewModel.cancelConfirmation()

        XCTAssertNil(viewModel.confirmingProject)
        XCTAssertEqual(viewModel.runState, .ready)
    }

    func testClickingAProjectWhoseFolderIsGoneReportsInsteadOfRunning() {
        let viewModel = makeViewModel(gitResult: .repository(root: "/repos/deleted"))
        viewModel.setPromptForTesting("Fix the navbar")
        viewModel.addProject(at: "/repos/deleted")

        viewModel.requestRun(viewModel.savedProjects[0])

        XCTAssertNil(viewModel.confirmingProject)
        XCTAssertTrue(viewModel.notice.contains("no longer exists"))
    }

    func testClickingProjectWithoutPromptDoesNothing() {
        let viewModel = makeViewModel()
        viewModel.setPromptForTesting("")
        viewModel.addProject(at: "/repos/ef")

        viewModel.requestRun(viewModel.savedProjects[0])

        XCTAssertNil(viewModel.confirmingProject)
    }

    func testSecondRunIsBlockedWhileOneIsActive() {
        let viewModel = makeViewModel()
        viewModel.setPromptForTesting("Fix the navbar")
        viewModel.addProject(at: "/repos/ef")
        let project = viewModel.savedProjects[0]

        viewModel.enterRunningForTesting(project)

        XCTAssertTrue(viewModel.runState.isBusy)
        XCTAssertFalse(viewModel.canRunProjects)

        viewModel.requestRun(project)
        XCTAssertNil(viewModel.confirmingProject)
    }

    func testRemovingProjectOnlyForgetsIt() throws {
        // The repository on disk must survive being removed from the widget.
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiflow-keep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }

        let viewModel = makeViewModel(gitResult: .repository(root: repo.path))
        viewModel.addProject(at: repo.path)
        viewModel.remove(viewModel.savedProjects[0])

        XCTAssertTrue(viewModel.savedProjects.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.path))
    }

    func testRenameUpdatesButtonLabel() {
        let viewModel = makeViewModel()
        viewModel.addProject(at: "/repos/ef")
        viewModel.rename(viewModel.savedProjects[0], to: "Engineering Foundry")

        XCTAssertEqual(viewModel.savedProjects.first?.name, "Engineering Foundry")
    }
}

// MARK: - Chat mapping as a convenience, never a requirement

@MainActor
final class ChatMappingIntegrationTests: XCTestCase {
    private var storeURL: URL!
    private var mapURL: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        let unique = UUID().uuidString
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiflow-map-vm-\(unique)/saved.json")
        mapURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiflow-map-vm-\(unique)/map.json")
        suiteName = "aiflow.tests.map.\(unique)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent())
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeViewModel(chatURL: String?) -> WidgetViewModel {
        let viewModel = WidgetViewModel(
            store: SavedProjectStore(fileURL: storeURL),
            map: ChatProjectMap(fileURL: mapURL),
            defaults: defaults,
            detectChat: { chatURL },
            validateGit: { .repository(root: $0) }
        )
        viewModel.applyConfigForTesting(
            CodexConfig(
                models: [CodexModel(role: "terra", modelId: "gpt-5.6-terra")],
                reasoningEfforts: ["medium"],
                defaultSandbox: "workspace-write"))
        viewModel.refreshChat()
        return viewModel
    }

    func testMappedChatHighlightsCorrectProject() {
        let viewModel = makeViewModel(chatURL: "https://chatgpt.com/c/abc")
        viewModel.addProject(at: "/repos/ef")
        viewModel.addProject(at: "/repos/viz")
        let foundry = viewModel.savedProjects[0]
        let viz = viewModel.savedProjects[1]

        viewModel.mapCurrentChat(to: foundry)

        XCTAssertTrue(viewModel.isMapped(foundry))
        XCTAssertFalse(viewModel.isMapped(viz))
    }

    func testMappingPersistsForTheSameConversation() {
        let first = makeViewModel(chatURL: "https://chatgpt.com/c/abc")
        first.addProject(at: "/repos/ef")
        first.mapCurrentChat(to: first.savedProjects[0])

        let second = makeViewModel(chatURL: "https://chatgpt.com/c/abc")

        XCTAssertTrue(second.isMapped(second.savedProjects[0]))
    }

    func testDifferentConversationsMapToDifferentProjects() {
        let first = makeViewModel(chatURL: "https://chatgpt.com/c/abc")
        first.addProject(at: "/repos/ef")
        first.addProject(at: "/repos/viz")
        first.mapCurrentChat(to: first.savedProjects[0])

        let second = makeViewModel(chatURL: "https://chatgpt.com/c/xyz")
        second.mapCurrentChat(to: second.savedProjects[1])

        XCTAssertTrue(second.isMapped(second.savedProjects[1]))
        XCTAssertFalse(second.isMapped(second.savedProjects[0]))
    }

    func testUnmappedChatDoesNotBlockProjectButtons() throws {
        let repo = mapURL.deletingLastPathComponent().appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)

        let viewModel = makeViewModel(chatURL: nil)
        viewModel.addProject(at: repo.path)
        viewModel.setPromptForTesting("Fix the navbar")

        XCTAssertNil(viewModel.mappedProjectPath)
        XCTAssertTrue(viewModel.canRunProjects)

        viewModel.requestRun(viewModel.savedProjects[0])
        XCTAssertNotNil(viewModel.confirmingProject)
    }

    func testMappingToARemovedProjectIsReportedStale() {
        let viewModel = makeViewModel(chatURL: "https://chatgpt.com/c/abc")
        viewModel.addProject(at: "/repos/ef")
        let project = viewModel.savedProjects[0]
        viewModel.mapCurrentChat(to: project)

        viewModel.remove(project)

        XCTAssertEqual(viewModel.staleMappingPath, "/repos/ef")
    }

    func testUnmapClearsHighlight() {
        let viewModel = makeViewModel(chatURL: "https://chatgpt.com/c/abc")
        viewModel.addProject(at: "/repos/ef")
        viewModel.mapCurrentChat(to: viewModel.savedProjects[0])
        viewModel.unmapCurrentChat()

        XCTAssertFalse(viewModel.isMapped(viewModel.savedProjects[0]))
    }

    func testMappingWithoutADetectedChatIsReportedNotCrashed() {
        let viewModel = makeViewModel(chatURL: nil)
        viewModel.addProject(at: "/repos/ef")
        viewModel.mapCurrentChat(to: viewModel.savedProjects[0])

        XCTAssertEqual(viewModel.notice, "No ChatGPT conversation detected")
    }
}
