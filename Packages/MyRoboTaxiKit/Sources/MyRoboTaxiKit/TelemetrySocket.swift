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
    /// MYR-432 — where the post-4002 access set is read from. Optional: see
    /// ``VehicleAccessListing``.
    private let accessListing: (any VehicleAccessListing)?
    private let channelFactory: any WebSocketChannelFactory
    private let backoff: ExponentialBackoff
    private let randomUnit: @Sendable () -> Double
    /// MYR-319 — the cold-read attempt schedule: one entry per attempt, the
    /// delay BEFORE it (the first is always immediate). See
    /// ``fetchAndEmitSnapshot(vehicleId:scope:)`` for why a non-streaming
    /// car cannot be left on a single ask. Injected as `[0]` in tests.
    private let snapshotRetryDelays: [Double]
    /// MYR-387 — see ``defaultStandaloneSnapshotGrace``.
    private let standaloneSnapshotGrace: Double

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
    /// Account-wide ride-request observers (P10, MYR-174). Not keyed by vehicle:
    /// `ride_request_created` / `ride_status_changed` are unicast to a ride's two
    /// parties, so they fan out to every ride observer regardless of the selected
    /// vehicle — see ``rideEvents()`` and ``RideRequestEvent``.
    private var rideObservers: [UUID: AsyncStream<RideRequestEvent>.Continuation] = [:]
    /// MYR-319 — the in-flight cold-read retry per vehicle, so an unsubscribe or a
    /// newer activation cancels the old schedule instead of racing it.
    private var snapshotRetryTasks: [String: Task<Void, Never>] = [:]
    /// MYR-387 — the pending SOCKET-INDEPENDENT cold read per vehicle. Armed on a
    /// subscribe that could not be activated immediately, cancelled the moment
    /// the socket activates that subscription itself.
    private var standaloneSnapshotTasks: [String: Task<Void, Never>] = [:]
    /// MYR-387 — vehicles a snapshot has genuinely been emitted for. Guards the
    /// fallback against spending a request on data we already hold.
    private var snapshotDelivered: Set<String> = []
    /// MYR-432 — account-wide access-revocation observers. Fan-out mirrors
    /// ``rideEvents()``: a prune is a fact about the ACCOUNT's set, not about one
    /// vehicle's stream, and the surface that has to release reads it there.
    private var accessObservers: [UUID: AsyncStream<VehicleAccessRevocation>.Continuation] = [:]
    /// MYR-432 — the close code the peer used on the connection that just ended,
    /// read off the channel before it is discarded.
    private var lastCloseCode: Int?
    /// MYR-432 — set by an access close, consumed by the next `auth_ok`, which is
    /// where the reduced set is resolved and the prune happens.
    private var awaitingAccessRevalidation = false
    /// MYR-432 — CONSECUTIVE access closes, deliberately NOT `attempt`.
    ///
    /// `attempt` is reset to 0 by every `auth_ok`, which is correct for transport
    /// churn and is exactly what made the reported loop permanent: a 4002 close
    /// always follows a SUCCESSFUL handshake, so the counter that governs backoff
    /// was zeroed a few hundred microseconds before every close. This one is
    /// cleared only by a prune that actually removed a vehicle, so a server that
    /// keeps closing over an access set we already agree with escalates instead of
    /// hammering.
    private var accessCloseStreak = 0
    /// MYR-432 — vehicles whose `/snapshot` read was refused `403`. Defense in
    /// depth behind the prune (§3): the retry ladder and the MYR-387 standalone
    /// fallback both stand down for that vehicle, so a revoked car cannot keep
    /// spending REST requests even on a build/route where the prune never fires.
    private var snapshotAccessDenied: Set<String> = []

    // MARK: Init

    public init(
        webSocketURL: URL,
        tokenProvider: any TokenProvider,
        snapshotSource: any SnapshotFetching,
        accessListing: (any VehicleAccessListing)? = nil,
        channelFactory: any WebSocketChannelFactory = URLSessionWebSocketChannelFactory(),
        backoff: ExponentialBackoff = .standard,
        randomUnit: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) },
        snapshotRetryDelays: [Double] = TelemetrySocket.defaultSnapshotRetryDelays,
        standaloneSnapshotGrace: Double = TelemetrySocket.defaultStandaloneSnapshotGrace
    ) {
        self.webSocketURL = webSocketURL
        self.tokenProvider = tokenProvider
        self.snapshotSource = snapshotSource
        self.accessListing = accessListing
        self.channelFactory = channelFactory
        self.backoff = backoff
        self.randomUnit = randomUnit
        // An empty schedule would mean "never fetch", which is never what a
        // caller means; degrade to the single immediate attempt.
        self.snapshotRetryDelays = snapshotRetryDelays.isEmpty ? [0] : snapshotRetryDelays
        self.standaloneSnapshotGrace = max(0, standaloneSnapshotGrace)
    }

    /// MYR-387 — how long a subscribe waits for the socket before asking REST for
    /// the cold snapshot itself.
    ///
    /// Long enough that a working handshake always wins the race (open + `auth` +
    /// `auth_ok` is a fraction of this on any network the app is usable on), short
    /// enough that a broken one costs the owner two seconds instead of the whole
    /// `ColdSnapshotLoad` budget — or, before this issue, the entire session.
    public static let defaultStandaloneSnapshotGrace: Double = 2

    /// Four attempts over ~13s: immediate, +0.8s, +3s, +9s. Short enough that an
    /// owner opening the app to a sleeping car sees it fill in rather than
    /// wondering, long enough to outlast a backend wake round trip, and bounded
    /// so a genuinely unreachable car costs four requests, not a poll.
    public static let defaultSnapshotRetryDelays: [Double] = [0, 0.8, 3, 9]

    // MARK: - Public API

    /// Current transport health.
    public func currentConnectionState() -> ConnectionState { connectionState }

    /// MYR-432 — TEST SEAM. The two counters that decide whether a reconnect is
    /// backed off, exposed `internal` so a suite can assert the ESCALATION rather
    /// than infer it from wall-clock timings.
    ///
    /// It is the distinction between them that matters and that a timing-based
    /// test cannot see: `attempt` is reset by every `auth_ok`, and an access close
    /// always follows a successful handshake, so `attempt` alone can never
    /// escalate on this path. `accessCloseStreak` is the one that survives.
    func retryCounters() -> (attempt: Int, accessCloseStreak: Int) {
        (attempt, accessCloseStreak)
    }

    /// MYR-432 — TEST SEAM. The vehicles currently subscribed, so a prune can be
    /// asserted directly rather than only through the streams it finished.
    func subscribedVehicleIDs() -> Set<String> { Set(subscribers.keys) }

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

    /// A stream of ride-request lifecycle events (`ride_request_created` /
    /// `ride_status_changed`, P10 ride-hailing — MYR-174). Account-wide, not
    /// per-vehicle: the server unicasts these to a ride's two parties, so every
    /// caller sees every ride frame this connection receives. Frames are summary-
    /// only — refetch `RestClient.rideRequest(id:)` for the full record. Mirrors
    /// ``connectionStates()``'s multi-observer fan-out pattern.
    public func rideEvents() -> AsyncStream<RideRequestEvent> {
        let (stream, continuation) = AsyncStream<RideRequestEvent>.makeStream()
        let id = UUID()
        rideObservers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeRideObserver(id) }
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
        } else {
            // MYR-387 — THE COLD READ IS A REST CALL AND MUST NOT WAIT FOREVER
            // ON THE SOCKET.
            //
            // Before this, `fetchAndEmitSnapshot` had exactly two callers, and
            // both required a live connection: `activateSubscription` (reached
            // only from `auth_ok`, or from this branch when already connected)
            // and `refreshSnapshot` (which requires a subscription that had
            // already been activated). So a WebSocket that failed to connect or
            // failed to authenticate meant `GET /api/vehicles/{id}/snapshot` was
            // **never even attempted** — on a device whose REST client was
            // demonstrably healthy, since `GET /api/vehicles` had just answered.
            //
            // That is the MYR-387 client report: the fleet list landed (his
            // switcher chip read "Lunar"), the snapshot never did, and owner Home
            // sat on MYR-326's skeleton over a black map for the whole
            // `ColdSnapshotLoad` budget with nothing in flight that could end it.
            // A terminal `auth_failed` is the sharpest form — `supervise()` breaks
            // out of its loop for the rest of the session — but any transient
            // failure inside the backoff produces the same silence for as long as
            // it lasts, which is why the symptom is intermittent.
            //
            // The two reads are independent facts about the backend and are now
            // treated as such. `.standalone` scope, NOT the connection
            // generation: a subscribe issued before the first `runConnection()`
            // captures generation 0, which the connect then bumps to 1 — so a
            // generation-gated fetch would have its emit dropped as "superseded"
            // in the common case, which is the whole case this exists for.
            //
            // **It is a GRACE-DELAYED FALLBACK, not a second cold read**, and
            // that is what keeps the healthy path byte-identical. A socket that
            // is going to work authenticates in well under
            // `standaloneSnapshotGrace`, and `activateSubscription` cancels the
            // pending fallback the moment it does — so a healthy boot still makes
            // exactly ONE `/snapshot` request, from exactly the caller it always
            // did, with CG-SM-4's ordering guarantee intact. Only a socket that
            // has visibly failed to deliver pays for the fallback.
            scheduleStandaloneSnapshot(vehicleId: vehicleId)
        }
        return stream
    }

    /// MYR-387 — arm the socket-independent cold read for a vehicle.
    ///
    /// Cancelled by `activateSubscription` (the socket got there first), by
    /// `unsubscribe` (nobody is watching), and by `disconnect` (we are stopping).
    /// Declines to run at all once a snapshot has genuinely been emitted for the
    /// vehicle, so a late-arriving grace can never spend a request on data we
    /// already hold.
    private func scheduleStandaloneSnapshot(vehicleId: String) {
        standaloneSnapshotTasks[vehicleId]?.cancel()
        let grace = standaloneSnapshotGrace
        standaloneSnapshotTasks[vehicleId] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, grace) * 1_000_000_000))
            if Task.isCancelled { return }
            await self?.runStandaloneSnapshot(vehicleId: vehicleId)
        }
    }

    private func runStandaloneSnapshot(vehicleId: String) async {
        standaloneSnapshotTasks.removeValue(forKey: vehicleId)
        guard !isStopped,
              subscribers[vehicleId] != nil,
              !snapshotDelivered.contains(vehicleId),
              // MYR-432 — a vehicle the server has already refused `403` is not a
              // slow one. The fallback exists for a socket that failed to deliver,
              // not for a read that was answered.
              !snapshotAccessDenied.contains(vehicleId)
        else { return }
        await fetchAndEmitSnapshot(vehicleId: vehicleId, scope: .standalone)
    }

    /// Stop receiving updates for a vehicle. Finishes its streams and, if
    /// connected, sends an `unsubscribe` frame (does not close the socket).
    public func unsubscribe(from vehicleId: String) {
        if let continuations = subscribers.removeValue(forKey: vehicleId) {
            for continuation in continuations.values { continuation.finish() }
        }
        dataStates.removeValue(forKey: vehicleId)
        // MYR-319 — stop asking for a car nobody is watching any more.
        snapshotRetryTasks.removeValue(forKey: vehicleId)?.cancel()
        // MYR-387 — including the pending socket-independent fallback.
        standaloneSnapshotTasks.removeValue(forKey: vehicleId)?.cancel()
        snapshotDelivered.remove(vehicleId)
        // MYR-432 — a vehicle nobody is watching carries no verdict either.
        snapshotAccessDenied.remove(vehicleId)
        if connectionState == .connected, let channel {
            Task { try? await channel.send(WireCodec.encodeFrame(type: .unsubscribe, payload: UnsubscribePayload(vehicleId: vehicleId))) }
        }
    }

    // MARK: - MYR-432 — access revocation (§6.2 close code 4002)

    /// A stream of ``VehicleAccessRevocation``s — one per prune. Account-wide,
    /// like ``rideEvents()``, because a prune is a statement about the account's
    /// vehicle SET and the surface that has to release reads it as such.
    ///
    /// The app funnels this into the machinery that already exists for a shrinking
    /// vehicle list — the §7.0 list re-read and the release it drives — rather
    /// than into a second release path. There is exactly one definition of "this
    /// account no longer has that car", and it is the list.
    public func accessRevocations() -> AsyncStream<VehicleAccessRevocation> {
        let (stream, continuation) = AsyncStream<VehicleAccessRevocation>.makeStream()
        let id = UUID()
        accessObservers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeAccessObserver(id) }
        }
        return stream
    }

    /// Reconcile the live subscriptions against an authoritative access set,
    /// pruning every subscribed vehicle that is absent from it.
    ///
    /// Public because the same reconciliation is worth performing from the app's
    /// own §7.0 reads — a suspension the server enforces by dropping the row is
    /// visible there first if the socket happens to be down (MYR-369's viewer
    /// half). Idempotent and cheap: a set that contains everything subscribed
    /// does nothing at all.
    ///
    /// **THE SET IS THE AUTHORITY, NOT THE CLOSE CODE.** The close says only that
    /// SOMETHING changed; it names no vehicle, and a viewer revoked from one of
    /// two cars must keep the other streaming. Deriving the prune from the set
    /// makes the partial case fall out for free instead of being a second branch.
    @discardableResult
    public func applyAccessSet(_ accessible: Set<String>) -> VehicleAccessRevocation? {
        // A restored grant clears its 403 latch — access can come back, and a
        // permanent client-side refusal would outlive the server's decision.
        snapshotAccessDenied.subtract(accessible)
        let lost = Set(subscribers.keys).subtracting(accessible)
        guard !lost.isEmpty else { return nil }
        for vehicleId in lost { pruneRevokedVehicle(vehicleId) }
        // The prune settled it, so the access streak starts over: a LATER
        // revocation (a second car, minutes on) gets its own free re-handshake
        // rather than inheriting this one's escalation.
        accessCloseStreak = 0
        let revocation = VehicleAccessRevocation(revoked: lost, remaining: Set(subscribers.keys))
        for continuation in accessObservers.values { continuation.yield(revocation) }
        return revocation
    }

    /// Resolve the access set for the connection that has just authenticated and
    /// prune against it.
    ///
    /// A read that FAILS prunes nothing — MYR-326's rule, pointed at access: a
    /// list that did not answer is not evidence a car is gone, and guessing here
    /// would tear a working stream down every time the network blinked at the
    /// wrong moment. The vehicle then stays subscribed and, if the server closes
    /// again, `accessCloseStreak` escalates the backoff instead of looping.
    private func revalidateAccess() async {
        awaitingAccessRevalidation = false
        guard let accessListing else { return }
        guard let accessible = try? await accessListing.accessibleVehicleIDs() else { return }
        applyAccessSet(accessible)
    }

    /// Tear one revoked vehicle's subscription down: emit the terminal
    /// ``VehicleTelemetryEvent/accessRevoked``, finish the streams, and drop every
    /// piece of per-vehicle bookkeeping — including the MYR-387 standalone
    /// fallback and the MYR-319 retry ladder, which are the two things that would
    /// otherwise keep firing `GET /api/vehicles/{id}/snapshot` at a car we may not
    /// read.
    ///
    /// Deliberately sends NO `unsubscribe` frame. The connection that held the
    /// grant is already gone, and the fresh one never subscribed this vehicle —
    /// there is nothing on the server to cancel, and asking it to cancel a
    /// subscription it refused is one more request about a car we have no access
    /// to.
    private func pruneRevokedVehicle(_ vehicleId: String) {
        emit(.accessRevoked, to: vehicleId)
        if let continuations = subscribers.removeValue(forKey: vehicleId) {
            for continuation in continuations.values { continuation.finish() }
        }
        dataStates.removeValue(forKey: vehicleId)
        snapshotRetryTasks.removeValue(forKey: vehicleId)?.cancel()
        standaloneSnapshotTasks.removeValue(forKey: vehicleId)?.cancel()
        snapshotDelivered.remove(vehicleId)
        snapshotAccessDenied.insert(vehicleId)
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
        // MYR-319 — a pending cold-read retry must not outlive the connection.
        for task in snapshotRetryTasks.values { task.cancel() }
        snapshotRetryTasks.removeAll()
        // MYR-387 — nor a pending socket-independent fallback.
        for task in standaloneSnapshotTasks.values { task.cancel() }
        standaloneSnapshotTasks.removeAll()
        let channel = self.channel
        self.channel = nil
        authOK = false
        // MYR-432 — an explicit stop ends the access episode with it: a later
        // `connect()` is a fresh session, and inheriting a streak would deny it
        // the free re-handshake a first revocation is entitled to.
        awaitingAccessRevalidation = false
        accessCloseStreak = 0
        lastCloseCode = nil
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

                // MYR-432 — 4002 IS AN ACCESS SIGNAL, NOT TRANSPORT CHURN.
                //
                // The server closes with §6.2's `4002` within ~100µs of an owner
                // revoking or suspending a viewer. The JWT is still valid and the
                // very next handshake succeeds, so every ordinary reconnect
                // heuristic reads it as a healthy blip — which is precisely the
                // reported defect: re-handshake, `auth_ok` resets `attempt` to 0,
                // `onConnected` re-subscribes the vehicle that caused the close,
                // the server closes again. A ~1s loop plus one `403` snapshot read
                // per cycle, for as long as the app is open.
                //
                // ONE free re-handshake is granted, and it is the whole point: the
                // reduced access set is only knowable from a connection that has
                // authenticated, so standing down without reconnecting would blind
                // a viewer who was revoked from ONE of two cars. `awaitingAccessRevalidation`
                // is what makes that reconnect a QUESTION rather than a repetition
                // — see `revalidateAccess`, which prunes BEFORE `onConnected` can
                // re-subscribe anything.
                if TelemetryCloseCode.isAccessSignal(lastCloseCode) {
                    awaitingAccessRevalidation = true
                    accessCloseStreak += 1
                    if accessCloseStreak == 1 {
                        // The one free re-handshake: no backoff, `attempt`
                        // untouched, so a genuinely transient failure that follows
                        // still starts from where it would have.
                        lastCloseCode = nil
                        setConnectionState(.reconnecting)
                        continue
                    }
                    // A REPEATED access close means the prune did not settle it —
                    // an old server closing over a set we already agree with, or a
                    // listing we could not read. Escalate on the ACCESS streak,
                    // which the intervening `auth_ok` cannot reset. Without this
                    // the loop is permanent BY CONSTRUCTION however good the
                    // pruning is, because `attempt` is zeroed microseconds before
                    // every close.
                    attempt = max(attempt, accessCloseStreak - 1)
                }
                lastCloseCode = nil

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

        // MYR-432 — READ THE CLOSE CODE ON EVERY WAY OUT, not just on a failed
        // `receive()`.
        //
        // The first cut captured it inside the receive catch, which reads as
        // sufficient — a close is what makes a read fail. It is not: a close that
        // lands while the handshake is still in flight makes the `send` throw
        // instead, and the code is silently lost. That arm is not exotic (the
        // server closes ~100µs after the owner's tap, so a revoke during a
        // reconnect's own handshake hits it), and it is genuinely intermittent
        // rather than reproducible, which is exactly the kind of gap that ships.
        // It was found by a test that passed alone and failed inside the full
        // suite. The thrown error never carries the close frame — that is a
        // `URLSession` fact reported on the task — so this is the only place it
        // can be read, and it must be read before `defer` tears the channel down.
        do {
            // §2.2: the auth frame MUST be the first frame after the upgrade.
            let token = try await tokenProvider.token()
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
        } catch {
            if !isStopped { lastCloseCode = await channel.closeCode() }
            throw error
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
            // MYR-432 — THE PRUNE HAPPENS BEFORE THE RESUBSCRIBE, and the order is
            // the fix rather than an optimisation. `onConnected` re-subscribes
            // every key in `subscribers`; revalidating afterwards would send the
            // revoked vehicle's `subscribe` frame first and invite the identical
            // close a second time. Doing it here means that on BOTH server
            // generations — one that closes again, one that silently refuses the
            // subscribe (telemetry PR #369) — the frame is simply never sent.
            if awaitingAccessRevalidation {
                await revalidateAccess()
                guard gen == generation else { return }
            }
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

        case .rideRequestCreated:
            guard let payload = try? WireCodec.decodePayload(RideRequestCreatedPayload.self, from: envelope) else { return }
            emitRide(.created(payload))

        case .rideStatusChanged:
            guard let payload = try? WireCodec.decodePayload(RideStatusChangedPayload.self, from: envelope) else { return }
            emitRide(.statusChanged(payload))

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
        // MYR-387 — the socket got here; the fallback is not needed and must not
        // fire behind it.
        standaloneSnapshotTasks.removeValue(forKey: vehicleId)?.cancel()
        try? await channel.send(WireCodec.encodeFrame(type: .subscribe, payload: SubscribePayload(vehicleId: vehicleId)))
        await fetchAndEmitSnapshot(vehicleId: vehicleId, scope: .connection(generation: gen))
    }

    /// MYR-387 — what a cold read's emit is still VALID for.
    ///
    /// A read started by a connection belongs to that connection: if a newer one
    /// supersedes it, its answer describes a socket generation nobody is on any
    /// more and is dropped (invariant #5, unchanged). A `.standalone` read
    /// belongs to the SUBSCRIPTION — it is a plain REST fact about a vehicle
    /// somebody is watching, and no amount of socket churn makes it wrong.
    private enum SnapshotFetchScope {
        case connection(generation: Int)
        case standalone
    }

    /// Whether a fetch started under `scope` may still emit.
    private func isCurrent(_ scope: SnapshotFetchScope) -> Bool {
        switch scope {
        case .connection(let gen): return gen == generation
        case .standalone: return true
        }
    }

    /// Move the vehicle's groups to `.loading` (D-7), fetch the cold snapshot and
    /// emit it (D-1 on success, D-2 on failure). Extracted so the on-demand
    /// refresh below re-uses the EXACT path a (re)connect takes.
    ///
    /// MYR-319 — the fetch is RETRIED, because for a car that is not streaming
    /// this one read is not "the first of many": it is the only data event that
    /// will ever happen. A car that is offline or in service produces no
    /// `vehicle_update` frames at all, and the socket stays healthy — so nothing
    /// downstream re-triggers a cold read, and no reconnect comes along to
    /// perform one. Before this, a single failed ask (the `503 vehicle_asleep`
    /// a backend returns for exactly this car, or any transient blip) left
    /// `LiveVehicleState.state` nil for the whole session: the owner's sheet had
    /// no VIN, no software version, no composed model and no seat-cooling
    /// capability, from a snapshot the server was serving perfectly well a second
    /// later. The retry is bounded and backed off; a healthy first read is
    /// unchanged (one request, no delay).
    private func fetchAndEmitSnapshot(vehicleId: String, scope: SnapshotFetchScope) async {
        setDataState(vehicleId: vehicleId, groups: AtomicGroup.allCases, to: .loading)
        // The FIRST attempt stays inline, so the ordering guarantee is untouched:
        // a caller awaiting this (the receive loop, on `auth_ok`) still parks
        // until the snapshot has been emitted, and live frames still buffer
        // behind it (CG-SM-4).
        if await attemptSnapshot(vehicleId: vehicleId, scope: scope) { return }
        // The retries do NOT block the receive loop — parking it for a whole
        // backoff schedule would hold up every OTHER vehicle's live frames to
        // wait on one car that isn't answering.
        //
        // MYR-387 — one schedule per VEHICLE, whichever scope started it. A
        // connection coming up mid-schedule replaces the standalone one with its
        // own, which is right: that read is the one with the ordering guarantee.
        snapshotRetryTasks[vehicleId]?.cancel()
        // MYR-432 — a `403` on the inline attempt stops here: `attemptSnapshot`
        // returned `true` above, so no ladder is armed for a vehicle the server
        // has refused.
        snapshotRetryTasks[vehicleId] = Task { [weak self] in
            await self?.runSnapshotRetries(vehicleId: vehicleId, scope: scope)
        }
    }

    /// One cold-read attempt. `true` when the snapshot was emitted.
    private func attemptSnapshot(vehicleId: String, scope: SnapshotFetchScope) async -> Bool {
        // MYR-351 — stamped BEFORE the await, deliberately. This is the instant the
        // read was ISSUED, which is the only instant that says what the response
        // can possibly have seen. Stamping after the await would record when it
        // ARRIVED and would call a response that was served before a write "newer
        // than" that write.
        let issuedAt = Date()
        do {
            let snapshot = try await snapshotSource.snapshot(vehicleId: vehicleId)
            guard isCurrent(scope), subscribers[vehicleId] != nil else { return true }
            emit(.snapshot(snapshot, readIssuedAt: issuedAt), to: vehicleId)
            setDataState(vehicleId: vehicleId, groups: AtomicGroup.allCases, to: .ready)
            snapshotDelivered.insert(vehicleId) // MYR-387
            return true
        } catch {
            guard isCurrent(scope) else { return true } // superseded — stop, don't retry
            // Surface the failure NOW rather than claiming to still be loading
            // through the backoff. The last-known snapshot, if any, is retained
            // either way (NFR-3.12/3.13).
            setDataState(vehicleId: vehicleId, groups: AtomicGroup.allCases, to: .error)
            // MYR-432, §3 — DEFENSE IN DEPTH: a `403` is an ANSWER, not a blip.
            //
            // The MYR-319 ladder and the MYR-387 standalone fallback both exist
            // for a car that is slow to answer — an asleep vehicle, a `503`, a
            // transient blip — and retrying is right for every one of those. A
            // `403` is the server stating that this account may not read this
            // vehicle, and no amount of asking again changes that: it is what
            // produced the reported "~1–2 REST 403s per second, forever". The
            // server may also cut REST before the socket notices, so this must
            // stand on its own rather than lean on the prune.
            //
            // Latched per VEHICLE, and lifted by `applyAccessSet` the moment a
            // list read shows the grant back — a client-side refusal must never
            // outlive the server's decision.
            if (error as? RestError)?.httpStatus == 403 {
                snapshotAccessDenied.insert(vehicleId)
                return true // stop the ladder for THIS vehicle; others are untouched
            }
            return false
        }
    }

    /// The backed-off remainder of the attempt schedule. Abandons the moment the
    /// connection is superseded, the vehicle is unsubscribed, or the socket stops
    /// — a car nobody is watching must not keep costing requests.
    private func runSnapshotRetries(vehicleId: String, scope: SnapshotFetchScope) async {
        for delay in snapshotRetryDelays.dropFirst() {
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            if Task.isCancelled { return }
            guard isCurrent(scope), subscribers[vehicleId] != nil, !isStopped else { return }
            if await attemptSnapshot(vehicleId: vehicleId, scope: scope) { return }
        }
    }

    /// MYR-315 — re-fetch the §7.1 snapshot for an ALREADY-SUBSCRIBED vehicle and
    /// deliver it down the same `.snapshot` event path a reconnect uses, so the
    /// value lands in `LiveVehicleState` (and every view above it) through the
    /// normal pipeline rather than a second, parallel one.
    ///
    /// The two callers are both "the world may have moved without us": the app
    /// coming back to the foreground after a spell in the background, and the
    /// owner explicitly asking for a newer read (§7.15, which returns only a
    /// timestamp — the STATE still has to come from §7.1).
    ///
    /// A no-op when the vehicle is not subscribed: there is no stream to emit on,
    /// and fetching for a vehicle nobody is watching would spend a request to
    /// update nothing. Failures are absorbed into `.error` data state exactly as on
    /// reconnect — a refresh that can't reach the server must never clear the
    /// last-known snapshot (NFR-3.12/3.13).
    public func refreshSnapshot(vehicleId: String) async {
        guard subscribers[vehicleId] != nil else { return }
        // MYR-387 — `.standalone`, for the same reason `subscribe` is: this is a
        // REST read on behalf of a SUBSCRIPTION, and both of its callers (the
        // foreground resume and the owner's §7.15 wake) are situations in which
        // the socket may well be exactly what is broken. Gating it on the
        // connection generation would make the recovery unavailable precisely
        // when it is needed.
        await fetchAndEmitSnapshot(vehicleId: vehicleId, scope: .standalone)
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

    /// Fan a ride-request frame out to every ride observer (account-wide, not
    /// per-vehicle — see ``rideEvents()``).
    private func emitRide(_ event: RideRequestEvent) {
        for continuation in rideObservers.values { continuation.yield(event) }
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

    private func removeRideObserver(_ id: UUID) {
        rideObservers.removeValue(forKey: id)
    }

    private func removeAccessObserver(_ id: UUID) {
        accessObservers.removeValue(forKey: id)
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
