import Foundation

/// Reduces a browser URL to the stable ChatGPT conversation URL used as a mapping key,
/// so query strings, fragments, and GPT-scoped paths don't create duplicate mappings.
///
///     https://chatgpt.com/c/abc123?foo=bar#x  ->  https://chatgpt.com/c/abc123
///     https://chatgpt.com/g/g-xyz/c/abc123    ->  https://chatgpt.com/c/abc123
///     https://example.com/c/abc123            ->  nil
enum ChatURL {
    static let knownHosts: Set<String> = [
        "chatgpt.com",
        "www.chatgpt.com",
        "chat.openai.com",
        "www.chat.openai.com",
    ]

    static func normalize(_ rawURL: String?) -> String? {
        guard let rawURL else { return nil }

        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
            let components = URLComponents(string: trimmed),
            let host = components.host?.lowercased(),
            knownHosts.contains(host)
        else { return nil }

        // Find the "/c/<id>" segment, which may be preceded by a "/g/<gpt-id>" scope.
        let segments = components.path.split(separator: "/").map(String.init)
        guard let markerIndex = segments.firstIndex(of: "c"),
            markerIndex + 1 < segments.count
        else { return nil }

        let conversationID = segments[markerIndex + 1]
        guard !conversationID.isEmpty else { return nil }

        return "https://chatgpt.com/c/\(conversationID)"
    }

    /// The bare conversation id, for compact display in the popover.
    static func conversationID(from normalizedURL: String) -> String {
        normalizedURL.split(separator: "/").last.map(String.init) ?? normalizedURL
    }
}
