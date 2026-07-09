import Foundation
import MyRobotaxiContracts

/// Actor-isolated telemetry WebSocket client (websocket-protocol.md +
/// state-machine.md). One instance owns a single authenticated connection to the
/// telemetry server and demultiplexes its frames into per-vehicle async streams.
///
/// Responsibilities:
/// - **Handshake** — send the `auth` frame first, await `auth_ok` (C-3), bound
///   by a 6s pre-`auth_ok` timer (§2.3 rule 4).
/// - **Per-vehicle subscription** — the server implicitly streams every owned
///   vehicle at handshake; the Kit additionally sends explicit `subscribe` /
///   `unsubscribe` frames (MYR-46 / DV-07) to narrow, and always demultiplexes
///   the single socket into per-vehicle streams locally.
/// - **Keepalive** — reset a 30s liveness watchdog (2× the 15s server heartbeat,
///   §7.4.1) on every inbound frame; a transport-level PING is sent every 15s.
/// - **Reconnect** — on any disconnect, jittered exponential backoff (1s/2×/30s/
///   ±25%, §7.1), re-fetch the REST snapshot **before** resuming the live stream
///   (NFR-3.11, CG-SM-4), and re-send the subscribe frames (resubscribe).
/// - **dataState** — drive the per-group freshness machine (state-machine.md §2).
///
/// Swift 6 concurrency-clean: all mutable state is actor-isolated; every value
/// that crosses an isolation boundary (`WebSocketChannel`, payloads,
/// continuations) is `Sendable`.
public actor TelemetrySocket {
    // MARK: Configuration

    /// Server heartbeat cadence (§7.4). The liveness watchdog fires at 2× this.
    public static let heartbeatInterval: Double = 15
    /// Silent-disconnect watchdog timeout — 2× the heartbeat (§7.4.1).
    public static let livenessTimeout: Double = 30
    /// Pre-`auth_ok` bound — 1s grace over the server's 5s AuthTimeout (§2.3 rule 4).
    public static let preAuthTimeout: Double = 6

    // MARK: Dependencies

    private let webSocketURL: URL
    private let tokenProvider: any TokenProvider
    private let snapshotSource: any SnapshotFetching
    private let channelFactory: any WebSocketChannelFactory
    private let backoff: ExponentialBackoff
    private let randomUnit: @Sendable () -> Double

    // MARK: State

    private var connectionState: ConnectionState = .disconnected
    /// Last typed error reason (e.g. a terminal `auth_failed`).
    public private(set) var lastError: ErrorPayload?

    private var channel: (any WebSocketChannel)?
    private var supervisor: Task<Void, Never>?
    private var preAuthTask: Task<Void, Never>?
    private var livenessTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?

    private var isStopped = false
    private var authOK = false
    private var attempt = 0
    /// Bumped on every connection attempt; snapshot emits check it so a stale
    /// in-flight fetch from a superseded connection is dropped (invariant #5).
    private var generation = 0

    private var subscribers: [String: [UUID: AsyncStream<VehicleTelemetryEvent>.Continuation]] = [:]
    private var connectionObservers: [UUID: AsyncStream<ConnectionState>.Continuation] = [:]
    private var dataStates: [String: [AtomicGroup: DataState]] = [:]

    // MARK: Init

    public init(
        webSocketURL: URL,
        tokenProvider: any TokenProvider,
        snapshotSource: any SnapshotFetching,
        channelFactory: any WebSocketChannelFactory = URLSessionWebSocketChannelFactory(),
        backoff: ExponentialBackoff = .standard,
        randomUnit: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }
    ) {
        self.webSocketURL = webSocketURL
        self.tokenProvider = tokenProvider
        self.snapshotSource = snapshotSource
        self.channelFactory = channelFactory
        self.backoff = backoff
        self.randomUnit = randomUnit
    }

    // MARK: - Public API

    /// Current transport health.
    public func currentConnectionState() -> ConnectionState { connectionState }

    /// Current freshness for a vehicle's atomic group (`.loading` if unknown).
    public func dataState(vehicleId: String, group: AtomicGroup) -> DataState {
        dataStates[vehicleId]?[group] ?? .loading
    }

    /// A stream of ``ConnectionState`` changes, seeded with the current value.
    public func connectionStates() -> AsyncStream<ConnectionState> {
        let (stream, continuation) = AsyncStream<ConnectionState>.makeStream()
        let id = UUID()
        connectionObservers[id] = continuation
        continuation.yield(connectionState)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeConnectionObserver(id) }
        }
        return stream
    }

    /// Subscribe to a vehicle's telemetry. Returns a stream of
    /// ``VehicleTelemetryEvent``. If the socket is already connected, the
    /// subscribe frame is sent and a fresh snapshot is fetched immediately;
    /// otherwise both happen on (re)connect.
    public func subscribe(to vehicleId: String) -> AsyncStream<VehicleTelemetryEvent> {
        let (stream, continuation) = AsyncStream<VehicleTelemetryEvent>.makeStream()
        let id = UUID()
        subscribers[vehicleId, default: [:]][id] = continuation
        if dataStates[vehicleId] == nil {
            dataStates[vehicleId] = Dictionary(uniqueKeysWithValues: AtomicGroup.allCases.map { ($0, .loading) })
        }
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(vehicleId: vehicleId, id: id) }
        }
        if connectionState == .connected, let channel {
            let gen = generation
            Task { await self.activateSubscription(vehicleId: vehicleId, channel: channel, generation: gen) }
        }
        return stream
    }

    /// Stop receiving updates for a vehicle. Finishes its streams and, if
    /// connected, sends an `unsubscribe` frame (does not close the socket).
    public func unsubscribe(from vehicleId: String) {
        if let continuations = subscribers.removeValue(forKey: vehicleId) {
            for continuation in continuations.values { continuation.finish() }
        }
        dataStates.removeValue(forKey: vehicleId)
        if connectionState == .connected, let channel {
            Task { try? await channel.send(WireCodec.encodeFrame(type: .unsubscribe, payload: UnsubscribePayload(vehicleId: vehicleId))) }
        }
    }

    /// Open the connection and start the supervised reconnect loop. Idempotent.
    public func connect() {
        guard supervisor == nil else { return }
        isStopped = false
        supervisor = Task { await self.supervise() }
    }

    /// Cleanly stop: cancel the reconnect loop, close the socket, and settle to
    /// ``ConnectionState/disconnected``. Subscriber streams stay open so a later
    /// ``connect()`` resumes them.
    public func disconnect() {
        isStopped = true
        supervisor?.cancel(); supervisor = nil
        cancelTimers()
        let channel = self.channel
        self.channel = nil
        authOK = false
        Task { await channel?.close() }
        setConnectionState(.disconnected)
    }

    /// Consumer-driven foreground reconnect (NFR-3.36a): reset the retry counter
    /// and, if not connected, reconnect immediately, bypassing the backoff delay.
    /// The app wires this from its `scenePhase` observer (state-machine.md §5.3).
    public func handleForegroundTransition() {
        attempt = 0
        if supervisor == nil {
            connect()
        } else if connectionState != .connected, let channel {
            // Nudge a stalled attempt: closing makes the receive loop fail fast
            // and the supervisor retries at attempt 0 (no backoff wait).
            Task { await channel.close() }
        }
    }

    /// Background transition (state-machine.md §5.3). On iOS the socket is left
    /// open; the OS suspends it silently and the liveness watchdog detects the
    /// stall on resume. Present so the app can wire its lifecycle uniformly.
    public func handleBackgroundTransition() {
        // iOS: intentionally a no-op — do not proactively close (watchOS would).
    }

    // MARK: - Supervisor / reconnect loop

    private func supervise() async {
        attempt = 0
        while !isStopped {
            setConnectionState(attempt == 0 ? .connecting : .reconnecting)
            do {
                try await runConnection()
                break // returned cleanly (stopped)
            } catch is TerminalError {
                // Non-retryable (e.g. auth_failed, C-5/C-8): settle terminal.
                markAllGroupsStale()
                setConnectionState(.disconnected)
                break
            } catch {
                // Transient: mark stale, back off, retry (C-4 / C-6 / C-7).
                markAllGroupsStale()
                if isStopped { break }
                attempt += 1
                setConnectionState(.reconnecting)
                let seconds = backoff.delay(attempt: attempt, random: randomUnit())
                try? await Task.sleep(nanoseconds: UInt64((seconds * 1_000_000_000).rounded()))
            }
        }
        cancelTimers()
        supervisor = nil
    }

    /// One connection attempt: open → auth → receive-loop until disconnect.
    /// Returns normally only on a clean stop; throws ``TerminalError`` for a
    /// non-retryable failure and any other error for a transient one.
    private func runConnection() async throws {
        cancelTimers()
        generation &+= 1
        let gen = generation
        authOK = false

        let channel = channelFactory.makeChannel(url: webSocketURL)
        self.channel = channel
        defer { let c = channel; Task { await c.close() } }

        // §2.2: the auth frame MUST be the first frame after the upgrade.
        let token: String
        do { token = try await tokenProvider.token() }
        catch { throw error } // transient — provider will be asked again on retry
        try await channel.send(WireCodec.encodeFrame(type: .auth, payload: AuthPayload(token: token)))
        armPreAuthTimer(channel: channel, generation: gen)

        while true {
            let text: String
            do { text = try await channel.receive() }
            catch {
                if isStopped { return }
                throw error // close / transport failure → supervisor reconnects
            }
            if isStopped { return }
            resetLivenessIfAuthed(channel: channel, generation: gen)
            guard let envelope = try? WireCodec.decodeEnvelope(text) else { continue }
            try await handle(envelope, channel: channel, generation: gen)
        }
    }

    /// Non-retryable connection failure (auth rejected).
    private struct TerminalError: Error {}

    // MARK: - Frame handling

    private func handle(_ envelope: WebSocketEnvelope, channel: any WebSocketChannel, generation gen: Int) async throws {
        switch envelope.type {
        case .authOk:
            authOK = true
            preAuthTask?.cancel(); preAuthTask = nil
            attempt = 0
            lastError = nil
            setConnectionState(.connected)
            resetLiveness(channel: channel, generation: gen)
            startKeepalive(channel: channel, generation: gen)
            await onConnected(channel: channel, generation: gen)

        case .vehicleUpdate:
            guard let payload = try? WireCodec.decodePayload(VehicleUpdatePayload.self, from: envelope) else { return }
            routeVehicleUpdate(payload)

        case .driveStarted:
            guard let payload = try? WireCodec.decodePayload(DriveStartedPayload.self, from: envelope) else { return }
            emit(.driveStarted(payload), to: payload.vehicleId)

        case .driveEnded:
            guard let payload = try? WireCodec.decodePayload(DriveEndedPayload.self, from: envelope) else { return }
            emit(.driveEnded(payload), to: payload.vehicleId)

        case .connectivity:
            guard let payload = try? WireCodec.decodePayload(ConnectivityPayload.self, from: envelope) else { return }
            emit(.connectivity(payload), to: payload.vehicleId)

        case .heartbeat:
            break // liveness already reset above

        case .error:
            let payload = try? WireCodec.decodePayload(ErrorPayload.self, from: envelope)
            lastError = payload
            if payload?.code == .authFailed {
                throw TerminalError() // C-8: terminal, no auto-retry (FR-7.3)
            }
            // Everything else is transient: force a reconnect by closing.
            await channel.close()

        case .auth, .subscribe, .unsubscribe, .ping, .pong, .unrecognized:
            break // client→server types or unhandled — ignore (open-object rule)
        }
    }

    /// On (re)connect: resubscribe and fetch the snapshot for every subscribed
    /// vehicle **before** returning to the live stream (ordering guarantee,
    /// CG-SM-4). Awaiting here parks the receive loop, so live frames buffer in
    /// the socket and are applied only after the snapshot.
    private func onConnected(channel: any WebSocketChannel, generation gen: Int) async {
        for vehicleId in subscribers.keys {
            guard gen == generation else { return }
            await activateSubscription(vehicleId: vehicleId, channel: channel, generation: gen)
        }
    }

    /// Send the subscribe frame, move the vehicle's groups to `.loading` (D-7),
    /// then fetch + emit the snapshot (D-1 on success, D-2 on failure).
    private func activateSubscription(vehicleId: String, channel: any WebSocketChannel, generation gen: Int) async {
        try? await channel.send(WireCodec.encodeFrame(type: .subscribe, payload: SubscribePayload(vehicleId: vehicleId)))
        setDataState(vehicleId: vehicleId, groups: AtomicGroup.allCases, to: .loading)
        do {
            let snapshot = try await snapshotSource.snapshot(vehicleId: vehicleId)
            guard gen == generation, subscribers[vehicleId] != nil else { return }
            emit(.snapshot(snapshot), to: vehicleId)
            setDataState(vehicleId: vehicleId, groups: AtomicGroup.allCases, to: .ready)
        } catch {
            guard gen == generation else { return }
            setDataState(vehicleId: vehicleId, groups: AtomicGroup.allCases, to: .error)
        }
    }

    private func routeVehicleUpdate(_ payload: VehicleUpdatePayload) {
        emit(.update(payload), to: payload.vehicleId)
        let (groups, navCleared) = VehicleStateMerger.classify(fields: payload.fields)
        for group in groups {
            let state: DataState = (group == .navigation && navCleared) ? .cleared : .ready
            setDataState(vehicleId: payload.vehicleId, groups: [group], to: state)
        }
    }

    // MARK: - dataState bookkeeping

    private func setDataState(vehicleId: String, groups: [AtomicGroup], to state: DataState) {
        guard subscribers[vehicleId] != nil else { return }
        for group in groups {
            let current = dataStates[vehicleId]?[group]
            guard current != state else { continue }
            dataStates[vehicleId, default: [:]][group] = state
            emit(.dataState(group: group, state: state), to: vehicleId)
        }
    }

    /// WS_DISCONNECTED (D-4): every ready group across every vehicle → stale.
    /// Cached values are retained (CG-SM-5).
    private func markAllGroupsStale() {
        for vehicleId in subscribers.keys {
            let groups = dataStates[vehicleId]?.filter { $0.value == .ready }.map(\.key) ?? []
            setDataState(vehicleId: vehicleId, groups: groups, to: .stale)
        }
    }

    // MARK: - Emission

    private func emit(_ event: VehicleTelemetryEvent, to vehicleId: String) {
        guard let continuations = subscribers[vehicleId] else { return }
        for continuation in continuations.values { continuation.yield(event) }
    }

    private func setConnectionState(_ new: ConnectionState) {
        guard new != connectionState else { return }
        connectionState = new
        for continuation in connectionObservers.values { continuation.yield(new) }
    }

    private func removeSubscriber(vehicleId: String, id: UUID) {
        subscribers[vehicleId]?.removeValue(forKey: id)
        if subscribers[vehicleId]?.isEmpty == true {
            subscribers.removeValue(forKey: vehicleId)
            dataStates.removeValue(forKey: vehicleId)
        }
    }

    private func removeConnectionObserver(_ id: UUID) {
        connectionObservers.removeValue(forKey: id)
    }

    // MARK: - Timers (all reconnect the socket by closing the channel)

    private func armPreAuthTimer(channel: any WebSocketChannel, generation gen: Int) {
        preAuthTask?.cancel()
        preAuthTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.preAuthTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.preAuthTimerFired(channel: channel, generation: gen)
        }
    }

    private func preAuthTimerFired(channel: any WebSocketChannel, generation gen: Int) async {
        guard gen == generation, !authOK else { return }
        // §2.3 rule 4: silent handshake failure → close locally, auto-retry.
        await channel.close()
    }

    private func resetLivenessIfAuthed(channel: any WebSocketChannel, generation gen: Int) {
        guard authOK else { return }
        resetLiveness(channel: channel, generation: gen)
    }

    private func resetLiveness(channel: any WebSocketChannel, generation gen: Int) {
        livenessTask?.cancel()
        livenessTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.livenessTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.livenessFired(channel: channel, generation: gen)
        }
    }

    private func livenessFired(channel: any WebSocketChannel, generation gen: Int) async {
        guard gen == generation else { return }
        // §7.4.1: no frame for 2× heartbeat → treat as a silent disconnect.
        await channel.close()
    }

    private func startKeepalive(channel: any WebSocketChannel, generation gen: Int) {
        keepaliveTask?.cancel()
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.heartbeatInterval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                let stop = await self?.sendKeepalivePing(channel: channel, generation: gen) ?? true
                if stop { return }
            }
        }
    }

    /// Returns true when the keepalive loop should stop (superseded connection).
    private func sendKeepalivePing(channel: any WebSocketChannel, generation gen: Int) async -> Bool {
        guard gen == generation else { return true }
        try? await channel.ping() // best-effort; the liveness watchdog catches death
        return false
    }

    private func cancelTimers() {
        preAuthTask?.cancel(); preAuthTask = nil
        livenessTask?.cancel(); livenessTask = nil
        keepaliveTask?.cancel(); keepaliveTask = nil
    }
}
