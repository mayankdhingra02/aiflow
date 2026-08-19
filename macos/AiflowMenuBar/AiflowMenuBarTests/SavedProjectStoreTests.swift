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
