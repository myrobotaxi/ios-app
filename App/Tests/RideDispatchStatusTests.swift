import CoreLocation
@testable import MyRoboTaxi
import MyRoboTaxiKit
import MyRobotaxiContracts
import XCTest

// MARK: - MYR-270 owner-driven dispatch v2 — pure status/stage/resolver coverage
//
// The wire→app status mapping (arrived now a DISTINCT state), the per-leg tracking
// anchors, the rider phase transitions + tracking STAGE for the new statuses, the
// owner ride-aware status-line resolver + action gating — all pure, no view mounting.
final class RideDispatchStatusTests: XCTestCase {

    // MARK: wire → app status (MYR-270: arrived is its own state, nothing collapsed)

    func testWireStatusMappingCarriesEveryDispatchState() {
        typealias M = RideRequestContractMapping
        XCTAssertEqual(M.status(.requested), .pending)
        XCTAssertEqual(M.status(.accepted), .accepted, "leg 1 — car → pickup")
        XCTAssertEqual(M.status(.arrived), .arrived, "picked up, awaiting rider start — DISTINCT, not folded into enroute")
        XCTAssertEqual(M.status(.enroute), .enroute, "leg 2 — ride started, car → dropoff")
        XCTAssertEqual(M.status(.completed), .completed, "dropped off")
        XCTAssertEqual(M.status(.declined), .declined)
        XCTAssertNil(M.status(.cancelled), "terminal cancel drops the card")
        XCTAssertNil(M.status(.unrecognized("weird")))
    }

    // MARK: record(from:) seeds the per-leg tracking anchor

    func testRecordFromArrivedWireSeedsLeg1Anchor() throws {
        let record = try XCTUnwrap(RideRequestContractMapping.record(from: Self.wire(status: .arrived)))
        XCTAssertEqual(record.status, .arrived)
        let progress = try XCTUnwrap(record.trackProgress)
        XCTAssertLessThan(progress, record.pickupCut, "arrived (car at pickup) mounts on the leg-1 framing")
    }

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

    func testReconciledPhaseArrivedAndEnrouteEnterTrackingFromBookingOrIdle() {
        for status in [MyRoboTaxi.RideRequestStatus.arrived, .enroute] {
            XCTAssertEqual(SharedViewerScreen.reconciledPhase(status: status, hasSchedule: false, current: .idle), .tracking)
            XCTAssertEqual(SharedViewerScreen.reconciledPhase(status: status, hasSchedule: false, current: .booking), .tracking)
            XCTAssertNil(SharedViewerScreen.reconciledPhase(status: status, hasSchedule: false, current: .tracking),
                         "already tracking → the stage flips off the status, no phase change")
            XCTAssertNil(SharedViewerScreen.reconciledPhase(status: status, hasSchedule: true, current: .idle),
                         "scheduled reservations never enter live tracking")
        }
    }

    func testReconciledPhaseCompletedGoesToSummaryFromTracking() {
        XCTAssertEqual(SharedViewerScreen.reconciledPhase(status: .completed, hasSchedule: false, current: .tracking), .summary)
        XCTAssertNil(SharedViewerScreen.reconciledPhase(status: .completed, hasSchedule: false, current: .idle))
    }

    // MARK: rider tracking STAGE (RiderTrackingStage.stage — start CTA gating)

    func testRiderStageArrivedShowsStartCTAState() {
        XCTAssertEqual(RiderTrackingStage.stage(status: .arrived, atPickupByProgress: false, arriving: false),
                       .arrivedAwaitingStart, "arrived → the pulsing Start CTA state")
    }

    func testRiderStartCTAGatedToArrivedNeverAccepted() {
        // accepted (live leg 1) and a nil status never reach the Start CTA stage.
        XCTAssertEqual(RiderTrackingStage.stage(status: .accepted, atPickupByProgress: false, arriving: false), .toPickup)
        XCTAssertEqual(RiderTrackingStage.stage(status: nil, atPickupByProgress: false, arriving: false), .toPickup)
        XCTAssertNotEqual(RiderTrackingStage.stage(status: .accepted, atPickupByProgress: false, arriving: false),
                          .arrivedAwaitingStart, "no Start CTA before the owner confirms pickup")
    }

    func testRiderStageEnrouteArrivingDerivesFromWireETA() {
        // enroute + wire ETA ≤ 2 → arriving takeover; otherwise the in-ride leg.
        XCTAssertEqual(RiderTrackingStage.stage(status: .enroute, atPickupByProgress: false, arriving: true), .arrivingDropoff)
        XCTAssertEqual(RiderTrackingStage.stage(status: .enroute, atPickupByProgress: false, arriving: false), .inRide)
    }

    func testRiderStageSimProgressPathUnchanged() {
        // The sim/`.accepted` progress path: before pickupCut → toPickup; past it →
        // inRide, or arrivingDropoff once remain ≤ 2 (existing drift-gate scenes).
        XCTAssertEqual(RiderTrackingStage.stage(status: .accepted, atPickupByProgress: false, arriving: false), .toPickup)
        XCTAssertEqual(RiderTrackingStage.stage(status: .accepted, atPickupByProgress: true, arriving: false), .inRide)
        XCTAssertEqual(RiderTrackingStage.stage(status: .accepted, atPickupByProgress: true, arriving: true), .arrivingDropoff)
    }

    // MARK: owner ride-aware status line (OwnerRideStatusLine)

    func testOwnerStatusLineAccepted() {
        XCTAssertEqual(OwnerRideStatusLine.text(status: .accepted, riderName: "Maya", dropoffLabel: "SFO"),
                       "En route to pickup \u{00B7} Maya")
        XCTAssertEqual(OwnerRideStatusLine.text(status: .accepted, riderName: nil, dropoffLabel: "SFO"),
                       "En route to pickup", "neutral when no rider name (MYR-228)")
        XCTAssertEqual(OwnerRideStatusLine.text(status: .accepted, riderName: "   ", dropoffLabel: "SFO"),
                       "En route to pickup", "blank name treated as absent")
    }

    func testOwnerArrivingRequiresDrivingAndRealETA() {
        // The bug (MYR-270 review): etaMinutes collapses an ABSENT ETA to 0, so
        // the owner must NOT read "Arriving" at eta==0 the instant leg 2 starts
        // (car still parked at pickup).
        XCTAssertFalse(OwnerRideStatusLine.arriving(status: .enroute, isDriving: true, etaMinutes: 0),
                       "eta 0 = no ETA yet / stationary, never arriving")
        XCTAssertFalse(OwnerRideStatusLine.arriving(status: .enroute, isDriving: false, etaMinutes: 2),
                       "parked at pickup, not driving → not arriving")
        XCTAssertFalse(OwnerRideStatusLine.arriving(status: .enroute, isDriving: true, etaMinutes: 3),
                       "3 min out is not yet arriving")
        XCTAssertTrue(OwnerRideStatusLine.arriving(status: .enroute, isDriving: true, etaMinutes: 2))
        XCTAssertTrue(OwnerRideStatusLine.arriving(status: .enroute, isDriving: true, etaMinutes: 1))
        // Only during the in-ride leg.
        XCTAssertFalse(OwnerRideStatusLine.arriving(status: .accepted, isDriving: true, etaMinutes: 1))
        XCTAssertFalse(OwnerRideStatusLine.arriving(status: .arrived, isDriving: true, etaMinutes: 1))
    }

    func testOwnerStatusLineArrived() {
        XCTAssertEqual(OwnerRideStatusLine.text(status: .arrived, riderName: "Maya", dropoffLabel: "SFO"),
                       "Picked up \u{00B7} waiting for Maya to start")
        XCTAssertEqual(OwnerRideStatusLine.text(status: .arrived, riderName: nil, dropoffLabel: "SFO"),
                       "Picked up \u{00B7} waiting to start", "neutral when no rider name")
    }

    func testOwnerStatusLineEnroute() {
        XCTAssertEqual(OwnerRideStatusLine.text(status: .enroute, riderName: "Maya", dropoffLabel: "SFO · Terminal 2"),
                       "Maya aboard \u{00B7} heading to SFO · Terminal 2")
        XCTAssertEqual(OwnerRideStatusLine.text(status: .enroute, riderName: nil, dropoffLabel: "SFO"),
                       "Heading to SFO", "neutral rider")
        XCTAssertEqual(OwnerRideStatusLine.text(status: .enroute, riderName: "Maya", dropoffLabel: nil),
                       "Maya aboard", "neutral drop-off")
    }

    func testOwnerStatusLineArrivingTakesOverEnroute() {
        XCTAssertEqual(OwnerRideStatusLine.text(status: .enroute, riderName: "Maya", dropoffLabel: "SFO", arriving: true),
                       "Arriving at SFO", "ETA ≤ 2 → arriving takeover")
        XCTAssertEqual(OwnerRideStatusLine.text(status: .enroute, riderName: nil, dropoffLabel: nil, arriving: true),
                       "Arriving", "neutral drop-off")
    }

    func testOwnerStatusLineCompletedAndInactive() {
        XCTAssertEqual(OwnerRideStatusLine.text(status: .completed, riderName: "Maya", dropoffLabel: "SFO"),
                       "Dropped off \u{2713}")
        XCTAssertNil(OwnerRideStatusLine.text(status: .pending, riderName: "Maya", dropoffLabel: "SFO"))
        XCTAssertNil(OwnerRideStatusLine.text(status: .declined, riderName: "Maya", dropoffLabel: "SFO"))
    }

    // MARK: owner action gating (Picked up / Dropped off)

    func testOwnerActionTitleGating() {
        XCTAssertEqual(OwnerRideStatusLine.actionTitle(for: .accepted), "Picked up")
        XCTAssertEqual(OwnerRideStatusLine.actionTitle(for: .enroute), "Dropped off")
        XCTAssertNil(OwnerRideStatusLine.actionTitle(for: .arrived), "arrived is the rider's move (Start) — owner waits")
        XCTAssertNil(OwnerRideStatusLine.actionTitle(for: .completed))
        XCTAssertNil(OwnerRideStatusLine.actionTitle(for: .pending))
        XCTAssertNil(OwnerRideStatusLine.actionTitle(for: .declined))
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
