import Foundation

enum RunResultHandoffStoreError: Error, Equatable {
    case invalidRunId
    case conflictingExistingRecord
}

/// Immutable local outbox for terminal Aiflow results.
///
/// Each run occupies exactly one JSON file. Re-persisting the exact same
/// canonical envelope is idempotent; different evidence for the same run id
/// is rejected rather than overwritten.
final class RunResultHandoffStore {
    let directoryURL: URL

    static func defaultDirectoryURL() -> URL {
        let base =
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())

        return base.appendingPathComponent(
            "Aiflow/handoffs/pending",
            isDirectory: true
        )
    }

    init(
        directoryURL: URL = RunResultHandoffStore.defaultDirectoryURL()
    ) {
        self.directoryURL = directoryURL
    }

    func persist(_ handoff: RunResultHandoff) throws {
        guard UUID(uuidString: handoff.runId) != nil else {
            throw RunResultHandoffStoreError.invalidRunId
        }

        try ensureDirectoryPermissions()

        let url = fileURL(for: handoff.runId)
        let newData = try encode(handoff)

        if FileManager.default.fileExists(atPath: url.path) {
            guard let existingData = try? Data(contentsOf: url) else {
                throw RunResultHandoffStoreError.conflictingExistingRecord
            }

            if existingData == newData {
                try ensureFilePermissions(at: url)
                return
            }

            throw RunResultHandoffStoreError.conflictingExistingRecord
        }

        try newData.write(to: url, options: .atomic)
        try ensureFilePermissions(at: url)
    }

    func handoff(runId: String) -> RunResultHandoff? {
        guard UUID(uuidString: runId) != nil else {
            return nil
        }

        return decode(from: fileURL(for: runId))
    }

    func pendingHandoffs() -> [RunResultHandoff] {
        guard
            let urls = try? FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }

        return urls
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { decode(from: $0) }
            .sorted { lhs, rhs in
                if lhs.finishedAt == rhs.finishedAt {
                    return lhs.runId < rhs.runId
                }
                return lhs.finishedAt < rhs.finishedAt
            }
    }

    private func fileURL(for runId: String) -> URL {
        directoryURL.appendingPathComponent(
            "\(runId).json",
            isDirectory: false
        )
    }

    private func encode(_ handoff: RunResultHandoff) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(handoff)
    }

    private func decode(from url: URL) -> RunResultHandoff? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RunResultHandoff.self, from: data)
    }

    private func ensureDirectoryPermissions() throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
    }

    private func ensureFilePermissions(at url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}
