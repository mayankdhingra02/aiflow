import Foundation

/// Resolves a chosen folder to its Git root using `git -C <path> rev-parse --show-toplevel`,
/// so picking a subdirectory still saves the repository root.
///
/// Always Process + argument array — never a shell string.
enum GitRepositoryValidator {
    enum Result: Equatable {
        case repository(root: String)
        case notARepository
        case missingDirectory
        case gitUnavailable
    }

    static let gitCandidates = [
        "/usr/bin/git",
        "/opt/homebrew/bin/git",
        "/usr/local/bin/git",
    ]

    static func locateGit(
        isExecutableFile: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        gitCandidates.first(where: isExecutableFile).map { URL(fileURLWithPath: $0) }
    }

    static func validate(
        path: String,
        runGit: (String) -> (output: String, exitCode: Int32)? = runGitShowToplevel
    ) -> Result {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return .missingDirectory }

        guard let result = runGit(path) else { return .gitUnavailable }
        guard result.exitCode == 0 else { return .notARepository }

        let root = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { return .notARepository }

        // Resolve symlinks so /tmp and /private/tmp style paths compare equal later.
        return .repository(root: URL(fileURLWithPath: root).resolvingSymlinksInPath().path)
    }

    static func runGitShowToplevel(path: String) -> (output: String, exitCode: Int32)? {
        guard let git = locateGit() else { return nil }

        let process = Process()
        process.executableURL = git
        process.arguments = ["-C", path, "rev-parse", "--show-toplevel"]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        _ = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return (String(decoding: data, as: UTF8.self), process.terminationStatus)
    }
}
