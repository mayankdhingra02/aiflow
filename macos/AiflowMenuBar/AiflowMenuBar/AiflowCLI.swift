import Foundation

/// The only CLI query this widget makes: the model configuration, so model IDs stay defined
/// once in Python. It never drives the Aiflow task workflow.
enum AiflowCommand: Equatable {
    case modelsJSON

    var arguments: [String] {
        switch self {
        case .modelsJSON:
            return ["models", "--json"]
        }
    }
}

struct CommandResult {
    let arguments: [String]
    let stdout: String
    let stderr: String
    let exitCode: Int32

    var succeeded: Bool { exitCode == 0 }

    /// A clean, human-readable rendering of the CLI's own output for the popover's
    /// "last action" area. The backend prints via Rich, which draws panel borders using
    /// Unicode box-drawing characters even when not attached to a terminal; those are
    /// stripped here so the widget shows the backend's actual message text (including the
    /// existing failure recovery guidance) instead of raw box art.
    var summaryMessage: String {
        let text = stdout.isEmpty ? stderr : stdout

        let cleaned =
            text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { Self.stripBoxDrawing($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        if cleaned.isEmpty {
            return succeeded ? "Done." : "Command failed."
        }

        let limit = 1200
        return cleaned.count > limit ? String(cleaned.prefix(limit)) + "…" : cleaned
    }

    private static let boxDrawingRange: ClosedRange<UInt32> = 0x2500...0x257F

    private static func stripBoxDrawing(_ line: Substring) -> String {
        String(
            String.UnicodeScalarView(
                line.unicodeScalars.filter { !boxDrawingRange.contains($0.value) }
            )
        )
    }
}

enum CLIError: Error, LocalizedError {
    case executableNotFound
    case launchFailed(String)
    case decodingFailed(String)
    case commandFailed(CommandResult)

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "The aiflow CLI could not be found. Set AIFLOW_CLI_PATH to its full path."
        case .launchFailed(let detail):
            return "Failed to launch aiflow: \(detail)"
        case .decodingFailed(let detail):
            return "Could not read aiflow's output: \(detail)"
        case .commandFailed(let result):
            return result.summaryMessage
        }
    }
}

/// Resolves the absolute path to the installed `aiflow` executable. This is a personal,
/// single-machine tool, so a fixed known location plus an environment override is enough —
/// deliberately not a settings screen.
enum AiflowExecutableLocator {
    static let knownInstallPath =
        "/Users/mayankdhingra/Desktop/aiflow-phase1/.venv/bin/aiflow"

    struct Resolution: Equatable {
        let executableURL: URL
        let argumentPrefix: [String]
    }

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutableFile: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> Resolution? {
        if let overridden = environment["AIFLOW_CLI_PATH"], !overridden.isEmpty,
            isExecutableFile(overridden)
        {
            return Resolution(executableURL: URL(fileURLWithPath: overridden), argumentPrefix: [])
        }

        if isExecutableFile(knownInstallPath) {
            return Resolution(
                executableURL: URL(fileURLWithPath: knownInstallPath), argumentPrefix: [])
        }

        if isExecutableFile("/usr/bin/env") {
            return Resolution(
                executableURL: URL(fileURLWithPath: "/usr/bin/env"), argumentPrefix: ["aiflow"])
        }

        return nil
    }
}

/// Thin adapter over the `aiflow` CLI. Captures stdout/stderr/exit status for every
/// invocation and never blocks the caller's thread while a command runs.
actor AiflowCLI {
    static let shared = AiflowCLI()

    private let resolution: AiflowExecutableLocator.Resolution?

    init(resolution: AiflowExecutableLocator.Resolution? = AiflowExecutableLocator.resolve()) {
        self.resolution = resolution
    }

    @discardableResult
    func execute(_ command: AiflowCommand) async throws -> CommandResult {
        guard let resolution else { throw CLIError.executableNotFound }
        let arguments = resolution.argumentPrefix + command.arguments
        return try await Self.run(executableURL: resolution.executableURL, arguments: arguments)
    }

    /// Runs a JSON-producing command and decodes it, throwing `.commandFailed` if the
    /// process exited non-zero rather than attempting to decode error text as JSON.
    func decode<T: Decodable>(_ type: T.Type, from command: AiflowCommand) async throws -> T {
        let result = try await execute(command)
        guard result.succeeded else {
            throw CLIError.commandFailed(result)
        }
        do {
            return try JSONDecoder().decode(T.self, from: Data(result.stdout.utf8))
        } catch {
            throw CLIError.decodingFailed(error.localizedDescription)
        }
    }

    private static func run(executableURL: URL, arguments: [String]) async throws -> CommandResult
    {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let stdoutBuffer = OutputAccumulator()
            let stderrBuffer = OutputAccumulator()

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    stdoutBuffer.append(data)
                }
            }

            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    stderrBuffer.append(data)
                }
            }

            process.terminationHandler = { finished in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                let result = CommandResult(
                    arguments: arguments,
                    stdout: String(decoding: stdoutBuffer.snapshot(), as: UTF8.self),
                    stderr: String(decoding: stderrBuffer.snapshot(), as: UTF8.self),
                    exitCode: finished.terminationStatus
                )
                continuation.resume(returning: result)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: CLIError.launchFailed(error.localizedDescription))
            }
        }
    }
}

/// A small lock-protected buffer for accumulating pipe output read incrementally off the
/// main thread, avoiding the classic full-pipe-buffer deadlock from reading only at exit.
final class OutputAccumulator: @unchecked Sendable {
    private var storage = Data()
    private let lock = NSLock()

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
