import CoreLocation
@testable import MyRoboTaxi
import MyRoboTaxiKit
import MyRobotaxiContracts
import XCTest

// MARK: - MYR-376 / MYR-377 — the reservation lifecycle, both roles
//
// TestFlight r13 (build 202607310302). The client scheduled a ride for the NEXT
// DAY, accepted it as the owner, and got the live dispatch card a day early over a
// parked car — while the rider half of the same account saw nothing at all: an
// empty Scheduled tab, no tracking card, no "Start ride", no Live Activity. His
// verbatim: *"Rider flow is completely broken."*
//
// Everything asserted here is PURE. The gates are the ones the surfaces read, so a
// regression on any of them fails a test rather than a screenshot nobody takes.
private typealias AppRideStatus = MyRoboTaxi.RideRequestStatus
private typealias WireRideStatus = MyRobotaxiContracts.RideRequestStatus

final class RideReservationLifecycleTests: XCTestCase {

    // MARK: - Dormancy (the record-level model)

    func testAnInstantRideIsNeverDormantAtAnyStatus() {
        for status in Self.everyStatus {
            let record = Self.instantRecord(status: status)
            XCTAssertFalse(
                RideReservation.isDormant(record),
                "an on-demand ride carries no schedule, so dormancy cannot apply to it (\(status))"
            )
            XCTAssertTrue(RideReservation.isLiveRide(record))
        }
    }

    func testAnAcceptedReservationForTomorrowIsDormant() {
        let record = Self.reservation(status: .accepted, scheduledFor: Self.tomorrow)
        XCTAssertTrue(RideReservation.isDormant(record))
        XCTAssertFalse(RideReservation.isLiveRide(record))
    }

    func testARequestedReservationIsDormantEvenPastItsDueMoment() {
        // Nobody accepted it, so there is nothing to proceed WITH. The server
        // expires it; until then the honest client answer is that it never
        // happened.
        let record = Self.reservation(status: .pending, scheduledFor: Self.anHourAgo)
        XCTAssertTrue(RideReservation.isDormant(record))
    }

    func testDispatchEndsDormancyOnEitherFieldAlone() {
        var stamped = Self.reservation(status: .accepted, scheduledFor: Self.tomorrow)
        stamped.dispatchedAt = Date()
        XCTAssertFalse(RideReservation.isDormant(stamped), "the exactly-once latch is dispatch")

        var resolved = Self.reservation(status: .accepted, scheduledFor: Self.tomorrow)
        resolved.dispatchStatus = .sent
        XCTAssertFalse(RideReservation.isDormant(resolved))
    }

    /// A dispatch that FAILED or was SKIPPED still means the sweeper RAN. Treating
    /// those as still-dormant would hide the card from the one owner who most needs
    /// to act manually — the one whose car did not take the navigation push.
    func testAFailedOrSkippedDispatchIsStillADispatch() {
        for outcome in [DispatchStatus.failed, .skipped, .unrecognized("something-new")] {
            var record = Self.reservation(status: .accepted, scheduledFor: Self.tomorrow)
            record.dispatchStatus = outcome
            XCTAssertFalse(RideReservation.isDormant(record), "\(outcome) is an outcome, not an absence")
        }
    }

    /// THE TIME-BOUNDED HALF. The server lets a scheduled ride be picked up when
    /// `dispatch_status = 'sent'` OR `scheduledFor <= now`; a client gating on the
    /// latch alone would strand a reservation whose sweeper never ran.
    func testAPastDueAcceptedReservationIsLiveEvenWithNoDispatchStamp() {
        let record = Self.reservation(status: .accepted, scheduledFor: Self.anHourAgo)
        XCTAssertNil(record.dispatchedAt)
        XCTAssertNil(record.dispatchStatus)
        XCTAssertFalse(RideReservation.isDormant(record), "at/past due, manual proceed is the documented recovery")
        XCTAssertTrue(RideReservation.isLiveRide(record))
    }

    func testDormancyIsEvaluatedAgainstTheInjectedClockNotTheWallClock() {
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        let record = Self.reservation(status: .accepted, scheduledFor: due)
        XCTAssertTrue(RideReservation.isDormant(record, now: due.addingTimeInterval(-1)))
        XCTAssertFalse(RideReservation.isDormant(record, now: due))
        XCTAssertFalse(RideReservation.isDormant(record, now: due.addingTimeInterval(1)))
    }

    /// The SIMULATED path carries display strings and no instant. An unknown moment
    /// must not read as "the moment has come" — that would put a dispatch card on
    /// every simulated reservation and drift every existing owner capture.
    func testAReservationWithNoKnownInstantStaysDormant() {
        let record = Self.reservation(status: .accepted, scheduledFor: nil)
        XCTAssertTrue(RideReservation.isDormant(record))
    }

    func testEveryStatusBeyondAcceptedIsLiveRegardlessOfTheDispatchFields() {
        for status in [AppRideStatus.arrived, .enroute, .completed] {
            let record = Self.reservation(status: status, scheduledFor: Self.tomorrow)
            XCTAssertFalse(
                RideReservation.isDormant(record),
                "a rider is aboard — that outranks a missing optional field (\(status))"
            )
        }
    }

    // MARK: - The owner's dispatch card (MYR-376, item A1)

    /// THE CLIENT'S OWN FRAME. Same record, same status, one day apart.
    @MainActor
    func testTheOwnerDispatchCardIsWithheldUntilTheReservationGoesLive() {
        let dormant = StubRideRequestService()
        dormant.activeRequest = Self.reservation(status: .accepted, scheduledFor: Self.tomorrow)
        XCTAssertNil(dormant.ownerDispatch, "no card, no 'En route to pickup', no 'Arrived at pickup' button")

        var dispatched = Self.reservation(status: .accepted, scheduledFor: Self.tomorrow)
        dispatched.dispatchedAt = Date()
        let live = StubRideRequestService()
        live.activeRequest = dispatched
        XCTAssertNotNil(live.ownerDispatch, "once dispatched the card is live exactly as today")

        let overdue = StubRideRequestService()
        overdue.activeRequest = Self.reservation(status: .accepted, scheduledFor: Self.anHourAgo)
        XCTAssertNotNil(overdue.ownerDispatch, "past due with no stamp: manual proceed is the recovery")
    }

    @MainActor
    func testTheOwnerDispatchCardStillHidesPendingAndDeclinedAndStillShowsInstantRides() {
        for status in [AppRideStatus.pending, .declined] {
            let service = StubRideRequestService()
            service.activeRequest = Self.instantRecord(status: status)
            XCTAssertNil(service.ownerDispatch, "unchanged by this issue (\(status))")
        }
        for status in [AppRideStatus.accepted, .arrived, .enroute, .completed] {
            let service = StubRideRequestService()
            service.activeRequest = Self.instantRecord(status: status)
            XCTAssertNotNil(service.ownerDispatch, "an instant ride is untouched (\(status))")
        }
    }

    // MARK: - Adoption (MYR-377, item B2)

    func testAnInstantRideKeepsItsExactPreExistingAdoptionSet() {
        let open: [WireRideStatus] = [.requested, .accepted, .enroute, .arrived]
        for status in open {
            XCTAssertTrue(RideReservation.isAdoptableLiveRide(Self.wire(status: status)))
        }
        for status in [WireRideStatus.completed, .declined, .cancelled] {
            XCTAssertFalse(RideReservation.isAdoptableLiveRide(Self.wire(status: status)))
        }
    }

    /// A dormant reservation must NOT enter the rider's single active slot: it
    /// would replace "Where to?" with a tracking map for a ride that is tomorrow,
    /// and — because the slot holds one ride — lock the rider out of booking today.
    func testADormantReservationIsNotAdoptable() {
        XCTAssertFalse(RideReservation.isAdoptableLiveRide(
            Self.wire(status: .accepted, scheduledFor: Self.tomorrow)
        ))
        XCTAssertFalse(RideReservation.isAdoptableLiveRide(
            Self.wire(status: .requested, scheduledFor: Self.tomorrow)
        ))
    }

    func testAReservationBecomesAdoptableOnDispatchOnStatusOrOnItsDueMoment() {
        XCTAssertTrue(RideReservation.isAdoptableLiveRide(
            Self.wire(status: .accepted, scheduledFor: Self.tomorrow, dispatchedAt: Date())
        ), "dispatched")
        XCTAssertTrue(RideReservation.isAdoptableLiveRide(
            Self.wire(status: .arrived, scheduledFor: Self.tomorrow)
        ), "the car is at the kerb")
        XCTAssertTrue(RideReservation.isAdoptableLiveRide(
            Self.wire(status: .enroute, scheduledFor: Self.tomorrow)
        ))
        XCTAssertTrue(RideReservation.isAdoptableLiveRide(
            Self.wire(status: .accepted, scheduledFor: Self.anHourAgo)
        ), "past due with no stamp — the sweeper never ran and the rider is still waiting")
    }

    /// A `requested` reservation is nobody's active ride however long ago its
    /// moment was.
    func testAPastDueUnansweredReservationIsNeverAdopted() {
        XCTAssertFalse(RideReservation.isAdoptableLiveRide(
            Self.wire(status: .requested, scheduledFor: Self.anHourAgo)
        ))
    }

    // MARK: - Drives → Upcoming (MYR-376, item A3)

    func testUpcomingHoldsOnlyAcceptedUndispatchedFutureReservations() {
        XCTAssertTrue(RideReservation.isUpcomingReservation(
            Self.wire(status: .accepted, scheduledFor: Self.tomorrow)
        ))
        // The client's own screenshot: an `arrived` ride — a passenger in the car —
        // still listed as something that had not happened yet.
        XCTAssertFalse(RideReservation.isUpcomingReservation(
            Self.wire(status: .arrived, scheduledFor: Self.anHourAgo)
        ))
        XCTAssertFalse(RideReservation.isUpcomingReservation(
            Self.wire(status: .accepted, scheduledFor: Self.tomorrow, dispatchedAt: Date())
        ), "dispatched — it belongs to the dispatch card now")
        XCTAssertFalse(RideReservation.isUpcomingReservation(
            Self.wire(status: .accepted, scheduledFor: Self.anHourAgo)
        ), "past due — the owner's job is to proceed, not to read about it in a list of plans")
        XCTAssertFalse(RideReservation.isUpcomingReservation(Self.wire(status: .accepted)),
                       "an INSTANT ride was never upcoming")
        XCTAssertFalse(RideReservation.isUpcomingReservation(
            Self.wire(status: .requested, scheduledFor: Self.tomorrow)
        ), "nobody has confirmed it, so it is not a plan yet")
    }

    /// The FILTER runs inside the shipping mapping, so the pause dialog and the
    /// Drives list cannot disagree about which reservations exist.
    func testTheReservationMappingRefusesEverythingThatIsNoLongerUpcoming() {
        XCTAssertNotNil(LiveUpcomingReservations.reservation(
            from: Self.wire(status: .accepted, scheduledFor: Self.tomorrow)
        ))
        XCTAssertNil(LiveUpcomingReservations.reservation(
            from: Self.wire(status: .arrived, scheduledFor: Self.anHourAgo)
        ))
        XCTAssertNil(LiveUpcomingReservations.reservation(
            from: Self.wire(status: .accepted, scheduledFor: Self.tomorrow, dispatchedAt: Date())
        ))
    }

    func testTheUpcomingRowCarriesTheServerRideIdBecauseThatIsWhatTheXDeclines() throws {
        let wire = Self.wire(status: .accepted, scheduledFor: Self.tomorrow)
        let reservation = try XCTUnwrap(LiveUpcomingReservations.reservation(from: wire))
        let row = try XCTUnwrap(UpcomingReservationRow.row(for: reservation))
        XCTAssertEqual(row.id, wire.id, "the local accept-time row used 'ou-' + id, which declines nothing")
        XCTAssertEqual(row.destination.label, "SFO \u{00B7} Terminal 2")
        XCTAssertGreaterThan(row.destination.miles, 0, "the client-side trip estimate, not the wire's 0")
        XCTAssertEqual(row.scheduledFor, reservation.scheduledFor)
    }

    // MARK: - The contract mapping carries the three facts (the foundation)

    func testTheMappingCarriesScheduledForAndBothDispatchFields() throws {
        let due = Date(timeIntervalSince1970: 1_800_003_600)
        let wire = Self.wire(status: .accepted, scheduledFor: due, dispatchedAt: due)
        let record = try XCTUnwrap(RideRequestContractMapping.record(from: wire))
        XCTAssertEqual(record.scheduledFor?.timeIntervalSince1970 ?? 0, due.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(record.dispatchedAt?.timeIntervalSince1970 ?? 0, due.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(record.dispatchStatus, .sent)
    }

    func testAnInstantWireRecordCarriesNoneOfThem() throws {
        let record = try XCTUnwrap(RideRequestContractMapping.record(from: Self.wire(status: .accepted)))
        XCTAssertNil(record.scheduledFor)
        XCTAssertNil(record.dispatchedAt)
        XCTAssertNil(record.dispatchStatus)
    }

    // MARK: - The rider's Scheduled tab (MYR-377, item B1)

    func testTheScheduledTabRendersRequestedAndAcceptedReservationsAsPendingAndConfirmed() {
        let rows = RiderScheduledRideMapping.rides(
            from: [
                Self.wire(id: "a", status: .accepted, scheduledFor: Self.tomorrow),
                Self.wire(id: "b", status: .requested, scheduledFor: Self.tomorrow.addingTimeInterval(-3600)),
            ],
            vehicles: [:],
            now: Self.noonToday
        )
        XCTAssertEqual(rows.map(\.id), ["b", "a"], "soonest first")
        XCTAssertEqual(rows.map(\.status), [.pending, .confirmed])
    }

    func testTheScheduledTabRefusesEverythingThatIsNotADormantReservation() {
        let excluded: [MyRobotaxiContracts.RideRequest] = [
            Self.wire(status: .accepted), // instant
            Self.wire(status: .arrived, scheduledFor: Self.anHourAgo),
            Self.wire(status: .enroute, scheduledFor: Self.anHourAgo),
            Self.wire(status: .completed, scheduledFor: Self.anHourAgo),
            Self.wire(status: .cancelled, scheduledFor: Self.tomorrow),
            Self.wire(status: .declined, scheduledFor: Self.tomorrow),
            // Dispatched: the rider's MAP is tracking this, and a duplicate of it in
            // a list of things that have not happened yet is the "0 scheduled"
            // defect's mirror image.
            Self.wire(status: .accepted, scheduledFor: Self.tomorrow, dispatchedAt: Date()),
        ]
        for wire in excluded {
            XCTAssertNil(
                RiderScheduledRideMapping.ride(from: wire, vehicle: nil, now: Self.noonToday),
                "\(wire.status) does not belong on the Scheduled tab"
            )
        }
    }

    /// The wire instant is UTC; the row is the RIDER's calendar. A ride at
    /// 03:00 UTC is the previous EVENING in Los Angeles, and printing it as
    /// tomorrow would put a different day on the row than on the chip they tapped.
    func testTheDayAndTimeResolveInTheRidersOwnTimeZone() throws {
        // 2026-08-01T03:00:00Z == Fri Jul 31, 8:00 PM in Los Angeles.
        let instant = Self.iso("2026-08-01T03:00:00.000Z")
        let now = Self.iso("2026-07-31T17:00:00.000Z") // Fri Jul 31, 10:00 AM LA

        let la = try XCTUnwrap(RiderScheduledRideMapping.ride(
            from: Self.wire(status: .accepted, scheduledFor: instant),
            vehicle: nil,
            now: now,
            calendar: Self.calendar("America/Los_Angeles")
        ))
        XCTAssertEqual(la.day, "Today", "8 PM tonight, LA")
        XCTAssertEqual(la.time, "8:00 PM")

        let london = try XCTUnwrap(RiderScheduledRideMapping.ride(
            from: Self.wire(status: .accepted, scheduledFor: instant),
            vehicle: nil,
            now: now,
            calendar: Self.calendar("Europe/London")
        ))
        XCTAssertEqual(london.day, "Tomorrow", "the SAME instant, 4 AM on Aug 1 in London")
        XCTAssertEqual(london.time, "4:00 AM")
    }

    /// The row's day grammar is the PICKER's own, so a ride booked from a chip
    /// reading "Sat, Aug 1" comes back listed that way rather than some other way.
    func testTheDayGrammarIsTheScheduleChipsOwn() {
        let calendar = Self.calendar("America/Los_Angeles")
        let now = Self.iso("2026-07-31T17:00:00.000Z")
        let chips = RideScheduleDays.days(now: now, calendar: calendar)
        for chip in chips {
            let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: chip.date) ?? chip.date
            XCTAssertEqual(
                RideScheduleDays.label(for: noon, now: now, calendar: calendar),
                chip.token,
                "the tab and the picker must write one grammar"
            )
        }
    }

    /// A live reservation carries NO owner name anywhere on the wire, so the row
    /// must render the car alone. Inventing one is MYR-184's `InviteHostFixture`
    /// leak on a new surface.
    func testALiveRowNamesNoOwnerAndRendersTheCarAlone() throws {
        let row = try XCTUnwrap(RiderScheduledRideMapping.ride(
            from: Self.wire(status: .accepted, scheduledFor: Self.tomorrow),
            vehicle: RiderScheduledRideVehicle(name: "Lunar", relationship: "Your Tesla"),
            now: Self.noonToday
        ))
        XCTAssertEqual(row.driver, "", "the wire's `requesterName` is the RIDER, not the owner")
        XCTAssertEqual(row.vehicle, "Lunar")
        XCTAssertEqual(ScheduledRideDisplay.vehicleTitle(row), "Lunar")
        XCTAssertNil(ScheduledRideDisplay.avatarInitial(row))
        XCTAssertEqual(ScheduledRideDisplay.relationshipLine(row), "Your Tesla")
        XCTAssertEqual(ScheduledRideDisplay.changeNote(row), "Changes notify the owner to re-confirm.")
    }

    /// …and the FIXTURE rows are untouched, which is what keeps every simulated and
    /// DEBUG capture byte-identical.
    func testAFixtureRowKeepsThePrototypesOwnerGrammar() throws {
        let fixture = try XCTUnwrap(RideHistoryFixtures.scheduledRides.first)
        XCTAssertEqual(ScheduledRideDisplay.vehicleTitle(fixture), "Mom\u{2019}s Model Y")
        XCTAssertEqual(ScheduledRideDisplay.avatarInitial(fixture), "M")
        XCTAssertEqual(ScheduledRideDisplay.relationshipLine(fixture), "Family \u{00B7} Shared with you")
        XCTAssertEqual(ScheduledRideDisplay.changeNote(fixture), "Changes notify Mom to re-confirm.")
        XCTAssertNil(fixture.scheduledFor, "the prototype's rides are a day token and a clock, never an instant")
    }

    /// A wire reservation carries its two ENDPOINTS and no road geometry, so the
    /// sheet's preview must draw pins and NO line — "no straight lines ever"
    /// (MYR-237 / MYR-293).
    func testALiveRowsRouteIsNeverDrawnAsAPolyline() throws {
        let row = try XCTUnwrap(RiderScheduledRideMapping.ride(
            from: Self.wire(status: .accepted, scheduledFor: Self.tomorrow),
            vehicle: nil,
            now: Self.noonToday
        ))
        XCTAssertEqual(row.route.count, 2, "the two ENDPOINTS, and no road between them")
        XCTAssertFalse(RideRoutePolyline.isReal(row.route))
        XCTAssertFalse(ScheduledRideDisplay.drawsRouteLine(row), "pins only — a straight gold segment is a fabricated road")
        XCTAssertTrue(
            RideHistoryFixtures.scheduledRides.allSatisfy { ScheduledRideDisplay.drawsRouteLine($0) },
            "the PROTOTYPE's own illustrated routes keep their line, so the four scheduled scenes are byte-identical"
        )
    }

    // MARK: - Honest cancel (MYR-376 item A4, MYR-377 item B1)

    @MainActor
    func testARefusedRiderCancelKeepsTheRowAndSaysSo() async {
        let source = StubScheduledRides(rides: [Self.scheduledRow(id: "s1")])
        source.cancelFailure = RestError.http(status: 409, code: nil, message: nil, subCode: nil)
        let store = RiderScheduledRidesStore(source: source)
        await store.load()
        XCTAssertEqual(store.rides.map(\.id), ["s1"])

        await store.cancel(id: "s1")
        // MYR-381 — the sentence is CLASSIFIED now (the server answered, and the
        // reservation is still standing), not the one generic line.
        XCTAssertEqual(store.failureNotice, ReservationCancelCopy.rider.refused)
        XCTAssertEqual(store.rides.map(\.id), ["s1"], "NEVER optimistically removed on a refused cancel")
    }

    @MainActor
    func testASuccessfulRiderCancelReReadsRatherThanRemovingLocally() async {
        let source = StubScheduledRides(rides: [Self.scheduledRow(id: "s1")])
        let store = RiderScheduledRidesStore(source: source)
        await store.load()

        await store.cancel(id: "s1")
        XCTAssertNil(store.failureNotice)
        XCTAssertEqual(source.cancelled, ["s1"], "the REAL cancel call ran")
        XCTAssertTrue(store.rides.isEmpty, "the list is the server's answer, not a local edit")
    }

    @MainActor
    func testARefusedOwnerCancelKeepsTheReservationAndSaysSo() async {
        let source = StubUpcomingReservations(rows: [Self.upcomingReservation(id: "r1")])
        source.declineFailure = RestError.http(status: 409, code: nil, message: nil, subCode: nil)
        let state = OwnerDrivesState(live: true, reservations: source)
        await state.loadUpcoming(vehicleID: "veh-live")
        XCTAssertEqual(state.upcoming.map(\.id), ["r1"])

        await state.cancelReservation(id: "r1", vehicleID: "veh-live")
        XCTAssertEqual(state.cancelFailureNotice, ReservationCancelCopy.owner.refused) // MYR-381
        XCTAssertEqual(state.upcoming.map(\.id), ["r1"], "the row stays where it is")
    }

    @MainActor
    func testASuccessfulOwnerCancelDeclinesForRealAndReReads() async {
        let source = StubUpcomingReservations(rows: [Self.upcomingReservation(id: "r1")])
        let state = OwnerDrivesState(live: true, reservations: source)
        await state.loadUpcoming(vehicleID: "veh-live")

        await state.cancelReservation(id: "r1", vehicleID: "veh-live")
        XCTAssertEqual(source.declined, ["r1"], "the local list used to just drop the row and call nothing")
        XCTAssertNil(state.cancelFailureNotice)
        XCTAssertTrue(state.upcoming.isEmpty)
    }

    /// A read that did not ANSWER is not "nothing is booked" (MYR-326).
    @MainActor
    func testAFailedUpcomingReadKeepsWhateverIsHeld() async {
        let source = StubUpcomingReservations(rows: [Self.upcomingReservation(id: "r1")])
        let state = OwnerDrivesState(live: true, reservations: source)
        await state.loadUpcoming(vehicleID: "veh-live")
        source.readFailure = RestError.http(status: 503, code: nil, message: nil, subCode: nil)

        await state.loadUpcoming(vehicleID: "veh-live", force: true)
        XCTAssertEqual(state.upcoming.map(\.id), ["r1"])
    }

    /// The SIMULATED state composes no source at all, so the prototype's local
    /// removal is still exactly what runs there.
    @MainActor
    func testTheSimulatedDrivesStateIsUnchanged() {
        let state = OwnerDrivesState()
        XCTAssertFalse(state.readsLiveReservations)
        XCTAssertEqual(state.upcoming.count, DriveFixtures.upcomingRides.count)
        state.cancelUpcoming(id: DriveFixtures.upcomingRides[0].id)
        XCTAssertEqual(state.upcoming.count, DriveFixtures.upcomingRides.count - 1)
    }

    // MARK: - Live Activity (MYR-377, item B4)

    /// `go_live_activities` had ZERO rows in production, and this gate is why: the
    /// client's only rides were reservations, and MYR-172 refused every one of them
    /// forever rather than only while dormant.
    func testNoActivityStartsWhileTheReservationIsDormant() {
        let action = RideActivityStateMachine.action(
            phase: .idle,
            record: Self.reservation(status: .accepted, scheduledFor: Self.tomorrow),
            vehicleName: "Lunar"
        )
        XCTAssertEqual(action, RideActivityAction.none)
    }

    func testAnActivityStartsOnceTheReservationGoesLive() throws {
        var dispatched = Self.reservation(status: .accepted, scheduledFor: Self.tomorrow)
        dispatched.dispatchedAt = Date()
        guard case .start(let rideID, let state) = RideActivityStateMachine.action(
            phase: .idle, record: dispatched, vehicleName: "Lunar"
        ) else { return XCTFail("a dispatched reservation is a live ride") }
        XCTAssertEqual(rideID, dispatched.id)
        XCTAssertEqual(state.status, .accepted)
        XCTAssertEqual(state.vehicleName, "Lunar")
        XCTAssertNil(state.eta, "the client never computes an ETA — the contract's is the car's own")
    }

    func testAPastDueReservationStartsAnActivityEvenWithNoDispatchStamp() {
        let action = RideActivityStateMachine.action(
            phase: .idle,
            record: Self.reservation(status: .accepted, scheduledFor: Self.anHourAgo),
            vehicleName: "Lunar"
        )
        guard case .start = action else { return XCTFail("the sweeper never ran; the rider is still waiting") }
    }

    func testAReservationRunsTheSameArrivedEnrouteCompletedArcAnInstantRideDoes() throws {
        var record = Self.reservation(status: .arrived, scheduledFor: Self.anHourAgo)
        record.dispatchedAt = Date()
        let opening = RideActivityStateMachine.contentState(for: record, vehicleName: "Lunar", previous: nil)

        // arrived → enroute updates.
        record.status = .enroute
        guard case .update(_, let enroute) = RideActivityStateMachine.action(
            phase: .live(rideID: record.id, state: opening), record: record, vehicleName: "Lunar"
        ) else { return XCTFail("expected an update") }
        XCTAssertEqual(enroute.status, .enroute)

        // enroute → completed ends, with the arrival linger.
        record.status = .completed
        guard case .end(_, let final, let dismissal) = RideActivityStateMachine.action(
            phase: .live(rideID: record.id, state: enroute), record: record, vehicleName: "Lunar"
        ) else { return XCTFail("expected an end") }
        XCTAssertEqual(final.status, .completed)
        XCTAssertEqual(dismissal, .completedLinger)
    }

    /// A dormant reservation that is CANCELLED must not manufacture an Activity to
    /// end — there was never one to take down.
    func testADormantReservationNeverProducesAnEndEither() {
        XCTAssertEqual(
            RideActivityStateMachine.action(
                phase: .idle,
                record: Self.reservation(status: .pending, scheduledFor: Self.tomorrow),
                vehicleName: "Lunar"
            ),
            RideActivityAction.none
        )
    }

    // MARK: - The rider's sheet phase (MYR-377, item B2)

    func testTheTrackingSheetOpensForALiveReservationAndNotForADormantOne() {
        for status in [AppRideStatus.accepted, .arrived, .enroute] {
            XCTAssertNil(
                SharedViewerScreen.reconciledPhase(status: status, isDormantReservation: true, current: .idle),
                "tomorrow's ride does not take today's map (\(status))"
            )
            XCTAssertEqual(
                SharedViewerScreen.reconciledPhase(status: status, isDormantReservation: false, current: .idle),
                .tracking,
                "and once it is live, 'Start ride' is reachable (\(status))"
            )
        }
    }

    // MARK: - Fixtures

    private static let everyStatus: [AppRideStatus] = [.pending, .accepted, .arrived, .enroute, .completed, .declined]
    private static let tomorrow = Date().addingTimeInterval(26 * 60 * 60)
    private static let anHourAgo = Date().addingTimeInterval(-60 * 60)
    private static let noonToday = Date()

    private static func instantRecord(status: AppRideStatus) -> RideRequestRecord {
        RideRequestRecord(input: input(schedule: nil), status: status)
    }

    private static func reservation(status: AppRideStatus, scheduledFor: Date?) -> RideRequestRecord {
        var record = RideRequestRecord(
            input: input(schedule: RideSchedule(day: "Tomorrow", time: "12:00 PM")),
            status: status
        )
        record.scheduledFor = scheduledFor
        return record
    }

    private static func input(schedule: RideSchedule?) -> RideRequestInput {
        RideRequestInput(
            pickup: RidePlace(
                id: "p", label: "Home", subtitle: nil, miles: 0, minutes: 0, icon: "mappin",
                coordinate: CLLocationCoordinate2D(latitude: 37.7793, longitude: -122.3937)
            ),
            destination: RidePlace(
                id: "d", label: "SFO \u{00B7} Terminal 2", subtitle: nil, miles: 18.4, minutes: 32, icon: "mappin",
                coordinate: CLLocationCoordinate2D(latitude: 37.6156, longitude: -122.3900)
            ),
            fleetMemberID: "veh-live",
            schedule: schedule
        )
    }

    private static func wire(
        id: String = "r1",
        status: WireRideStatus,
        scheduledFor: Date? = nil,
        dispatchedAt: Date? = nil
    ) -> MyRobotaxiContracts.RideRequest {
        MyRobotaxiContracts.RideRequest(
            id: id, riderId: "u", ownerId: "u", vehicleId: "veh-live",
            pickup: MyRobotaxiContracts.RidePlace(lat: 37.7793, lng: -122.3937, label: "Home"),
            dropoff: MyRobotaxiContracts.RidePlace(
                lat: 37.6156, lng: -122.3900,
                label: "SFO \u{00B7} Terminal 2", address: "San Francisco International"
            ),
            status: status,
            scheduledFor: scheduledFor.map { isoFormatter.string(from: $0) },
            createdAt: "2026-07-30T18:00:00.000Z",
            updatedAt: "2026-07-30T18:06:00.000Z",
            acceptedAt: status == .requested ? nil : "2026-07-30T18:04:00.000Z",
            dispatchStatus: dispatchedAt == nil ? nil : .sent,
            dispatchedAt: dispatchedAt.map { isoFormatter.string(from: $0) },
            requesterName: "Thomas"
        )
    }

    private static func upcomingReservation(id: String) -> UpcomingReservation {
        LiveUpcomingReservations.reservation(from: wire(id: id, status: .accepted, scheduledFor: tomorrow))!
    }

    private static func scheduledRow(id: String) -> ScheduledRide {
        RiderScheduledRideMapping.ride(
            from: wire(id: id, status: .accepted, scheduledFor: tomorrow),
            vehicle: nil,
            now: noonToday
        )!
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    private static func iso(_ string: String) -> Date {
        isoFormatter.date(from: string)!
    }

    private static func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }
}

// MARK: - Stubs

/// The protocol default `ownerDispatch` — i.e. the expression EVERY simulated run
/// and DEBUG scene resolves — driven directly, so the dormancy gate is asserted on
/// the shared path rather than only on the live override.
@MainActor
private final class StubRideRequestService: RideRequestService {
    var activeRequest: RideRequestRecord?
    func submit(_ input: RideRequestInput) {}
    func accept() {}
    func decline() {}
    func cancel() {}
    func pickedUp() {}
    func startRide() {}
    func droppedOff() {}
    func completeAndReset() -> RequestedRide? { nil }
}

private final class StubScheduledRides: RiderScheduledRideSource, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ScheduledRide]
    var cancelFailure: Error?
    private(set) var cancelled: [String] = []

    init(rides: [ScheduledRide]) { stored = rides }

    func scheduledRides(now: Date) async throws -> [ScheduledRide] {
        lock.withLock { stored }
    }

    func cancel(rideID: String) async throws {
        if let cancelFailure { throw cancelFailure }
        lock.withLock {
            cancelled.append(rideID)
            stored.removeAll { $0.id == rideID }
        }
    }
}

private final class StubUpcomingReservations: UpcomingReservationSource, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [UpcomingReservation]
    var readFailure: Error?
    var declineFailure: Error?
    private(set) var declined: [String] = []

    init(rows: [UpcomingReservation]) { stored = rows }

    func upcomingReservations(vehicleID: String) async throws -> [UpcomingReservation] {
        if let readFailure { throw readFailure }
        return lock.withLock { stored }
    }

    func decline(reservationID: String) async throws {
        if let declineFailure { throw declineFailure }
        lock.withLock {
            declined.append(reservationID)
            stored.removeAll { $0.id == reservationID }
        }
    }
}
