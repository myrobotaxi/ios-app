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
    let pinLabeler: any RidePinLabeling
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
        pinLabeler = seams.pinLabeler
        isLiveLocation = seams.isLive
    }

    public var snapshot: VehicleTelemetrySnapshot { telemetrySource.snapshot }

    public func startTelemetry() {
        telemetryStarted = true
        telemetrySource.start()
        userLocation.start()
        liveVehicleLocator?.start()
    }

    public func stopTelemetry() {
        telemetryStarted = false
        telemetrySource.stop()
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
    }

    public func handleForeground() {
        guard telemetryStarted else { return }
        userLocation.start()
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
        draftDestination = place
    }

    /// Clear a search-sheet destination choice (the field was edited or cleared),
    /// returning the sheet to search-as-you-type (deliverable 3).
    public func clearChosenDestination() {
        draftDestination = nil
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

    /// Pin-drop pickup coordinate: in live mode the map's settled center (the
    /// authoritative pin position the rider dragged to), falling back to the
    /// region center until the first camera settle; the fixture point in sim
    /// (byte-identical).
    public var pinDropCoordinate: CLLocationCoordinate2D {
        guard isLiveLocation else { return DriveFixtures.financialDistrict }
        return pinDropCameraCenter ?? mapRegionCenter
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

    /// Enter Review, computing the trip estimate once from the confirmed
    /// pickup → destination (MYR-212 defect 5). Only recomputes when the
    /// destination carries no estimate yet (`minutes == 0`, the live search /
    /// pin case) — fixture destinations keep their canned miles/minutes, so the
    /// simulated flow is untouched.
    public func enterReview() {
        if let pickup = draftPickup, let destination = draftDestination {
            draftDestination = TripEstimate.applied(to: destination, pickup: pickup.coordinate)
        }
        sheetPhase = .review
    }

    /// The live fleet member (nickname / real battery / availability / VIN
    /// plate), or `nil` in sim / before the vehicle list loads — MYR-212
    /// deliverable 4. Review + Booking prefer this over the fixture fleet.
    public var liveFleetMember: FleetMember? {
        isLiveLocation ? liveVehicleLocator?.fleetMember : nil
    }

    /// The fleet member to render for a draft/record `id`: the live vehicle in
    /// live mode (single-vehicle join), else the fixture looked up by id.
    public func fleetMember(forID id: String) -> FleetMember {
        liveFleetMember ?? (RideRequestFixtures.fleet.first { $0.id == id } ?? RideRequestFixtures.fleet[0])
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
        sheetPhase = .search
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
