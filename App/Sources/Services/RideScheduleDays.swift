import Foundation

// MARK: - RideScheduleDays (MYR-370)
//
// THE DAY CHIPS ARE GENERATED FROM `now`. They used to be a hard-coded literal.
//
// `RideRequestFixtures.scheduleDays` was `["Today", "Tomorrow", "Thu", "Fri",
// "Sat", "Sun", "Mon"]`, transcribed verbatim from the prototype's
// `ride-request.jsx`. That list is a SNAPSHOT of one particular week: the sibling
// `ScheduledRideSheet.schedDates` maps the same seven tokens to "Jun 16" … "Jun
// 22", and 2026-06-16 was a TUESDAY. So the row is chronological if and only if
// the rider opens it on a Tuesday, and on every other weekday it is wrong in two
// ways at once:
//
//  1. **Duplicate weekdays.** On Thursday it reads `Today · Tomorrow · Thu · Fri
//     · Sat · Sun · Mon` — "Thu" repeats Today's weekday and "Fri" repeats
//     Tomorrow's. The rider sees the same day named twice with no way to tell
//     the two apart.
//  2. **Non-chronological, by a whole week.** The tokens are resolved by
//     `RideRequestContractMapping.scheduledDate`, whose weekday rule is "the next
//     date carrying that weekday, and if that lands on today with the wall clock
//     already gone, the following week's". Opened at 10 PM on Thu Jul 30, the row
//     therefore resolves to Jul 30 → Jul 31 → **Aug 6** → **Jul 31** → Aug 1 →
//     Aug 2 → Aug 3. Chip 2 jumps a week forward and chip 3 jumps six days back.
//
// That is the whole of the client's report. His "Thu 7:00 AM" was Thursday
// **August 6th** — genuinely clear of the service window, and genuinely not what
// anybody reading a chip labelled "Thu" on a Thursday would expect. The picker
// was not offering a slot inside the window; it was refusing to say which day it
// had booked. Both halves are fixed by making the day a DATE the rider can read
// rather than a weekday they have to guess at.
//
// Every function takes an injected `now`/`calendar` — the
// `DriveContractMapping.dateGroup(…, now:)` precedent that `VehicleServiceWindow`
// and `RideScheduleFloor` already follow — so the matrices are deterministic
// under test and correct at runtime, where the defaults are the rider's own
// device clock and time zone.

/// One day chip: the calendar day it names, and the label printed on it.
struct RideScheduleDay: Equatable, Hashable, Sendable {
    /// Start of the day, in the resolving calendar's time zone.
    let date: Date
    /// "Today" / "Tomorrow" / "Thu, Aug 6" — and the value committed into
    /// `RideSchedule.day`, so every confirm surface carries the date for free.
    let token: String
}

enum RideScheduleDays {

    /// Seven days, matching the horizon the hard-coded list happened to span.
    static let horizon = 7

    /// The chip row: strictly chronological, one entry per calendar day starting
    /// at today, with **explicit dates beyond Today/Tomorrow**.
    ///
    /// "Today" and "Tomorrow" keep their words because they are unambiguous and
    /// are what the prototype prints; from the third chip on, a weekday alone
    /// stops disambiguating (that is exactly how "Thu" came to mean two different
    /// Thursdays), so the label carries the date.
    static func days(
        now: Date = Date(),
        calendar: Calendar = .current,
        count: Int = horizon
    ) -> [RideScheduleDay] {
        let today = calendar.startOfDay(for: now)
        return (0..<max(0, count)).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: today) else { return nil }
            return RideScheduleDay(date: date, token: label(offset: offset, date: date, calendar: calendar))
        }
    }

    /// The label for one offset. Deliberately the SAME `"EEE, MMM d"` grammar
    /// `VehicleServiceWindow` writes its completion instant in, so the caption
    /// above the row ("Lunar is in service until Sat, Aug 1 · 11:30 AM") and the
    /// chip the rider matches it against ("Sat, Aug 1") are one date format
    /// rather than two. `RideScheduleDaysTests` pins that agreement.
    static func label(offset: Int, date: Date, calendar: Calendar = .current) -> String {
        switch offset {
        case 0: return "Today"
        case 1: return "Tomorrow"
        default: return dateFormatter(calendar: calendar).string(from: date)
        }
    }

    /// The chip label for an ARBITRARY instant, in the reader's own calendar.
    ///
    /// MYR-377 — the rider's Scheduled tab renders reservations off the wire, whose
    /// `scheduledFor` is a UTC instant rather than one of this generator's seven
    /// offsets. It must print that instant in the SAME grammar the picker used when
    /// the rider committed it, or a ride booked from a chip reading "Sat, Aug 1"
    /// would come back listed some other way. So the offset is derived and the
    /// existing `label(offset:date:)` does the writing — one grammar, one place.
    ///
    /// A day beyond the picker's horizon (a reservation ten days out, once the
    /// reschedule flow can move one) takes the dated form, which is what every
    /// offset past 1 already does. A day in the PAST takes it too: "Today"/
    /// "Tomorrow" are the only relative words here and neither is ever true
    /// backwards.
    static func label(
        for instant: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let day = calendar.startOfDay(for: instant)
        let offset = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: day).day ?? 0
        // `label(offset:date:)` already answers the dated form for everything that
        // is not 0 or 1, negatives included, so no clamping is needed or wanted.
        return label(offset: offset, date: day, calendar: calendar)
    }

    /// "6:30 AM" — the wall clock, in the reader's own calendar, in the picker's own
    /// `en_US_POSIX` 12-hour grammar (`RideRequestContractMapping.clockParser`
    /// reads exactly this shape back).
    static func timeLabel(for instant: Date, calendar: Calendar = .current) -> String {
        formatter(dateFormat: "h:mm a", calendar: calendar).string(from: instant)
    }

    /// "Aug 1" — the bare date, for the secondary line that sits beside a relative
    /// day word. The prototype's `SCHED_DATES` table is exactly this, resolved
    /// rather than transcribed.
    static func shortDate(for instant: Date, calendar: Calendar = .current) -> String {
        formatter(dateFormat: "MMM d", calendar: calendar).string(from: instant)
    }

    /// The calendar day a committed `RideSchedule.day` token names, or `nil` when
    /// the token is not one this generator produces.
    ///
    /// `nil` is how the legacy BARE-WEEKDAY tokens ("Thu", "Sat") stay working:
    /// `RideRequestContractMapping.scheduledDate` falls through to its existing
    /// weekday branch for them, so a schedule committed by an older build — or
    /// anything already in flight — resolves exactly as it did before. This
    /// generator simply stops MINTING them.
    static func dayStart(
        forToken token: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Date? {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        let today = calendar.startOfDay(for: now)
        switch trimmed.lowercased() {
        case "today": return today
        case "tomorrow": return calendar.date(byAdding: .day, value: 1, to: today)
        default: break
        }
        guard let monthDay = monthDay(from: trimmed, calendar: calendar) else { return nil }

        // No year travels in the label (a picker seven days deep never needs
        // one), so resolve to the NEXT occurrence at or after today — which is
        // what makes the row keep working across a New Year's boundary, where
        // "Fri, Jan 2" is next year's date read on Dec 30.
        let thisYear = calendar.component(.year, from: today)
        for year in [thisYear, thisYear + 1] {
            var components = DateComponents()
            components.year = year
            components.month = monthDay.month
            components.day = monthDay.day
            guard let candidate = calendar.date(from: components) else { continue }
            let start = calendar.startOfDay(for: candidate)
            if start >= today { return start }
        }
        return nil
    }

    /// The calendar day an EXPLICITLY DATED token ("Thu, Aug 6") names — `nil`
    /// for "Today", "Tomorrow" and for every legacy bare weekday.
    ///
    /// Split out from ``dayStart(forToken:now:calendar:)`` because
    /// `RideRequestContractMapping.scheduledDate` must keep its OWN handling of
    /// the two relative words: "Today" carries MYR-179's roll-forward ("a
    /// reservation is never in the past") and that rule is the wire encoder's,
    /// not this generator's to quietly repeal.
    static func datedTokenDayStart(
        forToken token: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Date? {
        switch token.trimmingCharacters(in: .whitespaces).lowercased() {
        case "today", "tomorrow": return nil
        default: return dayStart(forToken: token, now: now, calendar: calendar)
        }
    }

    /// Whether `token` is one this generator mints (as opposed to a legacy bare
    /// weekday). Used by the picker's day-identity check.
    static func isGeneratedToken(
        _ token: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        dayStart(forToken: token, now: now, calendar: calendar) != nil
    }

    // MARK: - Parsing

    /// "Thu, Aug 6" → (8, 6). The weekday prefix is STRIPPED rather than parsed:
    /// a `DateFormatter` reading `"EEE, MMM d"` with no year lands in a reference
    /// year whose Aug 6 falls on some other weekday, and how strictly it then
    /// treats that disagreement is not ours to depend on. The month and day are
    /// the only parts that carry meaning here.
    private static func monthDay(from token: String, calendar: Calendar) -> (month: Int, day: Int)? {
        let datePart = token.contains(",")
            ? token.split(separator: ",").dropFirst().joined(separator: ",").trimmingCharacters(in: .whitespaces)
            : token
        guard !datePart.isEmpty, let parsed = formatter(dateFormat: "MMM d", calendar: calendar).date(from: datePart)
        else { return nil }
        let components = calendar.dateComponents([.month, .day], from: parsed)
        guard let month = components.month, let day = components.day else { return nil }
        return (month, day)
    }

    // MARK: - Formatters
    //
    // Fixed `en_US_POSIX`, matching `VehicleServiceWindow`'s and
    // `RideRequestContractMapping`'s: the picker's time chips are English
    // 12-hour strings, so a device locale that wrote the DAY chips some other way
    // would put two grammars in one row.

    private static func dateFormatter(calendar: Calendar) -> DateFormatter {
        formatter(dateFormat: "EEE, MMM d", calendar: calendar)
    }

    private static func formatter(dateFormat: String, calendar: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = dateFormat
        return f
    }
}

// MARK: - RideScheduleDisplay (MYR-370)

/// The ONE phrase every confirm surface prints for a committed slot.
///
/// The four surfaces that quote a schedule — the card's CTA, the search sheet's
/// summary row, the Review badge and the owner's incoming sheet — each composed
/// their own string, and three of the four used a bare space between the day and
/// the time. With the day now carrying a date ("Thu, Aug 6"), a bare space reads
/// as one run-on date. They all go through this instead, so the grammar is one
/// fact in one place and no surface can quote a slot without its date.
enum RideScheduleDisplay {
    /// "Thu, Aug 6 · 7:00 AM"
    static func phrase(day: String, time: String) -> String {
        "\(day) \u{00B7} \(time)"
    }

    static func phrase(_ schedule: RideSchedule) -> String {
        phrase(day: schedule.day, time: schedule.time)
    }
}
