import Foundation

/// Dedicated shared secret for the browser result-transport channel.
///
/// This intentionally does not reuse the VS Code companion's bridge token.
/// A browser extension that knows this value may read and acknowledge result
/// handoffs, but it gains no authority over Codex runs, approvals, or questions.
enum HandoffToken {
    static let fileName = "handoff-token"

    static func defaultFileURL() -> URL {
        AiflowStorageRoot.url(fileName)
    }

    @discardableResult
    static func loadOrCreate(
        at url: URL = defaultFileURL()
    ) -> String? {
        if let existing = load(at: url) {
            return existing
        }

        let token = generate()
        return BridgeToken.write(token, to: url) ? token : nil
    }

    static func load(
        at url: URL = defaultFileURL()
    ) -> String? {
        AiflowStorageRoot.assertSafeForCurrentProcess(url)
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }

        let token = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return token.isEmpty ? nil : token
    }

    static func generate() -> String {
        BridgeToken.generate()
    }

    static func matches(
        _ candidate: String,
        expected: String
    ) -> Bool {
        BridgeToken.matches(candidate, expected: expected)
    }
}
