import CoreLocation
import DesignSystem
@testable import MyRoboTaxi
import MyRoboTaxiKit
import MyRobotaxiContracts
import XCTest

// MARK: - MYR-458 / MYR-459 — the rider's tracking map draws no straight lines,
// and its route keeps up with the car
//
// **THE TWO REPORTS**, both James Guan, both build `202608030843`, both from the
// SAME ride on 2026-08-06:
//
//   * **MYR-458** (AJTsVSFh, 7:10 PM) — *"After riding, there is straight line
//     between the current location and beginning dot."* Not a one-frame artifact:
//     the same connector is in his 7:16, 7:17 and 7:20 PM submissions. The main
//     route follows roads; this segment does not.
//   * **MYR-459** (AFX6zpFg 7:05 PM, AC7o7M-c 7:06 PM) — *"During ride, the car
//     isn't fully aligning with the route of beginning"*, and one minute later
//     *"The car route isn't going with the route displayed"*, with the car further
//     off. **The gap WIDENS**, which is what rules out a fixed projection offset
//     and points at routing freshness.
//
// **THE DISCIPLINE GATE.** Both predate MYR-449. That fix cannot have removed
// either — it makes the rider's live fix MORE available, and both defects are
// driven BY the live fix (458's straight segment is anchored on it; 459's marker
// IS it). Pre-449, a rider with no snapshot had no fix, so `trackingCarOrigin`
// was nil, leg 1 was empty and neither symptom could render at all. 449 therefore
// widens the population that can see them. Both still reproduce on main.
//
// **MYR-458's MECHANISM.** `SharedViewerScreen.trackingLeg1Route` falls back to
// `[trackingCarOrigin, trackingPickup]` — and on the live path `trackingCarOrigin`
// IS `trackingVehicleCoordinate`, the car's current fix. So the pair is literally
// *[the current location, the beginning dot]*. `TrackingRouteMapContent.routeLeg`
// then drew it, because its gate was `count > 1` and not
// `RideRoutePolyline.isReal` — the ONE route surface in the app that never
// consulted MYR-293's predicate. It persists all trip because nothing refetches
// leg 1 once the ride is under way.
//
// **MYR-459's MECHANISM.** `RideRouteStore.ensureLeg1` consults
// `RideRouteGeometry.shouldRefetch` — a correct, separately-tested deviation rule
// — and its only caller is `SharedViewerScreen.reconcileTrackingRoutes()`, whose
// triggers are the tracking-phase entry and
// `onChange(of: activeRequest?.trackProgress)`. On the LIVE path `trackProgress`
// is written **only at status transitions** (`accepted` → `enroute` →
// `completed`); there is no live ticker. So the deviation refetch had no live
// consumer: the polyline stayed as fetched at accept time while the marker — the
// live fix — drove away from it. The repo's own recurring shape (MYR-387's defect
// 2, `VehicleRideShare.display`, MYR-402): **a pure rule with good tests and the
// wrong consumer.** The comment above that `onChange` even promises "no per-fix
// network", describing a per-fix reconciliation that never happened.
@MainActor
final class RiderTrackingRouteGeometryTests: XCTestCase {

    private static let pickup = CLLocationCoordinate2D(latitude: 33.0790, longitude: -96.8100)
    private static let destination = CLLocationCoordinate2D(latitude: 33.0930, longitude: -96.8300)
    private static let carAtAccept = CLLocationCoordinate2D(latitude: 33.0700, longitude: -96.7990)
    /// ~700m from the accept-time fix — comfortably past
    /// `MRTMetrics.rideRouteDeviationThresholdMeters` and past the ~11m ask
    /// quantization.
    private static let carDeviated = CLLocationCoordinate2D(latitude: 33.0760, longitude: -96.7950)

    // MARK: - MYR-458 · no straight lines on the tracking map

    /// **THE HEADLINE FOR MYR-458.** The leg-1 fallback is exactly the shape
    /// MYR-237/MYR-293 named as never a route, and the tracking map must refuse to
    /// stroke it.
    ///
    /// Pre-fix the gate was `route.count > 1`, which this pair passes — so this
    /// assertion is the defect stated directly.
    func testTheLiveFixToPickupPairIsNeverStroked() {
        let leg1Fallback = [Self.carAtAccept, Self.pickup]

        XCTAssertEqual(leg1Fallback.count, 2, "precondition: this is the shape the screen falls back to")
        XCTAssertFalse(
            TrackingRouteMapContent.drawsLine(leg1Fallback),
            "[current location, beginning dot] is a claim about the car's path, and it is false"
        )
    }

    /// Leg 2's endpoint pair is refused by the same predicate — the rule is one
    /// predicate in one place, so neither leg can acquire its own looser test.
    func testTheLegTwoEndpointPairIsRefusedByTheSameRule() {
        XCTAssertFalse(TrackingRouteMapContent.drawsLine([Self.pickup, Self.destination]))
    }

    /// A REAL road route is drawn exactly as before. The gate withholds the
    /// fabrication and nothing else.
    func testARealRoadRouteIsStillDrawn() {
        XCTAssertTrue(TrackingRouteMapContent.drawsLine(Self.roadRoute()))
    }

    /// **THE PINS AND THE CAMERA KEEP THE PAIR**, which is MYR-293's rule stated
    /// in full: *pins unconditionally, the LINE only from `isReal`*. Withholding
    /// the geometry instead of the stroke would move the pickup pin onto the car.
    func testWithholdingTheLineDoesNotMoveThePickupPin() {
        let leg1Fallback = [Self.carAtAccept, Self.pickup]

        let pin = TrackingRouteMapContent.pickup(
            leg1Route: leg1Fallback,
            leg2Route: [Self.pickup, Self.destination],
            carCoordinate: Self.carAtAccept
        )

        XCTAssertFalse(TrackingRouteMapContent.drawsLine(leg1Fallback))
        XCTAssertEqual(pin.latitude, Self.pickup.latitude, accuracy: 1e-9)
        XCTAssertEqual(pin.longitude, Self.pickup.longitude, accuracy: 1e-9)
    }

    /// An empty leg still frames on the pickup alone (MYR-393, unchanged).
    func testAnEmptyLegOneStillFramesOnThePickup() {
        let pin = TrackingRouteMapContent.pickup(
            leg1Route: [], leg2Route: [Self.pickup, Self.destination], carCoordinate: nil
        )
        XCTAssertEqual(pin.latitude, Self.pickup.latitude, accuracy: 1e-9)
    }

    // MARK: - MYR-459 · the deviation refetch gets a live trigger

    /// The ask is quantized at ~11m, so a ~1Hz stream does not re-ask per frame.
    /// `HomeScreen.dispatchedCarPositionKey`'s rule, reused verbatim.
    func testTheFixKeyQuantizesJitterAwayButNotRealMovement() {
        let base = SharedViewerState.trackingFixKey(Self.carAtAccept)
        let jittered = SharedViewerState.trackingFixKey(
            CLLocationCoordinate2D(latitude: Self.carAtAccept.latitude + 0.000_01,
                                   longitude: Self.carAtAccept.longitude)
        )
        let moved = SharedViewerState.trackingFixKey(Self.carDeviated)

        XCTAssertEqual(base, jittered, "a metre of GPS jitter is not a deviation")
        XCTAssertNotEqual(base, moved, "hundreds of metres is")
        XCTAssertNil(SharedViewerState.trackingFixKey(nil))
    }

    /// **THE HEADLINE FOR MYR-459, through the REAL composition.**
    ///
    /// A viewer frame arrives off a scripted socket with the cold snapshot refused
    /// `403` exactly as the server refuses it (MYR-449's harness), and the route
    /// cache is re-asked. Pre-fix the count is **0 forever**: nothing downstream of
    /// a frame ever ran, because the only reconcile trigger is a simulated ticker.
    ///
    /// The ASKS are counted rather than MKDirections calls — `SharedViewerState`
    /// builds its own store, so the provider is not injectable, and "the store
    /// no-oped" is indistinguishable from "the store was never asked" at every
    /// other observation point. Being asked is precisely the half this issue is
    /// about.
    func testALiveFrameReAsksTheRouteCacheAsTheCarMoves() async {
        let row = Self.sharedRow()
        let channels = AuthenticatingChannelFactory()
        let locator = Self.locator(channels: channels, rows: [row])
        let state = Self.state(locator: locator)

        Self.adopt([row], into: state)
        state.startTelemetry()
        state.sheetPhase = .tracking
        await eventuallyAsync { await Self.subscribed(channels, to: row.vehicleId) }

        // The screen publishes what it wants routed — this is
        // `reconcileTrackingRoutes()`'s own call, with the leg-1 arm live because
        // the car is heading to pickup.
        state.setTrackingRouteContext(.init(
            pickup: Self.pickup, destination: Self.destination, fetchesLeg1: true
        ))
        XCTAssertEqual(state.trackingRouteLiveReasks, 0, "precondition: nothing asked yet")

        await Self.push(channels, vehicleId: row.vehicleId, at: Self.carAtAccept)
        await eventually { state.trackingRouteLiveReasks == 1 }

        // The car drives on. THIS is the frame the pre-fix build had no path for,
        // and it is the whole of the widening gap in his two screenshots.
        await Self.push(channels, vehicleId: row.vehicleId, at: Self.carDeviated,
                        lastUpdated: "2026-08-06T00:07:10Z")
        await eventually { state.trackingRouteLiveReasks == 2 }

        XCTAssertEqual(state.trackingRouteLiveReasks, 2,
                       "a car that moved re-asks; before this fix it never could")
        state.stopTelemetry()
    }

    /// And a car sitting still does NOT re-ask. A trigger that fired per frame
    /// would be a poll wearing an observer's clothes (MYR-402's own phrase),
    /// against Apple's per-device throttle.
    func testAStationaryCarDoesNotReAskOnEveryFrame() async {
        let row = Self.sharedRow()
        let channels = AuthenticatingChannelFactory()
        let locator = Self.locator(channels: channels, rows: [row])
        let state = Self.state(locator: locator)

        Self.adopt([row], into: state)
        state.startTelemetry()
        state.sheetPhase = .tracking
        await eventuallyAsync { await Self.subscribed(channels, to: row.vehicleId) }
        state.setTrackingRouteContext(.init(
            pickup: Self.pickup, destination: Self.destination, fetchesLeg1: true
        ))

        await Self.push(channels, vehicleId: row.vehicleId, at: Self.carAtAccept)
        await eventually { state.trackingRouteLiveReasks == 1 }

        for i in 0..<3 {
            await Self.push(
                channels, vehicleId: row.vehicleId,
                at: CLLocationCoordinate2D(latitude: Self.carAtAccept.latitude + Double(i) * 0.000_01,
                                           longitude: Self.carAtAccept.longitude),
                lastUpdated: "2026-08-06T00:06:0\(i)Z"
            )
        }
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(state.trackingRouteLiveReasks, 1, "jitter is not deviation")
        state.stopTelemetry()
    }

    /// **A RIDE ALREADY UNDER WAY RE-ASKS FOR NOTHING.** MYR-393's rule stands: no
    /// origin, no leg-1 fetch — and once the rider is aboard, leg 1 is history.
    /// This is what stops the new trigger spending throttle budget for the whole
    /// of every trip.
    func testAnInRideContextNeverReAsksLegOne() async {
        let row = Self.sharedRow()
        let channels = AuthenticatingChannelFactory()
        let locator = Self.locator(channels: channels, rows: [row])
        let state = Self.state(locator: locator)

        Self.adopt([row], into: state)
        state.startTelemetry()
        state.sheetPhase = .tracking
        await eventuallyAsync { await Self.subscribed(channels, to: row.vehicleId) }
        state.setTrackingRouteContext(.init(
            pickup: Self.pickup, destination: Self.destination, fetchesLeg1: false
        ))

        await Self.push(channels, vehicleId: row.vehicleId, at: Self.carAtAccept)
        await Self.push(channels, vehicleId: row.vehicleId, at: Self.carDeviated,
                        lastUpdated: "2026-08-06T00:07:10Z")
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(state.trackingRouteLiveReasks, 0)
        state.stopTelemetry()
    }

    /// Leaving tracking clears the context, so a frame arriving for a rider who is
    /// no longer watching asks for nothing.
    func testLeavingTrackingStandsTheTriggerDown() {
        let state = Self.state(locator: nil)
        state.sheetPhase = .tracking
        state.setTrackingRouteContext(.init(
            pickup: Self.pickup, destination: Self.destination, fetchesLeg1: true
        ))
        state.setTrackingRouteContext(nil)

        state.reconcileTrackingRoutesForLiveFix()
        XCTAssertEqual(state.trackingRouteLiveReasks, 0)
    }

    // MARK: - The deviation rule itself (unchanged, and still the gate)

    /// The new trigger does not replace the deviation test — it delivers a car
    /// position TO it. Restated here so the two halves are visible together: the
    /// rule was always right, and it was never being asked.
    func testTheDeviationRuleStillDecidesWhetherAnAskCostsACall() {
        let cached = Self.roadRoute()
        XCTAssertFalse(
            RideRouteGeometry.shouldRefetch(
                carPosition: cached[1], cachedRoute: cached,
                thresholdMeters: MRTMetrics.rideRouteDeviationThresholdMeters
            ),
            "a car ON its route needs no new route"
        )
        XCTAssertTrue(
            RideRouteGeometry.shouldRefetch(
                carPosition: CLLocationCoordinate2D(latitude: 33.2000, longitude: -96.9500),
                cachedRoute: cached,
                thresholdMeters: MRTMetrics.rideRouteDeviationThresholdMeters
            ),
            "a car that has left it does"
        )
    }

    // MARK: Composition helpers (the MYR-449 engagement idiom)

    private static func roadRoute(_ count: Int = 6) -> [CLLocationCoordinate2D] {
        (0..<count).map { i in
            let t = Double(i) / Double(count - 1)
            return CLLocationCoordinate2D(
                latitude: carAtAccept.latitude + (pickup.latitude - carAtAccept.latitude) * t,
                longitude: carAtAccept.longitude + (pickup.longitude - carAtAccept.longitude) * t
            )
        }
    }

    private nonisolated static func sharedRow(id: String = "shared-1") -> VehicleSummary {
        VehicleSummary(
            vehicleId: id, name: "Quicksilver Model Y", model: "Model Y", year: 2026,
            color: "Quicksilver", vinLast4: "5545", status: .driving,
            chargeLevel: 68, estimatedRange: 231,
            lastUpdated: "2026-08-06T00:05:34.000Z", role: .viewer,
            sharePermission: .rides
        )
    }

    /// The snapshot is refused `403` forever — the server's settled answer for a
    /// viewer (MYR-432), and the condition MYR-449's harness established.
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

    private static func state(locator: RiderLiveVehicleLocator?) -> SharedViewerState {
        let seams = PlaceSearchComposition.Seams(
            placeSearch: SimulatedPlaceSearch(),
            userLocation: TrackingFakeLocation(),
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

    private static func push(
        _ channels: AuthenticatingChannelFactory,
        vehicleId: String,
        at coordinate: CLLocationCoordinate2D,
        lastUpdated: String = "2026-08-06T00:06:00Z"
    ) async {
        guard let channel = channels.madeChannels().last else { return }
        await channel.emit(AuthenticatingWebSocketChannel.viewerGPSFrame(
            vehicleId: vehicleId,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            lastUpdated: lastUpdated
        ))
    }

    /// Has the socket actually sent a `subscribe`? Pushing a frame before it has
    /// would prove nothing (MYR-449's harness rule).
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
private final class TrackingFakeLocation: UserLocationProviding {
    var coordinate: CLLocationCoordinate2D?
    var currentLocationLabel: String { "Current location" }
    var showsUserLocationDot: Bool { coordinate != nil }
    func start() {}
    func stop() {}
    func refresh() {}
}
