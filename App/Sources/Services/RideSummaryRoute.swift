import CoreLocation
import Foundation
import MyRoboTaxiKit
import MyRobotaxiContracts
import Observation

// MARK: - MYR-422 — the post-ride hero's route is a LADDER, and every rung is real
//
// MYR-414 made this map honest by REFUSING: the summary drew the ride's leg-2 road
// route when the tracking sheet had happened to warm one, and pins otherwise. The
// client's decision on that build is that the refusal is too eager in both
// directions — the app should go and GET the geometry, and it should prefer the
// truest geometry there is:
//
//   1. **THE TESLA-DRIVEN ROUTE.** The car recorded where it actually went
//      (§7.2 + §7.4, the machinery the owner's Drives tab has used since
//      MYR-203/204). Joined to the ride by TIME — see `RideDriveJoin` — and
//      trimmed to the trip's own window, so what is drawn is the path the rider
//      was in the car for and nothing else.
//   2. **THE APP'S OWN ROAD-ROUTE PREVIEW.** MKDirections pickup → dropoff, the
//      same `RideRouteStore` / `AppleRideRouteProvider` the booking preview and
//      the tracking legs use. Not what the car drove — what the roads say — but
//      REAL road geometry, which is the whole of MYR-293's law.
//   3. **PINS ONLY.** Both refused: the two endpoint dots, no line, ever.
//
// **MYR-293'S LAW IS UNTOUCHED AND IS ENFORCED IN ONE PLACE.** Every rung passes
// through `RideRoutePolyline.isReal`, so a two-point "driven route" (a drive whose
// window barely overlaps, a stub, a decode that lost its middle) is refused
// exactly as MKDirections' straight `[from, to]` degradation is. There is no path
// through this file that puts a straight line on the summary.
//
// **THE RUNGS ARE STRICTLY ORDERED, AND THAT ORDER COSTS SOMETHING.** The
// MKDirections rung is not *fetched* until the join has SETTLED — otherwise every
// summary would spend a throttle-budgeted Apple call it may not need, which is the
// MYR-237 budget this repo has been careful with for six issues. A route already
// in hand (the ride warmed leg 2 during tracking) is still DRAWN while the join
// runs: it is real geometry, so withholding it would be an artificial blank.

// MARK: - What the summary hero draws, and what the distance tile measures

/// The hero's geometry AND its length, as ONE value.
///
/// MYR-414's invariant is that the drawn line and the distance tile are refused by
/// the same fact — "the page can never draw a route it will not measure or measure
/// one it will not draw". Carrying the two in one optional makes that structural
/// rather than a rule two call sites have to keep.
///
/// The length is measured on the FULL geometry, before any decimation for drawing
/// (`RideSummaryDriveRouteStore` thins a long drive to the Drives tab's own 800-pt
/// render cap): a thinned track cuts corners, and the tile states a distance to one
/// decimal place.
struct RideSummaryHeroRoute {
    /// Real road geometry — `RideRoutePolyline.isReal` by construction.
    let polyline: [CLLocationCoordinate2D]
    /// The polyline's own length in miles, measured before decimation.
    let miles: Double
    /// Which rung answered. Nothing in the UI branches on this today; it exists so
    /// a capture, a log line or a test can say WHICH source drew the line, which is
    /// the only way to tell rung 1 from rung 2 in a screenshot of two real routes.
    let source: RideSummaryRoute.Source
}

// MARK: - The ladder itself (pure)

enum RideSummaryRoute {
    /// Which rung produced the geometry on screen.
    enum Source: Equatable {
        /// §7.4 — where the car actually went.
        case tesla
        /// MKDirections — where the roads say it would go.
        case apple
    }

    /// What the drive join has to say about this ride.
    ///
    /// **`none` DELIBERATELY FOLDS EVERY REASON THERE IS NO TESLA ROUTE**: no drive
    /// covers the trip's window, the drives read failed (a viewer-tier rider's
    /// **403** is the ordinary case — MYR-369), the ride has no observable window to
    /// match on, the polyline came back empty, or there is no join seam at all (the
    /// simulated path). They differ in cause and not in consequence: the summary
    /// falls to the next rung, silently, in every one of them. Splitting them into
    /// cases would invite a surface to say something about a distinction the rider
    /// cannot act on — MYR-395's "right now" caption reasoning, pointed at a rung
    /// that has a working alternative underneath it.
    enum DriveJoin: Equatable {
        /// The read has not answered (or has not started). No line is claimed from
        /// this rung, and no Apple call is spent yet.
        case resolving
        /// The car's own driven polyline for the trip's window, plus its length.
        case drive(polyline: [CLLocationCoordinate2D], miles: Double)
        /// Settled: this ride has no Tesla route, for whatever reason.
        case none

        static func == (lhs: DriveJoin, rhs: DriveJoin) -> Bool {
            switch (lhs, rhs) {
            case (.resolving, .resolving), (.none, .none): return true
            case let (.drive(lp, lm), .drive(rp, rm)):
                return lm == rm && lp.count == rp.count
                    && zip(lp, rp).allSatisfy { $0.latitude == $1.latitude && $0.longitude == $1.longitude }
            default: return false
            }
        }
    }

    struct Resolution {
        /// What to draw and measure — `nil` is rung 3, pins only.
        var hero: RideSummaryHeroRoute?
        /// Whether the caller should run the MKDirections rung NOW. False while the
        /// join is still resolving (rung 1 may yet answer, and an Apple call spent
        /// on a ride that has a driven route is a call spent for nothing) and false
        /// once a driven route is in hand.
        var fetchesRoadRoute: Bool
    }

    /// - Parameters:
    ///   - join: rung 1's verdict.
    ///   - roadRoute: whatever the `RideRouteStore` currently holds for THIS ride's
    ///     exact pickup/destination pair — the store's raw answer, straight
    ///     fallback and all. The realness gate is applied here so the summary has
    ///     exactly one place that decides what may be drawn.
    static func resolve(join: DriveJoin, roadRoute: [CLLocationCoordinate2D]?) -> Resolution {
        switch join {
        case let .drive(polyline, miles) where RideRoutePolyline.isReal(polyline):
            return Resolution(
                hero: RideSummaryHeroRoute(polyline: polyline, miles: miles, source: .tesla),
                fetchesRoadRoute: false
            )
        case .drive:
            // A driven "route" of fewer than three points is not a route (MYR-293's
            // predicate, applied to the car's own track for the same reason it is
            // applied to MKDirections'), so this ride has no rung-1 geometry after
            // all and the ladder continues.
            return roadRung(roadRoute)
        case .resolving:
            // Nothing is claimed FROM rung 1 yet, but a route already in hand is
            // still real geometry and is drawn. No fetch: the join may still answer.
            return Resolution(hero: appleHero(roadRoute), fetchesRoadRoute: false)
        case .none:
            return roadRung(roadRoute)
        }
    }

    private static func roadRung(_ roadRoute: [CLLocationCoordinate2D]?) -> Resolution {
        Resolution(hero: appleHero(roadRoute), fetchesRoadRoute: true)
    }

    private static func appleHero(_ roadRoute: [CLLocationCoordinate2D]?) -> RideSummaryHeroRoute? {
        guard let roadRoute, RideRoutePolyline.isReal(roadRoute) else { return nil }
        return RideSummaryHeroRoute(
            polyline: roadRoute,
            miles: RideRouteGeometry.lengthMiles(roadRoute),
            source: .apple
        )
    }
}

// MARK: - Rung 1's two inputs, narrowed to what the join needs

/// One completed drive's window (§7.2 `DriveSummary`, reduced to the three fields
/// the join reads). Reduced deliberately: the join is about TIME and identity, and
/// a type carrying `fsdMiles` would invite the summary to start quoting a drive's
/// statistics for a ride — see the note on `RideSummaryDriveRouteStore` about why
/// it does not.
struct RideDriveWindow: Equatable, Sendable {
    let id: String
    let start: Date
    let end: Date

    var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// One driven GPS point (§7.4 `RoutePoint`, reduced to position + instant).
///
/// **THE INSTANT IS WHAT MAKES RUNG 1 HONEST.** A Tesla drive is bounded by the
/// car shifting out of park and back into it, so a single drive routinely contains
/// BOTH legs of a ride — the owner's approach to the pickup and the trip itself. A
/// summary that drew the whole drive would show the rider a journey that starts
/// somewhere they have never been. Because every point is stamped, the track can be
/// cut to the trip's own window instead.
struct RideDrivePoint: Sendable {
    let coordinate: CLLocationCoordinate2D
    let at: Date
}

/// "Which drive was this ride, and what did the car drive during it?" — narrowed to
/// two methods so the store can be driven by a stub with no network, the same seam
/// style as `RideBookedWindowsProviding`.
protocol RideDriveRouteProviding: Sendable {
    /// The vehicle's recent completed drives, newest first (§7.2, first page).
    func recentDrives(vehicleID: String) async throws -> [RideDriveWindow]
    /// One drive's GPS track, oldest first (§7.4).
    func drivenRoute(driveID: String) async throws -> [RideDrivePoint]
}

/// The production provider: §7.2 + §7.4 through the Kit, folded by the shipping
/// `DriveContractMapping` timestamp parse.
///
/// Holds the ENDPOINT protocol rather than a concrete `RestClient` so a DEBUG
/// capture scene can inject a wire stub and still run this exact code — the "real
/// code path, injected wire" precedent of `DebugBookedWindowsEndpoint` /
/// `DebugServiceWindowEndpoint`.
struct LiveRideDriveRoutes: RideDriveRouteProviding {
    let endpoint: any VehicleDrivesEndpoint

    /// One page is the whole horizon, on purpose. The join is about a ride that
    /// just ended, and §7.2 is newest-first, so the covering drive is at the head of
    /// page 1 or it does not exist yet (a drive is written when the car parks, which
    /// can be minutes after the drop-off). Paging backwards through a rider's
    /// history to find an older cover would be searching for a drive that cannot be
    /// this ride.
    static let pageLimit = 20

    func recentDrives(vehicleID: String) async throws -> [RideDriveWindow] {
        let page = try await endpoint.drives(vehicleID: vehicleID, cursor: nil, limit: Self.pageLimit)
        return page.items.compactMap { summary in
            guard let start = VehicleContractMapping.parseTimestamp(summary.startTime),
                  let end = VehicleContractMapping.parseTimestamp(summary.endTime),
                  end > start
            else { return nil }
            return RideDriveWindow(id: summary.id, start: start, end: end)
        }
    }

    func drivenRoute(driveID: String) async throws -> [RideDrivePoint] {
        let route = try await endpoint.driveRoute(id: driveID)
        return route.routePoints.compactMap { point in
            guard let at = VehicleContractMapping.parseTimestamp(point.timestamp) else { return nil }
            return RideDrivePoint(
                coordinate: CLLocationCoordinate2D(latitude: point.lat, longitude: point.lng),
                at: at
            )
        }
    }
}

// MARK: - The join rule (pure)

/// Matching a ride to the drive that WAS it, and cutting that drive down to the
/// ride.
///
/// **THE MATCHING RULE, STATED ONCE:** a drive is a candidate when it COVERS the
/// trip's window — `drive.start <= tripStart + tolerance` and
/// `drive.end >= tripEnd - tolerance` — and the candidate with the SHORTEST
/// duration wins.
///
/// Each half of that is doing work:
///
///  • **Coverage, not overlap.** A neighbouring drive (the owner's approach to the
///    pickup, if the car parked at the kerb; the drive home afterwards) overlaps a
///    trip window at its edges and is not the ride. Requiring the drive to span the
///    whole trip refuses those outright.
///  • **A TOLERANCE, because the two clocks are different measurements of different
///    events.** `tripStart` is THIS DEVICE's observation of the rider's "Start ride"
///    tap; `drive.start` is the car shifting out of park. `tripEnd` is the server's
///    `completedAt` (the owner's "Dropped off"); `drive.end` is the car parking. Any
///    of the four can lag the others by a minute or two, in either direction, and a
///    zero-tolerance rule would miss the correct drive on most real rides.
///    `coverageTolerance` (5 min) is deliberately generous: MISSING a cover costs a
///    silent fall to rung 2, which is a perfectly good road route; a WRONG cover
///    would draw another journey.
///  • **The tightest candidate wins**, so a long errand that happens to contain the
///    trip loses to the drive that IS the trip, and the answer is deterministic
///    whatever order the page arrived in.
///
/// A ride with no observable `tripStart` (adopted mid-flight after a force-quit —
/// MYR-414's honest gap) has no window to match on, so the caller never gets here.
enum RideDriveJoin {
    /// How far apart the two clocks may be at each end of the window.
    static let coverageTolerance: TimeInterval = 5 * 60

    /// How far outside the trip's window a driven point may still belong to the
    /// trip. Absorbs the same clock difference the coverage tolerance does, at the
    /// finer granularity of the track: without it, a `tripStart` observed a few
    /// seconds late would clip the first block from the drawn line.
    static let trimPad: TimeInterval = 60

    static func drive(
        coveringTripFrom tripStart: Date,
        to tripEnd: Date,
        in drives: [RideDriveWindow],
        tolerance: TimeInterval = coverageTolerance
    ) -> RideDriveWindow? {
        drives
            .filter { $0.start <= tripStart.addingTimeInterval(tolerance) && $0.end >= tripEnd.addingTimeInterval(-tolerance) }
            // Tightest cover first; the id breaks a tie so the answer never depends
            // on page order.
            .min { ($0.duration, $0.id) < ($1.duration, $1.id) }
    }

    /// The driven track, cut to the trip's own window.
    ///
    /// Points are kept in the order given (§7.4 is oldest-first) — a sort here would
    /// paper over a wire ordering bug by drawing a plausible line through it.
    static func trim(
        _ points: [RideDrivePoint],
        tripFrom tripStart: Date,
        to tripEnd: Date,
        pad: TimeInterval = trimPad
    ) -> [CLLocationCoordinate2D] {
        let from = tripStart.addingTimeInterval(-pad)
        let to = tripEnd.addingTimeInterval(pad)
        return points.filter { $0.at >= from && $0.at <= to }.map(\.coordinate)
    }
}

// MARK: - Rung 1's store: one verdict per ride, ever

/// Fetches and REMEMBERS the drive join for a ride.
///
/// **THE RE-ENTRY DISCIPLINE IS THE POINT OF THIS TYPE.** A settled summary can be
/// mounted more than once — a tab switch, a remount, a return to the rider shell —
/// and every mount asks the same question about the same finished ride. So the
/// verdict is resolved ONCE per ride id and then answered from memory: two REST
/// calls per ride, not per appearance. `RideRouteStore`'s pair cache gives the
/// MKDirections rung the identical property, so no rung can be made to re-fetch by
/// looking at the page again.
///
/// **EVERY FAILURE IS A VERDICT, AND IT IS CACHED.** A 403 (the viewer-tier rider,
/// MYR-369 — the common case, not an exceptional one), an offline read, a decode:
/// all record "no Tesla route" for this ride's lifetime. Retrying would re-spend
/// the same forbidden call on every mount to be told the same thing, and the rung
/// underneath is already a real road route. This is deliberately NOT MYR-326's
/// "loading ≠ unavailable" situation: nothing here is presented to the rider as a
/// state, and there is a working alternative one rung down.
///
/// **IT DOES NOT READ THE DRIVE'S STATISTICS, and that is a decision rather than an
/// omission.** `DriveSummary` carries `fsdMiles` and `fsdPercentage` — the very
/// numbers MYR-422's placeholder tiles are dashes for. They describe the WHOLE
/// DRIVE, which routinely contains the approach leg as well as the trip (that is
/// why the polyline has to be trimmed at all), and unlike the polyline they cannot
/// be cut to the window: §7.4's points carry no autonomy state. Quoting a drive's
/// FSD figure as the ride's would be MYR-414's defect with better provenance. See
/// `RideSummaryPresentation.Tile` for where a window-scoped figure would land the
/// day the server can produce one.
@Observable
@MainActor
final class RideSummaryDriveRouteStore {

    /// Bumped whenever a verdict settles, so a view can re-resolve the ladder (and,
    /// on a `.none`, start the MKDirections rung) without polling.
    private(set) var settledCount = 0

    @ObservationIgnored private let provider: (any RideDriveRouteProviding)?
    private var verdicts: [String: RideSummaryRoute.DriveJoin] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []

    /// `nil` provider = the simulated path, exactly as `RideBookedWindowsStore`
    /// takes it: a simulated summary does not *decline* to join, it has nothing to
    /// join WITH, so no `isLive` branch is needed inside this type and every
    /// simulated capture is byte-identical.
    init(provider: (any RideDriveRouteProviding)?) {
        self.provider = provider
    }

    /// This ride's verdict — `.resolving` until one is recorded.
    func join(for rideID: String) -> RideSummaryRoute.DriveJoin {
        verdicts[rideID] ?? .resolving
    }

    /// Resolve the join for a ride, at most once per ride id.
    ///
    /// - Parameters:
    ///   - tripStart: the trip's own start (`RideRequestRecord.enrouteObservedAt`).
    ///     `nil` — a ride adopted mid-flight — settles `.none` immediately: with no
    ///     window there is nothing to match a drive against and nothing to trim one
    ///     to, and guessing a window from `acceptedAt` would put the approach leg on
    ///     the rider's summary.
    ///   - completedAt: the server's own completion instant.
    ///   - onSettled: run once, AFTER an asynchronous verdict is recorded — the hook
    ///     the caller advances the ladder's next rung from. Deliberately NOT called
    ///     for a verdict settled synchronously (no seam, no window, or one already
    ///     in hand): the caller can see that outcome on the line after this one, and
    ///     a callback that sometimes fires before `resolve` has returned is the
    ///     shape that produces a double-fetch at exactly one call site.
    func resolve(
        rideID: String,
        vehicleID: String,
        tripStart: Date?,
        completedAt: Date?,
        onSettled: (@MainActor (RideSummaryRoute.DriveJoin) -> Void)? = nil
    ) {
        guard verdicts[rideID] == nil, !inFlight.contains(rideID) else { return }
        guard let provider,
              !vehicleID.isEmpty,
              let tripStart,
              let completedAt,
              completedAt > tripStart
        else {
            record(.none, for: rideID)
            return
        }
        inFlight.insert(rideID)
        Task { [weak self] in
            let verdict = await Self.fetch(
                provider: provider,
                vehicleID: vehicleID,
                tripStart: tripStart,
                tripEnd: completedAt
            )
            self?.inFlight.remove(rideID)
            self?.record(verdict, for: rideID)
            onSettled?(verdict)
        }
    }

    /// Forget every verdict (the rider's slot released — a new ride asks again).
    func reset() {
        verdicts.removeAll()
        inFlight.removeAll()
    }

    private func record(_ verdict: RideSummaryRoute.DriveJoin, for rideID: String) {
        verdicts[rideID] = verdict
        settledCount += 1
    }

    private static func fetch(
        provider: any RideDriveRouteProviding,
        vehicleID: String,
        tripStart: Date,
        tripEnd: Date
    ) async -> RideSummaryRoute.DriveJoin {
        do {
            let drives = try await provider.recentDrives(vehicleID: vehicleID)
            guard let match = RideDriveJoin.drive(coveringTripFrom: tripStart, to: tripEnd, in: drives) else {
                return .none
            }
            let points = try await provider.drivenRoute(driveID: match.id)
            let trimmed = RideDriveJoin.trim(points, tripFrom: tripStart, to: tripEnd)
            guard RideRoutePolyline.isReal(trimmed) else { return .none }
            return .drive(
                // Drawn at the Drives tab's own render cap (MYR-204's uniform
                // decimation, endpoints preserved) …
                polyline: DriveContractMapping.thin(trimmed),
                // … and MEASURED on the full track: thinning cuts corners, and the
                // distance tile states one decimal place.
                miles: RideRouteGeometry.lengthMiles(trimmed)
            )
        } catch {
            // 403 (a viewer-tier rider — the ordinary case), offline, a decode: one
            // verdict, cached, and the ladder falls to a real road route.
            return .none
        }
    }
}
