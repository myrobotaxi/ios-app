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

        init(
            environment: BackendEnvironment,
            tokenProvider: any TokenProvider,
            http: (any HTTPPerforming)? = nil,
            channelFactory: (any WebSocketChannelFactory)? = nil
        ) {
            self.environment = environment
            self.tokenProvider = tokenProvider
            self.http = http
            self.channelFactory = channelFactory
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

    private(set) var statusMessage: String?

    init(config: Config) {
        environment = config.environment
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

    func handleForeground() {
        let socket = self.socket
        Task { await socket.handleForegroundTransition() }
        // If a prior load failed or never happened, retry on foreground — the
        // low-friction recovery the design prefers over a retry button.
        if started, statusMessage != nil || !hasLoaded {
            loadFleet()
        }
    }

    func handleBackground() {
        let socket = self.socket
        Task { await socket.handleBackgroundTransition() }
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
        summaries = items
        sources = items.map { summary in
            LiveVehicleTelemetrySource(liveState: LiveVehicleState(vehicleId: summary.vehicleId, socket: socket))
        }
        executors = items.map { summary in
            LiveVehicleCommandExecutor(
                vehicleID: summary.vehicleId,
                sender: rest,
                driving: summary.status == .driving,
                plate: VehicleContractMapping.plateDisplay(vinLast4: summary.vinLast4)
            )
        }
        feeds = items.map { summary in
            LiveDrivesFeed(rest: rest, vehicleID: summary.vehicleId)
        }
        // FR-9.2 — a completed drive on a vehicle refreshes its own drive feed
        // (first page) so it appears without a manual re-fetch. Only the active
        // vehicle's socket delivers frames, so only its feed refreshes.
        for (source, feed) in zip(sources, feeds) {
            source.liveState.onDriveEnded = { [weak feed] _ in feed?.refresh() }
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
