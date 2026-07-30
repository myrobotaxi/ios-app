import XCTest
import UIKit
import SwiftUI
import DesignSystem
import MyRoboTaxiKit
import MyRobotaxiContracts
@testable import MyRoboTaxi

// MARK: - MYR-360 — pausing ride sharing over an accepted reservation
//
// THE DEFECT. An owner pauses ride sharing on a car that already carries an
// ACCEPTED FUTURE RESERVATION. The server holds the reservation at due time and
// expires it 30 minutes later, so the rider finds out nobody is coming half an
// hour AFTER the pickup they planned around.
//
// Every assertion in this file is on the WIRE — which reservation ids were
// declined, in what order, and whether the pause PUT went out at all — because
// that is the only level at which "we did not strand anybody" is a fact rather
// than a UI flag. The flow is driven directly; no view is mounted.
final class RideSharePauseWarningTests: XCTestCase {

    // MARK: - Harness

    /// A `RideRequestAPI` scripted with wire reservations, recording the order of
    /// every decline. The `StubRideAPI` recipe from `LiveRideRequestServiceTests`,
    /// narrowed to the two calls this flow makes.
    private actor StubReservationAPI: RideRequestAPI {
        private var pages: [RideRequestsListResponse]
        private let listError: Error?
        /// Ids that must FAIL to decline (everything else succeeds).
        private let declineFailures: Set<String>

        private(set) var listedVehicleIDs: [String] = []
        private(set) var listedCursors: [String?] = []
        private(set) var declinedIDs: [String] = []

        init(
            reservations: [MyRobotaxiContracts.RideRequest] = [],
            pages: [RideRequestsListResponse]? = nil,
            listError: Error? = nil,
            declineFailures: Set<String> = []
        ) {
            self.pages = pages ?? [RideRequestsListResponse(items: reservations, hasMore: false)]
            self.listError = listError
            self.declineFailures = declineFailures
        }

        func upcomingReservations(vehicleID: String, cursor: String?, limit: Int) async throws -> RideRequestsListResponse {
            listedVehicleIDs.append(vehicleID)
            listedCursors.append(cursor)
            if let listError { throw listError }
            return pages.isEmpty ? RideRequestsListResponse(items: [], hasMore: false) : pages.removeFirst()
        }

        func declineRideRequest(id: String) async throws -> MyRobotaxiContracts.RideRequest {
            declinedIDs.append(id)
            if declineFailures.contains(id) {
                throw RestError.http(status: 500, code: nil, message: nil, subCode: nil)
            }
            return RideSharePauseWarningTests.wire(id: id, name: nil, scheduledFor: Date().addingTimeInterval(3600))
        }

        // Never reached by this flow — present to keep the conformance total.
        func vehicles() async throws -> [VehicleSummary] { [] }
        func createRideRequest(_ body: RideRequestCreateRequest) async throws -> MyRobotaxiContracts.RideRequest {
            throw RestError.http(status: 501, code: nil, message: nil, subCode: nil)
        }
        func rideRequests(cursor: String?, limit: Int) async throws -> RideRequestsListResponse {
            RideRequestsListResponse(items: [], hasMore: false)
        }
        func rideRequest(id: String) async throws -> MyRobotaxiContracts.RideRequest { try await declineRideRequest(id: id) }
        func cancelRideRequest(id: String) async throws -> MyRobotaxiContracts.RideRequest { try await declineRideRequest(id: id) }
        func acceptRideRequest(id: String) async throws -> MyRobotaxiContracts.RideRequest { try await declineRideRequest(id: id) }
        func pickedUp(rideID: String) async throws -> MyRobotaxiContracts.RideRequest { try await declineRideRequest(id: rideID) }
        func start(rideID: String) async throws -> MyRobotaxiContracts.RideRequest { try await declineRideRequest(id: rideID) }
        func droppedOff(rideID: String) async throws -> MyRobotaxiContracts.RideRequest { try await declineRideRequest(id: rideID) }
        func incomingRideRequests(cursor: String?, limit: Int) async throws -> RideRequestsListResponse {
            RideRequestsListResponse(items: [], hasMore: false)
        }
    }

    private static let isoUTC: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    /// One ACCEPTED scheduled reservation, exactly as the server emits it.
    static func wire(id: String, name: String?, scheduledFor: Date) -> MyRobotaxiContracts.RideRequest {
        let stamp = isoUTC.string(from: Date())
        return MyRobotaxiContracts.RideRequest(
            id: id,
            riderId: "rider-1",
            ownerId: "owner-1",
            vehicleId: "veh-1",
            pickup: MyRobotaxiContracts.RidePlace(lat: 37.7749, lng: -122.4194, label: "Home"),
            dropoff: MyRobotaxiContracts.RidePlace(lat: 37.6156, lng: -122.39, label: "SFO"),
            status: .accepted,
            scheduledFor: isoUTC.string(from: scheduledFor),
            createdAt: stamp,
            updatedAt: stamp,
            acceptedAt: stamp,
            requesterName: name
        )
    }

    /// A real `LiveVehicleCommandExecutor` over the EXISTING scripted §7.18
    /// endpoint (MYR-342's own `ScriptedRideShareEndpoint`), so the pause PUT — and
    /// its absence — is asserted on the wire rather than on a flag. Reused, not
    /// forked: the other two owner-write seams get the same scripted stand-ins
    /// every executor test already uses.
    @MainActor
    private func makeExecutor(_ endpoint: ScriptedRideShareEndpoint) -> LiveVehicleCommandExecutor {
        LiveVehicleCommandExecutor(
            vehicleID: "veh-1",
            sender: ScriptedCommandSender(),
            plateEndpoint: ScriptedPlateEndpoint(),
            serviceWindowEndpoint: ScriptedServiceWindowEndpoint(),
            rideShareEndpoint: endpoint,
            driving: false,
            plate: "",
            wakeRetryDelay: .zero,
            maxWakeRetries: 1,
            // Long enough that no test races the MYR-301 bounded display.
            noticeDisplayDuration: .seconds(600)
        )
    }

    @MainActor
    private func makeFlow(_ api: StubReservationAPI) -> RideSharePauseFlow {
        RideSharePauseFlow(source: LiveUpcomingReservations(api: api))
    }

    private func date(_ offset: TimeInterval) -> Date { Date().addingTimeInterval(offset) }

    // MARK: - 1. The decision matrix

    /// ZERO reservations is the common case and it must be UNCHANGED: no dialog, no
    /// extra step, straight to the pause PUT. If this ever regresses, every owner
    /// pays a dialog for a situation that does not exist.
    @MainActor
    func testNoReservationsPausesImmediatelyWithNoDialog() async {
        let api = StubReservationAPI()
        let endpoint = ScriptedRideShareEndpoint()
        let flow = makeFlow(api)
        let executor = makeExecutor(endpoint)

        await flow.setEnabled(false, vehicleID: "veh-1", executor: executor)

        XCTAssertNil(flow.warning, "nothing is booked — there is nothing to warn about")
        let submitted = await endpoint.submitted()
        XCTAssertEqual(submitted, [false], "the pause PUT fires exactly as it did before this issue")
        let listed = await api.listedVehicleIDs
        XCTAssertEqual(listed, ["veh-1"], "the read is scoped to the vehicle whose switch was flipped")
        XCTAssertFalse(executor.controls.rideShareEnabled)
    }

    /// ONE reservation: the warning, the singular copy, and NOTHING committed yet.
    @MainActor
    func testOneReservationRaisesTheWarningAndPausesNothing() async {
        let pickup = date(60 * 60 * 30)
        let api = StubReservationAPI(reservations: [Self.wire(id: "r1", name: "Alex", scheduledFor: pickup)])
        let endpoint = ScriptedRideShareEndpoint()
        let flow = makeFlow(api)
        let executor = makeExecutor(endpoint)

        await flow.setEnabled(false, vehicleID: "veh-1", executor: executor)

        let warning = try? XCTUnwrap(flow.warning)
        XCTAssertEqual(warning?.reservations.map(\.id), ["r1"])
        XCTAssertEqual(warning?.reservations.first?.riderFirstName, "Alex")
        let submitted = await endpoint.submitted()
        XCTAssertTrue(submitted.isEmpty, "nothing is committed while the owner is being asked")
        XCTAssertTrue(executor.controls.rideShareEnabled, "and the switch has not moved")

        let config = RideSharePauseDialog.warning(
            count: warning?.reservations.count ?? 0,
            onDeclineAndPause: {},
            onPauseAnyway: {}
        )
        XCTAssertEqual(config.title, "Pause ride sharing?")
        XCTAssertEqual(config.actionLabel, "Decline it and pause")
        XCTAssertEqual(config.secondaryLabel, "Pause anyway")
        XCTAssertEqual(config.dismissLabel, "Keep sharing")
        XCTAssertEqual(
            config.message,
            "Paused rides won\u{2019}t be dispatched \u{2014} they expire 30 minutes after pickup time.",
            "the consequence sentence, verbatim"
        )
        // The reservations are ROWS in the dialog's content slot, never prose in the
        // body — the client's own correction on the first build.
        XCTAssertFalse(config.message.contains("Alex"), "the message names nobody")
        XCTAssertFalse(config.message.contains("Pickup"), "and states no pickup time")
    }

    /// MANY reservations: soonest first, the cap applied, the remainder rolled up,
    /// and every plural form in agreement.
    @MainActor
    func testManyReservationsListSoonestFirstCappedWithARollup() async {
        let now = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let api = StubReservationAPI(reservations: [
            Self.wire(id: "r1", name: "Alex", scheduledFor: now.addingTimeInterval(86_400)),
            Self.wire(id: "r2", name: "Priya", scheduledFor: now.addingTimeInterval(2 * 86_400)),
            Self.wire(id: "r3", name: "Sam", scheduledFor: now.addingTimeInterval(3 * 86_400)),
            Self.wire(id: "r4", name: "Jo", scheduledFor: now.addingTimeInterval(4 * 86_400))
        ])
        let flow = makeFlow(api)
        await flow.setEnabled(false, vehicleID: "veh-1", executor: makeExecutor(ScriptedRideShareEndpoint()))

        let reservations = flow.warning?.reservations ?? []
        XCTAssertEqual(reservations.map(\.id), ["r1", "r2", "r3", "r4"], "the server's soonest-first order is preserved")

        XCTAssertEqual(RideSharePauseDialog.displayCap, 3)
        XCTAssertEqual(
            reservations.prefix(RideSharePauseDialog.displayCap).map {
                RideSharePauseDialog.rowTime(for: $0, now: now, calendar: calendar)
            },
            reservations.prefix(3).map { VehicleServiceWindow.completionLabel(for: $0.scheduledFor, now: now, calendar: calendar)! },
            "each visible row leads with the shared day-and-time stamp"
        )
        XCTAssertEqual(
            reservations.prefix(RideSharePauseDialog.displayCap).map(RideSharePauseDialog.rowRider),
            ["Alex", "Priya", "Sam"],
            "…over the rider's first name, soonest first"
        )
        XCTAssertEqual(
            RideSharePauseDialog.overflowLabel(for: reservations), "+1 more",
            "everything past the cap is counted, never dropped"
        )
        XCTAssertNil(
            RideSharePauseDialog.overflowLabel(for: Array(reservations.prefix(3))),
            "and nothing rolls up when nothing is hidden"
        )
        XCTAssertEqual(RideSharePauseDialog.actionLabel(count: reservations.count), "Decline them and pause")
    }

    // MARK: - 2. The three actions, asserted on the wire

    /// "Decline it and pause" — EVERY reservation declined, including the two past
    /// the display cap, and THEN the pause. The order is the whole point: pausing
    /// first would strand a rider for as long as a decline took to land.
    @MainActor
    func testDeclineAndPauseDeclinesEveryReservationThenPauses() async {
        let now = Date()
        let api = StubReservationAPI(reservations: (1...4).map {
            Self.wire(id: "r\($0)", name: "Rider\($0)", scheduledFor: now.addingTimeInterval(Double($0) * 86_400))
        })
        let endpoint = ScriptedRideShareEndpoint()
        let flow = makeFlow(api)
        let executor = makeExecutor(endpoint)

        await flow.setEnabled(false, vehicleID: "veh-1", executor: executor)
        await flow.confirmDeclineAndPause()

        let declined = await api.declinedIDs
        XCTAssertEqual(declined, ["r1", "r2", "r3", "r4"], "including the two the dialog could not name")
        let submitted = await endpoint.submitted()
        XCTAssertEqual(submitted, [false], "the pause follows the declines")
        XCTAssertFalse(executor.controls.rideShareEnabled)
        XCTAssertNil(executor.uiState(for: .rideShare).notice, "a clean run raises no notice")
        XCTAssertNil(flow.warning, "the dialog is gone")
    }

    /// "Pause anyway" — the pause PUT exactly as today, and NOT ONE decline. The
    /// server's hold-then-expire backstop still covers the reservations, and an
    /// owner who resumes before the pickup strands nobody.
    @MainActor
    func testPauseAnywayPausesAndTouchesNoReservation() async {
        let api = StubReservationAPI(reservations: [
            Self.wire(id: "r1", name: "Alex", scheduledFor: date(86_400))
        ])
        let endpoint = ScriptedRideShareEndpoint()
        let flow = makeFlow(api)
        let executor = makeExecutor(endpoint)

        await flow.setEnabled(false, vehicleID: "veh-1", executor: executor)
        await flow.pauseAnyway()

        let declined = await api.declinedIDs
        XCTAssertTrue(declined.isEmpty, "the reservations are left exactly as they were")
        let submitted = await endpoint.submitted()
        XCTAssertEqual(submitted, [false])
        XCTAssertFalse(executor.controls.rideShareEnabled)
        XCTAssertNil(flow.warning)
    }

    /// "Keep sharing" — nothing at all happens, and the SWITCH IS STILL ON.
    ///
    /// The position needs no restoring, and that is structural rather than lucky:
    /// the optimistic flip lives inside `setRideShareEnabled`, which the cancel path
    /// never calls, so the row has been rendering the committed ON value for the
    /// whole life of the dialog. Asserted through the same
    /// `VehicleRideShare.resolvedEnabled` → `display(storedEnabled:isInService:)`
    /// chain the row itself uses.
    @MainActor
    func testKeepSharingWritesNothingAndLeavesTheToggleOn() async {
        let api = StubReservationAPI(reservations: [
            Self.wire(id: "r1", name: "Alex", scheduledFor: date(86_400))
        ])
        let endpoint = ScriptedRideShareEndpoint()
        let flow = makeFlow(api)
        let executor = makeExecutor(endpoint)

        await flow.setEnabled(false, vehicleID: "veh-1", executor: executor)
        XCTAssertNotNil(flow.warning)
        flow.keepSharing()

        let declined = await api.declinedIDs
        XCTAssertTrue(declined.isEmpty, "no declines")
        let submitted = await endpoint.submitted()
        XCTAssertTrue(submitted.isEmpty, "no PUT")
        XCTAssertNil(flow.warning)
        XCTAssertNil(executor.uiState(for: .rideShare).notice, "cancelling is not a failure")

        // The row's own resolution, end to end: the snapshot says ON, nothing was
        // committed, so the switch renders ON.
        let resolved = VehicleRideShare.resolvedEnabled(executor: executor, snapshot: snapshotWithRideShare(true))
        XCTAssertTrue(resolved)
        XCTAssertTrue(VehicleRideShare.display(storedEnabled: resolved, isInService: false).isOn)
    }

    // MARK: - 3. The honest failure states

    /// THE MIDWAY FAILURE. Some declines landed, one did not — so the pause must NOT
    /// happen. Pausing here would strand exactly the rider the flow was protecting,
    /// after having told the owner the opposite. The successful declines are
    /// irreversible, so the honest resting state is: sharing still ON, some
    /// reservations declined, a notice explaining the rest did not go through.
    @MainActor
    func testADeclineFailureMidwayLeavesRideSharingOnAndRaisesTheNotice() async {
        let now = Date()
        let api = StubReservationAPI(
            reservations: (1...3).map {
                Self.wire(id: "r\($0)", name: "Rider\($0)", scheduledFor: now.addingTimeInterval(Double($0) * 86_400))
            },
            declineFailures: ["r2"]
        )
        let endpoint = ScriptedRideShareEndpoint()
        let flow = makeFlow(api)
        let executor = makeExecutor(endpoint)

        await flow.setEnabled(false, vehicleID: "veh-1", executor: executor)
        await flow.confirmDeclineAndPause()

        let declined = await api.declinedIDs
        XCTAssertEqual(declined, ["r1", "r2"], "it stops at the failure — r3 is never attempted")
        let submitted = await endpoint.submitted()
        XCTAssertTrue(submitted.isEmpty, "THE PAUSE MUST NOT FIRE — asserted on the wire, not on a flag")
        XCTAssertTrue(executor.controls.rideShareEnabled, "ride sharing is still ON")
        XCTAssertEqual(executor.uiState(for: .rideShare).notice, .reservationNotDeclined)
        XCTAssertNil(flow.warning, "the dialog is answered either way — the notice carries the outcome")
    }

    /// THE FETCH FAILURE. An unreachable list is UNKNOWN, not empty — and the
    /// deliberate choice is to refuse the pause rather than guess. A pause that may
    /// strand a rider is the exact harm this issue exists to prevent, and an owner
    /// whose tap did not take can simply tap again; a stranded rider cannot undo
    /// anything.
    @MainActor
    func testAnUnreachableReservationListBlocksThePauseAndSaysSo() async {
        let api = StubReservationAPI(listError: RestError.http(status: 503, code: nil, message: nil, subCode: nil))
        let endpoint = ScriptedRideShareEndpoint()
        let flow = makeFlow(api)
        let executor = makeExecutor(endpoint)

        await flow.setEnabled(false, vehicleID: "veh-1", executor: executor)

        XCTAssertNil(flow.warning, "there is nothing honest to put in a dialog")
        let submitted = await endpoint.submitted()
        XCTAssertTrue(submitted.isEmpty, "the pause is NOT committed on an unknown list")
        XCTAssertTrue(executor.controls.rideShareEnabled, "the switch stays where the server has it")
        XCTAssertEqual(
            executor.uiState(for: .rideShare).notice, .rideShareNotSaved,
            "the existing notice says exactly what happened: ride sharing did not change"
        )
    }

    /// The pure rule behind both, stated once.
    func testTheDecisionRuleIsThreeWay() {
        XCTAssertEqual(RideSharePause.decide(.success([])), .pause)
        let one = UpcomingReservation(id: "r1", riderFirstName: "Alex", scheduledFor: Date())
        XCTAssertEqual(RideSharePause.decide(.success([one])), .warn([one]))
        XCTAssertEqual(
            RideSharePause.decide(.failure(RestError.http(status: 500, code: nil, message: nil, subCode: nil))),
            .blocked
        )
    }

    // MARK: - 4. Turning ride sharing back ON

    /// RESUMING is never questioned: it cannot strand anyone — it is the recovery
    /// from this whole situation — so it never reads, never dialogs and never waits.
    @MainActor
    func testTurningRideSharingOnNeverFetchesAndNeverDialogs() async {
        let api = StubReservationAPI(reservations: [
            Self.wire(id: "r1", name: "Alex", scheduledFor: date(86_400))
        ])
        let endpoint = ScriptedRideShareEndpoint()
        let flow = makeFlow(api)
        let executor = makeExecutor(endpoint)

        await flow.setEnabled(true, vehicleID: "veh-1", executor: executor)

        let listed = await api.listedVehicleIDs
        XCTAssertTrue(listed.isEmpty, "the ON direction reads nothing")
        XCTAssertNil(flow.warning, "and asks nothing")
        let submitted = await endpoint.submitted()
        XCTAssertEqual(submitted, [true])
    }

    /// With NO seam composed at all — the simulated path and the MYR-342 capture
    /// scenes — the pause commits exactly as it did before this issue. `nil` is
    /// "this feature is not wired here", which is not the same as a read that failed.
    @MainActor
    func testWithNoReservationSeamThePauseCommitsAsBefore() async {
        let endpoint = ScriptedRideShareEndpoint()
        let flow = RideSharePauseFlow(source: nil)
        let executor = makeExecutor(endpoint)

        await flow.setEnabled(false, vehicleID: "veh-1", executor: executor)

        XCTAssertNil(flow.warning)
        let submitted = await endpoint.submitted()
        XCTAssertEqual(submitted, [false])
        XCTAssertNil(executor.uiState(for: .rideShare).notice)
    }

    // MARK: - 5. Honest identity + the paging bound

    /// A reservation the server could not name renders the NEUTRAL ROLE, never a
    /// persona and never a fabricated initial — the same rule, from the same
    /// resolver, the owner's incoming card uses (MYR-228 / MYR-264).
    @MainActor
    func testANamelessReservationRendersHonestly() async {
        let api = StubReservationAPI(reservations: [
            Self.wire(id: "r1", name: nil, scheduledFor: date(86_400)),
            Self.wire(id: "r2", name: "   ", scheduledFor: date(2 * 86_400))
        ])
        let flow = makeFlow(api)
        await flow.setEnabled(false, vehicleID: "veh-1", executor: makeExecutor(ScriptedRideShareEndpoint()))

        let reservations = flow.warning?.reservations ?? []
        XCTAssertEqual(reservations.map(\.riderFirstName), [nil, nil], "an absent or blank name stays absent")
        XCTAssertEqual(
            reservations.map(RideSharePauseDialog.rowRider), ["A rider", "A rider"],
            "the honest fallback — never an invented name and never an initial"
        )
        XCTAssertEqual(RideSharePauseDialog.unnamedRider, "A rider")
        // "Shared viewer" is an INTERNAL role term. It is the right answer on the
        // incoming card (which is about a person's relationship to the vehicle) and
        // the wrong one in a list of pickups, where it reads as jargon.
        XCTAssertNotEqual(RideSharePauseDialog.unnamedRider, IncomingRequestDisplay.neutralRole)
        for text in reservations.map(RideSharePauseDialog.rowRider) + [RideSharePauseDialog.message] {
            XCTAssertFalse(text.contains("Shared viewer"), "\"Shared viewer\" must never reach this dialog")
            XCTAssertFalse(text.contains("Sam"), "no fixture persona ever reaches this surface")
        }
    }

    /// "Decline it and pause" means ALL of them, so the read follows the cursor —
    /// declining the first page and pausing would strand the rest by the exact
    /// mechanism this issue exists to prevent.
    @MainActor
    func testTheReadFollowsTheCursorSoTheListIsComplete() async {
        let now = Date()
        let api = StubReservationAPI(pages: [
            RideRequestsListResponse(
                items: [Self.wire(id: "r1", name: "Alex", scheduledFor: now.addingTimeInterval(86_400))],
                nextCursor: "PAGE2",
                hasMore: true
            ),
            RideRequestsListResponse(
                items: [Self.wire(id: "r2", name: "Priya", scheduledFor: now.addingTimeInterval(2 * 86_400))],
                hasMore: false
            )
        ])
        let flow = makeFlow(api)
        await flow.setEnabled(false, vehicleID: "veh-1", executor: makeExecutor(ScriptedRideShareEndpoint()))

        XCTAssertEqual(flow.warning?.reservations.map(\.id), ["r1", "r2"])
        let cursors = await api.listedCursors
        XCTAssertEqual(cursors, [nil, "PAGE2"], "the second page is asked for with the server's own cursor")
    }

    // MARK: Helpers

    private func snapshotWithRideShare(_ enabled: Bool) -> VehicleTelemetrySnapshot {
        var snapshot = LiveVehicleTelemetrySource.placeholder
        snapshot.rideShareEnabled = enabled
        return snapshot
    }
}
