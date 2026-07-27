@testable import MyRoboTaxi
import XCTest

// MARK: - MYR-233 acceptance criterion 2 — the instant-request CTA gate
//
// `RideRequestCTAGate` is the pure decision behind the Review sheet's CTA, so
// the gating rule is asserted here without mounting SwiftUI.

final class RideRequestCTAGateTests: XCTestCase {

    // MARK: The normal path is untouched

    /// An available vehicle keeps the gold `outline-draw` "Request from …" CTA —
    /// this is the case every fixture / simulated scene takes, so it must stay
    /// exactly as it was before this issue.
    func testAvailableVehicleKeepsTheInstantCTA() {
        let gate = RideRequestCTAGate(unavailability: nil, isScheduled: false)
        XCTAssertFalse(gate.routesToScheduling)
        XCTAssertTrue(gate.allowsSubmit)
        XCTAssertNil(gate.reason)
    }

    // MARK: Every unavailable state gates the instant CTA

    func testEveryUnavailabilityGatesTheInstantCTAAndRoutesToScheduling() {
        for unavailability in FleetUnavailability.allCases {
            let gate = RideRequestCTAGate(unavailability: unavailability, isScheduled: false)
            XCTAssertTrue(gate.routesToScheduling, "\(unavailability.rawValue) must gate the instant CTA")
            XCTAssertFalse(gate.allowsSubmit, "\(unavailability.rawValue) must block submit")
            XCTAssertEqual(gate.reason, unavailability)
        }
    }

    // MARK: Scheduled requests are EXEMPT

    /// A draft that already carries a schedule is never gated. Scheduled rides
    /// are explicitly outside the busy rule (contracts `hasActiveRide`: "a request
    /// with scheduledFor set … is outside the index and outside this flag no
    /// matter its status"), and an in-service / offline car may well be back by
    /// the requested time — gating it would refuse a request the server accepts.
    func testScheduledRequestIsExemptFromEveryUnavailability() {
        for unavailability in FleetUnavailability.allCases {
            let gate = RideRequestCTAGate(unavailability: unavailability, isScheduled: true)
            XCTAssertFalse(gate.routesToScheduling, "scheduled + \(unavailability.rawValue) must NOT be gated")
            XCTAssertTrue(gate.allowsSubmit)
            XCTAssertNil(gate.reason)
        }
    }

    // MARK: The gate composes with the real mapping

    /// End-to-end through the shipping predicate: a busy live row produces a
    /// gated CTA, and the same row seen by the rider who owns the ride does not.
    func testGateComposesWithTheLiveMappingIncludingTheOwnRideException() {
        let busy = FleetMember(
            id: "veh-1", owner: "Lunar", relationship: "Your Tesla", name: "Model Y",
            model: "2026 Tesla", colorName: "Quicksilver", battery: 68, etaMin: 3,
            plate: "VIN ····2046", isAvailable: false, availabilityWord: "Busy",
            unavailability: .busy
        )
        XCTAssertTrue(RideRequestCTAGate(unavailability: busy.unavailability, isScheduled: false).routesToScheduling)

        let owned = busy.clearingUnavailability()
        XCTAssertFalse(
            RideRequestCTAGate(unavailability: owned.unavailability, isScheduled: false).routesToScheduling,
            "the rider who owns the open ride keeps their normal instant CTA"
        )
    }
}
