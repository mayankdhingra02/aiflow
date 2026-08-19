import Foundation

/// Persists "this ChatGPT conversation belongs to this local repo" as a small JSON file
/// under Application Support. Keys are normalized conversation URLs; values are absolute
/// repository paths.
///
/// Deliberately a plain file rather than the Aiflow SQLite database: the mapping is a
/// property of this Mac utility, not of the Python workflow.
final class ChatProjectMap {
    private(set) var mappings: [String: String] = [:]
    private let fileURL: URL

    static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Aiflow/chat-project-map.json")
    }

    init(fileURL: URL = ChatProjectMap.defaultFileURL()) {
        self.fileURL = fileURL
        load()
    }

    func projectPath(for chatURL: String) -> String? {
        mappings[chatURL]
    }

    func setMapping(chatURL: String, projectPath: String) {
        mappings[chatURL] = projectPath
        save()
    }

    func removeMapping(chatURL: String) {
        mappings.removeValue(forKey: chatURL)
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return }
        mappings = decoded
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(mappings).write(to: fileURL, options: .atomic)
        } catch {
            // A personal utility: a failed write costs the mapping, not the run.
        }
    }
}
