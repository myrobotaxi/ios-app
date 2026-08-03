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
    /// Dispatch — "Ride requested from {car}" (MYR-417) over an idle rail. The wait
    /// for a car is the part of an instant ride a rider is most likely to be staring
    /// at a locked phone through, so it is the part that most needs a lock-screen card.
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
    /// arm without that guard would have put a dispatch card on the lock screen
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

    // MARK: - MYR-425: completed is an UPDATE, and the server owns the end

    /// **THE DEFECT, AS ONE ASSERTION.** Prod, r20: every completed ride wrote
    /// `go_live_activities.ended_at = completed_at + ~0.5s` with `alerted_phase`
    /// stuck at 5 — the server's completed announcement and its 5-minute held end
    /// (MYR-421, deployed) never ran, because this line ended the Activity first and
    /// the coordinator's registration release tombstoned the row the server was
    /// about to push to.
    func testACompletedRideUPDATESTheCardRatherThanEndingIt() {
        let record = makeRecord(status: .completed)
        let phase = RideActivityPhase.live(rideID: record.id, state: liveState(.enroute))

        let action = RideActivityStateMachine.action(phase: phase, record: record, vehicleName: "Blue Whale")

        guard case .update(let rideID, let state) = action else {
            return XCTFail("""
            expected .update — an `.end` here is the defect: the Activity leaves the \
            Dynamic Island ~1.4s later whatever the dismissal date says, and the \
            server's alerted update lands on a tombstoned row. Got \(action)
            """)
        }
        XCTAssertEqual(rideID, record.id)
        XCTAssertEqual(state.status, .completed, "the final frame is still written; only the END is deferred")
    }

    func testTheCompletedFrameHoldsTheSERVERSDeliveredFieldsThroughTheUpdatePath() {
        // MYR-423's merge rule, over the path MYR-425 newly routes `completed` down.
        // The local frame asserts the STATUS and holds everything the server said —
        // the completed card would otherwise lose the ETA, the full rail and the
        // "Last updated" instant at the exact moment it becomes the payoff frame.
        var delivered = liveState(.enroute)
        delivered.eta = 1_770_000_000
        delivered.progress = 0.87
        delivered.asOf = 1_769_999_000

        let record = makeRecord(status: .completed)
        let action = RideActivityStateMachine.action(
            phase: .live(rideID: record.id, state: delivered),
            record: record,
            vehicleName: "Blue Whale"
        )

        guard case .update(_, let state) = action else { return XCTFail("expected .update, got \(action)") }
        XCTAssertEqual(state.status, .completed)
        XCTAssertEqual(state.eta, 1_770_000_000, "enroute and completed are the SAME leg, so the ETA is held")
        XCTAssertEqual(state.progress, 0.87)
        XCTAssertEqual(state.asOf, 1_769_999_000, "`asOf` is held across everything — the app is not the server")
    }

    func testAReCOMPOSEDIdenticalCompletedFrameSaysNothingAtAll() {
        // The server's own completed push is a perfectly ordinary way for the card to
        // already say this. Re-writing identical bytes would spend the rider's
        // ActivityKit budget and, worse, would read as the client fighting the server.
        let record = makeRecord(status: .completed)
        let first = RideActivityStateMachine.action(
            phase: .live(rideID: record.id, state: liveState(.enroute)),
            record: record,
            vehicleName: "Blue Whale"
        )
        guard case .update(_, let completedFrame) = first else { return XCTFail("expected .update") }

        XCTAssertEqual(
            RideActivityStateMachine.action(
                phase: .live(rideID: record.id, state: completedFrame),
                record: record,
                vehicleName: "Blue Whale"
            ),
            .none
        )
    }

    func testTheBACKSTOPEndsTheCardFiveMinutesOnWhenNoServerEndArrived() {
        // A dead APNs token, an unregistered ride, a phone that never came back
        // online: the server's held end is not coming, and a finished ride's card
        // must not sit on the lock screen for ever.
        let record = makeRecord(status: .completed)
        let completedAt = Date(timeIntervalSince1970: 1_770_000_000)

        let action = RideActivityStateMachine.action(
            phase: .live(rideID: record.id, state: liveState(.enroute)),
            record: record,
            vehicleName: "Blue Whale",
            completedAt: completedAt,
            now: completedAt.addingTimeInterval(RideActivityCompletedEnd.backstop)
        )

        guard case .end(let rideID, let state, let dismissal) = action else {
            return XCTFail("expected .end at the backstop, got \(action)")
        }
        XCTAssertEqual(rideID, record.id)
        XCTAssertEqual(state.status, .completed, "the same final frame, not a blank one")
        XCTAssertEqual(
            dismissal,
            .immediate,
            """
            `.immediate`, not a second linger: the five minutes this is the far end of \
            have already been served by the card standing there live.
            """
        )
    }

    func testTheBackstopDoesNOTFireOneSecondEarly() {
        let record = makeRecord(status: .completed)
        let completedAt = Date(timeIntervalSince1970: 1_770_000_000)

        let action = RideActivityStateMachine.action(
            phase: .live(rideID: record.id, state: liveState(.enroute)),
            record: record,
            vehicleName: "Blue Whale",
            completedAt: completedAt,
            now: completedAt.addingTimeInterval(RideActivityCompletedEnd.backstop - 1)
        )

        guard case .update = action else {
            return XCTFail("the server's held end is due at exactly +5min; got \(action)")
        }
    }

    func testANULLCompletionInstantIsNEVERElapsed() {
        // The arm that decides whether this fix ships or reproduces the defect. A
        // completion the client learned about through a WS frame carries no server
        // instant; reading absence as "long ago" would end the card at the same
        // moment the old `.completedLinger` rule did.
        XCTAssertFalse(RideActivityCompletedEnd.backstopHasElapsed(completedAt: nil, now: Date()))
        XCTAssertFalse(
            RideActivityCompletedEnd.backstopHasElapsed(
                completedAt: nil,
                now: Date(timeIntervalSince1970: 4_000_000_000)
            )
        )
    }

    func testTheBackstopHorizonIsTheSAMEFiveMinutesTheServerHolds() {
        // MYR-421's held end fires at completed_at + 5min. An equal horizon means the
        // backstop is only ever reached when that end genuinely did not arrive; a
        // longer one would leave a visible gap on every merely-late push.
        XCTAssertEqual(RideActivityCompletedEnd.backstop, 5 * 60)
        XCTAssertEqual(RideActivityDismissal.completedLinger, .linger(RideActivityCompletedEnd.backstop))
    }

    func testAFinalFrameIsTheONLYKindThatCarriesNoStaleDate() {
        // `completed` reaches the UPDATE path now, and `RideActivityStaleness.window`
        // is THREE minutes against a five-minute wait — so without this the arrival
        // card would grey itself out before the server's end even arrives.
        XCTAssertTrue(RideActivityCompletedEnd.isFinalFrame(.completed))
        XCTAssertTrue(RideActivityCompletedEnd.isFinalFrame(.declined))
        XCTAssertTrue(RideActivityCompletedEnd.isFinalFrame(.cancelled))
        XCTAssertTrue(RideActivityCompletedEnd.isFinalFrame(.reservationExpired))
        for running in [LiveActivityRideStatus.requested, .accepted, .arrived, .enroute] {
            XCTAssertFalse(
                RideActivityCompletedEnd.isFinalFrame(running),
                "a running ride CAN move on without us — that is what staleness is for"
            )
        }
    }

    func testTheActionsThatContinueTheHeldCardAreExactlyTheTwoQuietOnes() {
        // The backstop arms off this rather than off a list of case names, so an
        // action added later has to answer the question instead of falling outside it.
        let state = liveState(.completed)
        XCTAssertTrue(RideActivityAction.none.continuesTheHeldCard)
        XCTAssertTrue(RideActivityAction.update(rideID: "r", state: state).continuesTheHeldCard)
        XCTAssertFalse(RideActivityAction.start(rideID: "r", state: state).continuesTheHeldCard)
        XCTAssertFalse(
            RideActivityAction.end(rideID: "r", state: state, dismissal: .immediate).continuesTheHeldCard
        )
        XCTAssertFalse(
            RideActivityAction.restart(
                endingRideID: "r", endingState: state, rideID: "r2", state: state
            ).continuesTheHeldCard
        )
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

    func testNoTerminalRouteEverLeavesTheActivitySayingSomethingUNTRUE() {
        // Was "every terminal route ENDS the Activity". MYR-425 splits that in two:
        // `declined` and the cancellation erasure still end it, and `completed`
        // writes its final frame and waits for the server. What no terminal route may
        // do is stay silent on a card still claiming the ride is in progress.
        let phase = RideActivityPhase.live(rideID: "ride-1", state: liveState(.enroute))

        for record in [makeRecord(id: "ride-1", status: .declined), nil] {
            let action = RideActivityStateMachine.action(phase: phase, record: record, vehicleName: "Blue Whale")
            switch action {
            case .end: break
            default: XCTFail("expected .end for \(String(describing: record?.status)), got \(action)")
            }
        }

        let completed = RideActivityStateMachine.action(
            phase: phase, record: makeRecord(id: "ride-1", status: .completed), vehicleName: "Blue Whale"
        )
        guard case .update(_, let state) = completed else {
            return XCTFail("expected .update for completed, got \(completed)")
        }
        XCTAssertEqual(state.status, .completed, "the card must never be left saying 'On the way'")
    }

    /// **THE RIDER TAPPING DONE ON THE SUMMARY IS NOT A CANCELLATION — MYR-425.**
    ///
    /// A newly reachable arm, and a nasty one. Dismissing the post-ride summary nils
    /// `activeRequest`, which this machine reads as the wire's `cancelled` (the
    /// record is ERASED rather than transitioned). Before this issue the completed
    /// card had already been ended by then, so the `nil` found nothing; now the card
    /// is live for five minutes, and an unguarded erasure would relabel the arrival
    /// "Ride cancelled" and take it down early — this issue's own defect, reached
    /// through the summary's Done button.
    func testAnERASUREOverACompletedCardIsNotACancellation() {
        let completedCard = RideActivityPhase.live(rideID: "ride-1", state: liveState(.completed))

        XCTAssertEqual(
            RideActivityStateMachine.action(phase: completedCard, record: nil, vehicleName: "Blue Whale"),
            .none,
            "the record going away says nothing at all about a card that already announced the arrival"
        )
    }

    func testTheBackstopStillAppliesOnceTheRecordIsGone() {
        // The other half: the ride is over either way, so the deadline is the only
        // thing that can still end the card locally — and it must survive the record.
        let completedAt = Date(timeIntervalSince1970: 1_770_000_000)

        let action = RideActivityStateMachine.action(
            phase: .live(rideID: "ride-1", state: liveState(.completed)),
            record: nil,
            vehicleName: "Blue Whale",
            completedAt: completedAt,
            now: completedAt.addingTimeInterval(RideActivityCompletedEnd.backstop)
        )

        guard case .end(_, let state, let dismissal) = action else {
            return XCTFail("expected .end at the backstop, got \(action)")
        }
        XCTAssertEqual(state.status, .completed, "and it goes out as an arrival, not as a cancellation")
        XCTAssertEqual(dismissal, .immediate)
    }

    func testANEWRideEndsACompletedCardWITHOUTRelabellingItCancelled() {
        // The `.restart` arm corrects a replaced card to `cancelled` because it "is
        // over and did not complete" — simply false of an arrival, and a branch a
        // completed card could not reach before MYR-425 (an `.ended` card was skipped
        // by the reaper rather than restarted over).
        let action = RideActivityStateMachine.action(
            phase: .live(rideID: "ride-1", state: liveState(.completed)),
            record: makeRecord(id: "ride-2", status: .accepted),
            vehicleName: "Blue Whale"
        )

        guard case .restart(let endingRideID, let endingState, let rideID, _) = action else {
            return XCTFail("expected .restart, got \(action)")
        }
        XCTAssertEqual(endingRideID, "ride-1")
        XCTAssertEqual(rideID, "ride-2")
        XCTAssertEqual(endingState.status, .completed, "the client's rule is 'clear banners', not 'relabel them'")
    }

    func testAReplacedRideThatDidNOTCompleteIsStillCorrectedToCancelled() {
        // The guard above must not swallow the case it was carved out of.
        let action = RideActivityStateMachine.action(
            phase: .live(rideID: "ride-1", state: liveState(.enroute)),
            record: makeRecord(id: "ride-2", status: .accepted),
            vehicleName: "Blue Whale"
        )

        guard case .restart(_, let endingState, _, _) = action else {
            return XCTFail("expected .restart, got \(action)")
        }
        XCTAssertEqual(endingState.status, .cancelled)
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
        // `accepted → arrived` — the SAME leg (pickup). Nothing about the car's
        // reported arrival instant is invalidated by reaching the kerb.
        let record = makeRecord(id: "ride-1", status: .arrived)

        guard case .update(_, let state) = RideActivityStateMachine.action(
            phase: phase, record: record, vehicleName: "Client Name"
        ) else { return XCTFail("expected .update") }

        XCTAssertEqual(state.vehicleName, "Server Name")
        XCTAssertEqual(
            state.eta,
            1_785_535_200,
            "carrying the previous instant forward is not a guess — an instant does not decay"
        )
        XCTAssertEqual(state.status, .arrived, "but the local status change IS applied")
    }

    /// **⚠️ THIS ASSERTION REVERSES ONE THIS TEST FILE USED TO MAKE, DELIBERATELY —
    /// MYR-423.** The case above was originally written against `.enroute`, i.e. it
    /// pinned a PICKUP ETA surviving the flip to the DROPOFF leg. That was harmless
    /// for as long as it was unreachable: the coordinator fed `previous` from its own
    /// last locally-composed frame, whose `eta` is nil by construction, so no real
    /// frame ever carried an instant across a flip and the assertion was about a
    /// hypothetical. MYR-423 makes `previous` the frame ActivityKit is actually
    /// rendering — push included — so it is reachable now, and it is a lie:
    /// `RideActivityCopy.showsFigure` is true for `accepted` AND `enroute`, and
    /// `RideActivityCard.figure` reads a pickup ETA as a countdown and a dropoff ETA
    /// as a CLOCK TIME. The car's arrival at the kerb would be restated as the moment
    /// the rider is dropped off.
    func testTheLegFlipDropsThePickupETARatherThanRestatingItAsADropoffTime() {
        let pushed = RideActivityAttributes.ContentState(
            status: .accepted,
            eta: 1_785_535_200,
            vehicleName: "Server Name",
            destination: "Home",
            progress: 1.0,
            asOf: 1_785_534_900
        )
        let phase = RideActivityPhase.live(rideID: "ride-1", state: pushed)
        let record = makeRecord(id: "ride-1", status: .enroute)

        guard case .update(_, let state) = RideActivityStateMachine.action(
            phase: phase, record: record, vehicleName: "Client Name"
        ) else { return XCTFail("expected .update") }

        XCTAssertEqual(state.status, .enroute)
        XCTAssertNil(state.eta, "leg one's arrival instant is not leg two's dropoff clock")
        XCTAssertNil(state.progress, "MYR-398's rule, unchanged: leg one ends at 1, leg two opens near 0")
        XCTAssertEqual(
            state.asOf,
            1_785_534_900,
            """
            `asOf` is the one server field that is NOT leg-scoped: it says when the \
            server last learned something about this RIDE, which a leg flip does not \
            change.
            """
        )
        XCTAssertEqual(state.vehicleName, "Server Name", "and the car is the same car")
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

    func testNOTHINGTheClientEndsLingersAnyMore() {
        // MYR-425 — `completed` was the only status that lingered client-side, and it
        // is no longer ended by the client at all. Every end the client still issues
        // is `.immediate`: `declined` (unchanged), the cancellation ERASURE
        // (unchanged), and the backstop.
        let completed = RideActivityStateMachine.action(
            phase: .live(rideID: "ride-1", state: liveState(.enroute)),
            record: makeRecord(status: .completed),
            vehicleName: "Blue Whale"
        )
        guard case .update = completed else {
            return XCTFail("the client does not end a completed ride any more; got \(completed)")
        }

        let declined = RideActivityStateMachine.action(
            phase: .live(rideID: "ride-1", state: liveState(.enroute)),
            record: makeRecord(status: .declined),
            vehicleName: "Blue Whale"
        )
        guard case .end(_, _, let declinedDismissal) = declined else {
            return XCTFail("expected .end, got \(declined)")
        }
        XCTAssertEqual(declinedDismissal, .immediate, "there is no arrival to admire")

        let erased = RideActivityStateMachine.action(
            phase: .live(rideID: "ride-1", state: liveState(.enroute)),
            record: nil,
            vehicleName: "Blue Whale"
        )
        guard case .end(_, _, let cancelledDismissal) = erased else {
            return XCTFail("expected .end, got \(erased)")
        }
        XCTAssertEqual(cancelledDismissal, .immediate, "a cancellation is byte-identical to before MYR-425")
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
