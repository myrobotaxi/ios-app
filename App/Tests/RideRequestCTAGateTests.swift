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

    /// EVERY unavailability blocks submit — that half is universal and is what
    /// keeps a `409 vehicle_unavailable` from ever being POSTed.
    ///
    /// MYR-342 split the other half off. Routing to SCHEDULING is no longer a
    /// property of "being gated", because `paused` gates without offering it (the
    /// server refuses scheduled rides against a paused car too, §7.18). The
    /// scheduling assertion therefore names the three reasons it holds for, rather
    /// than iterating `allCases` and quietly acquiring a fourth — which is exactly
    /// how this test would otherwise have started asserting the wrong thing about a
    /// case it had never heard of.
    func testEveryUnavailabilityBlocksSubmitAndTheEndingOnesRouteToScheduling() {
        for unavailability in FleetUnavailability.allCases {
            let gate = RideRequestCTAGate(unavailability: unavailability, isScheduled: false)
            XCTAssertTrue(gate.isGated, "\(unavailability.rawValue) must gate the instant CTA")
            XCTAssertFalse(gate.allowsSubmit, "\(unavailability.rawValue) must block submit")
            XCTAssertEqual(gate.reason, unavailability)
        }
        for unavailability: FleetUnavailability in [.busy, .inService, .offline] {
            XCTAssertTrue(
                RideRequestCTAGate(unavailability: unavailability, isScheduled: false).routesToScheduling,
                "\(unavailability.rawValue) ends on its own, so scheduling stays the offered alternative"
            )
        }
        XCTAssertFalse(
            RideRequestCTAGate(unavailability: .paused, isScheduled: false).routesToScheduling,
            "an owner's pause is open-ended and blocks scheduling server-side — the CTA area shows helper text alone"
        )
    }

    // MARK: Scheduled requests are EXEMPT

    /// A draft that already carries a schedule is never gated. Scheduled rides
    /// are explicitly outside the busy rule (contracts `hasActiveRide`: "a request
    /// with scheduledFor set … is outside the index and outside this flag no
    /// matter its status"), and an in-service / offline car may well be back by
    /// the requested time — gating it would refuse a request the server accepts.
    ///
    /// MYR-342 — "every" became "every one that ends on its own". rest-api.md §7.18
    /// removes a paused car from this exemption in as many words ("the pause does
    /// NOT inherit that exemption, on any layer") and gives the reason: MYR-313's
    /// argument is that a service visit ENDS, so refusing a reservation days out
    /// would strand the owner over a condition that will have cleared by then. An
    /// owner's pause is open-ended, so exempting reservations would let a rider
    /// book a car withdrawn indefinitely — and would drop the request into the
    /// owner's queue, the treadmill the toggle exists to end.
    func testScheduledRequestIsExemptFromTheThreeReasonsThatEndOnTheirOwn() {
        for unavailability: FleetUnavailability in [.busy, .inService, .offline] {
            let gate = RideRequestCTAGate(unavailability: unavailability, isScheduled: true)
            XCTAssertFalse(gate.routesToScheduling, "scheduled + \(unavailability.rawValue) must NOT be gated")
            XCTAssertTrue(gate.allowsSubmit)
            XCTAssertNil(gate.reason)
        }
    }

    /// ...and the exemption stops at an owner's pause.
    func testScheduledRequestIsNotExemptFromAPause() {
        let gate = RideRequestCTAGate(unavailability: .paused, isScheduled: true)
        XCTAssertEqual(gate.reason, .paused)
        XCTAssertFalse(gate.allowsSubmit, "the server refuses scheduled rides against a paused car too (§7.18)")
        XCTAssertFalse(gate.routesToScheduling)
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
