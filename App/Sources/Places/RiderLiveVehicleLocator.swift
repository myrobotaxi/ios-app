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

    /// MYR-398 v3 — the head row's IDENTIFICATION, as the Live Activity's pickup
    /// subline needs it (`7SRJ294 · Silver Model Y`).
    ///
    /// Published beside `fleetMembers` off the SAME list read rather than derived
    /// from it, because `FleetMember.plate` is `VehicleContractMapping.plateDisplay`
    /// — the owner's plate OR the `VIN ····2046` degrade — and the board's rule for
    /// this line is that a missing plate DROPS the segment rather than substituting
    /// four characters of hex nobody can read off a bumper. So the raw
    /// `VehicleSummary.licensePlate` has to survive the mapping, and the honest way
    /// to keep it is to keep the row's own fields.
    ///
    /// The HEAD, deliberately: the ride is created against `vehicles.first`
    /// (MYR-212/MYR-343), so the car the Activity describes is the car the request
    /// was made against, by construction rather than by a second lookup.
    private(set) var activityVehicle: RideActivityVehicle?

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
            // MYR-432 — the same §7.0 read this locator already makes, handed to
            // the socket so a §6.2 close can resolve the REDUCED access set from
            // the one list the whole rider shell treats as the truth about access
            // (MYR-369: a suspended grant simply leaves it).
            accessListing: rest,
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
            // MYR-449 — THE RIDER'S BRIDGE SEEDS FROM DELTAS, and this one argument
            // is the fix for "live tracking never engages". Until it existed, a
            // `vehicle_update` for a vehicle whose cold `/snapshot` had not landed
            // was discarded by `LiveVehicleState`, so the rider's whole live
            // surface hung on one REST read the VIEWER path can legitimately never
            // complete — a `403` latches `snapshotAccessDenied` for good (MYR-432),
            // the MYR-319 ladder is bounded, and MYR-440 recorded a viewer snapshot
            // retrying silently forever. The car streamed, the server delivered
            // viewer frames throughout every external-beta ride, and the tracking
            // sheet drew a route with no car on it.
            //
            // Safe here and NOT on the owner path for a reason that is about what
            // each side ASKS this state: the rider asks only where the car is, which
            // a delta answers on its own, while the owner's sheet renders identity
            // (model, VIN, software, seat capability) that only a snapshot carries.
            liveState: LiveVehicleState(vehicleId: next, socket: socket, seedsStateFromDeltas: true)
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
        observeAccessRevocations()
        telemetrySource?.start()
        loadFleet()
    }

    // MARK: - MYR-432 — a revoked grant stands the rider surface down

    /// MYR-432 — the count of access revocations this locator has seen.
    ///
    /// A COUNTER rather than a flag, and that is what makes it a usable trigger:
    /// a second revocation (the other car, minutes later) has to be
    /// distinguishable from the first, and a `Bool` that is already `true` fires
    /// no `onChange`. Nothing reads its VALUE — it is the edge that matters.
    private(set) var accessRevocationTick = 0

    @ObservationIgnored private var accessTask: Task<Void, Never>?

    /// MYR-432 — turn a §6.2 close into the ONE thing that already releases this
    /// surface: another §7.0 read.
    ///
    /// The socket has pruned its subscription by the time this runs, so the
    /// stream is over either way. What is left is the shell, which decides what
    /// the rider SEES from `RiderVehicleSet.resolve` over the catalog's two
    /// partitions — and that only moves when the list is re-read. So this does
    /// two things and builds nothing new: it drops the watched id (a car we may
    /// not see is not one to hold a slot for, and holding it would block
    /// `loadFleet`'s fallback from adopting a surviving car), and it bumps a tick
    /// the shell funnels into `refreshRideEndGateInputs()` + the catalog re-read.
    ///
    /// **A viewer revoked from ONE of two cars keeps the other**, and that falls
    /// out of the set rather than out of a branch here: the socket pruned only the
    /// absent vehicle, `refreshFleet()` republishes the reduced list, and the
    /// shell re-resolves `.ridable` on whatever survived.
    private func observeAccessRevocations() {
        guard accessTask == nil else { return }
        let socket = self.socket
        accessTask = Task { [weak self] in
            for await revocation in await socket.accessRevocations() {
                guard let self, self.started else { break }
                self.applyAccessRevocation(revocation)
            }
        }
    }

    private func applyAccessRevocation(_ revocation: VehicleAccessRevocation) {
        if let watched = watchedVehicleID, revocation.revoked.contains(watched) {
            watch(vehicleID: nil)
        }
        refreshFleet()
        accessRevocationTick += 1
    }

    /// MYR-402 — RE-READ `GET /api/vehicles`.
    ///
    /// **THE LIST WAS A ONE-SHOT, AND ONE OF ITS FIELDS IS A GATE.** Until this
    /// issue the only caller of the list load was `start()`, i.e. the rider map
    /// mounting, and `handleForeground` below refreshed the SOCKET's snapshot and
    /// nothing else. So `fleetMembers` — and with it `VehicleSummary.hasActiveRide`,
    /// which `LiveFleetMemberMapping.unavailability` turns into MYR-233's `.busy` —
    /// was fixed for the life of the process, and a **cold launch was the only thing
    /// in the app that could correct it.** That is exactly the client's "the app
    /// should not have to be forced closed" signature (MYR-402).
    ///
    /// It is worse than a stale read, because the staleness is MASKED while the ride
    /// runs and only surfaces when it ends: MYR-233's own-ride exception clears
    /// `.busy` for the rider holding the ride, so the gate opens the moment the ride
    /// is erased and the stale row underneath it becomes load-bearing. The rider's
    /// idle sheet therefore got MORE restrictive after their ride ended than during
    /// it — no ETA line, and MYR-352's "no rides right now" banner over a free car.
    ///
    /// Cheap and safe to call often: it coalesces onto any load already in flight,
    /// makes no request while the map is off screen, and a failed read changes
    /// nothing (MYR-326's rule — a list that did not answer is not evidence about a
    /// car).
    func refreshFleet() {
        guard started else { return }
        loadFleet()
    }

    /// The one list read. Coalesced on `loadTask` so the mount, the foreground and a
    /// ride ending in the same second cost one request rather than three.
    private func loadFleet() {
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
            // MYR-398 v3 — the same rows, kept RAW for the Live Activity's static
            // vehicle attribute. See `activityVehicle`.
            self?.activityVehicle = vehicles.first.map(RideActivityVehicle.init(summary:))
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

    /// MYR-449 — RE-ESTABLISH A STREAM THAT HAS GONE QUIET WITHOUT SAYING SO.
    ///
    /// **THE CLIENT CANNOT TELL A PARKED CAR FROM A DARK SOCKET, AND TWO REAL
    /// SERVER HAZARDS PRODUCE EXACTLY THE SECOND** (telemetry investigation on
    /// this issue, both in `internal/ws`):
    ///
    ///   • A transient `ResolveRole` failure at handshake is logged and skipped,
    ///     leaving no role entry. `roleFor` then answers `Role("")`, `mask.For`
    ///     returns the DENY-ALL zero mask, and **every** frame for that vehicle is
    ///     silently suppressed for the life of the connection. The 60s
    ///     `AccessRevalidator` reasons about vehicle ids only, never roles, so it
    ///     never closes the session. One momentary DB blip buys a permanently dark
    ///     socket, with `auth_ok` received, no error frame and no close.
    ///   • The handshake access set is written once and only ever NARROWS, so a
    ///     grant redeemed after the socket opened (or inside the 5-minute vehicle
    ///     cache TTL) is never picked up; an explicit `subscribe` is refused while
    ///     the connection deliberately stays open, so the SDK gets no reconnect
    ///     trigger either.
    ///
    /// From here both look identical to a car that is simply asleep, and the
    /// pre-MYR-449 client waited on all three for ever — the MYR-389/MYR-402
    /// "works after a force-quit" signature, on the surface a rider stares at
    /// hardest. So after the grace this stops waiting: drop the subscription and
    /// re-take it, which re-runs the handshake and therefore re-resolves BOTH the
    /// role and the access set.
    ///
    /// **BOUNDED, and that bound is the point.** `maxDarkStreamRecoveries` attempts
    /// per watched vehicle, because the honest end state for a car that is really
    /// asleep is the sheet SAYING so (`RiderTrackingLiveState.unavailable`), not a
    /// client reconnecting at it for the rest of the ride. A reconnect loop is the
    /// MYR-432 "~1–2 requests per second, forever" defect wearing a fix's clothes.
    static let maxDarkStreamRecoveries = 2

    @ObservationIgnored private var darkStreamRecoveries = 0

    /// How many times this locator has re-established a dark stream. Published for
    /// the tests — a recovery that cannot be counted cannot be shown to be bounded.
    private(set) var darkStreamRecoveryCount = 0

    func recoverDarkStream() {
        guard started, let vehicleID = watchedVehicleID else { return }
        guard darkStreamRecoveries < Self.maxDarkStreamRecoveries else { return }
        darkStreamRecoveries += 1
        darkStreamRecoveryCount += 1
        // Through `watch(vehicleID:)` in both directions rather than a bespoke
        // teardown: it is the ONE place that owns the source's lifecycle, and a
        // second copy of that sequence is a second place to leak a subscription.
        // The `nil` hop is what makes the re-take non-idempotent — `watch` guards
        // on an unchanged id precisely so a re-adopt costs nothing.
        watch(vehicleID: nil)
        watch(vehicleID: vehicleID)
        // The subscribe alone reaches a socket that is already up, and a dark
        // socket IS already up — so the connection itself has to be recycled for
        // the handshake to re-run. `connect()` after a `disconnect()` is the same
        // pair `handleBackground`/`handleForeground` perform.
        let socket = self.socket
        Task {
            await socket.disconnect()
            await socket.connect()
        }
    }

    func stop() {
        started = false
        darkStreamRecoveries = 0
        loadTask?.cancel()
        loadTask = nil
        accessTask?.cancel()
        accessTask = nil
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
        // MYR-402 — the LIST too, not only the socket. A ride can end while the app
        // is suspended (the client's case: cancelled server-side), and then the WS
        // frame that would have erased it never reaches this process. The snapshot
        // refetch below re-reads where the car IS; this re-reads whether it can take
        // a request, which is the other half and the half that was missing.
        refreshFleet()
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
