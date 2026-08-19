import XCTest

@testable import AiflowMenuBar

final class ChatProjectMapTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiflow-map-tests-\(UUID().uuidString)/map.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        super.tearDown()
    }

    func testSaveAndReadBackInSameInstance() {
        let map = ChatProjectMap(fileURL: fileURL)
        map.setMapping(chatURL: "https://chatgpt.com/c/abc", projectPath: "/repos/ef")

        XCTAssertEqual(map.projectPath(for: "https://chatgpt.com/c/abc"), "/repos/ef")
    }

    func testMappingPersistsAcrossInstances() {
        let first = ChatProjectMap(fileURL: fileURL)
        first.setMapping(chatURL: "https://chatgpt.com/c/abc", projectPath: "/repos/ef")

        let reloaded = ChatProjectMap(fileURL: fileURL)

        XCTAssertEqual(reloaded.projectPath(for: "https://chatgpt.com/c/abc"), "/repos/ef")
    }

    func testUpdatingAMappingReplacesThePath() {
        let map = ChatProjectMap(fileURL: fileURL)
        map.setMapping(chatURL: "https://chatgpt.com/c/abc", projectPath: "/repos/ef")
        map.setMapping(chatURL: "https://chatgpt.com/c/abc", projectPath: "/repos/viz")

        XCTAssertEqual(map.projectPath(for: "https://chatgpt.com/c/abc"), "/repos/viz")
        XCTAssertEqual(ChatProjectMap(fileURL: fileURL).mappings.count, 1)
    }

    func testRemovingAMapping() {
        let map = ChatProjectMap(fileURL: fileURL)
        map.setMapping(chatURL: "https://chatgpt.com/c/abc", projectPath: "/repos/ef")
        map.removeMapping(chatURL: "https://chatgpt.com/c/abc")

        XCTAssertNil(map.projectPath(for: "https://chatgpt.com/c/abc"))
        XCTAssertNil(ChatProjectMap(fileURL: fileURL).projectPath(for: "https://chatgpt.com/c/abc"))
    }

    func testDifferentConversationsMapToDifferentRepositories() {
        let map = ChatProjectMap(fileURL: fileURL)
        map.setMapping(chatURL: "https://chatgpt.com/c/abc", projectPath: "/repos/ef")
        map.setMapping(chatURL: "https://chatgpt.com/c/xyz", projectPath: "/repos/viz")

        XCTAssertEqual(map.projectPath(for: "https://chatgpt.com/c/abc"), "/repos/ef")
        XCTAssertEqual(map.projectPath(for: "https://chatgpt.com/c/xyz"), "/repos/viz")
    }

    func testUnknownConversationHasNoMapping() {
        XCTAssertNil(ChatProjectMap(fileURL: fileURL).projectPath(for: "https://chatgpt.com/c/nope"))
    }

    func testMissingFileLoadsEmptyRatherThanCrashing() {
        XCTAssertTrue(ChatProjectMap(fileURL: fileURL).mappings.isEmpty)
    }
}
