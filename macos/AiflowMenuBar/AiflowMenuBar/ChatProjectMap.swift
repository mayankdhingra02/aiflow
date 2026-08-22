import Foundation

/// Persists "this ChatGPT conversation belongs to this local repo" as a small JSON file
/// under Application Support. Keys are normalized conversation URLs; values are absolute
/// repository paths.
///
/// Deliberately a plain file rather than the Aiflow SQLite database: the mapping is a
/// property of this Mac utility, not of the Python workflow.
final class ChatProjectMap {
    private(set) var mappings: [String: String] = [:]
    let fileURL: URL

    static func defaultFileURL() -> URL {
        AiflowStorageRoot.url("chat-project-map.json")
    }

    init(fileURL: URL = ChatProjectMap.defaultFileURL()) {
        AiflowStorageRoot.assertSafeForCurrentProcess(fileURL)
        self.fileURL = fileURL
        load()
    }

    func projectPath(for chatURL: String) -> String? {
        mappings[chatURL]
    }

    /// The single ChatGPT conversation assigned as this project's return target.
    func chatURL(forProjectPath projectPath: String) -> String? {
        mappings
            .filter { $0.value == projectPath }
            .map(\.key)
            .sorted()
            .first
    }

    /// Assigns one return chat to one project.
    ///
    /// A project may have only one return chat. Reassigning the project removes
    /// any previous chat->project entry for that project. A chat itself also maps
    /// to only one project because the dictionary key is unique.
    func setMapping(chatURL: String, projectPath: String) {
        mappings = mappings.filter { key, value in
            value != projectPath || key == chatURL
        }

        mappings[chatURL] = projectPath
        save()
    }

    func removeMapping(chatURL: String) {
        mappings.removeValue(forKey: chatURL)
        save()
    }

    func removeMapping(forProjectPath projectPath: String) {
        mappings = mappings.filter { $0.value != projectPath }
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
