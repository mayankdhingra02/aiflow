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
    private let routingStore: CodexInitialRoutingStore
    private let token: String?
    private let onReviewPersisted: ((ChatGPTReview) -> Void)?
    private let onRoutingResponse: ((CodexInitialRoutingRequest) -> Void)?
    private let onRoutingAttention: ((CodexInitialRoutingRequest) -> Void)?

    private let queue =
        DispatchQueue(label: "aiflow.handoff.transport")

    private let lock = NSLock()
    private var listener: NWListener?
    private var listenerState: ListenerState = .stopped
    private var resolvedPort: UInt16?
    private var connections:
        [ObjectIdentifier: Connection] = [:]

    /// Exactly one authenticated browser connection may pull handoffs.
    private var activeClientKey: ObjectIdentifier?

    private(set) var lastError: String?

    init(
        port: UInt16 = HandoffTransportServer.defaultPort,
        store: RunResultHandoffStore,
        reviewStore: ChatGPTReviewStore = ChatGPTReviewStore(),
        routingStore: CodexInitialRoutingStore = CodexInitialRoutingStore(),
        token: String? = HandoffToken.loadOrCreate(),
        onReviewPersisted: ((ChatGPTReview) -> Void)? = nil,
        onRoutingResponse: ((CodexInitialRoutingRequest) -> Void)? = nil,
        onRoutingAttention: ((CodexInitialRoutingRequest) -> Void)? = nil
    ) {
        self.port = port
        self.store = store
        self.reviewStore = reviewStore
        self.routingStore = routingStore
        self.token = token
        self.onReviewPersisted = onReviewPersisted
        self.onRoutingResponse = onRoutingResponse
        self.onRoutingAttention = onRoutingAttention
    }

    var boundPort: UInt16 {
        lock.lock()
        defer { lock.unlock() }
        return resolvedPort ?? port
    }

    var isListening: Bool {
        lock.lock()
        defer { lock.unlock() }
        if case .ready = listenerState { return listener != nil }
        return false
    }

    @discardableResult
    func start() -> Bool {
        guard token != nil else {
            lastError = "handoff token unavailable"
            return false
        }

        lock.lock()
        let existingState = listenerState
        let hasListener = listener != nil
        lock.unlock()
        if hasListener { return existingState != .stopping }

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

        let requestedPort: NWEndpoint.Port = port == 0
            ? .any
            : NWEndpoint.Port(rawValue: port)!
        parameters.requiredLocalEndpoint =
            NWEndpoint.hostPort(
                host: NWEndpoint.Host(Self.loopbackHost),
                port: requestedPort
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
                [weak self, weak listener] state in
                self?.listenerDidChange(state, listener: listener)
            }

            lock.lock()
            self.listener = listener
            listenerState = .starting
            resolvedPort = nil
            lock.unlock()

            listener.start(queue: queue)
            return true
        } catch {
            lock.lock()
            lastError = error.localizedDescription
            listenerState = .failed(error.localizedDescription)
            lock.unlock()
            return false
        }
    }

    func stop() {
        lock.lock()

        let openConnections =
            Array(connections.values)

        connections.removeAll()
        activeClientKey = nil

        let listener = listener
        if listener != nil {
            listenerState = .stopping
        } else {
            listenerState = .stopped
            resolvedPort = nil
        }

        lock.unlock()

        listener?.cancel()
        openConnections.forEach {
            $0.cancel()
        }
    }

    func waitUntilReady(timeout: TimeInterval = 5) async throws -> UInt16 {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let state = currentListenerState()

            switch state {
            case .ready(let port):
                return port
            case .failed(let message):
                throw HandoffTransportServerError.listenerFailed(message)
            case .stopped:
                throw HandoffTransportServerError.notStarted
            case .stopping:
                throw HandoffTransportServerError.stopped
            case .starting:
                break
            }

            guard Date() < deadline else {
                throw HandoffTransportServerError.readinessTimedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func waitUntilStopped(timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let state = currentListenerState()

            switch state {
            case .stopped, .failed:
                return
            case .ready, .starting:
                throw HandoffTransportServerError.notStopped
            case .stopping:
                guard Date() < deadline else {
                    throw HandoffTransportServerError.stopTimedOut
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    private func listenerDidChange(
        _ state: NWListener.State,
        listener: NWListener?
    ) {
        guard let listener else { return }

        switch state {
        case .ready:
            guard let port = listener.port?.rawValue else {
                recordListenerFailure(
                    "listener became ready without a bound port",
                    listener: listener
                )
                listener.cancel()
                return
            }
            lock.lock()
            guard self.listener === listener else {
                lock.unlock()
                return
            }
            resolvedPort = port
            listenerState = .ready(port)
            lock.unlock()
        case .failed(let error):
            recordListenerFailure(error.localizedDescription, listener: listener)
        case .cancelled:
            lock.lock()
            guard self.listener === listener else {
                lock.unlock()
                return
            }
            self.listener = nil
            resolvedPort = nil
            listenerState = .stopped
            lock.unlock()
        default:
            break
        }
    }

    private func recordListenerFailure(
        _ message: String,
        listener: NWListener
    ) {
        lock.lock()
        guard self.listener === listener else {
            lock.unlock()
            return
        }
        lastError = message
        self.listener = nil
        resolvedPort = nil
        listenerState = .failed(message)
        lock.unlock()
    }

    private func currentListenerState() -> ListenerState {
        lock.lock()
        defer { lock.unlock() }
        return listenerState
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
        case .nextRouting:
            sendNextRouting(to: connection)
        case .routingDelivered:
            acknowledgeRoutingDelivery(command, on: connection)
        case .routingResponse:
            captureRoutingResponse(command, on: connection)
        case .routingFailed:
            markRoutingAttention(command, on: connection)
        }
    }

    private func sendNextRouting(to connection: Connection) {
        do {
            guard let request = try routingStore.pendingRequest() else {
                send(.routingEmpty(), to: connection)
                return
            }
            try routingStore.markDelivering(runId: request.runId)
            guard let delivered = try routingStore.record(runId: request.runId) else {
                throw CodexInitialRoutingStoreError.recordNotFound
            }
            send(.routing(delivered), to: connection)
        } catch {
            send(.error("routing_store_error"), to: connection)
        }
    }
    private func acknowledgeRoutingDelivery(_ command: HandoffClientCommand, on connection: Connection) {
        guard let runId = command.runId else { send(.error("missing_run_id"), to: connection); return }
        guard UUID(uuidString: runId) != nil else { send(.error("invalid_run_id", runId: runId), to: connection); return }
        do { try routingStore.markDelivered(runId: runId); send(.routingDeliveredAck(runId: runId), to: connection) }
        catch { send(.error("routing_delivery_conflict", runId: runId), to: connection) }
    }
    private func captureRoutingResponse(_ command: HandoffClientCommand, on connection: Connection) {
        guard let runId = command.runId, let conversationId = command.conversationId, let text = command.assistantMessage else { send(.error("invalid_routing", runId: command.runId), to: connection); return }
        guard UUID(uuidString: runId) != nil else { send(.error("invalid_run_id", runId: runId), to: connection); return }
        do { let request = try routingStore.captureResponse(runId: runId, conversationId: conversationId, assistantMessage: text); onRoutingResponse?(request); send(.routingResponseAck(runId: runId), to: connection) }
        catch CodexInitialRoutingStoreError.invalidRecord { send(.error("invalid_routing", runId: runId), to: connection) }
        catch { send(.error("routing_conflict", runId: runId), to: connection) }
    }
    private func markRoutingAttention(_ command: HandoffClientCommand, on connection: Connection) {
        guard let runId = command.runId, UUID(uuidString: runId) != nil else {
            send(.error("invalid_run_id", runId: command.runId), to: connection)
            return
        }
        do {
            guard let request = try routingStore.record(runId: runId) else {
                throw CodexInitialRoutingStoreError.recordNotFound
            }
            switch request.state {
            case .delivering, .delivered:
                try routingStore.markManualAttention(
                    runId: runId,
                    reason: "ChatGPT routing delivery did not complete safely.",
                    manualFallbackAvailable: true
                )
                if let attention = try routingStore.record(runId: runId) { onRoutingAttention?(attention) }

            // A response or execution boundary has already won. Acknowledge this stale browser
            // observation so its durable client evidence is cleared, but never mutate it into a
            // second, fallback-eligible execution path.
            case .pending, .completed, .starting, .started, .manualAttention, .cancelled:
                break
            }
            send(.routingResponseAck(runId: runId), to: connection)
        } catch {
            send(.error("routing_conflict", runId: runId), to: connection)
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
                 .conflictingDeliveredRecord,
                 .unreadableDeliveredRecord,
                 .invalidDeliveredRecord:
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
            onReviewPersisted?(review)
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

    private enum ListenerState: Equatable {
        case stopped
        case starting
        case ready(UInt16)
        case stopping
        case failed(String)
    }
}

enum HandoffTransportServerError: Error, Equatable {
    case notStarted
    case stopped
    case listenerFailed(String)
    case readinessTimedOut
    case notStopped
    case stopTimedOut
}
