import CoreLocation
import DesignSystem
@testable import MyRoboTaxi
import MyRoboTaxiKit
import MyRobotaxiContracts
import XCTest

// MARK: - MYR-482 / MYR-483 — the rider's in-ride map draws the road ahead, and
// stops drawing the road behind
//
// **THE REPORT** (AKDNLlnM / AFzN_NtS, Thomas Nandola riding his own car in rider
// mode, build `202608081012`): no route line to the destination for the whole
// trip, plus an L-shaped gold fragment left by the pickup pin after boarding. The
// telemetry was healthy — the gold capsule moved along Town & Country Blvd with the
// car between frames — and the car's own dash was actively navigating to 5330
// Parkwood Blvd. So the stream was fine, the honesty gate was fine, and the map was
// still empty.
//
// **WHAT WAS SUPPOSED TO FEED THAT LINE, AND WHY IT COULD NOT.** The rider's
// in-ride polyline was `RideRouteStore.leg2` — one MKDirections **pickup →
// drop-off** preview, fetched from `reconcileTrackingRoutes()`, whose only live
// triggers are the tracking-phase entry and `onChange(of: trackProgress)` (which on
// the live path moves only at status transitions). So:
//
//   * **THERE WAS NO WIRE RUNG AT ALL.** `navRouteCoordinates` has been on the
//     wire, folded by `VehicleStateMerger`, and inside the MYR-435 viewer mask the
//     whole time; the tracking map has simply never read it. MYR-460's heading hop,
//     one field over.
//   * **AND NO RETRY.** MYR-459 gave leg 1 a live deviation trigger; leg 2 got
//     none. A single throttled/failed MKDirections call at the enroute transition
//     therefore cached the straight `[pickup, drop-off]` fallback, `isReal` refused
//     to stroke it — correctly — and nothing on the live path ever asked again.
//     That is "no line, all trip", exactly.
//   * **AND IT WAS THE WRONG LINE ANYWAY.** pickup → drop-off is the trip as
//     planned before the car moved; a rider aboard needs the road from where the
//     car IS.
//
// The fix reuses `OwnerDrivingRoute.resolve` — the ladder MYR-456/457 built for the
// owner's driving map, whose `.fetched` rung answers the client's own instruction
// (*"we should default the app map route preview if we can't get the route polyline
// from Tesla"*) — rather than growing a second one. These tests are about the rider
// half: the missing wire hop, the rungs in order, the live re-ask, the retirement of
// the approach leg, and MYR-483's own blue dot.
@MainActor
final class RiderInRideRouteTests: XCTestCase {

    private static let pickup = CLLocationCoordinate2D(latitude: 33.0790, longitude: -96.8100)
    private static let destination = CLLocationCoordinate2D(latitude: 33.0930, longitude: -96.8300)
    private static let carAboard = CLLocationCoordinate2D(latitude: 33.0830, longitude: -96.8160)
    /// ~700m on — past `MRTMetrics.rideRouteDeviationThresholdMeters` and past the
    /// ~11m ask quantization.
    private static let carMovedOn = CLLocationCoordinate2D(latitude: 33.0880, longitude: -96.8210)

    // MARK: - The missing hop: Tesla's own route reaches the rider

    /// **THE HEADLINE FOR THE WIRE RUNG.** The car was navigating; the app held its
    /// route and never looked at it.
    func testTheWireNavRouteIsReadableFromTheRidersProjection() {
        let route = RiderVehicleProjection.navRoute(from: Self.state(navRoute: Self.wireRoute()))

        XCTAssertEqual(route.count, 6)
        // Guarded so a restored defect FAILS rather than traps — an index crash
        // takes the rest of the suite's process with it and reports nothing useful.
        guard route.count == 6 else { return }
        XCTAssertEqual(route[0].latitude, Self.carAboard.latitude, accuracy: 1e-9)
        XCTAssertEqual(route[0].longitude, Self.carAboard.longitude, accuracy: 1e-9,
                       "GeoJSON is [lon, lat] — a swapped pair puts the car in the Indian Ocean")
    }

    /// MYR-293's predicate is applied AT THE SOURCE, so a 2-point "route" can never
    /// reach a consumer that might draw it — and, just as importantly, so the next
    /// rung of the ladder stays reachable.
    func testATwoPointWireRouteIsRefusedAtTheSourceRatherThanByEachConsumer() {
        let route = RiderVehicleProjection.navRoute(
            from: Self.state(navRoute: [Self.carAboard, Self.destination])
        )
        XCTAssertTrue(route.isEmpty)
    }

    /// No frame, no route. (`nil` is the pre-first-frame state of every live ride.)
    func testNoStateMeansNoWireRoute() {
        XCTAssertTrue(RiderVehicleProjection.navRoute(from: nil).isEmpty)
    }

    /// The wire route is NOT gated on `hasFix`: the nav group and the gps group are
    /// different atomic groups, and geometry Tesla decoded is geometry.
    func testTheWireRouteSurvivesAFrameThatCarriedNoPosition() {
        var state = Self.state(navRoute: Self.wireRoute())
        state.latitude = 0
        state.longitude = 0

        XCTAssertNil(RiderVehicleProjection.coordinate(from: state), "precondition: §2.3 no-fix sentinel")
        XCTAssertEqual(RiderVehicleProjection.navRoute(from: state).count, 6)
    }

    // MARK: - The ladder, in order

    /// Tesla's route wins when Tesla has one, and the app spends no MKDirections
    /// call at all.
    func testTheWireRouteOutranksTheAppsOwn() {
        let resolution = Self.resolve(wire: Self.wireRoute(), fetched: Self.fetchedRoute())

        XCTAssertEqual(resolution.source, .wire)
        XCTAssertTrue(resolution.drawsLine)
    }

    /// **THE CLIENT'S OWN INSTRUCTION, ON THE RIDER'S SURFACE.** With no wire route
    /// the app's road route is drawn — a real road route car → drop-off, not the
    /// pre-ride pickup → drop-off preview.
    func testTheAppRoadRouteAnswersWhenTeslaHasNoRouteLine() {
        let resolution = Self.resolve(wire: [], fetched: Self.fetchedRoute())

        XCTAssertEqual(resolution.source, .fetched)
        XCTAssertEqual(resolution.line.count, Self.fetchedRoute().count)
    }

    /// A nav-group update in flight blanks nothing: the last route this journey
    /// really had stays drawn (MYR-456's rule, inherited whole).
    func testANavLessFrameHoldsTheRouteTheJourneyAlreadyHad() {
        let first = Self.resolve(wire: Self.wireRoute(), fetched: [])
        let next = Self.resolve(wire: [], fetched: [], held: first)

        XCTAssertEqual(next.source, .held)
        XCTAssertEqual(next.line.count, first.line.count)
    }

    /// **HONEST EMPTY ONLY WHEN GENUINELY UNROUTABLE.** Nothing on the wire, nothing
    /// fetched, nothing held — and no invented segment.
    func testGenuinelyUnroutableDrawsNothing() {
        let resolution = Self.resolve(wire: [], fetched: [])

        XCTAssertEqual(resolution.source, .none)
        XCTAssertFalse(resolution.drawsLine)
        XCTAssertTrue(resolution.line.isEmpty)
    }

    /// The straight degradation is refused on BOTH rungs, by the one predicate — a
    /// throttled MKDirections must never become a gold diagonal across the city.
    func testTheStraightFallbackIsRefusedOnBothRungs() {
        let straight = [Self.carAboard, Self.destination]

        XCTAssertEqual(Self.resolve(wire: straight, fetched: []).source, .none)
        XCTAssertEqual(Self.resolve(wire: [], fetched: straight).source, .none)
        XCTAssertFalse(TrackingRouteMapContent.drawsLine(straight))
    }

    // MARK: - What the map strokes

    /// The in-ride route REPLACES the pickup → drop-off preview when it has
    /// resolved, and falls back to it when it has not — which is the pre-MYR-482
    /// rendering and what every simulated scene keeps.
    func testTheActiveStrokeIsTheCarToDropOffRouteWhenThereIsOne() {
        let leg2 = Self.leg2Route()
        let inRide = Self.fetchedRoute()

        let aboard = TrackingRouteMapContent.activeRoute(
            leg: .inRide, leg1Route: Self.leg1Route(), leg2Route: leg2, inRideRoute: inRide
        )
        XCTAssertEqual(aboard.count, inRide.count)
        guard let head = aboard.first else { return XCTFail("the in-ride stroke is empty") }
        XCTAssertEqual(head.latitude, Self.carAboard.latitude, accuracy: 1e-9,
                       "the line starts at the car, not at a kerb the rider has left")

        let unresolved = TrackingRouteMapContent.activeRoute(
            leg: .inRide, leg1Route: Self.leg1Route(), leg2Route: leg2, inRideRoute: []
        )
        XCTAssertEqual(unresolved.count, leg2.count)
    }

    /// Leg 1 is untouched by all of this.
    func testTheApproachLegStillStrokesItsOwnRouteBeforeBoarding() {
        let leg1 = Self.leg1Route()
        let active = TrackingRouteMapContent.activeRoute(
            leg: .toPickup, leg1Route: leg1, leg2Route: Self.leg2Route(), inRideRoute: Self.fetchedRoute()
        )
        XCTAssertEqual(active.count, leg1.count)
    }

    // MARK: - The lingering approach leg

    /// **THE HEADLINE FOR THE SECOND HALF OF THE REPORT.** The car → pickup route is
    /// history the moment the rider is aboard, and before this it was drawn dimmed
    /// for the whole trip: `reconcileTrackingRoutes` stops FETCHING leg 1 on the
    /// flip, which is not the same thing as stopping DRAWING it.
    func testTheApproachLegIsRetiredOnceTheRiderIsAboard() {
        let leg1 = Self.leg1Route()

        XCTAssertEqual(TrackingRouteMapContent.drawnLeg1(leg1, leg: .toPickup).count, leg1.count,
                       "heading to pickup, it is the active leg")
        XCTAssertTrue(TrackingRouteMapContent.drawnLeg1(leg1, leg: .inRide).isEmpty,
                      "aboard, it is a road the ride has already driven")
    }

    /// **PINS UNCONDITIONALLY** (MYR-293), so retiring the LINE must not move the
    /// pickup pin onto the car. It comes off leg 2, which is still the ride's own
    /// pickup → drop-off pair.
    func testRetiringTheApproachLegDoesNotMoveThePickupPin() {
        let pin = TrackingRouteMapContent.pickup(
            leg1Route: TrackingRouteMapContent.drawnLeg1(Self.leg1Route(), leg: .inRide),
            leg2Route: Self.leg2Route(),
            carCoordinate: Self.carAboard
        )

        XCTAssertEqual(pin.latitude, Self.pickup.latitude, accuracy: 1e-9)
        XCTAssertEqual(pin.longitude, Self.pickup.longitude, accuracy: 1e-9)
    }

    // MARK: - The hold's lifetime

    /// A hold is about ONE journey. A resolution that is itself `.held` never
    /// re-records (that would let a hold outlive its own evidence indefinitely), and
    /// a new drop-off forgets the old line.
    func testTheHoldIsRecordedOncePerJourneyAndForgottenWithIt() {
        let state = Self.viewerState(locator: nil)
        let fetched = Self.resolve(wire: [], fetched: Self.fetchedRoute())

        state.recordTrackingRoute(fetched, destinationKey: "A")
        XCTAssertEqual(state.trackingRouteHold?.destinationKey, "A")

        state.recordTrackingRoute(Self.resolve(wire: [], fetched: [], held: fetched), destinationKey: "A")
        XCTAssertEqual(state.trackingRouteHold?.resolution.source, .fetched,
                       "a held resolution is not new evidence")

        state.recordTrackingRoute(.none, destinationKey: "B")
        XCTAssertNil(state.trackingRouteHold, "a different drop-off is a different journey")
    }

    /// Every route cached for the ride goes through ONE door, and the hold goes with
    /// them — MYR-389's lesson pointed at a lifecycle that just grew a second store.
    func testReleasingTheRidesRoutesForgetsTheHoldToo() {
        let state = Self.viewerState(locator: nil)
        state.recordTrackingRoute(Self.resolve(wire: [], fetched: Self.fetchedRoute()), destinationKey: "A")

        state.resetRideRoutes()

        XCTAssertNil(state.trackingRouteHold)
        XCTAssertNil(state.trackingDestinationRouteStore.leg1Route(pickup: Self.destination))
    }

    // MARK: - The live trigger (the REAL composition, MYR-449's harness)

    /// **THE HEADLINE FOR "REFRESHED ON DEVIATION".** A viewer frame arrives off a
    /// scripted socket with the cold snapshot refused `403` exactly as the server
    /// refuses it, and the car → drop-off cache is asked — then asked again when the
    /// car has moved. Pre-fix the count is **0 forever**: leg 2 had no live trigger
    /// at all, which is why one throttled fetch was permanent for the trip.
    func testAnInRideFrameAsksForTheCarToDropOffRouteAndReAsksAsTheCarMoves() async {
        let row = Self.sharedRow()
        let channels = AuthenticatingChannelFactory()
        let state = Self.viewerState(locator: Self.locator(channels: channels, rows: [row]))

        Self.adopt([row], into: state)
        state.startTelemetry()
        state.sheetPhase = .tracking
        await eventuallyAsync { await Self.subscribed(channels, to: row.vehicleId) }

        // What `reconcileTrackingRoutes()` publishes for a rider ABOARD.
        state.setTrackingRouteContext(.init(
            pickup: Self.pickup, destination: Self.destination,
            fetchesLeg1: false, fetchesCarToDestination: true
        ))
        XCTAssertEqual(state.trackingDestinationRouteAsks, 0, "precondition: nothing asked yet")

        await Self.push(channels, vehicleId: row.vehicleId, at: Self.carAboard)
        await eventually { state.trackingDestinationRouteAsks == 1 }

        await Self.push(channels, vehicleId: row.vehicleId, at: Self.carMovedOn,
                        lastUpdated: "2026-08-08T16:34:00Z")
        await eventually { state.trackingDestinationRouteAsks == 2 }

        XCTAssertEqual(state.trackingRouteLiveReasks, 2)
        state.stopTelemetry()
    }

    /// **A CAR WITH ITS OWN NAV ROUTE COSTS NOTHING**, which is what keeps this off
    /// Apple's per-device throttle for the whole of every healthy trip
    /// (`reconcileDrivingRoute`'s guard on the owner's side, verbatim).
    func testACarCarryingItsOwnRouteSpendsNoMKDirectionsCall() async {
        let row = Self.sharedRow()
        let channels = AuthenticatingChannelFactory()
        let state = Self.viewerState(locator: Self.locator(channels: channels, rows: [row]))

        Self.adopt([row], into: state)
        state.startTelemetry()
        state.sheetPhase = .tracking
        await eventuallyAsync { await Self.subscribed(channels, to: row.vehicleId) }
        state.setTrackingRouteContext(.init(
            pickup: Self.pickup, destination: Self.destination,
            fetchesLeg1: false, fetchesCarToDestination: true
        ))

        await Self.push(channels, vehicleId: row.vehicleId, at: Self.carAboard, navRoute: Self.wireRoute())
        await eventually { !state.trackingWireRoute.isEmpty }
        await Self.push(channels, vehicleId: row.vehicleId, at: Self.carMovedOn,
                        navRoute: Self.wireRoute(), lastUpdated: "2026-08-08T16:34:00Z")
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertGreaterThan(state.trackingRouteLiveReasks, 0, "the frames DID reach the trigger")
        XCTAssertEqual(state.trackingDestinationRouteAsks, 0,
                       "Tesla already answered the question the fetch would ask")
        state.stopTelemetry()
    }

    /// A rider still heading to pickup asks for no in-ride route — the context flag
    /// defaults to `false`, so every pre-MYR-482 construction keeps the old
    /// behaviour by construction.
    func testAPickupLegContextNeverAsksForTheInRideRoute() async {
        let row = Self.sharedRow()
        let channels = AuthenticatingChannelFactory()
        let state = Self.viewerState(locator: Self.locator(channels: channels, rows: [row]))

        Self.adopt([row], into: state)
        state.startTelemetry()
        state.sheetPhase = .tracking
        await eventuallyAsync { await Self.subscribed(channels, to: row.vehicleId) }
        state.setTrackingRouteContext(.init(
            pickup: Self.pickup, destination: Self.destination, fetchesLeg1: true
        ))

        await Self.push(channels, vehicleId: row.vehicleId, at: Self.carAboard)
        await eventually { state.trackingRouteLiveReasks == 1 }

        XCTAssertEqual(state.trackingDestinationRouteAsks, 0)
        state.stopTelemetry()
    }

    /// **THE LEG FLIP HAPPENS WITH THE CAR STANDING STILL**, which is the one moment
    /// the ~11m fix-key de-dupe would swallow: the last leg-1 frame and the first
    /// in-ride frame carry the same key, because the car is at the kerb. Without the
    /// intent reset the new route would not be asked for until the car had driven a
    /// block — the exact window a rider is watching.
    func testTheLegFlipReAsksEvenThoughTheCarHasNotMoved() async {
        let row = Self.sharedRow()
        let channels = AuthenticatingChannelFactory()
        let state = Self.viewerState(locator: Self.locator(channels: channels, rows: [row]))

        Self.adopt([row], into: state)
        state.startTelemetry()
        state.sheetPhase = .tracking
        await eventuallyAsync { await Self.subscribed(channels, to: row.vehicleId) }

        // Heading to pickup, then the car arrives and stops.
        state.setTrackingRouteContext(.init(
            pickup: Self.pickup, destination: Self.destination, fetchesLeg1: true
        ))
        await Self.push(channels, vehicleId: row.vehicleId, at: Self.pickup)
        await eventually { state.trackingRouteLiveReasks == 1 }
        XCTAssertEqual(state.trackingDestinationRouteAsks, 0)

        // The rider taps Start ride: same kerb, different question.
        state.setTrackingRouteContext(.init(
            pickup: Self.pickup, destination: Self.destination,
            fetchesLeg1: false, fetchesCarToDestination: true
        ))
        await Self.push(channels, vehicleId: row.vehicleId, at: Self.pickup,
                        lastUpdated: "2026-08-08T16:34:30Z")
        await eventually { state.trackingDestinationRouteAsks == 1 }

        state.stopTelemetry()
    }

    // MARK: - MYR-483 · the rider's own blue dot

    /// **THE HEADLINE FOR MYR-483.** Aboard, the dot and the gold capsule are the
    /// same point and only one of them is informative.
    func testTheRidersOwnDotIsHiddenOnlyOnceTheyAreAboard() {
        XCTAssertTrue(RiderOwnLocationDot.shows(authorized: true, leg: .toPickup),
                      "before boarding, 'where am I relative to the kerb' is the rider's question")
        XCTAssertFalse(RiderOwnLocationDot.shows(authorized: true, leg: .inRide))
    }

    /// The rule can only ever take the dot AWAY. An unauthorized (or simulated)
    /// rider has no dot in either leg — which is what keeps every tracking capture
    /// byte-identical.
    func testTheRuleNeverGrantsADotNobodyAuthorized() {
        for leg in [TrackingLeg.toPickup, .inRide] {
            XCTAssertFalse(RiderOwnLocationDot.shows(authorized: false, leg: leg))
        }
    }

    // MARK: Fixtures

    private static func wireRoute() -> [CLLocationCoordinate2D] { path(from: carAboard, to: destination) }
    private static func fetchedRoute() -> [CLLocationCoordinate2D] { path(from: carAboard, to: destination) }
    private static func leg1Route() -> [CLLocationCoordinate2D] {
        path(from: CLLocationCoordinate2D(latitude: 33.0700, longitude: -96.7990), to: pickup)
    }
    private static func leg2Route() -> [CLLocationCoordinate2D] { path(from: pickup, to: destination, count: 8) }

    private static func path(
        from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, count: Int = 6
    ) -> [CLLocationCoordinate2D] {
        (0..<count).map { i in
            let t = Double(i) / Double(count - 1)
            return CLLocationCoordinate2D(
                latitude: from.latitude + (to.latitude - from.latitude) * t,
                longitude: from.longitude + (to.longitude - from.longitude) * t
            )
        }
    }

    /// The screen's own call, with the two parameters this surface pins: the journey
    /// is the RIDE (so navigation is active regardless of the dash), and progress
    /// comes from `trackingLegProgress` rather than from this ladder.
    private static func resolve(
        wire: [CLLocationCoordinate2D],
        fetched: [CLLocationCoordinate2D],
        held: OwnerDrivingRoute.Resolution? = nil
    ) -> OwnerDrivingRoute.Resolution {
        OwnerDrivingRoute.resolve(
            navigationActive: true,
            wireRoute: RideRoutePolyline.isReal(wire) ? wire : [],
            fetchedRoute: fetched,
            remainingMiles: nil,
            reportedProgress: 0,
            held: held
        )
    }

    private static func state(navRoute: [CLLocationCoordinate2D]) -> VehicleState {
        var state = Contracts.drivingState()
        state.latitude = carAboard.latitude
        state.longitude = carAboard.longitude
        state.navRouteCoordinates = navRoute.map { [$0.longitude, $0.latitude] }
        return state
    }

    // MARK: Composition helpers (the MYR-449 / MYR-459 engagement idiom)

    private nonisolated static func sharedRow(id: String = "shared-1") -> VehicleSummary {
        VehicleSummary(
            vehicleId: id, name: "Quicksilver Model Y", model: "Model Y", year: 2026,
            color: "Quicksilver", vinLast4: "5545", status: .driving,
            chargeLevel: 68, estimatedRange: 231,
            lastUpdated: "2026-08-08T16:33:00.000Z", role: .viewer,
            sharePermission: .rides
        )
    }

    private static func locator(channels: AuthenticatingChannelFactory, rows: [VehicleSummary]) -> RiderLiveVehicleLocator {
        let http = RoutedHTTP([
            .init("/snapshot", failFirst: 9_999, status: 403,
                  failureBody: Data(#"{"error":{"code":"forbidden","message":"viewer"}}"#.utf8),
                  body: Data()),
            .init("/vehicles", body: Contracts.listResponse(rows)),
        ])
        return RiderLiveVehicleLocator(config: .init(
            environment: .test,
            tokenProvider: StaticTokenProvider("test-token"),
            http: http,
            channelFactory: channels
        ))
    }

    private static func viewerState(locator: RiderLiveVehicleLocator?) -> SharedViewerState {
        let seams = PlaceSearchComposition.Seams(
            placeSearch: SimulatedPlaceSearch(),
            userLocation: InRideFakeLocation(),
            liveVehicleLocator: locator,
            pinLabeler: SimulatedPinLabeler(),
            isLive: true
        )
        return SharedViewerState(vehicle: nil, seams: seams)
    }

    private static func adopt(_ rows: [VehicleSummary], into state: SharedViewerState) {
        let resolution = RiderVehicleSet.resolve(
            hasLoaded: true, loadFailed: false,
            grants: LiveSharedVehicleCatalog.grants(from: rows),
            ownedVehicles: LiveSharedVehicleCatalog.ownedVehicles(from: rows)
        )
        if case .ridable(let adoption) = resolution { state.adopt(adoption) }
    }

    /// A viewer frame, optionally carrying the car's own decoded `RouteLine`. The
    /// nav route travels as the contract's `[[lon, lat]]`, through the SHIPPING
    /// `VehicleStateMerger` — a hand-set state would prove nothing about the fold.
    private static func push(
        _ channels: AuthenticatingChannelFactory,
        vehicleId: String,
        at coordinate: CLLocationCoordinate2D,
        navRoute: [CLLocationCoordinate2D] = [],
        lastUpdated: String = "2026-08-08T16:33:00Z"
    ) async {
        guard let channel = channels.madeChannels().last else { return }
        let nav = navRoute.isEmpty
            ? ""
            : ",\"navRouteCoordinates\":[" + navRoute.map { "[\($0.longitude),\($0.latitude)]" }.joined(separator: ",") + "]"
        await channel.emit("""
        {"type":"vehicle_update","payload":{"vehicleId":"\(vehicleId)","fields":{\
        "latitude":\(coordinate.latitude),"longitude":\(coordinate.longitude),"heading":212,\
        "speed":27,"status":"driving","lastUpdated":"\(lastUpdated)"\(nav)},\
        "timestamp":"\(lastUpdated)"}}
        """)
    }

    private static func subscribed(_ channels: AuthenticatingChannelFactory, to vehicleId: String) async -> Bool {
        for channel in channels.madeChannels() {
            let frames = await channel.sentFrames()
            if frames.contains(where: { $0.contains(#""type":"subscribe""#) && $0.contains(vehicleId) }) {
                return true
            }
        }
        return false
    }

    private func eventually(
        timeout: TimeInterval = 4.0,
        _ condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("condition never became true", file: file, line: line)
    }

    private func eventuallyAsync(
        timeout: TimeInterval = 4.0,
        _ condition: () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("async condition never became true", file: file, line: line)
    }
}

// MARK: - Test doubles

@Observable
@MainActor
private final class InRideFakeLocation: UserLocationProviding {
    var coordinate: CLLocationCoordinate2D?
    var currentLocationLabel: String { "Current location" }
    var showsUserLocationDot: Bool { coordinate != nil }
    func start() {}
    func stop() {}
    func refresh() {}
}
