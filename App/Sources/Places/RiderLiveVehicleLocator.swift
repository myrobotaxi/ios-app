import CoreLocation
import Foundation
import MyRoboTaxiKit
import MyRobotaxiContracts
import Observation

// MARK: - RiderLiveVehicleLocator (MYR-211 d3 → MYR-212 d4 → MYR-352 → MYR-336)
//
// The rider's ONE live-vehicle seam. Three things hang off it, and MYR-336 makes
// the third of them real:
//
//   1. REGION FALLBACK (MYR-211 d3) — when the device fix is unavailable
//      (permission not yet granted / denied), the rider map and search bias to
//      the watched vehicle's region instead of the SF fixture (the client's "map
//      is in SF, vehicle is in Dallas" bug).
//   2. THE FLEET (MYR-212 d4, widened by MYR-352) — the whole `GET /api/vehicles`
//      list as `FleetMember`s, so Review/Booking name the REAL car and the idle
//      banner can ask "can ANY of them take a request?".
//   3. TELEMETRY (MYR-336) — the watched vehicle's LIVE position and status.
//
// **MYR-336 replaced the one-shot with the stream.** Until this issue (3) was a
// single `GET /api/vehicles/{id}/snapshot` fired once per `start()`: the rider
// map adopted the REAL car (MYR-184/343) and then watched it sit perfectly still
// for the whole session, because nothing ever asked again. That is the last
// fixture-SHAPED behaviour on the live path — not fixture data, but placeholder
// motion, which is the same lie told more quietly.
//
// It now runs the SAME machinery the owner side does, deliberately reusing the
// types rather than paraphrasing them: a `TelemetrySocket` (cold `/snapshot` on
// subscribe, MYR-319's bounded 0/0.8/3/9s retry ladder for an asleep or
// in-service car, and the socket's own reconnect/backoff supervision), a
// `LiveVehicleState` bridge folding `vehicle_update` deltas onto that snapshot,
// and `LiveVehicleTelemetrySource` projecting it through the production
// `VehicleContractMapping`. Nothing about drop/backoff is re-implemented here —
// which is the point: a second reconnect policy is a second one to get wrong.
//
// The backend grants a viewer snapshot + WS access for any shared vehicle at
// tier `live` and above (telemetry #344), and an owner obviously has their own,
// so both halves of MYR-343's adoption rule are subscribable. WHICH id is
// subscribed is not this type's decision: `SharedViewerState.adoptSharedVehicle`
// pushes the resolved vehicle in through `watch(vehicleID:)`, so the car on the
// map and the car on the socket can never be two different cars.
//
// WHAT the stream is allowed to say about a car the rider does not own is
// `RiderVehicleProjection`'s rule — position + status, never identity.
@Observable
@MainActor
final class RiderLiveVehicleLocator {

    /// MYR-352 — the WHOLE §7.0 list as `FleetMember`s, in wire order.
    ///
    /// The single `GET /api/vehicles` this type already performs returns every
    /// vehicle the account can see; MYR-212 kept only `.first` because that is the
    /// one the ride is created against. The idle banner's question is different —
    /// "can ANY of them take a request?" — and answering it from one row would
    /// tell a rider with a second, free car that no rides are available. So the
    /// rest of the rows are published rather than discarded: **no new fetch, no
    /// new endpoint, the same list**.
    ///
    /// This is NOT the multi-vehicle picker (still MYR-91 scope) — nothing here
    /// chooses a different car to ride. `fleetMember` remains `.first`, exactly as
    /// before, so every surface that requests, tracks or names a vehicle is
    /// untouched.
    private(set) var fleetMembers: [FleetMember] = []

    /// The account's first owned vehicle as a `FleetMember` (identity + live
    /// battery/availability), or `nil` until the vehicle list has loaded.
    var fleetMember: FleetMember? { fleetMembers.first }

    /// MYR-336 — the watched vehicle's live telemetry source, or `nil` before a
    /// vehicle has been adopted. Handed up to `SharedViewerState.telemetrySource`,
    /// so the rider map reads the same `VehicleTelemetrySnapshot` shape it always
    /// did and no screen learns a new type.
    private(set) var telemetrySource: LiveVehicleTelemetrySource?

    /// The vehicle id currently subscribed, or `nil`. Published so the adoption
    /// (owned vs. shared) is legible to tests without reaching into the socket.
    private(set) var watchedVehicleID: String?

    /// The accumulated live `VehicleState` for the watched vehicle, or `nil`
    /// before its cold snapshot lands. Retained across disconnects by the Kit
    /// bridge (NFR-3.12/3.13), so a dropped socket never blanks the map.
    var state: VehicleState? { telemetrySource?.state }

    /// The watched vehicle's live coordinate — the region fallback (1) and, since
    /// MYR-341, the point the rider's pickup ETA is measured FROM.
    ///
    /// `nil` until a snapshot carrying a real fix arrives (contract §2.3: `0,0`
    /// means "no fix"), which is unchanged from the one-shot era — the pre-fix
    /// rendering is the honest one and nothing downstream fabricates a position
    /// to fill the gap. What changed is that it now KEEPS UP.
    var coordinate: CLLocationCoordinate2D? { RiderVehicleProjection.coordinate(from: state) }

    @ObservationIgnored private let rest: RestClient
    @ObservationIgnored private let socket: TelemetrySocket
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// Whether the rider map is on screen (`SharedViewerState.startTelemetry`).
    /// The subscription follows it, so a rider in Settings holds no socket.
    @ObservationIgnored private var started = false

    init(config: LiveVehicleFleet.Config) {
        let http = config.http ?? URLSession(configuration: RestClient.defaultConfiguration())
        rest = RestClient(environment: config.environment, tokenProvider: config.tokenProvider, http: http)
        // The same socket construction `LiveVehicleFleet` and
        // `RideRequestComposition` make. v1 stance (RideRequestComposition's
        // header): each live consumer opens its own connection; the server
        // unicasts to every authed connection of the party. Consolidating the
        // fleet + ride + rider sockets is a future cleanup, not this issue's.
        socket = TelemetrySocket(
            webSocketURL: config.environment.webSocketURL,
            tokenProvider: config.tokenProvider,
            snapshotSource: rest,
            channelFactory: config.channelFactory ?? URLSessionWebSocketChannelFactory()
        )
    }

    // MARK: - MYR-336 — the watched subscription

    /// Point the live stream at the vehicle the rider shell adopted.
    ///
    /// Idempotent BY ID, for the same reason `SharedViewerState.adoptSharedVehicle`
    /// is: the catalog re-resolves on every foreground and every redeem, and
    /// tearing the subscription down and back up on an unchanged list would
    /// re-fetch a cold snapshot (and re-run its retry ladder) for a car we are
    /// already streaming.
    ///
    /// A `nil`/blank id releases the subscription — the honest state for a rider
    /// whose vehicle set resolved to nothing.
    func watch(vehicleID: String?) {
        let next = vehicleID.flatMap { $0.isEmpty ? nil : $0 }
        guard next != watchedVehicleID else { return }
        telemetrySource?.stop()
        watchedVehicleID = next
        guard let next else {
            telemetrySource = nil
            return
        }
        let source = LiveVehicleTelemetrySource(
            liveState: LiveVehicleState(vehicleId: next, socket: socket)
        )
        telemetrySource = source
        // `start()` opens the socket (idempotent) and fetches the cold snapshot.
        // Only while the map is actually on screen: adoption can land from the
        // catalog before the rider ever reaches the Live Map.
        if started { source.start() }
    }

    // MARK: - Lifecycle

    /// Fetch the fleet list and (re)start the watched vehicle's stream. Idempotent
    /// while a list load is in flight; safe to call again on foreground.
    func start() {
        started = true
        telemetrySource?.start()
        guard loadTask == nil else { return }
        let rest = self.rest
        loadTask = Task { [weak self] in
            defer { self?.loadTask = nil }
            guard let vehicles = try? await rest.vehicles() else { return }
            guard !Task.isCancelled else { return }
            // Publish the live fleet identity from the list rows (nickname, color,
            // charge, VIN, status). `first` stays the head of this list, so
            // `fleetMember` is unchanged.
            self?.fleetMembers = vehicles.map(LiveFleetMemberMapping.fleetMember(from:))
            // MYR-336 — the FALLBACK adoption, and it exists to preserve MYR-211's
            // guarantee exactly. The shell's adoption (`watch(vehicleID:)`, owned
            // first then the first grant) is the authority and always wins because
            // this only fires while nothing is watched; but if the shared-vehicle
            // catalog is slow or fails outright while THIS list succeeded, the
            // region fallback and the pickup ETA must still have a car — which is
            // precisely the `vehicles.first` the pre-MYR-336 one-shot used.
            if self?.watchedVehicleID == nil, let first = vehicles.first {
                self?.watch(vehicleID: first.vehicleId)
            }
        }
    }

    func stop() {
        started = false
        loadTask?.cancel()
        loadTask = nil
        telemetrySource?.stop()
        let socket = self.socket
        Task { await socket.disconnect() }
    }

    // MARK: - Scene lifecycle (mirrors `LiveVehicleFleet`)
    //
    // The socket's own supervision is what handles a DROP; these two forward the
    // app's suspend/resume so a backgrounded rider isn't holding a connection the
    // OS is about to starve, and so the resume re-asks rather than re-rendering
    // whatever was last in memory. Same shape as the owner fleet's handlers, and
    // gated on `started` for the same reason `SharedViewerState`'s are: a
    // foreground transition before the rider map ever mounted must not open a
    // socket.
    func handleBackground() {
        guard started else { return }
        let socket = self.socket
        Task { await socket.handleBackgroundTransition() }
    }

    func handleForeground() {
        guard started else { return }
        let socket = self.socket
        let vehicleID = watchedVehicleID
        Task {
            await socket.handleForegroundTransition()
            // The nudge reconnects; the snapshot refetch is what actually updates
            // a car that moved while the app was suspended (§7.15's lesson on the
            // owner side — the wake is not the read). Runs the same bounded retry
            // schedule, so an asleep car costs nothing extra.
            if let vehicleID { await socket.refreshSnapshot(vehicleId: vehicleID) }
        }
    }
}
