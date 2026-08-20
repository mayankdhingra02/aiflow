import XCTest

@testable import AiflowMenuBar

final class HandoffTokenTests: XCTestCase {
    private var directory: URL!
    private var tokenURL: URL!

    override func setUp() {
        super.setUp()

        directory =
            FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "aiflow-handoff-token-\(UUID().uuidString)"
                )

        tokenURL =
            directory.appendingPathComponent(
                "handoff-token"
            )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(
            at: directory
        )

        super.tearDown()
    }

    func testGeneratedTokenIsLongAndRandomLooking() {
        let token = HandoffToken.generate()

        XCTAssertEqual(token.count, 64)
        XCTAssertNotEqual(
            token,
            HandoffToken.generate()
        )
    }

    func testTokenIsCreatedOnceAndReused() throws {
        let first =
            try XCTUnwrap(
                HandoffToken.loadOrCreate(
                    at: tokenURL
                )
            )

        let second =
            try XCTUnwrap(
                HandoffToken.loadOrCreate(
                    at: tokenURL
                )
            )

        XCTAssertEqual(first, second)
        XCTAssertEqual(
            HandoffToken.load(at: tokenURL),
            first
        )
    }

    func testTokenFileIs0600() throws {
        _ = try XCTUnwrap(
            HandoffToken.loadOrCreate(
                at: tokenURL
            )
        )

        let attributes =
            try FileManager.default
                .attributesOfItem(
                    atPath: tokenURL.path
                )

        let permissions =
            try XCTUnwrap(
                attributes[
                    .posixPermissions
                ] as? NSNumber
            )

        XCTAssertEqual(
            permissions.int16Value,
            0o600
        )
    }

    func testMatchesOnlyExactToken() {
        let token =
            HandoffToken.generate()

        XCTAssertTrue(
            HandoffToken.matches(
                token,
                expected: token
            )
        )

        XCTAssertFalse(
            HandoffToken.matches(
                token + "0",
                expected: token
            )
        )

        XCTAssertFalse(
            HandoffToken.matches(
                "",
                expected: token
            )
        )
    }
}
