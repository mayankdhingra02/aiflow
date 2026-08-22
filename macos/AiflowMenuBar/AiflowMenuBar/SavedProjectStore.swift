import Foundation

/// The single boundary for every file Aiflow owns under Application Support.
///
/// The unit-test bundle is application-hosted, so the app lifecycle and `WidgetViewModel.shared`
/// run before individual tests can inject temporary stores. XCTest must therefore be detected at
/// this boundary rather than in test setup. All default stores share one process-local temporary
/// root in tests, while production continues to use Application Support/Aiflow.
enum AiflowStorageRoot {
    private static let directoryName = "Aiflow"

    static var isRunningUnderXCTest: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    static let isolatedTestRootURL: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "Aiflow-XCTest-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)",
            isDirectory: true
        )

    static var productionRootURL: URL {
        productionRoot(
            applicationSupportDirectory: FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        )
    }

    static var currentRootURL: URL {
        let resolved = resolve(
            applicationSupportDirectory: productionRootURL.deletingLastPathComponent(),
            isRunningUnderXCTest: isRunningUnderXCTest,
            isolatedTestRoot: isolatedTestRootURL
        )
        assertSafeForCurrentProcess(resolved)
        return resolved
    }

    static func productionRoot(applicationSupportDirectory: URL) -> URL {
        applicationSupportDirectory.appendingPathComponent(directoryName, isDirectory: true)
    }

    static func resolve(
        applicationSupportDirectory: URL,
        isRunningUnderXCTest: Bool,
        isolatedTestRoot: URL
    ) -> URL {
        isRunningUnderXCTest
            ? isolatedTestRoot
            : productionRoot(applicationSupportDirectory: applicationSupportDirectory)
    }

    static func url(_ relativePath: String, isDirectory: Bool = false) -> URL {
        let target = currentRootURL.appendingPathComponent(
            relativePath,
            isDirectory: isDirectory
        )
        assertSafeForCurrentProcess(target)
        return target
    }

    static func isContained(_ target: URL, in root: URL) -> Bool {
        let targetComponents = target.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let rootComponents = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard targetComponents.count >= rootComponents.count else { return false }
        return Array(targetComponents.prefix(rootComponents.count)) == rootComponents
    }

    static func isSafeForCurrentProcess(_ target: URL) -> Bool {
        isSafe(
            target,
            isRunningUnderXCTest: isRunningUnderXCTest,
            productionRoot: productionRootURL
        )
    }

    static func isSafe(
        _ target: URL,
        isRunningUnderXCTest: Bool,
        productionRoot: URL
    ) -> Bool {
        !isRunningUnderXCTest || !isContained(target, in: productionRoot)
    }

    static func assertSafeForCurrentProcess(
        _ target: URL,
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        precondition(
            isSafeForCurrentProcess(target),
            "XCTest attempted to access production Aiflow storage: \(target.path)",
            file: file,
            line: line
        )
    }

    static let isolatedTestDefaults: UserDefaults = {
        let suite = "local.aiflow.menubar.xctest.\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString)"
        return UserDefaults(suiteName: suite) ?? UserDefaults()
    }()

    static func defaultUserDefaults() -> UserDefaults {
        isRunningUnderXCTest ? isolatedTestDefaults : .standard
    }
}

/// Loads/saves the one-click project list as JSON under Application Support.
///
/// Deliberately a plain inspectable file rather than the Aiflow SQLite database: the saved
/// list belongs to this Mac utility, not to the Python workflow. Removing a project here
/// only forgets it — it never touches the repository on disk.
final class SavedProjectStore {
    private(set) var projects: [SavedProject] = []
    private(set) var loadError: String?

    let fileURL: URL

    static func defaultFileURL() -> URL {
        AiflowStorageRoot.url("saved-projects.json")
    }

    init(fileURL: URL = SavedProjectStore.defaultFileURL()) {
        AiflowStorageRoot.assertSafeForCurrentProcess(fileURL)
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
