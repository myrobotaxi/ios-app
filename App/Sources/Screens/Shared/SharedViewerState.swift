import CoreLocation
import DesignSystem
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

// MARK: - Shared viewer state (MYR-191, extended MYR-171)
//
// Owns the rider's live-map telemetry + sheet phase + in-progress request
// draft, lifted above the `sharedTab` switch in `RootView` — mirrors
// `OwnerHomeState`'s reasoning (see that file's header comment) so the
// watched vehicle's ticking telemetry (and, as of MYR-171, the rider's place
// in the request flow) survives switching to Ride History/Settings and back.
@Observable
@MainActor
public final class SharedViewerState {
    /// The one shared vehicle the rider is watching on the live map
    /// (screens.jsx:1865 `v = VEHICLES[0]`). Distinct from `FLEET`
    /// (screens.jsx:15-19, ported as `RideRequestFixtures.fleet`) — the
    /// Teslas the rider can actually *request* in Review; M1 fixes the
    /// resting map's view to this one vehicle regardless of which fleet
    /// member ends up carrying an active request.
    public let vehicle: Vehicle
    public let telemetrySource: any VehicleTelemetrySource

    // MARK: MYR-211 — real place search + location seams
    //
    // Injected by `PlaceSearchComposition` (sim fixtures by default, live
    // MapKit/CoreLocation when the launch env selects it). The search sheet
    // reads `placeSearch.results`; the map/pin-drop read `mapRegionCenter` +
    // `userLocation`. See each seam's header for the sim↔live contract.
    let placeSearch: any PlaceSearching
    let userLocation: any UserLocationProviding
    let liveVehicleLocator: RiderLiveVehicleLocator?
    /// True only when the live seams are composed — gates the real pin-drop
    /// coordinate (device/vehicle region) below.
    let isLiveLocation: Bool

    /// MYR-191 extension point — see `RiderSheetPhase`.
    public var sheetPhase: RiderSheetPhase = .idle

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

    /// Public convenience: the simulated seams (fixtures) — the default for
    /// previews / tests / the sim demo. Delegates to the designated init.
    public convenience init(vehicle: Vehicle = VehicleFixtures.vehicles[0]) {
        self.init(vehicle: vehicle, seams: .simulated)
    }

    /// Designated init taking the composed seams (`PlaceSearchComposition.make()`
    /// wires live vs. sim in `RootView`). Internal — `Seams` is a module type.
    init(vehicle: Vehicle = VehicleFixtures.vehicles[0], seams: PlaceSearchComposition.Seams) {
        self.vehicle = vehicle
        telemetrySource = SimulatedVehicleTelemetrySource(activity: vehicle.activity)
        placeSearch = seams.placeSearch
        userLocation = seams.userLocation
        liveVehicleLocator = seams.liveVehicleLocator
        isLiveLocation = seams.isLive
    }

    public var snapshot: VehicleTelemetrySnapshot { telemetrySource.snapshot }

    public func startTelemetry() {
        telemetrySource.start()
        userLocation.start()
        liveVehicleLocator?.start()
    }

    public func stopTelemetry() {
        telemetrySource.stop()
        userLocation.stop()
        liveVehicleLocator?.stop()
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

    /// Select a destination and advance the flow (MYR-171 / MYR-211 defect B).
    /// If a pickup is already set, straight to Review; otherwise route through
    /// the pin-drop step so the rider confirms their exact pickup spot on the
    /// map — the design flow (`screens.jsx:2195`). The pin-drop map is centered
    /// on the rider's LIVE coordinate in live mode (`pinDropCoordinate`), so
    /// "Current location" is the pin's STARTING point, never a bypass. Sim is
    /// unchanged (no fix ⇒ pin-drop over the fixture region, as before).
    public func selectDestination(_ place: RidePlace) {
        draftDestination = place
        if draftPickup != nil {
            sheetPhase = .review
        } else {
            pinReturn = .review
            sheetPhase = .pinDrop(returnTo: .review)
        }
    }

    /// Pin-drop pickup coordinate: the real map-center (device/vehicle region)
    /// in live mode, the fixture point in sim (byte-identical).
    public var pinDropCoordinate: CLLocationCoordinate2D {
        isLiveLocation ? mapRegionCenter : DriveFixtures.financialDistrict
    }

    /// Pin-drop pickup label: the reverse-geocoded device label in live mode,
    /// the fixture "Folsom & 2nd St" in sim (byte-identical).
    public var pinDropLabel: String {
        isLiveLocation ? userLocation.currentLocationLabel : RideRequestFixtures.pinSpots[0]
    }

    /// Resets the draft + returns to `.idle` — ride-request.jsx `closeToIdle`.
    public func resetDraftToIdle() {
        sheetPhase = .idle
        draftPickup = nil
        draftDestination = nil
        draftFleetMemberID = RideRequestFixtures.fleet[0].id
        draftPassenger = nil
        draftSchedule = nil
        showDeclinedNotice = false
    }
}
