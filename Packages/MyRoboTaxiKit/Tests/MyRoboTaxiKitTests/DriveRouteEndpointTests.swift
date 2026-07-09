import XCTest
@testable import MyRoboTaxiKit
import MyRobotaxiContracts

/// Fixture round-trip tests for the lazy drive-route read-path (rest-api.md
/// §7.4, `DriveRoute`, contracts v0.7.0): request-path assembly, decoding a
/// multi-point polyline with every RoutePoint field present, the ALWAYS-array
/// `routePoints` contract (`[]` for a very short drive, never null), and a true
/// encode→decode round trip. No network — the deterministic `RecordingHTTP`
/// replays canonical fixtures.
final class DriveRouteEndpointTests: XCTestCase {
    private let devEnvironment = BackendEnvironment(
        restBaseURL: URL(string: "https://api.myrobotaxi.com/api")!,
        webSocketURL: URL(string: "wss://api.myrobotaxi.com/api/ws")!,
        allowsInsecureLoopback: false
    )

    private func client(_ stubs: [RecordingHTTP.Stub]) -> (RestClient, RecordingHTTP) {
        let http = RecordingHTTP(stubs)
        return (RestClient(environment: devEnvironment, tokenProvider: StaticTokenProvider("t"), http: http), http)
    }

    // MARK: - Path + multi-point decode

    func testDriveRouteTargetsRouteSubpathAndDecodesPolyline() async throws {
        let (client, http) = client([.init(status: 200, body: try Fixture.data("rest/drive_route.json"))])

        let route = try await client.driveRoute(id: "clmno9876543210zyxw0001")

        let requests = await http.capturedRequests()
        XCTAssertEqual(requests[0].url?.path, "/api/drives/clmno9876543210zyxw0001/route",
                       "route is the /route subpath of the drive, not the drive detail")

        XCTAssertEqual(route.driveId, "clmno9876543210zyxw0001")
        XCTAssertEqual(route.routePoints.count, 6)

        // Ordered oldest-first; every field present on every point.
        let first = try XCTUnwrap(route.routePoints.first)
        XCTAssertEqual(first.lat, 33.086114, accuracy: 1e-6)
        XCTAssertEqual(first.lng, -96.851844, accuracy: 1e-6)
        XCTAssertEqual(first.speed, 0, accuracy: 1e-6)
        XCTAssertEqual(first.heading, 0, accuracy: 1e-6)
        XCTAssertEqual(first.timestamp, "2026-07-06T13:23:54Z")

        let last = try XCTUnwrap(route.routePoints.last)
        XCTAssertEqual(last.lat, 32.992545, accuracy: 1e-6)
        XCTAssertEqual(last.lng, -96.794208, accuracy: 1e-6)
        XCTAssertEqual(last.speed, 12, accuracy: 1e-6)
        XCTAssertEqual(last.timestamp, "2026-07-06T13:46:04Z")

        // A fractional heading survives as a full Double (no truncation).
        XCTAssertEqual(route.routePoints[1].heading, 179.01947972755147, accuracy: 1e-9)
    }

    // MARK: - Empty route ([] — always an array, never null)

    func testDriveRouteDecodesEmptyArrayForVeryShortDrive() async throws {
        let (client, http) = client([.init(status: 200, body: try Fixture.data("rest/drive_route_empty.json"))])

        let route = try await client.driveRoute(id: "clmno0000000000zyxw9999")

        let requests = await http.capturedRequests()
        XCTAssertEqual(requests[0].url?.path, "/api/drives/clmno0000000000zyxw9999/route")

        XCTAssertEqual(route.driveId, "clmno0000000000zyxw9999")
        XCTAssertTrue(route.routePoints.isEmpty, "an empty route is [], branched on .isEmpty")
    }

    // MARK: - True encode -> decode round trip

    func testDriveRouteEncodeDecodeRoundTripsEqual() throws {
        let original = DriveRoute(
            driveId: "clmno9876543210zyxw0001",
            routePoints: [
                RoutePoint(lat: 33.086114, lng: -96.851844, speed: 0, heading: 0, timestamp: "2026-07-06T13:23:54Z"),
                RoutePoint(lat: 32.992545, lng: -96.794208, speed: 12, heading: 181.79747828962422, timestamp: "2026-07-06T13:46:04Z"),
            ]
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DriveRoute.self, from: encoded)
        XCTAssertEqual(decoded, original, "DriveRoute is Equatable and round-trips losslessly")
    }

    func testEmptyDriveRouteRoundTripsEqual() throws {
        let original = DriveRoute(driveId: "clmno0000000000zyxw9999", routePoints: [])
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DriveRoute.self, from: encoded)
        XCTAssertEqual(decoded, original)
        XCTAssertTrue(decoded.routePoints.isEmpty)
    }
}
