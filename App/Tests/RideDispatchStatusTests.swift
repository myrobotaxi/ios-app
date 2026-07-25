import CoreLocation
@testable import MyRoboTaxi
import MyRoboTaxiKit
import MyRobotaxiContracts
import XCTest

// MARK: - MYR-265 two-leg dispatch — pure status/phase/resolver coverage
//
// The wire→app status mapping (no longer collapsing enroute/completed into
// accepted), the leg-2 tracking anchor, the rider phase transitions for the new
// statuses, and the owner ride-aware status-line resolver — all pure, no view
// mounting.
final class RideDispatchStatusTests: XCTestCase {

    // MARK: wire → app status (MYR-265: enroute/completed no longer collapsed)

    func testWireStatusMappingCarriesEnrouteAndCompleted() {
        typealias M = RideRequestContractMapping
        XCTAssertEqual(M.status(.requested), .pending)
        XCTAssertEqual(M.status(.accepted), .accepted, "leg 1 — en route to pickup")
        XCTAssertEqual(M.status(.enroute), .enroute, "leg 2 — aboard, NOT collapsed to accepted")
        XCTAssertEqual(M.status(.arrived), .enroute, "arriving at drop-off is still the in-ride leg")
        XCTAssertEqual(M.status(.completed), .completed, "dropped off, NOT collapsed to accepted")
        XCTAssertEqual(M.status(.declined), .declined)
        XCTAssertNil(M.status(.cancelled), "terminal cancel drops the card")
        XCTAssertNil(M.status(.unrecognized("weird")))
    }

    // MARK: record(from:) seeds the per-leg tracking anchor

    func testRecordFromEnrouteWireSeedsLeg2Anchor() throws {
        let record = try XCTUnwrap(RideRequestContractMapping.record(from: Self.wire(status: .enroute)))
        XCTAssertEqual(record.status, .enroute)
        let progress = try XCTUnwrap(record.trackProgress)
        XCTAssertGreaterThan(progress, record.pickupCut, "enroute mounts on the in-ride leg (past pickupCut)")
        XCTAssertLessThan(progress, 0.999, "…but short of the arrived/summary trigger")
    }

    func testRecordFromCompletedWireSeedsArrived() throws {
        let record = try XCTUnwrap(RideRequestContractMapping.record(from: Self.wire(status: .completed)))
        XCTAssertEqual(record.status, .completed)
        XCTAssertTrue(record.isArrived, "completed lands the rider on the summary")
    }

    func testEnrouteSeedProgressIsPastPickupCutAndBelowOne() {
        let record = RideRequestRecord(input: Self.appInput())
        XCTAssertGreaterThan(record.enrouteSeedProgress, record.pickupCut)
        XCTAssertLessThan(record.enrouteSeedProgress, 1)
    }

    // MARK: rider phase transitions (SharedViewerScreen.reconciledPhase)

    func testReconciledPhaseEnrouteEntersTrackingFromBookingOrIdle() {
        XCTAssertEqual(SharedViewerScreen.reconciledPhase(status: .enroute, hasSchedule: false, current: .idle), .tracking)
        XCTAssertEqual(SharedViewerScreen.reconciledPhase(status: .enroute, hasSchedule: false, current: .booking), .tracking)
    }

    func testReconciledPhaseEnrouteStaysWithinTracking() {
        XCTAssertNil(SharedViewerScreen.reconciledPhase(status: .enroute, hasSchedule: false, current: .tracking),
                     "already tracking → the leg flips off the status, no phase change")
    }

    func testReconciledPhaseEnrouteIgnoresScheduled() {
        XCTAssertNil(SharedViewerScreen.reconciledPhase(status: .enroute, hasSchedule: true, current: .idle))
    }

    func testReconciledPhaseCompletedGoesToSummaryFromTracking() {
        XCTAssertEqual(SharedViewerScreen.reconciledPhase(status: .completed, hasSchedule: false, current: .tracking), .summary)
        XCTAssertNil(SharedViewerScreen.reconciledPhase(status: .completed, hasSchedule: false, current: .idle))
    }

    // MARK: owner ride-aware status line (OwnerRideStatusLine)

    func testOwnerStatusLineAccepted() {
        XCTAssertEqual(OwnerRideStatusLine.text(status: .accepted, riderName: "Maya", dropoffLabel: "SFO"),
                       "En route to pickup \u{00B7} picking up Maya")
        XCTAssertEqual(OwnerRideStatusLine.text(status: .accepted, riderName: nil, dropoffLabel: "SFO"),
                       "En route to pickup", "neutral when no rider name (MYR-228)")
        XCTAssertEqual(OwnerRideStatusLine.text(status: .accepted, riderName: "   ", dropoffLabel: "SFO"),
                       "En route to pickup", "blank name treated as absent")
    }

    func testOwnerStatusLineEnroute() {
        XCTAssertEqual(OwnerRideStatusLine.text(status: .enroute, riderName: "Maya", dropoffLabel: "SFO · Terminal 2"),
                       "Maya aboard \u{00B7} heading to SFO · Terminal 2")
        XCTAssertEqual(OwnerRideStatusLine.text(status: .enroute, riderName: nil, dropoffLabel: "SFO"),
                       "Heading to SFO", "neutral rider")
        XCTAssertEqual(OwnerRideStatusLine.text(status: .enroute, riderName: "Maya", dropoffLabel: nil),
                       "Maya aboard", "neutral drop-off")
    }

    func testOwnerStatusLineCompletedAndInactive() {
        XCTAssertEqual(OwnerRideStatusLine.text(status: .completed, riderName: "Maya", dropoffLabel: "SFO"),
                       "Dropped off \u{2713}")
        XCTAssertNil(OwnerRideStatusLine.text(status: .pending, riderName: "Maya", dropoffLabel: "SFO"))
        XCTAssertNil(OwnerRideStatusLine.text(status: .declined, riderName: "Maya", dropoffLabel: "SFO"))
    }

    // MARK: builders

    private static func appInput() -> RideRequestInput {
        RideRequestInput(
            pickup: RidePlace(id: "pin", label: "Current location", subtitle: nil, miles: 0, minutes: 0, icon: "mappin",
                              coordinate: CLLocationCoordinate2D(latitude: 37.7793, longitude: -122.3937)),
            destination: RidePlace(id: "sfo", label: "SFO · Terminal 2", subtitle: nil, miles: 18.4, minutes: 32, icon: "mappin",
                                   coordinate: CLLocationCoordinate2D(latitude: 37.6156, longitude: -122.3900)),
            fleetMemberID: "veh-live"
        )
    }

    private static func wire(status: MyRobotaxiContracts.RideRequestStatus) -> RideRequest {
        RideRequest(
            id: "r1", riderId: "u", ownerId: "u", vehicleId: "veh-live",
            pickup: MyRobotaxiContracts.RidePlace(lat: 37.7793, lng: -122.3937, label: "Current location"),
            dropoff: MyRobotaxiContracts.RidePlace(lat: 37.6156, lng: -122.3900, label: "SFO · Terminal 2"),
            status: status,
            createdAt: "2026-07-10T18:00:00.000Z",
            updatedAt: "2026-07-10T18:06:00.000Z",
            acceptedAt: "2026-07-10T18:04:00.000Z"
        )
    }
}
