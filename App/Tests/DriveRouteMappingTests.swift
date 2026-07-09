import CoreLocation
@testable import MyRoboTaxi
import MyRobotaxiContracts
import XCTest

// MARK: - MYR-204 deliverable 2 — DriveRoute → hero polyline mapping
//
// Pure RoutePoint(lat,lng) → CLLocationCoordinate2D projection + uniform
// thinning (endpoints always preserved). No I/O.
final class DriveRouteMappingTests: XCTestCase {

    private func point(_ lat: Double, _ lng: Double) -> RoutePoint {
        RoutePoint(lat: lat, lng: lng, speed: 0, heading: 0, timestamp: "2026-07-06T13:23:54Z")
    }

    func testCoordinatesProjectLatLngInOrder() {
        let route = DriveRoute(driveId: "d1", routePoints: [
            point(33.086114, -96.851844),
            point(33.043874, -96.794544),
            point(32.992545, -96.794208),
        ])
        let coords = DriveContractMapping.coordinates(from: route)
        XCTAssertEqual(coords.count, 3)
        XCTAssertEqual(coords.first?.latitude ?? 0, 33.086114, accuracy: 1e-6)
        XCTAssertEqual(coords.first?.longitude ?? 0, -96.851844, accuracy: 1e-6)
        XCTAssertEqual(coords.last?.latitude ?? 0, 32.992545, accuracy: 1e-6)
        XCTAssertEqual(coords.last?.longitude ?? 0, -96.794208, accuracy: 1e-6)
    }

    func testEmptyRouteMapsToEmpty() {
        let coords = DriveContractMapping.coordinates(from: DriveRoute(driveId: "d0", routePoints: []))
        XCTAssertTrue(coords.isEmpty, "empty [] route → routeless placeholder")
    }

    func testThinCapsCountAndKeepsEndpoints() {
        let dense = (0..<2000).map { CLLocationCoordinate2D(latitude: Double($0) * 0.001, longitude: -96.0) }
        let thinned = DriveContractMapping.thin(dense, maxPoints: 800)
        XCTAssertEqual(thinned.count, 800)
        XCTAssertEqual(thinned.first?.latitude ?? -1, dense.first?.latitude ?? -2, accuracy: 1e-12)
        XCTAssertEqual(thinned.last?.latitude ?? -1, dense.last?.latitude ?? -2, accuracy: 1e-12,
                       "the true last point is preserved after decimation")
    }

    func testThinIsNoOpWithinCap() {
        let sparse = (0..<10).map { CLLocationCoordinate2D(latitude: Double($0), longitude: 0) }
        let thinned = DriveContractMapping.thin(sparse, maxPoints: 800)
        XCTAssertEqual(thinned.count, 10)
    }

    func testDefaultCoordinateThinningUsesMaxRoutePoints() {
        let dense = (0...5000).map { RoutePoint(lat: Double($0) * 0.0001, lng: -96, speed: 0, heading: 0, timestamp: "t") }
        let coords = DriveContractMapping.coordinates(from: DriveRoute(driveId: "d", routePoints: dense))
        XCTAssertEqual(coords.count, DriveContractMapping.maxRoutePoints)
    }
}
