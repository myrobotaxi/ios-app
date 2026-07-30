import CoreLocation
@testable import MyRoboTaxi
import MyRoboTaxiKit
import MyRobotaxiContracts
import Observation
import XCTest

// MARK: - MYR-336 — the rider's watched vehicle streams for real
//
// THE STATE THIS CLOSES. MYR-184 made the rider's Live Map adopt the REAL shared
// car and MYR-343 settled which one (owned first, else the first grant); the
// TELEMETRY behind it stayed MYR-191's fixture ticker plus a single
// `GET /snapshot` fired once per session. So a viewer watched the right car sit
// perfectly still — not fixture DATA, but fixture-shaped BEHAVIOUR, which is the
// same lie told more quietly, and the last one on the live path.
//
// Everything below drives the REAL composition — `RiderLiveVehicleLocator` →
// `TelemetrySocket` (authenticating channel + routed REST) → `LiveVehicleState`
// → `LiveVehicleTelemetrySource` → `VehicleContractMapping` /
// `RiderVehicleProjection` — with the wire injected and nothing downstream
// stubbed. A test that seeded a `VehicleState` into the state object would pass
// over exactly the composition this issue changes.
@MainActor
final class RiderLiveTelemetryTests: XCTestCase {

    // MARK: Wire fixtures

    /// The rider's own car (`role: owner`) — MYR-343's self-ride.
    private nonisolated static func ownedRow(id: String = "owned-1") -> VehicleSummary {
        VehicleSummary(
            vehicleId: id, name: "Lunar", model: "Model Y", year: 2026,
            color: "Quicksilver", vinLast4: "3795", status: .parked,
            chargeLevel: 71, estimatedRange: 244,
            lastUpdated: "2026-07-30T15:40:00.000Z", role: .owner
        )
    }

    /// A car shared with the rider (`role: viewer`, tier `rides`).
    private nonisolated static func sharedRow(id: String = "shared-1") -> VehicleSummary {
        VehicleSummary(
            vehicleId: id, name: "Alex\u{2019}s Model 3", model: "Model 3", year: 2024,
            color: "Pearl White", vinLast4: "9417", status: .parked,
            chargeLevel: 82, estimatedRange: 210,
            lastUpdated: "2026-07-30T15:40:00.000Z", role: .viewer,
            sharePermission: .rides
        )
    }

    /// A snapshot for `id` at `at`. `(0, 0)` is the contract's "no fix" sentinel
    /// (§2.3) and is used verbatim by the pre-fix test below.
    ///
    /// It deliberately carries the OWNER-ONLY identity fields too (VIN, software
    /// version, FSD designation, plate, trim label), which is what makes the
    /// viewer-mask assertion a real proof rather than a tautology: the values are
    /// present in the state and must still not reach the rider's `Vehicle`.
    private nonisolated static func snapshotState(
        id: String,
        at coordinate: CLLocationCoordinate2D,
        status: VehicleState.Status = .parked,
        locationName: String = "Embarcadero Center \u{00B7} Lot B"
    ) -> VehicleState {
        VehicleState(
            vehicleId: id, name: "Wire Name", model: "Model Y", year: 2026,
            color: "Wire Colour", vin: "7SAYGDET7TA613795",
            softwareVersion: "2026.20.6.6", trim: "p74d",
            status: status, speed: status == .driving ? 41 : 0, heading: 180,
            latitude: coordinate.latitude, longitude: coordinate.longitude,
            locationName: locationName,
            locationAddress: "1 Embarcadero Ctr, San Francisco",
            gearPosition: status == .driving ? .d : .p,
            chargeLevel: 71, chargeState: nil, estimatedRange: 244, timeToFull: nil,
            interiorTemp: 68, exteriorTemp: 61,
            odometerMiles: 6349, fsdMilesSinceReset: 812.5,
            licensePlate: "WIRE123",
            trimLabel: "Performance",
            fsdVersion: "FSD (Supervised) v14.3.5",
            lastUpdated: "2026-07-30T15:41:00.000Z"
        )
    }

    private nonisolated static func body(_ state: VehicleState) -> Data {
        // swiftlint:disable:next force_try
        try! JSONEncoder().encode(state)
    }

    // MARK: Composition

    private func makeLocator(http: any HTTPPerforming) -> RiderLiveVehicleLocator {
        RiderLiveVehicleLocator(config: .init(
            environment: .test,
            tokenProvider: StaticTokenProvider("test-token"),
            http: http,
            // Authenticates, then emits NOTHING — a parked/asleep car, whose only
            // data event ever is the cold REST read the socket fetches on
            // subscribe. Exactly the shape MYR-319's retry ladder exists for.
            channelFactory: AuthenticatingChannelFactory()
        ))
    }

    private func makeState(
        locator: RiderLiveVehicleLocator?,
        userLocation: (any UserLocationProviding)? = nil,
        isLive: Bool = true
    ) -> SharedViewerState {
        let userLocation = userLocation ?? FakeRiderLocation()
        let seams = PlaceSearchComposition.Seams(
            placeSearch: SimulatedPlaceSearch(),
            userLocation: userLocation,
            liveVehicleLocator: locator,
            pinLabeler: SimulatedPinLabeler(),
            isLive: isLive
        )
        // `nil` is what `RootView` passes on the live path (MYR-184/228): the
        // vehicle is ADOPTED, never defaulted to a fixture.
        return SharedViewerState(vehicle: isLive ? nil : VehicleFixtures.vehicles[0], seams: seams)
    }

    /// Run the SHIPPING adoption rule over a §7.0 list and push the result into
    /// the viewer state, exactly as `RootView.adoptRiderVehicle` does. Using the
    /// real `LiveSharedVehicleCatalog` partitioners + `RiderVehicleSet.resolve`
    /// (rather than hand-picking a row) is what makes "owned vs shared" an
    /// assertion about the shipping rule.
    @discardableResult
    private func adopt(_ rows: [VehicleSummary], into state: SharedViewerState) -> RiderVehicleSet {
        let resolution = RiderVehicleSet.resolve(
            hasLoaded: true,
            loadFailed: false,
            grants: LiveSharedVehicleCatalog.grants(from: rows),
            ownedVehicles: LiveSharedVehicleCatalog.ownedVehicles(from: rows)
        )
        if case .ridable(let adoption) = resolution { state.adopt(adoption) }
        return resolution
    }

    // MARK: - Adoption: the car on the map is the car on the socket

    /// OWNED WINS (MYR-343), and MYR-336's job is that the SOCKET agrees. The list
    /// is deliberately ordered viewer-first, so `vehicles.first` — the id the
    /// pre-MYR-336 one-shot fetched — is the SHARED car and the wrong answer. If
    /// the subscription followed list order instead of the adoption, the map would
    /// caption one car and stream another.
    func testOwnedVehicleIsTheOneSubscribed() async {
        let owned = Self.ownedRow()
        let rows = [Self.sharedRow(), owned]
        let http = RoutedHTTP([
            .init("/snapshot", body: Self.body(Self.snapshotState(id: owned.vehicleId, at: Self.lot))),
            .init("/vehicles", body: Contracts.listResponse(rows)),
        ])
        let locator = makeLocator(http: http)
        let state = makeState(locator: locator)

        adopt(rows, into: state)
        state.startTelemetry()

        await eventually { state.mapVehicle.activity.parkedLocation?.coordinate.latitude != 0 }

        XCTAssertEqual(locator.watchedVehicleID, owned.vehicleId,
                       "the socket must follow the ADOPTION, not the list head")
        XCTAssertEqual(state.sharedVehicle?.id, owned.vehicleId)
        XCTAssertNil(state.sharedVehicleTier, "an owner is not on a tier")
        assertCoordinate(state.mapVehicle.activity.parkedLocation?.coordinate, isNear: Self.lot)

        state.stopTelemetry()
    }

    /// The account owns nothing, so the first GRANT is adopted — and the viewer's
    /// subscription is the one the backend grants at tier `live`+ (telemetry #344).
    func testSharedVehicleIsSubscribedWhenTheAccountOwnsNothing() async {
        let shared = Self.sharedRow()
        let rows = [shared]
        let http = RoutedHTTP([
            .init("/snapshot", body: Self.body(Self.snapshotState(id: shared.vehicleId, at: Self.lot))),
            .init("/vehicles", body: Contracts.listResponse(rows)),
        ])
        let locator = makeLocator(http: http)
        let state = makeState(locator: locator)

        adopt(rows, into: state)
        state.startTelemetry()

        await eventually { locator.coordinate != nil }

        XCTAssertEqual(locator.watchedVehicleID, shared.vehicleId)
        XCTAssertEqual(state.sharedVehicleTier, .rides)
        assertCoordinate(locator.coordinate, isNear: Self.lot)

        state.stopTelemetry()
    }

    /// Re-adopting the SAME car is a no-op on the wire. The catalog re-resolves on
    /// every foreground and every redeem; tearing the subscription down and back
    /// up would re-run a cold read (and its retry ladder) for a car already
    /// streaming — the same idempotence `adoptSharedVehicle` has always had, now
    /// extended to the socket.
    func testReAdoptingTheSameVehicleDoesNotResubscribe() async {
        let owned = Self.ownedRow()
        let rows = [owned]
        let http = RoutedHTTP([
            .init("/snapshot", body: Self.body(Self.snapshotState(id: owned.vehicleId, at: Self.lot))),
            .init("/vehicles", body: Contracts.listResponse(rows)),
        ])
        let locator = makeLocator(http: http)
        let state = makeState(locator: locator)

        adopt(rows, into: state)
        state.startTelemetry()
        await eventually { locator.coordinate != nil }
        let source = locator.telemetrySource

        adopt(rows, into: state)
        adopt(rows, into: state)

        XCTAssertTrue(source === locator.telemetrySource,
                      "an unchanged catalog must not rebuild the live source")
        let reads = await http.callCount(suffix: "/snapshot")
        XCTAssertEqual(reads, 1, "no cold re-read for a car we are already streaming")

        state.stopTelemetry()
    }

    /// Adopting a DIFFERENT car swaps the subscription — the rider redeems a code
    /// while the map is up, or the owned partition arrives after a shared one.
    func testAdoptingADifferentVehicleSwapsTheSubscription() async {
        let shared = Self.sharedRow()
        let owned = Self.ownedRow()
        let http = RoutedHTTP([
            .init("/snapshot", body: Self.body(Self.snapshotState(id: owned.vehicleId, at: Self.lot))),
            .init("/vehicles", body: Contracts.listResponse([shared])),
        ])
        let locator = makeLocator(http: http)
        let state = makeState(locator: locator)

        adopt([shared], into: state)
        state.startTelemetry()
        XCTAssertEqual(locator.watchedVehicleID, shared.vehicleId)

        adopt([shared, owned], into: state)
        XCTAssertEqual(locator.watchedVehicleID, owned.vehicleId,
                       "owned wins, and the socket follows")
        XCTAssertEqual(state.sharedVehicle?.id, owned.vehicleId)

        state.stopTelemetry()
    }

    // MARK: - Honest states

    /// NO FIX YET → the pre-fix rendering, unchanged. `(0, 0)` is the contract's
    /// "no fix" sentinel, and the rider's map keeps the catalog row's "Locating…"
    /// placeholder rather than parking the car on the equator. Nothing downstream
    /// gets a coordinate to fabricate an ETA from either.
    func testNoFixKeepsThePreFixRenderingAndOffersNoCoordinate() async {
        let owned = Self.ownedRow()
        let rows = [owned]
        let noFix = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let http = RoutedHTTP([
            .init("/snapshot", body: Self.body(Self.snapshotState(id: owned.vehicleId, at: noFix))),
            .init("/vehicles", body: Contracts.listResponse(rows)),
        ])
        let locator = makeLocator(http: http)
        let state = makeState(locator: locator)

        adopt(rows, into: state)
        state.startTelemetry()
        await eventually { locator.state != nil } // the snapshot DID land

        XCTAssertNil(locator.coordinate, "0,0 is 'no fix', never a location")
        // The catalog row's placeholder activity survives untouched.
        XCTAssertEqual(state.mapVehicle.activity.parkedLocation?.label, "Locating\u{2026}")
        state.refreshPickupETAAnchors()
        XCTAssertNil(state.pickupETAVehicleAnchor)
        XCTAssertNil(state.pickupETAMinutes, "no vehicle fix → no fabricated minute")

        state.stopTelemetry()
    }

    /// MYR-319's ladder, on the rider side. A car asleep in a service bay answers
    /// the first `/snapshot` with `503 vehicle_asleep` and produces no WS frame to
    /// re-trigger anything — so a single failure used to be terminal. The rider
    /// inherits the retry by construction, because it is the same socket.
    func testAFailedColdReadIsRetriedForTheRider() async {
        let owned = Self.ownedRow()
        let rows = [owned]
        let http = RoutedHTTP([
            .init("/snapshot", failFirst: 1, status: 503,
                  failureBody: Data(#"{"error":{"code":"vehicle_asleep","message":"did not wake"}}"#.utf8),
                  body: Self.body(Self.snapshotState(id: owned.vehicleId, at: Self.lot))),
            .init("/vehicles", body: Contracts.listResponse(rows)),
        ])
        let locator = makeLocator(http: http)
        let state = makeState(locator: locator)

        adopt(rows, into: state)
        state.startTelemetry()

        await eventually(timeout: 6) { locator.coordinate != nil }
        assertCoordinate(locator.coordinate, isNear: Self.lot)
        let reads = await http.callCount(suffix: "/snapshot")
        XCTAssertGreaterThanOrEqual(reads, 2, "the ladder asked again")

        state.stopTelemetry()
    }

    /// The FALLBACK adoption. MYR-211's region bias and MYR-341's ETA must survive
    /// a shared-vehicle catalog that is slow or unreachable while `GET /api/vehicles`
    /// itself succeeded — which is exactly what the pre-MYR-336 one-shot did off
    /// `vehicles.first`. Nothing is adopted here at all.
    func testTheListHeadIsWatchedWhenNothingHasBeenAdopted() async {
        let owned = Self.ownedRow()
        let http = RoutedHTTP([
            .init("/snapshot", body: Self.body(Self.snapshotState(id: owned.vehicleId, at: Self.lot))),
            .init("/vehicles", body: Contracts.listResponse([owned])),
        ])
        let locator = makeLocator(http: http)
        let state = makeState(locator: locator)

        state.startTelemetry() // no adopt() at all

        await eventually { locator.coordinate != nil }
        XCTAssertEqual(locator.watchedVehicleID, owned.vehicleId)
        assertCoordinate(locator.coordinate, isNear: Self.lot)

        state.stopTelemetry()
    }

    // MARK: - MYR-341 — the ETA seam is still fed (now from the stream)

    /// `RiderPickupETA` reads the watched vehicle's coordinate through
    /// `SharedViewerState.pickupETAVehicleAnchor`. The quantize/latch logic is
    /// upstream-agnostic by design, so the only thing MYR-336 owes it is a
    /// coordinate — and this asserts the one that arrives is the STREAM's.
    func testPickupETAIsFedFromTheLiveStream() async {
        let owned = Self.ownedRow()
        let rows = [owned]
        let http = RoutedHTTP([
            .init("/snapshot", body: Self.body(Self.snapshotState(id: owned.vehicleId, at: Self.lot))),
            .init("/vehicles", body: Contracts.listResponse(rows)),
        ])
        let locator = makeLocator(http: http)
        // A rider standing ~2.6 mi from the car.
        let rider = CLLocationCoordinate2D(latitude: 37.7602, longitude: -122.4103)
        let state = makeState(locator: locator, userLocation: FakeRiderLocation(coordinate: rider))

        adopt(rows, into: state)
        state.startTelemetry()
        await eventually { locator.coordinate != nil }

        state.refreshPickupETAAnchors()
        XCTAssertNotNil(state.pickupETAVehicleAnchor, "the anchor took the streamed fix")
        let minutes = state.pickupETAMinutes
        XCTAssertNotNil(minutes)
        // The SHIPPING estimator over the SHIPPING anchors — this asserts the seam
        // is wired, not that the arithmetic is a particular number (that is
        // `RiderPickupETATests`' job).
        XCTAssertEqual(
            minutes,
            RiderPickupETA.minutes(vehicle: state.pickupETAVehicleAnchor, rider: state.pickupETARiderAnchor)
        )

        state.stopTelemetry()
    }

    // MARK: - Viewer masking (RiderVehicleProjection)

    /// THE VIEWER RULE. The snapshot above carries every owner-only identity
    /// field populated. The rider's `Vehicle` must take POSITION and STATUS from
    /// it and NOTHING else — identity stays on the catalog row the server masks.
    /// Asserted as a pure projection so the rule is provable without a socket.
    func testProjectionFoldsPositionAndStatusOnly() {
        let row = VehicleContractMapping.vehicle(summary: Self.sharedRow())
        let state = Self.snapshotState(id: "shared-1", at: Self.lot)

        let projected = RiderVehicleProjection.apply(state, to: row)

        // Position + status: taken.
        assertCoordinate(projected.activity.parkedLocation?.coordinate, isNear: Self.lot)
        XCTAssertEqual(projected.activity.parkedLocation?.label, "Embarcadero Center \u{00B7} Lot B")
        // Identity: untouched, every field.
        XCTAssertEqual(projected.id, row.id)
        XCTAssertEqual(projected.name, row.name)
        XCTAssertEqual(projected.model, row.model, "no trim-composed model off a viewer stream")
        XCTAssertEqual(projected.colorName, row.colorName)
        XCTAssertEqual(projected.plate, row.plate)
        XCTAssertNil(projected.vin, "a VIN must never reach the rider from telemetry")
        XCTAssertNil(projected.softwareVersion)
        XCTAssertNil(projected.fsdVersion)
        XCTAssertEqual(projected.seatVent, row.seatVent)
        XCTAssertEqual(projected.seatHeat, row.seatHeat)
    }

    /// A DRIVING car folds to the driving activity — the status half of the two
    /// facts the projection carries.
    func testProjectionCarriesTheDrivingStatus() {
        let row = VehicleContractMapping.vehicle(summary: Self.ownedRow())
        XCTAssertFalse(row.activity.isDriving, "the parked list row")
        let driving = Self.snapshotState(id: "owned-1", at: Self.lot, status: .driving)
        XCTAssertTrue(RiderVehicleProjection.apply(driving, to: row).activity.isDriving)
    }

    func testProjectionWithNoStateOrNoFixReturnsTheRowUnchanged() {
        let row = VehicleContractMapping.vehicle(summary: Self.sharedRow())
        XCTAssertEqual(RiderVehicleProjection.apply(nil, to: row), row)
        let noFix = Self.snapshotState(id: "shared-1", at: CLLocationCoordinate2D(latitude: 0, longitude: 0))
        XCTAssertEqual(RiderVehicleProjection.apply(noFix, to: row), row)
        XCTAssertFalse(RiderVehicleProjection.hasFix(noFix))
        XCTAssertNil(RiderVehicleProjection.coordinate(from: noFix))
    }

    // MARK: - Socket lifecycle

    /// The subscription follows the SCREEN. A rider who never reaches the Live Map
    /// (adoption lands from the catalog first) holds no connection until
    /// `startTelemetry`, and `stopTelemetry` releases it.
    func testSubscriptionFollowsTheScreenLifecycle() async {
        let owned = Self.ownedRow()
        let rows = [owned]
        let http = RoutedHTTP([
            .init("/snapshot", body: Self.body(Self.snapshotState(id: owned.vehicleId, at: Self.lot))),
            .init("/vehicles", body: Contracts.listResponse(rows)),
        ])
        let locator = makeLocator(http: http)
        let state = makeState(locator: locator)

        adopt(rows, into: state)
        XCTAssertEqual(locator.watchedVehicleID, owned.vehicleId, "adopted, not yet on screen")
        // Nothing has been asked for: no list, no snapshot.
        let coldPaths = await http.paths()
        XCTAssertTrue(coldPaths.isEmpty, "no request before the map mounts")

        state.startTelemetry()
        await eventually { locator.coordinate != nil }

        // Re-entry cycle: stop → start again cleanly, and the retained last-known
        // state is never blanked (NFR-3.12/3.13).
        state.stopTelemetry()
        XCTAssertNotNil(locator.state, "a stopped socket never clears what we hold")
        state.startTelemetry()
        await eventually { locator.coordinate != nil }

        state.stopTelemetry()
    }

    /// A resume nudges the socket AND re-asks for the watched car's snapshot — a
    /// car that moved while the app was suspended must not be re-rendered from
    /// whatever was last in memory (`LiveVehicleFleet.handleForeground`'s lesson).
    func testForegroundRefetchesTheWatchedSnapshot() async {
        let owned = Self.ownedRow()
        let rows = [owned]
        let http = RoutedHTTP([
            .init("/snapshot", body: Self.body(Self.snapshotState(id: owned.vehicleId, at: Self.lot))),
            .init("/vehicles", body: Contracts.listResponse(rows)),
        ])
        let locator = makeLocator(http: http)
        let state = makeState(locator: locator)

        adopt(rows, into: state)
        state.startTelemetry()
        await eventually { locator.coordinate != nil }
        let before = await http.callCount(suffix: "/snapshot")

        state.handleBackground()
        state.handleForeground()

        await eventuallyAsync { await http.callCount(suffix: "/snapshot") > before }

        state.stopTelemetry()
    }

    // MARK: - The simulated path is untouched (drift gate)

    /// SIM keeps the MYR-191 fixture ticker, the same object across reads, and
    /// never consults a live source — which is what keeps every simulated and
    /// DEBUG rider capture byte-identical.
    func testSimulatedPathKeepsTheFixtureTicker() {
        let state = makeState(locator: nil, isLive: false)
        XCTAssertTrue(state.telemetrySource is SimulatedVehicleTelemetrySource)
        XCTAssertNil(state.liveTelemetrySource)
        let first = state.telemetrySource
        state.startTelemetry()
        XCTAssertTrue(first === state.telemetrySource as AnyObject)
        XCTAssertEqual(state.mapVehicle, VehicleFixtures.vehicles[0])
        state.stopTelemetry()
    }

    /// Even with a locator composed, the SIM seam refuses the live source — the
    /// `AppMode` gate is `isLiveLocation`, not "is a locator present".
    func testSimulatedSeamsIgnoreALiveLocator() async {
        let http = RoutedHTTP([.init("/vehicles", body: Contracts.listResponse([Self.ownedRow()]))])
        let state = makeState(locator: makeLocator(http: http), isLive: false)
        XCTAssertNil(state.liveTelemetrySource)
        XCTAssertTrue(state.telemetrySource is SimulatedVehicleTelemetrySource)
    }

    // MARK: - Helpers

    /// Embarcadero Center · Lot B — the snapshot's position throughout.
    private static let lot = CLLocationCoordinate2D(latitude: 37.7955, longitude: -122.3937)

    private func assertCoordinate(
        _ actual: CLLocationCoordinate2D?,
        isNear expected: CLLocationCoordinate2D,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actual else { return XCTFail("no coordinate", file: file, line: line) }
        XCTAssertEqual(actual.latitude, expected.latitude, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(actual.longitude, expected.longitude, accuracy: 0.0001, file: file, line: line)
    }

    private func eventually(
        timeout: TimeInterval = 3.0,
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
        timeout: TimeInterval = 3.0,
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

/// Minimal `UserLocationProviding` — the rider's device fix, or none.
@Observable
@MainActor
private final class FakeRiderLocation: UserLocationProviding {
    var coordinate: CLLocationCoordinate2D?

    init(coordinate: CLLocationCoordinate2D? = nil) { self.coordinate = coordinate }

    var currentLocationLabel: String { "Current location" }
    var showsUserLocationDot: Bool { coordinate != nil }
    func start() {}
    func stop() {}
    func refresh() {}
}
