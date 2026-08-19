import Foundation

/// Locates the `codex` executable. A menu-bar app launched from Finder does not inherit a
/// login shell's PATH, so PATH is scanned explicitly and known install locations are
/// checked as a fallback. No `which`, no shell.
enum CodexLocator {
    /// Known install locations, including the copy bundled inside the ChatGPT desktop app —
    /// which is where Codex lives when only the desktop app is installed.
    static var knownPaths: [String] {
        [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(NSHomeDirectory())/.local/bin/codex",
            "\(NSHomeDirectory())/.bun/bin/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "\(NSHomeDirectory())/Applications/ChatGPT.app/Contents/Resources/codex",
        ]
    }

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutableFile: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        if let override = environment["AIFLOW_CODEX_PATH"], !override.isEmpty,
            isExecutableFile(override)
        {
            return URL(fileURLWithPath: override)
        }

        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = "\(directory)/codex"
            if isExecutableFile(candidate) { return URL(fileURLWithPath: candidate) }
        }

        for candidate in knownPaths where isExecutableFile(candidate) {
            return URL(fileURLWithPath: candidate)
        }

        return nil
    }
}
