import Foundation

// MARK: - RideScheduleTimes (MYR-464)
//
// THE TIME CHIPS ARE A GENERATED GRID, AND ITS STEP IS FIFTEEN MINUTES.
//
// External beta, build 202608030843: *"I can't schedule 7:45. Something is off in
// design here."* The picker offered slots on the hour and the half hour only, so
// 7:45 was not a slot the tester failed to find — it did not exist. For a
// ride-hailing product whose natural request is "leave in about twenty minutes",
// half-hour buckets are the wrong resolution: the nearest bookable slot is up to
// fifteen minutes from what the rider wants, and the rider has no way to tell
// whether that is a product rule or a bug.
//
// It lives here rather than in `RideRequestFixtures` for MYR-370's reason,
// verbatim: the day row moved out of the fixtures the moment it stopped being a
// transcription of the prototype and became a rule with a clock in it, and the
// time row is now the same. **These strings are on the LIVE path** — the picker
// renders them for a real rider and `RideRequestContractMapping.scheduledFor`
// encodes the chosen one into the create body — so a name that says "fixture" is
// a MYR-228 trap waiting for someone who greps for one.
//
// THE STRINGS ARE THE WIRE ENCODER'S INPUT, WHICH IS WHY THE GRAMMAR IS FIXED.
// `RideSchedule.time` is a display string, and `RideRequestContractMapping
// .clockComponents` parses exactly this `en_US_POSIX` 12-hour shape back out of
// it. Widening the grid therefore had to be checked in both directions, and is:
// every slot this generator mints round-trips through that parser to the minute
// it names (`RideScheduleTimesTests`), and a `:15`/`:45` slot is no different in
// kind from the `:00`/`:30` ones that have always shipped.
//
// NOTHING ABOUT AN OLDER SLOT BREAKS. A schedule an earlier build committed is a
// half-hour string, every one of which is still in this grid, so it still selects,
// still renders and still encodes. No legacy table is needed and none is kept.
enum RideScheduleTimes {

    /// First and last bookable HOUR of the day, inclusive of the first and of the
    /// last slot inside the last hour. Unchanged from the half-hour grid: this
    /// issue is about resolution, not about opening hours.
    static let firstHour = 7
    static let lastHour = 22

    /// The step, in minutes.
    ///
    /// Fifteen rather than five or ten: it is the finest step at which the row is
    /// still readable at a glance (four chips per hour, and the quarter-hours are
    /// the times people actually say out loud), and it keeps the row to 64 chips
    /// rather than 192.
    static let stepMinutes = 15

    /// "7:00 AM" … "10:45 PM" — the row, in order.
    ///
    /// Computed once. A grid this size is cheap, but it is read inside a
    /// `ForEach` and inside `RideScheduleFloor.allowedTimes`, which the day row
    /// calls once PER DAY CHIP on every render.
    static let grid: [String] = {
        var out: [String] = []
        for hour in firstHour...lastHour {
            for minute in stride(from: 0, to: 60, by: stepMinutes) {
                out.append(label(hour24: hour, minute: minute))
            }
        }
        return out
    }()

    /// The picker's own 12-hour grammar, spelled once.
    ///
    /// Deliberately built by hand rather than by a `DateFormatter`: these strings
    /// are compared for equality against a committed `RideSchedule.time` and fed
    /// to a fixed `en_US_POSIX` parser, so a device locale must not be able to
    /// reach them (the same rule `RideScheduleDays`' formatters state).
    static func label(hour24: Int, minute: Int) -> String {
        let meridiem = hour24 >= 12 ? "PM" : "AM"
        let hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12
        return String(format: "%d:%02d %@", hour12, minute, meridiem)
    }
}
