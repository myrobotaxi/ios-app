@testable import MyRoboTaxi
import XCTest

// MARK: - MYR-230 deliverable 1 — mount-time status→phase reconciliation mapping
//
// `SharedViewerScreen.reconciledPhase` is the ONE pure decision both the reactive
// `.onChange` path and the mount reconciliation route through, so an owner
// accept/decline (or a cold-launch / 409 adoption) that landed while the rider
// screen was unmounted is folded into the sheet phase on appear. These tests pin
// the mapping and its IDEMPOTENCE (a ride+status already reflected → no change)
// without mounting the view.
@MainActor
final class SharedViewerMountReconcileTests: XCTestCase {

    // MARK: accepted → tracking (now-rides only, from idle/booking)

    func testAcceptedNowRideFromIdleEntersTracking() {
        XCTAssertEqual(
            SharedViewerScreen.reconciledPhase(status: .accepted, hasSchedule: false, current: .idle),
            .tracking,
            "the client bug: accept landed while unmounted → mount lands on tracking, not idle"
        )
    }

    func testAcceptedNowRideFromBookingEntersTracking() {
        XCTAssertEqual(
            SharedViewerScreen.reconciledPhase(status: .accepted, hasSchedule: false, current: .booking),
            .tracking
        )
    }

    // MARK: idempotence — already reflected → no-op

    func testAcceptedAlreadyTrackingIsNoOp() {
        XCTAssertNil(
            SharedViewerScreen.reconciledPhase(status: .accepted, hasSchedule: false, current: .tracking),
            "an accepted ride already on tracking must not re-enter tracking on remount"
        )
    }

    func testAcceptedFromSummaryIsNoOp() {
        XCTAssertNil(
            SharedViewerScreen.reconciledPhase(status: .accepted, hasSchedule: false, current: .summary),
            "a completed/arrived ride resting on summary is not dragged back to tracking"
        )
    }

    // MARK: scheduled acceptance is a reservation, never a live trip

    func testScheduledAcceptanceNeverEntersTracking() {
        XCTAssertNil(SharedViewerScreen.reconciledPhase(status: .accepted, hasSchedule: true, current: .idle))
        XCTAssertNil(SharedViewerScreen.reconciledPhase(status: .accepted, hasSchedule: true, current: .booking))
    }

    // MARK: pending → no change (idle sheet shows the pending pill)

    func testPendingLeavesPhaseUnchanged() {
        XCTAssertNil(SharedViewerScreen.reconciledPhase(status: .pending, hasSchedule: false, current: .idle))
        XCTAssertNil(SharedViewerScreen.reconciledPhase(status: .pending, hasSchedule: false, current: .booking))
    }

    // MARK: declined → search (idempotent once already there)

    func testDeclinedFromIdleGoesToSearch() {
        XCTAssertEqual(
            SharedViewerScreen.reconciledPhase(status: .declined, hasSchedule: false, current: .idle),
            .search
        )
    }

    func testDeclinedAlreadyOnSearchIsNoOp() {
        XCTAssertNil(
            SharedViewerScreen.reconciledPhase(status: .declined, hasSchedule: false, current: .search),
            "declined already reflected on search → no redundant phase write"
        )
    }
}
