import CoreLocation
@testable import MyRoboTaxi
import MyRobotaxiContracts
import XCTest

// MARK: - MYR-229 — owner sees the real requester's name

// Backend + contracts v0.11.0 add optional `requesterName` to the wire
// `RideRequest` (server-side "first name -> email local-part -> Rider"
// fallback). Before this fix, `IncomingRequestSheet` rendered a hardcoded
// fixture persona ("Sam") on EVERY path, including live — a "no fixtures on
// the live path" violation (CLAUDE.md). `RideRequestContractMapping
// .record(from:)` now folds the wire field onto `RideRequestRecord
// .requesterName`, and `RideRequestRecord.requesterDisplayName` is the ONE
// place the "Sam" fallback is spelled (consumed by `IncomingRequestSheet`
// and `HomeScreen.handleAccept`'s scheduled-owner-card/toast copy).
final class RequesterNameMappingTests: XCTestCase {

    private let pickup = CLLocationCoordinate2D(latitude: 37.7793, longitude: -122.3937)
    private let dropoff = CLLocationCoordinate2D(latitude: 37.6156, longitude: -122.3900)

    private func wireRide(requesterName: String?) -> RideRequest {
        RideRequest(
            id: "srv-live-requester",
            riderId: "u-rider",
            ownerId: "u-owner",
            vehicleId: "veh-live",
            pickup: MyRobotaxiContracts.RidePlace(lat: pickup.latitude, lng: pickup.longitude, label: "Current location"),
            dropoff: MyRobotaxiContracts.RidePlace(lat: dropoff.latitude, lng: dropoff.longitude, label: "SFO \u{00B7} Terminal 2"),
            status: .requested,
            createdAt: "2026-07-09T18:00:00.000Z",
            updatedAt: "2026-07-09T18:00:00.000Z",
            acceptedAt: nil,
            requesterName: requesterName
        )
    }

    /// Present on the wire (the common case — the server almost always
    /// resolves a name) → shown verbatim, not the fixture.
    func testLiveWireRecordUsesRequesterNameWhenPresent() throws {
        let record = try XCTUnwrap(RideRequestContractMapping.record(from: wireRide(requesterName: "Thomas")))
        XCTAssertEqual(record.requesterName, "Thomas")
        XCTAssertEqual(record.requesterDisplayName, "Thomas")
    }

    /// OPTIONAL/additive field omitted (identity lookup hasn't resolved a
    /// name yet) → an honest "Rider", NEVER a fixture persona.
    func testLiveWireRecordFallsBackToRiderWhenAbsent() throws {
        let record = try XCTUnwrap(RideRequestContractMapping.record(from: wireRide(requesterName: nil)))
        XCTAssertEqual(record.requesterName, "Rider")
        XCTAssertEqual(record.requesterDisplayName, "Rider")
        XCTAssertNotEqual(record.requesterDisplayName, "Sam")
    }

    /// The simulated path builds the record directly (never routes through
    /// `record(from:)`), so `requesterName` stays `nil` and
    /// `requesterDisplayName` keeps rendering the fixture "Sam" — the
    /// drift-gate `ownerIncoming` scene stays pixel-identical.
    func testSimFixtureRecordKeepsFixtureRequesterName() {
        let input = RideRequestInput(
            pickup: RideRequestFixtures.savedPlaces[0],
            destination: RideRequestFixtures.recentPlaces[1],
            fleetMemberID: RideRequestFixtures.fleet[0].id
        )
        let record = RideRequestRecord(input: input, status: .pending)
        XCTAssertNil(record.requesterName)
        XCTAssertEqual(record.requesterDisplayName, "Sam")
    }
}
