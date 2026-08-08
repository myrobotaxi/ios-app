import CoreLocation
import XCTest
@testable import MyRoboTaxi

// MARK: - MYR-463 — Drives → Upcoming is not allowed to say "nothing is booked"
// unless it has asked and the answer was nothing
//
// External beta, build 202608030843: *"Scheduled ride disappeared."*
//
// The production row (`c8b316c8…`) proves nothing was lost: created 23:28:06 for
// 23:30:00, ACCEPTED at 23:28:28, dispatch `failed`/`reservation_expired` at
// 00:00:28, picked up 00:30:42, completed 01:39:07. At the moment of the
// screenshot it was `accepted` and PAST DUE, which both the server's
// `?upcomingForVehicle=` predicate and `RideReservation.isUpcomingReservation`
// correctly exclude. The defect is that the tab then rendered its most definitive
// sentence over it.
//
// THE RESTORATION TESTS, i.e. the ones that fail if the defect is put back:
//
//  • `testAnInFlightReadIsNeverTheEmptyHero` — the old screen resolved from
//    `sortedUpcoming.isEmpty` alone, so this is exactly the frame MYR-386's class
//    produces (`isLoadingUpcoming` was published and read by nothing).
//  • `testAFailedReadIsNeverTheEmptyHero`.
//  • `testAReservationThatWentLiveIsSaidRatherThanErased` — the reported frame.
@MainActor
final class OwnerUpcomingPresentationTests: XCTestCase {

    private var calendar: Calendar { .current }

    private func place(id: String, label: String) -> RidePlace {
        RidePlace(
            id: id, label: label, subtitle: nil, miles: 4.2, minutes: 12,
            icon: "mappin", coordinate: CLLocationCoordinate2D(latitude: 32.96, longitude: -96.82)
        )
    }

    /// The client's own reservation, as a record: Dallas Pkwy → Aritzia, booked
    /// for "Today · 6:30 PM".
    private func reservation(
        status: RideRequestStatus = .accepted,
        scheduledFor: Date?,
        vehicleID: String = "cmphman6p000fkz04rq3adktk",
        dispatchedAt: Date? = nil,
        schedule: RideSchedule? = RideSchedule(day: "Today", time: "6:30 PM")
    ) -> RideRequestRecord {
        var record = RideRequestRecord(
            input: RideRequestInput(
                pickup: place(id: "p", label: "Dallas Pkwy"),
                destination: place(id: "d", label: "Aritzia"),
                fleetMemberID: vehicleID,
                schedule: schedule
            ),
            status: status
        )
        record.scheduledFor = scheduledFor
        record.dispatchedAt = dispatchedAt
        return record
    }

    private let vehicle = "cmphman6p000fkz04rq3adktk"
    /// 2026-08-03 23:30Z — the instant of the report, and the reservation's own
    /// due moment.
    private var due: Date { Date(timeIntervalSince1970: 1_785_540_600) }

    // MARK: The ladder

    func testRowsInHandOutrankEveryPhase() {
        for phase: OwnerUpcomingLoadPhase in [.idle, .loading, .loaded, .failed("nope")] {
            XCTAssertEqual(
                OwnerUpcomingResolution.resolve(phase: phase, hasRows: true, dueReservation: nil),
                .rows,
                "a re-read must never blank a populated list — a decline re-reads"
            )
        }
    }

    func testAnInFlightReadIsNeverTheEmptyHero() {
        for phase: OwnerUpcomingLoadPhase in [.idle, .loading] {
            XCTAssertEqual(
                OwnerUpcomingResolution.resolve(phase: phase, hasRows: false, dueReservation: nil),
                .loading
            )
        }
    }

    func testAFailedReadIsNeverTheEmptyHero() {
        XCTAssertEqual(
            OwnerUpcomingResolution.resolve(
                phase: .failed(OwnerDrivesState.unreadableMessage), hasRows: false, dueReservation: nil
            ),
            .unavailable(OwnerDrivesState.unreadableMessage)
        )
    }

    /// The failure is about the LIST, so it outranks a note about one ride —
    /// otherwise an owner reads "your 6:30 is running" and concludes that is all
    /// there is, on a tab that could not read their reservations at all.
    func testAFailedReadOutranksTheDueNote() {
        let note = OwnerDueReservation(phrase: "Today · 6:30 PM", destination: "Aritzia")
        XCTAssertEqual(
            OwnerUpcomingResolution.resolve(phase: .failed("x"), hasRows: false, dueReservation: note),
            .unavailable("x")
        )
    }

    /// THE ONLY WAY TO THE HERO. Swept over the whole phase enum, so a phase added
    /// later has to answer this question rather than fall outside the test.
    func testTheEmptyHeroIsReachableOnlyFromASettledEmptyRead() {
        let phases: [OwnerUpcomingLoadPhase] = [.idle, .loading, .loaded, .failed("x")]
        for phase in phases {
            let presentation = OwnerUpcomingResolution.resolve(
                phase: phase, hasRows: false, dueReservation: nil
            )
            XCTAssertEqual(presentation == .empty, phase == .loaded, "\(phase)")
        }
    }

    // MARK: The reported frame

    func testAReservationThatWentLiveIsSaidRatherThanErased() {
        let record = reservation(scheduledFor: due)
        let note = OwnerUpcomingResolution.dueReservation(
            ownerDispatch: record, vehicleID: vehicle, now: due
        )
        XCTAssertEqual(note, OwnerDueReservation(phrase: "Today · 6:30 PM", destination: "Aritzia"))
        XCTAssertEqual(
            OwnerUpcomingResolution.resolve(phase: .loaded, hasRows: false, dueReservation: note),
            .dueNow(note!)
        )
    }

    /// The sweeper's own window. `reservation_expired` marks the dispatch failed
    /// thirty minutes after the due time and the ride stays `accepted` — MYR-376's
    /// `isDispatched` deliberately reads a FAILED dispatch as "the sweeper ran", so
    /// the ride is still live and the note still stands.
    func testASweptReservationStillHasSomethingHonestToSay() {
        let swept = reservation(
            scheduledFor: due, dispatchedAt: due.addingTimeInterval(30 * 60)
        )
        XCTAssertNotNil(OwnerUpcomingResolution.dueReservation(
            ownerDispatch: swept, vehicleID: vehicle, now: due.addingTimeInterval(35 * 60)
        ))
    }

    // MARK: The four guards, each of which is a way the note could lie

    /// MYR-376's original defect, re-entered through a caption: tomorrow's
    /// reservation is `accepted` today and is still IN the list above.
    func testADormantReservationIsNotHappeningNow() {
        let tomorrow = reservation(scheduledFor: due.addingTimeInterval(24 * 3600))
        XCTAssertNil(OwnerUpcomingResolution.dueReservation(
            ownerDispatch: tomorrow, vehicleID: vehicle, now: due
        ))
    }

    /// An instant ride never appeared in Upcoming, so its absence needs no
    /// explaining. Its record carries no schedule at all.
    func testAnInstantRideNeverProducesTheNote() {
        let instant = reservation(status: .enroute, scheduledFor: nil, schedule: nil)
        XCTAssertNil(OwnerUpcomingResolution.dueReservation(
            ownerDispatch: instant, vehicleID: vehicle, now: due
        ))
    }

    /// A note about the OTHER car, on a tab headed "Lunar", is worse than the
    /// silence it replaces.
    func testAnotherCarsRideIsNotThisTabsBusiness() {
        let other = reservation(scheduledFor: due, vehicleID: "cmnccy8gf0006ky04sv0xsykl")
        XCTAssertNil(OwnerUpcomingResolution.dueReservation(
            ownerDispatch: other, vehicleID: vehicle, now: due
        ))
        XCTAssertNil(
            OwnerUpcomingResolution.dueReservation(ownerDispatch: other, vehicleID: nil, now: due),
            "a screen that does not yet know its car must not guess"
        )
    }

    /// `ownerDispatch` keeps a `completed` ride until MYR-292's banner is
    /// acknowledged. A finished ride is not happening now.
    func testAFinishedRideIsNotHappeningNow() {
        let done = reservation(status: .completed, scheduledFor: due)
        XCTAssertNil(OwnerUpcomingResolution.dueReservation(
            ownerDispatch: done, vehicleID: vehicle, now: due.addingTimeInterval(3600)
        ))
    }

    func testNoHeldRideMeansNoNote() {
        XCTAssertNil(OwnerUpcomingResolution.dueReservation(
            ownerDispatch: nil, vehicleID: vehicle, now: due
        ))
    }

    // MARK: Copy

    /// The old sub-line was "Scheduled rides you accept will appear here", which
    /// is true of what ENTERS the list and silent about what LEAVES it — and read
    /// at a reservation's pickup time it says the opposite of what happened. The
    /// new one states the whole lifetime.
    func testTheEmptyHeroSaysHowLongAReservationStays() {
        XCTAssertFalse(
            DrivesScreen.emptyUpcomingSubtitle.contains("will appear here"),
            "the line has to describe the list's whole lifetime, not only its entry"
        )
        XCTAssertTrue(DrivesScreen.emptyUpcomingSubtitle.contains("pickup time"))
    }

    /// "Right now" is load-bearing (MYR-395): the next appearance re-reads, so
    /// the failure sentence must not read as a verdict.
    func testTheUnreadableSentenceIsNotAVerdict() {
        XCTAssertTrue(OwnerDrivesState.unreadableMessage.contains("right now"))
    }
}
