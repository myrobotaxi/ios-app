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

enum RideScheduleFloor {

    /// Whether one picker cell is bookable against `floor`.
    ///
    /// A cell whose day/time cannot be resolved at all (an unparseable time — not
    /// reachable from the shipped chip sets, but the mapping's signature admits
    /// it) is ALLOWED. The server is the authority on validity; a client that
    /// hid slots it merely failed to parse would silently shrink the picker.
    static func allows(
        day: String,
        time: String,
        floor: Date?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        guard let floor else { return true }
        guard let slot = RideRequestContractMapping.scheduledDate(
            from: RideSchedule(day: day, time: time), now: now, calendar: calendar
        ) else { return true }
        return VehicleServiceWindow.allows(slot, floor: floor)
    }

    /// The times bookable on `day`. Empty means the whole day is out.
    static func allowedTimes(
        on day: String,
        times: [String],
        floor: Date?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [String] {
        guard floor != nil else { return times }
        return times.filter { allows(day: day, time: $0, floor: floor, now: now, calendar: calendar) }
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
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [String] {
        guard floor != nil else { return days }
        return days.filter {
            !allowedTimes(on: $0, times: times, floor: floor, now: now, calendar: calendar).isEmpty
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
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> RideSchedule? {
        for day in days {
            if let time = allowedTimes(on: day, times: times, floor: floor, now: now, calendar: calendar).first {
                return RideSchedule(day: day, time: time)
            }
        }
        return nil
    }
}
