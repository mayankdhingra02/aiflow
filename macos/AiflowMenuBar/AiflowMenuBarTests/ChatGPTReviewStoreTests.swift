import XCTest

@testable import AiflowMenuBar

final class ChatGPTReviewStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("aiflow-review-store-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testReviewRoundTrips() throws {
        let store = ChatGPTReviewStore(directoryURL: directory)
        let review = sampleReview()
        try store.persist(review)
        XCTAssertEqual(store.review(runId: review.runId), review)
    }

    func testInvalidRunIdIsRejected() {
        let store = ChatGPTReviewStore(directoryURL: directory)
        XCTAssertThrowsError(try store.persist(sampleReview(runId: "../bad"))) {
            XCTAssertEqual($0 as? ChatGPTReviewStoreError, .invalidRunId)
        }
    }

    func testIdenticalPersistIsIdempotentAndConflictFails() throws {
        let store = ChatGPTReviewStore(directoryURL: directory)
        let review = sampleReview()
        try store.persist(review)
        XCTAssertNoThrow(try store.persist(review))
        XCTAssertThrowsError(try store.persist(sampleReview(runId: review.runId, message: "different"))) {
            XCTAssertEqual($0 as? ChatGPTReviewStoreError, .conflictingExistingRecord)
        }
    }

    func testMalformedExistingRecordIsNotOverwritten() throws {
        let store = ChatGPTReviewStore(directoryURL: directory)
        let review = sampleReview()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(review.runId).json")
        let malformed = Data("not valid JSON".utf8)
        try malformed.write(to: url)

        XCTAssertThrowsError(try store.persist(review)) {
            XCTAssertEqual($0 as? ChatGPTReviewStoreError, .unreadableExistingRecord)
        }
        XCTAssertEqual(try Data(contentsOf: url), malformed)
    }

    func testDirectoryAndFilePermissionsArePrivate() throws {
        let store = ChatGPTReviewStore(directoryURL: directory)
        let review = sampleReview()
        try store.persist(review)
        let directoryPermissions = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)
        let filePermissions = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("\(review.runId).json").path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(directoryPermissions.int16Value, 0o700)
        XCTAssertEqual(filePermissions.int16Value, 0o600)
    }

    private func sampleReview(runId: String = UUID().uuidString, message: String = "Looks good.") -> ChatGPTReview {
        ChatGPTReview(runId: runId, conversationId: "chat-one", sourceChatURL: "https://chatgpt.com/c/chat-one", assistantMessage: message, capturedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }
}
