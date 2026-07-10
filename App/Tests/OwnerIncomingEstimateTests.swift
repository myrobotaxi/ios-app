import CoreLocation
@testable import MyRoboTaxi
import MyRobotaxiContracts
import XCTest

// MARK: - MYR-219 deliverable 1 — owner incoming card trip estimates
//
// The owner's `IncomingRequestSheet` route card renders DISTANCE / DRIVE TIME
// from `request.input.destination.miles`/`.minutes`. A LIVE request arrives over
// the wire with NO miles/minutes (routing is MYR-176/177), so those mapped to 0
// and the card read "DISTANCE 0.0 mi / DRIVE TIME ~0 min" (client dual-simulator
// QA). `RideRequestContractMapping.record(from:)` now fills the destination
// estimate client-side from the pickup→dropoff coordinates via `TripEstimate`.
// The sim/fixture path never routes through `record(from:)`, so its baked values
// are unaffected — proven by the second test.
final class OwnerIncomingEstimateTests: XCTestCase {

    // Real coordinates (~25 mi apart) so a straight-line ×1.3 detour estimate is
    // clearly non-zero.
    private let pickup = CLLocationCoordinate2D(latitude: 32.7767, longitude: -96.7970) // downtown Dallas
    private let dropoff = CLLocationCoordinate2D(latitude: 33.1507, longitude: -96.8236) // Frisco

    private func wireRide(status: MyRobotaxiContracts.RideRequestStatus = .requested) -> RideRequest {
        RideRequest(
            id: "srv-live-1",
            riderId: "u-rider",
            ownerId: "u-owner",
            vehicleId: "veh-live",
            pickup: MyRobotaxiContracts.RidePlace(lat: pickup.latitude, lng: pickup.longitude, label: "1200 Grandscape Blvd"),
            dropoff: MyRobotaxiContracts.RidePlace(lat: dropoff.latitude, lng: dropoff.longitude, label: "Bell Southstone Yards"),
            status: status,
            createdAt: "2026-07-09T18:00:00.000Z",
            updatedAt: "2026-07-09T18:00:00.000Z",
            acceptedAt: nil
        )
    }

    func testLiveWireRecordFillsNonZeroDestinationEstimate() throws {
        let record = try XCTUnwrap(RideRequestContractMapping.record(from: wireRide()))
        let dest = record.input.destination

        // The card would no longer show 0.0 mi / ~0 min.
        XCTAssertGreaterThan(dest.miles, 0)
        XCTAssertGreaterThan(dest.minutes, 0)
        // It's exactly the client-side closed-form estimate for these coordinates.
        let expected = TripEstimate.estimate(from: pickup, to: dropoff)
        XCTAssertEqual(dest.miles, expected.miles, accuracy: 0.001)
        XCTAssertEqual(dest.minutes, expected.minutes)
        // Identity is preserved — only miles/minutes were filled.
        XCTAssertEqual(dest.label, "Bell Southstone Yards")
        XCTAssertEqual(dest.coordinate.latitude, dropoff.latitude, accuracy: 0.0001)
    }

    func testSimFixtureRecordKeepsBakedEstimate() {
        // The simulated path builds the record directly from a fixture destination
        // (baked miles/minutes) and never routes through `record(from:)` — so the
        // owner card keeps the fixture numbers and the sim scene is unchanged.
        let fixtureDest = RideRequestFixtures.recentPlaces[1] // SFO · Terminal 2 — 18.4 mi / 32 min
        XCTAssertGreaterThan(fixtureDest.minutes, 0)
        let input = RideRequestInput(
            pickup: RideRequestFixtures.savedPlaces[0],
            destination: fixtureDest,
            fleetMemberID: RideRequestFixtures.fleet[0].id
        )
        let record = RideRequestRecord(input: input, status: .pending)
        XCTAssertEqual(record.input.destination.miles, fixtureDest.miles, accuracy: 0.0001)
        XCTAssertEqual(record.input.destination.minutes, fixtureDest.minutes)
    }
}
