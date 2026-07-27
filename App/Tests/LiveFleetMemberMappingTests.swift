@testable import MyRoboTaxi
import MyRobotaxiContracts
import XCTest

// MARK: - MYR-212 deliverable 4 — live vehicle → FleetMember join

final class LiveFleetMemberMappingTests: XCTestCase {

    /// `hasActiveRide` defaults to `nil` — i.e. ABSENT, the older-server shape —
    /// so every pre-MYR-233 expectation below is also a tolerant-decode assertion.
    private func summary(status: VehicleSummary.Status = .parked, name: String = "Lunar",
                         vinLast4: String = "2046", charge: Int = 82,
                         hasActiveRide: Bool? = nil) -> VehicleSummary {
        VehicleSummary(vehicleId: "veh-1", name: name, model: "Model Y", year: 2025, color: "Quicksilver",
                       vinLast4: vinLast4, status: status, chargeLevel: charge, estimatedRange: 210,
                       lastUpdated: "2026-07-09T18:00:00Z", role: .owner, hasActiveRide: hasActiveRide)
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

    // MARK: MYR-214 — nickname is the row's primary identity, model is separate

    /// The Review vehicle row names the live car by its nickname as the PRIMARY
    /// line ("Lunar") and keeps the model ("Model Y") as a separate field for the
    /// subline — never the possessive "Lunar's Model Y" (client QA, MYR-214). The
    /// mapping supplies both as distinct fields so the view can render two lines.
    func testNicknameAndModelAreDistinctFieldsForTheRow() {
        let member = LiveFleetMemberMapping.fleetMember(from: summary(name: "Lunar"))
        XCTAssertEqual(member.owner, "Lunar")  // primary line
        XCTAssertEqual(member.name, "Model Y") // subline model — not folded into a possessive
        XCTAssertNotEqual(member.owner, "\(member.owner)\u{2019}s \(member.name)")
    }

    // MARK: - MYR-233 — the rider availability predicate
    //
    // The full truth table for
    //   `hasActiveRide == true || status ∈ { inService, offline }`
    // minus the own-ride exception. Four wire statuses × three `hasActiveRide`
    // values (true / false / ABSENT) × the own-ride exception.

    /// The matrix, exhaustively. Each row is (status, hasActiveRide, expected).
    func testUnavailabilityPredicateAcrossEveryStatusAndFlag() {
        let cases: [(VehicleSummary.Status, Bool?, FleetUnavailability?)] = [
            // Bookable statuses: ONLY an explicit `true` makes them Busy.
            (.parked, nil, nil), (.parked, false, nil), (.parked, true, .busy),
            (.charging, nil, nil), (.charging, false, nil), (.charging, true, .busy),
            // `driving` is deliberately NOT gated by status (MYR-212 already
            // renders it "not bookable now"); it is gated only by an open ride.
            (.driving, nil, nil), (.driving, false, nil), (.driving, true, .busy),
            // Status-driven states win regardless of the flag — including when it
            // is absent, because the STATUS alone is enough to know.
            (.inService, nil, .inService), (.inService, false, .inService), (.inService, true, .inService),
            (.offline, nil, .offline), (.offline, false, .offline), (.offline, true, .offline),
        ]
        for (status, flag, expected) in cases {
            XCTAssertEqual(
                LiveFleetMemberMapping.unavailability(status: status, hasActiveRide: flag),
                expected,
                "status \(status.rawValue) + hasActiveRide \(String(describing: flag))"
            )
        }
    }

    /// Acceptance criterion 5 — an ABSENT `hasActiveRide` (older server) means
    /// "availability unknown → treat as available". Busy must NEVER be rendered
    /// from absence. `false` behaves identically.
    func testAbsentHasActiveRideIsTreatedAsAvailableNeverBusy() {
        for flag: Bool? in [nil, false] {
            let member = LiveFleetMemberMapping.fleetMember(from: summary(hasActiveRide: flag))
            XCTAssertNil(member.unavailability, "absent/false must never produce Busy")
            XCTAssertTrue(member.isRequestable)
            XCTAssertTrue(member.isAvailable)
            XCTAssertEqual(member.availabilityWord, "Available")
        }
    }

    /// Acceptance criterion 1 — `hasActiveRide == true` on an otherwise bookable
    /// car yields Busy, and folds onto MYR-212's dot/word pair so the row cannot
    /// simultaneously claim "Available".
    func testActiveRideOnParkedVehicleRendersBusy() {
        let member = LiveFleetMemberMapping.fleetMember(from: summary(hasActiveRide: true))
        XCTAssertEqual(member.unavailability, .busy)
        XCTAssertEqual(member.unavailability?.word, "Busy")
        XCTAssertFalse(member.isRequestable)
        XCTAssertFalse(member.isAvailable, "a busy car is never the green 'Available now' dot")
        XCTAssertEqual(member.availabilityWord, "Busy")
        // Identity is untouched — only availability affordances change.
        XCTAssertEqual(member.owner, "Lunar")
        XCTAssertEqual(member.name, "Model Y")
        XCTAssertEqual(member.battery, 82)
    }

    /// Acceptance criterion 1 — the two status-driven unavailable states use
    /// status-appropriate wording, not "Busy".
    func testInServiceAndOfflineUseStatusAppropriateWording() {
        let inService = LiveFleetMemberMapping.fleetMember(from: summary(status: .inService))
        XCTAssertEqual(inService.unavailability, .inService)
        XCTAssertEqual(inService.availabilityWord, "In service")
        XCTAssertFalse(inService.isRequestable)

        let offline = LiveFleetMemberMapping.fleetMember(from: summary(status: .offline))
        XCTAssertEqual(offline.unavailability, .offline)
        XCTAssertEqual(offline.availabilityWord, "Offline")
        XCTAssertFalse(offline.isRequestable)
    }

    /// Acceptance criterion 4 — the rider who OWNS the open ride never sees Busy.
    func testOwnRideExceptionSuppressesBusy() {
        XCTAssertNil(
            LiveFleetMemberMapping.unavailability(status: .parked, hasActiveRide: true, riderOwnsActiveRide: true),
            "the rider holding the open ride sees their active ride, never Busy"
        )
        XCTAssertEqual(
            LiveFleetMemberMapping.unavailability(status: .driving, hasActiveRide: true, riderOwnsActiveRide: true),
            nil,
            "same while the car is driving them"
        )
    }

    /// ...but the exception is scoped to `busy` ONLY. A car that is in service or
    /// offline is unavailable to everyone, including the rider mid-ride — saying
    /// otherwise would be dishonest.
    func testOwnRideExceptionDoesNotMaskInServiceOrOffline() {
        XCTAssertEqual(
            LiveFleetMemberMapping.unavailability(status: .inService, hasActiveRide: true, riderOwnsActiveRide: true),
            .inService
        )
        XCTAssertEqual(
            LiveFleetMemberMapping.unavailability(status: .offline, hasActiveRide: true, riderOwnsActiveRide: true),
            .offline
        )
    }

    /// `clearingUnavailability()` is how the own-ride exception is applied at the
    /// read seam. Clearing `busy` restores the full MYR-212 "Available" row.
    func testClearingBusyRestoresTheAvailableRow() {
        let busy = LiveFleetMemberMapping.fleetMember(from: summary(hasActiveRide: true))
        let cleared = busy.clearingUnavailability()
        XCTAssertNil(cleared.unavailability)
        XCTAssertTrue(cleared.isRequestable)
        XCTAssertTrue(cleared.isAvailable)
        XCTAssertEqual(cleared.availabilityWord, "Available")
        // Identity survives the fold.
        XCTAssertEqual(cleared.id, busy.id)
        XCTAssertEqual(cleared.owner, busy.owner)
        XCTAssertEqual(cleared.battery, busy.battery)
    }

    /// Fixtures carry no unavailability, which is exactly what keeps every
    /// simulated / DEBUG scene pixel-identical (CLAUDE.md's fixture rule).
    func testFixtureFleetIsAlwaysRequestable() {
        for member in RideRequestFixtures.fleet {
            XCTAssertNil(member.unavailability, "\(member.id) must stay a plain available fixture row")
            XCTAssertTrue(member.isRequestable)
        }
    }
}
