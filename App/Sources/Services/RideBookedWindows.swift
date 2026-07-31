import Foundation
import MyRobotaxiContracts

// MARK: - RideBookedWindows (MYR-385)
//
// THE CLIENT'S REPORT (r15, build `202607311129`): *"Still letting me schedule
// for noon even though I already have a ride scheduled for that time."*
//
// MYR-383 shipped the SERVER gate in r14 and it does refuse that booking — with a
// `409 vehicle_unavailable` / `subCode: time_conflict`, at SUBMIT, after the rider
// has picked a day, picked a time and tapped a CTA naming both. A rule the picker
// cannot see is indistinguishable from a bug, which is what he reported. §7.22 is
// the READ side of that same gate, and this file is the client half of it.
//
// **THE INVARIANT §7.22 IS BUILT AROUND**: a slot the picker dims is exactly a
// slot the gate would refuse at that instant, and a slot it leaves enabled is
// exactly one the gate would allow. On the server that is held by construction —
// both surfaces are assembled from the same SQL fragments and reach the window
// constant through the same bind parameter. On THIS side it is held by three
// rules, each of which is a way the invariant could have been broken quietly:
//
//  1. **THE HALF-WIDTH NEVER CROSSES THE WIRE, AND MUST NOT BE RE-DERIVED HERE.**
//     §7.22 emits CONCRETE INSTANTS. The ±45 minutes is a product guess living in
//     one place on the server, passed to SQL as a bind parameter, encoded in no
//     schema and no client — so widening or narrowing it changes every picker on
//     the NEXT RESPONSE, with no client release. Nothing in this file adds,
//     subtracts, re-centres, pads or rounds an instant, and `RideBookedWindowsTests
//     .testNothingInThisLayerKnowsTheHalfWidth` is the guard that it stays that
//     way. A client that hard-codes 45 minutes silently disagrees with the gate
//     the day the number moves.
//  2. **THE INTERVAL IS OPEN AT BOTH ENDS.** The gate compares strictly inside, so
//     a reservation for exactly `start` or exactly `end` is ACCEPTED — two rides
//     touching at a boundary are a legal back-to-back booking. `contains` is
//     therefore `start < slot && slot < end`, and the `<=` spelling — the one a
//     reader's hand reaches for — would refuse slots the server would have taken.
//  3. **A WINDOW IS A SNAPSHOT.** It can vanish (the holder cancels; a refusal is
//     a DEFERRAL, never a permanent hold on a slot) and the ACTIVE-INSTANT arm
//     SLIDES forward with the server's clock while the response does not. So this
//     layer is ADVISORY: the create-time 409 stays the authority, and every
//     degradation here points at "allowed" rather than at "blocked".
//
// The last of those is why the whole file FAILS OPEN. An unparseable instant is
// dropped rather than guessed at, an empty list dims nothing, and a fetch that
// never answered leaves the picker exactly as it was before this issue. The
// server backstops an under-dimmed picker; nothing backstops an over-dimmed one.

/// One interval in which the target vehicle cannot take a new reservation, as the
/// app speaks it: resolved instants plus the two facts the caption is worded from.
///
/// Deliberately NOT the generated `BookedWindow` re-exported. That type carries
/// RFC 3339 STRINGS, and every consumer here compares against a `Date` resolved by
/// `RideRequestContractMapping.scheduledDate` — parsing at each comparison site is
/// how one of them ends up with a different parser. Parsed once, at the seam.
struct RideBookedWindow: Equatable, Sendable {
    /// EXCLUSIVE lower bound. A reservation for exactly this instant is accepted.
    let start: Date
    /// EXCLUSIVE upper bound. A reservation for exactly this instant is accepted.
    let end: Date
    /// The claim is a still-undecided `requested` reservation rather than one the
    /// owner committed to.
    ///
    /// **IT CHANGES THE WORDS, NEVER THE AVAILABILITY.** §7.22 is explicit that
    /// pending claims count in FULL against a create — the gate counts them
    /// deliberately, so a rider is never handed a booking that is going to collide
    /// with somebody's unanswered request and cost the owner a hand-decline. A
    /// `pending` window is dimmed exactly as hard as a committed one; all it buys
    /// is "already requested" in place of the untrue "booked".
    let pending: Bool
    /// The occupying ride is one the CALLER themselves requested.
    ///
    /// Purely presentational — an own window blocks a new booking exactly as hard
    /// as anybody else's, because the gate does not care whose the other ride is.
    /// It exists because the r15 report was a rider colliding with their OWN noon
    /// reservation, and "that car is busy" would have been a poor answer to it.
    let own: Bool

    /// Whether `instant` falls STRICTLY inside this window.
    ///
    /// The strictness is the contract's, not a rounding preference: "a picker that
    /// dims the endpoints refuses a slot the server would have taken; it should dim
    /// `start < slot < end`."
    func contains(_ instant: Date) -> Bool { start < instant && instant < end }
}

// MARK: - Wire → app

/// Folds §7.22's response onto ``RideBookedWindow``. The ONE place a window
/// instant is parsed.
enum RideBookedWindowMapping {

    /// Every window in the response that resolves to a real interval, in wire
    /// order (`start` ascending, per §7.22).
    ///
    /// **A ROW THAT DOES NOT PARSE IS DROPPED, NOT GUESSED AT.** Both instants are
    /// required and non-null on the wire, so this cannot fire against a healthy
    /// server — but the failure direction has to be chosen deliberately, and the
    /// only safe one is toward the OPEN picker: a dropped window under-dims and the
    /// create-time 409 catches it, whereas a fabricated one dims a slot the server
    /// would have accepted and the rider has no recourse at all. Same reasoning as
    /// `LiveFleetMemberMapping`'s service-window parse degrading to "no bound".
    ///
    /// A window whose `end` is not strictly after its `start` is dropped for the
    /// same reason: §7.22 guarantees it never happens, and an inverted interval
    /// would make `contains` vacuously false anyway — dropping it says so.
    static func windows(from response: VehicleBookedWindowsResponse) -> [RideBookedWindow] {
        response.items.compactMap(window(from:))
    }

    static func window(from wire: BookedWindow) -> RideBookedWindow? {
        guard let start = RideRequestContractMapping.parseISO(wire.start),
              let end = RideRequestContractMapping.parseISO(wire.end),
              end > start
        else { return nil }
        return RideBookedWindow(start: start, end: end, pending: wire.pending, own: wire.own)
    }
}

// MARK: - The picker rules

/// The pure layer over a set of windows: which slot is blocked, and what the card
/// says about it.
///
/// A sibling of ``RideScheduleFloor`` rather than a second copy of its machinery —
/// the floor threads these windows through its OWN grid predicate, so the day
/// chips, the time chips, the CTA gate and the selection reconciler all read one
/// rule and cannot disagree about a slot.
enum RideBookedWindows {

    /// The window blocking `instant`, or `nil` when nothing does.
    ///
    /// **PRECEDENCE WHEN SEVERAL WINDOWS COVER ONE SLOT: the rider's OWN wins.**
    /// §7.22 emits one item per occupying ride and does not merge them, so overlap
    /// is possible (rare — the gate keeps open rides on one car at least a
    /// half-width apart — but reachable through pre-gate rows and the reschedule
    /// path). Availability is identical whichever is chosen; only the CAPTION
    /// differs, and "you already have a ride around this time" is both the more
    /// specific fact and the more actionable one. "That car is booked" said to
    /// somebody looking at their own reservation is the r15 report's failure mode
    /// restated as copy. Ties beyond that fall to wire order, i.e. earliest start.
    static func conflict(at instant: Date, in windows: [RideBookedWindow]) -> RideBookedWindow? {
        let overlapping = windows.filter { $0.contains(instant) }
        return overlapping.first { $0.own } ?? overlapping.first
    }

    /// The window blocking one picker CELL, resolved through the same
    /// day/time → instant rule the create body is encoded with
    /// (`RideRequestContractMapping.scheduledDate`).
    ///
    /// Re-deriving that rule here would be a second implementation of a subtle
    /// calendar rule (weekday roll-over, "Today" past the wall clock, MYR-370's
    /// dated tokens), and the two would drift — which is exactly the reasoning
    /// `RideScheduleFloor` already records for the service-window floor. A cell
    /// whose day/time cannot be resolved at all conflicts with NOTHING: the server
    /// is the authority on validity, and a client that blocked slots it merely
    /// failed to parse would shrink the picker for no stated reason.
    static func conflict(
        day: String,
        time: String,
        windows: [RideBookedWindow],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> RideBookedWindow? {
        guard !windows.isEmpty,
              let slot = RideRequestContractMapping.scheduledDate(
                  from: RideSchedule(day: day, time: time), now: now, calendar: calendar
              )
        else { return nil }
        return conflict(at: slot, in: windows)
    }

    /// Whether one picker cell clears every window. The predicate
    /// ``RideScheduleFloor`` folds into its grid.
    static func allows(
        day: String,
        time: String,
        windows: [RideBookedWindow],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        conflict(day: day, time: time, windows: windows, now: now, calendar: calendar) == nil
    }

    // MARK: - Copy

    /// The card's muted caption for a conflicted SELECTION, or `nil` when there is
    /// nothing to say.
    ///
    /// Grammar follows `VehicleServiceWindow.schedulingCaption` ("Lunar is in
    /// service until Sat, Aug 1 · 2:00 PM") — one muted line, present tense, the
    /// subject named first, no punctuation flourish. Four variants, because `own`
    /// and `pending` are independent facts and each pair is a genuinely different
    /// sentence:
    ///
    ///  • own, committed → "You already have a ride around this time"
    ///  • own, pending   → "You already have a ride requested around this time"
    ///  • theirs, committed → "Lunar is booked around this time"
    ///  • theirs, pending   → "Lunar is already requested around this time"
    ///
    /// **"AROUND", NOT "AT", IN ALL FOUR.** The blocked interval is wider than the
    /// occupying ride — it is that ride plus the drive to the next pickup — and the
    /// picker is deliberately not told by how much. "At this time" would claim the
    /// other ride is at the slot the rider picked, which is usually false and is
    /// the closest this copy could come to leaking the half-width the contract
    /// keeps off the wire.
    ///
    /// **"BOOKED" IS RESERVED FOR A COMMITTED CLAIM.** A rider told a slot is
    /// booked when it is merely contested has been misinformed, and this whole
    /// surface exists because the client asked for accuracy.
    ///
    /// The vehicle name is only needed on the two `own == false` arms; an empty or
    /// whitespace name suppresses those (the same guard `schedulingCaption` makes)
    /// rather than emitting " is booked around this time". The OWN arms need no
    /// name and are therefore never suppressed — what they say is true of the
    /// rider whatever the car is called.
    static func caption(vehicleName: String, conflict: RideBookedWindow?) -> String? {
        guard let conflict else { return nil }
        if conflict.own {
            return conflict.pending
                ? "You already have a ride requested around this time"
                : "You already have a ride around this time"
        }
        let name = vehicleName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return conflict.pending
            ? "\(name) is already requested around this time"
            : "\(name) is booked around this time"
    }
}
