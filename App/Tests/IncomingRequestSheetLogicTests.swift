import CoreLocation
import DesignSystem
@testable import MyRoboTaxi
import XCTest

// MARK: - MYR-277 A2 + C — owner incoming-request sheet logic
//
// Pure, SwiftUI-free coverage of the `IncomingRequestSheet` decisions this issue
// changes:
//  • A2 — the car→pickup leg is estimated from the target vehicle's live position
//    and the pickup coordinate (real data only, MYR-228); no car position (SIM /
//    no fix) omits the leg.
//  • A2 — dispatch v2 copy: LIVE says the car routes to the PICKUP first; SIM keeps
//    the M1 prototype copy verbatim (drift-gate pixel-identity).
//  • C — Accept is gated (with an honest reason) when the target vehicle is
//    in_service/offline, and enabled when it's parked/charging/driving.
final class IncomingRequestSheetLogicTests: XCTestCase {

    // Car ~0.9 mi (straight line) from the pickup — a clearly non-zero leg.
    private let carPosition = CLLocationCoordinate2D(latitude: 37.7793, longitude: -122.3937)
    private let pickup = CLLocationCoordinate2D(latitude: 37.7871, longitude: -122.3971)

    // MARK: A2 — car→pickup leg estimate

    func testPickupLegEstimatedFromCarPositionAndPickup() throws {
        let leg = try XCTUnwrap(IncomingRequestSheet.pickupLegEstimate(carPosition: carPosition, pickup: pickup))
        // It's exactly the shared closed-form estimate between the two points.
        let expected = TripEstimate.estimate(from: carPosition, to: pickup)
        XCTAssertEqual(leg.miles, expected.miles, accuracy: 0.0001)
        XCTAssertEqual(leg.minutes, expected.minutes)
        XCTAssertGreaterThan(leg.miles, 0)
        XCTAssertGreaterThanOrEqual(leg.minutes, 1)
    }

    func testPickupLegOmittedWithoutCarPosition() {
        // SIM / unloaded vehicle → no car position → single-leg fallback (pixel-identical M1).
        XCTAssertNil(IncomingRequestSheet.pickupLegEstimate(carPosition: nil, pickup: pickup))
    }

    func testPickupLegOmittedForNoFixSentinel() {
        // The "0,0 = no fix" convention (§2.3) must never estimate a Gulf-of-Guinea leg.
        let noFix = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        XCTAssertNil(IncomingRequestSheet.pickupLegEstimate(carPosition: noFix, pickup: pickup))
    }

    // MARK: A2 — dispatch v2 accept copy

    func testLiveNowRideCopyRoutesToPickupFirst() {
        let copy = IncomingRequestSheet.nowRideCopy(isLive: true, vehicleName: "Lunar", destination: "SFO · Terminal 2")
        XCTAssertEqual(copy, "Accepting routes Lunar to the pickup, then to SFO · Terminal 2.")
        // The v1 "route to <destination>" wording is gone.
        XCTAssertFalse(copy.contains("route Lunar to SFO"))
    }

    func testLiveNowRideCopyNeutralWhenVehicleNameAbsent() {
        let copy = IncomingRequestSheet.nowRideCopy(isLive: true, vehicleName: nil, destination: "SFO · Terminal 2")
        XCTAssertEqual(copy, "Accepting dispatches to the pickup, then to SFO · Terminal 2.")
    }

    func testSimNowRideCopyKeepsM1Wording() {
        // SIM path (drift-gate `ownerIncoming`) must be byte-identical to M1.
        let copy = IncomingRequestSheet.nowRideCopy(isLive: false, vehicleName: "Model Y", destination: "SFO · Terminal 2")
        XCTAssertEqual(copy, "Accepting will route Model Y to SFO · Terminal 2.")
    }

    func testPassengerCopyLiveAddsPickupRouteNote() {
        let copy = IncomingRequestSheet.passengerCopy(isLive: true, isScheduled: false, vehicleName: "Lunar", passengerFirstName: "Sam")
        XCTAssertEqual(copy, "Accepting texts Sam a live tracking link and routes Lunar to the pickup.")
    }

    func testPassengerCopySimKeepsM1Wording() {
        let copy = IncomingRequestSheet.passengerCopy(isLive: false, isScheduled: false, vehicleName: "Model Y", passengerFirstName: "Sam")
        XCTAssertEqual(copy, "Accepting texts Sam a live tracking link and routes Model Y.")
    }

    // MARK: C — accept gate for in_service/offline

    func testAcceptDisabledForInServiceAndOffline() {
        XCTAssertTrue(IncomingRequestSheet.isVehicleUnavailable(.inService))
        XCTAssertTrue(IncomingRequestSheet.isVehicleUnavailable(.offline))
    }

    func testAcceptEnabledForParkedChargingDrivingAndUnknown() {
        XCTAssertFalse(IncomingRequestSheet.isVehicleUnavailable(.parked))
        XCTAssertFalse(IncomingRequestSheet.isVehicleUnavailable(.charging))
        XCTAssertFalse(IncomingRequestSheet.isVehicleUnavailable(.driving))
        XCTAssertFalse(IncomingRequestSheet.isVehicleUnavailable(nil))
    }

    func testUnavailableReasonNamesTheVehicleAndStatus() {
        XCTAssertEqual(IncomingRequestSheet.unavailableReason(status: .inService, vehicleName: "Lunar"), "Lunar is in service \u{2014} unavailable")
        XCTAssertEqual(IncomingRequestSheet.unavailableReason(status: .offline, vehicleName: "Lunar"), "Lunar is offline \u{2014} unavailable")
        // Neutral when the name isn't known (live, no fleet join).
        XCTAssertEqual(IncomingRequestSheet.unavailableReason(status: .offline, vehicleName: nil), "This vehicle is offline \u{2014} unavailable")
        // No reason for an available vehicle.
        XCTAssertNil(IncomingRequestSheet.unavailableReason(status: .parked, vehicleName: "Lunar"))
    }
}
