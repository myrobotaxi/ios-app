import CoreLocation

// MARK: - MYR-456 / MYR-457 — what the owner's driving map draws, and the
// progress that goes with it
//
// **TWO EXTERNAL-BETA REPORTS, ONE DERIVATION.** Both are build `202608030843`,
// both are the owner's live map, and both are the same three lines of
// `VehicleContractMapping` read per frame with no gate, no fallback and no
// memory:
//
//   * **MYR-457** — *"No route poly line"*, *"TESLA route line is no longer
//     populating on the map for the current ride"*. The line was not missing, it
//     was WRONG: `drivingTrip` answered an absent `navRouteCoordinates` with
//     `[currentPosition, destination]` and `VehicleMapView` drew it, so the map
//     claimed a straight path across blocks, a park and a highway. The **same**
//     absence set `tripProgress` to 0 (an absent route has zero length), and
//     `DrivingHeroElement.resolve` gates the bar on `progress > 0` — which is the
//     second half of that report, *"weird gap below destination and menu bar"*.
//     One defect, two symptoms, and the reporter had already paired them.
//   * **MYR-456** — *"Gold eta line now back, seems every time route updates it
//     goes and comes."* His two frames are 30s apart on one trip, and in the
//     BROKEN one the destination, "Arriving in 23 min" and the ETA are all still
//     on screen. So navigation was active and only `progress > 0` can have
//     failed — i.e. the nav group was mid-update. The contract says so plainly:
//     the group's members "may legitimately arrive apart" inside the server's
//     500ms accumulation window, and NFR-3.9 amplifies any one null across the
//     whole group. **A frame that catches a route update in flight blanks the
//     line and the bar together, because both are read from the same
//     half-applied group.**
//
// **THE RULE THIS TYPE STATES.** A route update is ATOMIC from the map's point
// of view: the last route we really had stays drawn until a replacement is
// really in hand. Nothing here invents geometry — every rung is either wire
// geometry, road geometry someone fetched, or a route this same resolver
// already accepted.
enum OwnerDrivingRoute {

    /// Where the drawn line came from. Kept so a test can say WHICH rung answered
    /// rather than only that a line appeared — the `RiderIdleGate` lesson
    /// (MYR-402): every failure mode producing the same output is a failure mode
    /// no test can name.
    enum Source: Equatable {
        /// Tesla's own decoded `RouteLine`.
        case wire
        /// The app's MKDirections road route, fetched car → destination. The
        /// client's own direction for the sibling surface (MYR-422): *"we should
        /// default the app map route preview if we can't get the route polyline
        /// from Tesla."*
        case fetched
        /// A route already accepted on an earlier frame, held across an update.
        case held
        /// Nothing real to draw. Pins only — never a fabricated segment.
        case none
    }

    struct Resolution: Equatable {
        var line: [CLLocationCoordinate2D]
        var progress: Double
        var source: Source

        /// The map strokes a line only when there is one. `isReal` decided that
        /// on the way in, so this is a shape question, not a second predicate.
        var drawsLine: Bool { line.count > 1 }

        static let none = Resolution(line: [], progress: 0, source: .none)

        /// Hand-written because `CLLocationCoordinate2D` is not `Equatable`
        /// (`DrivingTrip` carries the same note for the same reason).
        static func == (lhs: Resolution, rhs: Resolution) -> Bool {
            lhs.source == rhs.source
                && lhs.progress == rhs.progress
                && lhs.line.count == rhs.line.count
                && zip(lhs.line, rhs.line).allSatisfy {
                    $0.latitude == $1.latitude && $0.longitude == $1.longitude
                }
        }
    }

    /// Fraction of `route` already travelled, or `nil` when the wire has not said.
    ///
    /// **`nil` and `0` are different answers and the difference is the whole
    /// MYR-456 fix.** `0` means "measured, and the car is at the start" — a real
    /// trip-start reading, and `DrivingHeroElement` correctly hides the bar for it
    /// (`TripProgressBar` clamps to 0.05, so 0 would draw a fabricated 5% orb).
    /// `nil` means "this frame did not carry a distance", which is not a position
    /// at all and must never be rendered as one.
    static func measure(remainingMiles: Double?, route: [CLLocationCoordinate2D]) -> Double? {
        guard let remainingMiles else { return nil }
        let total = VehicleRoute.totalDistanceMiles(along: route)
        guard total > 0 else { return nil }
        return min(1, max(0, 1 - remainingMiles / total))
    }

    /// Resolve this frame's line + progress.
    ///
    /// - Parameters:
    ///   - navigationActive: the nav atomic group's own predicate
    ///     (`DrivingNavigation.isActive`). When navigation is genuinely OFF there
    ///     is no trip, and the hold is dropped rather than kept — a route held
    ///     past the end of its journey is MYR-381's stale etch.
    ///   - wireRoute: Tesla's decoded `RouteLine` for this frame.
    ///   - fetchedRoute: the app's own road route for this car → this destination,
    ///     or empty while it is in flight / has failed.
    ///   - remainingMiles: `VehicleState.tripDistanceRemaining`.
    ///   - reportedProgress: the fraction the snapshot already carries.
    ///
    ///     **This parameter is what keeps the simulated path byte-identical, and
    ///     it was found by looking at the screen rather than by reading.** The
    ///     first cut of this type re-derived progress unconditionally — and on the
    ///     simulated path `tripDistanceRemaining` is `nil` (the ticker owns the
    ///     fraction directly), so every owner scene resolved 0 and the peek hero
    ///     silently lost its `TripProgressBar`. A `> 0` reported value is
    ///     therefore authoritative: on sim it is the ticker's own, and on live it
    ///     is `tripProgress`'s reading of the wire route, which is the same
    ///     arithmetic this function performs.
    ///   - held: the resolution this same function returned for the previous frame
    ///     of the SAME journey. The caller is responsible for dropping it when the
    ///     destination changes — identity is the caller's fact, not this
    ///     function's.
    static func resolve(
        navigationActive: Bool,
        wireRoute: [CLLocationCoordinate2D],
        fetchedRoute: [CLLocationCoordinate2D],
        remainingMiles: Double?,
        reportedProgress: Double,
        held: Resolution?
    ) -> Resolution {
        // 0 · No journey, no route. Nothing is held across this.
        guard navigationActive else { return .none }

        // 1 · Tesla's own geometry, when it is geometry at all. `isReal` is the
        //     ONE predicate (MYR-293) — a 2-point "route" is refused here exactly
        //     as `AppleRideRouteProvider`'s straight degradation is refused on the
        //     rider's surfaces, which is what retires `[currentPosition, dest]`.
        if RideRoutePolyline.isReal(wireRoute) {
            return Resolution(
                line: wireRoute,
                progress: measure(remainingMiles: remainingMiles, route: wireRoute)
                    ?? unmeasured(reportedProgress, held: held, for: wireRoute),
                source: .wire
            )
        }

        // 2 · The app's own road route. This is the rung that makes MYR-457's map
        //     honest rather than merely blank: MYR-395's *"a refusal to draw and a
        //     failure to draw are the same picture"* applies with full force to an
        //     owner watching their own car, and unlike that issue's surface this
        //     one has a working alternative underneath it.
        if RideRoutePolyline.isReal(fetchedRoute) {
            return Resolution(
                line: fetchedRoute,
                progress: measure(remainingMiles: remainingMiles, route: fetchedRoute)
                    ?? unmeasured(reportedProgress, held: held, for: fetchedRoute),
                source: .fetched
            )
        }

        // 3 · MYR-456 · HOLD. Navigation is still on and this frame simply has no
        //     geometry in it — a nav-group update in flight, or Tesla's RouteLine
        //     between two values. The previous route is the freshest thing we
        //     hold, and holding it is the same rule MYR-393 applies to the car
        //     marker: render what we have, never a gap where a fact used to be.
        if let held, held.drawsLine {
            return Resolution(line: held.line, progress: held.progress, source: .held)
        }

        // 4 · Genuinely nothing. Pins only.
        return .none
    }

    /// The progress to carry when THIS frame could not measure one.
    ///
    /// **The reported value wins whenever there is one**, which is what keeps the
    /// simulated ticker (and any future non-distance source) exactly as it was: a
    /// caller that already knows the fraction is not improved by this type
    /// guessing at it. Only when the report is ALSO empty — the live mid-update
    /// frame, where `tripProgress` measured against the same absent data and
    /// likewise answered 0 — does the hold speak.
    ///
    /// Held only when the held resolution describes the same geometry: a progress
    /// measured against a different polyline is a fraction of a different journey.
    private static func unmeasured(
        _ reportedProgress: Double,
        held: Resolution?,
        for line: [CLLocationCoordinate2D]
    ) -> Double {
        if reportedProgress > 0 { return reportedProgress }
        guard let held, held.line.count == line.count else { return 0 }
        return held.progress
    }
}
