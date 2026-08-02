import CoreLocation
import Foundation
import MyRoboTaxiKit
@testable import MyRoboTaxi
import XCTest

// MARK: - MYR-422 — the post-ride hero's route is a ladder, and every rung is real
//
// The client's decision on the MYR-414 build: the summary should GO AND GET its
// geometry, best source first — the car's own driven track (§7.2 + §7.4), then the
// app's MKDirections road-route preview, then pins.
//
// Five properties are pinned here, and each is a way this could pass a screenshot
// while being wrong:
//
//  1. **THE ORDER.** A ride with a driven track never spends an MKDirections call.
//     Rung 2 is not merely unpreferred, it is not FETCHED.
//  2. **THE ACCESS FALL-THROUGH.** Drives are owner-only (MYR-369), so a
//     viewer-tier rider's read is a 403 — the ORDINARY case. It must land on the
//     Apple rung silently and be remembered, not retried per mount.
//  3. **THE WINDOW MATCH.** A drive is this ride only if it COVERS the trip, and
//     the drawn track is cut to the trip — otherwise the rider's summary opens at
//     the owner's driveway.
//  4. **RE-ENTRY.** A settled summary re-mounted asks nothing again: one verdict per
//     ride, for ever.
//  5. **NO STRAIGHT LINES, ON EITHER RUNG.** MYR-293's predicate is applied to the
//     car's own track exactly as it is to MKDirections' degradation.
final class RideSummaryRouteLadderTests: XCTestCase {

    private let tripStart = Date(timeIntervalSince1970: 1_800_000_000)
    private var tripEnd: Date { tripStart.addingTimeInterval(14 * 60) }

    // MARK: - Fixtures

    private func coordinate(_ lat: Double, _ lng: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    /// A many-vertex polyline — real road geometry as far as `RideRoutePolyline` is
    /// concerned.
    private func polyline(_ count: Int = 6) -> [CLLocationCoordinate2D] {
        (0..<count).map { coordinate(37.77 + Double($0) * 0.002, -122.41 + Double($0) * 0.002) }
    }

    /// The straight `[from, to]` pair a provider returns when it has nothing.
    private var straightPair: [CLLocationCoordinate2D] {
        [coordinate(37.7749, -122.4194), coordinate(37.6156, -122.3900)]
    }

    /// A driven track spanning `[from, to]`, one point every `interval` seconds.
    private func track(from: Date, to: Date, interval: TimeInterval = 10) -> [RideDrivePoint] {
        var points: [RideDrivePoint] = []
        var t = from
        var step = 0.0
        while t <= to {
            points.append(RideDrivePoint(coordinate: coordinate(37.77 + step * 0.0005, -122.41 + step * 0.0005), at: t))
            t = t.addingTimeInterval(interval)
            step += 1
        }
        return points
    }

    /// A scripted join seam that COUNTS its reads — the only way to tell "cached"
    /// from "asked again", which is what half of this file is about (`RoutedHTTP
    /// .setBody`'s lesson from MYR-402: a stub that cannot be asked twice makes a
    /// re-read indistinguishable from a cache).
    private final class CountingJoin: RideDriveRouteProviding, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var driveListReads = 0
        private(set) var routeReads = 0
        var drives: [RideDriveWindow]
        var points: [RideDrivePoint]
        var failure: Error?

        init(drives: [RideDriveWindow] = [], points: [RideDrivePoint] = [], failure: Error? = nil) {
            self.drives = drives
            self.points = points
            self.failure = failure
        }

        func recentDrives(vehicleID: String) async throws -> [RideDriveWindow] {
            lock.lock(); driveListReads += 1; lock.unlock()
            if let failure { throw failure }
            return drives
        }

        func drivenRoute(driveID: String) async throws -> [RideDrivePoint] {
            lock.lock(); routeReads += 1; lock.unlock()
            if let failure { throw failure }
            return points
        }
    }

    /// The store's read is fire-and-forget by design (nothing waits on it), so the
    /// tests have to — the `RideBookedWindowsTests` convention verbatim.
    @MainActor
    private func settle() async {
        for _ in 0..<50 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    // MARK: - 1. The rung order

    /// **A DRIVEN TRACK ENDS THE LADDER.** The hero is the car's own geometry and
    /// the MKDirections rung is not merely unused — `fetchesRoadRoute` is false, and
    /// that flag is the ONLY thing that starts an Apple call for this page, so a
    /// ride with a Tesla route cannot spend one.
    func testTheDrivenRouteWinsAndTheAppleRungIsNeverFetched() {
        let driven = polyline(40)
        let resolution = RideSummaryRoute.resolve(
            join: .drive(polyline: driven, miles: 8.4),
            // A road route already in hand must NOT win: it is the fallback.
            roadRoute: polyline(12)
        )
        XCTAssertEqual(resolution.hero?.source, .tesla)
        XCTAssertEqual(resolution.hero?.polyline.count, driven.count)
        XCTAssertEqual(resolution.hero?.miles, 8.4)
        XCTAssertFalse(resolution.fetchesRoadRoute,
                       "an Apple call spent on a ride that has a driven track is a call spent for nothing")
    }

    /// While the join is still in flight, nothing is CLAIMED from rung 1 and no
    /// Apple call is spent — but a route already in hand (the one the ride warmed
    /// during tracking) is still real geometry and is still drawn. Withholding it
    /// would blank the hero for the length of two REST reads.
    func testAJoinInFlightDrawsWhatIsAlreadyHeldAndFetchesNothing() {
        let held = polyline(20)
        let resolution = RideSummaryRoute.resolve(join: .resolving, roadRoute: held)
        XCTAssertEqual(resolution.hero?.source, .apple)
        XCTAssertEqual(resolution.hero?.polyline.count, held.count)
        XCTAssertFalse(resolution.fetchesRoadRoute, "rung 1 may still answer")
    }

    /// The empty-handed in-flight frame: pins only, and still no fetch.
    func testAJoinInFlightWithNothingHeldIsPinsOnly() {
        let resolution = RideSummaryRoute.resolve(join: .resolving, roadRoute: nil)
        XCTAssertNil(resolution.hero)
        XCTAssertFalse(resolution.fetchesRoadRoute)
    }

    /// Rung 2: the join settled with nothing, so the road route is fetched — and
    /// drawn and measured once it lands.
    func testNoDriveRouteFallsToTheAppleRung() {
        let road = polyline(30)
        let pending = RideSummaryRoute.resolve(join: .none, roadRoute: nil)
        XCTAssertNil(pending.hero, "nothing is held yet, so pins — but the fetch is on")
        XCTAssertTrue(pending.fetchesRoadRoute)

        let landed = RideSummaryRoute.resolve(join: .none, roadRoute: road)
        XCTAssertEqual(landed.hero?.source, .apple)
        XCTAssertEqual(landed.hero?.miles, RideRouteGeometry.lengthMiles(road))
    }

    // MARK: - 2. No straight lines, on either rung

    /// **MYR-293'S LAW, APPLIED TO THE CAR'S OWN TRACK.** A two-point "driven route"
    /// (a trim that kept almost nothing, a stub, a decode that lost its middle) is
    /// no more a route than MKDirections' `[from, to]` degradation is, so the ladder
    /// continues past it instead of drawing it.
    func testATwoPointDrivenTrackIsRefusedAndTheLadderContinues() {
        let resolution = RideSummaryRoute.resolve(
            join: .drive(polyline: straightPair, miles: 12.4),
            roadRoute: nil
        )
        XCTAssertNil(resolution.hero, "two points is what a provider returns when it has nothing")
        XCTAssertTrue(resolution.fetchesRoadRoute, "so this ride still needs the Apple rung")
    }

    /// And the same predicate on rung 2 — the 14.2 mi defect, in one assertion: a
    /// straight fallback is neither drawn nor measured, on any join verdict.
    func testAStraightAppleFallbackIsNeverDrawnOrMeasured() {
        for join in [RideSummaryRoute.DriveJoin.resolving, .none] {
            let resolution = RideSummaryRoute.resolve(join: join, roadRoute: straightPair)
            XCTAssertNil(resolution.hero, "\(join): a great-circle guess is not the trip's geometry")
        }
    }

    // MARK: - 3. The window match

    private func window(_ id: String, from: TimeInterval, to: TimeInterval) -> RideDriveWindow {
        RideDriveWindow(
            id: id,
            start: tripStart.addingTimeInterval(from),
            end: tripEnd.addingTimeInterval(to)
        )
    }

    /// **COVERAGE, NOT OVERLAP.** The approach the car made before the trip and the
    /// drive home after it both overlap the window at an edge and are not the ride.
    func testOnlyADriveThatCoversTheWholeTripIsACandidate() {
        let approach = RideDriveWindow(
            id: "approach",
            start: tripStart.addingTimeInterval(-20 * 60),
            end: tripStart.addingTimeInterval(60)
        )
        let driveHome = RideDriveWindow(
            id: "home",
            start: tripEnd.addingTimeInterval(-60),
            end: tripEnd.addingTimeInterval(30 * 60)
        )
        XCTAssertNil(
            RideDriveJoin.drive(coveringTripFrom: tripStart, to: tripEnd, in: [approach, driveHome]),
            "a drive that shares an edge with the trip is a different journey"
        )
    }

    /// **THE TOLERANCE IS THE TWO CLOCKS.** `tripStart` is this device's observation
    /// of the rider's tap; `drive.start` is the car shifting out of park. A couple
    /// of minutes either way is the ordinary case, and a zero-tolerance rule would
    /// miss the correct drive on most real rides.
    func testTheToleranceAbsorbsTheDifferenceBetweenTheTwoClocks() {
        let slightlyLate = window("late", from: 2 * 60, to: -2 * 60)
        XCTAssertEqual(
            RideDriveJoin.drive(coveringTripFrom: tripStart, to: tripEnd, in: [slightlyLate])?.id,
            "late"
        )
        let wayOut = window("way-out", from: RideDriveJoin.coverageTolerance + 60, to: 0)
        XCTAssertNil(
            RideDriveJoin.drive(coveringTripFrom: tripStart, to: tripEnd, in: [wayOut]),
            "past the tolerance it is not this trip, and a miss costs only the Apple rung"
        )
    }

    /// The TIGHTEST cover wins, so a long errand that happens to contain the trip
    /// loses to the drive that IS the trip — and the answer does not depend on the
    /// order the page arrived in.
    func testTheTightestCoveringDriveWins() {
        let errand = window("errand", from: -40 * 60, to: 40 * 60)
        let theRide = window("the-ride", from: -60, to: 60)
        for candidates in [[errand, theRide], [theRide, errand]] {
            XCTAssertEqual(
                RideDriveJoin.drive(coveringTripFrom: tripStart, to: tripEnd, in: candidates)?.id,
                "the-ride"
            )
        }
    }

    /// **THE TRACK IS CUT TO THE TRIP.** A Tesla drive is bounded by park→park, so
    /// it routinely contains the approach leg as well; drawing the whole thing would
    /// show the rider a journey starting where they have never been.
    func testTheDrivenTrackIsTrimmedToTheTripsOwnWindow() {
        let whole = track(from: tripStart.addingTimeInterval(-6 * 60), to: tripEnd.addingTimeInterval(90))
        let trimmed = RideDriveJoin.trim(whole, tripFrom: tripStart, to: tripEnd)
        XCTAssertLessThan(trimmed.count, whole.count, "the approach is not part of the ride")
        XCTAssertGreaterThan(trimmed.count, 2, "and what remains is still real geometry")

        // Every kept point lies inside the padded window, and the FIRST one is at
        // the trip's own start rather than at the drive's.
        let kept = whole.filter { point in
            trimmed.contains { $0.latitude == point.coordinate.latitude && $0.longitude == point.coordinate.longitude }
        }
        for point in kept {
            XCTAssertGreaterThanOrEqual(point.at, tripStart.addingTimeInterval(-RideDriveJoin.trimPad))
            XCTAssertLessThanOrEqual(point.at, tripEnd.addingTimeInterval(RideDriveJoin.trimPad))
        }
    }

    /// The pad exists for the same reason the coverage tolerance does: a `tripStart`
    /// observed a few seconds late must not clip the first block off the line.
    func testTheTrimPadKeepsPointsJustOutsideTheWindow() {
        let justBefore = RideDrivePoint(coordinate: coordinate(1, 1), at: tripStart.addingTimeInterval(-30))
        let wellBefore = RideDrivePoint(coordinate: coordinate(2, 2), at: tripStart.addingTimeInterval(-10 * 60))
        let trimmed = RideDriveJoin.trim([wellBefore, justBefore], tripFrom: tripStart, to: tripEnd)
        XCTAssertEqual(trimmed.count, 1)
        XCTAssertEqual(trimmed.first?.latitude, 1)
    }

    // MARK: - 4. The store: one verdict per ride, ever

    @MainActor
    func testACoveringDriveResolvesToItsTrimmedTrack() async {
        let join = CountingJoin(
            drives: [window("the-ride", from: -3 * 60, to: 60)],
            points: track(from: tripStart.addingTimeInterval(-3 * 60), to: tripEnd.addingTimeInterval(60))
        )
        let store = RideSummaryDriveRouteStore(provider: join)
        store.resolve(rideID: "ride_1", vehicleID: "veh_1", tripStart: tripStart, completedAt: tripEnd)
        await settle()

        guard case let .drive(polyline, miles) = store.join(for: "ride_1") else {
            return XCTFail("the covering drive should have answered, got \(store.join(for: "ride_1"))")
        }
        XCTAssertTrue(RideRoutePolyline.isReal(polyline))
        XCTAssertGreaterThan(miles, 0)
        XCTAssertEqual(join.driveListReads, 1)
        XCTAssertEqual(join.routeReads, 1)
    }

    /// **RE-ENTRY SPENDS NOTHING.** A settled summary can be mounted many times — a
    /// tab switch, a remount, a return to the rider shell — and every mount asks the
    /// same question about the same finished ride.
    @MainActor
    func testASummaryReEnteredNeverAsksAgain() async {
        let join = CountingJoin(
            drives: [window("the-ride", from: -60, to: 60)],
            points: track(from: tripStart, to: tripEnd)
        )
        let store = RideSummaryDriveRouteStore(provider: join)
        // Three mounts before the read has even landed …
        for _ in 0..<3 {
            store.resolve(rideID: "ride_1", vehicleID: "veh_1", tripStart: tripStart, completedAt: tripEnd)
        }
        await settle()
        // … and three after it settled.
        for _ in 0..<3 {
            store.resolve(rideID: "ride_1", vehicleID: "veh_1", tripStart: tripStart, completedAt: tripEnd)
        }
        await settle()
        XCTAssertEqual(join.driveListReads, 1, "six mounts, one §7.2 read")
        XCTAssertEqual(join.routeReads, 1, "and one §7.4 read")
    }

    /// **THE 403 IS A VERDICT, AND IT IS CACHED.** Drives are owner-only (MYR-369),
    /// so this is the ordinary answer for a viewer-tier rider — not an error to
    /// retry. Re-spending a forbidden call on every mount would be a request per
    /// appearance to be told the same thing, with a real road route already
    /// available one rung down.
    @MainActor
    func testAForbiddenDrivesReadIsRememberedRatherThanRetried() async {
        let join = CountingJoin(failure: RestError.http(status: 403, code: .permissionDenied, message: nil, subCode: nil))
        let store = RideSummaryDriveRouteStore(provider: join)
        store.resolve(rideID: "ride_1", vehicleID: "veh_1", tripStart: tripStart, completedAt: tripEnd)
        await settle()
        XCTAssertEqual(store.join(for: "ride_1"), .none)

        store.resolve(rideID: "ride_1", vehicleID: "veh_1", tripStart: tripStart, completedAt: tripEnd)
        await settle()
        XCTAssertEqual(join.driveListReads, 1, "the refusal was remembered")
        XCTAssertEqual(join.routeReads, 0, "and the second read was never reached")

        // And the ladder falls through in silence — a real road route, no caption,
        // no error styling, nothing about drives anywhere on the page.
        XCTAssertEqual(
            RideSummaryRoute.resolve(join: store.join(for: "ride_1"), roadRoute: polyline(20)).hero?.source,
            .apple
        )
    }

    /// A ride adopted mid-flight has no observable start (MYR-414's honest gap), so
    /// there is no window to match a drive against and nothing to trim one to. It
    /// settles `.none` WITHOUT A READ — guessing a window from `acceptedAt` would put
    /// the approach leg on the rider's summary.
    @MainActor
    func testARideWithNoObservedStartMakesNoRequestAtAll() async {
        let join = CountingJoin(drives: [window("the-ride", from: -60, to: 60)], points: track(from: tripStart, to: tripEnd))
        let store = RideSummaryDriveRouteStore(provider: join)
        store.resolve(rideID: "ride_1", vehicleID: "veh_1", tripStart: nil, completedAt: tripEnd)
        await settle()
        XCTAssertEqual(store.join(for: "ride_1"), .none)
        XCTAssertEqual(join.driveListReads, 0)
    }

    /// No covering drive (the common case minutes after a drop-off — a drive is
    /// written when the car PARKS) → the Apple rung, with only the list read spent.
    @MainActor
    func testNoCoveringDriveNeverReadsARoute() async {
        let join = CountingJoin(
            drives: [RideDriveWindow(id: "yesterday", start: tripStart.addingTimeInterval(-86_400), end: tripStart.addingTimeInterval(-80_000))],
            points: track(from: tripStart, to: tripEnd)
        )
        let store = RideSummaryDriveRouteStore(provider: join)
        store.resolve(rideID: "ride_1", vehicleID: "veh_1", tripStart: tripStart, completedAt: tripEnd)
        await settle()
        XCTAssertEqual(store.join(for: "ride_1"), .none)
        XCTAssertEqual(join.driveListReads, 1)
        XCTAssertEqual(join.routeReads, 0, "the heavy §7.4 payload is only fetched for a drive we have matched")
    }

    /// A drive whose track leaves fewer than three points inside the trip's window
    /// is not a route (MYR-293 again), so the store answers `.none` rather than
    /// handing a straight line up the ladder.
    @MainActor
    func testADegenerateTrimmedTrackIsNotATeslaRoute() async {
        let join = CountingJoin(
            drives: [window("the-ride", from: -60, to: 60)],
            // Two points, both inside the window.
            points: [
                RideDrivePoint(coordinate: coordinate(37.77, -122.41), at: tripStart.addingTimeInterval(10)),
                RideDrivePoint(coordinate: coordinate(37.79, -122.39), at: tripEnd.addingTimeInterval(-10))
            ]
        )
        let store = RideSummaryDriveRouteStore(provider: join)
        store.resolve(rideID: "ride_1", vehicleID: "veh_1", tripStart: tripStart, completedAt: tripEnd)
        await settle()
        XCTAssertEqual(store.join(for: "ride_1"), .none)
    }

    /// **THE DISTANCE IS MEASURED BEFORE THE DECIMATION.** A long drive is thinned to
    /// the Drives tab's own 800-point render cap for DRAWING; a thinned track cuts
    /// corners, and the tile states one decimal place, so the miles come off the full
    /// track.
    @MainActor
    func testALongDriveIsThinnedForDrawingAndMeasuredWhole() async {
        let whole = track(from: tripStart, to: tripEnd, interval: 0.5) // ~1,681 points
        let join = CountingJoin(drives: [window("the-ride", from: -60, to: 60)], points: whole)
        let store = RideSummaryDriveRouteStore(provider: join)
        store.resolve(rideID: "ride_1", vehicleID: "veh_1", tripStart: tripStart, completedAt: tripEnd)
        await settle()

        guard case let .drive(polyline, miles) = store.join(for: "ride_1") else {
            return XCTFail("expected a driven route")
        }
        XCTAssertGreaterThan(whole.count, DriveContractMapping.maxRoutePoints)
        XCTAssertEqual(polyline.count, DriveContractMapping.maxRoutePoints, "drawn at the render cap")
        XCTAssertEqual(
            miles,
            RideRouteGeometry.lengthMiles(whole.map(\.coordinate)),
            accuracy: 0.0001,
            "measured on every point the car recorded"
        )
    }

    /// A new ride asks again — the verdicts are released with the rider's slot.
    @MainActor
    func testResetForgetsTheVerdict() async {
        let join = CountingJoin(failure: RestError.http(status: 403, code: .permissionDenied, message: nil, subCode: nil))
        let store = RideSummaryDriveRouteStore(provider: join)
        store.resolve(rideID: "ride_1", vehicleID: "veh_1", tripStart: tripStart, completedAt: tripEnd)
        await settle()
        store.reset()
        XCTAssertEqual(store.join(for: "ride_1"), .resolving, "forgotten, not remembered as settled")
        store.resolve(rideID: "ride_1", vehicleID: "veh_1", tripStart: tripStart, completedAt: tripEnd)
        await settle()
        XCTAssertEqual(join.driveListReads, 2)
    }

    // MARK: - 5. The simulated path cannot join at all

    /// The MYR-385 absence gate, applied to this seam: SIM has no drive history and
    /// no endpoint, so the summary does not *decline* to join — it has nothing to
    /// join WITH, and no `isLive` branch inside the store can be got backwards.
    @MainActor
    func testTheSimulatedPathCannotConstructTheJoinAtAll() async {
        XCTAssertNil(PlaceSearchComposition.Seams.simulated.driveRoutes)

        let store = RideSummaryDriveRouteStore(provider: nil)
        store.resolve(rideID: "ride_1", vehicleID: "veh_1", tripStart: tripStart, completedAt: tripEnd)
        await settle()
        XCTAssertEqual(store.join(for: "ride_1"), .none)
    }
}
