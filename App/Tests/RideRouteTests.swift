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
