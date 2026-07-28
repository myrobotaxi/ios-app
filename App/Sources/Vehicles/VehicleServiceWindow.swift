import Foundation

// MARK: - VehicleServiceWindow (MYR-316)
//
// The PURE decision layer for the service window — the single nullable instant
// `serviceEstimatedEndAt` (contracts 0.17.0), which says when the car's current
// service visit is estimated to END. Three consumers, three rules, all here so
// each is unit-testable without a view, a network, or a wall clock:
//
//   1. THE OWNER'S DISPLAY — "Estimated completion · <time>", beneath the In
//      Service badge on the owner sheet.
//   2. THE OWNER'S ENTRY — is the instant they picked actually valid (future)?
//      The server owns this rule; we mirror it so the owner gets an immediate
//      local answer instead of a round trip to be told no.
//   3. THE RIDER'S SCHEDULING FLOOR — the earliest instant a ride may be booked
//      against a car that is in service, plus a small buffer, and the muted
//      caption that explains why the early slots are gone.
//
// THE HONESTY RULE THAT GOVERNS ALL THREE: `nil` means NO WINDOW IS KNOWN, and
// that is the COMMON case — Tesla returns an all-null `service_data` body for
// any visit with no appointment record. So `nil` NEVER produces a display line,
// NEVER blocks a schedule slot, and NEVER means "we couldn't read it". The
// contract states this as a consumer rule in as many words: "when the field is
// ABSENT or NULL there is NO BOUND and scheduling stays fully open — consumers
// MUST NEVER block or gate scheduling on missing data."
//
// Every function takes an injected `now`/`calendar` (the
// `DriveContractMapping.dateGroup(…, now:)` precedent) so the matrices are
// deterministic under test and correct at runtime, where the defaults are the
// device's own clock and time zone.

public enum VehicleServiceWindow {

    // MARK: - 1. Owner display

    /// The owner-facing completion time, or `nil` when nothing honest can be said.
    ///
    /// Two shapes, because a bare "2:00 PM" is ambiguous the moment the estimate
    /// isn't today — and a service visit routinely spans days:
    ///   • SAME calendar day  → `"~2:00 PM"`
    ///   • ANY other day      → `"Sat ~2:00 PM"` (weekday + time)
    ///
    /// The `~` is load-bearing: this is an ESTIMATE (Tesla's or the owner's), not
    /// a commitment, and the copy must not read like an appointment the app can
    /// guarantee. A weekday name (rather than a date) is enough because a service
    /// visit that runs more than a week out is not a case this line is trying to
    /// serve — and the entry sheet shows the full date for anyone who needs it.
    public static func completionLabel(
        for end: Date?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String? {
        guard let end else { return nil }
        let time = timeFormatter(calendar: calendar).string(from: end)
        guard !calendar.isDate(end, inSameDayAs: now) else { return "~\(time)" }
        return "\(weekdayFormatter(calendar: calendar).string(from: end)) ~\(time)"
    }

    /// The full line the owner sheet renders beneath the In Service badge, or
    /// `nil` to render NOTHING (honest absence — no "unknown", no placeholder).
    ///
    /// Gated on the status as well as the value: the contract clears the field
    /// automatically when the car leaves `in_service`, but a client that had
    /// already read a value and then saw a parked status would otherwise keep a
    /// completion time on screen for a car that is demonstrably back. Requiring
    /// BOTH makes that unrepresentable rather than merely unlikely.
    public static func completionLine(
        for end: Date?,
        isInService: Bool,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String? {
        guard isInService, let label = completionLabel(for: end, now: now, calendar: calendar) else { return nil }
        return "Estimated completion \u{00B7} \(label)"
    }

    // MARK: - 2. Owner entry validation

    /// Whether an owner-picked instant is one the server will accept. Mirrors the
    /// server's rule EXACTLY ("must be in the future") rather than inventing a
    /// stricter client-side one — a client that demanded, say, an hour of lead
    /// time would reject entries the server would happily take, and the owner
    /// would have no way to tell which rule they had hit.
    ///
    /// The mirror is a courtesy, not the authority: the server still validates,
    /// and the write path folds its `400 invalid_request` onto an honest notice.
    public static func isEnterable(_ candidate: Date, now: Date = Date()) -> Bool {
        candidate > now
    }

    // MARK: - 3. Rider scheduling floor

    /// The buffer added to the estimated completion before the first bookable
    /// slot. A car does not become available the instant service "ends" — it has
    /// to be collected, and the estimate is an estimate. 15 minutes is the
    /// smallest interval the picker can express (its time chips step by 30, so
    /// this reliably pushes past the boundary slot rather than landing exactly on
    /// it), which keeps the floor from promising the very minute the window closes.
    public static let schedulingBuffer: TimeInterval = 15 * 60

    /// The earliest instant a ride may be scheduled against this vehicle, or
    /// `nil` when there is NO bound.
    ///
    /// `nil` in → `nil` out, deliberately and non-negotiably: an unknown window
    /// leaves scheduling FULLY OPEN. This is the single most important line in
    /// the file — the failure mode it prevents is a car with no Tesla appointment
    /// record (the common case) becoming unbookable forever.
    public static func earliestSelectable(
        serviceEstimatedEndAt end: Date?,
        buffer: TimeInterval = schedulingBuffer
    ) -> Date? {
        end.map { $0.addingTimeInterval(buffer) }
    }

    /// Whether a candidate pickup instant clears the floor. A `nil` floor allows
    /// everything; the boundary instant itself is ALLOWED (`>=`), so the floor
    /// names the first bookable moment rather than the last blocked one.
    public static func allows(_ slot: Date, floor: Date?) -> Bool {
        guard let floor else { return true }
        return slot >= floor
    }

    /// The muted caption on the scheduling card: "Lunar is in service until
    /// ~Sat 2 PM". `nil` when there is no window — the card then renders exactly
    /// as it always has.
    ///
    /// The time here is COMPACT ("2 PM", not "2:00 PM") because it sits inside a
    /// sentence rather than in a value slot, and ":00" reads as precision this
    /// number does not have. The weekday is dropped when the estimate is today,
    /// for the same reason it is in ``completionLabel(for:now:calendar:)``.
    ///
    /// Note the caption names the ESTIMATED END, not the floor: the buffer is an
    /// implementation detail of which slots we offer, and quoting "2:15 PM" would
    /// imply a precision the estimate does not carry. The picker's disabled slots
    /// are where the buffer becomes visible.
    public static func schedulingCaption(
        vehicleName: String,
        serviceEstimatedEndAt end: Date?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String? {
        guard let end else { return nil }
        let name = vehicleName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let time = compactTime(end, calendar: calendar)
        let when = calendar.isDate(end, inSameDayAs: now)
            ? "~\(time)"
            : "~\(weekdayFormatter(calendar: calendar).string(from: end)) \(time)"
        return "\(name) is in service until \(when)"
    }

    // MARK: - Formatters
    //
    // Fixed `en_US_POSIX` locale, matching `RideRequestContractMapping`'s clock
    // parser: the schedule picker's own chips are English 12-hour strings, so a
    // 24-hour device locale would otherwise print a completion time in a format
    // that no longer lines up with the chips beside it.

    private static func timeFormatter(calendar: Calendar) -> DateFormatter {
        formatter(dateFormat: "h:mm a", calendar: calendar)
    }

    /// "2 PM" on the hour, "2:30 PM" otherwise — the in-sentence form. Dropping a
    /// ":00" that carries no information is what keeps the caption reading like a
    /// sentence instead of a timestamp.
    private static func compactTime(_ date: Date, calendar: Calendar) -> String {
        let onTheHour = calendar.component(.minute, from: date) == 0
        return formatter(dateFormat: onTheHour ? "h a" : "h:mm a", calendar: calendar).string(from: date)
    }

    private static func weekdayFormatter(calendar: Calendar) -> DateFormatter {
        formatter(dateFormat: "EEE", calendar: calendar)
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
