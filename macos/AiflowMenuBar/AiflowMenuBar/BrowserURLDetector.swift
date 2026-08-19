import Foundation

/// Reads the active tab's URL from a running browser via AppleScript.
///
/// Only the URL is read — no page content, no DOM, no automation of the page itself.
/// Each script is a fixed string with nothing interpolated into it, and is run through
/// `/usr/bin/osascript` with an argument array (never a shell).
///
/// Both scripts check `application "X" is running` first, because a bare `tell application`
/// would otherwise launch that browser.
enum BrowserURLDetector {
    static let chromeScript = """
        if application "Google Chrome" is running then
            tell application "Google Chrome"
                if (count of windows) > 0 then
                    return URL of active tab of front window
                end if
            end tell
        end if
        return ""
        """

    static let safariScript = """
        if application "Safari" is running then
            tell application "Safari"
                if (count of documents) > 0 then
                    return URL of front document
                end if
            end tell
        end if
        return ""
        """

    /// Returns the first ChatGPT conversation URL found, checking Chrome then Safari.
    /// Returns nil when no browser is running, no window is open, or the active tab is
    /// simply not a ChatGPT conversation — all of which are ordinary, not errors.
    static func detectChatURL(
        runScript: (String) -> String? = runOsascript
    ) -> String? {
        for script in [chromeScript, safariScript] {
            if let normalized = ChatURL.normalize(runScript(script)) {
                return normalized
            }
        }
        return nil
    }

    static func runOsascript(_ script: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

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
        // Drain stderr so a chatty failure can't wedge the pipe.
        _ = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return nil }

        let output = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? nil : output
    }
}
