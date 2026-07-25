import CoreLocation
@testable import MyRoboTaxi
import MyRobotaxiContracts
import XCTest

// MARK: - MYR-264 — no fixture personas/vehicles on the live incoming-request path
//
// Two things proven here:
//  1. `RideRequestContractMapping.record(from:)` PRESERVES the real wire identity
//     (`vehicleId`, `requesterName`) instead of substituting `RideRequestFixtures
//     .fleet[0]` / a hardcoded "Sam".
//  2. `IncomingRequestDisplay.resolve` — the single gated resolver the owner sheet
//     + accept toast both consume — renders the real rider name + real fleet-join
//     vehicle on live (neutral / hidden when absent), and the fixture persona +
//     fixture vehicle in sim (pixel-identical to M1).
final class IncomingRequestLiveIdentityTests: XCTestCase {

    private let pickup = CLLocationCoordinate2D(latitude: 32.7767, longitude: -96.7970)
    private let dropoff = CLLocationCoordinate2D(latitude: 33.1507, longitude: -96.8236)

    private func wireRide(
        vehicleId: String = "veh-live",
        requesterName: String? = "Jamie Rivera",
        status: MyRobotaxiContracts.RideRequestStatus = .requested
    ) -> RideRequest {
        RideRequest(
            id: "srv-live-1",
            riderId: "u-rider",
            ownerId: "u-owner",
            vehicleId: vehicleId,
            pickup: MyRobotaxiContracts.RidePlace(lat: pickup.latitude, lng: pickup.longitude, label: "1200 Grandscape Blvd"),
            dropoff: MyRobotaxiContracts.RidePlace(lat: dropoff.latitude, lng: dropoff.longitude, label: "Bell Southstone Yards"),
            status: status,
            createdAt: "2026-07-09T18:00:00.000Z",
            updatedAt: "2026-07-09T18:00:00.000Z",
            acceptedAt: nil,
            requesterName: requesterName
        )
    }

    private func liveVehicle(id: String = "veh-live", name: String = "Lunar") -> Vehicle {
        Vehicle(
            id: id,
            name: name,
            model: "Model Y",
            colorName: "Quicksilver",
            plate: "",
            seatHeat: false,
            seatVent: false,
            activity: .parked(ParkedLocation(
                label: "Home",
                coordinate: pickup,
                parkedSince: Date()
            ))
        )
    }

    // MARK: - Mapping preserves real identity

    func testMappingPreservesRealVehicleId() throws {
        let record = try XCTUnwrap(RideRequestContractMapping.record(from: wireRide()))
        // The real vehicle id is preserved (was overwritten with the fixture fleet[0].id).
        XCTAssertEqual(record.input.fleetMemberID, "veh-live")
        XCTAssertNotEqual(record.input.fleetMemberID, RideRequestFixtures.fleet[0].id)
    }

    func testMappingPreservesRealRequesterName() throws {
        let record = try XCTUnwrap(RideRequestContractMapping.record(from: wireRide(requesterName: "Jamie Rivera")))
        XCTAssertEqual(record.input.requesterName, "Jamie Rivera")
    }

    func testMappingLeavesRequesterNameNilWhenAbsent() throws {
        let record = try XCTUnwrap(RideRequestContractMapping.record(from: wireRide(requesterName: nil)))
        XCTAssertNil(record.input.requesterName)
    }

    // MARK: - Live display: real name + real vehicle, never fixtures

    func testLiveDisplayUsesRealRiderNameAndVehicleJoin() throws {
        let record = try XCTUnwrap(RideRequestContractMapping.record(from: wireRide(requesterName: "Jamie Rivera")))
        let display = IncomingRequestDisplay.resolve(request: record, isLive: true, liveVehicle: liveVehicle())

        XCTAssertEqual(display.riderName, "Jamie Rivera")
        XCTAssertEqual(display.avatarInitial, "J")
        XCTAssertEqual(display.title(hasPassenger: false), "Jamie Rivera wants a ride")
        // Real fleet-join vehicle name — never the fixture "Model Y".
        XCTAssertEqual(display.vehicleName, "Lunar")
        XCTAssertNotEqual(display.vehicleName, RideRequestFixtures.fleet[0].name)
        // The wire carries no per-request battery/status → hidden, not asserted.
        XCTAssertNil(display.batteryAfter)
        XCTAssertFalse(display.showsReadyStatus)
    }

    func testLiveDisplayFallsBackToNeutralWhenNameAbsent() throws {
        for absent in [nil, "", "   "] as [String?] {
            let record = try XCTUnwrap(RideRequestContractMapping.record(from: wireRide(requesterName: absent)))
            let display = IncomingRequestDisplay.resolve(request: record, isLive: true, liveVehicle: liveVehicle())

            XCTAssertNil(display.riderName, "requesterName \(String(describing: absent)) should be treated as absent")
            XCTAssertNil(display.avatarInitial) // neutral person glyph, no fabricated initial
            XCTAssertEqual(display.title(hasPassenger: false), "Shared viewer wants a ride")
            XCTAssertEqual(display.riderLabel, "Shared viewer")
        }
    }

    func testLiveDisplayHidesVehicleWhenNotInFleet() throws {
        // A live request whose vehicle isn't in the owner's loaded fleet: no name to
        // show and nothing to fake.
        let record = try XCTUnwrap(RideRequestContractMapping.record(from: wireRide(vehicleId: "veh-unknown")))
        let display = IncomingRequestDisplay.resolve(request: record, isLive: true, liveVehicle: nil)
        XCTAssertNil(display.vehicleName)
    }

    // MARK: - Sim display: fixture persona + fixture vehicle (pixel-identical M1)

    func testSimDisplayKeepsFixturePersonaAndVehicle() {
        let member = RideRequestFixtures.fleet[0] // Alex · Model Y · 68%
        let dest = RideRequestFixtures.recentPlaces[1] // SFO · 18.4 mi
        let input = RideRequestInput(
            pickup: RideRequestFixtures.savedPlaces[0],
            destination: dest,
            fleetMemberID: member.id
        )
        let record = RideRequestRecord(input: input, status: .pending)
        let display = IncomingRequestDisplay.resolve(request: record, isLive: false, liveVehicle: nil)

        XCTAssertEqual(display.riderName, "Sam")
        XCTAssertEqual(display.avatarInitial, "S")
        XCTAssertEqual(display.title(hasPassenger: false), "Sam wants a ride")
        XCTAssertEqual(display.vehicleName, member.name) // "Model Y"
        XCTAssertTrue(display.showsReadyStatus)
        // The fixture battery-after formula: max(10, battery - round(miles*0.7)).
        XCTAssertEqual(display.batteryAfter, max(10, member.battery - Int((dest.miles * 0.7).rounded())))
    }
}
