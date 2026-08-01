@testable import MyRoboTaxi
import MyRobotaxiContracts
import XCTest

// MARK: - MYR-233 — the `SharedViewerState` seam
//
// `liveFleetMember` is the ONE place the own-ride exception is folded in, and
// `routeToScheduling()` is the one way the gated CTA hands the rider onward.
// Both are pinned here without mounting SwiftUI.
@MainActor
final class RiderVehicleAvailabilityStateTests: XCTestCase {

    private func busySummary(status: VehicleSummary.Status = .parked, hasActiveRide: Bool? = true) -> VehicleSummary {
        VehicleSummary(vehicleId: "veh-1", name: "Lunar", model: "Model Y", year: 2026, color: "Quicksilver",
                       vinLast4: "2046", status: status, chargeLevel: 68, estimatedRange: 210,
                       lastUpdated: "2026-07-26T12:00:00Z", role: .owner, hasActiveRide: hasActiveRide)
    }

    // MARK: The own-ride exception, at the read seam

    /// A rider who does NOT own the open ride sees the vehicle as Busy.
    func testOtherRidersOpenRideSurfacesAsBusy() {
        let state = SharedViewerState()
        state.debugFleetMemberOverride = LiveFleetMemberMapping.fleetMember(from: busySummary())
        state.setRiderOwnsActiveRide(false)

        XCTAssertEqual(state.liveFleetMember?.unavailability, .busy)
        XCTAssertEqual(state.liveFleetMember?.isRequestable, false)
    }

    /// Acceptance criterion 4 — the rider who OWNS the open ride never sees Busy;
    /// the vehicle reads exactly as it did before this issue.
    func testOwnOpenRideNeverSurfacesAsBusy() {
        let state = SharedViewerState()
        state.debugFleetMemberOverride = LiveFleetMemberMapping.fleetMember(from: busySummary())
        state.setRiderOwnsActiveRide(true)

        XCTAssertNil(state.liveFleetMember?.unavailability, "their own active ride takes precedence")
        XCTAssertEqual(state.liveFleetMember?.isRequestable, true)
        XCTAssertEqual(state.liveFleetMember?.isAvailable, true)
        XCTAssertEqual(state.liveFleetMember?.availabilityWord, "Available")
        // Identity is never touched by the fold.
        XCTAssertEqual(state.liveFleetMember?.owner, "Lunar")
    }

    /// ...and the exception does NOT mask a genuinely in-service / offline car,
    /// even for the rider holding the ride — that would be dishonest.
    func testOwnRideExceptionDoesNotMaskOfflineAtTheSeam() {
        let state = SharedViewerState()
        state.debugFleetMemberOverride = LiveFleetMemberMapping.fleetMember(from: busySummary(status: .offline))
        state.setRiderOwnsActiveRide(true)

        XCTAssertEqual(state.liveFleetMember?.unavailability, .offline)
        XCTAssertEqual(state.liveFleetMember?.isRequestable, false)
    }

    /// Tolerant decode at the seam: an older server that omits the field can
    /// never produce a Busy vehicle.
    func testAbsentFieldNeverSurfacesAsBusyAtTheSeam() {
        let state = SharedViewerState()
        state.debugFleetMemberOverride = LiveFleetMemberMapping.fleetMember(from: busySummary(hasActiveRide: nil))
        XCTAssertNil(state.liveFleetMember?.unavailability)
        XCTAssertEqual(state.liveFleetMember?.isRequestable, true)
    }

    // MARK: Routing to the scheduling flow (acceptance criterion 2)

    /// The gated CTA hands the rider to Search with the schedule picker armed,
    /// KEEPING the whole draft so only the time is left to choose — a route
    /// onward, never a dead end.
    func testRouteToSchedulingArmsThePickerAndKeepsTheDraft() {
        let state = SharedViewerState()
        state.draftPickup = RideRequestFixtures.savedPlaces[0]
        state.draftDestination = RideRequestFixtures.recentPlaces[1]
        state.sheetPhase = .review

        state.routeToScheduling()

        XCTAssertEqual(state.sheetPhase, .search)
        XCTAssertTrue(state.opensScheduleOnSearch)
        XCTAssertNotNil(state.draftPickup, "the trip survives the hand-off")
        XCTAssertNotNil(state.draftDestination)
    }

    /// The routing flag is one-shot state tied to the draft — abandoning the
    /// request must not leave the schedule card primed to pop on the next open.
    func testResetDraftClearsTheSchedulingRoutingFlag() {
        let state = SharedViewerState()
        state.routeToScheduling()
        XCTAssertTrue(state.opensScheduleOnSearch)

        state.resetDraftToIdle()
        XCTAssertFalse(state.opensScheduleOnSearch)
        XCTAssertEqual(state.sheetPhase, .idle)
    }

    // MARK: Sim stays sim

    /// With no live locator and no DEBUG override, `liveFleetMember` is nil, so
    /// every simulated surface keeps rendering the fixture fleet unchanged.
    func testSimulatedStateHasNoLiveFleetMember() {
        let state = SharedViewerState()
        XCTAssertNil(state.liveFleetMember)
        XCTAssertNil(state.fleetMember(forID: RideRequestFixtures.fleet[0].id).unavailability)
    }
}
