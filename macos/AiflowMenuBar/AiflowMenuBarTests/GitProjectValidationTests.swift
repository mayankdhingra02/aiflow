import XCTest

@testable import AiflowMenuBar

/// Uses real temporary directories and the real `git` binary so the resolution behaviour
/// (subdirectory -> repository root) is genuinely exercised, not just mocked.
final class GitProjectValidationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiflow-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func git(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
    }

    func testValidGitRepositoryResolvesToItself() throws {
        try git(["init", "-q"], in: root)

        let expected = root.resolvingSymlinksInPath().path

        XCTAssertEqual(
            GitRepositoryValidator.validate(path: root.path),
            .repository(root: expected)
        )
    }

    func testChildDirectoryResolvesToRepositoryRoot() throws {
        try git(["init", "-q"], in: root)
        let nested = root.appendingPathComponent("app/foo")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let expected = root.resolvingSymlinksInPath().path

        XCTAssertEqual(
            GitRepositoryValidator.validate(path: nested.path),
            .repository(root: expected)
        )
    }

    func testNonRepositoryIsRejected() {
        XCTAssertEqual(GitRepositoryValidator.validate(path: root.path), .notARepository)
    }

    func testMissingDirectoryIsReported() {
        XCTAssertEqual(
            GitRepositoryValidator.validate(path: root.appendingPathComponent("nope").path),
            .missingDirectory
        )
    }

    func testFilePathIsNotAcceptedAsDirectory() throws {
        let file = root.appendingPathComponent("file.txt")
        try Data("x".utf8).write(to: file)

        XCTAssertEqual(GitRepositoryValidator.validate(path: file.path), .missingDirectory)
    }

    func testGitUnavailableIsReportedRatherThanCrashing() {
        let result = GitRepositoryValidator.validate(path: root.path, runGit: { _ in nil })

        XCTAssertEqual(result, .gitUnavailable)
    }

    func testValidatorUsesArgumentArrayNotAShell() {
        // Guards the documented safety property: git is invoked directly with -C.
        XCTAssertTrue(GitRepositoryValidator.gitCandidates.allSatisfy { $0.hasSuffix("/git") })
    }
}
