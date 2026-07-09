import Foundation
@testable import MyRoboTaxi
import MyRoboTaxiKit
import MyRobotaxiContracts
import XCTest

// MARK: - MYR-203 deliverable 3 — drive contracts → view model
//
// DriveSummary / Drive fixtures → the app's `Drive` view model, covering the
// absent-location omit-when-empty degrade, the authoritative fsd%, the
// seconds→minutes conversion, day-grouping, and (via `LiveDrivesFeed`) the
// hasMore cursor-paging predicate. Pure Swift-value transforms + a deterministic
// HTTP stub — no network.
final class DriveContractMappingTests: XCTestCase {

    // A fixed "now" so relative day-grouping is deterministic: 2026-04-14 noon UTC.
    private let now = ISO8601DateFormatter().date(from: "2026-04-14T12:00:00Z")!

    private func summary(
        id: String = "d1",
        startTime: String = "2026-04-13T18:22:00Z",
        endTime: String = "2026-04-13T18:46:18Z",
        date: String = "2026-04-13",
        startLocation: String? = "Home",
        startAddress: String? = "742 Evergreen Terrace, San Francisco, CA 94107",
        endLocation: String? = "Whole Foods Market",
        endAddress: String? = "399 4th Street, San Francisco, CA 94107",
        distanceMiles: Double = 12.4,
        durationSeconds: Int = 1458,
        avgSpeedMph: Double = 30.5,
        maxSpeedMph: Double = 65.2,
        startChargeLevel: Int = 82,
        endChargeLevel: Int = 76,
        fsdMiles: Double = 8.1,
        fsdPercentage: Double = 65.3
    ) -> DriveSummary {
        DriveSummary(
            id: id, vehicleId: "v1", startTime: startTime, endTime: endTime, date: date,
            startLocation: startLocation, startAddress: startAddress,
            endLocation: endLocation, endAddress: endAddress,
            distanceMiles: distanceMiles, durationSeconds: durationSeconds,
            avgSpeedMph: avgSpeedMph, maxSpeedMph: maxSpeedMph,
            startChargeLevel: startChargeLevel, endChargeLevel: endChargeLevel,
            fsdMiles: fsdMiles, fsdPercentage: fsdPercentage, createdAt: endTime
        )
    }

    // MARK: Full-location summary → view model

    func testSummaryMapsCoreStats() {
        let drive = DriveContractMapping.appDrive(from: summary(), now: now)
        XCTAssertEqual(drive.id, "d1")
        XCTAssertEqual(drive.from, "Home")
        XCTAssertEqual(drive.to, "Whole Foods Market")
        XCTAssertEqual(drive.miles, 12.4, accuracy: 0.001)
        XCTAssertEqual(drive.mins, 24, "1458s → 24 min (rounded)")
        XCTAssertEqual(drive.avgSpeedMPH, 31, "30.5 → 31 rounded")
        XCTAssertEqual(drive.maxSpeedMPH, 65)
        XCTAssertEqual(drive.startChargePercent, 82)
        XCTAssertEqual(drive.endChargePercent, 76)
        XCTAssertEqual(drive.batteryDeltaPercent, -6, "76 − 82")
        XCTAssertTrue(drive.route.isEmpty, "v0.6.0 carries no route coordinates")
    }

    func testFsdPercentPrefersAuthoritativeWireValue() {
        // Wire fsdPercentage 65.3 → 65, NOT the fixture's fsdMiles/miles (65.3% too,
        // but the override path is what's exercised).
        let drive = DriveContractMapping.appDrive(from: summary(fsdMiles: 8.1, fsdPercentage: 65.3), now: now)
        XCTAssertEqual(drive.fsdPercentOverride, 65)
        XCTAssertEqual(drive.fsdPercent, 65)
    }

    func testZeroMileDriveHasNoFsdDivideByZero() {
        let drive = DriveContractMapping.appDrive(
            from: summary(distanceMiles: 0, fsdMiles: 0, fsdPercentage: 0), now: now
        )
        XCTAssertEqual(drive.fsdPercent, 0, "guarded — no NaN → Int crash")
    }

    // MARK: Absent-location degrade

    func testAbsentNameDegradesToAddressThenNeutral() {
        // Name nil but address present → address, trimmed to street + city
        // (MYR-208) so the row's one-line "A → B" fits both endpoints.
        let addressOnly = DriveContractMapping.appDrive(
            from: summary(startLocation: nil, endLocation: nil), now: now
        )
        XCTAssertEqual(addressOnly.from, "742 Evergreen Terrace, San Francisco")
        XCTAssertEqual(addressOnly.to, "399 4th Street, San Francisco")

        // Both name and address nil → neutral fallback.
        let ungeocoded = DriveContractMapping.appDrive(
            from: summary(startLocation: nil, startAddress: nil, endLocation: nil, endAddress: nil),
            now: now
        )
        XCTAssertEqual(ungeocoded.from, DriveContractMapping.unnamedLocation)
        XCTAssertEqual(ungeocoded.to, DriveContractMapping.unnamedLocation)
    }

    func testShortAddressKeepsStreetAndCityOnly() {
        // The live-data shape that motivated MYR-208.
        XCTAssertEqual(
            DriveContractMapping.shortAddress("4222 Stratus Way, Frisco, Texas 75034, United States"),
            "4222 Stratus Way, Frisco"
        )
        // Fewer than three components → not a raw postal address; verbatim.
        XCTAssertEqual(DriveContractMapping.shortAddress("Ferry Building"), "Ferry Building")
        XCTAssertEqual(DriveContractMapping.shortAddress("Katy Trail, Dallas"), "Katy Trail, Dallas")
    }

    func testServerPlaceNameBypassesTrim() {
        // A server-provided place name (MYR-206) with commas is a NAME, not an
        // address — it must pass through label() untouched.
        XCTAssertEqual(
            DriveContractMapping.label(name: "Whole Foods Market, Preston Rd, Frisco", address: nil),
            "Whole Foods Market, Preston Rd, Frisco"
        )
    }

    // MARK: Day grouping

    func testDateGroupTodayYesterdayAndLiteral() {
        // now = 2026-04-14. A same-day drive → "today"; prior day → "yesterday";
        // older → a literal "EEE, MMM d" key (maps through Drive.groupLabel).
        let today = DriveContractMapping.appDrive(
            from: summary(startTime: "2026-04-14T09:00:00Z", date: "2026-04-14"), now: now
        )
        XCTAssertEqual(today.dateGroup, "today")
        XCTAssertEqual(Drive.groupLabel(for: today.dateGroup), "Today")

        let yesterday = DriveContractMapping.appDrive(from: summary(), now: now) // 04-13
        XCTAssertEqual(yesterday.dateGroup, "yesterday")

        let older = DriveContractMapping.appDrive(
            from: summary(startTime: "2026-05-04T13:48:00Z", date: "2026-05-04"), now: now
        )
        // Literal weekday key passes through groupLabel unchanged.
        XCTAssertEqual(Drive.groupLabel(for: older.dateGroup), older.dateGroup)
        XCTAssertTrue(older.dateGroup.contains("May"), "literal 'EEE, MMM d' key: \(older.dateGroup)")
    }

    // MARK: Drive detail → view model

    func testDetailMapsAndDropsDetailOnlyStats() {
        let detail = MyRobotaxiContracts.Drive(
            id: "d9", vehicleId: "v1",
            startTime: "2026-04-13T18:22:00Z", endTime: "2026-04-13T18:46:18Z", date: "2026-04-13",
            distanceMiles: 12.4, durationSeconds: 1458, avgSpeedMph: 30.5, maxSpeedMph: 65.2,
            energyUsedKwh: 4.2, startChargeLevel: 82, endChargeLevel: 76,
            fsdMiles: 8.1, fsdPercentage: 65.3, interventions: 1,
            startLocation: "Home", startAddress: "742 Evergreen Terrace",
            endLocation: nil, endAddress: nil, createdAt: "2026-04-13T18:46:19Z"
        )
        let drive = DriveContractMapping.appDrive(from: detail, now: now)
        XCTAssertEqual(drive.id, "d9")
        XCTAssertEqual(drive.from, "Home")
        XCTAssertEqual(drive.to, DriveContractMapping.unnamedLocation, "absent end → neutral")
        XCTAssertEqual(drive.fsdPercentOverride, 65)
        XCTAssertEqual(drive.mins, 24)
    }

    // MARK: LiveDrivesFeed — hasMore cursor paging

    @MainActor
    func testFeedFirstPageSetsHasMoreAndMapsRows() async throws {
        let page = DrivesListResponse(items: [summary(id: "a"), summary(id: "b")], nextCursor: "CUR", hasMore: true)
        let http = SequencedHTTP([encoded(page)])
        let feed = LiveDrivesFeed(rest: makeRest(http), vehicleID: "v1")

        feed.loadInitial()
        await settle(feed)

        XCTAssertEqual(feed.drives.map(\.id), ["a", "b"])
        XCTAssertTrue(feed.hasMore, "nextCursor present → more pages")
        XCTAssertNotNil(feed.drive(id: "a"), "row is tap-through addressable")
    }

    @MainActor
    func testFeedPaginatesThenStopsOnNullCursor() async throws {
        let page1 = DrivesListResponse(items: [summary(id: "a")], nextCursor: "CUR", hasMore: true)
        let page2 = DrivesListResponse(items: [summary(id: "b")], nextCursor: nil, hasMore: false)
        let http = SequencedHTTP([encoded(page1), encoded(page2)])
        let feed = LiveDrivesFeed(rest: makeRest(http), vehicleID: "v1")

        feed.loadInitial()
        await settle(feed)
        XCTAssertTrue(feed.hasMore)

        feed.loadMore()
        await settle(feed)

        XCTAssertEqual(feed.drives.map(\.id), ["a", "b"], "page 2 appended")
        XCTAssertFalse(feed.hasMore, "null cursor / hasMore=false → last page")
    }

    @MainActor
    func testFeedRefreshReloadsFirstPage() async throws {
        let initial = DrivesListResponse(items: [summary(id: "a")], nextCursor: nil, hasMore: false)
        let afterDrive = DrivesListResponse(items: [summary(id: "new"), summary(id: "a")], nextCursor: nil, hasMore: false)
        let http = SequencedHTTP([encoded(initial), encoded(afterDrive)])
        let feed = LiveDrivesFeed(rest: makeRest(http), vehicleID: "v1")

        feed.loadInitial()
        await settle(feed)
        XCTAssertEqual(feed.drives.map(\.id), ["a"])

        feed.refresh() // simulates a drive_ended arriving
        await settle(feed)
        XCTAssertEqual(feed.drives.map(\.id), ["new", "a"], "completed drive at the head, no manual re-fetch")
    }

    // MARK: - Helpers

    private func encoded(_ page: DrivesListResponse) -> Data {
        // swiftlint:disable:next force_try
        try! JSONEncoder().encode(page)
    }

    private func makeRest(_ http: SequencedHTTP) -> RestClient {
        RestClient(environment: .test, tokenProvider: StaticTokenProvider("t"), http: http)
    }

    /// Spin the run loop until the feed's in-flight page fetch settles (the stub
    /// resolves synchronously, so a handful of yields suffices).
    @MainActor
    private func settle(_ feed: LiveDrivesFeed) async {
        for _ in 0..<200 {
            if !feed.isLoading { return }
            await Task.yield()
        }
    }
}

/// Deterministic `HTTPPerforming` that replays a scripted response sequence.
/// (App-target twin of the Kit test's `RecordingHTTP`; the App tests can't see
/// the Kit test target's doubles.)
actor SequencedHTTP: HTTPPerforming {
    private var bodies: [Data]
    init(_ bodies: [Data]) { self.bodies = bodies }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let body = bodies.isEmpty ? Data() : bodies.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }
}
