import Foundation

// MARK: - Drives → Upcoming: what the tab is entitled to say (MYR-463)
//
// THE DEFECT, from the external beta (build 202608030843, 2026-08-03 23:30Z):
// *"Scheduled ride disappeared."* Drives → Upcoming rendered the designed empty
// state — a calendar glyph, "No upcoming rides", "Scheduled rides you accept will
// appear here." — for a reservation the owner had accepted ninety seconds earlier.
//
// THE RESERVATION WAS NEVER GONE, AND NOTHING WAS COMPUTED WRONG. Production row
// `c8b316c8…`: created 23:28:06 for 23:30:00, ACCEPTED at 23:28:28, dispatch
// `failed`/`reservation_expired` at 00:00:28 (the §7.8 thirty-minute lateness
// sweeper), picked up at 00:30:42 and completed at 01:39:07. So at the moment of
// the screenshot the ride was `accepted`, PAST ITS DUE INSTANT, and not yet
// dispatched.
//
// A reservation leaving this list at its due moment is CORRECT and deliberate.
// `RideReservation.isUpcomingReservation` is `accepted && scheduled &&
// !isAdoptableLiveRide`, and the server's own `?upcomingForVehicle=` predicate is
// `accepted` AND STRICTLY FUTURE — so both sides agree, and MYR-376 wrote down
// why: *"a row in Upcoming is a promise about the future; the moment the ride goes
// live it stops being one and the dispatch card owns it instead."*
//
// **THE DEFECT IS THE SILENCE, NOT THE FILTER.** The tab had exactly two things it
// could render — rows, or the most definitive sentence it owns — so three
// genuinely different situations all came out as "you have nothing booked":
//
//  1. **The read has not answered yet.** `OwnerDrivesState` published
//     `isLoadingUpcoming` from the day MYR-376 shipped and **no screen ever read
//     it** (zero call sites). That is MYR-386's defect on its own surface: an
//     empty array IN FLIGHT is byte-identical to an empty array that came back
//     empty, and the screen answered both with the hero.
//  2. **The read FAILED.** `loadUpcoming` correctly leaves what is held rather
//     than emptying the list (MYR-326) — but on a cold entry what is held is
//     `[]`, so a car that could not be reached also read "No upcoming rides",
//     which is a claim about the ACCOUNT that a failed fetch does not support.
//  3. **The reservation went live.** The reported frame. The list is right to
//     drop it and the screen said nothing about where it went, while its own
//     sub-line ("Scheduled rides **you accept** will appear here") implies the
//     owner never accepted it — which he had, twenty-two seconds after it was
//     created.
//
// So the fix is structural rather than a copy pass: the empty hero is reachable
// ONLY from a completed, successful read that also has nothing live to point at.
// A screen cannot forget an arm of an enum the way it can forget the third leg of
// an `if`/`else` (MYR-387's rule, and this is the fourth surface to need it).
//
// **NOTHING IS RESURRECTED.** The past-due reservation is not put back in the
// list, no read is widened, and the swept `reservation_expired` row is not
// re-listed as a plan. The note below is built ENTIRELY from what the owner's own
// pipeline already holds (`RideRequestService.ownerDispatch`), i.e. from the ride
// the Vehicle tab is already narrating — so it can never claim a reservation the
// app is not simultaneously showing somewhere it can be acted on.

/// How far a Drives → Upcoming read has got.
///
/// Replaces `isLoadingUpcoming`, which could not express the difference that
/// mattered: `false` meant BOTH "loaded, genuinely empty" and "nobody has asked
/// yet" (MYR-343 / MYR-386 / MYR-395's lesson for the fourth time — three
/// situations told apart by fewer arms than they have, so one always borrows
/// another's surface).
public enum OwnerUpcomingLoadPhase: Equatable, Sendable {
    /// No read has been issued. On this screen that is always "about to ask" —
    /// `DrivesScreen`'s `.task` fires unconditionally on appear — which is what
    /// makes it legitimate for `.idle` to render the same skeleton `.loading`
    /// does (`InvitesScreen`'s own reasoning, MYR-386).
    case idle
    /// A read is genuinely in flight and nothing is held behind it.
    case loading
    /// A read ANSWERED. Only this phase may produce the empty hero.
    case loaded
    /// A read failed, with the one honest sentence to say about it.
    case failed(String)
}

/// A reservation of the owner's that has stopped being *upcoming* because its
/// moment came — the thing Drives → Upcoming used to say nothing about.
public struct OwnerDueReservation: Equatable, Sendable {
    /// "Today · 6:30 PM" — the picker's own committed phrase, through
    /// `RideScheduleDisplay`, so the row quotes a slot exactly as every other
    /// surface in this app quotes one.
    public let phrase: String
    /// The destination label off the same record the Vehicle tab is narrating.
    public let destination: String

    public init(phrase: String, destination: String) {
        self.phrase = phrase
        self.destination = destination
    }
}

/// What the Upcoming segment renders, as ONE pure resolution.
public enum OwnerUpcomingPresentation: Equatable, Sendable {
    /// The server's rows are in hand — render them.
    case rows
    /// A first read is running and nothing is held behind it.
    case loading
    /// The read failed and there is nothing held. Carries the sentence.
    case unavailable(String)
    /// Nothing is booked ahead, but a reservation of this car's is happening
    /// RIGHT NOW — so "no upcoming rides" is true and misleading at once.
    case dueNow(OwnerDueReservation)
    /// A completed read, nothing booked, nothing live. The designed hero.
    case empty
}

public enum OwnerUpcomingResolution {

    /// The ladder. Order is the whole rule, so it is written out:
    ///
    ///  1. **ROWS IN HAND OUTRANK EVERY PHASE.** `loadUpcoming` re-reads on every
    ///     appearance and after every cancel, so a re-read that blanked a
    ///     populated list into a skeleton would make a decline look like the tab
    ///     falling over. Same rule `LiveShareService` and `LiveSharedVehicleCatalog`
    ///     already apply.
    ///  2. **A read that has not answered is not an empty account.** `.idle` and
    ///     `.loading` are one arm here for the reason above.
    ///  3. **A read that FAILED is not an empty account either.** Deliberately
    ///     ABOVE `.dueNow`: the failure is about the LIST, and quietly replacing
    ///     "we could not read your reservations" with a note about one ride would
    ///     let the owner conclude that one ride is all there is.
    ///  4. **A reservation that went live is SAID.** This is the reported frame.
    ///  5. Only then, the hero.
    public static func resolve(
        phase: OwnerUpcomingLoadPhase,
        hasRows: Bool,
        dueReservation: OwnerDueReservation?
    ) -> OwnerUpcomingPresentation {
        if hasRows { return .rows }
        switch phase {
        case .idle, .loading: return .loading
        case .failed(let message): return .unavailable(message)
        case .loaded: break
        }
        if let dueReservation { return .dueNow(dueReservation) }
        return .empty
    }

    /// The owner's own held ride, reduced to the note — or `nil`, which is the
    /// answer in every case this must not speak about.
    ///
    /// Four guards, each of which is a way the note could otherwise lie:
    ///
    ///  • **It must be a RESERVATION.** An instant ride never appeared in Upcoming,
    ///    so its absence needs no explaining (`RideReservation.isReservation`).
    ///  • **It must be LIVE**, by the SHARED dormancy predicate rather than a
    ///    second copy of it. A reservation the owner accepted for tomorrow is
    ///    `accepted` today and is still in the list above; saying "happening now"
    ///    about it is MYR-376's original defect re-entered through a caption.
    ///  • **It must be THIS CAR's.** `input.fleetMemberID` is the wire's
    ///    `vehicleId` on the live path (`RideRequestContractMapping`), and this
    ///    screen is scoped to one vehicle — a note about the other car's ride, on
    ///    a tab headed "Lunar", would be worse than the silence it replaces.
    ///  • **It must not be OVER.** `ownerDispatch` keeps a `completed` ride until
    ///    the owner acknowledges MYR-292's banner; a finished ride is not
    ///    something "happening now".
    public static func dueReservation(
        ownerDispatch record: RideRequestRecord?,
        vehicleID: String?,
        now: Date = Date()
    ) -> OwnerDueReservation? {
        guard let record,
              RideReservation.isReservation(record),
              RideReservation.isLiveRide(record, now: now),
              record.status != .completed,
              let schedule = record.input.schedule
        else { return nil }
        // A nil vehicle id means the screen does not yet know which car it is
        // about, and a note that might be about another one is not worth the
        // risk; the read it is standing in for has not happened either.
        guard let vehicleID, record.input.fleetMemberID == vehicleID else { return nil }
        return OwnerDueReservation(
            phrase: RideScheduleDisplay.phrase(schedule),
            destination: record.input.destination.label
        )
    }
}
