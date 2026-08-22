import XCTest

@testable import AiflowMenuBar

final class SavedProjectStoreTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiflow-store-\(UUID().uuidString)/saved-projects.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        super.tearDown()
    }

    func testMissingFileLoadsEmpty() {
        let store = SavedProjectStore(fileURL: fileURL)

        XCTAssertTrue(store.projects.isEmpty)
        XCTAssertNil(store.loadError)
    }

    func testAddProjectUsesFolderBasenameByDefault() {
        let store = SavedProjectStore(fileURL: fileURL)
        let (project, isNew) = store.add(path: "/Users/me/Desktop/Engineeringfoundry")

        XCTAssertTrue(isNew)
        XCTAssertEqual(project.name, "Engineeringfoundry")
        XCTAssertEqual(project.path, "/Users/me/Desktop/Engineeringfoundry")
    }

    func testPersistsAcrossInstances() {
        let first = SavedProjectStore(fileURL: fileURL)
        first.add(path: "/repos/ef")
        first.add(path: "/repos/viz")

        let reloaded = SavedProjectStore(fileURL: fileURL)

        XCTAssertEqual(reloaded.projects.map(\.path), ["/repos/ef", "/repos/viz"])
        XCTAssertEqual(reloaded.projects.map(\.name), ["ef", "viz"])
    }

    func testDuplicatePathIsNotAddedTwice() {
        let store = SavedProjectStore(fileURL: fileURL)
        let (first, firstIsNew) = store.add(path: "/repos/ef")
        let (second, secondIsNew) = store.add(path: "/repos/ef")

        XCTAssertTrue(firstIsNew)
        XCTAssertFalse(secondIsNew)
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(store.projects.count, 1)
    }

    func testRenamePersists() {
        let store = SavedProjectStore(fileURL: fileURL)
        let (project, _) = store.add(path: "/repos/ef")
        store.rename(id: project.id, to: "Engineering Foundry")

        XCTAssertEqual(store.projects.first?.name, "Engineering Foundry")
        XCTAssertEqual(SavedProjectStore(fileURL: fileURL).projects.first?.name,
                       "Engineering Foundry")
    }

    func testRenameToBlankIsIgnored() {
        let store = SavedProjectStore(fileURL: fileURL)
        let (project, _) = store.add(path: "/repos/ef")
        store.rename(id: project.id, to: "   ")

        XCTAssertEqual(store.projects.first?.name, "ef")
    }

    func testRemovePersists() {
        let store = SavedProjectStore(fileURL: fileURL)
        let (project, _) = store.add(path: "/repos/ef")
        store.add(path: "/repos/viz")
        store.remove(id: project.id)

        XCTAssertEqual(store.projects.map(\.path), ["/repos/viz"])
        XCTAssertEqual(SavedProjectStore(fileURL: fileURL).projects.map(\.path), ["/repos/viz"])
    }

    func testLookupByPath() {
        let store = SavedProjectStore(fileURL: fileURL)
        store.add(path: "/repos/ef")

        XCTAssertEqual(store.project(withPath: "/repos/ef")?.name, "ef")
        XCTAssertNil(store.project(withPath: "/repos/nope"))
    }

    func testMalformedFileFailsGracefullyWithoutCrashing() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: fileURL)

        let store = SavedProjectStore(fileURL: fileURL)

        XCTAssertTrue(store.projects.isEmpty)
        XCTAssertNotNil(store.loadError)
        // The unreadable file is preserved rather than silently overwritten.
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testDefaultNameHelper() {
        XCTAssertEqual(
            SavedProject.defaultName(for: "/Users/me/Desktop/Engineeringfoundry"),
            "Engineeringfoundry")
    }
}

@MainActor
final class StorageIsolationTests: XCTestCase {
    func testXCTestDefaultRootIsIsolatedFromProductionApplicationSupport() {
        XCTAssertTrue(AiflowStorageRoot.isRunningUnderXCTest)
        XCTAssertNotEqual(
            AiflowStorageRoot.currentRootURL.standardizedFileURL,
            AiflowStorageRoot.productionRootURL.standardizedFileURL
        )
        XCTAssertTrue(
            AiflowStorageRoot.isContained(
                AiflowStorageRoot.currentRootURL,
                in: FileManager.default.temporaryDirectory
            )
        )
        XCTAssertFalse(
            AiflowStorageRoot.isSafeForCurrentProcess(
                AiflowStorageRoot.productionRootURL.appendingPathComponent("sentinel")
            )
        )
    }

    func testDefaultReviewStoresResolveInsideOneIsolatedRoot() {
        let reviewStore = ChatGPTReviewStore()
        let dispatchStore = ChatGPTReviewDispatchStore()

        XCTAssertTrue(
            AiflowStorageRoot.isContained(
                reviewStore.directoryURL,
                in: AiflowStorageRoot.currentRootURL
            )
        )
        XCTAssertTrue(
            AiflowStorageRoot.isContained(
                dispatchStore.directoryURL,
                in: AiflowStorageRoot.currentRootURL
            )
        )
    }

    func testDefaultHandoffRoutingAndTokenStoresResolveInsideOneIsolatedRoot() {
        let handoffStore = RunResultHandoffStore()
        let routingStore = CodexInitialRoutingStore()
        let urls = [
            handoffStore.directoryURL,
            handoffStore.deliveredDirectoryURL,
            routingStore.directoryURL,
            BridgeToken.defaultFileURL(),
            HandoffToken.defaultFileURL(),
        ]

        XCTAssertTrue(urls.allSatisfy {
            AiflowStorageRoot.isContained($0, in: AiflowStorageRoot.currentRootURL)
        })
    }

    func testDefaultAndSharedViewModelsCannotResolveProductionStorage() {
        let defaultViewModel = WidgetViewModel(
            notifications: StorageIsolationNotifications(),
            clipboardString: { nil }
        )
        let urls = defaultViewModel.persistentStorageURLsForTesting
            + WidgetViewModel.shared.persistentStorageURLsForTesting

        XCTAssertFalse(urls.isEmpty)
        XCTAssertTrue(urls.allSatisfy {
            AiflowStorageRoot.isContained($0, in: AiflowStorageRoot.currentRootURL)
        })
        XCTAssertTrue(urls.allSatisfy {
            !AiflowStorageRoot.isContained($0, in: AiflowStorageRoot.productionRootURL)
        })
    }

    func testTestResolutionLeavesSentinelProductionTreeUntouched() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiflow-storage-boundary-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let applicationSupport = root.appendingPathComponent("Application Support")
        let production = AiflowStorageRoot.productionRoot(
            applicationSupportDirectory: applicationSupport
        )
        let sentinel = production.appendingPathComponent("sentinel")
        let isolated = root.appendingPathComponent("isolated", isDirectory: true)
        try FileManager.default.createDirectory(at: production, withIntermediateDirectories: true)
        try Data("immutable".utf8).write(to: sentinel)
        let before = try Data(contentsOf: sentinel)

        let resolved = AiflowStorageRoot.resolve(
            applicationSupportDirectory: applicationSupport,
            isRunningUnderXCTest: true,
            isolatedTestRoot: isolated
        )
        let store = SavedProjectStore(
            fileURL: resolved.appendingPathComponent("saved-projects.json")
        )
        _ = store.add(path: "/tmp/isolated-project")

        XCTAssertEqual(resolved.standardizedFileURL, isolated.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: sentinel), before)
        XCTAssertFalse(
            AiflowStorageRoot.isSafe(
                sentinel,
                isRunningUnderXCTest: true,
                productionRoot: production
            )
        )
    }

    func testExplicitTemporaryStoreInjectionStillWins() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiflow-explicit-stores-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let handoffStore = RunResultHandoffStore(
            directoryURL: root.appendingPathComponent("handoffs/pending"),
            deliveredDirectoryURL: root.appendingPathComponent("handoffs/delivered")
        )
        let viewModel = WidgetViewModel(
            store: SavedProjectStore(fileURL: root.appendingPathComponent("saved.json")),
            map: ChatProjectMap(fileURL: root.appendingPathComponent("map.json")),
            defaults: UserDefaults(suiteName: "aiflow.explicit.\(UUID().uuidString)")!,
            notifications: StorageIsolationNotifications(),
            handoffStore: handoffStore,
            reviewStore: ChatGPTReviewStore(directoryURL: root.appendingPathComponent("reviews")),
            reviewDispatchStore: ChatGPTReviewDispatchStore(
                directoryURL: root.appendingPathComponent("dispatches")
            ),
            initialRoutingStore: CodexInitialRoutingStore(
                directoryURL: root.appendingPathComponent("routing")
            ),
            clipboardString: { nil }
        )

        XCTAssertTrue(viewModel.persistentStorageURLsForTesting.allSatisfy {
            AiflowStorageRoot.isContained($0, in: root)
                || $0 == BridgeToken.defaultFileURL()
                || $0 == HandoffToken.defaultFileURL()
        })
    }

    func testPureProductionResolutionUsesApplicationSupportAiflow() {
        let applicationSupport = URL(fileURLWithPath: "/Users/example/Library/Application Support")
        let resolved = AiflowStorageRoot.resolve(
            applicationSupportDirectory: applicationSupport,
            isRunningUnderXCTest: false,
            isolatedTestRoot: URL(fileURLWithPath: "/private/tmp/ignored")
        )

        XCTAssertEqual(
            resolved.standardizedFileURL.path,
            applicationSupport.appendingPathComponent("Aiflow").standardizedFileURL.path
        )
    }
}

@MainActor
private final class StorageIsolationNotifications: NotificationManaging {
    func prepareForRun() async -> Bool { false }
    func sendApproval(for request: ApprovalRequest) {}
    func sendQuestion(for question: UserQuestion) {}
    func sendCompletion(for project: SavedProject) {}
    func sendFailure(for project: SavedProject?) {}
    func removePendingRequest(id: CodexRequestID) {}
}
