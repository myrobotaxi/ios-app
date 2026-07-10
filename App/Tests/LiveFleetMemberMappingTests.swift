@testable import MyRoboTaxi
import MyRobotaxiContracts
import XCTest

// MARK: - MYR-212 deliverable 4 — live vehicle → FleetMember join

final class LiveFleetMemberMappingTests: XCTestCase {

    private func summary(status: VehicleSummary.Status = .parked, name: String = "Lunar",
                         vinLast4: String = "2046", charge: Int = 82) -> VehicleSummary {
        VehicleSummary(vehicleId: "veh-1", name: name, model: "Model Y", year: 2025, color: "Quicksilver",
                       vinLast4: vinLast4, status: status, chargeLevel: charge, estimatedRange: 210,
                       lastUpdated: "2026-07-09T18:00:00Z", role: .owner)
    }

    func testMapsRealIdentityBatteryAndVinPlate() {
        let member = LiveFleetMemberMapping.fleetMember(from: summary())
        XCTAssertEqual(member.id, "veh-1")
        XCTAssertEqual(member.owner, "Lunar")        // nickname stands in for owner display name
        XCTAssertEqual(member.name, "Model Y")
        XCTAssertEqual(member.colorName, "Quicksilver")
        XCTAssertEqual(member.battery, 82)            // real charge, not fixture 68
        XCTAssertEqual(member.plate, "VIN ····2046")  // VIN-last-4 plate degrade
        XCTAssertTrue(member.isAvailable)
        XCTAssertEqual(member.availabilityWord, "Available")
    }

    func testEmptyVinHidesThePlateChip() {
        let member = LiveFleetMemberMapping.fleetMember(from: summary(vinLast4: ""))
        XCTAssertEqual(member.plate, "", "empty VIN → empty plate → chip hidden by the caller")
    }

    func testAvailabilityReflectsLiveStatus() {
        XCTAssertTrue(LiveFleetMemberMapping.isAvailable(.parked))
        XCTAssertTrue(LiveFleetMemberMapping.isAvailable(.charging))
        XCTAssertFalse(LiveFleetMemberMapping.isAvailable(.driving))
        XCTAssertFalse(LiveFleetMemberMapping.isAvailable(.offline))

        let driving = LiveFleetMemberMapping.fleetMember(from: summary(status: .driving))
        XCTAssertFalse(driving.isAvailable)
        XCTAssertEqual(driving.availabilityWord, "Driving")
    }

    func testFallsBackToModelWhenNicknameEmpty() {
        let member = LiveFleetMemberMapping.fleetMember(from: summary(name: ""))
        XCTAssertEqual(member.owner, "Model Y") // nickname empty → model name
    }
}
