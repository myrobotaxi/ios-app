import CoreLocation
import MyRobotaxiContracts
import XCTest
@testable import MyRoboTaxi

// MARK: - The lifecycle, without ActivityKit (MYR-172)
//
// ActivityKit cannot run in a unit test, so the lifecycle is asserted where it
// actually lives: a pure function of (what we last did, what the ride looks like
// now). Same split as MYR-186's `PushPermissionMoment.decide`.

final class RideActivityStateMachineTests: XCTestCase {

    // MARK: - Starting

    func testAnAcceptedRideStartsTheActivity() {
        let record = makeRecord(status: .accepted)

        let action = RideActivityStateMachine.action(
            phase: .idle,
            record: record,
            vehicleName: "Blue Whale"
        )

        guard case .start(let rideID, let state) = action else {
            return XCTFail("expected .start, got \(action)")
        }
        XCTAssertEqual(rideID, record.id)
        XCTAssertEqual(state.status, .accepted)
        XCTAssertEqual(state.vehicleName, "Blue Whale")
        XCTAssertEqual(state.destination, "Home")
    }

    func testAPendingRequestDoesNotStartAnActivity() {
        // "start at ACCEPTED — a pending request is the app's job" (MYR-172). A
        // request nobody has answered has no car assigned and nothing to count
        // down.
        let action = RideActivityStateMachine.action(
            phase: .idle,
            record: makeRecord(status: .pending),
            vehicleName: "Blue Whale"
        )

        XCTAssertEqual(action, .none)
    }

    func testNoRideAtAllDoesNothing() {
        XCTAssertEqual(
            RideActivityStateMachine.action(phase: .idle, record: nil, vehicleName: "Blue Whale"),
            .none
        )
    }

    func testAnArrivedOrEnrouteRideStartsToo_soColdLaunchAdoptionIsCovered() {
        // The app adopts a rider's already-open ride on cold launch (MYR-230). A
        // rider who force-quit mid-ride and reopened would otherwise get no Activity
        // for the rest of the trip.
        for status in [MyRoboTaxi.RideRequestStatus.arrived, .enroute] {
            let action = RideActivityStateMachine.action(
                phase: .idle,
                record: makeRecord(status: status),
                vehicleName: "Blue Whale"
            )
            guard case .start = action else {
                return XCTFail("expected .start for \(status), got \(action)")
            }
        }
    }

    func testAnAlreadyFinishedRideDoesNotStartAnActivityJustToEndIt() {
        for status in [MyRoboTaxi.RideRequestStatus.completed, .declined] {
            XCTAssertEqual(
                RideActivityStateMachine.action(
                    phase: .idle,
                    record: makeRecord(status: status),
                    vehicleName: "Blue Whale"
                ),
                .none,
                "\(status) must not put a card on the lock screen announcing something that already ended"
            )
        }
    }

    func testAScheduledRideDoesNotStartAnActivityEvenOnceAccepted() {
        // MYR-313 lets a reservation be accepted days ahead. An Activity started
        // here would sit on the lock screen until Saturday. This must agree with
        // `SharedViewerScreen.reconciledPhase`, which gates the tracking sheet on
        // exactly `!hasSchedule`.
        let scheduled = makeRecord(status: .accepted, schedule: RideSchedule(day: "Sat", time: "5:30 PM"))

        XCTAssertEqual(
            RideActivityStateMachine.action(phase: .idle, record: scheduled, vehicleName: "Blue Whale"),
            .none
        )
    }

    func testTheStartFrameCarriesNoLocallyInventedETA() {
        // The schema's ETA is the CAR'S OWN nav ETA, which only the server has:
        // "never null, never zero, never a guess". The app knows a
        // `destination.minutes` estimate and must not turn it into one.
        let record = makeRecord(status: .accepted, destinationMinutes: 27)

        guard case .start(_, let state) = RideActivityStateMachine.action(
            phase: .idle, record: record, vehicleName: "Blue Whale"
        ) else { return XCTFail("expected .start") }

        XCTAssertNil(
            state.eta,
            "a locally started Activity opens with NO countdown and gains one when the first push lands"
        )
    }

    // MARK: - Ending

    func testACompletedRideEndsWithTheFifteenMinuteLinger() {
        let record = makeRecord(status: .completed)
        let phase = RideActivityPhase.live(rideID: record.id, state: liveState(.enroute))

        let action = RideActivityStateMachine.action(phase: phase, record: record, vehicleName: "Blue Whale")

        guard case .end(let rideID, let state, let dismissal) = action else {
            return XCTFail("expected .end, got \(action)")
        }
        XCTAssertEqual(rideID, record.id)
        XCTAssertEqual(state.status, .completed)
        XCTAssertEqual(dismissal, .linger(15 * 60))
        XCTAssertEqual(dismissal, .completedLinger)
    }

    func testADeclinedRideEndsImmediately() {
        let record = makeRecord(status: .declined)
        let phase = RideActivityPhase.live(rideID: record.id, state: liveState(.accepted))

        let action = RideActivityStateMachine.action(phase: phase, record: record, vehicleName: "Blue Whale")

        guard case .end(_, let state, let dismissal) = action else {
            return XCTFail("expected .end, got \(action)")
        }
        XCTAssertEqual(state.status, .declined)
        XCTAssertEqual(
            dismissal,
            .immediate,
            "there is no arrival to admire; a declined card is clutter about a non-event"
        )
    }

    func testACANCELLEDRideIsAnERASUREAndStillEndsTheActivity() {
        // THE SUBTLE ONE. `LiveRideRequestService.integrate` maps the wire's
        // `cancelled` to NO app status, so `activeRequest` is set to nil outright.
        // If the machine treated nil as "nothing to do", the card would stay on the
        // lock screen forever for a ride that no longer exists.
        let phase = RideActivityPhase.live(rideID: "ride-1", state: liveState(.accepted))

        let action = RideActivityStateMachine.action(phase: phase, record: nil, vehicleName: "Blue Whale")

        guard case .end(let rideID, let state, let dismissal) = action else {
            return XCTFail("expected .end on erasure, got \(action)")
        }
        XCTAssertEqual(rideID, "ride-1")
        XCTAssertEqual(dismissal, .immediate)
        XCTAssertEqual(
            state.status,
            .cancelled,
            "the last known frame is corrected to cancelled — the ride is over and it did not complete"
        )
        XCTAssertEqual(
            state.destination,
            "Home",
            """
            and it keeps the car and destination from the last known frame, which is \
            the whole reason the phase carries one: at the moment we most need to \
            write a final frame there is no record left to build one from.
            """
        )
    }

    func testSignOutStyleErasureNeverLeavesTheActivityRunning() {
        // Every terminal route ends the Activity — none of them returns .none.
        let phase = RideActivityPhase.live(rideID: "ride-1", state: liveState(.enroute))

        for record in [makeRecord(id: "ride-1", status: .completed), makeRecord(id: "ride-1", status: .declined), nil] {
            let action = RideActivityStateMachine.action(phase: phase, record: record, vehicleName: "Blue Whale")
            switch action {
            case .end: break
            default: XCTFail("expected .end for \(String(describing: record?.status)), got \(action)")
            }
        }
    }

    // MARK: - Updating

    func testAStatusChangeOnTheLiveRideUpdatesIt() {
        let record = makeRecord(id: "ride-1", status: .enroute)
        let phase = RideActivityPhase.live(rideID: "ride-1", state: liveState(.accepted))

        let action = RideActivityStateMachine.action(phase: phase, record: record, vehicleName: "Blue Whale")

        guard case .update(let rideID, let state) = action else {
            return XCTFail("expected .update, got \(action)")
        }
        XCTAssertEqual(rideID, "ride-1")
        XCTAssertEqual(state.status, .enroute)
    }

    func testAnUNCHANGEDRideProducesNoUpdateAtAll() {
        // The coordinator is driven by `.onChange` on the WHOLE record, which fires
        // for `trackProgress` ticks the Activity does not carry. Every no-op update
        // would spend part of the rider's ActivityKit budget saying nothing.
        var record = makeRecord(id: "ride-1", status: .accepted)
        let phase = RideActivityPhase.live(
            rideID: "ride-1",
            state: RideActivityStateMachine.contentState(for: record, vehicleName: "Blue Whale", previous: nil)
        )

        record.trackProgress = 0.42 // the field the Activity does not carry

        XCTAssertEqual(
            RideActivityStateMachine.action(phase: phase, record: record, vehicleName: "Blue Whale"),
            .none
        )
    }

    func testTheSERVERSVehicleNameAndETAOutrankTheClientsOnAnUpdate() {
        // Pushes are the truth (MYR-194 decision 2). Once a push has supplied a name
        // and an instant, a local update must not overwrite them with whatever the
        // client happens to have resolved.
        let pushed = RideActivityAttributes.ContentState(
            status: .accepted,
            eta: 1_785_535_200,
            vehicleName: "Server Name",
            destination: "Home"
        )
        let phase = RideActivityPhase.live(rideID: "ride-1", state: pushed)
        let record = makeRecord(id: "ride-1", status: .enroute)

        guard case .update(_, let state) = RideActivityStateMachine.action(
            phase: phase, record: record, vehicleName: "Client Name"
        ) else { return XCTFail("expected .update") }

        XCTAssertEqual(state.vehicleName, "Server Name")
        XCTAssertEqual(
            state.eta,
            1_785_535_200,
            "carrying the previous instant forward is not a guess — an instant does not decay"
        )
        XCTAssertEqual(state.status, .enroute, "but the local status change IS applied")
    }

    // MARK: - Ride swap

    func testADIFFERENTOpenRideEndsTheOldActivityAndStartsANewOne() {
        let phase = RideActivityPhase.live(rideID: "ride-1", state: liveState(.enroute))
        let newRide = makeRecord(id: "ride-2", status: .accepted)

        let action = RideActivityStateMachine.action(phase: phase, record: newRide, vehicleName: "Blue Whale")

        guard case .restart(let endingID, let endingState, let rideID, let state) = action else {
            return XCTFail("expected .restart, got \(action)")
        }
        XCTAssertEqual(endingID, "ride-1")
        XCTAssertEqual(endingState.status, .cancelled)
        XCTAssertEqual(rideID, "ride-2")
        XCTAssertEqual(state.status, .accepted)
    }

    func testADIFFERENTRideThatIsNotStartableJustEndsTheOldOne() {
        let phase = RideActivityPhase.live(rideID: "ride-1", state: liveState(.enroute))
        let newPending = makeRecord(id: "ride-2", status: .pending)

        let action = RideActivityStateMachine.action(phase: phase, record: newPending, vehicleName: "Blue Whale")

        guard case .end(let rideID, _, let dismissal) = action else {
            return XCTFail("expected .end, got \(action)")
        }
        XCTAssertEqual(rideID, "ride-1")
        XCTAssertEqual(dismissal, .immediate)
    }

    // MARK: - Status mapping

    func testEveryAppStatusMapsToItsContractTwin() {
        XCTAssertEqual(RideActivityStateMachine.wireStatus(for: .pending), .requested)
        XCTAssertEqual(RideActivityStateMachine.wireStatus(for: .accepted), .accepted)
        XCTAssertEqual(RideActivityStateMachine.wireStatus(for: .arrived), .arrived)
        XCTAssertEqual(RideActivityStateMachine.wireStatus(for: .enroute), .enroute)
        XCTAssertEqual(RideActivityStateMachine.wireStatus(for: .completed), .completed)
        XCTAssertEqual(RideActivityStateMachine.wireStatus(for: .declined), .declined)
        // There is deliberately no `cancelled` arm: the app has no such status to
        // map FROM — the wire's `cancelled` is an erasure client-side.
    }

    // MARK: - Fixtures

    private func makeRecord(
        id: String = "ride-1",
        status: MyRoboTaxi.RideRequestStatus,
        schedule: RideSchedule? = nil,
        destinationMinutes: Int = 12
    ) -> RideRequestRecord {
        let place = RidePlace(
            id: "dest",
            label: "Home",
            subtitle: nil,
            miles: 4.2,
            minutes: destinationMinutes,
            icon: "house.fill",
            coordinate: CLLocationCoordinate2D(latitude: 37.77, longitude: -122.39)
        )
        let pickup = RidePlace(
            id: "pickup",
            label: "Current location",
            subtitle: nil,
            miles: 0,
            minutes: 0,
            icon: "location.fill",
            coordinate: CLLocationCoordinate2D(latitude: 37.78, longitude: -122.40)
        )
        var record = RideRequestRecord(
            id: id,
            input: RideRequestInput(
                pickup: pickup,
                destination: place,
                fleetMemberID: "vehicle-1",
                schedule: schedule
            ),
            status: status
        )
        record.status = status
        return record
    }

    private func liveState(_ status: LiveActivityRideStatus) -> RideActivityAttributes.ContentState {
        RideActivityAttributes.ContentState(
            status: status,
            vehicleName: "Blue Whale",
            destination: "Home"
        )
    }
}
