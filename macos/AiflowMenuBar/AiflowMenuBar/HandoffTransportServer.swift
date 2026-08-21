import Foundation
import Network

/// Authenticated loopback-only WebSocket transport for result handoffs.
///
/// This transport does not know anything about ChatGPT DOM structure. It only
/// gives one authenticated browser client access to the durable outbox and
/// accepts idempotent delivery acknowledgements.
final class HandoffTransportServer: @unchecked Sendable {
    static let defaultPort: UInt16 = 47322
    static let loopbackHost = "127.0.0.1"

    private let port: UInt16
    private let store: RunResultHandoffStore
    private let reviewStore: ChatGPTReviewStore
    private let token: String?

    private let queue =
        DispatchQueue(label: "aiflow.handoff.transport")

    private let lock = NSLock()
    private var listener: NWListener?
    private var connections:
        [ObjectIdentifier: Connection] = [:]

    /// Exactly one authenticated browser connection may pull handoffs.
    private var activeClientKey: ObjectIdentifier?

    private(set) var lastError: String?

    init(
        port: UInt16 = HandoffTransportServer.defaultPort,
        store: RunResultHandoffStore,
        reviewStore: ChatGPTReviewStore = ChatGPTReviewStore(),
        token: String? = HandoffToken.loadOrCreate()
    ) {
        self.port = port
        self.store = store
        self.reviewStore = reviewStore
        self.token = token
    }

    var boundPort: UInt16 {
        port
    }

    var isListening: Bool {
        lock.lock()
        defer { lock.unlock() }
        return listener != nil
    }

    @discardableResult
    func start() -> Bool {
        guard token != nil else {
            lastError = "handoff token unavailable"
            return false
        }

        lock.lock()
        let alreadyListening = listener != nil
        lock.unlock()

        if alreadyListening {
            return true
        }

        let webSocketOptions = NWProtocolWebSocket.Options()
        webSocketOptions.autoReplyPing = true
        webSocketOptions.maximumMessageSize =
            HandoffTransport.maximumInboundMessageBytes

        webSocketOptions.setClientRequestHandler(queue) {
            _, _ in
            NWProtocolWebSocket.Response(
                status: .accept,
                subprotocol: nil
            )
        }

        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack
            .applicationProtocols
            .insert(webSocketOptions, at: 0)

        parameters.requiredLocalEndpoint =
            NWEndpoint.hostPort(
                host: NWEndpoint.Host(Self.loopbackHost),
                port: NWEndpoint.Port(rawValue: port)!
            )

        parameters.allowLocalEndpointReuse = true

        do {
            let listener = try NWListener(
                using: parameters
            )

            listener.newConnectionHandler = {
                [weak self] connection in
                self?.accept(connection)
            }

            listener.stateUpdateHandler = {
                [weak self] state in

                if case .failed(let error) = state {
                    self?.lastError =
                        error.localizedDescription
                }
            }

            lock.lock()
            self.listener = listener
            lock.unlock()

            listener.start(queue: queue)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func stop() {
        lock.lock()

        let openConnections =
            Array(connections.values)

        connections.removeAll()
        activeClientKey = nil

        listener?.cancel()
        listener = nil

        lock.unlock()

        openConnections.forEach {
            $0.cancel()
        }
    }

    private func accept(
        _ nwConnection: NWConnection
    ) {
        let connection = Connection(
            nwConnection: nwConnection,
            queue: queue
        )

        let key = ObjectIdentifier(connection)

        connection.onReady = {
            [weak self, weak connection] in

            guard
                let self,
                let connection
            else {
                return
            }

            self.send(
                .hello(),
                to: connection
            )
        }

        connection.onData = {
            [weak self, weak connection] data in

            guard
                let self,
                let connection
            else {
                return
            }

            self.receive(
                data: data,
                on: connection,
                key: key
            )
        }

        connection.onClose = {
            [weak self] in

            guard let self else {
                return
            }

            self.lock.lock()
            self.connections.removeValue(
                forKey: key
            )

            if self.activeClientKey == key {
                self.activeClientKey = nil
            }

            self.lock.unlock()
        }

        lock.lock()
        connections[key] = connection
        lock.unlock()

        connection.start()
    }

    private func receive(
        data: Data,
        on connection: Connection,
        key: ObjectIdentifier
    ) {
        guard
            data.count
                <= HandoffTransport
                    .maximumInboundMessageBytes,
            let command =
                HandoffTransportCodec
                    .decodeClientCommand(data)
        else {
            connection.cancel()
            return
        }

        guard connection.isAuthenticated else {
            guard command.type == .auth else {
                return
            }

            guard command.protocolVersion == HandoffTransport.protocolVersion else {
                send(.error("protocol_incompatible"), to: connection)
                return
            }

            guard
                let candidate = command.token,
                let expected = token,
                HandoffToken.matches(
                    candidate,
                    expected: expected
                )
            else {
                // Keep the WebSocket alive long enough to return an
                // explicit authentication error. The client remains
                // unauthenticated and cannot read the outbox.
                send(
                    .error("authentication_failed"),
                    to: connection
                )
                return
            }

            lock.lock()

            let mayBecomeActive =
                activeClientKey == nil
                || activeClientKey == key

            if mayBecomeActive {
                activeClientKey = key
            }

            lock.unlock()

            guard mayBecomeActive else {
                connection.cancel()
                return
            }

            connection.isAuthenticated = true

            send(
                .ready(),
                to: connection
            )

            return
        }

        lock.lock()
        let isActiveClient =
            activeClientKey == key
        lock.unlock()

        guard isActiveClient else {
            connection.cancel()
            return
        }

        switch command.type {
        case .auth:
            send(
                .error("already_authenticated"),
                to: connection
            )

        case .ping:
            send(
                .pong(),
                to: connection
            )

        case .next:
            sendNextHandoff(
                to: connection
            )

        case .delivered:
            acknowledgeDelivery(
                command,
                on: connection
            )

        case .review:
            captureReview(command, on: connection)
        }
    }

    private func sendNextHandoff(
        to connection: Connection
    ) {
        if let runId =
            connection.inFlightRunId
        {
            if let handoff =
                store.handoff(runId: runId)
            {
                send(
                    .handoff(handoff),
                    to: connection
                )
                return
            }

            connection.inFlightRunId = nil
        }

        guard
            let handoff =
                store.pendingHandoffs().first
        else {
            send(
                .empty(),
                to: connection
            )
            return
        }

        connection.inFlightRunId =
            handoff.runId

        send(
            .handoff(handoff),
            to: connection
        )
    }

    private func acknowledgeDelivery(
        _ command: HandoffClientCommand,
        on connection: Connection
    ) {
        guard let runId = command.runId else {
            send(
                .error("missing_run_id"),
                to: connection
            )
            return
        }

        guard UUID(uuidString: runId) != nil else {
            send(
                .error(
                    "invalid_run_id",
                    runId: runId
                ),
                to: connection
            )
            return
        }

        if let inFlight =
            connection.inFlightRunId,
            inFlight != runId
        {
            send(
                .error(
                    "run_mismatch",
                    runId: runId
                ),
                to: connection
            )
            return
        }

        do {
            try store.markDelivered(
                runId: runId
            )

            if connection.inFlightRunId
                == runId
            {
                connection.inFlightRunId = nil
            }

            send(
                .deliveredAck(runId: runId),
                to: connection
            )
        } catch let error
            as RunResultHandoffStoreError
        {
            let code: String

            switch error {
            case .invalidRunId:
                code = "invalid_run_id"

            case .handoffNotFound:
                code = "handoff_not_found"

            case .conflictingExistingRecord,
                 .conflictingDeliveredRecord:
                code = "handoff_conflict"
            }

            send(
                .error(
                    code,
                    runId: runId
                ),
                to: connection
            )
        } catch {
            send(
                .error(
                    "handoff_store_error",
                    runId: runId
                ),
                to: connection
            )
        }
    }

    private func captureReview(_ command: HandoffClientCommand, on connection: Connection) {
        guard let runId = command.runId else {
            send(.error("missing_run_id"), to: connection)
            return
        }

        guard UUID(uuidString: runId) != nil else {
            send(.error("invalid_run_id", runId: runId), to: connection)
            return
        }

        guard let conversationId = command.conversationId,
              let assistantMessage = command.assistantMessage,
              !conversationId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !assistantMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              assistantMessage.lengthOfBytes(using: .utf8) <= ChatGPTReview.maximumAssistantMessageUTF8Bytes
        else {
            send(.error("invalid_review", runId: runId), to: connection)
            return
        }

        guard let handoff = store.deliveredHandoff(runId: runId) else {
            send(.error("handoff_not_delivered", runId: runId), to: connection)
            return
        }

        guard handoff.sourceChat.conversationId == conversationId else {
            send(.error("conversation_mismatch", runId: runId), to: connection)
            return
        }

        let review = ChatGPTReview(
            runId: runId,
            conversationId: conversationId,
            sourceChatURL: handoff.sourceChat.url,
            assistantMessage: assistantMessage,
            capturedAt: Date()
        )

        do {
            try reviewStore.persist(review)
            send(.reviewAck(runId: runId), to: connection)
        } catch ChatGPTReviewStoreError.conflictingExistingRecord {
            send(.error("review_conflict", runId: runId), to: connection)
        } catch ChatGPTReviewStoreError.unreadableExistingRecord {
            send(.error("review_conflict", runId: runId), to: connection)
        } catch ChatGPTReviewStoreError.invalidRunId {
            send(.error("invalid_run_id", runId: runId), to: connection)
        } catch {
            send(.error("review_store_error", runId: runId), to: connection)
        }
    }

    private func send(
        _ event: HandoffServerEvent,
        to connection: Connection
    ) {
        guard
            let data =
                HandoffTransportCodec
                    .encodeServerEvent(event)
        else {
            return
        }

        connection.send(data)
    }

    private final class Connection {
        private let nwConnection: NWConnection
        private let queue: DispatchQueue
        private let stateLock = NSLock()

        private var authenticated = false
        private var didBecomeReady = false
        private var didClose = false

        var inFlightRunId: String?

        var onReady: (() -> Void)?
        var onData: ((Data) -> Void)?
        var onClose: (() -> Void)?

        init(
            nwConnection: NWConnection,
            queue: DispatchQueue
        ) {
            self.nwConnection = nwConnection
            self.queue = queue
        }

        var isAuthenticated: Bool {
            get {
                stateLock.lock()
                defer {
                    stateLock.unlock()
                }

                return authenticated
            }

            set {
                stateLock.lock()
                authenticated = newValue
                stateLock.unlock()
            }
        }

        func start() {
            nwConnection.stateUpdateHandler = {
                [weak self] state in

                guard let self else {
                    return
                }

                switch state {
                case .ready:
                    guard self.markReadyOnce()
                    else {
                        return
                    }

                    self.onReady?()
                    self.readNext()

                case .failed, .cancelled:
                    self.closeOnce()

                default:
                    break
                }
            }

            nwConnection.start(queue: queue)
        }

        func send(_ data: Data) {
            let metadata =
                NWProtocolWebSocket.Metadata(
                    opcode: .text
                )

            let context =
                NWConnection.ContentContext(
                    identifier:
                        "aiflow-handoff-message",
                    metadata: [metadata]
                )

            nwConnection.send(
                content: data,
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed {
                    [weak self] error in

                    if error != nil {
                        self?.cancel()
                    }
                }
            )
        }

        func cancel() {
            nwConnection.cancel()
            closeOnce()
        }

        private func readNext() {
            nwConnection.receiveMessage {
                [weak self]
                data,
                context,
                _,
                error in

                guard let self else {
                    return
                }

                if error != nil {
                    self.closeOnce()
                    self.nwConnection.cancel()
                    return
                }

                let webSocketMetadata =
                    context?
                        .protocolMetadata(
                            definition:
                                NWProtocolWebSocket
                                    .definition
                        )
                        as? NWProtocolWebSocket.Metadata

                if let webSocketMetadata {
                    switch webSocketMetadata.opcode {
                    case .close:
                        // A peer close is not an application JSON message.
                        // Release the active-client slot immediately so a
                        // reconnecting browser may authenticate.
                        self.closeOnce()
                        self.nwConnection.cancel()
                        return

                    case .ping, .pong:
                        // autoReplyPing handles protocol ping replies.
                        // Control-frame payloads must never reach the JSON
                        // command decoder.
                        self.readNext()
                        return

                    case .text, .binary, .cont:
                        break

                    @unknown default:
                        self.cancel()
                        return
                    }
                }

                if let data,
                    !data.isEmpty
                {
                    guard
                        data.count
                            <= HandoffTransport
                                .maximumInboundMessageBytes
                    else {
                        self.cancel()
                        return
                    }

                    self.onData?(data)
                }

                self.readNext()
            }
        }

        private func markReadyOnce() -> Bool {
            stateLock.lock()
            defer {
                stateLock.unlock()
            }

            guard !didBecomeReady else {
                return false
            }

            didBecomeReady = true
            return true
        }

        private func closeOnce() {
            stateLock.lock()

            guard !didClose else {
                stateLock.unlock()
                return
            }

            didClose = true
            stateLock.unlock()

            onClose?()
        }
    }
}
