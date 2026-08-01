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

    /// **THE ACTIVITY NOW STARTS AT REQUEST** — MYR-398 v3, client-directed, and the
    /// reversal of MYR-172's "start at ACCEPTED".
    ///
    /// The v3 board answers "a pending request is the app's job" with a STATE:
    /// Dispatch, "Finding your ride" over an idle rail. The wait for a car is the
    /// part of an instant ride a rider is most likely to be staring at a locked
    /// phone through, so it is the part that most needs a lock-screen card.
    func testAnINSTANTRequestSTARTSTheActivityAtRequestedTime() {
        let record = makeRecord(status: .pending)

        let action = RideActivityStateMachine.action(
            phase: .idle,
            record: record,
            vehicleName: "Blue Whale"
        )

        guard case .start(let rideID, let state) = action else {
            return XCTFail("expected .start, got \(action)")
        }
        XCTAssertEqual(rideID, record.id)
        XCTAssertEqual(state.status, .requested, "the wire status behind the Dispatch card")
        XCTAssertNil(state.eta, "no car is assigned, so there is nothing to count down")
        XCTAssertNil(state.progress, "and nothing to be part-way along — the rail is idle")
    }

    /// **A SCHEDULED RIDE STILL STARTS NOTHING AT REQUEST TIME**, and that is the
    /// half of the new start point that could have gone wrong quietly.
    ///
    /// It falls out of the DORMANCY guard rather than out of the status switch: a
    /// `pending` reservation is dormant at every moment before it is dispatched, so
    /// it never reaches the `.pending` arm at all. An implementation that opened the
    /// arm without that guard would have put "Finding your ride" on the lock screen
    /// the moment somebody booked a car for Saturday, and left it there.
    func testAScheduledRequestStillStartsNothing() {
        let scheduled = makeRecord(status: .pending, schedule: RideSchedule(day: "Sat", time: "5:30 PM"))

        XCTAssertEqual(
            RideActivityStateMachine.action(phase: .idle, record: scheduled, vehicleName: "Blue Whale"),
            .none
        )
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

    func testACompletedRideEndsWithTheFiveMinuteLinger() {
        // MYR-405 SUPERSEDES MYR-194's ~15 minutes, by client decision on
        // 2026-07-31: "when ride is complete we should clear banners after 5min".
        let record = makeRecord(status: .completed)
        let phase = RideActivityPhase.live(rideID: record.id, state: liveState(.enroute))

        let action = RideActivityStateMachine.action(phase: phase, record: record, vehicleName: "Blue Whale")

        guard case .end(let rideID, let state, let dismissal) = action else {
            return XCTFail("expected .end, got \(action)")
        }
        XCTAssertEqual(rideID, record.id)
        XCTAssertEqual(state.status, .completed)
        XCTAssertEqual(dismissal, .linger(5 * 60))
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

    /// A DIFFERENT ride that cannot open a card of its own just ends the old one.
    ///
    /// **The fixture had to change with the v3 start point**: this used to be a
    /// `pending` ride, which is now startable (Dispatch), so the case is reached with
    /// a DORMANT reservation instead — still the only kind of open ride that may hold
    /// no Activity.
    func testADIFFERENTRideThatIsNotStartableJustEndsTheOldOne() {
        let phase = RideActivityPhase.live(rideID: "ride-1", state: liveState(.enroute))
        let dormant = makeRecord(
            id: "ride-2",
            status: .accepted,
            schedule: RideSchedule(day: "Sat", time: "5:30 PM")
        )

        let action = RideActivityStateMachine.action(phase: phase, record: dormant, vehicleName: "Blue Whale")

        guard case .end(let rideID, _, let dismissal) = action else {
            return XCTFail("expected .end, got \(action)")
        }
        XCTAssertEqual(rideID, "ride-1")
        XCTAssertEqual(dismissal, .immediate)
    }

    /// **A NEW INSTANT REQUEST NOW RESTARTS**, which is the other side of the same
    /// change: a rider whose previous ride ended while the app was away and who has
    /// already requested another gets the second ride's Dispatch card rather than
    /// nothing at all.
    func testADIFFERENTRideThatIsANewREQUESTRestarts() {
        let phase = RideActivityPhase.live(rideID: "ride-1", state: liveState(.enroute))
        let newRequest = makeRecord(id: "ride-2", status: .pending)

        let action = RideActivityStateMachine.action(phase: phase, record: newRequest, vehicleName: "Blue Whale")

        guard case .restart(let endingID, _, let rideID, let state) = action else {
            return XCTFail("expected .restart, got \(action)")
        }
        XCTAssertEqual(endingID, "ride-1")
        XCTAssertEqual(rideID, "ride-2")
        XCTAssertEqual(state.status, .requested)
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

    // MARK: - MYR-405: reconciling what the SYSTEM restored

    func testTheLIVERidesRestoredCardIsADOPTEDAndEveryOtherOneIsREAPED() {
        let plan = RideActivityStateMachine.reconcile(
            snapshots: [
                snapshot("stale-orphan"),
                snapshot("ride-1"),
                snapshot("another-orphan", .stale)
            ],
            liveRide: .live(rideID: "ride-1")
        )

        XCTAssertEqual(plan.adopt, "ride-1")
        XCTAssertEqual(plan.reap, ["stale-orphan", "another-orphan"])
        XCTAssertTrue(
            !plan.isDuplicateOfAdopted("stale-orphan"),
            "an orphan's (ride, rider) registration is genuinely dead and should be dropped"
        )
    }

    func testASECONDCardForTheSameRideIsReapedButItsREGISTRATIONIsNot() {
        // The client's exact frame. One is kept; the other comes down. The §7.21
        // delete is keyed on the RIDE, so issuing it would delete the registration
        // belonging to the banner just adopted — re-creating the starvation this
        // whole issue is about, from inside the fix.
        let plan = RideActivityStateMachine.reconcile(
            snapshots: [snapshot("ride-1"), snapshot("ride-1")],
            liveRide: .live(rideID: "ride-1")
        )

        XCTAssertEqual(plan.adopt, "ride-1")
        XCTAssertEqual(plan.reap, ["ride-1"])
        XCTAssertTrue(plan.isDuplicateOfAdopted("ride-1"))
    }

    func testAnUNRESOLVEDRideReapsNothingAndAdoptsNothing() {
        // `.unresolved` is a real third arm, and leaving it out is how the reaper
        // would eat the card it exists to protect: on a cold launch a nil record
        // means "§7.8 has not answered", not "this rider has no ride".
        let plan = RideActivityStateMachine.reconcile(
            snapshots: [snapshot("ride-1"), snapshot("ride-2")],
            liveRide: .unresolved
        )

        XCTAssertTrue(plan.reap.isEmpty)
        XCTAssertNil(plan.adopt)
    }

    func testAnACCOUNTWithNoRideMakesEveryOnScreenCardAnOrphan() {
        let plan = RideActivityStateMachine.reconcile(
            snapshots: [snapshot("ride-1"), snapshot("ride-2")],
            liveRide: .none
        )

        XCTAssertEqual(plan.reap, ["ride-1", "ride-2"])
        XCTAssertNil(plan.adopt)
    }

    func testAnENDEDCardIsSKIPPEDSoItsDismissalPolicyIsAllowedToRun() {
        // `.ended` means the system is already taking it down on the policy it was
        // given — for a completed ride, MYR-405's own five minutes.
        let plan = RideActivityStateMachine.reconcile(
            snapshots: [snapshot("ride-done", .ended)],
            liveRide: .none
        )

        XCTAssertTrue(plan.reap.isEmpty)
        XCTAssertNil(plan.adopt)
        XCTAssertTrue(plan.dismissed.isEmpty, "ended is the APP's doing; dismissed is the RIDER's")
    }

    func testADISMISSEDCardIsRememberedRatherThanReapedOrAdopted() {
        let plan = RideActivityStateMachine.reconcile(
            snapshots: [snapshot("ride-1", .dismissed)],
            liveRide: .live(rideID: "ride-1")
        )

        XCTAssertEqual(plan.dismissed, ["ride-1"])
        XCTAssertTrue(plan.reap.isEmpty, "nothing is on screen to reap")
        XCTAssertNil(plan.adopt, "and nothing is on screen to adopt")
    }

    // MARK: - MYR-405: resolving the account's ride

    func testAnUnansweredPipelineResolvesUNRESOLVEDWhateverTheRecordSays() {
        XCTAssertEqual(
            RideActivityAccountRide(record: nil, isResolved: false).resolve(),
            .unresolved
        )
        XCTAssertEqual(
            RideActivityAccountRide(record: makeRecord(status: .enroute), isResolved: false).resolve(),
            .unresolved
        )
    }

    func testACOMPLETEDRideStillOWNSItsCard() {
        // Not reaped as an orphan: the state machine has to be the one that ends it,
        // because only the state machine knows to end it on the five-minute linger
        // rather than immediately.
        XCTAssertEqual(
            RideActivityAccountRide(record: makeRecord(status: .completed), isResolved: true).resolve(),
            .live(rideID: "ride-1")
        )
    }

    func testADORMANTReservationOwnsNOCardAtAll() {
        // The same `RideReservation.isLiveRide` gate `startState` consults, so
        // "which ride may hold a card" is ONE rule rather than two that can drift.
        // A reservation accepted for Saturday is not the ride the rider is on today.
        let record = makeRecord(status: .accepted, schedule: RideSchedule(day: "Sat", time: "5:30 PM"))

        XCTAssertEqual(
            RideActivityAccountRide(record: record, isResolved: true).resolve(),
            RideActivityLiveRide.none
        )
    }

    // MARK: - MYR-405: the rider's swipe

    func testADISMISSEDRideNeverStartsAgain() {
        let action = RideActivityStateMachine.action(
            phase: .idle,
            record: makeRecord(status: .enroute),
            vehicleName: "Blue Whale",
            dismissedRideIDs: ["ride-1"]
        )

        XCTAssertEqual(action, .none)
    }

    func testADIFFERENTRideAfterADismissalStartsNormally() {
        let action = RideActivityStateMachine.action(
            phase: .idle,
            record: makeRecord(id: "ride-2", status: .accepted),
            vehicleName: "Blue Whale",
            dismissedRideIDs: ["ride-1"]
        )

        guard case .start(let rideID, _) = action else {
            return XCTFail("a dismissal is a decision about ONE ride, got \(action)")
        }
        XCTAssertEqual(rideID, "ride-2")
    }

    func testReplacingALiveRideWithADISMISSEDOneEndsRatherThanRestarts() {
        let action = RideActivityStateMachine.action(
            phase: .live(rideID: "ride-1", state: liveState(.enroute)),
            record: makeRecord(id: "ride-2", status: .accepted),
            vehicleName: "Blue Whale",
            dismissedRideIDs: ["ride-2"]
        )

        guard case .end(let rideID, _, let dismissal) = action else {
            return XCTFail("expected .end, got \(action)")
        }
        XCTAssertEqual(rideID, "ride-1")
        XCTAssertEqual(dismissal, .immediate)
    }

    // MARK: - MYR-405: five minutes, and what it is NOT

    func testTheCompletedLingerIsNotTheServersPushExpiration() {
        // The linger is a CLIENT-SIDE END POLICY and has nothing to do with the
        // server's 24h-floored APNs push expiration (MYR-398 review). That number
        // governs how long APNs keeps TRYING to deliver a push; this one governs how
        // long a finished ride stays on the rider's lock screen. Written down as an
        // assertion because the two are one plausible refactor apart.
        XCTAssertEqual(RideActivityDismissal.completedLinger, .linger(5 * 60))
        XCTAssertNotEqual(RideActivityDismissal.completedLinger, .linger(24 * 60 * 60))
    }

    func testOnlyACompletedRideLingersAtAll() {
        let completed = RideActivityStateMachine.action(
            phase: .live(rideID: "ride-1", state: liveState(.enroute)),
            record: makeRecord(status: .completed),
            vehicleName: "Blue Whale"
        )
        guard case .end(_, _, let completedDismissal) = completed else {
            return XCTFail("expected .end, got \(completed)")
        }
        XCTAssertEqual(completedDismissal, .completedLinger)

        let declined = RideActivityStateMachine.action(
            phase: .live(rideID: "ride-1", state: liveState(.enroute)),
            record: makeRecord(status: .declined),
            vehicleName: "Blue Whale"
        )
        guard case .end(_, _, let declinedDismissal) = declined else {
            return XCTFail("expected .end, got \(declined)")
        }
        XCTAssertEqual(declinedDismissal, .immediate, "there is no arrival to admire")
    }

    // MARK: - Fixtures

    private func snapshot(
        _ rideID: String,
        _ lifecycle: RideActivitySnapshot.Lifecycle = .active
    ) -> RideActivitySnapshot {
        RideActivitySnapshot(rideID: rideID, lifecycle: lifecycle)
    }

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
