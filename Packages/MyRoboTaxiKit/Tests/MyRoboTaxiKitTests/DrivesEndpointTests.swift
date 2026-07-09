import XCTest
@testable import MyRoboTaxiKit
import MyRobotaxiContracts

/// Fixture round-trip tests for the drive read-path (rest-api.md §7.2/§7.3):
/// request-path + query-param assembly, `DrivesListResponse` envelope decoding,
/// the absent-location omit-when-empty convention (nil, never ""), and the
/// null-cursor / `hasMore == false` last-page contract. No network — the
/// deterministic `RecordingHTTP` replays canonical fixtures.
final class DrivesEndpointTests: XCTestCase {
    private let devEnvironment = BackendEnvironment(
        restBaseURL: URL(string: "https://api.myrobotaxi.com/api")!,
        webSocketURL: URL(string: "wss://api.myrobotaxi.com/api/ws")!,
        allowsInsecureLoopback: false
    )

    private func client(_ stubs: [RecordingHTTP.Stub]) -> (RestClient, RecordingHTTP) {
        let http = RecordingHTTP(stubs)
        return (RestClient(environment: devEnvironment, tokenProvider: StaticTokenProvider("t"), http: http), http)
    }

    // MARK: - List: path + query + envelope

    func testDrivesTargetsCorrectPathWithDefaultLimit() async throws {
        let (client, http) = client([.init(status: 200, body: try Fixture.data("rest/drives.json"))])

        let page = try await client.drives(vehicleID: "clxyz1234567890abcdef")

        XCTAssertEqual(page.items.count, 2)
        let requests = await http.capturedRequests()
        let components = URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(components.path, "/api/vehicles/clxyz1234567890abcdef/drives")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "limit" })?.value, "20")
        XCTAssertNil(components.queryItems?.first(where: { $0.name == "cursor" }), "no cursor on the first page")
    }

    func testDrivesForwardsCursorAndClampsLimit() async throws {
        let (client, http) = client([.init(status: 200, body: try Fixture.data("rest/drives_last_page.json"))])

        _ = try await client.drives(vehicleID: "v1", cursor: "PAGE2CURSOR", limit: 500)

        let requests = await http.capturedRequests()
        let query = URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
        XCTAssertEqual(query.first(where: { $0.name == "cursor" })?.value, "PAGE2CURSOR")
        XCTAssertEqual(query.first(where: { $0.name == "limit" })?.value, "100", "limit clamps to the 1…100 contract range")
    }

    func testDrivesDecodesEnvelopeAndFirstPageFlags() async throws {
        let (client, _) = client([.init(status: 200, body: try Fixture.data("rest/drives.json"))])

        let page = try await client.drives(vehicleID: "v1")

        XCTAssertTrue(page.hasMore, "page 1 has a following page")
        XCTAssertNotNil(page.nextCursor, "non-null cursor => not the last page")

        let first = page.items[0]
        XCTAssertEqual(first.id, "clmno9876543210zyxw0001")
        XCTAssertEqual(first.distanceMiles, 12.4, accuracy: 0.001)
        XCTAssertEqual(first.durationSeconds, 1458)
        XCTAssertEqual(first.fsdMiles, 8.1, accuracy: 0.001)
        XCTAssertEqual(first.fsdPercentage, 65.3, accuracy: 0.001)
    }

    // MARK: - Absent-location fixture (omit-when-empty => nil, never "")

    func testAbsentLocationKeysDecodeToNilNotEmptyString() async throws {
        let (client, _) = client([.init(status: 200, body: try Fixture.data("rest/drives.json"))])

        let page = try await client.drives(vehicleID: "v1")

        let geocoded = page.items[0]
        XCTAssertEqual(geocoded.startLocation, "Home")
        XCTAssertEqual(geocoded.endLocation, "Whole Foods Market")

        let ungeocoded = page.items[1]
        XCTAssertNil(ungeocoded.startLocation, "omitted key => nil")
        XCTAssertNil(ungeocoded.startAddress)
        XCTAssertNil(ungeocoded.endLocation)
        XCTAssertNil(ungeocoded.endAddress)
        // fsd stats stay present even when the location labels are absent (P0, default 0).
        XCTAssertEqual(ungeocoded.fsdMiles, 0, accuracy: 0.001)
        XCTAssertEqual(ungeocoded.fsdPercentage, 0, accuracy: 0.001)
    }

    // MARK: - Null-cursor last page (hasMore is the paging predicate)

    func testLastPageHasNullCursorAndHasMoreFalse() async throws {
        let (client, _) = client([.init(status: 200, body: try Fixture.data("rest/drives_last_page.json"))])

        let page = try await client.drives(vehicleID: "v1", cursor: "PREV")

        XCTAssertFalse(page.hasMore)
        XCTAssertNil(page.nextCursor, "null nextCursor => the final page has been reached")
        XCTAssertEqual(page.items.count, 1)
    }

    // MARK: - Drive detail (§7.3)

    func testDriveDetailTargetsPathAndDecodesDetailOnlyFields() async throws {
        let (client, http) = client([.init(status: 200, body: try Fixture.data("rest/drive_detail.json"))])

        let drive = try await client.drive(id: "clmno9876543210zyxw0001")

        let requests = await http.capturedRequests()
        XCTAssertEqual(requests[0].url?.path, "/api/drives/clmno9876543210zyxw0001")
        // Detail-only stats absent from DriveSummary.
        XCTAssertEqual(drive.energyUsedKwh, 4.2, accuracy: 0.001)
        XCTAssertEqual(drive.interventions, 1)
        XCTAssertEqual(drive.startLocation, "Home")
        XCTAssertEqual(drive.endLocation, "Whole Foods Market")
    }

    func testDrivesNotFoundMapsToTypedCode() async throws {
        let (client, _) = client([.init(status: 404, body: try Fixture.data("rest/error.not_found.json"))])

        do {
            _ = try await client.drives(vehicleID: "missing")
            XCTFail("expected RestError.http 404")
        } catch let error as RestError {
            guard case .http(let status, let code, _, _) = error else { return XCTFail("wrong case") }
            XCTAssertEqual(status, 404)
            XCTAssertEqual(code, .notFound)
        }
    }
}
