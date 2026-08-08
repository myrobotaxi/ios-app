import CoreLocation
import DesignSystem
// MYR-393 — the tracking surface's motion + marker inputs are the live
// `VehicleState` itself (speed, status, fix, read time), read through the pure
// resolvers in `RiderMotionLadder.swift`.
import MyRobotaxiContracts
import Observation

// MARK: - Rider sheet phase (MYR-191, extended MYR-171)
//
// screens.jsx's `SharedViewerScreen` drives its expanding request sheet off
// a local `phase` string (screens.jsx:1869 `useState(initialPhase || 'idle')`)
// that `ExpandingRequestSheet` switches on (design/app/ride-request.jsx
// 1218-1249: 'idle' | 'search' | 'pinDrop' | 'review' | 'pending' |
// 'tracking'). MYR-191 ("rider shell") shipped only the resting map +
// greeting sheet (`.idle`); MYR-171 adds one case per remaining phase. Two
// notes on naming vs. the jsx: (1) `.tracking`/`.summary` are split into two
// cases here even though the jsx renders both from its single `'tracking'`
// phase (switching content once `trackProgress >= 0.999`, ride-request.jsx:
// 1125,1245 `isSummary`) — the split matches this story's own deliverable
// list and keeps `SharedViewerScreen`'s switch exhaustive per rendered
// layout; (2) `.pending` is named `.booking` to match CLAUDE.md's phase list
// ("search, pinDrop, review, booking, tracking, summary") — same phase,
// friendlier name for a case that's rendering a "Booking ride with {owner}"
// title.
public enum RiderSheetPhase: Equatable, Sendable {
    case idle
    case search
    case pinDrop(returnTo: PinDropReturn)
    case review
    case booking
    case tracking
    case summary
}

/// Where `.pinDrop` returns to once the pickup pin is confirmed —
/// ride-request.jsx's `pinReturn` (`'search'` from the pickup row's "Set on
/// map"; `'review'` when a destination was picked with no pickup set yet, or
/// from the idle sheet's Home/Work quick chips, screens.jsx:2195).
public enum PinDropReturn: Equatable, Sendable {
    case search
    case review
}

/// MYR-382 — where the SCHEDULE CARD returns to once a pickup time is committed.
///
/// *"When I select schedule with lunar we go back 2 steps to the schedule button
/// again!"* MYR-233's busy-vehicle CTA sends the rider from Review to the search
/// sheet with the picker armed, which is right — the picker lives on that sheet —
/// but the journey ENDED there: setting a time closed the card and left the rider
/// on Search, with a destination already chosen, a vehicle already picked, and two
/// taps (Continue → Review) between them and the CTA they had been about to press.
/// The route out of Review was one-way.
///
/// It is a round trip now, modelled exactly like `PinDropReturn` above — the same
/// shape of problem (leave a sheet to pick one value, come back with it) already
/// solved once in this flow. `.review` is set ONLY by `routeToScheduling()`; the
/// two entries that are already ON the search sheet (the Schedule chip and the
/// "Pickup {day} · {time}" summary row's Edit) leave it `.search` and behave
/// exactly as they did.
public enum ScheduleCardReturn: Equatable, Sendable {
    case search
    case review
}

// MARK: - Shared viewer state (MYR-191, extended MYR-171)
//
// Owns the rider's live-map telemetry + sheet phase + in-progress request
// draft, lifted above the `sharedTab` switch in `RootView` — mirrors
// `OwnerHomeState`'s reasoning (see that file's header comment) so the
// watched vehicle's ticking telemetry (and, as of MYR-171, the rider's place
// in the request flow) survives switching to Ride History/Settings and back.
//
// MYR-336: "live-map telemetry" is finally literal. The watched vehicle's
// position and status come from a real `TelemetrySocket` subscription (held by
// `RiderLiveVehicleLocator`) on the live path, and from the MYR-191 fixture
// ticker in sim — one `AppMode` seam (`isLiveLocation`), the same one every
// other live-only branch in this file reads.
@Observable
@MainActor
public final class SharedViewerState {
    /// The one shared vehicle the rider is watching on the live map
    /// (screens.jsx:1865 `v = VEHICLES[0]`). Distinct from `FLEET`
    /// (screens.jsx:15-19, ported as `RideRequestFixtures.fleet`) — the
    /// Teslas the rider can actually *request* in Review; M1 fixes the
    /// resting map's view to this one vehicle regardless of which fleet
    /// member ends up carrying an active request.
    ///
    /// MYR-184 — now OPTIONAL, and that is the point. It used to default to
    /// `VehicleFixtures.vehicles[0]` with **no live gate at all**: a signed-in
    /// rider with nothing shared with them watched a map captioned "Cybercab", a
    /// car that does not exist on any account (MYR-228 fix (c)). On the live path
    /// it is seeded `nil` and ADOPTED from the first `role: viewer` row in
    /// `SharedVehicleCatalog`; `nil` means the shell renders its honest empty
    /// state instead of this screen. SIM still seeds `VehicleFixtures.vehicles[0]`,
    /// so every simulated + DEBUG capture is unchanged.
    public private(set) var sharedVehicle: Vehicle?
    /// The rider's watched-vehicle telemetry.
    ///
    /// MYR-184 fixed the vehicle's IDENTITY (name/model/plate off the real
    /// `VehicleSummary` through the production `VehicleContractMapping`) and left
    /// its DATA simulated — a real shared car on a fixture ticker. **MYR-336
    /// closes that seam**: on the live path this resolves to the watched vehicle's
    /// `LiveVehicleTelemetrySource` (`TelemetrySocket` cold snapshot + WS deltas,
    /// owned by `RiderLiveVehicleLocator`), and on the simulated path it stays the
    /// MYR-191 ticker below, byte-for-byte.
    ///
    /// Resolved rather than stored, so the flip from "no snapshot yet" to "live"
    /// needs no re-assignment and no re-created object: `@Observable` tracking
    /// reaches through the locator to the Kit bridge exactly as it does for the
    /// owner sheet (see `LiveVehicleTelemetrySource`'s observation note).
    public var telemetrySource: any VehicleTelemetrySource {
        liveTelemetrySource ?? simulatedTelemetrySource
    }

    /// The live source for the watched vehicle, or `nil` in sim / before adoption.
    /// The ONE `AppMode` gate for MYR-336 — `isLiveLocation` is the same resolved
    /// seam every other live-only branch in this file reads.
    var liveTelemetrySource: LiveVehicleTelemetrySource? {
        guard isLiveLocation else { return nil }
        return liveVehicleLocator?.telemetrySource
    }

    /// The MYR-191 fixture ticker. Re-created on adoption so its activity matches
    /// the vehicle it belongs to; started only in sim (MYR-336 — a live rider has
    /// no use for a fixture ticker, and running one under a live map is exactly
    /// the class of thing MYR-228 exists to prevent).
    private(set) var simulatedTelemetrySource: any VehicleTelemetrySource

    // MARK: MYR-211 — real place search + location seams
    //
    // Injected by `PlaceSearchComposition` (sim fixtures by default, live
    // MapKit/CoreLocation when the launch env selects it). The search sheet
    // reads `placeSearch.results`; the map/pin-drop read `mapRegionCenter` +
    // `userLocation`. See each seam's header for the sim↔live contract.
    let placeSearch: any PlaceSearching
    let userLocation: any UserLocationProviding
    let liveVehicleLocator: RiderLiveVehicleLocator?
    let pinLabeler: any RidePinLabeling
    /// True only when the live seams are composed — gates the real pin-drop
    /// coordinate (device/vehicle region) below.
    let isLiveLocation: Bool

    /// MYR-385 — the schedule picker's §7.22 conflict read.
    ///
    /// Held HERE, not as `@State` on `RideRequestSearchContent`, for the reason
    /// `rideRouteStore` and `recentDestinations` are: the round-4 engine keeps that
    /// content mounted across the whole idle↔search range but `RootView` still
    /// destroys the rider shell on a tab switch, and a per-mount cache would spend
    /// a fresh request on every re-entry to a picker the rider already opened.
    ///
    /// Constructed on BOTH paths — with a `nil` provider in sim, which is a store
    /// that cannot fetch (see `RideBookedWindowsStore`). One non-optional property
    /// with a disabled interior beats an optional the picker has to unwrap: there
    /// is no `if isLive` in the card, so there is no `if isLive` to get backwards.
    let bookedWindows: RideBookedWindowsStore

    /// MYR-191 extension point — see `RiderSheetPhase`.
    public var sheetPhase: RiderSheetPhase = .idle {
        didSet {
            // MYR-449 — the ONE funnel that arms the tracking surface's honest-state
            // clock. On the phase rather than at a call site, because `.tracking` is
            // reached from an accept, from a cold-launch adoption and from a push
            // tap, and an exit-side arm would be as complete as the exit list was on
            // the day it was written (MYR-389's lesson, stated the other way round).
            // `arm` is idempotent, so the repeated writes a SwiftUI body performs
            // cannot restart the grace.
            if sheetPhase == .tracking { armTrackingLiveWatch() } else { trackingLiveWatch.disarm() }
        }
    }

    // MARK: MYR-171 — in-progress request draft
    //
    // Local UI-only fields the rider fills in across Search → PinDrop →
    // Review before `RideRequestService.submit(_:)` stamps them into a
    // shared `RideRequestRecord`. Kept here (not in the service) because
    // they're per-device draft state with no cross-role meaning until
    // submitted — mirrors `SharedViewerScreen`'s own local `useState`s in the
    // jsx (`requestDest`, `requestPassenger`, …, screens.jsx:1866-1885).

    public var draftPickup: RidePlace?
    public var draftDestination: RidePlace?
    public var draftFleetMemberID: String = RideRequestFixtures.fleet[0].id
    public var draftPassenger: RidePassenger?
    public var draftSchedule: RideSchedule?
    /// Set by the idle sheet's Home/Work chips or Search's "Set on map" —
    /// where `.pinDrop` should write its confirmed pin back into.
    public var pinReturn: PinDropReturn = .search
    /// Drives `DeclinedNotice`'s overlay on `.search` (ride-request.jsx:
    /// 1254-1258) — a rejected request shows this once, then the rider
    /// dismisses or rebooks; it isn't a `RiderSheetPhase` case of its own
    /// (the jsx overlays it on top of `search`, not a separate screen).
    public var showDeclinedNotice = false

    /// MYR-381 (shipping MYR-306's `.declined` variant on MYR-292's precedent) —
    /// the id of the declined ride the rider has ALREADY DISMISSED.
    ///
    /// *"I already dismissed the declined ride, why is it showing up again?"* —
    /// TestFlight r14. `showDeclinedNotice` is raised from the HELD RECORD every
    /// time the rider screen reconciles (mount, foreground refetch, WS frame,
    /// MYR-376's due-refetch), and a declined ride stays in the slot on purpose —
    /// so a dismissal that only lowered the flag was undone by the very next
    /// reconcile.
    ///
    /// It lives HERE, on the rider-scoped observable, for exactly the reason
    /// `OwnerHomeState.acknowledgedCompletedRideID` does: `RootView` builds the
    /// rider shell inside a `switch`, so view `@State` is destroyed by a tab
    /// switch — and the record outlives it. Keyed by RIDE ID rather than a bare
    /// flag, so the dismissal is permanent for THIS ride and no ride at all for
    /// the next one.
    public var acknowledgedDeclinedRideID: String?

    /// The rider dismissed (or rebooked past) the declined card for `rideID`.
    /// Lowers the notice and records the acknowledgement in one place, so a caller
    /// cannot do half of it.
    public func acknowledgeDeclined(rideID: String?) {
        showDeclinedNotice = false
        guard let rideID else { return }
        acknowledgedDeclinedRideID = rideID
    }

    /// MYR-233 (acceptance criterion 2): the instant CTA on an unavailable
    /// vehicle routes the rider TOWARD the scheduling flow rather than dead-
    /// ending. The scheduling affordance is the Search sheet's "Schedule" chip
    /// slide-up card, so Review sets this and hands back to `.search`;
    /// `RideRequestSearchContent` consumes it once on appear and opens the card.
    /// One-shot — cleared by the consumer, and by `resetDraftToIdle()`.
    public var opensScheduleOnSearch = false

    /// MYR-382 — where the schedule card hands the rider back to. See
    /// `ScheduleCardReturn`. One-shot in practice: the card clears it to `.search`
    /// on both of its exits (commit and dismiss), so a later chip-tap on the search
    /// sheet can never inherit a Review return from a route the rider abandoned.
    public var scheduleReturn: ScheduleCardReturn = .search

    // MARK: MYR-356 — recent destinations
    //
    // Device-local and therefore honest on BOTH paths (see `RecentDestinations
    // .swift`). Held here rather than read from the store per frame so the search
    // sheet observes a change the instant one is recorded, and so the disk is
    // touched exactly twice per app run per choice: once on load, once on write.

    @ObservationIgnored private let recentDestinationsStore: any RecentDestinationsStoring

    /// The rider's recently-CHOSEN destinations, most-recent-first, capped at
    /// `RecentDestinationList.limit`. Empty on a cold install and in every DEBUG
    /// scene but `riderRecentDestinations`, which is what keeps the drift gate whole.
    public private(set) var recentDestinations: [RecentDestination] = []

    /// The same list in the type every row in the search sheet speaks.
    public var recentDestinationPlaces: [RidePlace] { recentDestinations.map(\.place) }

    /// Public convenience: the simulated seams (fixtures) — the default for
    /// previews / tests / the sim demo. Delegates to the designated init.
    public convenience init(vehicle: Vehicle = VehicleFixtures.vehicles[0]) {
        self.init(vehicle: vehicle, seams: .simulated)
    }

    /// Designated init taking the composed seams (`PlaceSearchComposition.make()`
    /// wires live vs. sim in `RootView`). Internal — `Seams` is a module type.
    ///
    /// MYR-356 — `recentDestinationsStore` defaults to `UserDefaults`, so previews
    /// and hand-rolled callers behave like the app. `RootView` swaps in an
    /// `InMemoryRecentDestinationsStore` for every DEBUG scene, which is what stops
    /// a capture picking up recents left behind by hand-driving the flow on the same
    /// simulator.
    init(
        vehicle: Vehicle? = VehicleFixtures.vehicles[0],
        seams: PlaceSearchComposition.Seams,
        recentDestinationsStore: any RecentDestinationsStoring = UserDefaultsRecentDestinationsStore()
    ) {
        self.recentDestinationsStore = recentDestinationsStore
        recentDestinations = recentDestinationsStore.load()
        // MYR-184/228 — the ONE gate. `RootView` passes `nil` on the live path
        // (the vehicle arrives from the catalog); every other caller keeps the
        // fixture default, so sim is unchanged.
        sharedVehicle = vehicle
        simulatedTelemetrySource = SimulatedVehicleTelemetrySource(
            // No vehicle yet → an EMPTY parked activity carrying no fixture
            // geometry and no fixture label at all. It is never on screen (the
            // shell renders its empty state while `sharedVehicle` is nil), and it
            // exists only so the source is non-optional for the rest of the class.
            activity: vehicle?.activity ?? Self.unknownActivity
        )
        placeSearch = seams.placeSearch
        userLocation = seams.userLocation
        liveVehicleLocator = seams.liveVehicleLocator
        pinLabeler = seams.pinLabeler
        isLiveLocation = seams.isLive
        // MYR-385 — `nil` in sim, so this store exists and can never fetch.
        bookedWindows = RideBookedWindowsStore(provider: seams.bookedWindows)
        // MYR-422 — same construction, same reason: `nil` in sim, so the post-ride
        // summary's drive join cannot be made even in principle there.
        summaryDriveRoutes = RideSummaryDriveRouteStore(provider: seams.driveRoutes)
        // MYR-177 (client-approved): the tracking map draws REAL Apple Maps
        // driving routes in BOTH sim and live — "the route should be calculated
        // by Apple Maps until the Tesla integration", not the straight-line
        // stopgap — so the demo/debug tracking scenes show road geometry too.
        // MKDirections runs fine in the Simulator. `StraightLineRideRouteProvider`
        // remains the provider's own on-failure fallback and the hermetic
        // test-injection provider (unit tests never hit the network). When the
        // Tesla route polyline lands, only this one line swaps.
        #if DEBUG
        // MYR-395 — `MRT_ROUTE_UNAVAILABLE=1` swaps in the provider's OWN
        // documented degradation (`StraightLineRideRouteProvider` returns exactly
        // the `[from, to]` pair `AppleRideRouteProvider` returns when MKDirections
        // is throttled, offline or times out), so the honest no-road-geometry
        // state has a headless capture route. It has no other one: on a healthy
        // networked simulator MKDirections answers every pair in ~1s, which is why
        // the client's frame could not be photographed before this issue.
        rideRouteStore = RideRouteStore(provider: DebugScene.routeUnavailable
            ? StraightLineRideRouteProvider()
            : AppleRideRouteProvider())
        #else
        rideRouteStore = RideRouteStore(provider: AppleRideRouteProvider())
        #endif
    }

    public var snapshot: VehicleTelemetrySnapshot { telemetrySource.snapshot }

    // MARK: - MYR-184 — adopting the real shared vehicle

    /// A parked activity with NO fixture content — no SF coordinate, no fixture
    /// label, no park time. The honest stand-in for "we do not have a vehicle",
    /// mirroring `VehicleContractMapping.placeholderActivity`'s own unknown case.
    private static let unknownActivity = VehicleActivity.parked(
        ParkedLocation(
            label: "",
            coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            parkedSince: nil
        )
    )

    /// A vehicle with NO fixture content: no name, no plate, no model. The map's
    /// input for the brief window between "the rider has nothing" and the shell
    /// swapping to its empty state. Deliberately NOT `VehicleFixtures.vehicles[0]`
    /// — that default with no live gate is the MYR-228 defect this issue fixes,
    /// and a placeholder that renders an empty label is honest where "Cybercab"
    /// is a lie.
    private static let unknownVehicle = Vehicle(
        id: "",
        name: "",
        model: "",
        colorName: "",
        plate: "",
        seatHeat: false,
        // MYR-441 — a placeholder knows nothing about the car's seats, and
        // `false` here was a claim rather than a default.
        seatClimate: .unknown,
        activity: unknownActivity
    )

    /// What the rider's map renders: the adopted shared vehicle, else the
    /// contentless placeholder above.
    ///
    /// MYR-336 — on the live path the adopted row's POSITION and STATUS are folded
    /// forward from the live snapshot (`RiderVehicleProjection`), so the car on
    /// the map is where the car actually is. **Only those two facts**: identity
    /// stays on the catalog row the server viewer-masks, and the projection is
    /// what keeps a widened mask from ever reaching a rider's screen as a
    /// stranger's VIN. With no fix yet the row is returned untouched — the
    /// pre-fix "Locating…" placeholder, never a fabricated coordinate.
    public var mapVehicle: Vehicle {
        let adopted = sharedVehicle ?? Self.unknownVehicle
        guard isLiveLocation else { return adopted }
        return RiderVehicleProjection.apply(liveVehicleLocator?.state, to: adopted)
    }

    /// MYR-184 §7.5.0 — the rider's client-side capability gate for the vehicle
    /// they are watching. `true` when the grant is on the top (`rides`) tier, or
    /// on ANY simulated path (the prototype's rider can always request; every
    /// simulated + DEBUG scene must stay pixel-identical).
    ///
    /// AFFORDANCE HINT ONLY — the server enforces §7.8's non-owner gate itself.
    /// What this prevents is the app offering a "Where to?" that will 403.
    public var canRequestRides: Bool {
        guard let sharedVehicleTier else { return true }
        return sharedVehicleTier == .rides
    }

    /// The tier of the grant behind `sharedVehicle`, or `nil` when tiers do not
    /// apply (sim, and any path with no catalog behind it).
    public private(set) var sharedVehicleTier: ShareAccessLevel?

    /// Adopt the vehicle the rider actually has access to (MYR-184) — the first
    /// `role: viewer` row in `SharedVehicleCatalog`.
    ///
    /// Idempotent by identity: re-adopting the SAME vehicle id is a no-op, so a
    /// catalog refresh on every foreground does not tear down and re-create the
    /// telemetry source (which would restart the ticker and jump the map) on a
    /// list that has not changed.
    func adoptSharedVehicle(_ grant: SharedVehicleGrant?) {
        sharedVehicleTier = grant?.tier
        adoptSharedVehicle(grant?.vehicle)
    }

    /// MYR-343 — adopt the vehicle the rider shell RESOLVED, which is not always a
    /// share: an OWNER in rider mode self-rides their own car (a supported flow,
    /// MYR-325) and holds zero `role: viewer` rows. The adoption carries the tier
    /// with it, `nil` for an owned car, which `canRequestRides` already reads as
    /// "tiers do not apply" — correct, since §7.8's non-owner gate is not one an
    /// owner can fail.
    ///
    /// Same idempotence as the grant path (it delegates to it): re-adopting the
    /// same vehicle id does not restart the ticker or jump the map.
    func adopt(_ adoption: RiderVehicleAdoption?) {
        sharedVehicleTier = adoption?.tier
        adoptSharedVehicle(adoption?.vehicle)
    }

    public func adoptSharedVehicle(_ vehicle: Vehicle?) {
        guard sharedVehicle?.id != vehicle?.id else { return }
        let wasRunning = telemetryStarted
        simulatedTelemetrySource.stop()
        sharedVehicle = vehicle
        simulatedTelemetrySource = SimulatedVehicleTelemetrySource(
            activity: vehicle?.activity ?? Self.unknownActivity
        )
        if wasRunning, vehicle != nil, !isLiveLocation { simulatedTelemetrySource.start() }
        // MYR-336 — point the LIVE stream at the car the shell just adopted, so
        // the vehicle on the map and the vehicle on the socket are one vehicle.
        // Owned or shared makes no difference here: MYR-343 resolved that upstream
        // and the backend subscribes a viewer at tier `live`+ just as it does an
        // owner. `watch` is idempotent by id, so a catalog re-resolve on an
        // unchanged list re-fetches nothing.
        if isLiveLocation { liveVehicleLocator?.watch(vehicleID: vehicle?.id) }
    }

    // MARK: MYR-177 — live ride tracking (route provider + leg-fit camera owner)
    //
    // Owned here (not in the per-render `SharedViewerScreen` struct) so the
    // route cache + the single camera owner survive view updates and the
    // idle↔tracking phase churn — the same reasoning `telemetrySource` and the
    // pin-drop owner follow. `@ObservationIgnored` (stable references) — the
    // `@Observable` route store's own `leg1`/`leg2` reads ARE tracked by any
    // view that reads them.

    /// Per-leg route cache for the active ride (MYR-177). Provider is Apple
    /// MKDirections in live (client-approved TEMP until Tesla route polylines
    /// land — swap the provider, nothing else) and the offline straight-line in
    /// sim/tests so no network touches the sim path.
    @ObservationIgnored let rideRouteStore: RideRouteStore

    /// MYR-422 — rung 1 of the post-ride summary's route ladder: which DRIVE this
    /// ride was, and the track the car actually drove during it (§7.2 + §7.4).
    ///
    /// Lives here, beside the route cache, for the same reason that cache does: the
    /// verdict is about the RIDE and must outlive any one mounting of the summary,
    /// so a re-entered page answers from memory instead of re-spending two REST
    /// calls. `@ObservationIgnored` on the reference; the store's own
    /// `settledCount` is what a view observes.
    @ObservationIgnored let summaryDriveRoutes: RideSummaryDriveRouteStore

    /// MYR-390 — has the route in front of the rider already been etched? Owned
    /// HERE, beside the route cache, for exactly the reason that cache is: the
    /// rider walks the route preview from Search through Review to Booking and
    /// the view drawing it is torn down and rebuilt on the way. A pass that must
    /// happen once per trip cannot be remembered by whichever overlay happens to
    /// be mounted; `RideRequestRouteMap` used to try, and replayed its 1.6s etch
    /// from zero on every step (r15).
    ///
    /// `@ObservationIgnored` like the store, and the ledger itself is not
    /// `@Observable`: it is read once when a presentation is decided, never
    /// rendered from.
    @ObservationIgnored let routeEtchLedger = RouteEtchLedger()

    /// The single leg-fit camera owner for the tracking phase (MYR-177) — every
    /// programmatic tracking-camera write flows through it.
    @ObservationIgnored let trackingCamera = TrackingCameraController()

    // MARK: MYR-459 — the deviation refetch's missing LIVE trigger

    /// What the tracking surface currently wants routed, published here so a frame
    /// arriving off the socket can re-ask for it.
    ///
    /// The endpoints live on `SharedViewerScreen` (they come off the ride record),
    /// but the TRIGGER cannot: a live fix arrives with no view event behind it, and
    /// `SharedViewerScreen.body` is at the type-checker's budget (MYR-422), so this
    /// cannot be one more `.onChange`. The screen therefore publishes what it wants
    /// routed through its existing `reconcileTrackingRoutes()`, and the frame does
    /// the asking.
    struct TrackingRouteContext {
        var pickup: CLLocationCoordinate2D
        var destination: CLLocationCoordinate2D
        /// Leg 1 is fetched only while heading to pickup (MYR-393: no origin, no
        /// leg-1 fetch), so a car already carrying the rider re-asks for nothing.
        var fetchesLeg1: Bool
    }

    @ObservationIgnored private(set) var trackingRouteContext: TrackingRouteContext?

    /// A ~11m-resolution key for the watched car's fix.
    ///
    /// `HomeScreen.dispatchedCarPositionKey`'s rule verbatim, and for its reason: a
    /// device streams ~1Hz, so keying on the raw coordinate would re-ask on every
    /// frame. The store's own guards would absorb it — this keeps the ASK at human
    /// cadence, and the store then decides whether the car has actually DEVIATED
    /// far enough to be worth a throttle-budgeted MKDirections call.
    @ObservationIgnored private var lastReconciledFixKey: String?

    /// How many times a live FRAME has re-asked the route cache.
    ///
    /// A counter rather than a flag, and published for the reason
    /// `RiderLiveVehicleLocator.accessRevocations` is: the whole defect is that
    /// nothing downstream of a frame ever ran, and "the store no-oped" is
    /// indistinguishable from "the store was never asked" at every other
    /// observation point. `RideRouteStore` takes its provider at construction and
    /// `SharedViewerState` builds its own, so a test cannot count MKDirections
    /// calls — it can count the ASKS, which is the half this issue is about.
    @ObservationIgnored private(set) var trackingRouteLiveReasks = 0

    static func trackingFixKey(_ coordinate: CLLocationCoordinate2D?) -> String? {
        coordinate.map { String(format: "%.4f,%.4f", $0.latitude, $0.longitude) }
    }

    /// Publish (or clear) what the tracking surface wants routed. Clearing also
    /// forgets the fix key, so re-entering tracking always re-asks once.
    func setTrackingRouteContext(_ context: TrackingRouteContext?) {
        trackingRouteContext = context
        if context == nil { lastReconciledFixKey = nil }
    }

    /// MYR-459 — re-ask the route cache because the CAR MOVED.
    ///
    /// Called from every folded live frame (`RiderLiveVehicleLocator.onLiveFrame`).
    /// Cheap by construction: quantized here, and `ensureLeg1` is a no-op unless
    /// the car has genuinely deviated past `MRTMetrics
    /// .rideRouteDeviationThresholdMeters` or a 2-point fallback's retry cooldown
    /// has elapsed.
    func reconcileTrackingRoutesForLiveFix() {
        guard sheetPhase == .tracking,
              let context = trackingRouteContext,
              context.fetchesLeg1,
              let fix = trackingVehicleCoordinate,
              let key = Self.trackingFixKey(fix),
              key != lastReconciledFixKey
        else { return }
        lastReconciledFixKey = key
        trackingRouteLiveReasks += 1
        rideRouteStore.ensureLeg1(carPosition: fix, pickup: context.pickup)
    }

    public func startTelemetry() {
        telemetryStarted = true
        // MYR-336 — the fixture ticker runs in SIM ONLY. On the live path the
        // watched vehicle's stream is the locator's to own (it holds the socket),
        // so `liveVehicleLocator?.start()` below is the whole live lifecycle.
        if !isLiveLocation { simulatedTelemetrySource.start() }
        userLocation.start()
        liveVehicleLocator?.start()
    }

    public func stopTelemetry() {
        telemetryStarted = false
        simulatedTelemetrySource.stop()
        userLocation.stop()
        liveVehicleLocator?.stop()
    }

    // MARK: MYR-222 — scene lifecycle, by design
    //
    // The rider's location stream is explicitly stopped on suspend and
    // restarted on resume (mirroring `OwnerHomeState.handleBackground/
    // Foreground` for the owner fleet). iOS would starve a when-in-use
    // `CLLocationManager` anyway while suspended — but that accident was
    // exactly what used to "heal" the MYR-222 camera feedback loop, so the
    // lifecycle is now owned, not incidental: no fixes are DELIVERED in the
    // background, and the camera states (`PinDropCameraController.Phase`,
    // `isFollowing`) are designed to survive the round-trip untouched.
    //
    // Gated on `telemetryStarted` so a foreground transition BEFORE the rider
    // map ever mounted (cold launch on Sign-In) can't start location — and
    // with it the when-in-use permission prompt — prematurely.

    @ObservationIgnored private var telemetryStarted = false

    public func handleBackground() {
        guard telemetryStarted else { return }
        userLocation.stop()
        // MYR-336 — the watched vehicle's socket joins the same owned lifecycle
        // (mirrors `LiveVehicleFleet.handleBackground`). No-op in sim.
        liveVehicleLocator?.handleBackground()
    }

    public func handleForeground() {
        guard telemetryStarted else { return }
        userLocation.start()
        // MYR-336 — nudge the socket and re-ask for the watched car's snapshot: a
        // car that moved while the app was suspended must not be re-rendered from
        // whatever was last in memory (`LiveVehicleFleet.handleForeground`'s
        // lesson, same shape). No-op in sim.
        liveVehicleLocator?.handleForeground()
    }

    // MARK: MYR-211 — region biasing + current-location pickup

    /// The coordinate to bias search + center the rider map/pin-drop on:
    /// device location first, live-vehicle region as fallback, fixture region
    /// only in sim (MYR-211 addendum #4). In sim both live sources report
    /// nothing, so this is `DriveFixtures.home` — byte-identical to the
    /// pre-MYR-211 `centerOverride`.
    public var mapRegionCenter: CLLocationCoordinate2D {
        userLocation.coordinate ?? liveVehicleLocator?.coordinate ?? DriveFixtures.home
    }

    // MARK: MYR-341 — the rider pickup ETA ("A ride is N min away")
    //
    // The idle placeholder's number, and — through `liveFleetMember` below —
    // Review's "N min away" and Booking's pickup clock. ONE estimator feeds all
    // three, so the three surfaces cannot disagree about the same car.
    //
    // The endpoints are ANCHORS, not fixes. `refreshPickupETAAnchors()` is called
    // on idle-sheet appearance and whenever either raw coordinate changes, but a
    // `StableFixAnchor` only re-seats on a move of a full grid cell — so a ~1Hz
    // GPS stream writes NOTHING here, the observation never fires, and the number
    // cannot twitch across the placeholder's 2800ms rotation (MYR-237 class).

    /// The rider anchor the ETA is measured TO at idle — the stable form of the
    /// device fix. `nil` with no fix, which is honesty gate 1: it is deliberately
    /// NOT `mapRegionCenter`, whose own fallback ladder resolves to the VEHICLE's
    /// coordinate and would yield an ETA from the car to itself.
    public private(set) var idleRiderAnchor: CLLocationCoordinate2D?
    /// The watched vehicle's stable coordinate anchor. `nil` until the cold
    /// snapshot lands (or when the car reports the contract's "no fix" 0,0).
    public private(set) var pickupETAVehicleAnchor: CLLocationCoordinate2D?

    @ObservationIgnored private var riderFixAnchor = StableFixAnchor()
    @ObservationIgnored private var vehicleFixAnchor = StableFixAnchor()

    #if DEBUG
    /// MYR-341 capture hook: a live-shaped vehicle coordinate a scene can inject,
    /// mirroring `debugFleetMemberOverride`. `nil` for every other scene and every
    /// shipping build. Release builds never compile it.
    public var debugVehicleCoordinateOverride: CLLocationCoordinate2D?
    /// MYR-341 capture hook: resolve the idle placeholder on the LIVE-shaped
    /// branch from a simulated boot. The state is live-only by construction (it
    /// needs a device fix, a real vehicle coordinate and a live fleet member at
    /// once), so this is the same stand-in-for-a-live-session precedent as
    /// `rendersLiveVehicleFreshness`. `false` everywhere else, so every simulated
    /// scene keeps the fixture placeholder and stays byte-identical.
    public var debugResolvesLivePickupETA = false
    /// MYR-414 capture hook: resolve the post-ride SUMMARY on the LIVE-shaped
    /// branch from a simulated boot.
    ///
    /// The honest summary is live-path-only by construction — it needs a ride
    /// record carrying a server `completedAt` and an observed enroute transition,
    /// plus a real MKDirections leg-2 route for the same pair — so the one branch
    /// is forced exactly as `debugResolvesLivePickupETA` does. `false` everywhere
    /// else, which is what keeps the `summary` drift-gate scene byte-identical.
    public var debugResolvesLiveRideSummary = false
    /// MYR-393 capture hook: resolve the tracking sheet's MOTION LADDER and its car
    /// marker on the LIVE-shaped branch from a simulated boot.
    ///
    /// The waiting-to-start state is live-path-only by construction — the ladder
    /// short-circuits to the pre-MYR-393 line whenever there is no telemetry to be
    /// honest with, precisely so the `trackProgress`-driven tracking scenes are not
    /// told they are stationary while the simulation is driving them. So the only
    /// way to photograph it is to force the one branch, exactly as
    /// `debugResolvesLivePickupETA` and `rendersLiveVehicleFreshness` do. `false`
    /// everywhere else, so every simulated scene keeps the old line.
    public var debugResolvesLiveMotion = false
    /// MYR-393 capture hook: the live-shaped `VehicleState` the ladder and the
    /// marker read. Travels the SHIPPING `RiderCarMotion.evidence` /
    /// `RiderVehicleProjection.hasFix` / `RiderCarMarker.resolve`, so a capture
    /// shows what the production resolvers made of a real wire shape rather than a
    /// hand-set phase.
    public var debugTrackingVehicleState: VehicleState?
    /// MYR-393 capture hook: the freshness pair that goes with the state above.
    /// `nil` = not streaming, which is the situation the position-age qualifier is
    /// for (an in-service car reporting through REST polling, MYR-394).
    public var debugTrackingIsStreaming: Bool?
    #endif

    // MARK: MYR-393 — the tracking surface's live-motion inputs
    //
    // Three accessors rather than three reads scattered through
    // `SharedViewerScreen`, for the reason the pickup-ETA pair above exists: the
    // ladder, the marker and the freshness note must all be looking at ONE car and
    // one read, and a DEBUG scene must be able to substitute that car in exactly
    // one place.

    /// Whether the tracking surface resolves motion + marker on the live branch.
    var resolvesTrackingMotion: Bool {
        #if DEBUG
        if debugResolvesLiveMotion { return true }
        #endif
        return isLiveLocation
    }

    /// The watched vehicle's accumulated live state, as the tracking surface sees it.
    var trackingVehicleState: VehicleState? {
        #if DEBUG
        if let debugTrackingVehicleState { return debugTrackingVehicleState }
        #endif
        return liveVehicleLocator?.state
    }

    /// The freshest position we hold for the watched vehicle, through the SAME
    /// `(0,0)`-is-no-fix gate the rider map already applies.
    var trackingVehicleCoordinate: CLLocationCoordinate2D? {
        RiderVehicleProjection.coordinate(from: trackingVehicleState)
    }

    /// MYR-460 — the car's own compass heading, through the SAME projection and
    /// the SAME `(0,0)`-is-no-fix gate the coordinate takes, so the glyph's
    /// position and its rotation can never come from different evidence.
    var trackingVehicleHeading: Double? {
        RiderVehicleProjection.heading(from: trackingVehicleState)
    }

    // MARK: MYR-449 — the tracking surface's honest live state

    /// The clock behind "Waiting for live location…" → "Live location unavailable
    /// right now", and the trigger for the dark-stream recovery. Armed by
    /// `sheetPhase`'s `didSet`, above.
    let trackingLiveWatch = RiderTrackingLiveWatch()

    /// Arm the watch and bind its two seams. Bound HERE rather than at
    /// construction because `liveVehicleLocator` is a `let` on this type and the
    /// watch must hold no opinion about where telemetry comes from — it asks this
    /// state the one question it needs ("do we have a fix?") and hands the answer
    /// its one consequence.
    private func armTrackingLiveWatch() {
        trackingLiveWatch.hasLiveFix = { [weak self] in self?.trackingVehicleCoordinate != nil }
        // MYR-459 — bound in the SAME place, for the same reason the watch's two
        // seams are: this state asks the locator one question and hands the answer
        // its one consequence. Only the LIVE branch has frames to be triggered by;
        // a simulated tracking scene never rings it, so every capture is unchanged.
        liveVehicleLocator?.onLiveFrame = { [weak self] in
            self?.reconcileTrackingRoutesForLiveFix()
        }
        trackingLiveWatch.onGraceElapsed = { [weak self] in
            // Only the LIVE branch recovers. A simulated tracking scene has no
            // socket to re-establish and must stay byte-identical.
            guard let self, self.isLiveLocation else { return }
            self.liveVehicleLocator?.recoverDarkStream()
        }
        trackingLiveWatch.arm()
    }

    /// How current that position is: the read time and whether the car is
    /// streaming. `VehicleFreshnessStamp`'s own two inputs, so the rider's
    /// position qualifier and the owner's freshness stamp cannot disagree about
    /// what "current" means.
    var trackingPositionRead: (lastUpdated: Date?, isStreaming: Bool?) {
        #if DEBUG
        if let debugTrackingVehicleState {
            return (VehicleContractMapping.parseTimestamp(debugTrackingVehicleState.lastUpdated), debugTrackingIsStreaming)
        }
        #endif
        return (snapshot.lastUpdated, snapshot.isStreaming)
    }

    /// Whether the pickup ETA resolves at all: the live path, plus the one DEBUG
    /// capture scene. On the simulated path this is false and every ETA surface
    /// keeps its fixture value untouched.
    var resolvesPickupETA: Bool {
        #if DEBUG
        if debugResolvesLivePickupETA { return true }
        #endif
        return isLiveLocation
    }

    /// MYR-414 — whether the post-ride summary renders its HONEST stat strip (each
    /// tile gated on its own datum, no tip section, no straight hero line) or the
    /// prototype's illustration. The ONE resolved `AppMode`, plus the one DEBUG
    /// capture scene — never a new env var (MYR-228).
    var resolvesLiveRideSummary: Bool {
        #if DEBUG
        if debugResolvesLiveRideSummary { return true }
        #endif
        return isLiveLocation
    }

    /// The vehicle coordinate the ETA measures FROM (the cold snapshot's, or a
    /// DEBUG scene's injected one).
    private var pickupETAVehicleFix: CLLocationCoordinate2D? {
        #if DEBUG
        if let debugVehicleCoordinateOverride { return debugVehicleCoordinateOverride }
        #endif
        return liveVehicleLocator?.coordinate
    }

    /// A change-key over the RAW endpoints (`CLLocationCoordinate2D` isn't
    /// `Equatable`) — the screen re-seats the anchors when this changes. Changing
    /// it does NOT change the anchors unless the move was material.
    public var pickupETAFixKey: String {
        let rider = userLocation.coordinate
        let vehicle = pickupETAVehicleFix
        return "\(rider?.latitude ?? .nan),\(rider?.longitude ?? .nan)|\(vehicle?.latitude ?? .nan),\(vehicle?.longitude ?? .nan)"
    }

    // MARK: MYR-402 — a ride ending is a REFETCH, not only a transition
    //
    // THE INVARIANT: every input to `RiderIdlePlaceholder`'s honesty gates is
    // observed state that updates from the same events that end a ride — a WS
    // frame, a foreground refetch, a push tap. No gate may latch.
    //
    // It did not hold, and the way it failed is worth stating because the shape
    // recurs. `RiderIdleGate.carAvailability` reads `VehicleSummary.hasActiveRide`
    // off `GET /api/vehicles`, and that list was fetched exactly ONCE per rider-map
    // mount. Nothing re-read it when a ride ended, when the app foregrounded, or
    // when a push was tapped — **a cold launch was the only refresh in the app**,
    // which is precisely the "works after a force-quit" signature MYR-389 named as
    // this whole class's tell.
    //
    // And the staleness was INVISIBLE while it mattered least: MYR-233's own-ride
    // exception suppresses `.busy` for the rider holding the ride, so the stale row
    // was masked for the whole ride and became load-bearing the instant the ride was
    // erased. The gate therefore CLOSED on the transition that should have opened
    // it. A test that only checked the placeholder DURING a ride would see nothing.

    /// Re-read every input to the idle placeholder's honesty gates that this object
    /// owns, and re-seat the anchors over whatever lands.
    ///
    /// ONE funnel rather than a call per input at each of the three event sites: an
    /// input added later joins here and is covered by all three at once, which is
    /// the MYR-389 lesson (an entry invariant beats an exit list) pointed at reads.
    /// `RiderIdleGate.requestInFlight`'s input is the ride service's slot and is
    /// refreshed by `RideRequestService.refreshActiveRide()`, the one input this
    /// object does not hold.
    ///
    /// No-op on the simulated path (there is no locator), so every simulated and
    /// DEBUG capture is byte-identical.
    public func refreshRideEndGateInputs() {
        // `carAvailability` — the §7.0 list row.
        liveVehicleLocator?.refreshFleet()
        // `pickupEstimate` — re-seat from whatever the raw endpoints say now. Writes
        // nothing unless an anchor genuinely moved, so this cannot invalidate a view
        // on its own.
        refreshPickupETAAnchors()
    }

    /// MYR-432 — the rider socket's access-revocation edge, forwarded so the shell
    /// can observe it without reaching into the locator.
    ///
    /// `0` on the simulated path, where there is no locator and no socket, so the
    /// shell's `onChange` never fires and every simulated + DEBUG capture is
    /// byte-identical.
    public var riderAccessRevocationTick: Int {
        liveVehicleLocator?.accessRevocationTick ?? 0
    }

    /// Re-seat both ETA anchors from the current raw fixes. Idempotent and cheap;
    /// writes an observable property ONLY when an anchor actually moved, so a
    /// streaming fix does not invalidate any view.
    public func refreshPickupETAAnchors() {
        let rider = riderFixAnchor.update(userLocation.coordinate)
        if !Self.sameCoordinate(rider, idleRiderAnchor) { idleRiderAnchor = rider }
        let vehicle = vehicleFixAnchor.update(pickupETAVehicleFix)
        if !Self.sameCoordinate(vehicle, pickupETAVehicleAnchor) { pickupETAVehicleAnchor = vehicle }
    }

    private static func sameCoordinate(_ a: CLLocationCoordinate2D?, _ b: CLLocationCoordinate2D?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return a.latitude == b.latitude && a.longitude == b.longitude
        default: return false
        }
    }

    /// The rider endpoint the pickup ETA measures TO, by phase — one lineage so
    /// the idle placeholder, Review and Booking all measure to the same point:
    ///  • the CONFIRMED pickup once the rider has dropped a pin,
    ///  • else MYR-237's `previewPickupAnchor` (the fix anchored at the moment a
    ///    destination was chosen — the same anti-jitter anchor the route preview
    ///    already uses),
    ///  • else the stable idle anchor (the rider's current location).
    public var pickupETARiderAnchor: CLLocationCoordinate2D? {
        draftPickup?.coordinate ?? previewPickupAnchor ?? idleRiderAnchor
    }

    /// Minutes for the watched vehicle to reach the rider, or `nil` when either
    /// endpoint is unknown (or when the ETA doesn't resolve on this path).
    public var pickupETAMinutes: Int? {
        guard resolvesPickupETA else { return nil }
        return RiderPickupETA.minutes(vehicle: pickupETAVehicleAnchor, rider: pickupETARiderAnchor)
    }

    /// Equatable change-key for `mapRegionCenter` (`CLLocationCoordinate2D`
    /// isn't `Equatable`) — the search sheet re-runs its active query when
    /// this changes (MYR-211 region-bias fix: a search issued before the first
    /// location fix must re-bias once the fix lands). Constant in sim (the
    /// fixture center never moves), so sim never re-runs — pixel-identical.
    public var mapRegionCenterKey: String {
        let center = mapRegionCenter
        return "\(center.latitude),\(center.longitude)"
    }

    /// Push the current query + region bias into the search backend.
    public func updateSearch(query: String) {
        placeSearch.update(query: query, regionCenter: mapRegionCenter)
    }

    /// MYR-278 — the rider tapped a "Search Nearby" category row: run a real
    /// nearby POI search for that category (region-biased to the rider) whose
    /// results replace the list. The row is NOT a destination — it has no single
    /// coordinate — so this never touches `draftDestination`.
    public func runNearbySearch(_ place: RidePlace) {
        placeSearch.runNearbySearch(category: place.label, regionCenter: mapRegionCenter)
    }

    /// Select a destination and advance the flow (MYR-171 / MYR-211 defect B).
    /// If a pickup is already set, straight to Review; otherwise route through
    /// the pin-drop step so the rider confirms their exact pickup spot on the
    /// map — the design flow (`screens.jsx:2195`). The pin-drop map is centered
    /// on the rider's LIVE coordinate in live mode (`pinDropCoordinate`), so
    /// "Current location" is the pin's STARTING point, never a bypass. Sim is
    /// unchanged (no fix ⇒ pin-drop over the fixture region, as before).
    public func selectDestination(_ place: RidePlace) {
        // MYR-278 — a "Search Nearby" category row is not a place (it has no
        // single coordinate); it must never become a destination via any path
        // (it would produce a 0.0mi trip / arbitrary point). The search UI runs
        // a nearby search on tap instead; this is belt-and-suspenders.
        guard !RidePlaceMapper.isCategorySearch(place) else { return }
        draftDestination = place
        // MYR-356 — THE one funnel. `proceedFromSearch()` (the Continue CTA)
        // delegates here and the idle sheet's Home/Work chips call it directly, so
        // every path that genuinely ADVANCES on a destination records it exactly
        // once. Deliberately NOT `chooseDestination`, which only fills the field:
        // a destination the rider backed out of with "Change trip" is not one they
        // chose.
        recordRecentDestination(place)
        capturePreviewPickupAnchor()
        resolveDraftDestinationIfNeeded()
        if draftPickup != nil {
            enterReview()
        } else {
            pinReturn = .review
            sheetPhase = .pinDrop(returnTo: .review)
        }
    }

    // MARK: MYR-215 deliverable 3 — choose-then-proceed on the search sheet
    //
    // CLIENT-APPROVED PROTOTYPE DEVIATION (the story's 2nd, alongside the
    // pin-drop zoom): the prototype advances the flow the instant a result row
    // is tapped (`selectDestination` above, screens.jsx:2195). The client ruled
    // that too abrupt — tapping a result should just ENTER that destination into
    // the field (keeping the rider on Search so they can still set the
    // Now/Schedule + Me/Someone-else chips), and an EXPLICIT "Continue" CTA then
    // advances. The prototype shows no such CTA ("even if it's not displayed in
    // the prototype … add something … that follows our design system"). Applies
    // in BOTH modes so sim and live share one flow. See `RideRequestSearchContent`
    // for the CTA (a `.gold` step-CTA — outline-draw stays reserved for the final
    // "Request from X" commit) and the field-edit → search-as-you-type return.

    /// Enter a destination on the search sheet WITHOUT advancing — the rider
    /// stays on `.search` to set chips before proceeding (deliverable 3).
    public func chooseDestination(_ place: RidePlace) {
        // MYR-278 — never let a "Search Nearby" category row become the chosen
        // destination (see `selectDestination`); the UI routes it to a nearby
        // search instead.
        guard !RidePlaceMapper.isCategorySearch(place) else { return }
        draftDestination = place
        capturePreviewPickupAnchor()
        resolveDraftDestinationIfNeeded()
    }

    /// MYR-237 device trace: the route preview's pickup must NOT track the live
    /// GPS fix — every jitter changed the route-cache key, collapsing the etched
    /// route back to loading in a visible ~2s loop. The fix is anchored ONCE
    /// when a destination is chosen and only replaced by an explicit pickup.
    public private(set) var previewPickupAnchor: CLLocationCoordinate2D?
    private func capturePreviewPickupAnchor() {
        guard draftPickup == nil else { previewPickupAnchor = nil; return }
        if previewPickupAnchor == nil {
            previewPickupAnchor = userLocation.coordinate
        }
    }

    /// MYR-237 (device QA): a picked live suggestion may be an UNRESOLVED row —
    /// its placeholder coordinate is the rider's own location, so every
    /// consumer downstream (trip estimate, route preview, the eventual create)
    /// would silently use pickup≈destination (0.0mi trips, pickup→pickup
    /// route requests). Selection therefore re-resolves the real coordinate
    /// (bounded retries for Apple's throttle) and swaps it into the draft —
    /// recomputing the Review estimate if the rider already advanced.
    /// Re-kick a stalled destination resolution (MYR-237 device QA: when the
    /// first bounded attempts all lost to Apple's throttle, NOTHING retried —
    /// the flow sat on the breathing head forever). Called by the route
    /// preview's retry loop on its cadence; a no-op when the destination is
    /// resolved or a resolve task is already in flight.
    public func retryDestinationResolutionIfNeeded() {
        guard destinationResolveInFlight == false else { return }
        resolveDraftDestinationIfNeeded()
    }

    @ObservationIgnored private var destinationResolveTask: Task<Void, Never>?
    @ObservationIgnored private var destinationResolveInFlight = false
    private func resolveDraftDestinationIfNeeded() {
        guard let place = draftDestination, RidePlaceMapper.isUnresolved(place) else { return }
        destinationResolveTask?.cancel()
        let bias = userLocation.coordinate ?? draftPickup?.coordinate ?? mapRegionCenter
        destinationResolveInFlight = true
        destinationResolveTask = Task { [weak self] in
            defer { self?.destinationResolveInFlight = false }
            guard let resolved = await SelectionPlaceResolver.resolve(place, near: bias) else { return }
            guard !Task.isCancelled, let self, self.draftDestination?.id == place.id else { return }
            if let pickup = self.draftPickup, self.sheetPhase == .review || self.sheetPhase == .booking {
                self.draftDestination = TripEstimate.applied(to: resolved, pickup: pickup.coordinate)
            } else {
                self.draftDestination = resolved
            }
        }
    }

    /// MYR-356 — record a chosen destination, in memory and on disk.
    ///
    /// The list rule (dedupe, ordering, cap) is `RecentDestinationList.recording`, a
    /// pure function, so the only thing here is the write. `nil` back from it means
    /// "not a place" (a MYR-278 category row, a blank label) and nothing is touched
    /// — not even the existing list's order.
    private func recordRecentDestination(_ place: RidePlace) {
        guard let updated = RecentDestinationList.recording(place, in: recentDestinations) else { return }
        recentDestinations = updated
        recentDestinationsStore.save(updated)
    }

    /// Clear a search-sheet destination choice (the field was edited or cleared),
    /// returning the sheet to search-as-you-type (deliverable 3).
    public func clearChosenDestination() {
        draftDestination = nil
        previewPickupAnchor = nil
    }

    // MARK: MYR-379 — THE PICKUP IS TYPEABLE, AND TYPING IT CHAINS INTO THE PIN
    //
    // The client, r18: *"No option to type in pick up location and then fine set
    // up exact spot to pick up on map. It locks to current location."*
    //
    // The pickup had exactly two affordances — an implicit "Current location"
    // (which is what `draftPickup == nil` renders as) and "Set on map". The
    // DESTINATION has had typed search, MKLocalSearch autocomplete, MYR-237's
    // selection-time resolution and a recents list since MYR-211. This is that
    // machinery pointed at the other end of the trip: **the same
    // `PlaceSearching` seam, the same results list, the same rows, the same
    // resolver.** Nothing here is a second search stack — see
    // `RideRequestSearchContent.searchTarget`, which is the whole of how one
    // seam serves two fields.
    //
    // ⚠️ THE PROTOTYPE HAS NO SUCH AFFORDANCE, and its accessibility tree is the
    // cleanest statement of the gap: the pickup is `StaticText "Current
    // location"` beside `button "Set on map"`, while the destination is
    // `textbox "Where to?"`. `ride-request.jsx:179` is `const pickupLabel =
    // pickup?.label || 'Current location'` and :239 is the lone "Set on map"
    // capsule — there is no pickup field to port. So this follows the
    // DESTINATION's own grammar rather than inventing one, under the standing
    // precedent that **the client outranks the prototype** (MYR-346's FSD
    // celebration, MYR-347's Share tab).

    /// Select a searched pickup and chain into the pin-drop to fine-tune it.
    ///
    /// **This does NOT set `draftPickup`**, and that is the design rather than an
    /// omission. A typed place is a rider saying roughly where they are; the
    /// pickup a car is dispatched to is the exact kerb, and the surface that
    /// settles that question already exists. So the searched coordinate becomes
    /// the pin-drop's ENTRY (`pinDropSeed`) and the rider's own "Confirm pickup
    /// here" is still what commits — through the same `confirmPickup()` a
    /// pin-dropped pickup has always gone through, producing the same `id: "pin"`
    /// `RidePlace` with the same labeler-resolved street.
    ///
    /// **ONE REPRESENTATION, NOT A PARALLEL ONE**: nothing downstream —
    /// `previewPickupAnchor`, the route preview, `createBody`, the itinerary's
    /// pickup label — can tell a searched pickup from a dropped one, because
    /// after this chain there is no such thing as a searched pickup. There is
    /// only a pin, reached by a new door.
    ///
    /// The chain mirrors `selectDestination`'s own: that funnel has routed
    /// through the pin-drop when no pickup is set since MYR-171, so "a place
    /// selection can open the pin-drop" is this flow's existing grammar and not
    /// a new one.
    public func selectPickup(_ place: RidePlace) {
        // MYR-278, the same belt-and-suspenders `selectDestination` carries: a
        // "Search Nearby" category row has no single coordinate and must never
        // become an endpoint by any path.
        guard !RidePlaceMapper.isCategorySearch(place) else { return }
        pinDropSeed = place.coordinate
        // MYR-237 — the anchor is pickup identity for the route cache, and the
        // rider has just named a pickup that is NOT the device fix. Leaving the
        // old anchor up would key the preview route off wherever they happened to
        // be standing when they picked a destination.
        reAnchorPreviewPickup(to: place.coordinate)
        pinReturn = .search
        sheetPhase = .pinDrop(returnTo: .search)
    }

    /// MYR-445 defect 3 — **AN EXPLICIT CHOICE ALWAYS RE-ANCHORS.**
    ///
    /// `previewPickupAnchor` has exactly two kinds of writer and they need
    /// opposite rules, which is what the client's *"if I select current location
    /// or any other pick up address it doesn't actually set it and is stuck on the
    /// first one"* is made of.
    ///
    ///  • `capturePreviewPickupAnchor()` writes **only into a nil anchor**. That
    ///    guard is right and stays: it fires from destination selection, where the
    ///    coordinate on offer is the raw device fix, and MYR-237's device trace is
    ///    what happens when a ~1Hz stream of those re-keys the route cache — the
    ///    etched line collapsing back to loading in a visible ~2s loop.
    ///  • THIS one is a rider naming a pickup. There is no jitter to guard against
    ///    — a tap is not a fix — and an explicit choice that lost to a guard
    ///    written for GPS noise is a choice that silently did not happen.
    ///
    /// It exists as a named method rather than as two bare assignments so the
    /// asymmetry is legible at both call sites and so a third explicit-choice door
    /// added later has somewhere obvious to go. Both of today's callers —
    /// `selectPickup` and `clearPickup` — are choices, and neither may ever be
    /// routed through the nil-guarded writer.
    private func reAnchorPreviewPickup(to coordinate: CLLocationCoordinate2D?) {
        previewPickupAnchor = coordinate
    }

    /// Clear a typed/confirmed pickup back to the implicit "Current location"
    /// default — the pickup field's `xmark`, which is the destination field's own
    /// clear affordance (`mrt.search.clearDestination`) at the other end of the
    /// route card rather than a new control.
    ///
    /// The SEED goes with it: it is the pending half of a chain the rider has
    /// just abandoned, and leaving it would re-open the pin-drop on a place they
    /// removed.
    /// ⚠️ **MYR-445 DEFECT 3/4 — RETURNING TO THE DEFAULT IS A CHOICE, AND IT HAS
    /// TO MOVE THE ANCHOR.** This method cleared `draftPickup` and `pinDropSeed`
    /// and left `previewPickupAnchor` pointing at the pickup the rider had just
    /// abandoned. Every consumer reads the anchor as the "current location" rung of
    /// its ladder (`RidePreviewPickup.resolve`, `pickupETARiderAnchor`), so
    /// choosing the default resolved to the OLD place — the pickup did not move,
    /// the route cache was never re-keyed with a new pair, and the polyline stayed
    /// where it was **for the rest of the session**. That is the client's *"if I
    /// select current location … it doesn't actually set it and is stuck on the
    /// first one … the map route polyline is also stuck bc the pickup point did not
    /// update"*, and the two halves of his sentence are one line of code apart.
    ///
    /// Re-anchoring to the live fix here is **not** the live-GPS leak MYR-237
    /// forbids, and the distinction is the one that matters: this is a single WRITE
    /// at the instant of a tap, not a per-frame READ. The anchor then holds still
    /// against the fix stream exactly as it does after `selectPickup`.
    public func clearPickup() {
        confirmedPickupLabelTask?.cancel() // MYR-239 — no re-resolution outlives the pickup
        confirmedPickupLabelTask = nil
        draftPickup = nil
        pinDropSeed = nil
        reAnchorPreviewPickup(to: userLocation.coordinate)
    }

    /// Advance from the search sheet once the rider taps "Continue" — identical
    /// semantics to `selectDestination` (pin-drop to confirm the pickup when none
    /// is set yet, else straight to Review), but the destination is already
    /// chosen. No-op if somehow tapped with no destination (deliverable 3).
    public func proceedFromSearch() {
        guard let destination = draftDestination else { return }
        selectDestination(destination)
    }

    // MARK: MYR-212 — authoritative pin (map-center follow + street label)
    //
    // The confirmed pickup is wherever the rider drags the map to, not the
    // static initial center. `pinDropCameraCenter` is the map's live settled
    // center (reported by `VehicleMapView` while the pin-drop phase is up);
    // `pinDropResolvedLabel` is that center reverse-geocoded to a street label.
    // Both are live-only — sim keeps the fixture coordinate/label so every
    // simulated pin-drop scene renders byte-identically.

    // MARK: MYR-223 deliverable 1 — throttle-aware label state
    //
    // The label the pin capsule + sheet header show has THREE states, not two:
    // besides the resolved street and the neutral "Pinned location", there is a
    // calm in-flight "Finding address…" shown WHILE a resolution (including its
    // backoff retries) is running with nothing valid to display yet. The client
    // explicitly wanted to SEE that capture is live rather than watch a named
    // road read neutral: on-device geocoders THROTTLE drag bursts, and the old
    // ladder degraded every such failure straight to neutral. Now a throttled/
    // transient failure retries with backoff while the pin stays settled, and
    // only a genuine unresolvable point (or exhausted retries) reaches neutral.

    /// The label display state (MYR-223). `.neutral` initially; drives
    /// `pinDropLabel`. Private setter — only the settle pipeline mutates it.
    enum PinLabelDisplayState: Equatable {
        /// A resolution (including backoff retries) is in flight and there is
        /// nothing valid to show yet → the calm "Finding address…".
        case resolving
        /// A precise label resolved → show it.
        case resolved(String)
        /// Genuinely unresolvable, or retries exhausted → "Pinned location".
        case neutral
    }
    private(set) var pinLabelState: PinLabelDisplayState = .neutral

    /// The map's last settled center while dropping a pin (live only).
    private(set) var pinDropCameraCenter: CLLocationCoordinate2D?
    /// The resolved street label currently valid for `pinDropResolvedLabelCoordinate`
    /// (live only) — the staleness guard's kept-street. `nil` once cleared.
    private(set) var pinDropResolvedLabel: String?
    /// MYR-216-3b: the coordinate `pinDropResolvedLabel` was resolved FOR — the
    /// staleness guard only lets a resolved street persist across a later settle
    /// while the pin stays within `pinLabelStalenessMeters` of it.
    @ObservationIgnored private var pinDropResolvedLabelCoordinate: CLLocationCoordinate2D?
    @ObservationIgnored private var pinLabelTask: Task<Void, Never>?

    /// MYR-216-3b — the calm neutral shown while no street is confidently
    /// resolved for the current pin (never a stale street resolved elsewhere).
    static let pinNeutralLabel = "Pinned location"
    /// MYR-223 deliverable 1 — the calm in-flight label shown while a resolution
    /// (or its backoff retries) is running. Distinct from the neutral so the
    /// client can SEE capture is live; never a wrong street.
    static let pinResolvingLabel = "Finding address…"
    /// MYR-216-3b — a resolved street label may persist across a settle only
    /// while the pin stays within this radius of where it was resolved.
    static let pinLabelStalenessMeters: Double = 40
    /// MYR-216-3c.3 — reverse-geocode debounce after a settle: tight enough to
    /// track the pin as it moves (client: "label should track as the pin moves")
    /// while coalescing a fast drag's settle stream into one request.
    static let pinLabelDebounceMs = 350
    /// MYR-223 deliverable 1 — backoff schedule for retrying a THROTTLED /
    /// transient geocode failure (`.failed`) while the pin stays settled. The
    /// first attempt runs immediately (after the debounce); each `.failed`
    /// waits the next interval, then retries; once the schedule is exhausted the
    /// failure is treated as genuine and the label degrades to neutral. Real
    /// devices clear a reverse-geocode rate limit within a second or two, so a
    /// short 1s→2s ladder recovers the common burst-throttle without leaving the
    /// pin "Finding address…" indefinitely.
    static let pinLabelRetryBackoffs: [Duration] = [.seconds(1), .seconds(2)]
    /// MYR-239 — the calm neutral pickup fallback: the same string the Search
    /// pickup row shows with no confirmed pickup ("Current location"). A pin
    /// confirmed while its street was still in flight takes this (never the
    /// "Finding address…" transient) until a bounded re-resolution upgrades it.
    public static let pickupFallbackLabel = "Current location"

    /// MYR-379 — a pickup the rider TYPED, waiting to be fine-tuned on the map.
    ///
    /// Written by `selectPickup(_:)` as it chains into the pin-drop, and cleared
    /// on every exit from that session (`confirmPickup`, `returnFromPinDropToSearch`,
    /// `discardDraftTrip`). It is deliberately a ONE-SHOT: see the rung-1 note in
    /// `RiderPickupEntry` for why a seed that outlived its session would silently
    /// undo a drag the rider had already committed.
    public private(set) var pinDropSeed: CLLocationCoordinate2D?

    /// MYR-379 — where the pin-drop's entry camera seats. The whole rule is
    /// `RiderPickupEntry`, so the ladder is pinned by a pure test and there is one
    /// definition of it; this is the binding of that rule to this state's facts.
    /// Read by `SharedViewerScreen` as `PinDropOverlay.entryFix`.
    public var pinDropEntryCoordinate: CLLocationCoordinate2D? {
        RiderPickupEntry.coordinate(
            seed: pinDropSeed,
            confirmedPickup: draftPickup?.coordinate,
            deviceFix: userLocation.coordinate
        )
    }

    /// Pin-drop pickup coordinate: in live mode the map's settled center (the
    /// authoritative pin position the rider dragged to), falling back to the
    /// region center until the first camera settle; the fixture point in sim
    /// (byte-identical).
    ///
    /// MYR-379 threads the SEED through both arms, and the reason is the same on
    /// each: a rider who searched a pickup and confirmed it before the first
    /// camera settle reported must get the place they typed, never the fallback
    /// underneath it. On live that fallback is `mapRegionCenter`, whose own ladder
    /// resolves to the device fix — i.e. exactly the "it locks to current
    /// location" defect, surviving in the one window where the camera has not
    /// spoken yet. In sim the fallback is the fixture point, and honouring the
    /// seed there is what makes the chain photographable at all; **no simulated
    /// scene carries a seed unless it is about one**, so every existing capture
    /// is byte-identical.
    public var pinDropCoordinate: CLLocationCoordinate2D {
        guard isLiveLocation else { return pinDropSeed ?? DriveFixtures.financialDistrict }
        return pinDropCameraCenter ?? pinDropSeed ?? mapRegionCenter
    }

    /// Pin-drop pickup label (MYR-223): in live mode the current label display
    /// state — the calm in-flight "Finding address…" while a resolution/retry is
    /// running, the resolved street once it lands, or the calm neutral
    /// ("Pinned location") for a genuinely unresolvable point / exhausted retries.
    /// NEVER a stale street resolved for somewhere else (MYR-216-3b, preserved by
    /// the staleness guard in `pinDropCameraSettled`). The fixture "Folsom & 2nd
    /// St" in sim (byte-identical).
    public var pinDropLabel: String {
        guard isLiveLocation else { return RideRequestFixtures.pinSpots[0] }
        switch pinLabelState {
        case .resolving: return Self.pinResolvingLabel
        case .resolved(let label): return label
        case .neutral: return Self.pinNeutralLabel
        }
    }

    /// Called when the pin-drop phase mounts: request a fresh device fix (so the
    /// pin opens on the freshest coordinate, not a stale one / the vehicle
    /// fallback — MYR-212 defect 2) and clear any prior settled pin so it
    /// re-seeds from this session's map. No-op-ish in sim (refresh is a no-op;
    /// the live-only fields stay nil and unused).
    public func enterPinDrop() {
        pinLabelTask?.cancel()
        pinDropCameraCenter = nil
        pinDropResolvedLabel = nil
        pinDropResolvedLabelCoordinate = nil
        // MYR-223: capture is starting — show the calm in-flight label from the
        // first frame (the camera seats before the first settle reports a
        // coordinate), rather than a flash of neutral. The sim path ignores this
        // (pinDropLabel returns the fixture behind the isLiveLocation guard).
        pinLabelState = .resolving
        // MYR-379 — the refresh is asked for ONLY when this session is about the
        // device. See `RiderPickupEntry.isPlaceLed`: a fresh fix landing under a
        // place-led session moves `mapRegionCenter`, which `pinDropCoordinate`
        // falls back to before the first camera settle — i.e. the reported
        // "it locks to current location" defect coming back through the one door
        // left open. A session that IS about the device is unchanged.
        guard !RiderPickupEntry.isPlaceLed(seed: pinDropSeed, confirmedPickup: draftPickup?.coordinate) else { return }
        userLocation.refresh()
    }

    /// The map reported a settled center during pin-drop (live only): adopt it as
    /// the authoritative pickup and refresh the street label. Fires on the ENTRY
    /// settle too, not only after a drag (MYR-216-3a) — the label resolves on
    /// entry without the rider having to jiggle the pin. Ignored in sim so
    /// screenshots stay identical.
    ///
    /// MYR-216-3b STALENESS GUARD: before the fresh geocode lands, a previously
    /// resolved street may keep showing ONLY while the pin is still within
    /// `pinLabelStalenessMeters` of where that street was resolved; past that it's
    /// stale (resolved for somewhere else) and drops to the neutral label at once,
    /// so a drag can never leave a confidently-wrong street on screen. A geocode
    /// that returns `nil` (unresolved / far parcel — MYR-216-3c.2) likewise never
    /// re-keeps a stale street: it clears to neutral until a real result lands.
    public func pinDropCameraSettled(at center: CLLocationCoordinate2D) {
        guard isLiveLocation else { return }
        pinDropCameraCenter = center

        // MYR-216-3b staleness guard, extended for MYR-223's in-flight state: a
        // previously-resolved street may keep showing across this settle ONLY
        // while the pin is still within `pinLabelStalenessMeters` of where it was
        // resolved. If it survives, keep it on screen while we re-resolve (no
        // flicker to "Finding…"); if it does NOT (a drag to a new area, or no
        // prior resolution), drop the stale street at once and show the calm
        // in-flight label — never a confidently-wrong street, never (yet) neutral.
        if Self.resolvedLabelSurvivesSettle(previousCoordinate: pinDropResolvedLabelCoordinate, newCenter: center),
           let kept = pinDropResolvedLabel {
            pinLabelState = .resolved(kept)
        } else {
            pinDropResolvedLabel = nil
            pinDropResolvedLabelCoordinate = nil
            pinLabelState = .resolving
        }

        // MYR-223 SINGLE-FLIGHT + SUPERSEDE: cancel any in-flight resolution — a
        // newer settle always wins. Only ONE resolution runs at a time; a stale
        // one that was mid-backoff is cancelled and ignored.
        pinLabelTask?.cancel()
        let labeler = pinLabeler
        pinLabelTask = Task { [weak self] in
            // Debounce so a fast drag doesn't fire a geocode per settle event.
            try? await Task.sleep(for: .milliseconds(Self.pinLabelDebounceMs))
            guard !Task.isCancelled else { return }
            await self?.resolveLabel(for: center, using: labeler)
        }
    }

    /// MYR-223 deliverable 1 — the single-flight resolution with THROTTLE-AWARE
    /// backoff retry. Runs inside `pinLabelTask` (so a newer settle cancels it):
    ///   • `.resolved` → adopt the street (records the coordinate it's valid for);
    ///   • `.unresolved` → genuine no-result, degrade to neutral immediately (a
    ///     retry returns the same nothing) — never re-keeps a stale street;
    ///   • `.failed` → throttled / transient: stay in-flight ("Finding address…"
    ///     — or, if a valid nearby street is still showing, keep it) and retry
    ///     after the next backoff interval; only once the backoff schedule is
    ///     exhausted is the failure treated as genuine → neutral.
    /// Every branch checks `Task.isCancelled` around the awaits so a superseded
    /// resolution never writes a stale label.
    private func resolveLabel(for center: CLLocationCoordinate2D, using labeler: any RidePinLabeling) async {
        var attempt = 0
        while true {
            guard !Task.isCancelled else { return }
            let resolution = await labeler.resolve(for: center)
            guard !Task.isCancelled else { return }
            switch resolution {
            case .resolved(let label):
                pinDropResolvedLabel = label
                pinDropResolvedLabelCoordinate = center
                pinLabelState = .resolved(label)
                return
            case .unresolved:
                pinDropResolvedLabel = nil
                pinDropResolvedLabelCoordinate = nil
                pinLabelState = .neutral
                return
            case .failed:
                guard attempt < Self.pinLabelRetryBackoffs.count else {
                    // Retries exhausted — treat the persistent failure as genuine.
                    pinDropResolvedLabel = nil
                    pinDropResolvedLabelCoordinate = nil
                    pinLabelState = .neutral
                    return
                }
                // Stay in flight (the label is already `.resolving`, or a valid
                // nearby street is being kept) and back off before retrying.
                try? await Task.sleep(for: Self.pinLabelRetryBackoffs[attempt])
                attempt += 1
            }
        }
    }

    /// MYR-216-3b (pure, testable) — whether the currently resolved street label
    /// may survive a settle to `newCenter`: only while it was resolved for a
    /// coordinate within `pinLabelStalenessMeters` of the new pin. No prior
    /// resolution (nil) never survives (there's nothing valid to keep).
    static func resolvedLabelSurvivesSettle(previousCoordinate: CLLocationCoordinate2D?, newCenter: CLLocationCoordinate2D) -> Bool {
        guard let previous = previousCoordinate else { return false }
        return LivePinLabeler.distanceMeters(previous, newCenter) <= pinLabelStalenessMeters
    }

    // MARK: MYR-239 — confirmed-pickup label (never a stuck transient)
    //
    // The pin-drop sheet's in-flight "Finding address…" (`pinLabelState ==
    // .resolving`) is a TRANSIENT owned by the pin-drop phase — its labeler only
    // runs while dropping the pin (`pinDropCameraSettled`). Baking that transient
    // into the confirmed `draftPickup.label` (the pre-MYR-239 `confirm()` did
    // exactly this) leaked it onto the Search pickup row with nothing left to
    // finish it — it read "Finding address…" forever and persisted across further
    // searches (client device QA IMG_2192/2193/2194). Confirm therefore NEVER
    // persists the transient: a pin confirmed mid-resolution takes the calm
    // "Current location" fallback and ONE bounded re-resolution (the same throttle
    // backoff ladder) upgrades it to the real street if the geocoder recovers,
    // else it stays the fallback — deterministic on every re-entry into Search.

    /// MYR-239 (pure, testable) — the label to PERSIST for a confirmed pickup,
    /// given the pin-drop label state at confirm time. Never the in-flight
    /// transient: a still-`.resolving` pin persists a calm placeholder (a bounded
    /// re-resolution then upgrades it), a resolved street persists as-is, and a
    /// genuinely-neutral pin keeps "Pinned location".
    ///
    /// ⚠️ **MYR-445 DEFECT 2 — THE CALM FALLBACK USED TO BE THE DEFAULT'S OWN
    /// NAME, AND THAT IS THE WHOLE BUG.** MYR-239 chose `pickupFallbackLabel`
    /// ("Current location") here on the explicit reasoning that it was *"the same
    /// string the Search pickup row shows with no confirmed pickup"* — which was
    /// a virtue when that row was a static `Text` and the only alternative was the
    /// stuck "Finding address…" transient. **MYR-379 then made that exact string
    /// the FIELD's default rendering**, and the two collided: a rider who
    /// confirmed a kerb three blocks away — while the reverse geocode was still in
    /// flight, which is the ordinary case on a throttled device — came back to a
    /// field reading "Current location" over a `draftPickup` that is a specific
    /// coordinate. His words: *"current location shows as the placeholder again
    /// even though its not actually set"*. The mirror was right; it was faithfully
    /// mirroring a label that says "nothing is set".
    ///
    /// It is `pinNeutralLabel` now — the same honest "Pinned location" a genuinely
    /// unresolvable pin already takes, which says what is true (you pinned a spot,
    /// we have no street for it yet) and is DISTINGUISHABLE from the untouched
    /// default. MYR-239's invariant is untouched: the transient is still never
    /// persisted, and `resolveConfirmedPickupLabel`'s bounded ladder still upgrades
    /// it to the real street. The stronger guarantee is asserted directly — **no
    /// label state may persist `pickupFallbackLabel`**, so a set pickup can never
    /// again wear the default's name.
    ///
    /// This is LIVE-only (`confirmPickup` reads it behind `isLiveLocation`), so
    /// every simulated pin-drop capture keeps its fixture label and is
    /// byte-identical.
    static func confirmedPickupLabel(for state: PinLabelDisplayState) -> String {
        switch state {
        case .resolved(let label): return label
        case .neutral: return pinNeutralLabel
        case .resolving: return pinNeutralLabel
        }
    }

    @ObservationIgnored private var confirmedPickupLabelTask: Task<Void, Never>?

    /// Confirm the pin-drop pickup as the authoritative `draftPickup` — the
    /// MYR-211/212 coordinate with a MYR-239 DETERMINISTIC label. In sim the
    /// fixture label is kept verbatim (every simulated pin-drop scene stays
    /// pixel-identical). In live, a pin confirmed while its street was still
    /// resolving persists the "Current location" fallback and kicks ONE bounded
    /// re-resolution (see `resolveConfirmedPickupLabel`) — never the stuck
    /// "Finding address…" transient.
    public func confirmPickup() {
        let coordinate = pinDropCoordinate
        let label = isLiveLocation ? Self.confirmedPickupLabel(for: pinLabelState) : pinDropLabel
        draftPickup = Self.pinPickup(label: label, coordinate: coordinate)
        // MYR-379 — the seed is spent the moment a pin is committed. It is rung 1
        // of `RiderPickupEntry`'s ladder and `draftPickup` is rung 2, so a seed
        // left standing would outrank the coordinate the rider just confirmed and
        // re-open the next pin-drop on the pre-drag place — silently undoing the
        // fine-tune this whole feature exists to offer.
        pinDropSeed = nil
        if isLiveLocation, pinLabelState == .resolving {
            resolveConfirmedPickupLabel(for: coordinate)
        }
    }

    /// The confirmed-pickup `RidePlace` shape (id "pin" + pin glyph), shared by
    /// `confirmPickup` and its bounded re-resolution so a label swap preserves
    /// every other field and the coordinate.
    private static func pinPickup(label: String, coordinate: CLLocationCoordinate2D) -> RidePlace {
        RidePlace(id: "pin", label: label, subtitle: nil, miles: 0, minutes: 0,
                  icon: "mappin.circle.fill", coordinate: coordinate)
    }

    /// MYR-239 — ONE bounded re-resolution of a pickup confirmed mid-flight, with
    /// the same throttle-backoff ladder as the pin-drop labeler. On success the
    /// confirmed pickup's label upgrades from the "Current location" fallback to
    /// the real street; a genuine no-result or exhausted retries leaves the
    /// fallback — never a stuck transient. Cancelled/superseded if the pin is
    /// re-dropped or the draft resets.
    private func resolveConfirmedPickupLabel(for coordinate: CLLocationCoordinate2D) {
        confirmedPickupLabelTask?.cancel()
        let labeler = pinLabeler
        confirmedPickupLabelTask = Task { [weak self] in
            defer { self?.confirmedPickupLabelTask = nil }
            var attempt = 0
            while true {
                guard !Task.isCancelled else { return }
                let resolution = await labeler.resolve(for: coordinate)
                guard !Task.isCancelled, let self else { return }
                // Apply only while THIS pin is still the confirmed pickup (the
                // rider hasn't re-dropped it or reset the draft).
                guard let pin = self.draftPickup, pin.id == "pin",
                      LivePinLabeler.distanceMeters(pin.coordinate, coordinate) < 1 else { return }
                switch resolution {
                case .resolved(let label):
                    self.draftPickup = Self.pinPickup(label: label, coordinate: pin.coordinate)
                    return
                case .unresolved:
                    return // keep the calm "Current location" fallback
                case .failed:
                    guard attempt < Self.pinLabelRetryBackoffs.count else { return }
                    try? await Task.sleep(for: Self.pinLabelRetryBackoffs[attempt])
                    attempt += 1
                }
            }
        }
    }

    /// Enter Review, computing the trip estimate once from the confirmed
    /// pickup → destination (MYR-212 defect 5). Only recomputes when the
    /// destination carries no estimate yet (`minutes == 0`, the live search /
    /// pin case) — fixture destinations keep their canned miles/minutes, so the
    /// simulated flow is untouched.
    public func enterReview() {
        if let pickup = draftPickup, let destination = draftDestination {
            draftDestination = TripEstimate.applied(to: destination, pickup: pickup.coordinate)
        }
        // Re-kick a still-unresolved destination (MYR-237) — the estimate just
        // computed from the placeholder gets recomputed when the coordinate
        // lands (see resolveDraftDestinationIfNeeded).
        resolveDraftDestinationIfNeeded()
        sheetPhase = .review
    }

    /// MYR-233 own-ride exception (acceptance criterion 4): true while THIS
    /// rider holds an open instant ride. Kept here (not derived) because the
    /// ride lives in `RideRequestService`, which `SharedViewerState` doesn't
    /// own — `SharedViewerScreen` mirrors the service's status onto it. When
    /// true, the vehicle carrying that ride is never shown as Busy: the rider
    /// sees it as their active ride, exactly as before this issue.
    ///
    /// **MYR-402 — `private(set)`, and the setter below is the only door.** The
    /// exception LIFTING is not a cosmetic flag flip: it is the moment the list row
    /// it was masking becomes load-bearing, and that row is a cached read. Leaving
    /// this assignable meant a caller could lift the mask without re-reading what
    /// was under it — which is exactly what shipped, and what the client saw. Making
    /// the write go through `setRiderOwnsActiveRide` puts the two facts in one
    /// statement the compiler enforces, rather than in two call sites one of which
    /// can be forgotten.
    public private(set) var riderOwnsActiveRide = false

    /// MYR-233 criterion 4 / MYR-402 — mirror "this rider holds an open ride" onto
    /// the viewer state, and re-read the gate inputs whenever the mirror goes DOWN.
    ///
    /// Only on the true→false EDGE: this is called on every appearance and every
    /// status fold, and re-reading on each of those would be a poll wearing an
    /// observer's clothes. Raising the exception needs no refetch — the mask is
    /// going ON, so what is under it cannot matter yet.
    public func setRiderOwnsActiveRide(_ owned: Bool) {
        let lifted = riderOwnsActiveRide && !owned
        riderOwnsActiveRide = owned
        if lifted { refreshRideEndGateInputs() }
    }

    #if DEBUG
    /// MYR-233 drift-gate hook: a live-shaped `FleetMember` a capture scene can
    /// inject so the rider Review row's Busy state is screenshot-able headlessly
    /// without a live backend (the `riderBusyVehicle` scene). `nil` for every
    /// other scene and every shipping build, so the simulated experience is
    /// pixel-identical. Release builds never compile it.
    public var debugFleetMemberOverride: FleetMember?

    /// MYR-352 drift-gate hook: a live-shaped MULTI-vehicle set for the
    /// `riderNoRidesFleet` capture. A fleet is the one input the single-member
    /// override cannot express, and it is the input that selects the banner's
    /// generic headline. `nil` for every other scene and every shipping build.
    public var debugFleetMembersOverride: [FleetMember]?
    #endif

    /// The live fleet member (nickname / real battery / availability / VIN
    /// plate), or `nil` in sim / before the vehicle list loads — MYR-212
    /// deliverable 4. Review + Booking prefer this over the fixture fleet.
    ///
    /// MYR-233: the ONE place the own-ride exception is applied. Folding it here
    /// (rather than at each of the five read sites) means a rider mid-ride can
    /// never see Busy on any surface — Review, Booking, Tracking or Summary.
    ///
    /// MYR-341: and the ONE place the pickup ETA becomes real, for the same
    /// reason. `LiveFleetMemberMapping` cannot compute it — it sees one wire row
    /// and knows nothing about where the rider is standing — so it emits the 0
    /// sentinel and this seam fills it from `RiderPickupETA`. Review's "N min
    /// away" and Booking's pickup clock both read `etaMin` through here, so they
    /// and the idle placeholder are guaranteed to quote the same estimate.
    public var liveFleetMember: FleetMember? {
        #if DEBUG
        if let debugFleetMemberOverride { return resolving(debugFleetMemberOverride) }
        #endif
        guard isLiveLocation, let member = liveVehicleLocator?.fleetMember else { return nil }
        return resolving(member)
    }

    /// MYR-352 — the rider's WHOLE resolved vehicle set, for the idle banner's
    /// "can ANY of them take a request?" question.
    ///
    /// Built on the SAME seam as ``liveFleetMember`` rather than beside it, so the
    /// two can never disagree about the vehicle they share:
    ///
    ///  • The HEAD is `liveFleetMember` itself — fully resolved, i.e. with the
    ///    MYR-233 own-ride exception and the MYR-341 pickup-ETA fill already
    ///    applied. A rider holding this car's open ride must not be told "no rides
    ///    available" about the ride they are on, and that exception lives in
    ///    exactly one place.
    ///  • The TAIL is the remaining `GET /api/vehicles` rows as mapped. Neither of
    ///    those two resolutions applies to them: the own-ride exception is about a
    ///    ride against a specific car, and the pickup ETA is measured to the
    ///    WATCHED vehicle. Applying either would be inventing a fact about a car
    ///    this screen is not showing.
    ///  • EMPTY in SIM and before the list lands, because `liveFleetMember` is
    ///    `nil` there — which is what makes the banner live-path-only and every
    ///    simulated capture byte-identical.
    public var liveFleetMembers: [FleetMember] {
        #if DEBUG
        if let debugFleetMembersOverride { return debugFleetMembersOverride }
        #endif
        guard let head = liveFleetMember else { return [] }
        let tail = liveVehicleLocator.map { Array($0.fleetMembers.dropFirst()) } ?? []
        return [head] + tail
    }

    /// MYR-398 v3 — the car the Live Activity's pickup subline identifies, or `nil`
    /// on the simulated path and before the list lands.
    ///
    /// Gated on `isLiveLocation` exactly as `liveFleetMember` is, so a SIMULATED ride
    /// can never put a fixture plate on a real lock screen (MYR-228). The Activity
    /// itself is inert in simulated mode anyway, which makes this the second of two
    /// independent gates rather than the only one.
    /// Internal rather than `public` like its neighbours, because
    /// `RideActivityVehicle` is: the type is shared with the WIDGET target as a
    /// source folder rather than as a package, so it has no `public` surface to
    /// inherit and does not need one.
    var liveActivityVehicle: RideActivityVehicle? {
        guard isLiveLocation else { return nil }
        return liveVehicleLocator?.activityVehicle
    }

    /// MYR-352 — the idle sheet's banner, or `nil` when there is nothing honest to
    /// say. Composed here (not in the view) so the whole matrix is a pure value.
    public var idleAvailabilityBanner: RiderIdleAvailability? {
        RiderIdleAvailabilityBanner.banner(members: liveFleetMembers)
    }

    private func resolving(_ member: FleetMember) -> FleetMember {
        applyingPickupETA(resolvingOwnRide(member))
    }

    private func resolvingOwnRide(_ member: FleetMember) -> FleetMember {
        guard riderOwnsActiveRide, member.unavailability == .busy else { return member }
        return member.clearingUnavailability()
    }

    /// MYR-341 — fill the pickup ETA, following `TripEstimate.applied(to:)`'s
    /// gate style exactly: only when the member carries the 0 sentinel (so a
    /// fixture's own 3/8/12 is never overwritten) and only when a real estimate
    /// exists (so an unmeasurable car keeps 0 and the surfaces render their calm
    /// unknown rather than a fabricated minute).
    private func applyingPickupETA(_ member: FleetMember) -> FleetMember {
        guard member.etaMin == 0, let minutes = pickupETAMinutes else { return member }
        return member.withPickupETA(minutes)
    }

    /// MYR-270 — the streamed nav ETA (minutes) of the ride's car for the rider's
    /// tracking "Arriving" takeover. Still `nil`, so the rider sheet never
    /// fabricates an "Arriving" state on the live path (MYR-228 — no fake ETA).
    ///
    /// MYR-336 gives the rider a live stream, so the reason this stays nil has
    /// CHANGED and is worth stating precisely: the snapshot's `etaMinutes` is the
    /// car's own navigation ETA to whatever Tesla is routing it to, which is not
    /// provably the rider's pickup. Quoting it as "arriving in N" would be a real
    /// number about the wrong destination — a worse failure than silence. It
    /// becomes safe once MYR-231's two-leg dispatch statuses identify the car's
    /// current leg; this stays the one place it swaps in.
    public var riderNavMinutesToArrival: Int? { nil }

    /// The fleet member to render for a draft/record `id`: the live vehicle in
    /// live mode (single-vehicle join), else the fixture looked up by id.
    public func fleetMember(forID id: String) -> FleetMember {
        liveFleetMember ?? (RideRequestFixtures.fleet.first { $0.id == id } ?? RideRequestFixtures.fleet[0])
    }

    // MARK: MYR-385 — the schedule picker's conflict read
    //
    // WHICH vehicle and WHICH range are derived exactly once, here, because three
    // callers need the answer and they must not be able to disagree: the picker
    // OPENING (a fresh read), a DAY-CHIP change (top up the range if the chips
    // ever outgrow one request), and a create refused `409 time_conflict` (the one
    // moment the previous answer is known to be wrong). A `refresh` spelled at
    // three call sites is three chances to name a different car than the one the
    // draft targets.
    //
    // Both are no-ops on the simulated path — not by a branch here, but because
    // `RideBookedWindowsStore` holds no provider there.

    /// The vehicle the schedule is being picked FOR — the same `fleetMember(forID:)`
    /// resolution `RideRequestSearchContent.targetVehicle` and MYR-316's floor use,
    /// so the windows read and the floor applied describe one car.
    private var scheduleTargetVehicleID: String { fleetMember(forID: draftFleetMemberID).id }

    /// Re-read §7.22 unconditionally.
    func refreshBookedWindows(now: Date = Date(), calendar: Calendar = .current) {
        guard let range = RideBookedWindowsRange.range(
            days: RideScheduleDays.days(now: now, calendar: calendar), now: now, calendar: calendar
        ) else { return }
        bookedWindows.refresh(vehicleID: scheduleTargetVehicleID, from: range.from, to: range.to)
    }

    /// Read §7.22 only when the picker's chip range is not already covered.
    func ensureBookedWindowsCovered(now: Date = Date(), calendar: Calendar = .current) {
        guard let range = RideBookedWindowsRange.range(
            days: RideScheduleDays.days(now: now, calendar: calendar), now: now, calendar: calendar
        ) else { return }
        bookedWindows.ensureCovered(vehicleID: scheduleTargetVehicleID, from: range.from, to: range.to)
    }

    /// The windows held for the vehicle THIS draft targets — `[]` whenever nothing
    /// has landed, the read failed, the path is simulated, or the draft has since
    /// been re-pointed at another car. Empty dims nothing, which is the picker
    /// exactly as it behaved before MYR-385.
    var draftBookedWindows: [RideBookedWindow] {
        bookedWindows.windows(for: scheduleTargetVehicleID)
    }

    // MARK: MYR-216 deliverable 2 — pin-drop back affordance
    //
    // A back control on the pin-drop sheet returns to SEARCH *without* confirming
    // a pickup, RETAINING the chosen destination so the rider lands back on the
    // search sheet in its CTA state (the field filled + "Continue") to adjust or
    // restart. This is distinct from Cancel, which ABANDONS the whole request to
    // idle (`resetDraftToIdle`). The design's `PinDropContent` (ride-request.jsx
    // 722-738) has only one control — Cancel wired to `setPhase('search')`
    // (screens.jsx:2075); MYR-216 splits that into a dedicated back (→ search,
    // keep destination) and a true Cancel (→ idle), so the two are genuinely
    // distinct (the design's lone Cancel and a new back would otherwise both land
    // on search). The back chevron follows the design's existing back pattern —
    // Review's "‹ Change trip" (ride-request.jsx ReviewContent / this app's
    // `RideRequestReviewContent` 65-78).

    /// Pin-drop "back": return to the search sheet, keeping the chosen
    /// destination (CTA state) — the rider adjusts or restarts. No pickup is
    /// confirmed. Nothing else in the draft is touched.
    public func returnFromPinDropToSearch() {
        // MYR-379 — backing out commits NOTHING, so the searched pickup that led
        // here goes with the session. The search sheet's pickup field is a mirror
        // of `draftPickup` (which this leaves untouched), so the row falls back to
        // "Current location" and the sheet tells the truth: the rider looked at a
        // place and did not take it.
        pinDropSeed = nil
        sheetPhase = .search
    }

    // MARK: MYR-389 — A DRAFT TRIP DOES NOT OUTLIVE THE FLOW THAT MADE IT
    //
    // THE DEFECT (r15, build 202607311129, the client's own words): *"when I tried
    // to search it pulled up a prev route, the state wasn't reset to a clean
    // search."* He tapped the idle map's "Where to?" and got his previous booking
    // attempt back — destination filled, "Pickup Tomorrow · 12:00 PM" still
    // latched, the old route etching in behind the sheet.
    //
    // THE CAUSE is an exit that ends the FLOW without ending the DRAFT. Review's
    // scheduled `confirm()` returned the rider to the idle map with a bare
    // `sheetPhase = .idle` (M1 scope: a reservation starts no live trip), leaving
    // every draft field exactly where the rider left it — and the idle search bar
    // was a bare `sheetPhase = .search`, which ADOPTS whatever is lying around.
    // Two halves of one omission, and neither reads as wrong at its own call site.
    //
    // THE RULE, and it is deliberately an ENTRY invariant rather than an exit
    // cleanup: **entering the request flow from the idle map always starts from
    // nothing.** An exit-side fix has to be repeated on every path out — there are
    // six today, `resetDraftToIdle` covered five, and the sixth is the one that
    // shipped. An entry-side fix is one rule at the two doors, and it covers exits
    // that do not exist yet. The offending exit is fixed TOO (it is one line, and a
    // draft that lingers is still wrong even where nothing reads it), but the
    // guarantee does not depend on it.
    //
    // SCOPE: this is UNSUBMITTED state only. Nothing here touches
    // `RideRequestService.activeRequest`, so a submitted ride keeps the rider's
    // slot and keeps resuming its own surface through `reconciledPhase` — the
    // reservation the rider just booked is still theirs, it is simply no longer a
    // draft. Nor is the route cache dropped: a LIVE ride owns its geometry
    // (MYR-381), and the search preview stops reading that ride's endpoints
    // instead (`SharedViewerScreen.previewRouteRequest`).

    /// Everything an in-progress, UNSUBMITTED draft trip consists of — the ONE
    /// list, so a field added to the draft cannot be forgotten by half the callers.
    ///
    /// `previewPickupAnchor` is in it now and was not before: `resetDraftToIdle`
    /// cleared the pickup PLACE but left the anchored fix behind it, so the next
    /// trip's route cache was keyed on the previous trip's pickup until a new
    /// destination re-anchored it (`capturePreviewPickupAnchor` only writes when the
    /// anchor is nil). `clearChosenDestination` had always cleared both, which is
    /// what kept it invisible.
    public func discardDraftTrip() {
        confirmedPickupLabelTask?.cancel() // MYR-239 — no re-resolution outlives the draft
        confirmedPickupLabelTask = nil
        draftPickup = nil
        // MYR-379 — and so is a searched pickup that never reached the pin. This
        // is MYR-389's own lesson applied to the field it added: the ONE list of
        // what a draft is has to name every part of it, or the next trip inherits
        // the leftover. A stale seed is the sharpest possible version of that —
        // it would open a brand-new trip's pin-drop on the previous trip's pickup.
        pinDropSeed = nil
        draftDestination = nil
        draftFleetMemberID = RideRequestFixtures.fleet[0].id
        draftPassenger = nil
        draftSchedule = nil
        previewPickupAnchor = nil // MYR-389 — the pickup ANCHOR is draft state too
        // MYR-390 — and so is whether this trip's route has been etched. Keying
        // the etch on route IDENTITY already makes a NEW destination etch from
        // zero on its own; this covers the case identity cannot see, which is a
        // rider who abandoned a trip and started an identical one. That is a new
        // trip by every other measure in this method, so it draws itself again.
        routeEtchLedger.forget()
        pinReturn = .search
        showDeclinedNotice = false
        opensScheduleOnSearch = false // MYR-233 — one-shot, never outlives the draft
        scheduleReturn = .search // MYR-382 — and neither does where it returns to
    }

    /// Resets the draft + returns to `.idle` — ride-request.jsx `closeToIdle`.
    public func resetDraftToIdle() {
        discardDraftTrip()
        sheetPhase = .idle
    }

    /// MYR-389 — the idle map's "Where to?" (tapped OR dragged open). The ONE door
    /// into search from idle, and it opens on nothing: a rider reaching for the
    /// search field is starting a trip, never resuming one they walked away from.
    public func enterSearchFromIdle() {
        noteRideFlowEntry()
        discardDraftTrip()
        sheetPhase = .search
    }

    /// MYR-389 — the idle sheet's Home/Work quick chips, which enter the flow
    /// WITH a destination. Same door, same rule: the chip supplies the destination
    /// and nothing else may ride along, or a stale schedule/passenger from an
    /// abandoned trip would silently become part of a brand-new one.
    public func selectDestinationFromIdle(_ place: RidePlace) {
        noteRideFlowEntry()
        discardDraftTrip()
        selectDestination(place)
    }

    // MARK: MYR-478 — ride capability is re-derived, not remembered
    //
    // An owner withdrawing a grantee's Rides toggle (§7.5.7 `allowRides: false`)
    // sends the rider's device NOTHING. The server busts its own cached access set
    // and the WebSocket teardown is deliberately SUSPENSION-only, because
    // `allowRides` has no socket effect at all — so the only way this client can
    // learn is to re-read the §7.0 list, which already carries the derived
    // `sharePermission` the tier is folded from.
    //
    // Before this, the catalog behind that tier was read once per rider-shell
    // entry and on nothing else: a foreground re-read existed but was gated on
    // `loadFailed && !hasLoaded`, i.e. it recovered a list that had NEVER
    // answered and never refreshed one that had. A healthy session therefore held
    // its first answer for the life of the process — MYR-402's "a cold launch was
    // the only refresh in the app", on the neighbouring read.
    //
    // This tick is the RIDE-FLOW-ENTRY half of the funnel (the shell observes it
    // and re-reads); `scenePhase` covers the FOREGROUND half. Same shape as
    // `riderAccessRevocationTick` — a counter the shell watches — rather than a
    // closure, so this object still knows nothing about the catalog and the
    // simulated path is untouched by construction (nothing observes it there
    // either, and `SimulatedSharedVehicleCatalog` publishes no tier).

    /// Bumped whenever this object has established that the rider's ride
    /// capability is worth re-reading. The shell observes it and performs the
    /// §7.0 read; nothing here knows the catalog exists.
    public private(set) var rideCapabilityRefreshTick = 0

    /// Door one — the rider entered the ride flow from idle. Both idle entry
    /// points call it, so a third added later has to walk past this line
    /// (MYR-389's entry-invariant lesson, applied to the read rather than the
    /// reset).
    private func noteRideFlowEntry() {
        rideCapabilityRefreshTick &+= 1
    }

    /// Door two — a create was refused `403 vehicle_not_owned`, which is the one
    /// moment the cached tier is KNOWN to be wrong: the server has just refused a
    /// ride on it. Same funnel as door one rather than a second read path, for
    /// MYR-385's reason (`handleVehicleUnavailable` re-reads §7.22 on exactly the
    /// same logic).
    public func noteRideCapabilityRefused() {
        rideCapabilityRefreshTick &+= 1
    }

    /// MYR-233 — leave Review for the SCHEDULING flow because the vehicle can't
    /// take an instant request right now. Keeps the whole draft (pickup,
    /// destination, passenger) so the rider only has to pick a time, and arms the
    /// search sheet's schedule card so the next thing they see IS that picker.
    public func routeToScheduling() {
        opensScheduleOnSearch = true
        // MYR-382 — THE ROUTE IS A ROUND TRIP NOW. See `scheduleReturn`.
        scheduleReturn = .review
        sheetPhase = .search
    }
}
