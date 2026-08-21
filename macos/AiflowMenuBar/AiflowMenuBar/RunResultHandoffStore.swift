import Foundation

enum RunResultHandoffStoreError: Error, Equatable {
    case invalidRunId
    case conflictingExistingRecord
    case conflictingDeliveredRecord
    case handoffNotFound
    case unreadableDeliveredRecord
    case invalidDeliveredRecord
}

/// Durable local outbox for terminal Aiflow results.
///
/// Pending records are immutable. Delivery moves the exact JSON file from
/// `pending` to `delivered`; a delivered record is also immutable.
final class RunResultHandoffStore {
    let directoryURL: URL
    let deliveredDirectoryURL: URL

    static func defaultBaseDirectoryURL() -> URL {
        let base =
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())

        return base.appendingPathComponent(
            "Aiflow/handoffs",
            isDirectory: true
        )
    }

    static func defaultDirectoryURL() -> URL {
        defaultBaseDirectoryURL().appendingPathComponent(
            "pending",
            isDirectory: true
        )
    }

    static func defaultDeliveredDirectoryURL() -> URL {
        defaultBaseDirectoryURL().appendingPathComponent(
            "delivered",
            isDirectory: true
        )
    }

    init(
        directoryURL: URL = RunResultHandoffStore.defaultDirectoryURL(),
        deliveredDirectoryURL: URL? = nil
    ) {
        self.directoryURL = directoryURL

        if let deliveredDirectoryURL {
            self.deliveredDirectoryURL = deliveredDirectoryURL
        } else if directoryURL.standardizedFileURL
            == RunResultHandoffStore.defaultDirectoryURL().standardizedFileURL
        {
            self.deliveredDirectoryURL =
                RunResultHandoffStore.defaultDeliveredDirectoryURL()
        } else {
            self.deliveredDirectoryURL = directoryURL.appendingPathComponent(
                "delivered",
                isDirectory: true
            )
        }
    }

    func persist(_ handoff: RunResultHandoff) throws {
        guard isValidRunId(handoff.runId) else {
            throw RunResultHandoffStoreError.invalidRunId
        }

        try ensureDirectoryPermissions(at: directoryURL)

        let url = pendingFileURL(for: handoff.runId)
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

        let deliveredURL = deliveredFileURL(for: handoff.runId)

        if FileManager.default.fileExists(atPath: deliveredURL.path) {
            guard
                let deliveredData = try? Data(contentsOf: deliveredURL),
                deliveredData == newData
            else {
                throw RunResultHandoffStoreError.conflictingDeliveredRecord
            }

            return
        }

        try newData.write(to: url, options: .atomic)
        try ensureFilePermissions(at: url)
    }

    func handoff(runId: String) -> RunResultHandoff? {
        guard isValidRunId(runId) else {
            return nil
        }

        return decode(from: pendingFileURL(for: runId))
    }

    func deliveredHandoff(runId: String) -> RunResultHandoff? {
        guard isValidRunId(runId) else {
            return nil
        }

        return decode(from: deliveredFileURL(for: runId))
    }

    /// A dispatch boundary must distinguish missing evidence from unreadable evidence.
    func validatedDeliveredHandoff(runId: String) throws -> RunResultHandoff? {
        guard isValidRunId(runId) else {
            throw RunResultHandoffStoreError.invalidRunId
        }
        return try validatedHandoff(
            at: deliveredFileURL(for: runId),
            runId: runId,
            unreadableError: .unreadableDeliveredRecord,
            invalidError: .invalidDeliveredRecord
        )
    }

    /// Reads immutable terminal evidence across the pending-to-delivered move without silently
    /// accepting corruption in either location. This is for evidence validation only; delivery
    /// ownership remains with `markDelivered`.
    func validatedHandoff(runId: String) throws -> RunResultHandoff? {
        guard isValidRunId(runId) else {
            throw RunResultHandoffStoreError.invalidRunId
        }
        let pending = try validatedHandoff(
            at: pendingFileURL(for: runId),
            runId: runId,
            unreadableError: .unreadableDeliveredRecord,
            invalidError: .invalidDeliveredRecord
        )
        let delivered = try validatedHandoff(
            at: deliveredFileURL(for: runId),
            runId: runId,
            unreadableError: .unreadableDeliveredRecord,
            invalidError: .invalidDeliveredRecord
        )

        switch (pending, delivered) {
        case (nil, nil):
            return nil
        case let (handoff?, nil), let (nil, handoff?):
            return handoff
        case let (pending?, delivered?) where pending == delivered:
            return delivered
        case (.some, .some):
            throw RunResultHandoffStoreError.conflictingDeliveredRecord
        }
    }

    func pendingHandoffs() -> [RunResultHandoff] {
        loadHandoffs(from: directoryURL)
    }

    func deliveredHandoffs() -> [RunResultHandoff] {
        loadHandoffs(from: deliveredDirectoryURL)
    }

    /// Read-only diagnostic location for immutable delivered handoff evidence.
    func deliveredEvidenceURL(runId: String) throws -> URL {
        guard isValidRunId(runId) else { throw RunResultHandoffStoreError.invalidRunId }
        return deliveredFileURL(for: runId)
    }

    /// Marks one exact run as delivered.
    ///
    /// This is idempotent. If the pending record has already been moved to
    /// `delivered`, calling this again succeeds without creating another copy.
    func markDelivered(runId: String) throws {
        guard isValidRunId(runId) else {
            throw RunResultHandoffStoreError.invalidRunId
        }

        let pendingURL = pendingFileURL(for: runId)
        let deliveredURL = deliveredFileURL(for: runId)

        try ensureDirectoryPermissions(at: directoryURL)
        try ensureDirectoryPermissions(at: deliveredDirectoryURL)

        let pendingExists =
            FileManager.default.fileExists(atPath: pendingURL.path)
        let deliveredExists =
            FileManager.default.fileExists(atPath: deliveredURL.path)

        if deliveredExists {
            guard let deliveredData = try? Data(contentsOf: deliveredURL) else {
                throw RunResultHandoffStoreError.conflictingDeliveredRecord
            }

            if pendingExists {
                guard
                    let pendingData = try? Data(contentsOf: pendingURL),
                    pendingData == deliveredData
                else {
                    throw RunResultHandoffStoreError.conflictingDeliveredRecord
                }

                try FileManager.default.removeItem(at: pendingURL)
            }

            try ensureFilePermissions(at: deliveredURL)
            return
        }

        guard pendingExists else {
            throw RunResultHandoffStoreError.handoffNotFound
        }

        try FileManager.default.moveItem(
            at: pendingURL,
            to: deliveredURL
        )

        try ensureFilePermissions(at: deliveredURL)
    }

    private func loadHandoffs(from directory: URL) -> [RunResultHandoff] {
        guard
            let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
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

    private func isValidRunId(_ runId: String) -> Bool {
        UUID(uuidString: runId) != nil
    }

    private func pendingFileURL(for runId: String) -> URL {
        directoryURL.appendingPathComponent(
            "\(runId).json",
            isDirectory: false
        )
    }

    private func deliveredFileURL(for runId: String) -> URL {
        deliveredDirectoryURL.appendingPathComponent(
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
        return try? decoder.decode(
            RunResultHandoff.self,
            from: data
        )
    }

    private func validatedHandoff(
        at url: URL,
        runId: String,
        unreadableError: RunResultHandoffStoreError,
        invalidError: RunResultHandoffStoreError
    ) throws -> RunResultHandoff? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let handoff: RunResultHandoff
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            handoff = try decoder.decode(RunResultHandoff.self, from: Data(contentsOf: url))
        } catch {
            throw unreadableError
        }
        guard handoff.schemaVersion == RunResultHandoff.currentSchemaVersion,
              handoff.runId == runId else {
            throw invalidError
        }
        return handoff
    }

    private func ensureDirectoryPermissions(at directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }

    private func ensureFilePermissions(at url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}
