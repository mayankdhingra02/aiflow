import XCTest

@testable import AiflowMenuBar

final class RunResultHandoffStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiflow-handoff-store-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testCompletedHandoffRoundTripsWithExactFields() {
        let store = RunResultHandoffStore(directoryURL: directory)
        let runId = UUID().uuidString
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let finishedAt = Date(timeIntervalSince1970: 1_700_000_010)
        let handoff = sampleHandoff(
            runId: runId,
            finalMessage: "done\nall good 🛠",
            startedAt: startedAt,
            finishedAt: finishedAt
        )

        XCTAssertNoThrow(try store.persist(handoff))
        let loaded = store.handoff(runId: runId)

        XCTAssertEqual(loaded, handoff)
        XCTAssertEqual(loaded?.schemaVersion, 1)
        XCTAssertEqual(loaded?.sourceChat.url, "https://chatgpt.com/c/chat-one")
        XCTAssertEqual(loaded?.execution.worker, "official-vscode")
        XCTAssertEqual(loaded?.execution.modelRole, "sol")
        XCTAssertEqual(loaded?.execution.modelId, "gpt-5.6-sol")
        XCTAssertEqual(loaded?.execution.effort, "low")
        XCTAssertEqual(loaded?.execution.codexConversationId, "codex-conversation")
        XCTAssertEqual(loaded?.execution.codexTurnId, "codex-turn")
        XCTAssertEqual(loaded?.result.finalMessage, "done\nall good 🛠")
        XCTAssertNil(loaded?.result.errorMessage)
        XCTAssertEqual(loaded?.startedAt, startedAt)
        XCTAssertEqual(loaded?.finishedAt, finishedAt)
        XCTAssertEqual(
            loaded?.project.id,
            UUID(uuidString: "d0d5a8b1-8ff3-4b7f-a4e2-3adf8d5d5bd1")
        )
    }

    func testPersistedSchemaVersionIsOne() throws {
        let store = RunResultHandoffStore(directoryURL: directory)
        let handoff = sampleHandoff()

        try store.persist(handoff)
        let loaded = try XCTUnwrap(store.handoff(runId: handoff.runId))

        XCTAssertEqual(loaded.schemaVersion, 1)
    }

    func testPersistedDatesAreISO8601Strings() throws {
        let store = RunResultHandoffStore(directoryURL: directory)
        let handoff = sampleHandoff(
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_700_000_001)
        )

        try store.persist(handoff)
        let data = try Data(contentsOf: directory.appendingPathComponent("\(handoff.runId).json"))
        let json = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = json as? [String: Any] else {
            XCTFail("expected dictionary JSON")
            return
        }

        XCTAssertTrue(dictionary["startedAt"] is String)
        XCTAssertTrue(dictionary["finishedAt"] is String)
    }

    func testPendingFilenameIsRunIdJSON() throws {
        let store = RunResultHandoffStore(directoryURL: directory)
        let handoff = sampleHandoff()

        try store.persist(handoff)

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files, ["\(handoff.runId).json"])
    }

    func testFilePermissionsAre0600() throws {
        let store = RunResultHandoffStore(directoryURL: directory)
        let handoff = sampleHandoff()

        try store.persist(handoff)

        let attributes = try FileManager.default.attributesOfItem(atPath: directory
            .appendingPathComponent("\(handoff.runId).json").path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)

        XCTAssertEqual(permissions.int16Value, 0o600)
    }

    func testDirectoryPermissionsAre0700() throws {
        let store = RunResultHandoffStore(directoryURL: directory)
        let handoff = sampleHandoff()

        try store.persist(handoff)

        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)

        XCTAssertEqual(permissions.int16Value, 0o700)
    }

    func testPersistingIdenticalHandoffIsIdempotent() throws {
        let store = RunResultHandoffStore(directoryURL: directory)
        let handoff = sampleHandoff()

        try store.persist(handoff)
        XCTAssertNoThrow(try store.persist(handoff))
        XCTAssertEqual(store.pendingHandoffs().count, 1)
    }

    func testPersistingDifferentHandoffForSameRunIdThrowsConflict() throws {
        let store = RunResultHandoffStore(directoryURL: directory)
        let runId = UUID().uuidString
        let first = sampleHandoff(runId: runId, finalMessage: "first")
        let second = sampleHandoff(
            runId: runId,
            finalMessage: "second")

        try store.persist(first)
        XCTAssertThrowsError(try store.persist(second)) { error in
            XCTAssertEqual(error as? RunResultHandoffStoreError, .conflictingExistingRecord)
        }
    }

    func testInvalidRunIdCannotBePersisted() throws {
        let store = RunResultHandoffStore(directoryURL: directory)
        let invalid = ["../../escape", "abc", "", "../\(UUID().uuidString)"]

        for runId in invalid {
            XCTAssertThrowsError(try store.persist(sampleHandoff(runId: runId))) {
                XCTAssertEqual($0 as? RunResultHandoffStoreError, .invalidRunId)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(runId).json").path))
        }
    }

    func testHandoffLoaderReturnsOnlyExactMatch() throws {
        let store = RunResultHandoffStore(directoryURL: directory)
        let first = sampleHandoff(runId: UUID().uuidString)
        let second = sampleHandoff(runId: UUID().uuidString)

        try store.persist(first)
        try store.persist(second)

        XCTAssertEqual(store.handoff(runId: first.runId)?.runId, first.runId)
        XCTAssertNil(store.handoff(runId: "00000000-0000-0000-0000-000000000000"))
    }

    func testHandoffLoaderReturnsNilForInvalidRunId() throws {
        let store = RunResultHandoffStore(directoryURL: directory)
        let valid = sampleHandoff()

        try store.persist(valid)
        XCTAssertNil(store.handoff(runId: "../\(UUID().uuidString)"))
        XCTAssertNil(store.handoff(runId: "not-a-uuid"))
    }

    func testPendingHandoffsAreDeterministicallyOrdered() throws {
        let store = RunResultHandoffStore(directoryURL: directory)
        let a = sampleHandoff(
            runId: "00000000-0000-0000-0000-0000000000a1",
            sourceChatURL: "https://chatgpt.com/c/first",
            finishedAt: Date(timeIntervalSince1970: 2)
        )
        let b = sampleHandoff(
            runId: "00000000-0000-0000-0000-0000000000b2",
            sourceChatURL: "https://chatgpt.com/c/second",
            finishedAt: Date(timeIntervalSince1970: 1)
        )
        let c = sampleHandoff(
            runId: "00000000-0000-0000-0000-0000000000c3",
            sourceChatURL: "https://chatgpt.com/c/third",
            finishedAt: Date(timeIntervalSince1970: 1)
        )

        try store.persist(a)
        try store.persist(b)
        try store.persist(c)

        let results = store.pendingHandoffs()
        XCTAssertEqual(results.map(\.runId), [b.runId, c.runId, a.runId])
    }

    func testMalformedJsonDoesNotCrashPendingHandoffLoader() throws {
        let store = RunResultHandoffStore(directoryURL: directory)
        let valid = sampleHandoff()

        try store.persist(valid)
        let malformed = directory.appendingPathComponent("bad.json")
        try Data("{ bad json }".utf8).write(to: malformed)

        let results = store.pendingHandoffs()

        XCTAssertEqual(results.map(\.runId), [valid.runId])
    }

    func testPersistedJSONContainsNoPromptFields() throws {
        let store = RunResultHandoffStore(directoryURL: directory)
        let handoff = sampleHandoff()

        try store.persist(handoff)
        let data = try Data(contentsOf: directory.appendingPathComponent("\(handoff.runId).json"))
        let json = try JSONSerialization.jsonObject(with: data)

        XCTAssertFalse(hasForbiddenPromptField(json))
    }

    func testMarkDeliveredMovesPendingHandoff() throws {
        let store = RunResultHandoffStore(directoryURL: directory)
        let handoff = sampleHandoff()

        try store.persist(handoff)

        XCTAssertEqual(
            store.handoff(runId: handoff.runId),
            handoff
        )
        XCTAssertNil(
            store.deliveredHandoff(runId: handoff.runId)
        )

        try store.markDelivered(runId: handoff.runId)

        XCTAssertNil(
            store.handoff(runId: handoff.runId)
        )
        XCTAssertEqual(
            store.deliveredHandoff(runId: handoff.runId),
            handoff
        )
        XCTAssertTrue(store.pendingHandoffs().isEmpty)
        XCTAssertEqual(
            store.deliveredHandoffs().map(\.runId),
            [handoff.runId]
        )
    }

    func testMarkDeliveredIsIdempotent() throws {
        let store = RunResultHandoffStore(directoryURL: directory)
        let handoff = sampleHandoff()

        try store.persist(handoff)
        try store.markDelivered(runId: handoff.runId)

        XCTAssertNoThrow(
            try store.markDelivered(runId: handoff.runId)
        )

        XCTAssertEqual(
            store.deliveredHandoffs().map(\.runId),
            [handoff.runId]
        )
    }

    func testDeliveredFilePermissionsAre0600() throws {
        let store = RunResultHandoffStore(directoryURL: directory)
        let handoff = sampleHandoff()

        try store.persist(handoff)
        try store.markDelivered(runId: handoff.runId)

        let path = store.deliveredDirectoryURL
            .appendingPathComponent("\(handoff.runId).json")
            .path

        let attributes =
            try FileManager.default.attributesOfItem(atPath: path)

        let permissions = try XCTUnwrap(
            attributes[.posixPermissions] as? NSNumber
        )

        XCTAssertEqual(permissions.int16Value, 0o600)
    }

    func testDeliveredDirectoryPermissionsAre0700() throws {
        let store = RunResultHandoffStore(directoryURL: directory)
        let handoff = sampleHandoff()

        try store.persist(handoff)
        try store.markDelivered(runId: handoff.runId)

        let attributes =
            try FileManager.default.attributesOfItem(
                atPath: store.deliveredDirectoryURL.path
            )

        let permissions = try XCTUnwrap(
            attributes[.posixPermissions] as? NSNumber
        )

        XCTAssertEqual(permissions.int16Value, 0o700)
    }

    func testMarkDeliveredRejectsInvalidRunId() {
        let store = RunResultHandoffStore(directoryURL: directory)

        XCTAssertThrowsError(
            try store.markDelivered(runId: "../../escape")
        ) {
            XCTAssertEqual(
                $0 as? RunResultHandoffStoreError,
                .invalidRunId
            )
        }
    }

    func testMarkDeliveredRejectsUnknownRun() {
        let store = RunResultHandoffStore(directoryURL: directory)

        XCTAssertThrowsError(
            try store.markDelivered(
                runId: "00000000-0000-0000-0000-000000000000"
            )
        ) {
            XCTAssertEqual(
                $0 as? RunResultHandoffStoreError,
                .handoffNotFound
            )
        }
    }

    func testPersistAfterDeliveryIsIdempotent() throws {
        let store = RunResultHandoffStore(directoryURL: directory)
        let handoff = sampleHandoff()

        try store.persist(handoff)
        try store.markDelivered(runId: handoff.runId)

        XCTAssertNoThrow(try store.persist(handoff))

        XCTAssertTrue(store.pendingHandoffs().isEmpty)
        XCTAssertEqual(
            store.deliveredHandoffs().map(\.runId),
            [handoff.runId]
        )
    }

    func testDifferentRecordCannotReplaceDeliveredHandoff() throws {
        let store = RunResultHandoffStore(directoryURL: directory)
        let runId = UUID().uuidString

        let first = sampleHandoff(
            runId: runId,
            finalMessage: "first"
        )

        let second = sampleHandoff(
            runId: runId,
            finalMessage: "second"
        )

        try store.persist(first)
        try store.markDelivered(runId: runId)

        XCTAssertThrowsError(try store.persist(second)) {
            XCTAssertEqual(
                $0 as? RunResultHandoffStoreError,
                .conflictingDeliveredRecord
            )
        }

        XCTAssertEqual(
            store.deliveredHandoff(runId: runId),
            first
        )
    }

    private func sampleHandoff(
        runId: String = UUID().uuidString,
        modelRole: String = "sol",
        modelId: String = "gpt-5.6-sol",
        effort: String = "low",
            sourceChatURL: String = "https://chatgpt.com/c/chat-one",
        conversationId: String = "codex-conversation",
        turnId: String = "codex-turn",
        outcome: RunResultHandoff.Outcome = .completed,
        finalMessage: String = "done",
        errorMessage: String? = nil,
        startedAt: Date = Date(timeIntervalSince1970: 1_700_000_010),
        finishedAt: Date = Date(timeIntervalSince1970: 1_700_000_011)
    ) -> RunResultHandoff {
        RunResultHandoff(
            runId: runId,
            outcome: outcome,
            project: .init(
                id: UUID(uuidString: "d0d5a8b1-8ff3-4b7f-a4e2-3adf8d5d5bd1")!,
                name: "demo",
                path: "/repos/demo"
            ),
            sourceChat: .init(
                url: sourceChatURL,
                conversationId: ChatURL.conversationID(from: sourceChatURL)
            ),
            execution: .init(
                worker: "official-vscode",
                modelRole: modelRole,
                modelId: modelId,
                effort: effort,
                codexConversationId: conversationId,
                codexTurnId: turnId
            ),
            result: .init(finalMessage: finalMessage, errorMessage: errorMessage),
            startedAt: startedAt,
            finishedAt: finishedAt
        )
    }

    private func hasForbiddenPromptField(_ json: Any) -> Bool {
        let forbidden: Set<String> = ["prompt", "promptText", "clipboardPrompt", "promptPreview"]

        if let dictionary = json as? [String: Any] {
            for (key, value) in dictionary {
                if forbidden.contains(key) { return true }
                if hasForbiddenPromptField(value) { return true }
            }
            return false
        }

        if let array = json as? [Any] {
            return array.contains(where: hasForbiddenPromptField)
        }

        return false
    }
}
