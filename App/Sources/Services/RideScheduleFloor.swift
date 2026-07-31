import Foundation

// MARK: - RideScheduleFloor (MYR-316)
//
// The rider scheduling picker is a pair of chip rows — a DAY token
// ("Today"/"Tomorrow"/"Thu"…"Mon") crossed with a 12-hour wall clock ("5:30 PM")
// — not a continuous date picker. So "floor the earliest selectable slot at the
// service window" cannot be expressed as a `DatePicker(in:)` range: it has to be
// evaluated per CELL of that grid.
//
// This is the pure layer that does it. Every cell is resolved to a real instant
// by the EXISTING `RideRequestContractMapping.scheduledDate(from:now:calendar:)`
// — the same function that later encodes the chosen slot into the create body's
// `scheduledFor` — so a slot the picker offers and the instant the server is
// asked for can never diverge. Re-deriving the day/time → instant rule here
// would be a second implementation of a subtle calendar rule (weekday roll-over,
// "Today" past the wall clock, …), and the two would drift.
//
// THE GOVERNING RULE, again: a `nil` floor allows EVERYTHING. An unknown service
// window leaves scheduling fully open, per the contract's explicit consumer
// guidance. Every function here degrades to "all allowed" on nil, so a bug that
// loses the floor makes the picker permissive, never bricked.
//
// MYR-385 — THE GRID NOW ANSWERS TO TWO RULES, AND THAT IS WHY THEY MEET HERE.
// A slot can be out because the car is still in a service bay (the floor, above)
// or because the car is already spoken for at that hour (§7.22's booked windows,
// `RideBookedWindows.swift`). They are unrelated facts from unrelated endpoints,
// and the second was NOT given its own parallel set of `allowedTimes` /
// `allowedDays` / `firstAllowedSlot` helpers — because five call sites in the
// card (day chips, time chips, the CTA gate, the selection reconciler, its
// fallback scan) would then each have had to remember to consult both, and the
// first one to forget produces a chip the CTA refuses or a "first bookable slot"
// that is not bookable. `windows` defaults to `[]`, which allows everything, so
// every pre-MYR-385 caller and test is unchanged by construction.
//
// The two rules are also DIFFERENT IN KIND and neither may be expressed as the
// other: the floor is a single monotone bound (everything before an instant is
// out), while windows are a scattered set of intervals with gaps a rider can and
// should book into. Folding windows into a "floor" would push the earliest
// bookable slot past a perfectly free morning.

enum RideScheduleFloor {

    /// Whether one picker cell is bookable against `floor` AND against the
    /// vehicle's booked `windows`.
    ///
    /// A cell whose day/time cannot be resolved at all (an unparseable time — not
    /// reachable from the shipped chip sets, but the mapping's signature admits
    /// it) is ALLOWED. The server is the authority on validity; a client that
    /// hid slots it merely failed to parse would silently shrink the picker.
    static func allows(
        day: String,
        time: String,
        floor: Date?,
        windows: [RideBookedWindow] = [],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        guard let slot = RideRequestContractMapping.scheduledDate(
            from: RideSchedule(day: day, time: time), now: now, calendar: calendar
        ) else { return true }

        // MYR-370 — THE CHIP'S DATE IS BINDING. A cell is offered only when the
        // instant it resolves to lands on the calendar day its chip names.
        //
        // This is what retires the roll-forward as a *visible* behaviour. The
        // encoder still rolls (MYR-179: "a reservation is never in the past",
        // and it is the authority on what reaches the wire) — but a slot that
        // would roll is now simply never offered, so the roll can no longer fire
        // from the picker at all. Concretely: "Today 7:00 AM" tapped at 10 PM
        // used to book TOMORROW 7 AM under a chip that said Today. It is dimmed
        // now, which is the honest answer, and the picker's remaining slots all
        // mean exactly what they say. `RideScheduleDaysTests` asserts that
        // invariant across the whole grid.
        //
        // Legacy bare-weekday tokens name no date, so `dayStart` is nil for them
        // and they skip this check entirely — a schedule committed by an older
        // build keeps resolving exactly as it did.
        if let dayStart = RideScheduleDays.dayStart(forToken: day, now: now, calendar: calendar),
           !calendar.isDate(slot, inSameDayAs: dayStart) {
            return false
        }

        // MYR-385 — §7.22's booked windows. Checked on the RESOLVED instant (the
        // same one the create body would carry), strictly inside, so the picker's
        // verdict and the gate's are the same comparison on the same value.
        // `windows` is empty whenever the read has not landed, has failed, or the
        // path is simulated — all three of which mean "no dimming", which is the
        // pre-MYR-385 picker exactly.
        if RideBookedWindows.conflict(at: slot, in: windows) != nil { return false }

        guard let floor else { return true }
        return VehicleServiceWindow.allows(slot, floor: floor)
    }

    /// The times bookable on `day`. Empty means the whole day is out.
    ///
    /// NOTE there is no `floor == nil` fast path any more. A nil floor still
    /// allows everything the SERVICE WINDOW would have blocked — that guarantee
    /// is untouched and is asserted — but the day-identity check above is not
    /// about the service window, and short-circuiting past it is what let the
    /// picker offer this morning's slots at ten tonight on every car that has no
    /// window at all (i.e. the common case).
    static func allowedTimes(
        on day: String,
        times: [String],
        floor: Date?,
        windows: [RideBookedWindow] = [],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [String] {
        times.filter { allows(day: day, time: $0, floor: floor, windows: windows, now: now, calendar: calendar) }
    }

    /// The days with at least one bookable time.
    ///
    /// A day is disabled ONLY when every one of its times is blocked — the picker
    /// never hides a day whose evening is still reachable just because its morning
    /// is not. That matters on the boundary day, which is the single most common
    /// case: the car is back at 2 PM, and "Today" must stay pickable.
    static func allowedDays(
        _ days: [String],
        times: [String],
        floor: Date?,
        windows: [RideBookedWindow] = [],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [String] {
        days.filter {
            !allowedTimes(on: $0, times: times, floor: floor, windows: windows, now: now, calendar: calendar).isEmpty
        }
    }

    /// The first bookable cell, scanning days in the picker's own order and times
    /// within each — the selection the sheet should open on when the rider's
    /// current pick is blocked. `nil` when nothing in the grid clears the floor
    /// (a service visit further out than the picker's horizon), which the caller
    /// treats as "leave the selection alone and let the CTA stay disabled" rather
    /// than as an excuse to offer an invalid slot.
    static func firstAllowedSlot(
        days: [String],
        times: [String],
        floor: Date?,
        windows: [RideBookedWindow] = [],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> RideSchedule? {
        for day in days {
            if let time = allowedTimes(
                on: day, times: times, floor: floor, windows: windows, now: now, calendar: calendar
            ).first {
                return RideSchedule(day: day, time: time)
            }
        }
        return nil
    }
}

// MARK: - RideScheduleConflict (MYR-370)

/// The confirm screen's plain-language line for a reservation the service window
/// has since overtaken.
///
/// A slot can be legal when it is picked and illegal by the time the rider
/// reaches Review: the owner can enter (or Tesla can revise) a completion
/// estimate at any point in between, and the picker is not re-run. Before this
/// the only thing on that screen saying so was the muted **"In service"** chip on
/// the vehicle row — a STATE badge, which says what the car is doing now and says
/// nothing at all about the reservation the rider is one tap from placing. So the
/// rider read "In service", read their own chosen time beside it, and had no way
/// to connect the two.
///
/// This is a sentence about the RESERVATION, and it names both halves: the slot
/// that is now unreachable and the moment the car is back.
enum RideScheduleConflict {

    /// `nil` when there is nothing to say — no reservation, NO KNOWN WINDOW, or a
    /// slot that still clears the floor.
    ///
    /// The nil-window arm is the fail-open rule this whole feature is built on
    /// (`VehicleServiceWindow.earliestSelectable` returns nil ⇒ no floor ⇒ no
    /// conflict is knowable). Owner acceptance remains the real gate throughout:
    /// this line is advisory and never blocks the submit, because a client that
    /// refused a ride on a stale estimate would be wrong more often than the
    /// estimate is.
    static func copy(
        vehicleName: String,
        schedule: RideSchedule?,
        serviceEstimatedEndAt end: Date?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String? {
        let name = vehicleName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let schedule,
              let floor = VehicleServiceWindow.earliestSelectable(serviceEstimatedEndAt: end),
              let slot = RideRequestContractMapping.scheduledDate(from: schedule, now: now, calendar: calendar),
              !VehicleServiceWindow.allows(slot, floor: floor),
              let back = VehicleServiceWindow.completionLabel(for: end, now: now, calendar: calendar)
        else { return nil }
        return "\(name) is still in service at \(RideScheduleDisplay.phrase(schedule)) \u{2014} back \(back). Pick a later time."
    }
}
