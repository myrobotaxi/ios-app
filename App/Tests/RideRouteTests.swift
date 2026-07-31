import CoreLocation
import DesignSystem
import MapKit
@testable import MyRoboTaxi
import XCTest

// MARK: - MYR-177 — ride-route provider seam: geometry + cache/deviation
//
// The provider is seam-injected and SCRIPTED here — no network on the test
// path (CLAUDE.md). These pin the deviation math (distance-from-polyline, not a
// timer) and the cache contract: leg 2 fetched once per pair, leg 1 refetched
// only on a MATERIAL deviation.

/// A no-network provider that returns a fixed 3-point polyline and counts calls.
private actor ScriptedRideRouteProvider: RideRouteProvider {
    private(set) var callCount = 0
    private(set) var lastFrom: CLLocationCoordinate2D?
    private(set) var lastTo: CLLocationCoordinate2D?

    func route(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async -> [CLLocationCoordinate2D] {
        callCount += 1
        lastFrom = from
        lastTo = to
        let mid = CLLocationCoordinate2D(latitude: (from.latitude + to.latitude) / 2,
                                         longitude: (from.longitude + to.longitude) / 2)
        return [from, mid, to]
    }

    func count() -> Int { callCount }
}

/// MYR-293 — a provider that behaves like a THROTTLED MKDirections: the first ask
/// degrades to the straight `[from, to]` fallback, every later one succeeds. The
/// only way to exercise the retry that the "draw nothing for a fallback" rule
/// makes necessary.
private actor FallbackThenRouteProvider: RideRouteProvider {
    private(set) var callCount = 0

    func route(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async -> [CLLocationCoordinate2D] {
        callCount += 1
        guard callCount > 1 else { return [from, to] }
        let mid = CLLocationCoordinate2D(latitude: (from.latitude + to.latitude) / 2,
                                         longitude: (from.longitude + to.longitude) / 2)
        return [from, mid, to]
    }

    func count() -> Int { callCount }
}

// MARK: - MYR-293 — "no straight lines" as ONE predicate
//
// TestFlight, Jul 25: *"Fake route poly line rendered."* The owner's leg-1
// tracking map and the incoming-request card's mini-map both drew literal
// two-point segments; the rider's review map had had the right predicate inline
// since MYR-237 and nothing shared it. These pin the rule itself.

final class RideRoutePolylineTests: XCTestCase {

    private let a = CLLocationCoordinate2D(latitude: 37.7899, longitude: -122.3969)
    private let b = CLLocationCoordinate2D(latitude: 37.7955, longitude: -122.3937)
    private var mid: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: (a.latitude + b.latitude) / 2, longitude: (a.longitude + b.longitude) / 2)
    }

    /// THE RULE. A two-point polyline is the provider's own honest-degradation
    /// fallback, never road geometry — MKDirections has never returned an
    /// automobile route between two distinct places as two vertices.
    func testAStraightSegmentIsNotARoute() {
        XCTAssertFalse(RideRoutePolyline.isReal([]))
        XCTAssertFalse(RideRoutePolyline.isReal([a]))
        XCTAssertFalse(RideRoutePolyline.isReal([a, b]), "the straight [from, to] fallback is not a route")
        XCTAssertTrue(RideRoutePolyline.isReal([a, mid, b]))
    }

    /// What a SURFACE draws. Nothing at all for a fallback — the pins stay and the
    /// line does not, which is the honest degradation; drawing the fallback is the
    /// defect this issue exists to remove.
    func testDrawableIsEmptyForEverythingThatIsNotARoute() {
        XCTAssertTrue(RideRoutePolyline.drawable([a, b]).isEmpty)
        XCTAssertTrue(RideRoutePolyline.drawable([a]).isEmpty)
        XCTAssertTrue(RideRoutePolyline.drawable([]).isEmpty)
        XCTAssertEqual(RideRoutePolyline.drawable([a, mid, b]).count, 3)
    }
}

final class RideRouteGeometryTests: XCTestCase {

    private let a = CLLocationCoordinate2D(latitude: 37.7899, longitude: -122.3969)
    private let b = CLLocationCoordinate2D(latitude: 37.7955, longitude: -122.3937)

    func testDistanceFromPolylineIsZeroOnTheLine() {
        let mid = CLLocationCoordinate2D(latitude: (a.latitude + b.latitude) / 2, longitude: (a.longitude + b.longitude) / 2)
        let d = RideRouteGeometry.distanceFromPolyline(mid, polyline: [a, b])
        XCTAssertLessThan(d, 1, "a point exactly on the segment is ~0 m away")
    }

    func testDistanceFromPolylineMeasuresPerpendicular() {
        // ~0.003° longitude off the line at this latitude ≈ ~260 m.
        let off = CLLocationCoordinate2D(latitude: b.latitude, longitude: b.longitude + 0.003)
        let d = RideRouteGeometry.distanceFromPolyline(off, polyline: [a, b])
        XCTAssertGreaterThan(d, 150)
        XCTAssertLessThan(d, 400)
    }

    func testShouldRefetchOnlyBeyondThreshold() {
        let onLine = CLLocationCoordinate2D(latitude: (a.latitude + b.latitude) / 2, longitude: (a.longitude + b.longitude) / 2)
        XCTAssertFalse(RideRouteGeometry.shouldRefetch(carPosition: onLine, cachedRoute: [a, b], thresholdMeters: 60))
        let wayOff = CLLocationCoordinate2D(latitude: b.latitude + 0.01, longitude: b.longitude + 0.01)
        XCTAssertTrue(RideRouteGeometry.shouldRefetch(carPosition: wayOff, cachedRoute: [a, b], thresholdMeters: 60))
    }

    func testEmptyCacheAlwaysRefetches() {
        XCTAssertTrue(RideRouteGeometry.shouldRefetch(carPosition: a, cachedRoute: [], thresholdMeters: 60))
    }
}

@MainActor
final class RideRouteStoreTests: XCTestCase {

    private let carOrigin = CLLocationCoordinate2D(latitude: 37.7965, longitude: -122.4079)
    private let pickup = CLLocationCoordinate2D(latitude: 37.7899, longitude: -122.3969)
    private let destination = CLLocationCoordinate2D(latitude: 37.6213, longitude: -122.3790)

    private func waitUntil(_ condition: @escaping () -> Bool, timeout: Int = 200) async {
        for _ in 0..<timeout {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    func testLeg2FetchedOncePerPair() async {
        let provider = ScriptedRideRouteProvider()
        let store = RideRouteStore(provider: provider)
        store.ensureLeg2(pickup: pickup, destination: destination)
        await waitUntil { store.leg2.count > 1 }
        XCTAssertEqual(store.leg2.count, 3)
        let firstCount = await provider.count()
        XCTAssertEqual(firstCount, 1)
        // Same pair again → no new fetch.
        store.ensureLeg2(pickup: pickup, destination: destination)
        await Task.yield()
        let secondCount = await provider.count()
        XCTAssertEqual(secondCount, 1, "leg 2 is fixed for the ride — fetched exactly once")
    }

    func testLeg1FetchedOnceThenRefetchesOnlyOnDeviation() async {
        let provider = ScriptedRideRouteProvider()
        let store = RideRouteStore(provider: provider, deviationThresholdMeters: 60)
        store.ensureLeg1(carPosition: carOrigin, pickup: pickup)
        await waitUntil { store.leg1.count > 1 }
        let afterFirst = await provider.count()
        XCTAssertEqual(afterFirst, 1)

        // A car ON the cached route (its midpoint) → no refetch.
        let onRoute = store.leg1[1]
        store.ensureLeg1(carPosition: onRoute, pickup: pickup)
        await Task.yield()
        let afterOnRoute = await provider.count()
        XCTAssertEqual(afterOnRoute, 1, "on-route car does not refetch")

        // A car far off the cached route → refetch from the new position.
        let wayOff = CLLocationCoordinate2D(latitude: onRoute.latitude + 0.02, longitude: onRoute.longitude + 0.02)
        store.ensureLeg1(carPosition: wayOff, pickup: pickup)
        await waitUntil { Task.isCancelled == false }
        var refetched = false
        for _ in 0..<200 {
            if await provider.count() == 2 { refetched = true; break }
            await Task.yield(); try? await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(refetched, "a material deviation refetches leg 1")
    }

    // MARK: MYR-293 — the two guards leg 1 was missing

    /// A cached 2-point FALLBACK must retry. Before MYR-293 the caller drew that
    /// fallback, so the store never needed to re-ask; now the caller draws
    /// NOTHING for it, and deviation alone cannot bring the route back — a car
    /// following the straight line never strays from it. Without this the owner's
    /// map would keep a bare pickup pin for the whole ride after one throttled
    /// MKDirections call.
    func testACachedStraightFallbackRetriesAfterTheCooldown() async {
        let provider = FallbackThenRouteProvider()
        let store = RideRouteStore(provider: provider, fallbackRetryCooldown: 0)
        store.ensureLeg1(carPosition: carOrigin, pickup: pickup)
        await waitUntil { store.leg1.count == 2 }
        XCTAssertFalse(RideRoutePolyline.isReal(store.leg1), "first answer is the straight fallback")

        // The car has not moved and the cache is not empty — pre-MYR-293 both
        // guards said "nothing to do" and this stayed 2 forever.
        store.ensureLeg1(carPosition: carOrigin, pickup: pickup)
        await waitUntil { store.leg1.count > 2 }
        XCTAssertTrue(RideRoutePolyline.isReal(store.leg1), "the retry upgraded the fallback to real geometry")
    }

    /// The cooldown is real: a repeat ask INSIDE it does not spend a call. The
    /// owner's map re-asks on every material move of the car, so without this a
    /// throttled route would be re-requested at fix cadence — which is what got
    /// MKDirections throttled in MYR-237 to begin with.
    func testTheFallbackRetryRespectsItsCooldown() async {
        let provider = FallbackThenRouteProvider()
        let store = RideRouteStore(provider: provider, fallbackRetryCooldown: 600)
        store.ensureLeg1(carPosition: carOrigin, pickup: pickup)
        await waitUntil { store.leg1.count == 2 }
        store.ensureLeg1(carPosition: carOrigin, pickup: pickup)
        await Task.yield()
        let calls = await provider.count()
        XCTAssertEqual(calls, 1, "inside the cooldown the store does not re-ask")
    }

    /// A NEW PICKUP is a different ride. The cache drops immediately rather than
    /// lingering until the refetch lands — real road geometry rendered to the
    /// WRONG place is worse than the straight line this issue removed, and it
    /// would look entirely convincing.
    func testANewPickupDropsTheCachedLegAtOnce() async {
        let provider = ScriptedRideRouteProvider()
        let store = RideRouteStore(provider: provider)
        store.ensureLeg1(carPosition: carOrigin, pickup: pickup)
        await waitUntil { store.leg1.count > 1 }
        XCTAssertNotNil(store.leg1Route(pickup: pickup))

        let otherPickup = CLLocationCoordinate2D(latitude: 37.8087, longitude: -122.4098)
        store.ensureLeg1(carPosition: carOrigin, pickup: otherPickup)
        XCTAssertTrue(store.leg1.isEmpty, "the previous ride's polyline is gone the instant the pickup changes")
        XCTAssertNil(store.leg1Route(pickup: pickup))
    }

    /// The keyed accessor never hands back a route for a pickup it was not
    /// fetched against — the leg-1 twin of `leg2Route(pickup:destination:)`.
    func testLeg1RouteIsKeyedOnItsPickup() async {
        let provider = ScriptedRideRouteProvider()
        let store = RideRouteStore(provider: provider)
        store.ensureLeg1(carPosition: carOrigin, pickup: pickup)
        await waitUntil { store.leg1.count > 1 }
        XCTAssertEqual(store.leg1Route(pickup: pickup)?.count, 3)
        XCTAssertNil(store.leg1Route(pickup: destination))
    }

    func testResetClearsCache() async {
        let provider = ScriptedRideRouteProvider()
        let store = RideRouteStore(provider: provider)
        store.ensureLeg2(pickup: pickup, destination: destination)
        await waitUntil { store.leg2.count > 1 }
        store.reset()
        XCTAssertTrue(store.leg1.isEmpty)
        XCTAssertTrue(store.leg2.isEmpty)
    }

    func testStraightLineProviderIsOfflineFallback() async {
        let store = RideRouteStore(provider: StraightLineRideRouteProvider())
        store.ensureLeg2(pickup: pickup, destination: destination)
        await waitUntil { store.leg2.count > 1 }
        XCTAssertEqual(store.leg2.count, 2, "the offline provider returns the straight [from, to]")
    }
}
