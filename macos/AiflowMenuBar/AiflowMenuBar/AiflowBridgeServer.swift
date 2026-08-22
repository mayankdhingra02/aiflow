import Foundation
import Network

/// What the bridge needs from the controller. Kept tiny so the server holds no business
/// logic: it forwards recognized commands and asks for a snapshot, nothing more.
@MainActor
protocol BridgeController: AnyObject {
    func handleBridgeCommand(_ command: BridgeCommand)
    func bridgeSnapshot() -> BridgeEvent
}

/// A local, loopback-only newline-delimited JSON server for the VS Code companion.
///
/// Transport only. It never interprets run state, never decides an approval, and never holds
/// the run: if no client is connected, or a client disconnects mid-run, Codex is unaffected
/// because the run lives entirely in `WidgetViewModel`.
final class AiflowBridgeServer: @unchecked Sendable {
    static let defaultPort: UInt16 = 47321
    static let loopbackHost = "127.0.0.1"

    /// Weak: the controller owns the server, so this must not close the cycle.
    weak var controller: BridgeController?

    private let port: UInt16
    private let queue = DispatchQueue(label: "aiflow.bridge")
    private var listener: NWListener?
    private var listenerState: ListenerState = .stopped
    private var resolvedPort: UInt16?
    private var connections: [ObjectIdentifier: Connection] = [:]
    private let lock = NSLock()

    /// The expected token. Never logged, never sent, never included in an event.
    private let token: String?

    /// The single companion allowed to execute runs. Others stay passive viewers.
    private var workerKey: ObjectIdentifier?
    private var nextWorkerReadinessOrder: UInt64 = 0

    private(set) var lastError: String?

    init(
        port: UInt16 = AiflowBridgeServer.defaultPort,
        token: String? = BridgeToken.loadOrCreate()
    ) {
        self.port = port
        self.token = token
    }

    /// The actual listener endpoint once Network.framework has confirmed that it is ready.
    /// `port == 0` asks the OS to choose a loopback port, which is useful for isolated tests.
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

    /// True when at least one companion has authenticated — i.e. a viewer is attached.
    var hasAuthenticatedClient: Bool {
        lock.lock()
        defer { lock.unlock() }
        return connections.values.contains { $0.isAuthenticated }
    }

    /// True when one companion has been designated to execute runs.
    var hasDesignatedWorker: Bool {
        lock.lock()
        defer { lock.unlock() }
        return currentWorker() != nil
    }

    /// Sends an execution instruction to the one designated worker.
    ///
    /// Execution is deliberately *not* broadcast: several companion windows can be
    /// authenticated at once, and broadcasting `execute_run` would have each of them start its
    /// own Codex turn for a single Aiflow run.
    @discardableResult
    func sendToWorker(_ event: BridgeEvent) -> Bool {
        guard let data = BridgeCodec.encode(event) else { return false }
        lock.lock()
        let target = currentWorker()
        lock.unlock()
        guard let target else { return false }
        target.send(data)
        return true
    }

    /// The designated worker, if it is still connected and authenticated. Caller holds `lock`.
    private func currentWorker() -> Connection? {
        guard let key = workerKey, let connection = connections[key],
            connection.isAuthenticated, connection.isWorker
        else { return nil }
        return connection
    }

    var connectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return connections.count
    }

    /// Binds to 127.0.0.1 only. `requiredLocalEndpoint` is what pins this to loopback —
    /// without it NWListener would accept connections from any interface.
    @discardableResult
    func start() -> Bool {
        lock.lock()
        let existingState = listenerState
        let hasListener = listener != nil
        lock.unlock()
        if hasListener {
            return existingState != .stopping
        }

        let parameters = NWParameters.tcp
        let requestedPort: NWEndpoint.Port = port == 0
            ? .any
            : NWEndpoint.Port(rawValue: port)!
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(Self.loopbackHost),
            port: requestedPort
        )
        parameters.allowLocalEndpointReuse = true

        do {
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
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
        let openConnections = Array(connections.values)
        connections.removeAll()
        // Retire the worker designation with the connections it referred to. `workerKey` is an
        // ObjectIdentifier, i.e. an address: leaving it set after its Connection is freed both
        // blocks the next companion from being designated and risks a future Connection
        // allocated at the same address being mistaken for the designated worker.
        workerKey = nil
        let listener = listener
        if listener != nil {
            listenerState = .stopping
        } else {
            listenerState = .stopped
            resolvedPort = nil
        }
        lock.unlock()
        listener?.cancel()
        openConnections.forEach { $0.cancel() }
    }

    /// Waits for Network.framework to either bind the loopback listener or report why it could
    /// not. Callers that need to connect immediately should use this instead of assuming that
    /// `start()` returning means the asynchronous bind has completed.
    func waitUntilReady(timeout: TimeInterval = 5) async throws -> UInt16 {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let state = currentListenerState()

            switch state {
            case .ready(let port):
                return port
            case .failed(let message):
                throw AiflowBridgeServerError.listenerFailed(message)
            case .stopped:
                throw AiflowBridgeServerError.notStarted
            case .stopping:
                throw AiflowBridgeServerError.stopped
            case .starting:
                break
            }

            guard Date() < deadline else {
                throw AiflowBridgeServerError.readinessTimedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Waits until a cancelled listener has released its endpoint. This is primarily useful to
    /// callers that need to bind a replacement listener on the same explicit port.
    func waitUntilStopped(timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let state = currentListenerState()

            switch state {
            case .stopped, .failed:
                return
            case .ready, .starting:
                throw AiflowBridgeServerError.notStopped
            case .stopping:
                guard Date() < deadline else {
                    throw AiflowBridgeServerError.stopTimedOut
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    private func listenerDidChange(_ state: NWListener.State, listener: NWListener?) {
        guard let listener else { return }

        switch state {
        case .ready:
            guard let port = listener.port?.rawValue else {
                recordListenerFailure("listener became ready without a bound port", listener: listener)
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

    private func recordListenerFailure(_ message: String, listener: NWListener) {
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

    /// Sends an event to every connected client. A send failure only drops that client.
    /// Events only ever reach authenticated connections. An unauthenticated socket sees the
    /// `hello` frame and nothing else — no run state, no request ids.
    func broadcast(_ event: BridgeEvent) {
        guard let data = BridgeCodec.encode(event) else { return }
        lock.lock()
        let targets = connections.values.filter { $0.isAuthenticated }
        lock.unlock()
        targets.forEach { $0.send(data) }
    }

    private func accept(_ nwConnection: NWConnection) {
        let connection = Connection(nwConnection: nwConnection, queue: queue)
        let key = ObjectIdentifier(connection)

        connection.onLine = { [weak self] line in
            self?.receive(line: line, on: connection)
        }
        connection.onClose = { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.connections.removeValue(forKey: key)
            let workerDeparted = self.workerKey == key
            if workerDeparted {
                self.workerKey = nil
                self.promoteEligibleWorkerLocked()
            }
            self.lock.unlock()
            if workerDeparted { self.notifyControllerOfWorkerAvailability() }
            // Deliberately nothing else: losing the viewer never touches the run.
        }

        lock.lock()
        connections[key] = connection
        lock.unlock()

        connection.start()

        // A version greeting is safe before authentication: it carries no run state and no
        // request ids. The snapshot waits until the client proves who it is.
        if let hello = BridgeCodec.encode(.hello()) { connection.send(hello) }
    }

    private func receive(line: String, on connection: Connection) {
        // Malformed JSON and unknown command types decode to nil and are dropped here.
        guard let command = BridgeCodec.decodeCommand(line) else { return }

        guard connection.isAuthenticated else {
            // The only command an unauthenticated connection can issue is `auth`.
            guard command.type == .auth else { return }
            guard let candidate = command.token, let expected = token,
                BridgeToken.matches(candidate, expected: expected)
            else {
                // Never say what was wrong, and never echo the expected value.
                connection.cancel()
                return
            }

            connection.isAuthenticated = true
            sendSnapshot(to: connection)
            return
        }

        // Worker designation is about connection identity, so it is settled here rather than
        // in the controller: the first authenticated companion that announces itself ready
        // becomes the one worker, and only it may execute runs or report on them.
        if command.type == .workerAvailable {
            let key = ObjectIdentifier(connection)
            let ready = command.workerState == "ready"
            lock.lock()
            let wasDesignated = workerKey == key
            if ready {
                if !connection.isWorker {
                    connection.workerReadinessOrder = nextWorkerReadinessOrder
                    nextWorkerReadinessOrder &+= 1
                }
                connection.isWorker = true
                if workerKey == nil { workerKey = key }
            } else if workerKey == key {
                connection.isWorker = false
                connection.workerReadinessOrder = nil
                workerKey = nil
                promoteEligibleWorkerLocked()
            } else {
                connection.isWorker = false
                connection.workerReadinessOrder = nil
            }
            let isDesignated = workerKey == key
            let designationChanged = isDesignated || (wasDesignated && !ready)
            lock.unlock()

            // A ready non-designated companion remains eligible for deterministic promotion.
            // The controller always receives the server's current designation, not a stale
            // command from a socket whose ownership changed while the MainActor was busy.
            if designationChanged { notifyControllerOfWorkerAvailability() }
            return
        }

        if command.type.isWorkerReport {
            lock.lock()
            let fromDesignatedWorker = workerKey == ObjectIdentifier(connection)
            lock.unlock()
            // A report from anything other than the worker serving the run is not evidence.
            guard fromDesignatedWorker else { return }
        }

        Task { @MainActor [weak self] in
            self?.controller?.handleBridgeCommand(command)
        }
    }

    /// Selects one already-authenticated ready replacement. Readiness order makes takeover
    /// deterministic while `workerKey` preserves the single-worker execution boundary.
    /// Caller holds `lock`.
    private func promoteEligibleWorkerLocked() {
        guard workerKey == nil else { return }
        let replacement = connections.min { lhs, rhs in
            let left = lhs.value.workerReadinessOrder ?? UInt64.max
            let right = rhs.value.workerReadinessOrder ?? UInt64.max
            return left < right
        }
        guard let replacement,
              replacement.value.isAuthenticated,
              replacement.value.isWorker,
              replacement.value.workerReadinessOrder != nil
        else { return }
        workerKey = replacement.key
    }

    private func notifyControllerOfWorkerAvailability() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.controller?.handleBridgeCommand(BridgeCommand(
                type: .workerAvailable,
                workerState: self.hasDesignatedWorker ? "ready" : "unavailable"
            ))
        }
    }

    /// Describes the world as it is right now, so a client that authenticates mid-run can
    /// reconstruct its UI without the run restarting.
    private func sendSnapshot(to connection: Connection) {
        Task { @MainActor [weak self] in
            guard let self, let snapshot = self.controller?.bridgeSnapshot() else { return }
            if let data = BridgeCodec.encode(snapshot) { connection.send(data) }
        }
    }

    /// One client connection: reads bytes, yields complete lines, writes frames.
    private final class Connection {
        private let nwConnection: NWConnection
        private let queue: DispatchQueue
        private let buffer = BoundedLineBuffer()
        private let stateLock = NSLock()
        private var authenticated = false

        /// Set when this companion announced it can execute runs.
        var isWorker = false
        var workerReadinessOrder: UInt64?

        /// Per connection: authenticating one client never authenticates another.
        var isAuthenticated: Bool {
            get {
                stateLock.lock()
                defer { stateLock.unlock() }
                return authenticated
            }
            set {
                stateLock.lock()
                authenticated = newValue
                stateLock.unlock()
            }
        }

        var onLine: ((String) -> Void)?
        var onClose: (() -> Void)?

        init(nwConnection: NWConnection, queue: DispatchQueue) {
            self.nwConnection = nwConnection
            self.queue = queue
        }

        func start() {
            nwConnection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed, .cancelled:
                    self?.onClose?()
                default:
                    break
                }
            }
            nwConnection.start(queue: queue)
            readNext()
        }

        func send(_ data: Data) {
            nwConnection.send(content: data, completion: .contentProcessed { _ in })
        }

        func cancel() {
            nwConnection.cancel()
        }

        private func readNext() {
            nwConnection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                [weak self] data, _, isComplete, error in
                guard let self else { return }

                if let data, !data.isEmpty {
                    guard let lines = self.buffer.append(data) else {
                        // Oversized frame: a legitimate command never gets close to the limit.
                        self.onClose?()
                        self.nwConnection.cancel()
                        return
                    }
                    for line in lines {
                        self.onLine?(line)
                    }
                }

                if isComplete || error != nil {
                    self.onClose?()
                    self.nwConnection.cancel()
                    return
                }
                self.readNext()
            }
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

enum AiflowBridgeServerError: Error, Equatable {
    case notStarted
    case stopped
    case listenerFailed(String)
    case readinessTimedOut
    case notStopped
    case stopTimedOut
}
