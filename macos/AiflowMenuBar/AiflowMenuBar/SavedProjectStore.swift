import Foundation

/// Loads/saves the one-click project list as JSON under Application Support.
///
/// Deliberately a plain inspectable file rather than the Aiflow SQLite database: the saved
/// list belongs to this Mac utility, not to the Python workflow. Removing a project here
/// only forgets it — it never touches the repository on disk.
final class SavedProjectStore {
    private(set) var projects: [SavedProject] = []
    private(set) var loadError: String?

    private let fileURL: URL

    static func defaultFileURL() -> URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Aiflow/saved-projects.json")
    }

    init(fileURL: URL = SavedProjectStore.defaultFileURL()) {
        self.fileURL = fileURL
        load()
    }

    func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            projects = []
            loadError = nil
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            projects = try decoder.decode([SavedProject].self, from: data)
            loadError = nil
        } catch {
            // Keep the bad file rather than clobbering it, and surface the problem.
            projects = []
            loadError = "Saved projects file could not be read"
        }
    }

    /// Adds a project unless its path is already saved. Returns the project occupying
    /// that path either way, so callers can report "already saved".
    @discardableResult
    func add(path: String, name: String? = nil) -> (project: SavedProject, isNew: Bool) {
        if let existing = project(withPath: path) {
            return (existing, false)
        }
        let project = SavedProject(name: name ?? SavedProject.defaultName(for: path), path: path)
        projects.append(project)
        save()
        return (project, true)
    }

    func rename(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = projects.firstIndex(where: { $0.id == id }) else {
            return
        }
        projects[index].name = trimmed
        save()
    }

    func remove(id: UUID) {
        projects.removeAll { $0.id == id }
        save()
    }

    func project(withPath path: String) -> SavedProject? {
        projects.first { $0.path == path }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(projects).write(to: fileURL, options: .atomic)
            loadError = nil
        } catch {
            loadError = "Saved projects could not be written"
        }
    }
}
