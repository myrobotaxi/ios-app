import CoreLocation
@testable import MyRoboTaxi
import MyRoboTaxiKit
import MyRobotaxiContracts
import XCTest

// MARK: - MYR-456 / MYR-457 — the owner's driving map draws a real route or none,
// and a route UPDATE never blanks it
//
// **THE TWO REPORTS, build `202608030843`.**
//
//   * MYR-457, four submissions: *"No route poly line"*, *"Route poly line not
//     showing, weird gap below destination and menu bar"*, *"TESLA route line is
//     no longer populating on the map for the current ride"*. All four screenshots
//     show the owner map in Driving with a **Live** badge and a real speed/ETA —
//     and a gold line running dead straight from the car to the destination across
//     blocks, a park and a highway. The route progress bar is absent in all four,
//     which is the "weird gap" the second one names.
//   * MYR-456, two submissions 60s apart on one trip: *"Gold eta line
//     disappeared"* then *"Gold eta line now back, seems every time route updates
//     it goes and comes."*
//
// **THE DISCIPLINE GATE.** Both were reported BEFORE MYR-449 merged, so the first
// question is whether they still reproduce. They do, and MYR-449 cannot have
// touched them: `LiveVehicleState(seedsStateFromDeltas:)` defaults to `false` and
// the OWNER fleet constructs it without the flag, so the owner path is
// byte-identical across that fix by construction. Everything below is the owner
// path.
//
// **WHAT THE PRE-FIX CODE DID**, in three lines that nothing tested together:
//
//   1. `drivingTrip` answered an absent/short `navRouteCoordinates` with
//      `[currentPosition, destination]`, and `VehicleMapView` stroked it with no
//      `isReal` gate — MYR-457's straight line.
//   2. `tripProgress` measured `tripDistanceRemaining` against that same absent
//      route, so it answered **0** — and `DrivingHeroElement.resolve` gates the
//      bar on `progress > 0`. MYR-457's missing bar, from the same absence.
//   3. Nothing held the previous route or the previous progress, so any frame
//      catching the nav atomic group mid-update dropped both at once — MYR-456.
//      The contract makes that an ORDINARY frame, not a rare one: the group's
//      members "may legitimately arrive apart" inside the server's 500ms
//      accumulation window, and NFR-3.9 amplifies any single null across the
//      whole group.
//
// The MYR-456 reading is pinned by his own screenshot: in the BROKEN frame the
// destination, "Arriving in 23 min" and the ETA are all still rendered. So
// navigation was active and `etaMinutes > 0` — and `progress > 0` is then the
// only gate left that can have removed the bar.
@MainActor
final class OwnerDrivingRouteTests: XCTestCase {

    // MARK: Geometry fixtures

    private static let car = CLLocationCoordinate2D(latitude: 33.1120, longitude: -96.8060)
    private static let destination = CLLocationCoordinate2D(latitude: 33.0980, longitude: -96.8240)

    /// A road route: more than two points, so `RideRoutePolyline.isReal` accepts it.
    private static func roadRoute(_ count: Int = 6) -> [CLLocationCoordinate2D] {
        (0..<count).map { i in
            let t = Double(i) / Double(count - 1)
            return CLLocationCoordinate2D(
                latitude: car.latitude + (destination.latitude - car.latitude) * t,
                longitude: car.longitude + (destination.longitude - car.longitude) * t
            )
        }
    }

    /// **The exact shape the defect drew**, and the one MYR-237/MYR-293 named as
    /// never a route.
    private static var straightPair: [CLLocationCoordinate2D] { [car, destination] }

    // MARK: - MYR-457 · the straight line

    /// **THE HEADLINE FOR MYR-457.** A car navigating with no decoded `RouteLine`
    /// must not produce a two-point line, whatever else it produces.
    ///
    /// Asserted through the SHIPPING mapping rather than through the resolver,
    /// because the invention lived in the mapping: pre-fix this returns
    /// `[currentPosition, destination]` and the assertion fails on `route.count`.
    func testANavigatingCarWithNoWireRouteNeverProducesATwoPointRoute() {
        let trip = VehicleContractMapping.drivingTrip(from: Self.state(wireRoute: nil))

        XCTAssertTrue(trip.navigation.isActive, "precondition: this car IS navigating")
        XCTAssertFalse(
            RideRoutePolyline.isReal(trip.route),
            "no wire route means no route — never a straight [car, destination] pair"
        )
        XCTAssertTrue(trip.route.isEmpty, "and the invented geometry is gone entirely, not merely refused")
    }

    /// The two facts the invented pair existed to carry now travel on their own,
    /// which is what makes removing it safe: the marker still has a position and
    /// the destination still has a dot.
    func testTheCarAndDestinationSurviveAsFactsRatherThanAsRouteEndpoints() {
        let trip = VehicleContractMapping.drivingTrip(from: Self.state(wireRoute: nil))

        XCTAssertEqual(trip.carCoordinate?.latitude ?? 0, Self.car.latitude, accuracy: 1e-9)
        XCTAssertEqual(trip.destinationCoordinate?.latitude ?? 0, Self.destination.latitude, accuracy: 1e-9)
    }

    /// A car with a REAL wire route is untouched — the whole point of the gate is
    /// that the healthy trip is unchanged.
    func testARealWireRouteIsCarriedThroughVerbatim() {
        let route = Self.roadRoute()
        let trip = VehicleContractMapping.drivingTrip(from: Self.state(wireRoute: route))

        XCTAssertEqual(trip.route.count, route.count)
        let resolution = OwnerDrivingRoute.resolve(
            navigationActive: true, wireRoute: trip.route, fetchedRoute: [],
            remainingMiles: 2.0, reportedProgress: 0, held: nil
        )
        XCTAssertEqual(resolution.source, .wire)
    }

    /// **THE HONEST FALLBACK** (MYR-422's client direction: *"we should default the
    /// app map route preview if we can't get the route polyline from Tesla"*).
    /// With no wire route, the app's own MKDirections road route is drawn — so the
    /// owner gets a real path rather than either a lie or a blank map.
    func testWithNoWireRouteTheAppsOwnRoadRouteIsDrawn() {
        let fetched = Self.roadRoute()
        let resolution = OwnerDrivingRoute.resolve(
            navigationActive: true, wireRoute: [], fetchedRoute: fetched,
            remainingMiles: nil, reportedProgress: 0, held: nil
        )

        XCTAssertEqual(resolution.source, .fetched)
        XCTAssertTrue(resolution.drawsLine)
        XCTAssertEqual(resolution.line.count, fetched.count)
    }

    /// And the fallback is refused when IT is the provider's straight degradation.
    /// One predicate, both rungs — `RideRoutePolyline.isReal` — so a throttled
    /// MKDirections cannot reintroduce the very shape this issue removes.
    func testAStraightFallbackFromTheProviderIsRefusedToo() {
        let resolution = OwnerDrivingRoute.resolve(
            navigationActive: true, wireRoute: [], fetchedRoute: Self.straightPair,
            remainingMiles: 3.0, reportedProgress: 0, held: nil
        )

        XCTAssertEqual(resolution.source, .none)
        XCTAssertFalse(resolution.drawsLine)
    }

    /// **THE MISSING BAR, and that it comes back.** MYR-457's second symptom is
    /// the same absence as its first, so the fetched route fixes both: progress is
    /// measured against the polyline actually drawn, and `DrivingHeroElement`
    /// admits the bar again.
    func testTheProgressBarReturnsWithTheFetchedRoute() {
        let fetched = Self.roadRoute()
        let total = VehicleRoute.totalDistanceMiles(along: fetched)

        // Pre-fix: no wire route → total 0 → progress 0 → no bar, whatever the
        // wire's distance said.
        XCTAssertEqual(
            VehicleContractMapping.tripProgress(from: Self.state(wireRoute: nil, remaining: total / 2)), 0,
            accuracy: 1e-9,
            "the wire-only derivation still answers 0 — which is why the screen re-measures"
        )

        let resolution = OwnerDrivingRoute.resolve(
            navigationActive: true, wireRoute: [], fetchedRoute: fetched,
            remainingMiles: total / 2, reportedProgress: 0, held: nil
        )
        XCTAssertEqual(resolution.progress, 0.5, accuracy: 0.01)

        let elements = DrivingHeroElement.resolve(
            navigation: .destination(name: "Home", city: nil, address: nil),
            etaMinutes: 24,
            progress: resolution.progress
        )
        XCTAssertTrue(elements.contains(.progressBar), "a measured half-way trip draws its bar")
    }

    // MARK: - MYR-456 · the vanishing line and bar

    /// **THE HEADLINE FOR MYR-456.** A frame that lands mid-update — navigation
    /// still on, geometry momentarily absent — keeps the route the journey already
    /// had. The line does not "go and come".
    func testARouteUpdateInFlightHoldsTheRouteItAlreadyHad() {
        let settled = OwnerDrivingRoute.resolve(
            navigationActive: true, wireRoute: Self.roadRoute(), fetchedRoute: [],
            remainingMiles: 1.0, reportedProgress: 0, held: nil
        )
        XCTAssertEqual(settled.source, .wire)

        // The update lands: NFR-3.9 amplified one null across the nav group, so
        // this frame carries no geometry and no distance at all.
        let midUpdate = OwnerDrivingRoute.resolve(
            navigationActive: true, wireRoute: [], fetchedRoute: [],
            remainingMiles: nil, reportedProgress: 0, held: settled
        )

        XCTAssertEqual(midUpdate.source, .held)
        XCTAssertTrue(midUpdate.drawsLine, "the gold line must not disappear on an update")
        XCTAssertEqual(midUpdate.line.count, settled.line.count)
    }

    /// The BAR is the other half of the same frame, and it is held by the same
    /// rule — for the reason `nil` and `0` are different answers.
    func testAFrameWithNoDistanceHoldsTheProgressRatherThanReadingZero() {
        let route = Self.roadRoute()
        let total = VehicleRoute.totalDistanceMiles(along: route)
        let settled = OwnerDrivingRoute.resolve(
            navigationActive: true, wireRoute: route, fetchedRoute: [],
            remainingMiles: total * 0.25, reportedProgress: 0, held: nil
        )
        XCTAssertEqual(settled.progress, 0.75, accuracy: 0.01)

        // Same route, and this frame simply did not carry `tripDistanceRemaining`.
        let quiet = OwnerDrivingRoute.resolve(
            navigationActive: true, wireRoute: route, fetchedRoute: [],
            remainingMiles: nil, reportedProgress: 0, held: settled
        )

        XCTAssertEqual(quiet.progress, 0.75, accuracy: 0.01)
        XCTAssertTrue(
            DrivingHeroElement.resolve(
                navigation: .destination(name: "Home", city: nil, address: nil),
                etaMinutes: 23, progress: quiet.progress
            ).contains(.progressBar),
            "the reported frame: destination and ETA on screen, and the bar must stay with them"
        )
    }

    /// **A MEASURED ZERO IS NOT A MISSING ONE**, and the hold must not paper over
    /// it. A trip that has genuinely not started reads 0 and draws no bar — which
    /// is `TripProgressBar`'s own 0.05 clamp being respected (MYR-294), not a
    /// regression of this fix.
    func testAGenuineTripStartStillReadsZeroAndStillDrawsNoBar() {
        let route = Self.roadRoute()
        let total = VehicleRoute.totalDistanceMiles(along: route)
        let held = OwnerDrivingRoute.resolve(
            navigationActive: true, wireRoute: route, fetchedRoute: [],
            remainingMiles: total * 0.5, reportedProgress: 0, held: nil
        )

        let atStart = OwnerDrivingRoute.resolve(
            navigationActive: true, wireRoute: route, fetchedRoute: [],
            remainingMiles: total, reportedProgress: 0, held: held
        )

        XCTAssertEqual(atStart.progress, 0, accuracy: 1e-9, "measured, and the answer is zero")
        XCTAssertFalse(
            DrivingHeroElement.resolve(
                navigation: .destination(name: "Home", city: nil, address: nil),
                etaMinutes: 24, progress: atStart.progress
            ).contains(.progressBar)
        )
    }

    /// **NAVIGATION ENDING DROPS EVERYTHING.** A held route outliving its journey
    /// is MYR-381's stale etch, so the hold is not a cache — it is a bridge across
    /// one update.
    func testNavigationEndingDropsTheHeldRoute() {
        let held = OwnerDrivingRoute.resolve(
            navigationActive: true, wireRoute: Self.roadRoute(), fetchedRoute: [],
            remainingMiles: 1.0, reportedProgress: 0, held: nil
        )

        let ended = OwnerDrivingRoute.resolve(
            navigationActive: false, wireRoute: [], fetchedRoute: [],
            remainingMiles: nil, reportedProgress: 0, held: held
        )

        XCTAssertEqual(ended, .none)
        XCTAssertFalse(ended.drawsLine)
    }

    /// A NEW journey never inherits the previous one's line. The hold is keyed on
    /// the destination by its owner (`OwnerHomeState`), because identity is a fact
    /// about the trip rather than about the geometry — the geometry is the thing
    /// that legitimately changes on the update being survived.
    func testTheHoldIsForgottenWhenTheDestinationChanges() {
        let state = OwnerHomeState()
        let resolution = OwnerDrivingRoute.resolve(
            navigationActive: true, wireRoute: Self.roadRoute(), fetchedRoute: [],
            remainingMiles: 1.0, reportedProgress: 0, held: nil
        )

        state.recordDrivingRoute(resolution, destinationKey: "A")
        XCTAssertEqual(state.drivingRouteHold?.destinationKey, "A")

        // A different destination: the previous journey's route is not evidence
        // about this one.
        state.recordDrivingRoute(.none, destinationKey: "B")
        XCTAssertNil(state.drivingRouteHold, "a new journey starts with no held line")
    }

    /// A HELD resolution is never re-recorded as the hold: it is not new evidence,
    /// and re-recording it would let a route survive indefinitely by being held
    /// once. The hold always traces back to a frame that really carried geometry.
    func testAHeldResolutionIsNotItselfRecorded() {
        let state = OwnerHomeState()
        let real = OwnerDrivingRoute.resolve(
            navigationActive: true, wireRoute: Self.roadRoute(), fetchedRoute: [],
            remainingMiles: 1.0, reportedProgress: 0, held: nil
        )
        state.recordDrivingRoute(real, destinationKey: "A")

        let held = OwnerDrivingRoute.resolve(
            navigationActive: true, wireRoute: [], fetchedRoute: [],
            remainingMiles: nil, reportedProgress: 0, held: real
        )
        XCTAssertEqual(held.source, .held)

        state.recordDrivingRoute(held, destinationKey: "A")
        XCTAssertEqual(state.drivingRouteHold?.resolution.source, .wire,
                       "the hold still names the frame that really carried the route")
    }

    // MARK: - The screen consults it

    /// The hero's progress is the RESOLVED one, so the bar and the polyline are
    /// two readings of one value rather than two derivations of one journey.
    func testTheScreenMeasuresProgressAgainstTheRouteItDrew() {
        let fetched = Self.roadRoute()
        let total = VehicleRoute.totalDistanceMiles(along: fetched)
        let resolution = OwnerDrivingRoute.resolve(
            navigationActive: true, wireRoute: [], fetchedRoute: fetched,
            remainingMiles: total * 0.4, reportedProgress: 0, held: nil
        )

        // `progress` off the wire-only derivation is 0 — there is no wire route.
        let raw = VehicleContractMapping.snapshot(from: Self.state(wireRoute: nil, remaining: total * 0.4))
        XCTAssertEqual(raw.progress, 0, accuracy: 1e-9)

        let resolved = HomeScreen.snapshot(
            raw,
            measuredAgainst: resolution,
            activity: .driving(VehicleContractMapping.drivingTrip(from: Self.state(wireRoute: nil)))
        )
        XCTAssertEqual(resolved.progress, 0.6, accuracy: 0.01)
    }

    /// A PARKED car is untouched by any of this — it has no journey to be part-way
    /// through, and every simulated capture is a parked or fixture-route hero.
    func testAParkedSnapshotIsNeverRewritten() {
        let raw = VehicleTelemetrySnapshot(status: .parked, progress: 0, speedMPH: 0, batteryPercent: 55, etaMinutes: 0)
        let resolved = HomeScreen.snapshot(
            raw,
            measuredAgainst: OwnerDrivingRoute.Resolution(line: Self.roadRoute(), progress: 0.9, source: .wire),
            activity: .parked(ParkedLocation(label: "Home", coordinate: Self.car, parkedSince: nil))
        )
        XCTAssertEqual(resolved.progress, 0)
    }

    /// The wire carries the DISTANCE now, and its nil travels rather than
    /// collapsing to 0 — the distinction the hold rests on (the MYR-362 lesson:
    /// an optional that silently becomes a plausible value is the hardest kind of
    /// wrong).
    func testTheSnapshotCarriesTheDistanceIncludingItsNil() {
        XCTAssertEqual(
            VehicleContractMapping.snapshot(from: Self.state(wireRoute: nil, remaining: 4.25)).tripDistanceRemainingMiles,
            4.25
        )
        XCTAssertNil(
            VehicleContractMapping.snapshot(from: Self.state(wireRoute: nil, remaining: nil)).tripDistanceRemainingMiles
        )
    }


    // MARK: - The simulated path is untouched

    /// **THE REGRESSION THIS BRANCH ACTUALLY SHIPPED FOR ONE ROUND, and only the
    /// simulator showed it.**
    ///
    /// `SimulatedVehicleTelemetrySource` owns its fraction directly and carries no
    /// `tripDistanceRemaining`, so a resolver that re-derived progress
    /// unconditionally answered 0 for every fixture trip — and `ownerHome`'s peek
    /// hero lost its `TripProgressBar`. The full unit suite was green straight
    /// through it, because nothing asserted that the fixture hero keeps its own
    /// number. This is that assertion.
    func testTheSimulatedTickersProgressSurvivesUntouched() {
        let route = Self.roadRoute()
        let resolution = OwnerDrivingRoute.resolve(
            navigationActive: true, wireRoute: route, fetchedRoute: [],
            remainingMiles: nil,            // the simulated path never reports one
            reportedProgress: 0.42,         // `VehicleFixtures`' own starting fraction
            held: nil
        )

        XCTAssertEqual(resolution.progress, 0.42, accuracy: 1e-9,
                       "a caller that already knows the fraction is not improved by a guess")
        XCTAssertTrue(
            DrivingHeroElement.resolve(
                navigation: .destination(name: "Duarte's Tavern", city: "Pescadero", address: nil),
                etaMinutes: 43, progress: resolution.progress
            ).contains(.progressBar),
            "every simulated owner capture keeps its progress bar"
        )
    }

    /// And the ticker keeps ADVANCING — the hold must never freeze a source that
    /// reports its own progress.
    func testAReportingSourceIsNeverFrozenByTheHold() {
        let route = Self.roadRoute()
        let first = OwnerDrivingRoute.resolve(
            navigationActive: true, wireRoute: route, fetchedRoute: [],
            remainingMiles: nil, reportedProgress: 0.42, held: nil
        )
        let later = OwnerDrivingRoute.resolve(
            navigationActive: true, wireRoute: route, fetchedRoute: [],
            remainingMiles: nil, reportedProgress: 0.55, held: first
        )

        XCTAssertEqual(later.progress, 0.55, accuracy: 1e-9)
    }

    // MARK: Wire fixture

    /// A DRIVING car navigating to a known destination. `wireRoute` nil is the
    /// reported condition — Tesla has decoded no `RouteLine` — and everything else
    /// on the nav group is present, which is what keeps `navigation.isActive` true
    /// and the destination + ETA on screen exactly as his screenshots show.
    private static func state(
        wireRoute: [CLLocationCoordinate2D]?,
        remaining: Double? = 5.0
    ) -> VehicleState {
        var state = VehicleStateBaseline.forDeltaSeed(vehicleId: "owner-1")
        state.status = .driving
        state.latitude = car.latitude
        state.longitude = car.longitude
        state.speed = 24
        state.chargeLevel = 71
        state.destinationName = "7300 Windrose Ave."
        state.destinationLatitude = destination.latitude
        state.destinationLongitude = destination.longitude
        state.etaMinutes = 23
        state.tripDistanceRemaining = remaining
        state.navRouteCoordinates = wireRoute.map { $0.map { [$0.longitude, $0.latitude] } }
        return state
    }
}
