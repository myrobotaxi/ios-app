import DesignSystem
import Foundation
import MyRoboTaxiKit
import MyRobotaxiContracts
import Observation

// MARK: - LiveVehicleFleet (MYR-201 deliverables 1, 3, 4)
//
// The Kit-backed `VehicleFleet`: REST `vehicles()` for the fleet list, a single
// shared `TelemetrySocket` whose subscription is narrowed to the SELECTED
// vehicle (per deliverable 1), and `VehicleContractMapping` from contracts types
// onto the app's `Vehicle`/`VehicleTelemetrySnapshot`. Command execution stays
// simulated — the signed-command proxy is P11 (NOT ready); this issue is the
// read-path.
//
// Lifecycle (deliverable 4): the socket connects when the selected vehicle's
// `LiveVehicleTelemetrySource.start()` runs (on owner-home appear, via
// `OwnerHomeState.startTelemetry`); background/foreground are forwarded to the
// Kit's `handleBackgroundTransition`/`handleForegroundTransition`. `stop()`
// disconnects and releases the streams — a re-entry cycle is leak-free because
// every `LiveVehicleState` cancels its stream tasks and unsubscribes on `stop()`.
@Observable
@MainActor
final class LiveVehicleFleet: VehicleFleet {

    struct Config {
        var environment: BackendEnvironment
        var tokenProvider: any TokenProvider
        /// Injected transport for tests (nil → a tuned `URLSession` in production).
        var http: (any HTTPPerforming)?
        /// Injected WS channel factory for tests (nil → the URLSession factory).
        var channelFactory: (any WebSocketChannelFactory)?
        /// MYR-315 — injected clock for the foreground-refetch debounce (nil →
        /// `Date.init`), so the policy is provable without a 10s sleep.
        var now: (() -> Date)?

        init(
            environment: BackendEnvironment,
            tokenProvider: any TokenProvider,
            http: (any HTTPPerforming)? = nil,
            channelFactory: (any WebSocketChannelFactory)? = nil,
            now: (() -> Date)? = nil
        ) {
            self.environment = environment
            self.tokenProvider = tokenProvider
            self.http = http
            self.channelFactory = channelFactory
            self.now = now
        }
    }

    private let environment: BackendEnvironment
    private let rest: RestClient
    private let socket: TelemetrySocket

    /// REST list rows (identity + model/year/color + last-known status/charge).
    private var summaries: [VehicleSummary] = []
    /// Parallel to `summaries` — one Kit-backed source per vehicle; only the
    /// active one holds a live subscription.
    private var sources: [LiveVehicleTelemetrySource] = []
    /// Parallel to `summaries` — one live command executor per vehicle, routing
    /// the backend-backed owner controls to the §7.9 command endpoint (MYR-249).
    private var executors: [any VehicleCommandExecutor] = []
    /// Parallel to `summaries` — one cursor-paginated live drive feed per vehicle
    /// (MYR-203), so pagination + loaded pages survive a tab switch.
    private var feeds: [LiveDrivesFeed] = []

    private var started = false
    private var hasLoaded = false
    private var activeIndex = 0
    private var loadTask: Task<Void, Never>?
    /// MYR-315 — when the app last went to `.background`, so the resume can tell a
    /// glance at Control Center from a genuine spell away (see
    /// `ForegroundRefetchPolicy`). `nil` before the first background transition.
    private var backgroundedAt: Date?
    /// Injected clock, so the foreground debounce is testable without sleeping.
    private let now: () -> Date

    private(set) var statusMessage: String?

    init(config: Config) {
        environment = config.environment
        now = config.now ?? Date.init
        let http = config.http ?? URLSession(configuration: RestClient.defaultConfiguration())
        rest = RestClient(environment: config.environment, tokenProvider: config.tokenProvider, http: http)
        socket = TelemetrySocket(
            webSocketURL: config.environment.webSocketURL,
            tokenProvider: config.tokenProvider,
            snapshotSource: rest,
            channelFactory: config.channelFactory ?? URLSessionWebSocketChannelFactory()
        )
    }

    // MARK: VehicleFleet

    /// Fleet rows, folding each vehicle's live `VehicleState` (once it arrives)
    /// onto its summary. Reading `source.state` here makes the switcher + hero
    /// reactive to live updates through `@Observable`.
    var vehicles: [Vehicle] {
        zip(summaries, sources).map { summary, source in
            VehicleContractMapping.vehicle(summary: summary, state: source.state)
        }
    }

    /// Subtle connecting state (deliverable 3): true while the fleet list is
    /// still loading, or while the SELECTED vehicle's first snapshot is in flight
    /// — so the screen shows one calm "Connecting…" pass, then real data appears
    /// at once (no 0%/blank flash). Suppressed once a `statusMessage` is set.
    var isConnecting: Bool {
        if statusMessage != nil { return false }
        if !hasLoaded { return true }
        guard sources.indices.contains(activeIndex) else { return false }
        return sources[activeIndex].state == nil
    }

    func telemetry(at index: Int) -> any VehicleTelemetrySource {
        guard sources.indices.contains(index) else { return LiveVehicleTelemetrySource(liveState: makeDetachedState()) }
        return sources[index]
    }

    func commandExecutor(at index: Int) -> any VehicleCommandExecutor {
        guard executors.indices.contains(index) else {
            return SimulatedVehicleCommandExecutor(driving: false, plate: "")
        }
        return executors[index]
    }

    func drivesFeed(at index: Int) -> any DrivesFeed {
        guard feeds.indices.contains(index) else {
            // Out of range (fleet still loading / empty): a detached live feed
            // bound to no vehicle — never fetches, shows nothing. Keeps the API
            // total without vending a fixture feed in live mode.
            return LiveDrivesFeed(rest: rest, vehicleID: "")
        }
        return feeds[index]
    }

    func badgeStatus(at index: Int) -> MRTVehicleStatus {
        guard summaries.indices.contains(index) else { return .offline }
        let state = sources.indices.contains(index) ? sources[index].state : nil
        return VehicleContractMapping.badgeStatus(forSummary: summaries[index], state: state)
    }

    func start() {
        guard !started else { return }
        started = true
        loadFleet()
    }

    func stop() {
        started = false
        loadTask?.cancel()
        loadTask = nil
        sources.forEach { $0.stop() }
        let socket = self.socket
        Task { await socket.disconnect() }
    }

    func setActive(index: Int) {
        guard index != activeIndex else { return }
        // Narrow the socket subscription to the newly selected vehicle: drop the
        // old subscription, open the new one (which fetches its cold snapshot).
        if sources.indices.contains(activeIndex) { sources[activeIndex].stop() }
        activeIndex = index
        if started, sources.indices.contains(activeIndex) { sources[activeIndex].start() }
    }

    /// MYR-201 nudged the socket here and, if a prior load had FAILED, retried it.
    /// That left the ordinary case — a healthy fleet, the app backgrounded for an
    /// hour — refetching nothing: iOS suspends the process, the socket is quietly
    /// dead for the whole spell, and the sheet re-renders whatever was last in
    /// memory until the watchdog eventually notices. MYR-315 adds the two refetches
    /// that make coming back to the app mean something, behind a debounce so a
    /// glance at another app doesn't cost two requests:
    ///
    ///   1. the WS reconnect nudge (unchanged — cheap, and correct at any interval),
    ///   2. the fleet LIST (`GET /api/vehicles`), which is what carries a car that
    ///      went in-service / a plate edited on another device,
    ///   3. the selected vehicle's SNAPSHOT, down the same `.snapshot` event path a
    ///      reconnect uses, so every view above it updates from one source.
    func handleForeground() {
        let socket = self.socket
        // Always nudge: it costs nothing when the socket is healthy, and it is the
        // fastest path back when it isn't.
        Task { await socket.handleForegroundTransition() }

        let backgroundedFor = backgroundedAt.map { now().timeIntervalSince($0) }
        backgroundedAt = nil
        guard started else { return }

        // Pre-existing recovery: a load that failed or never happened is retried on
        // EVERY resume, debounce or not — it is the low-friction recovery the design
        // prefers over a retry button, and there is nothing to preserve.
        if statusMessage != nil || !hasLoaded {
            loadFleet()
            return
        }
        guard ForegroundRefetchPolicy.shouldRefetch(backgroundedFor: backgroundedFor) else { return }
        loadFleet()
        refreshActiveSnapshot()
    }

    func handleBackground() {
        backgroundedAt = now()
        let socket = self.socket
        Task { await socket.handleBackgroundTransition() }
    }

    // MARK: - On-demand refresh (MYR-315, rest-api.md §7.15)

    /// Ask the server for a newer read of one vehicle, then pull the resulting
    /// STATE down the normal pipeline. §7.15 answers with a status + a timestamp
    /// only — it is the wake, not the read — so the snapshot refetch is what
    /// actually updates the sheet. It runs on BOTH statuses: `fresh` means the
    /// server has newer data than we may have folded, not that we already hold it.
    func refreshVehicle(at index: Int) async throws -> VehicleRefreshOutcome {
        guard summaries.indices.contains(index) else { return .unsupported }
        let vehicleID = summaries[index].vehicleId
        let response = try await rest.refreshVehicle(id: vehicleID)
        await socket.refreshSnapshot(vehicleId: vehicleID)
        return response.status.didWake ? .refreshed : .fresh
    }

    /// Re-fetch the SELECTED vehicle's snapshot. Only the active vehicle holds a
    /// socket subscription (deliverable 1), so it is the only one with a stream to
    /// deliver on — refetching the others would be a request per car to update
    /// nothing.
    private func refreshActiveSnapshot() {
        guard summaries.indices.contains(activeIndex) else { return }
        let vehicleID = summaries[activeIndex].vehicleId
        let socket = self.socket
        Task { await socket.refreshSnapshot(vehicleId: vehicleID) }
    }

    /// MYR-258 (§7.12) — drop a vehicle after its authoritative backend teardown.
    /// Releases that vehicle's live source (unsubscribes its socket stream) and
    /// its parallel executor/feed, keeping the four arrays aligned. Re-narrows the
    /// active index and re-subscribes the new selection if the removed row was at
    /// or before the active one, so the switcher never points past the end. A no-op
    /// if the id isn't present (idempotent — matches the endpoint's re-remove
    /// no-op).
    func remove(vehicleID: String) {
        guard let removedIndex = summaries.firstIndex(where: { $0.vehicleId == vehicleID }) else { return }
        sources[removedIndex].stop()
        summaries.remove(at: removedIndex)
        sources.remove(at: removedIndex)
        executors.remove(at: removedIndex)
        feeds.remove(at: removedIndex)

        if summaries.isEmpty {
            activeIndex = 0
            statusMessage = "No vehicles linked to this account"
            return
        }
        // Keep the active subscription valid: clamp the index, and if the removal
        // shifted the active vehicle, subscribe the row now sitting at activeIndex.
        let wasActiveAffected = removedIndex <= activeIndex
        activeIndex = min(activeIndex, summaries.count - 1)
        if started, wasActiveAffected, sources.indices.contains(activeIndex) {
            sources[activeIndex].start()
        }
    }

    // MARK: - Fleet load

    private func loadFleet() {
        loadTask?.cancel()
        statusMessage = nil
        let rest = self.rest
        loadTask = Task { [weak self] in
            do {
                let items = try await rest.vehicles()
                guard !Task.isCancelled else { return }
                self?.applyLoaded(items)
            } catch {
                guard !Task.isCancelled else { return }
                self?.applyLoadFailure(error)
            }
        }
    }

    private func applyLoaded(_ items: [VehicleSummary]) {
        hasLoaded = true

        // MYR-315 — a REPEAT load (the foreground refetch) of an unchanged fleet
        // must adopt the new row values WITHOUT rebuilding the live objects below.
        // Rebuilding drops every accumulated `LiveVehicleState`, so the selected
        // vehicle's `state` goes nil, `isConnecting` flips true, and `HomeScreen`
        // replaces the whole map+sheet with "Connecting to your vehicles…" — on
        // every single resume. The rows themselves (status, charge, plate) are
        // exactly what we came back for, so they are taken; the sources, executors
        // and drive feeds keep their subscriptions, reconcile hooks and pagination.
        if !sources.isEmpty, summaries.map(\.vehicleId) == items.map(\.vehicleId) {
            summaries = items
            statusMessage = nil
            return
        }

        summaries = items
        sources = items.map { summary in
            LiveVehicleTelemetrySource(liveState: LiveVehicleState(vehicleId: summary.vehicleId, socket: socket))
        }
        let liveExecutors = items.map { summary in
            LiveVehicleCommandExecutor(
                vehicleID: summary.vehicleId,
                sender: rest,
                plateEndpoint: rest,
                driving: summary.status == .driving,
                // MYR-286 — the RAW owner-entered plate (empty when unset), NOT
                // the `VIN ····xxxx` display string: `controls.plate` is what the
                // edit sheet prefills, and a VIN belongs in the display fallback,
                // not in an editable text field. The snapshot reconciles it, and
                // §7.14's echo replaces it on save.
                plate: VehicleContractMapping.editablePlate(licensePlate: summary.licensePlate)
            )
        }
        executors = liveExecutors
        feeds = items.map { summary in
            LiveDrivesFeed(rest: rest, vehicleID: summary.vehicleId)
        }
        // FR-9.2 — a completed drive on a vehicle refreshes its own drive feed
        // (first page) so it appears without a manual re-fetch. Only the active
        // vehicle's socket delivers frames, so only its feed refreshes.
        for (source, feed) in zip(sources, feeds) {
            source.liveState.onDriveEnded = { [weak feed] _ in feed?.refresh() }
        }
        // MYR-252 — reconcile the owner-control read-back fields the v0.12.0
        // `VehicleState` now carries: on every snapshot/delta, fold the real
        // lock/climate/seat/trunk/charge-port/media state into the executor so its
        // tiles flip from honest-"—" to the car's true state. Only the active
        // vehicle's socket delivers frames, so only its executor reconciles.
        for (source, executor) in zip(sources, liveExecutors) {
            source.liveState.onStateChanged = { [weak executor] state in
                executor?.reconcile(from: state)
            }
        }
        // MYR-286 — §7.14 fires NO WebSocket push, so a saved plate would not reach
        // the fleet row (map-header switcher, Settings rows, the rider's chip after
        // the next list fetch) until the next `GET /api/vehicles`. Adopt the
        // server's normalized echo straight into the summary row instead: the
        // `vehicles` computed property re-derives `Vehicle.plate` from it, so every
        // display surface updates at once and from ONE source of truth.
        for (index, executor) in liveExecutors.enumerated() {
            let vehicleID = items[index].vehicleId
            executor.onPlateSaved = { [weak self] normalized in
                guard let self,
                      let row = self.summaries.firstIndex(where: { $0.vehicleId == vehicleID })
                else { return }
                self.summaries[row].licensePlate = normalized
            }
        }
        if items.isEmpty {
            statusMessage = "No vehicles linked to this account"
            return
        }
        activeIndex = min(activeIndex, items.count - 1)
        // Subscribe only the selected vehicle (deliverable 1); its start() opens
        // the socket (idempotent) and fetches the cold snapshot.
        if started {
            sources[activeIndex].start()
        }
    }

    private func applyLoadFailure(_ error: Error) {
        hasLoaded = false
        statusMessage = Self.message(for: error)
    }

    /// Subtle, non-dramatic copy for the graceful state. The auth (401) case is
    /// the expected one when no valid token is supplied.
    static func message(for error: Error) -> String {
        if let restError = error as? RestError {
            switch restError {
            case .http(let status, _, _, _) where status == 401:
                return "Sign-in required to load vehicles"
            case .http(let status, _, _, _) where status == 403:
                return "This account can't access telemetry"
            case .insecureTransport:
                return "Telemetry endpoint is misconfigured"
            default:
                return "Can't reach telemetry right now"
            }
        }
        return "Can't reach telemetry right now"
    }

    /// A throwaway `LiveVehicleState` for the (unreachable) out-of-range
    /// `telemetry(at:)` guard — never subscribed. Keeps the API total.
    private func makeDetachedState() -> LiveVehicleState {
        LiveVehicleState(vehicleId: "", socket: socket)
    }
}
